import Foundation

/// Wirecast-style streaming quality presets for RTMP / platform live.
public struct StreamEncoderConfig: Codable, Equatable, Sendable {
    public var presetName: String
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var targetBitrateBps: Int
    public var maxBitrateCeilingBps: Int
    public var keyframeIntervalSeconds: Double
    public var audioBitrateBps: Int
    public var useHardwareEncoder: Bool
    public var customBitrateOverrideEnabled: Bool

    public init(
        presetName: String = StreamEncoderPreset.standard1080p30.rawValue,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 30,
        targetBitrateBps: Int = 4_500_000,
        maxBitrateCeilingBps: Int = 5_400_000,
        keyframeIntervalSeconds: Double = 2.0,
        audioBitrateBps: Int = 160_000,
        useHardwareEncoder: Bool = true,
        customBitrateOverrideEnabled: Bool = false
    ) {
        self.presetName = presetName
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.targetBitrateBps = targetBitrateBps
        self.maxBitrateCeilingBps = maxBitrateCeilingBps
        self.keyframeIntervalSeconds = keyframeIntervalSeconds
        self.audioBitrateBps = audioBitrateBps
        self.useHardwareEncoder = useHardwareEncoder
        self.customBitrateOverrideEnabled = customBitrateOverrideEnabled
    }

    public var targetBitrateKbps: Int { max(1, targetBitrateBps / 1000) }
    public var maxBitrateCeilingKbps: Int { max(1, maxBitrateCeilingBps / 1000) }
    public var audioBitrateKbps: Int { max(32, audioBitrateBps / 1000) }

    public var usesHighProfile: Bool { height >= 720 }

    public mutating func applyPreset(_ preset: StreamEncoderPreset) {
        let template = preset.config
        presetName = template.presetName
        width = template.width
        height = template.height
        frameRate = template.frameRate
        targetBitrateBps = template.targetBitrateBps
        maxBitrateCeilingBps = template.maxBitrateCeilingBps
        keyframeIntervalSeconds = template.keyframeIntervalSeconds
        audioBitrateBps = template.audioBitrateBps
        useHardwareEncoder = template.useHardwareEncoder
        if !customBitrateOverrideEnabled {
            customBitrateOverrideEnabled = false
        }
    }

    public mutating func applyCustomTargetKbps(_ target: Int, ceiling: Int) {
        customBitrateOverrideEnabled = true
        presetName = StreamEncoderPreset.custom.rawValue
        targetBitrateBps = max(400_000, target * 1000)
        maxBitrateCeilingBps = max(targetBitrateBps, ceiling * 1000)
    }

    func apply(to config: inout RtmpStreamConfig) {
        config.width = width
        config.height = height
        config.framerate = frameRate
        config.bitrateKbps = targetBitrateKbps
        config.keyframeIntervalSec = max(1, Int(keyframeIntervalSeconds.rounded()))
        config.audioBitrateKbps = audioBitrateKbps
        config.codec = "H264"
        config.audioCodec = "AAC"
    }

    func programEncoderSettings() -> ProgramEncoderSettings {
        ProgramEncoderSettings(
            codec: "H264",
            width: width,
            height: height,
            framerate: frameRate,
            bitrateKbps: targetBitrateKbps,
            keyframeIntervalSec: max(1, Int(keyframeIntervalSeconds.rounded())),
            keyframeIntervalFrames: max(1, frameRate) * max(1, Int(keyframeIntervalSeconds.rounded())),
            audioCodec: "AAC",
            audioBitrateKbps: audioBitrateKbps,
            frameInterval: 1.0 / Double(max(1, frameRate))
        )
    }

    public static func preset720p30Saver() -> StreamEncoderConfig {
        StreamEncoderPreset.saver720p30.config
    }

