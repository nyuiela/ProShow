import Foundation

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
                frameRate: 20,
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
