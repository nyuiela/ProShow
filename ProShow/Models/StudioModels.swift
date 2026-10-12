import Foundation

enum StudioVideoKind: String, Hashable, Codable, Sendable {
    case camera, continuity, captureCard, screenShare, ndi, webrtc, rtsp

    init(videoInput kind: VideoInputKind) {
        switch kind {
        case .camera: self = .camera
        case .continuity: self = .continuity
        case .captureCard: self = .captureCard
        case .screenShare: self = .screenShare
        case .ndi: self = .ndi
        case .webrtc: self = .webrtc
        case .rtsp: self = .rtsp
        }
    }

    var videoInputKind: VideoInputKind {
        switch self {
        case .camera: .camera
        case .continuity: .continuity
        case .captureCard: .captureCard
        case .screenShare: .screenShare
        case .ndi: .ndi
        case .webrtc: .webrtc
        case .rtsp: .rtsp
        }
    }
}

enum SceneLayoutKind: String, Hashable, Codable, Sendable {
    case soloPresenter
    case presenterPlusDeck
    case interviewSplit
    case screenShareMic
}

struct CanvasRect: Hashable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let fullFrame = CanvasRect(x: 0, y: 0, width: CanvasConfig.width, height: CanvasConfig.height)
    static let pipLowerRight = CanvasRect(x: 2880, y: 1540, width: 840, height: 480)
    static let leftHalf = CanvasRect(x: 0, y: 0, width: 1920, height: CanvasConfig.height)
    static let rightHalf = CanvasRect(x: 1920, y: 0, width: 1920, height: CanvasConfig.height)
}

struct StudioVideoSource: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var label: String
    var kind: StudioVideoKind
    var endpoint: String?
    var enabled: Bool
    var chromaEnabled: Bool

    init(
        id: UUID = UUID(),
        label: String,
        kind: StudioVideoKind,
        endpoint: String? = nil,
        enabled: Bool = true,
        chromaEnabled: Bool = false
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.endpoint = endpoint
        self.enabled = enabled
        self.chromaEnabled = chromaEnabled
    }

    var inputSource: VideoInputSource {
        let mapped: VideoInputKind
        switch kind {
        case .camera: mapped = .camera
        case .continuity: mapped = .continuity
        case .captureCard: mapped = .captureCard
        case .ndi: mapped = .ndi
        case .rtsp: mapped = .rtsp
        case .webrtc: mapped = .webrtc
        case .screenShare: mapped = .screenShare
        }
        return VideoInputSource(id: id, label: label, kind: mapped, endpoint: endpoint)
    }

    /// Seed placeholders have a kind but no device. Opening hardware for those
    /// falls through to the default camera and CMIO logs "System is exiting".
    var hasBindableHardwareEndpoint: Bool {
        if kind == .ndi {
            let address = endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !address.isEmpty { return true }
            return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let endpoint, !endpoint.isEmpty else { return false }
        return endpoint.hasPrefix("avf://")
            || endpoint.hasPrefix("sck://")
            || endpoint.hasPrefix("ndi://")
    }

    /// Project seed or catalog stub — not a currently attached unique device.
    var isHardwarePlaceholder: Bool {
        if kind == .screenShare, endpoint == "sck://display/0" { return true }
        if kind == .camera || kind == .continuity || kind == .captureCard {
            return !hasBindableHardwareEndpoint
        }
        return false
    }
}

struct StudioAudioDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var endpoint: String
}

struct SceneOverlay: Hashable, Codable, Sendable {
    var kind: String
    var enabled: Bool
}

struct AudioMixLevel: Hashable, Codable, Sendable {
    var channelID: UUID
    var gainDb: Double
}

