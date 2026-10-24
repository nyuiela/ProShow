import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if os(macOS)
import AppKit
#endif

extension ShowController {
    func applyLocalPreviewRenderQuality() {
        let resolution = projectSettings.resolution
        playback.configureLocalPreviewPixelBudget(
            fullWidth: resolution.width,
            fullHeight: resolution.height,
            renderPercent: UserSettingsStore.shared.localPreviewRenderPercent
        )
        compositor.programOutput.invalidate()
    }

    func configureOutputBusSubscriptions() {
        streaming.onPhoneDestinationChange = { [weak self] in self?.syncPhoneRecording() }
        let encoder = streaming.hardwareEncoder
        ProgramOutputBus.shared.subscribe(id: "sink.rtmp.encoder") { [weak self] payload in
            let passthrough = self?.isoRecorder.programFileWriter?.isPassthrough == true
            guard payload.mode.isLive || (passthrough && payload.mode.isRecording) else { return }
            StreamHoldFrameCache.remember(payload.pixelBuffer)
            if payload.mode.isLive {
                LatestFrameSlot.shared.store(payload.pixelBuffer)
                PhoneFrameIngress.shared.push(payload.pixelBuffer)
                return
            }
            encoder.encode(
                pixelBuffer: payload.pixelBuffer,
                presentationTime: payload.presentationTime,
                hostTime: payload.hostTime
            )
            Task { @MainActor in
                self?.streaming.markLastEncodeSource(.programComposite)
            }
        }
        ProgramOutputBus.shared.subscribe(id: "sink.program.recorder") { [weak self] payload in
            guard payload.mode.isRecording else { return }
            // Record-only 9:16: live frames already reach the Phone lane from the Stream sink.
            if !payload.mode.isLive, PhoneRecordingBridge.isActive {
                PhoneFrameIngress.shared.push(payload.pixelBuffer)
            }
            if self?.isoRecorder.programFileWriter?.isPassthrough == true { return }
            self?.isoRecorder.appendProgramFrame(
                payload.pixelBuffer,
                presentationTime: payload.presentationTime
            )
        }
        ProgramOutputBus.shared.subscribe(id: "sink.live.pixel.hub") { [weak self] payload in
            if self?.liveKitGuestReturnActive == true {
                self?.liveKitDesk.pushProgramFrame(payload.pixelBuffer)
            }
            LivePixelHub.shared.publish(
                endpoint: ProgramOutputComposer.previewEndpoint,
                sourceID: nil,
                buffer: payload.pixelBuffer,
                frameRevision: payload.frameRevision
            )
        }
        ProgramOutputBus.shared.subscribe(id: "sink.virtual.camera") { [weak self] payload in
            guard VirtualCameraOutputService.acceptsProgramFrames else { return }
            let buffer = payload.pixelBuffer
            let time = payload.presentationTime
            Task { @MainActor in
                self?.virtualCameraOutput?.enqueueProgramFrame(buffer, compositedAt: time)
            }
        }
    }

    func evaluateOutputMode() -> ProgramOutputMode {
        let preset = streaming.streamEncoderConfig.presetName
        if streaming.isLive, isoRecorder.isRecording {
            return .liveAndRecording(preset: preset)
        }
        if streaming.isLive {
            return .live(preset: preset)
        }
        if isoRecorder.isRecording {
            return .recording(capped: true)
        }
        if streamEncodePreviewEnabled {
            return .preview(source: .streamWindow)
        }
        if isAudienceOutputOn && !isAudienceCleared {
            return .preview(source: .operatorDesk)
        }
        if liveKitGuestReturnActive {
            return .preview(source: .operatorDesk)
        }
        return .idle
    }

    /// Record-only file rate: the project rate, capped at 30. Matches the 16:9 writer.
    var recordOnlyFrameRate: Int {
        min(30, max(1, projectSettings.frameRate.encoderFPS))
    }

    /// One size for composite, encoder, and file writer.
    func currentProgramRenderContract() -> ProgramRenderContract {
        switch evaluateOutputMode() {
        case .live, .liveAndRecording:
            return ProgramRenderContract(
                width: max(16, streaming.config.width),
                height: max(16, streaming.config.height),
                frameRate: max(1, streaming.config.framerate),
                colorSpace: "Rec709"
            )
        case .recording:
            let capped = StreamRecordingPaths.cappedForRecording(
                width: compositor.outputWidth,
                height: compositor.outputHeight
            )
            return ProgramRenderContract(
                width: capped.width,
                height: capped.height,
                frameRate: recordOnlyFrameRate,
                colorSpace: "Rec709"
            )
        case .preview(.operatorDesk):
            let full = ProgramRenderContract(
                width: max(16, compositor.outputWidth),
                height: max(16, compositor.outputHeight),
                frameRate: 30,
                colorSpace: "sRGB"
            )
            return full.scaledForLocalPreview(percent: UserSettingsStore.shared.localPreviewRenderPercent)
        default:
            return ProgramRenderContract(
                width: max(16, compositor.outputWidth),
                height: max(16, compositor.outputHeight),
                frameRate: 30,
                colorSpace: "sRGB"
            )
        }
    }
}


