import CoreMedia
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
        ProgramOutputBus.shared.subscribe(id: "sink.rtmp.encoder") { payload in
            guard payload.mode.isLive else { return }
            StreamHoldFrameCache.remember(payload.pixelBuffer)
            LatestFrameSlot.shared.store(payload.pixelBuffer)
            PhoneFrameIngress.shared.push(payload.pixelBuffer)
        }
        // Record-only 16:9 frames go through the pacer, which repeats the last frame when the
        // program clock stalls (slide loads, the stream stop handoff), the way the live CFR
        // pacer does. A passthrough file (the stream stopped mid-recording) keeps its encoder.
        RecordOnlyFramePacer.shared.emit = { [weak self] buffer, presentationTime, hostTime in
            guard let self else { return }
            if self.isoRecorder.programFileWriter?.isPassthrough == true {
                encoder.encode(pixelBuffer: buffer, presentationTime: presentationTime, hostTime: hostTime)
            } else {
                self.isoRecorder.appendProgramFrame(buffer, presentationTime: presentationTime)
            }
        }
        ProgramOutputBus.shared.subscribe(id: "sink.program.recorder") { [weak self] payload in
            guard payload.mode.isRecording else {
                RecordOnlyFramePacer.shared.stop()
                return
            }
            // Record-only 9:16: live frames already reach the Phone lane from the Stream sink.
            if !payload.mode.isLive, PhoneRecordingBridge.isActive {
                PhoneFrameIngress.shared.push(payload.pixelBuffer)
            }
            if payload.mode.isLive {
                RecordOnlyFramePacer.shared.stop()
                if self?.isoRecorder.programFileWriter?.isPassthrough == true { return }
                self?.isoRecorder.appendProgramFrame(
                    payload.pixelBuffer,
                    presentationTime: payload.presentationTime
                )
                return
            }
            RecordOnlyFramePacer.shared.submit(
                payload.pixelBuffer,
                presentationTime: payload.presentationTime,
                hostTime: payload.hostTime,
                frameRate: payload.renderContract.frameRate
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

#if canImport(CoreVideo)
/// Keeps the record-only 16:9 file at a constant rate on the shared clock. Real frames pass
/// straight through; when none arrives for 1.15 frame periods the last one is repeated one
/// period after the previous stamp. A composite that lands less than half a period after the last
/// frame is held and goes out in the next slot, so late frames and bursts never add frames to the file.
/// Video only: audio keeps its own pump and clock.
final class RecordOnlyFramePacer: @unchecked Sendable {
    static let shared = RecordOnlyFramePacer()

    /// (pixel buffer, presentation seconds on the bus clock, host time)
    var emit: ((CVPixelBuffer, TimeInterval, CMTime) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return emitHandler }
        set { lock.lock(); emitHandler = newValue; lock.unlock() }
    }

    private let queue = DispatchQueue(label: "com.proshow.record.pacer", qos: .userInteractive)
    private let lock = NSLock()
    private var emitHandler: ((CVPixelBuffer, TimeInterval, CMTime) -> Void)?
    private var timer: DispatchSourceTimer?
    private var period: TimeInterval = 1.0 / 30.0
    private var lastBuffer: CVPixelBuffer?
    private var lastStamp: TimeInterval = 0
    private var lastRealAt: TimeInterval = 0
    /// A real frame that landed within half a period of the last one; it goes out in the next slot.
    private var pendingReal = false
    private(set) var repeatedFrames: Int = 0
    /// Stop repeating after this long without a real frame (recording ended or the app is stuck).
    private let staleAfter: TimeInterval = 10

    func submit(_ buffer: CVPixelBuffer, presentationTime: TimeInterval, hostTime: CMTime, frameRate: Int) {
        lock.lock()
        let fps = max(1, min(60, frameRate))
        let wantPeriod = 1.0 / Double(fps)
        if timer == nil || abs(wantPeriod - period) > 0.0001 {
            startTimerLocked(period: wantPeriod)
        }
        if lastStamp > 0, presentationTime <= lastStamp + period * 0.55 {
            // This slot is already filled (a repeat, or a burst of late composites): the newest
            // frame goes out in the next slot and older ones in the burst are skipped.
            lastBuffer = buffer
            pendingReal = true
            lastRealAt = Date().timeIntervalSinceReferenceDate
            lock.unlock()
            return
        }
        let stamp = presentationTime
        let host = hostTime.isValid && hostTime.isNumeric ? hostTime : .invalid
        lastBuffer = buffer
        lastStamp = stamp
        pendingReal = false
        lastRealAt = Date().timeIntervalSinceReferenceDate
        // Emit under the lock so a repeat and a real frame never reach the writer out of order.
        emitHandler?(buffer, stamp, host)
        lock.unlock()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard timer != nil || lastBuffer != nil else { return }
        timer?.cancel()
        timer = nil
        lastBuffer = nil
        lastStamp = 0
        lastRealAt = 0
        pendingReal = false
    }

    private func startTimerLocked(period newPeriod: TimeInterval) {
        timer?.cancel()
        period = newPeriod
        let source = DispatchSource.makeTimerSource(queue: queue)
        // Check 8 times a frame so a repeat lands within a few ms of the missed slot.
        let check = newPeriod / 8
        source.schedule(deadline: .now() + check, repeating: check, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        lock.lock()
        let now = Date().timeIntervalSinceReferenceDate
        guard let buffer = lastBuffer, lastStamp > 0 else { lock.unlock(); return }
        if now - lastRealAt > staleAfter {
            lock.unlock()
            stop()
            return
        }
        guard now - lastStamp >= period * (pendingReal ? 1.0 : 1.15) else { lock.unlock(); return }
        // One period after the last frame; after a long stall, catch up to now.
        let stamp = now - lastStamp > period * 3 ? now : lastStamp + period
        lastStamp = stamp
        if pendingReal {
            pendingReal = false
        } else {
            repeatedFrames += 1
        }
        let host = Self.host(CMClockGetTime(CMClockGetHostTimeClock()), shiftedBy: stamp - now)
        emitHandler?(buffer, stamp, host)
        lock.unlock()
    }

    private static func host(_ time: CMTime, shiftedBy seconds: TimeInterval) -> CMTime {
        guard time.isValid, time.isNumeric else { return .invalid }
        guard abs(seconds) > 0.000_001 else { return time }
        return CMTimeAdd(time, CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}
#endif