struct ProShowScene: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var layout: SceneLayoutKind
    var hotKey: String
    var primarySourceID: UUID?
    var pipSourceID: UUID?
    var primaryBounds: CanvasRect
    var pipBounds: CanvasRect?
    var linkedPresentationName: String?
    var overlays: [SceneOverlay]
    var mix: [AudioMixLevel]
    var duckDesktopAudio: Bool
    var transitionPresetID: String?

    init(
        id: UUID = UUID(),
        name: String,
        layout: SceneLayoutKind,
        hotKey: String = "",
        primarySourceID: UUID? = nil,
        pipSourceID: UUID? = nil,
        primaryBounds: CanvasRect = .fullFrame,
        pipBounds: CanvasRect? = nil,
        linkedPresentationName: String? = nil,
        overlays: [SceneOverlay] = [],
        mix: [AudioMixLevel] = [],
        duckDesktopAudio: Bool = false,
        transitionPresetID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.hotKey = hotKey
        self.primarySourceID = primarySourceID
        self.pipSourceID = pipSourceID
        self.primaryBounds = primaryBounds
        self.pipBounds = pipBounds
        self.linkedPresentationName = linkedPresentationName
        self.overlays = overlays
        self.mix = mix
        self.duckDesktopAudio = duckDesktopAudio
        self.transitionPresetID = transitionPresetID
    }
}

enum SoundboardLoopMode: String, Hashable, Codable, Sendable {
    case once, loop
}

struct SoundboardPad: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var relativePath: String
    var volume: Double
    var ducksProgram: Bool
    var loopMode: SoundboardLoopMode
    var waveform: [Double]

    init(
        id: UUID = UUID(),
        name: String,
        relativePath: String = "",
        volume: Double = 1,
        ducksProgram: Bool = false,
        loopMode: SoundboardLoopMode = .once,
        waveform: [Double] = []
    ) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.volume = volume
        self.ducksProgram = ducksProgram
        self.loopMode = loopMode
        self.waveform = waveform
    }
}

enum AudioChannelRole: String, Hashable, Codable, Sendable {
    case microphone, desktop, guest, slide, soundboard
}

enum AudioOutputBus: String, Hashable, Codable, Sendable {
    case stream, monitor, both, stage, all
}

struct AudioEQ: Hashable, Codable, Sendable {
    var lowDb: Double = 0
    var midDb: Double = 0
    var highDb: Double = 0
}

enum ParametricEQFilter: String, Hashable, Codable, Sendable {
    case highPass, lowShelf, parametric, highShelf, lowPass

    var title: String {
        switch self {
        case .highPass: "Low Cut"
        case .lowShelf: "Low Shelf"
        case .parametric: "Peak"
        case .highShelf: "High Shelf"
        case .lowPass: "High Cut"
        }
    }
}

struct ParametricEQBand: Identifiable, Hashable, Codable, Sendable {
    var id: Int
    var filter: ParametricEQFilter
    var frequency: Double
    var gainDb: Double
    var q: Double
    var enabled: Bool

    var frequencyRange: ClosedRange<Double> {
        switch filter {
        case .highPass: 20...400
        case .lowShelf: 80...800
        case .parametric: id == 3 ? 200...2_000 : 1_000...8_000
        case .highShelf: 4_000...16_000
        case .lowPass: 8_000...20_000
        }
    }
}

struct ParametricEQ: Hashable, Codable, Sendable {
    var bands: [ParametricEQBand]

    static let studioDefault = ParametricEQ(bands: [
        ParametricEQBand(id: 1, filter: .highPass, frequency: 80, gainDb: 0, q: 0.7, enabled: true),
        ParametricEQBand(id: 2, filter: .lowShelf, frequency: 200, gainDb: 0, q: 0.7, enabled: true),
        ParametricEQBand(id: 3, filter: .parametric, frequency: 800, gainDb: 0, q: 1.0, enabled: true),
        ParametricEQBand(id: 4, filter: .parametric, frequency: 2_500, gainDb: 0, q: 1.0, enabled: true),
        ParametricEQBand(id: 5, filter: .highShelf, frequency: 8_000, gainDb: 0, q: 0.7, enabled: true),
        ParametricEQBand(id: 6, filter: .lowPass, frequency: 16_000, gainDb: 0, q: 0.7, enabled: true),
    ])

    static func migrated(from eq: AudioEQ) -> ParametricEQ {
        var next = studioDefault
        next.bands[1].gainDb = eq.lowDb
        next.bands[2].gainDb = eq.midDb * 0.55
        next.bands[3].gainDb = eq.midDb * 0.45
        next.bands[4].gainDb = eq.highDb
        return next
    }
}

struct MixerMasterState: Hashable, Codable, Sendable {
    var limiterEnabled: Bool = true
    var ceilingDb: Double = -0.1
    var muted: Bool = false
    var gainDb: Double = 0
    var peakLeft: Double = -120
    var peakRight: Double = -120
    var peakHoldDb: Double = -120
}

