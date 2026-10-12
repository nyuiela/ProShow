import Foundation

/// Tears down hardware PCM taps that no longer map to a visible / live layer binding.
@MainActor
enum AudioMatrixReconciler {
    static func reconcile(controller: ShowController) {
        let audioKeys = requiredAudioLaneKeys(controller: controller)
        let videoKeys = requiredVideoLaneKeys(controller: controller)
        let keepCaptureGraph = controller.streaming.isLive || controller.isoRecorder.isRecording
        controller.videoInputs.ingest.reconcileCapture(
            audioLaneKeys: audioKeys,
            videoLaneKeys: videoKeys,
            preserveLiveAudio: keepCaptureGraph
        )
        if !keepCaptureGraph {
            flushUnusedCaptureRoles(controller: controller, audioKeys: audioKeys)
        }
        let micLive = audioKeys.contains { $0.hasPrefix("avf://") || $0.hasPrefix("audio:") }
        let desktopLive = audioKeys.contains { $0.hasPrefix("sck://") }
        if micLive {
            ProgramStreamAudioGates.setHardwareCaptureOpen(.microphone, open: true)
        }
        if desktopLive {
            ProgramStreamAudioGates.setHardwareCaptureOpen(.desktop, open: true)
        }
        ProgramStreamAudioGates.setHardwareCaptureOpen(.slide, open: true)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.soundboard, open: true)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.guest, open: true)
        ProgramPCMBridge.clearMonitorRing()
        AudioMonitoringEngine.shared.resetPeaks()
        controller.audioIO.injectPeak(role: .microphone, db: micLive ? controller.audioIO.lastPeaks[.microphone] ?? -120 : -120)
        controller.audioIO.injectPeak(role: .desktop, db: desktopLive ? controller.audioIO.lastPeaks[.desktop] ?? -120 : -120)
    }

    static func purgeAllPCMQueues() {
        ProgramAACEncoder.flush(role: .microphone)
        ProgramAACEncoder.flush(role: .desktop)
        ProgramAACEncoder.flush(role: .guest)
        ProgramAACEncoder.flush(role: .slide)
        ProgramAACEncoder.flush(role: .soundboard)
    }

    private static func requiredAudioLaneKeys(controller: ShowController) -> Set<String> {
        // Keep hardware lanes alive whenever video is live; layer/shot mute is applied in the audio matrix only.
        requiredVideoLaneKeys(controller: controller)
    }

    private static func requiredVideoLaneKeys(controller: ShowController) -> Set<String> {
        var keys = Set<String>()
        let stack = controller.compositor.stack
        if stack.isVisible(.videoInput, onStage: false), let input = stack.videoInput {
            adoptVideoInput(input, into: &keys)
        }
        if let pip = stack.pipInput, !stack.isCleared(.videoInput) {
            adoptVideoInput(pip, into: &keys)
        }
        for layer in controller.masterLayers {
            guard let liveID = layer.liveShotID,
                  let shot = layer.shots.first(where: { $0.id == liveID })
            else { continue }
            switch shot.source.sourceType {
            case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .srtStream, .webPage:
                adoptDiscoveredSource(shot.source, into: &keys)
            default:
                break
            }
        }
        return keys
    }

    private static func adoptVideoInput(_ input: VideoInputSource, into keys: inout Set<String>) {
        if let endpoint = input.endpoint, !endpoint.isEmpty {
            keys.insert(endpoint)
        }
        keys.insert(input.id.uuidString)
    }

    private static func adoptDiscoveredSource(_ source: DiscoveredSourceItem, into keys: inout Set<String>) {
        if let endpoint = source.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines), !endpoint.isEmpty {
            switch source.sourceType {
            case .systemMicrophone:
                keys.insert(VideoIngestEngine.dedicatedAudioLaneKey(endpoint: endpoint))
                keys.insert(endpoint)
            default:
                keys.insert(endpoint)
            }
        }
        if let id = UUID(uuidString: source.id) {
            keys.insert(id.uuidString)
        }
    }

    private static func flushUnusedCaptureRoles(controller: ShowController, audioKeys: Set<String>) {
        let micLive = audioKeys.contains { $0.hasPrefix("avf://") || $0.hasPrefix("audio:") }
        let desktopLive = audioKeys.contains { $0.hasPrefix("sck://") }
        if !micLive {
            ProgramStreamAudioGates.flushCaptureRole(.microphone)
        }
        if !desktopLive {
            ProgramStreamAudioGates.flushCaptureRole(.desktop)
        }
        if !controller.videoInputs.activeHardwareMicrophoneCapture {
            controller.audioIO.stopCapture()
        }
    }
}
