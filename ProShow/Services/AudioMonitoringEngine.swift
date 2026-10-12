import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreAudio)
import CoreAudio
#endif

/// Operator headphone / speaker monitoring policy for the right pane.
@MainActor
@Observable
final class AudioMonitoringEngine {
    static let shared = AudioMonitoringEngine()

    private enum Storage {
        static let localSpeakerMuted = "proshow.desk.localSpeakerMuted"
        static let outputDeviceUID = "proshow.desk.preferredOutputDeviceUID"
    }

    enum MonitorMode: String, Sendable {
        case programMix
        case localPreview
    }

    var monitorMode: MonitorMode = .programMix
    var monitorVolume: Float = 1
    /// Mutes this Mac's speakers / headphones only — stream and ISO encode are unchanged.
    var localSpeakerMuted: Bool {
        didSet {
            UserDefaults.standard.set(localSpeakerMuted, forKey: Storage.localSpeakerMuted)
            notifyLocalOutputPolicyChanged()
        }
    }
    /// `nil` = system default output device.
    var preferredOutputDeviceUID: String? {
        didSet {
            if let preferredOutputDeviceUID {
                UserDefaults.standard.set(preferredOutputDeviceUID, forKey: Storage.outputDeviceUID)
            } else {
                UserDefaults.standard.removeObject(forKey: Storage.outputDeviceUID)
            }
            notifyLocalOutputPolicyChanged()
        }
    }
    private(set) var leftPeakDb: Double = -120
    private(set) var rightPeakDb: Double = -120

    var localSpeakerScalar: Float { localSpeakerMuted ? 0 : 1 }

    var effectiveMonitorVolume: Float { monitorVolume * localSpeakerScalar }

    private init() {
        localSpeakerMuted = UserDefaults.standard.bool(forKey: Storage.localSpeakerMuted)
        preferredOutputDeviceUID = UserDefaults.standard.string(forKey: Storage.outputDeviceUID)
    }

    func toggleLocalSpeakerMuted() {
        localSpeakerMuted.toggle()
    }

    func selectOutputDevice(uid: String?) {
        preferredOutputDeviceUID = uid?.isEmpty == true ? nil : uid
    }

    func outputDeviceLabel(for uid: String?) -> String {
        guard let uid else { return "System Default" }
        return MacAudioOutputRouting.deviceName(forUID: uid) ?? "Output"
    }

    private func notifyLocalOutputPolicyChanged() {
        ProgramAudioMonitorBridge.shared.refreshOutputRouting()
        PreviewCueMonitor.shared.refreshOutputRouting()
    }

    func noteProgramMixFrame(_ interleavedStereo: [Float]) {
        guard monitorMode == .programMix, !interleavedStereo.isEmpty else { return }
        var peakL: Float = 0
        var peakR: Float = 0
        var index = 0
        while index + 1 < interleavedStereo.count {
            peakL = max(peakL, abs(interleavedStereo[index]))
            peakR = max(peakR, abs(interleavedStereo[index + 1]))
            index += 2
        }
        leftPeakDb = AudioDSP.db(from: Double(peakL))
        rightPeakDb = AudioDSP.db(from: Double(peakR))
    }

    func resetPeaks() {
        leftPeakDb = -120
        rightPeakDb = -120
    }
}