struct AudioMatrixChannel: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var role: AudioChannelRole
    var gainDb: Double
    var muted: Bool
    var solo: Bool
    var eq: AudioEQ
    var bus: AudioOutputBus
    var peak: Double
    var trimDb: Double? = nil
    var duckTarget: Bool? = nil
    var parametricEQ: ParametricEQ? = nil
    var peakLeft: Double? = nil
    var peakRight: Double? = nil
    var peakHoldDb: Double? = nil
    /// Backstage guest ISO mic row for per-guest mix-minus return feeds.
    var linkedGuestID: UUID? = nil

    init(
        id: UUID = UUID(),
        name: String,
        role: AudioChannelRole,
        gainDb: Double = 0,
        muted: Bool = false,
        solo: Bool = false,
        eq: AudioEQ = AudioEQ(),
        bus: AudioOutputBus = .both,
        peak: Double = 0,
        trimDb: Double? = nil,
        duckTarget: Bool? = nil,
        parametricEQ: ParametricEQ? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.gainDb = gainDb
        self.muted = muted
        self.solo = solo
        self.eq = eq
        self.bus = bus
        self.peak = peak
        self.trimDb = trimDb
        self.duckTarget = duckTarget
        self.parametricEQ = parametricEQ
    }

    var resolvedTrimDb: Double { trimDb ?? 0 }
    var isDuckTarget: Bool { duckTarget ?? (role != .microphone) }
    var resolvedEQ: ParametricEQ { parametricEQ ?? .migrated(from: eq) }
    var stereoPeak: Double { max(peakLeft ?? peak, peakRight ?? peak) }
}

struct RGBAColor: Hashable, Codable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    static let green = RGBAColor(r: 0, g: 1, b: 0, a: 1)
    static let blue = RGBAColor(r: 0, g: 0, b: 1, a: 1)
}

struct ChromaKeySettings: Hashable, Codable, Sendable {
    var keyColor: RGBAColor
    var smoothness: Double
    var spillSuppression: Double
    var edgeCutoff: Double

    static let green = ChromaKeySettings(keyColor: .green, smoothness: 0.12, spillSuppression: 0.35, edgeCutoff: 0.18)
    static let blue = ChromaKeySettings(keyColor: .blue, smoothness: 0.12, spillSuppression: 0.35, edgeCutoff: 0.18)
}

struct ColorGradeSettings: Hashable, Codable, Sendable {
    var exposure: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var sharpness: Double = 0
    var backgroundBlur: Double = 0
    var lutName: String = ""
}

enum ChatPlatform: String, Hashable, Codable, Sendable, CaseIterable {
    case youtube, twitch, facebook, x, zoom, googleMeet, backstage
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var platform: ChatPlatform
    var author: String
    var text: String
    var avatarName: String

    init(id: UUID = UUID(), platform: ChatPlatform, author: String, text: String, avatarName: String = "") {
        self.id = id
        self.platform = platform
        self.author = author
        self.text = text
        self.avatarName = avatarName
    }
}

struct ChatOverlayCard: Hashable, Codable, Sendable {
    var message: ChatMessage
    var visible: Bool
}

struct StudioManifest: Hashable, Codable, Sendable {
    var scenes: [ProShowScene]
    var soundboard: [SoundboardPad]
    var videoSources: [StudioVideoSource]
    var audioChannels: [AudioMatrixChannel]
    var activeSceneID: UUID?
    var inspector: ActionInspectorCatalog?
    var mediaCollections: [MediaCollection]
    var importedMedia: [MediaBinItem]
    var placeholderMatrix: [PlaceholderConfiguration]
    var mapGraph: [MapGraphPlacement]
    var mapLinks: [MapGraphLink]
    var mapBackdrops: [MapBackdropGroup]
    var textFields: [ShowTextField]

