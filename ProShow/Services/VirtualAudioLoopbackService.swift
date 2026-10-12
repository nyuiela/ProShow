import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Routes the program mix to a dedicated loopback device for Zoom / Meet (`ProShow Virtual Audio`).
@MainActor
@Observable
final class VirtualAudioLoopbackService {
    static let deviceName = "ProShow Virtual Audio"

    var isPublishing = false
    var lastError: String?
    /// When no kernel driver is installed, meetings can still use BlackHole / Loopback as a manual route.
    var driverInstalled: Bool { installedDriverHint }

    private var installedDriverHint = false
    #if canImport(AVFoundation)
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    #endif

    func refreshDriverPresence() {
        #if os(macOS)
        installedDriverHint = Self.discoverVirtualDevice() != nil
        #else
        installedDriverHint = false
        #endif
    }

    func setPublishing(_ enabled: Bool) {
        isPublishing = enabled
        guard enabled else {
            stopEngine()
            return
        }
        refreshDriverPresence()
        guard installedDriverHint else {
            stopEngine()
            lastError = "Install the ProShow Virtual Audio driver or route program audio manually (e.g. BlackHole)."
            return
        }
        #if canImport(AVFoundation)
        startEngine()
        #else
        lastError = "Virtual audio requires AVFoundation."
        #endif
    }

    static func discoverVirtualDevice() -> String? {
        if ProcessInfo.processInfo.environment["PROSHOW_VIRTUAL_AUDIO_DRIVER"] == "1" {
            return deviceName
        }
        return nil
    }

    #if canImport(AVFoundation)
    private func startEngine() {
        stopEngine()
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            let stereo = ProgramPCMBridge.consumeInterleavedStereo(frameCount: frames)
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if abl.count >= 2,
               let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let right = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames {
                    let base = frame * 2
                    left[frame] = base < stereo.count ? stereo[base] : 0
                    right[frame] = base + 1 < stereo.count ? stereo[base + 1] : 0
                }
            } else if let buffer = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<frames {
                    let base = frame * 2
                    let mono = base < stereo.count ? stereo[base] : 0
                    buffer[frame] = mono
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
            tapInstalled = true
            lastError = installedDriverHint ? nil : "Install the ProShow Virtual Audio driver or route manually."
        } catch {
            lastError = error.localizedDescription
            self.engine = nil
        }
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        tapInstalled = false
    }
    #endif
}
