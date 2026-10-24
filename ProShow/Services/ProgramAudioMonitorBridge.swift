import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Plays the same interleaved PCM queued for AAC encode (`ProgramPCMBridge` monitor ring).
@MainActor
@Observable
final class ProgramAudioMonitorBridge {
    static let shared = ProgramAudioMonitorBridge()

    private(set) var isRunning = false
    /// Read on the render thread instead of the main-actor monitor engine (a plain Float store).
    nonisolated(unsafe) static var renderVolume: Float = 1

    #if canImport(AVFoundation)
    private var engine: AVAudioEngine?
    #endif

    private init() {}

    func setActive(_ active: Bool) {
        PreviewProgramAudioPump.setMonitorWantsPump(active)
        #if canImport(AVFoundation)
        if active {
            startIfNeeded()
        } else {
            stop()
        }
        #else
        isRunning = false
        #endif
    }

    #if canImport(AVFoundation)
    private func startIfNeeded() {
        guard AudioMonitoringEngine.shared.monitorMode == .programMix else {
            stop()
            return
        }
        guard engine == nil else {
            isRunning = true
            return
        }
        let graph = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            let stereo = ProgramPCMBridge.consumeInterleavedStereo(frameCount: frames)
            let volume = ProgramAudioMonitorBridge.renderVolume
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if abl.count >= 2,
               let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let right = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames {
                    let base = frame * 2
                    left[frame] = (base < stereo.count ? stereo[base] : 0) * volume
                    right[frame] = (base + 1 < stereo.count ? stereo[base + 1] : 0) * volume
                }
            } else if let buffer = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames {
                    let base = frame * 2
                    buffer[frame] = (base < stereo.count ? stereo[base] : 0) * volume
                }
            }
            return noErr
        }
        graph.attach(source)
        graph.connect(source, to: graph.mainMixerNode, format: format)
        _ = MacAudioOutputRouting.applyPreferredDevice(
            to: graph,
            uid: AudioMonitoringEngine.shared.activeOutputDeviceUID
        )
        do {
            try graph.start()
            engine = graph
            isRunning = true
        } catch {
            engine = nil
            isRunning = false
        }
    }

    private func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
    }

    /// Re-apply output device after title-bar changes (no-op when monitor is off).
    func refreshOutputRouting() {
        guard let engine else { return }
        engine.pause()
        _ = MacAudioOutputRouting.applyPreferredDevice(
            to: engine,
            uid: AudioMonitoringEngine.shared.activeOutputDeviceUID
        )
        try? engine.start()
    }
    #endif
}