#if canImport(CoreAudio)
/// Lists built-in / USB / HDMI outputs and routes `AVAudioEngine` to the desk selection.
enum MacAudioOutputRouting {
    static func outputDevices() -> [StudioAudioDevice] {
        let ids = systemDeviceIDs()
        var devices: [StudioAudioDevice] = []
        for id in ids where deviceHasOutput(id) {
            guard let uid = deviceUID(id), let name = deviceName(id) else { continue }
            devices.append(StudioAudioDevice(id: uid, name: name, endpoint: "coreaudio://\(uid)"))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func deviceName(forUID uid: String) -> String? {
        deviceID(forUID: uid).flatMap { deviceName($0) }
    }

    @discardableResult
    static func applyPreferredDevice(to engine: AVAudioEngine, uid: String?) -> Bool {
        guard let uid, !uid.isEmpty else { return true }
        guard let deviceID = deviceID(forUID: uid) else { return false }
        var id = deviceID
        let unit = engine.outputNode.audioUnit!
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        return status == noErr
    }

    private static func systemDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func deviceHasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        copyStringProperty(id: id, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        copyStringProperty(id: id, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func copyStringProperty(id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged) == noErr,
              let unmanaged
        else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        for id in systemDeviceIDs() {
            if deviceUID(id)?.caseInsensitiveCompare(uid) == .orderedSame {
                return id
            }
        }
        return nil
    }
}
#else
enum MacAudioOutputRouting {
    static func outputDevices() -> [StudioAudioDevice] { [] }
    static func deviceName(forUID uid: String) -> String? { nil }
    #if canImport(AVFoundation)
    static func applyPreferredDevice(to engine: AVAudioEngine, uid: String?) -> Bool { true }
    #endif
}
#endif

/// Local playback of the preview cue. Never enters the program mix or the encoder.
@MainActor
@Observable
final class PreviewCueMonitor {
    static let shared = PreviewCueMonitor()

    var headsetOn = true
    private(set) var leftPeakDb: Double = -120
    private(set) var rightPeakDb: Double = -120
    /// The current cue has a file with audio the operator can audition.
    private(set) var hasCueAudio = false

    #if canImport(AVFoundation)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var loadedURL: URL?
    private let peaks = PreviewCuePeakRelay()
    #endif

    private init() {}

    func toggleHeadset() {
        headsetOn.toggle()
        applyHeadsetGain()
    }

    func play(url: URL?) {
        #if canImport(AVFoundation)
        guard let url else {
            stop()
            return
        }
        if loadedURL == url, engine?.isRunning == true {
            applyHeadsetGain()
            if player?.isPlaying != true {
                player?.play()
            }
            hasCueAudio = true
            return
        }
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            let graph = AVAudioEngine()
            let node = AVAudioPlayerNode()
            graph.attach(node)
            graph.connect(node, to: graph.mainMixerNode, format: file.processingFormat)
            _ = MacAudioOutputRouting.applyPreferredDevice(
                to: graph,
                uid: AudioMonitoringEngine.shared.preferredOutputDeviceUID
            )
            let relay = peaks
            node.installTap(onBus: 0, bufferSize: 1024, format: file.processingFormat) { buffer, _ in
                relay.publish(buffer)
            }
            node.scheduleFile(file, at: nil)
            try graph.start()
            engine = graph
            player = node
            loadedURL = url
            hasCueAudio = true
            applyHeadsetGain()
            node.play()
        } catch {
            hasCueAudio = false
            leftPeakDb = -120
            rightPeakDb = -120
        }
        #else
        hasCueAudio = false
        leftPeakDb = -120
        rightPeakDb = -120
        #endif
    }

    func stop() {
        #if canImport(AVFoundation)
        player?.removeTap(onBus: 0)
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        loadedURL = nil
        #endif
        hasCueAudio = false
        leftPeakDb = -120
        rightPeakDb = -120
    }

    func refreshOutputRouting() {
        #if canImport(AVFoundation)
        guard let engine else { return }
        let wasPlaying = player?.isPlaying == true
        engine.pause()
        _ = MacAudioOutputRouting.applyPreferredDevice(
            to: engine,
            uid: AudioMonitoringEngine.shared.preferredOutputDeviceUID
        )
        try? engine.start()
        if wasPlaying {
            player?.play()
        }
        applyHeadsetGain()
        #endif
    }

    fileprivate func applyPublishedPeaks(left: Double, right: Double) {
        leftPeakDb = left
        rightPeakDb = right
    }

    private func applyHeadsetGain() {
        #if canImport(AVFoundation)
        engine?.mainMixerNode.outputVolume = headsetOn ? 1 : 0
        #endif
    }
}

#if canImport(AVFoundation)
private final class PreviewCuePeakRelay: @unchecked Sendable {
    private var lastPublish: CFAbsoluteTime = 0

    func publish(_ buffer: AVAudioPCMBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPublish >= 0.05 else { return }
        lastPublish = now
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        func peak(_ index: Int) -> Double {
            guard index < channelCount else { return -120 }
            var value: Float = 0
            let samples = channels[index]
            for frame in 0..<frames {
                value = max(value, abs(samples[frame]))
            }
            guard value > 0.000_01 else { return -120 }
            return 20 * log10(Double(value))
        }
        let left = peak(0)
        let right = channelCount > 1 ? peak(1) : left
        Task { @MainActor in
            PreviewCueMonitor.shared.applyPublishedPeaks(left: left, right: right)
        }
    }
}
#endif