    /// Lowers video, ceiling, and audio to the strictest selected ingest. Resolution stays on the preset.
    public func clamped(to policies: [PlatformIngestPolicy]) -> StreamEncoderConfig {
        guard !policies.isEmpty else { return self }
        var next = self
        if let maxTarget = policies.map(\.maxTargetBitrateBps).min(), next.targetBitrateBps > maxTarget {
            next.targetBitrateBps = maxTarget
        }
        if let maxCeiling = policies.map(\.maxCeilingBitrateBps).min() {
            next.maxBitrateCeilingBps = min(next.maxBitrateCeilingBps, max(next.targetBitrateBps, maxCeiling))
        }
        if next.maxBitrateCeilingBps < next.targetBitrateBps {
            next.maxBitrateCeilingBps = next.targetBitrateBps
        }
        if let audioCap = policies.compactMap(\.maxAudioBitrateBps).min(), next.audioBitrateBps > audioCap {
            next.audioBitrateBps = audioCap
        }
        if policies.contains(where: \.requiresTwoSecondKeyframe) {
            next.keyframeIntervalSeconds = 2
        }
        return next
    }
}

public enum StreamEncoderPreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case ultra4k30 = "4K30 Ultra HD"
    case high1080p60 = "1080p60 High"
    case standard1080p30 = "1080p30 Standard"
    case smooth720p60 = "720p60 Smooth"
    case saver720p30 = "720p30 Saver"
    case fallback480p30 = "480p30 Fallback"
    case custom = "Custom Profile"

    public var id: String { rawValue }

    public var menuTitle: String {
        switch self {
        case .ultra4k30: "4K30 Ultra HD (15 Mbps)"
        case .high1080p60: "1080p60 High (6.0 Mbps)"
        case .standard1080p30: "1080p30 Standard (4.5 Mbps) — Recommended"
        case .smooth720p60: "720p60 Smooth (4.0 Mbps)"
        case .saver720p30: "720p30 Saver (2.5 Mbps)"
        case .fallback480p30: "480p30 Fallback (1.2 Mbps)"
        case .custom: "Custom Profile"
        }
    }

    public var idealUseCase: String {
        switch self {
        case .ultra4k30: "YouTube Live, premium broadcasts"
        case .high1080p60: "High-motion video, gaming, fast action"
        case .standard1080p30: "Worship, presentations, keynotes"
        case .smooth720p60: "Mid-range bandwidth with smooth motion"
        case .saver720p30: "Limited upload bandwidth and mobile networks"
        case .fallback480p30: "Emergency low-bandwidth stream"
        case .custom: "Manual target and ceiling"
        }
    }

    public var config: StreamEncoderConfig {
        switch self {
        case .ultra4k30:
            StreamEncoderConfig(
                presetName: rawValue,
                width: 3840, height: 2160, frameRate: 30,
                targetBitrateBps: 15_000_000, maxBitrateCeilingBps: 18_000_000,
                keyframeIntervalSeconds: 2,
                audioBitrateBps: 256_000
            )
        case .high1080p60:
            StreamEncoderConfig(
                presetName: rawValue,
                width: 1920, height: 1080, frameRate: 60,
                targetBitrateBps: 6_000_000, maxBitrateCeilingBps: 7_200_000,
                keyframeIntervalSeconds: 2,
                audioBitrateBps: 192_000
            )
        case .standard1080p30:
            StreamEncoderConfig(
                presetName: rawValue,
                width: 1920, height: 1080, frameRate: 30,
                targetBitrateBps: 4_500_000, maxBitrateCeilingBps: 5_400_000,
                keyframeIntervalSeconds: 2,
                audioBitrateBps: 160_000
            )
        case .smooth720p60:
            StreamEncoderConfig(
                presetName: rawValue,
                width: 1280, height: 720, frameRate: 60,
                targetBitrateBps: 4_000_000, maxBitrateCeilingBps: 4_800_000,
                keyframeIntervalSeconds: 2,
                audioBitrateBps: 128_000
            )
        case .saver720p30:
            StreamEncoderConfig(
                presetName: rawValue,
                width: 1280, height: 720, frameRate: 30,
                targetBitrateBps: 2_500_000, maxBitrateCeilingBps: 3_000_000,
                keyframeIntervalSeconds: 2,
                audioBitrateBps: 128_000
            )
        case .fallback480p30:
            StreamEncoderConfig(
                presetName: rawValue,
                width: 854, height: 480, frameRate: 30,
                targetBitrateBps: 1_200_000, maxBitrateCeilingBps: 1_500_000,
                keyframeIntervalSeconds: 2,
                audioBitrateBps: 96_000
            )
        case .custom:
            StreamEncoderConfig(presetName: rawValue, customBitrateOverrideEnabled: true)
        }
    }

    public static func named(_ name: String) -> StreamEncoderPreset? {
        if let preset = StreamEncoderPreset(rawValue: name) { return preset }
        if name == "480p30 Low-BW" { return .fallback480p30 }
        return nil
    }
}