    init(
        scenes: [ProShowScene],
        soundboard: [SoundboardPad],
        videoSources: [StudioVideoSource],
        audioChannels: [AudioMatrixChannel],
        activeSceneID: UUID?,
        inspector: ActionInspectorCatalog? = nil,
        mediaCollections: [MediaCollection] = [],
        importedMedia: [MediaBinItem] = [],
        placeholderMatrix: [PlaceholderConfiguration] = [],
        mapGraph: [MapGraphPlacement] = [],
        mapLinks: [MapGraphLink] = [],
        mapBackdrops: [MapBackdropGroup] = [],
        textFields: [ShowTextField] = []
    ) {
        self.scenes = scenes
        self.soundboard = soundboard
        self.videoSources = videoSources
        self.audioChannels = audioChannels
        self.activeSceneID = activeSceneID
        self.inspector = inspector
        self.mediaCollections = mediaCollections
        self.importedMedia = importedMedia
        self.placeholderMatrix = placeholderMatrix
        self.mapGraph = mapGraph
        self.mapLinks = mapLinks
        self.mapBackdrops = mapBackdrops
        self.textFields = textFields
    }

    enum CodingKeys: String, CodingKey {
        case scenes, soundboard, videoSources, audioChannels, activeSceneID, inspector
        case mediaCollections, importedMedia, placeholderMatrix, mapGraph, mapLinks, mapBackdrops, textFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scenes = try container.decodeIfPresent([ProShowScene].self, forKey: .scenes) ?? []
        soundboard = try container.decodeIfPresent([SoundboardPad].self, forKey: .soundboard) ?? []
        videoSources = try container.decodeIfPresent([StudioVideoSource].self, forKey: .videoSources) ?? []
        audioChannels = try container.decodeIfPresent([AudioMatrixChannel].self, forKey: .audioChannels) ?? []
        activeSceneID = try container.decodeIfPresent(UUID.self, forKey: .activeSceneID)
        inspector = try container.decodeIfPresent(ActionInspectorCatalog.self, forKey: .inspector)
        mediaCollections = try container.decodeIfPresent([MediaCollection].self, forKey: .mediaCollections) ?? []
        importedMedia = try container.decodeIfPresent([MediaBinItem].self, forKey: .importedMedia) ?? []
        placeholderMatrix = try container.decodeIfPresent([PlaceholderConfiguration].self, forKey: .placeholderMatrix) ?? []
        mapGraph = try container.decodeIfPresent([MapGraphPlacement].self, forKey: .mapGraph) ?? []
        mapLinks = try container.decodeIfPresent([MapGraphLink].self, forKey: .mapLinks) ?? []
        mapBackdrops = try container.decodeIfPresent([MapBackdropGroup].self, forKey: .mapBackdrops) ?? []
        textFields = try container.decodeIfPresent([ShowTextField].self, forKey: .textFields) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scenes, forKey: .scenes)
        try container.encode(soundboard, forKey: .soundboard)
        try container.encode(videoSources, forKey: .videoSources)
        try container.encode(audioChannels, forKey: .audioChannels)
        try container.encodeIfPresent(activeSceneID, forKey: .activeSceneID)
        try container.encodeIfPresent(inspector, forKey: .inspector)
        try container.encode(mediaCollections, forKey: .mediaCollections)
        try container.encode(importedMedia, forKey: .importedMedia)
        try container.encode(placeholderMatrix, forKey: .placeholderMatrix)
        try container.encode(mapGraph, forKey: .mapGraph)
        try container.encode(mapLinks, forKey: .mapLinks)
        try container.encode(mapBackdrops, forKey: .mapBackdrops)
        try container.encode(textFields, forKey: .textFields)
    }

    static let empty = StudioManifest(
        scenes: [],
        soundboard: [],
        videoSources: [],
        audioChannels: [],
        activeSceneID: nil
    )
}

enum StudioSeedID {
    static let camera = UUID(uuidString: "A11A0000-0000-4000-8000-000000000001")!
    static let cameraB = UUID(uuidString: "A11A0000-0000-4000-8000-000000000002")!
    static let screen = UUID(uuidString: "A11A0000-0000-4000-8000-000000000003")!
    static let solo = UUID(uuidString: "B11B0000-0000-4000-8000-000000000001")!
    static let presenterDeck = UUID(uuidString: "B11B0000-0000-4000-8000-000000000002")!
    static let interview = UUID(uuidString: "B11B0000-0000-4000-8000-000000000003")!
    static let screenShare = UUID(uuidString: "B11B0000-0000-4000-8000-000000000004")!
    static let mic = UUID(uuidString: "C11C0000-0000-4000-8000-000000000001")!
    static let desktop = UUID(uuidString: "C11C0000-0000-4000-8000-000000000002")!
    static let applause = UUID(uuidString: "D11D0000-0000-4000-8000-000000000001")!
}
