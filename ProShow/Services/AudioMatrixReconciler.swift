import Foundation

/// Which hardware audio roles may reach the program mix, derived only from what is live now.
/// Privacy rule: the microphone is heard only while a live layer shot is an explicit,
/// unmuted microphone source. A camera is picture only; it never opens the mic.
struct ProgramAudioGatePolicy: Equatable, Sendable {
    var microphone: Bool
    var desktop: Bool

    /// `cameraHasMic`: a live camera shot with its audio on feeds the mic lane from its own mic.
    static func derive(
        from layers: [MasterLayer],
        cameraHasMic: (LayerShot) -> Bool = { _ in false }
    ) -> ProgramAudioGatePolicy {
        var mic = false
        var desktop = false
        for layer in layers {
            guard let liveID = layer.liveShotID,
                  let shot = layer.shots.first(where: { $0.id == liveID }),
                  !shot.isAudioMuted
            else { continue }
            switch shot.source.sourceType {
            case .systemMicrophone:
                mic = true
            case .systemDisplay, .systemWindow, .systemAudioCapture:
                desktop = true
            case .systemCamera:
                if cameraHasMic(shot) { mic = true }
            default:
                break
            }
        }
        return ProgramAudioGatePolicy(microphone: mic, desktop: desktop)
    }
}

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
        let gates = enforceProgramAudioGates(controller: controller)
        let micLive = gates.microphone
        let desktopLive = gates.desktop
        ProgramStreamAudioGates.setHardwareCaptureOpen(.slide, open: true)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.soundboard, open: true)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.guest, open: true)
        ProgramPCMBridge.clearMonitorRing()
        AudioMonitoringEngine.shared.resetPeaks()
        controller.audioIO.injectPeak(role: .microphone, db: micLive ? controller.audioIO.lastPeaks[.microphone] ?? -120 : -120)
        controller.audioIO.injectPeak(role: .desktop, db: desktopLive ? controller.audioIO.lastPeaks[.desktop] ?? -120 : -120)
    }

    private static var lastGates: ProgramAudioGatePolicy?
    private static var lastMicEndpoints: [String] = []

    /// Hard gate from the live program layers. Runs on every reconcile and every program tick,
    /// so a stale open gate (streaming, lifetime mic session, missed layer event) cannot leak audio.
    @discardableResult
    static func enforceProgramAudioGates(controller: ShowController) -> ProgramAudioGatePolicy {
        let gates = controller.programAudioGates()
        let previous = lastGates
        lastGates = gates
        let micEndpoints = gates.microphone
            ? controller.programMicrophoneShots().map { $0.source.connectionString ?? "" }
            : []
        let micChanged = micEndpoints != lastMicEndpoints
        lastMicEndpoints = micEndpoints
        // Always re-assert: other paths open these gates directly, so a cached
        // "nothing changed" would let a stale open gate survive.
        ProgramStreamAudioGates.setHardwareCaptureOpen(.microphone, open: gates.microphone)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.desktop, open: gates.desktop)
        if gates.microphone, previous?.microphone != true || micChanged {
            // Also on a handover (camera A to camera B, camera to mic shot): open the new owner.
            // Reopened (unmute, new take, relaunch): restart capture that a close or reconcile stopped.
            controller.resumeLiveMicrophoneCapture()
        }
        if previous?.microphone != false, !gates.microphone {
            ProgramStreamAudioGates.flushCaptureRole(.microphone)
            controller.audioIO.injectPeak(role: .microphone, db: -120)
        }
        if previous?.desktop != false, !gates.desktop {
            ProgramStreamAudioGates.flushCaptureRole(.desktop)
        }
        return gates
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
            case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .srtStream, .webPage,
                 .systemMicrophone, .systemAudioCapture:
                adoptDiscoveredSource(shot.source, into: &keys)
            default:
                break
            }
        }
        // A camera's own mic lane (only when it is the program mic).
        for mic in controller.programMicrophoneShots() {
            adoptDiscoveredSource(mic.source, into: &keys)
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