/// `GET /v1/program/probe` — read-only: what the right-pane Live monitor is sampling, plus slide layer facts.
extension ShowController {
    func programMonitorProbe() -> (Int, String) {
        var out: [String: Any] = ["ok": true]
        let stack = compositor.stack
        out["output_mode"] = String(describing: evaluateOutputMode())
        out["uses_canonical_monitor"] = usesCanonicalProgramMonitor
        out["program_output_enabled"] = programOutputEnabled
        out["slide_visible"] = stack.isVisible(.slide, onStage: false)
        out["slide_canvas_count"] = stack.slideCanvas.count
        out["slide_canvas_size"] = [stack.slideCanvasWidth, stack.slideCanvasHeight]
        out["slide_background"] = stack.slideBackgroundEnabled ? stack.slideBackgroundHex : "off"
        out["screen_color"] = stack.screenColorHex
        out["media_layer"] = stack.media?.title ?? ""
        out["objects"] = stack.slideCanvas.map { object -> [String: Any] in
            var row: [String: Any] = [
                "kind": object.kind.rawValue,
                "fill": object.fill.type.rawValue,
                "frame": [object.transform.x, object.transform.y, object.transform.width, object.transform.height],
                "audience": object.visibleOnAudience,
            ]
            let uri = object.fill.imageURI.trimmingCharacters(in: .whitespacesAndNewlines)
            if !uri.isEmpty {
                let resolved = MediaPath.resolve(uri)?.path
                row["image_resolves"] = resolved != nil
                #if os(macOS)
                if let resolved, let image = NSImage(contentsOfFile: resolved) {
                    var rect = CGRect(origin: .zero, size: image.size)
                    let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    row["image_px"] = cg.map { [$0.width, $0.height] } ?? []
                } else {
                    row["image_px"] = []
                }
                #endif
            }
            return row
        }
        #if canImport(CoreVideo)
        if let buffer = VideoInvalidationEngine.shared.buffer(forKey: ProgramOutputComposer.previewEndpoint, requiredRevision: 0) {
            out["frame"] = Self.probeSamples(buffer)
        } else {
            out["frame"] = "none"
        }
        let probeStack = compositor.stack
        for (label, playback) in [("offline_rest", BuildPlayback.rest), ("offline_settled", BuildPlayback.preview(elapsed: 86_400))] {
            if let r = ProgramOutputComposer.shared.render(
                stack: probeStack, width: 640, height: 360, video: nil, pip: nil, media: nil, videoFrame: nil,
                buildPlayback: playback, buildPhaseFilter: [.buildIn, .action], matchOnAirVisibility: true, frameAdmissionMaxWait: 0.5
            ) {
                out[label] = Self.probeSamples(r.buffer)
            } else {
                out[label] = "nil"
            }
        }
        #endif
        return (200, ControlJSON.encode(out))
    }

    #if canImport(CoreVideo)
    private static func probeSamples(_ buffer: CVPixelBuffer) -> [String: Any] {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var info: [String: Any] = ["size": [width, height], "format": CVPixelBufferGetPixelFormatType(buffer)]
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return info }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return info }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        var samples: [String: String] = [:]
        var distinct = Set<UInt32>()
        for (name, fx, fy) in [("tl", 0.1, 0.1), ("c", 0.5, 0.5), ("br", 0.9, 0.9), ("tr", 0.9, 0.1), ("bl", 0.1, 0.9)] {
            let x = min(width - 1, Int(Double(width) * fx))
            let y = min(height - 1, Int(Double(height) * fy))
            let p = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt8.self)
            samples[name] = String(format: "#%02X%02X%02X", p[2], p[1], p[0])
        }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            for x in stride(from: 0, to: width, by: max(1, width / 64)) {
                let p = base.advanced(by: y * row + x * 4).assumingMemoryBound(to: UInt32.self)
                distinct.insert(p.pointee & 0x00F0F0F0)
            }
        }
        info["samples"] = samples
        info["distinct_colors_coarse"] = distinct.count
        return info
    }
    #endif
}