/// Ingest ceilings for one shared H.264 encode. The strictest selected destination wins.
public struct PlatformIngestPolicy: Equatable, Sendable {
    public var name: String
    public var maxTargetBitrateBps: Int
    public var maxCeilingBitrateBps: Int
    public var requiresTwoSecondKeyframe: Bool
    public var maxAudioBitrateBps: Int?

    public static let youtube = PlatformIngestPolicy(
        name: "YouTube",
        maxTargetBitrateBps: 30_000_000,
        maxCeilingBitrateBps: 30_000_000,
        requiresTwoSecondKeyframe: false,
        maxAudioBitrateBps: nil
    )

    public static let twitch = PlatformIngestPolicy(
        name: "Twitch",
        maxTargetBitrateBps: 6_000_000,
        maxCeilingBitrateBps: 6_000_000,
        requiresTwoSecondKeyframe: true,
        maxAudioBitrateBps: nil
    )

    public static let facebook = PlatformIngestPolicy(
        name: "Facebook",
        maxTargetBitrateBps: 6_000_000,
        maxCeilingBitrateBps: 6_000_000,
        requiresTwoSecondKeyframe: true,
        maxAudioBitrateBps: 128_000
    )

    public static let kick = PlatformIngestPolicy(
        name: "Kick",
        maxTargetBitrateBps: 8_000_000,
        maxCeilingBitrateBps: 8_000_000,
        requiresTwoSecondKeyframe: true,
        maxAudioBitrateBps: nil
    )

    static func detect(platform: StreamPlatform, ingestURL: String) -> PlatformIngestPolicy? {
        switch platform {
        case .youtube: return .youtube
        case .facebook: return .facebook
        default: break
        }
        let url = ingestURL.lowercased()
        if url.contains("youtu") { return .youtube }
        if url.contains("facebook") || url.contains("fbcdn") { return .facebook }
        if url.contains("twitch") { return .twitch }
        if url.contains("kick.com") || url.contains("kick.tv") { return .kick }
        return nil
    }

    static func policies(for accounts: [StreamAccount]) -> [PlatformIngestPolicy] {
        var seen: Set<String> = []
        var result: [PlatformIngestPolicy] = []
        for account in accounts {
            guard let policy = detect(platform: account.platform, ingestURL: account.rtmpUrl),
                  seen.insert(policy.name).inserted else { continue }
            result.append(policy)
        }
        return result
    }
}

public enum EncoderPresetStore {
    public static let userDefaultsKey = "proshow.settings.streamConfig"

    public static func load() -> StreamEncoderConfig {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode(StreamEncoderConfig.self, from: data) {
            return decoded
        }
        return CaptureBudget.prefersCompactOutput()
            ? StreamEncoderPreset.saver720p30.config
            : StreamEncoderPreset.standard1080p30.config
    }

    public static func save(_ config: StreamEncoderConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    @MainActor
    static func apply(_ config: StreamEncoderConfig, to engine: StreamingEngine) {
        engine.applyStreamEncoderConfig(config)
    }
}
