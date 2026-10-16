import Foundation
import CoreGraphics

enum StreamPlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    var id: String { rawValue }
    case youtube = "YouTube Live"
    case facebook = "Facebook Live"
    case twitter = "X (Twitter)"
    case linkedin = "LinkedIn Live"
    case customRtmp = "Custom RTMP"
    case srt = "SRT Stream"

    var title: String { rawValue }

    var systemImage: String {
        switch self {
        case .youtube: "play.rectangle.fill"
        case .facebook: "f.square.fill"
        case .twitter: "at"
        case .linkedin: "rectangle.badge.person.crop"
        case .customRtmp: "dot.radiowaves.left.and.right"
        case .srt: "network"
        }
    }

    var tintHex: String {
        switch self {
        case .youtube: "#D44538"
        case .facebook: "#1877F2"
        case .twitter: "#14171A"
        case .linkedin: "#0A66C2"
        case .customRtmp: "#6B9FE0"
        case .srt: "#C9A24A"
        }
    }

    var studioURL: URL? {
        switch self {
        case .twitter: URL(string: "https://studio.x.com/")
        case .linkedin: URL(string: "https://www.linkedin.com/video/golive/now/")
        default: nil
        }
    }

    var ingestHint: String {
        switch self {
        case .twitter:
            "Premium unlocks studio.x.com. Sources → Create source → RTMP. Paste that URL and key here."
        case .linkedin:
            "Open Live Studio, click Get URL, then paste the RTMP URL and key here."
        case .customRtmp, .srt:
            "Paste the ingest URL and stream key from the server."
        default:
            "This destination mints a stream key after you go live."
        }
    }

    var defaultURL: String {
        switch self {
        case .youtube: "rtmp://a.rtmp.youtube.com/live2"
        case .facebook: "rtmps://live-api-s.facebook.com:443/rtmp/"
        case .twitter: "rtmp://va.pscp.tv:80/x"
        case .linkedin: "rtmp://live.linkedin.com/live"
        case .customRtmp: "rtmp://"
        case .srt: "srt://0.0.0.0:9000"
        }
    }
}

enum DestinationScreenKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case stream
    case phone
    case wall
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stream: "Stream"
        case .phone: "Phone"
        case .wall: "Wall"
        case .custom: "Custom"
        }
    }

    var encodesVideo: Bool { self != .wall }
}

enum DestinationScaleMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }
    var title: String { self == .fit ? "Fit" : "Fill" }
}

struct StreamAccount: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var accountName: String
    var platform: StreamPlatform
    var rtmpUrl: String
    var keychainStreamKeyIdentifier: String
    var targetResolution: DisplayResolution
    var targetFrameRate: TargetFrameRate
    var targetBitrateKbps: Int
    var isAuthenticated: Bool
    var channelOrPageId: String
    var profileImageUrl: String?
    var lastAuthenticated: Date?
    var tokenExpiresAt: Date?
    /// Empty or nil is Stream. Old projects omit this field.
    var screenId: String?
    var scaleMode: DestinationScaleMode

    init(
        id: UUID = UUID(),
        accountName: String,
        platform: StreamPlatform,
        rtmpUrl: String? = nil,
        keychainStreamKeyIdentifier: String? = nil,
        targetResolution: DisplayResolution = .res1080p,
        targetFrameRate: TargetFrameRate = .fps30,
        targetBitrateKbps: Int = 6000,
        isAuthenticated: Bool = false,
        channelOrPageId: String = "",
        profileImageUrl: String? = nil,
        lastAuthenticated: Date? = nil,
        tokenExpiresAt: Date? = nil,
        screenId: String? = nil,
        scaleMode: DestinationScaleMode = .fit
    ) {
        self.id = id
        self.accountName = accountName
        self.platform = platform
        self.rtmpUrl = rtmpUrl ?? platform.defaultURL
        self.keychainStreamKeyIdentifier = keychainStreamKeyIdentifier ?? "stream.\(id.uuidString)"
        self.targetResolution = targetResolution
        self.targetFrameRate = targetFrameRate
        self.targetBitrateKbps = targetBitrateKbps
        self.isAuthenticated = isAuthenticated
        self.channelOrPageId = channelOrPageId
        self.profileImageUrl = profileImageUrl
        self.lastAuthenticated = lastAuthenticated
        self.tokenExpiresAt = tokenExpiresAt
        self.screenId = screenId
        self.scaleMode = scaleMode
    }

    var screenKind: DestinationScreenKind {
        guard let screenId, !screenId.isEmpty, let kind = DestinationScreenKind(rawValue: screenId) else {
            return .stream
        }
        return kind
    }

    var oauthAccessIdentifier: String { "oauth.access.\(id.uuidString)" }
    var oauthRefreshIdentifier: String { "oauth.refresh.\(id.uuidString)" }
    var oauthExpiresIdentifier: String { "oauth.expires.\(id.uuidString)" }

    var profileSummary: String {
        "\(targetResolution.width)x\(targetResolution.height)@\(targetFrameRate.encoderFPS) · \(targetBitrateKbps) kbps"
    }

    var supportsOAuth: Bool {
        switch platform {
        case .youtube, .facebook, .twitter, .linkedin: true
        case .customRtmp, .srt: false
        }
    }

    /// YouTube and Facebook mint ingest. X and LinkedIn only give a key from their studio.
    var needsManualIngest: Bool {
        switch platform {
        case .twitter, .linkedin, .customRtmp, .srt: true
        case .youtube, .facebook: false
        }
    }

    var hasStoredStreamKey: Bool {
        let key = KeychainStreamVault.load(identifier: keychainStreamKeyIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case id, accountName, platform, rtmpUrl, keychainStreamKeyIdentifier
        case targetResolution, targetFrameRate, targetBitrateKbps, isAuthenticated
        case channelOrPageId, profileImageUrl, lastAuthenticated, tokenExpiresAt
        case screenId, scaleMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        accountName = try container.decode(String.self, forKey: .accountName)
        platform = try container.decode(StreamPlatform.self, forKey: .platform)
        rtmpUrl = try container.decodeIfPresent(String.self, forKey: .rtmpUrl) ?? platform.defaultURL
        keychainStreamKeyIdentifier = try container.decodeIfPresent(String.self, forKey: .keychainStreamKeyIdentifier)
            ?? "stream.\(id.uuidString)"
        targetResolution = try container.decodeIfPresent(DisplayResolution.self, forKey: .targetResolution) ?? .res1080p
        targetFrameRate = try container.decodeIfPresent(TargetFrameRate.self, forKey: .targetFrameRate) ?? .fps30
        targetBitrateKbps = try container.decodeIfPresent(Int.self, forKey: .targetBitrateKbps) ?? 6000
        isAuthenticated = try container.decodeIfPresent(Bool.self, forKey: .isAuthenticated) ?? false
        channelOrPageId = try container.decodeIfPresent(String.self, forKey: .channelOrPageId) ?? ""
        profileImageUrl = try container.decodeIfPresent(String.self, forKey: .profileImageUrl)
        lastAuthenticated = try container.decodeIfPresent(Date.self, forKey: .lastAuthenticated)
        tokenExpiresAt = try container.decodeIfPresent(Date.self, forKey: .tokenExpiresAt)
        screenId = try container.decodeIfPresent(String.self, forKey: .screenId)
        scaleMode = try container.decodeIfPresent(DestinationScaleMode.self, forKey: .scaleMode) ?? .fit
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(accountName, forKey: .accountName)
        try container.encode(platform, forKey: .platform)
        try container.encode(rtmpUrl, forKey: .rtmpUrl)
        try container.encode(keychainStreamKeyIdentifier, forKey: .keychainStreamKeyIdentifier)
        try container.encode(targetResolution, forKey: .targetResolution)
        try container.encode(targetFrameRate, forKey: .targetFrameRate)
        try container.encode(targetBitrateKbps, forKey: .targetBitrateKbps)
        try container.encode(isAuthenticated, forKey: .isAuthenticated)
        try container.encode(channelOrPageId, forKey: .channelOrPageId)
        try container.encodeIfPresent(profileImageUrl, forKey: .profileImageUrl)
        try container.encodeIfPresent(lastAuthenticated, forKey: .lastAuthenticated)
        try container.encodeIfPresent(tokenExpiresAt, forKey: .tokenExpiresAt)
        if let screenId, !screenId.isEmpty {
            try container.encode(screenId, forKey: .screenId)
        }
        if scaleMode != .fit {
            try container.encode(scaleMode, forKey: .scaleMode)
        }
    }
}

struct ProjectStreamMatrix: Codable, Equatable, Hashable, Sendable {
    var projectId: UUID
    var activeAccountIds: Set<UUID>

    init(projectId: UUID = UUID(), activeAccountIds: Set<UUID> = []) {
        self.projectId = projectId
        self.activeAccountIds = activeAccountIds
    }

    func isActive(_ id: UUID) -> Bool {
        activeAccountIds.contains(id)
    }
}

enum ScreenTargetType: String, Codable, CaseIterable, Sendable {
    case audienceProgram
    case stageConfidence
    case ndiOutput
    case virtualCamera
    case multiViewer

    var title: String {
        switch self {
        case .audienceProgram: "Audience Master Output"
        case .stageConfidence: "Stage Confidence"
        case .ndiOutput: "NDI Broadcast"
        case .virtualCamera: "System Virtual Camera"
        case .multiViewer: "MultiViewer Matrix"
        }
    }
}

struct OutputScreenConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var displayIndex: Int
    var name: String
    var targetType: ScreenTargetType
    var originX: Double
    var originY: Double
    var width: Double
    var height: Double
    var refreshHz: Double
    var isEnabled: Bool
    var linkedStageLayoutId: UUID?
    var alphaKeyEnabled: Bool
    var colorProfile: String
    var themeVariantID: UUID?

    var bounds: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }

    init(
        id: UUID = UUID(),
        displayIndex: Int,
        name: String,
        targetType: ScreenTargetType,
        originX: Double = 0,
        originY: Double = 0,
        width: Double = 1920,
        height: Double = 1080,
        refreshHz: Double = 60,
        isEnabled: Bool = true,
        linkedStageLayoutId: UUID? = nil,
        alphaKeyEnabled: Bool = false,
        colorProfile: String = "Rec.709",
        themeVariantID: UUID? = nil
    ) {
        self.id = id
        self.displayIndex = displayIndex
        self.name = name
        self.targetType = targetType
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.refreshHz = refreshHz
        self.isEnabled = isEnabled
        self.linkedStageLayoutId = linkedStageLayoutId
        self.alphaKeyEnabled = alphaKeyEnabled
        self.colorProfile = colorProfile
        self.themeVariantID = themeVariantID
    }

    enum CodingKeys: String, CodingKey {
        case id, displayIndex, name, targetType, originX, originY, width, height
        case refreshHz, isEnabled, linkedStageLayoutId, alphaKeyEnabled, colorProfile, themeVariantID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayIndex = try container.decode(Int.self, forKey: .displayIndex)
        name = try container.decode(String.self, forKey: .name)
        targetType = try container.decode(ScreenTargetType.self, forKey: .targetType)
        originX = try container.decodeIfPresent(Double.self, forKey: .originX) ?? 0
        originY = try container.decodeIfPresent(Double.self, forKey: .originY) ?? 0
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 1920
        height = try container.decodeIfPresent(Double.self, forKey: .height) ?? 1080
        refreshHz = try container.decodeIfPresent(Double.self, forKey: .refreshHz) ?? 60
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        linkedStageLayoutId = try container.decodeIfPresent(UUID.self, forKey: .linkedStageLayoutId)
        alphaKeyEnabled = try container.decodeIfPresent(Bool.self, forKey: .alphaKeyEnabled) ?? false
        colorProfile = try container.decodeIfPresent(String.self, forKey: .colorProfile) ?? "Rec.709"
        themeVariantID = try container.decodeIfPresent(UUID.self, forKey: .themeVariantID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayIndex, forKey: .displayIndex)
        try container.encode(name, forKey: .name)
        try container.encode(targetType, forKey: .targetType)
        try container.encode(originX, forKey: .originX)
        try container.encode(originY, forKey: .originY)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
        try container.encode(refreshHz, forKey: .refreshHz)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(linkedStageLayoutId, forKey: .linkedStageLayoutId)
        try container.encode(alphaKeyEnabled, forKey: .alphaKeyEnabled)
        try container.encode(colorProfile, forKey: .colorProfile)
        try container.encodeIfPresent(themeVariantID, forKey: .themeVariantID)
    }
}

enum StartupBehavior: String, Codable, CaseIterable, Sendable {
    case startMenu
    case lastProject
    case blankProject

    var title: String {
        switch self {
        case .startMenu: "Open Start Menu"
        case .lastProject: "Auto-Load Last Project"
        case .blankProject: "Open Blank Project"
        }
    }
}

enum SettingsAppearance: String, Codable, CaseIterable, Sendable {
    case system, dark, light

    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark Mode"
        case .light: "Light Mode"
        }
    }
}

enum SettingsNavSection: String, CaseIterable, Identifiable, Sendable {
    case show
    case output
    case studio
    case machine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .show: "Show"
        case .output: "Output"
        case .studio: "Studio"
        case .machine: "This Mac"
        }
    }

    var categories: [SettingsCategory] {
        switch self {
        case .show: [.general, .teleprompter, .groups]
        case .output: [.streaming, .screens, .audio, .recording]
        case .studio: [.inputs, .media, .network, .integrations, .ai]
        case .machine: [.cloud, .updates]
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case streaming
    case screens
    case audio
    case network
    case inputs
    case recording
    case media
    case integrations
    case ai
    case groups
    case teleprompter
    case cloud
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .streaming: "Streaming"
        case .screens: "Screens"
        case .audio: "Audio"
        case .network: "Network"
        case .inputs: "Inputs"
        case .recording: "Recording"
        case .media: "Media"
        case .integrations: "Integrations"
        case .ai: "AI"
        case .groups: "Groups"
        case .teleprompter: "Teleprompter"
        case .cloud: "Backups"
        case .updates: "About"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup, autosave, canvas, and appearance for this Mac and the open project."
        case .streaming: "Accounts saved on this Mac, and which destinations this project can go live to."
        case .screens: "Physical displays, MultiViewer layout, NDI, and the system virtual camera."
        case .audio: "CoreAudio clock, buffer, and master ducking."
        case .network: "Localhost Control API and telemetry. This Mac only."
        case .inputs: "Cameras, capture cards, and mixer channels already in the studio."
        case .recording: "Program and ISO files next to the project bundle."
        case .media: "How imported files land in the project and how previews are built."
        case .integrations: "Stream Deck, Companion, and outbound show hooks."
        case .ai: "Ask ProShow agent, xAI key, model, and practice mode."
        case .groups: "Slide group colors used for search and rundown marks."
        case .teleprompter: "CueLog word clock, pause holds, and how the prompt draws each word."
        case .cloud: "Copies of the project stay on this Mac unless you choose a folder."
        case .updates: "Installed build. This app does not check a server."
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .streaming: "dot.radiowaves.left.and.right"
        case .screens: "display.2"
        case .audio: "waveform"
        case .network: "network"
        case .inputs: "video.badge.plus"
        case .recording: "record.circle"
        case .media: "folder"
        case .integrations: "puzzlepiece.extension"
        case .ai: "sparkles"
        case .groups: "tag"
        case .teleprompter: "text.word.spacing"
        case .cloud: "icloud"
        case .updates: "arrow.up.circle"
        }
    }

    var keywords: [String] {
        switch self {
        case .general: ["startup", "autosave", "canvas", "appearance", "resolution", "swipe", "layer"]
        case .streaming: ["youtube", "facebook", "rtmp", "account", "destination", "multistream", "phone", "multiple screens"]
        case .screens: ["display", "ndi", "virtual camera", "audience", "stage", "blend", "multiviewer", "matrix"]
        case .audio: ["sample rate", "buffer", "ducking", "coreaudio"]
        case .network: ["api", "websocket", "localhost", "token", "osc", "midi"]
        case .inputs: ["camera", "capture", "microphone", "continuity"]
        case .recording: ["iso", "prores", "hevc", "split"]
        case .media: ["import", "thumbnail", "waveform", "copy"]
        case .integrations: ["webhook", "stream deck", "companion", "chat"]
        case .ai: ["xai", "grok", "agent", "compose", "practice", "ask", "key", "model"]
        case .groups: ["verse", "chorus", "label", "color"]
        case .teleprompter: ["prompt", "pause", "wpm", "kinetic", "scroll", "cuelog"]
        case .cloud: ["sync", "backup"]
        case .updates: ["version", "release"]
        }
    }

    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return title.lowercased().contains(needle)
            || keywords.contains { $0.contains(needle) || needle.contains($0) }
    }
}

struct SettingsGroupLabel: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: String
    var name: String
    var colorHex: String
    var hotKey: String

    static let factory: [SettingsGroupLabel] = [
        .init(id: "verse", name: "Verse", colorHex: "#3B82F6", hotKey: "1"),
        .init(id: "chorus", name: "Chorus", colorHex: "#D44538", hotKey: "2"),
        .init(id: "bridge", name: "Bridge", colorHex: "#C9A24A", hotKey: "3"),
        .init(id: "intro", name: "Intro", colorHex: "#2F9E44", hotKey: "4"),
    ]
}

struct DeviceSettingsDocument: Codable, Equatable, Sendable {
    var accounts: [StreamAccount]
    var screens: [OutputScreenConfig]
    var startup: StartupBehavior
    var appearance: SettingsAppearance
    var walFlushSeconds: Double
    var defaultResolution: DisplayResolution
    var defaultFrameRate: TargetFrameRate
    var audioSampleRate: Int
    var audioBufferSamples: Int
    var duckingThresholdDb: Double
    var duckingReleaseMs: Int
    var controlAPIEnabled: Bool
    var controlAPIPort: Int
    var webSocketEnabled: Bool
    var oscEnabled: Bool
    var oscPort: Int
    var midiEnabled: Bool
    var copyMediaIntoBundle: Bool
    var thumbnailPosterPercent: Int
    var waveformSamplesPerSecond: Int
    var isoCodec: String
    var autoSplit: String
    var groupLabels: [SettingsGroupLabel]
    var ndiOutputName: String
    var virtualCameraEnabled: Bool
    var blendWidth: Double
    var blendGamma: Double
    var showAlignmentPattern: Bool
    var multiViewer: MultiViewerLayout
    var youtubeRedirectURI: String
    var linkedinRedirectURI: String
    var xRedirectURI: String
    var facebookRedirectURI: String

    static let `default` = DeviceSettingsDocument(
        accounts: [],
        screens: [],
        startup: .startMenu,
        appearance: .dark,
        walFlushSeconds: 2,
        defaultResolution: CaptureBudget.factoryResolution(),
        defaultFrameRate: CaptureBudget.factoryFrameRate(),
        audioSampleRate: 48000,
        audioBufferSamples: 256,
        duckingThresholdDb: -24,
        duckingReleaseMs: 400,
        controlAPIEnabled: true,
        controlAPIPort: 55076,
        webSocketEnabled: true,
        oscEnabled: true,
        oscPort: 8000,
        midiEnabled: true,
        copyMediaIntoBundle: true,
        thumbnailPosterPercent: 10,
        waveformSamplesPerSecond: 100,
        isoCodec: "h264",
        autoSplit: "4 GB",
        groupLabels: SettingsGroupLabel.factory,
        ndiOutputName: "PROSHOW-MAIN-OUT",
        virtualCameraEnabled: true,
        blendWidth: 120,
        blendGamma: 2.2,
        showAlignmentPattern: false,
        multiViewer: .empty,
        youtubeRedirectURI: StreamOAuthConfiguration.n8nRedirectURI,
        linkedinRedirectURI: StreamOAuthConfiguration.n8nRedirectURI,
        xRedirectURI: StreamOAuthConfiguration.proshowXRedirectURI,
        facebookRedirectURI: StreamOAuthConfiguration.n8nRedirectURI
    )

    enum CodingKeys: String, CodingKey {
        case accounts, screens, startup, appearance, walFlushSeconds
        case defaultResolution, defaultFrameRate, audioSampleRate, audioBufferSamples
        case duckingThresholdDb, duckingReleaseMs, controlAPIEnabled, controlAPIPort
        case webSocketEnabled, oscEnabled, oscPort, midiEnabled
        case copyMediaIntoBundle, thumbnailPosterPercent, waveformSamplesPerSecond
        case isoCodec, autoSplit, groupLabels, ndiOutputName, virtualCameraEnabled
        case blendWidth, blendGamma, showAlignmentPattern, multiViewer
        case youtubeRedirectURI, linkedinRedirectURI, xRedirectURI, facebookRedirectURI
    }

    init(
        accounts: [StreamAccount],
        screens: [OutputScreenConfig],
        startup: StartupBehavior,
        appearance: SettingsAppearance,
        walFlushSeconds: Double,
        defaultResolution: DisplayResolution,
        defaultFrameRate: TargetFrameRate,
        audioSampleRate: Int,
        audioBufferSamples: Int,
        duckingThresholdDb: Double,
        duckingReleaseMs: Int,
        controlAPIEnabled: Bool,
        controlAPIPort: Int,
        webSocketEnabled: Bool,
        oscEnabled: Bool,
        oscPort: Int,
        midiEnabled: Bool,
        copyMediaIntoBundle: Bool,
        thumbnailPosterPercent: Int,
        waveformSamplesPerSecond: Int,
        isoCodec: String,
        autoSplit: String,
        groupLabels: [SettingsGroupLabel],
        ndiOutputName: String,
        virtualCameraEnabled: Bool,
        blendWidth: Double,
        blendGamma: Double,
        showAlignmentPattern: Bool,
        multiViewer: MultiViewerLayout,
        youtubeRedirectURI: String,
        linkedinRedirectURI: String,
        xRedirectURI: String,
        facebookRedirectURI: String
    ) {
        self.accounts = accounts
        self.screens = screens
        self.startup = startup
        self.appearance = appearance
        self.walFlushSeconds = walFlushSeconds
        self.defaultResolution = defaultResolution
        self.defaultFrameRate = defaultFrameRate
        self.audioSampleRate = audioSampleRate
        self.audioBufferSamples = audioBufferSamples
        self.duckingThresholdDb = duckingThresholdDb
        self.duckingReleaseMs = duckingReleaseMs
        self.controlAPIEnabled = controlAPIEnabled
        self.controlAPIPort = controlAPIPort
        self.webSocketEnabled = webSocketEnabled
        self.oscEnabled = oscEnabled
        self.oscPort = oscPort
        self.midiEnabled = midiEnabled
        self.copyMediaIntoBundle = copyMediaIntoBundle
        self.thumbnailPosterPercent = thumbnailPosterPercent
        self.waveformSamplesPerSecond = waveformSamplesPerSecond
        self.isoCodec = isoCodec
        self.autoSplit = autoSplit
        self.groupLabels = groupLabels
        self.ndiOutputName = ndiOutputName
        self.virtualCameraEnabled = virtualCameraEnabled
        self.blendWidth = blendWidth
        self.blendGamma = blendGamma
        self.showAlignmentPattern = showAlignmentPattern
        self.multiViewer = multiViewer
        self.youtubeRedirectURI = youtubeRedirectURI
        self.linkedinRedirectURI = linkedinRedirectURI
        self.xRedirectURI = xRedirectURI
        self.facebookRedirectURI = facebookRedirectURI
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decode([StreamAccount].self, forKey: .accounts)
        screens = try container.decode([OutputScreenConfig].self, forKey: .screens)
        startup = try container.decode(StartupBehavior.self, forKey: .startup)
        appearance = try container.decode(SettingsAppearance.self, forKey: .appearance)
        walFlushSeconds = try container.decode(Double.self, forKey: .walFlushSeconds)
        defaultResolution = try container.decode(DisplayResolution.self, forKey: .defaultResolution)
        defaultFrameRate = try container.decode(TargetFrameRate.self, forKey: .defaultFrameRate)
        audioSampleRate = try container.decode(Int.self, forKey: .audioSampleRate)
        audioBufferSamples = try container.decode(Int.self, forKey: .audioBufferSamples)
        duckingThresholdDb = try container.decode(Double.self, forKey: .duckingThresholdDb)
        duckingReleaseMs = try container.decode(Int.self, forKey: .duckingReleaseMs)
        controlAPIEnabled = try container.decode(Bool.self, forKey: .controlAPIEnabled)
        controlAPIPort = try container.decode(Int.self, forKey: .controlAPIPort)
        webSocketEnabled = try container.decode(Bool.self, forKey: .webSocketEnabled)
        oscEnabled = try container.decodeIfPresent(Bool.self, forKey: .oscEnabled) ?? true
        oscPort = try container.decodeIfPresent(Int.self, forKey: .oscPort) ?? 8000
        midiEnabled = try container.decodeIfPresent(Bool.self, forKey: .midiEnabled) ?? true
        copyMediaIntoBundle = try container.decode(Bool.self, forKey: .copyMediaIntoBundle)
        thumbnailPosterPercent = try container.decode(Int.self, forKey: .thumbnailPosterPercent)
        waveformSamplesPerSecond = try container.decode(Int.self, forKey: .waveformSamplesPerSecond)
        isoCodec = try container.decode(String.self, forKey: .isoCodec)
        autoSplit = try container.decode(String.self, forKey: .autoSplit)
        groupLabels = try container.decode([SettingsGroupLabel].self, forKey: .groupLabels)
        ndiOutputName = try container.decode(String.self, forKey: .ndiOutputName)
        virtualCameraEnabled = try container.decode(Bool.self, forKey: .virtualCameraEnabled)
        blendWidth = try container.decode(Double.self, forKey: .blendWidth)
        blendGamma = try container.decode(Double.self, forKey: .blendGamma)
        showAlignmentPattern = try container.decode(Bool.self, forKey: .showAlignmentPattern)
        multiViewer = try container.decodeIfPresent(MultiViewerLayout.self, forKey: .multiViewer) ?? .empty
        youtubeRedirectURI = try container.decodeIfPresent(String.self, forKey: .youtubeRedirectURI)
            ?? StreamOAuthConfiguration.n8nRedirectURI
        linkedinRedirectURI = try container.decodeIfPresent(String.self, forKey: .linkedinRedirectURI)
            ?? StreamOAuthConfiguration.n8nRedirectURI
        xRedirectURI = try container.decodeIfPresent(String.self, forKey: .xRedirectURI)
            ?? StreamOAuthConfiguration.n8nRedirectURI
        facebookRedirectURI = try container.decodeIfPresent(String.self, forKey: .facebookRedirectURI)
            ?? StreamOAuthConfiguration.n8nRedirectURI
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accounts, forKey: .accounts)
        try container.encode(screens, forKey: .screens)
        try container.encode(startup, forKey: .startup)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(walFlushSeconds, forKey: .walFlushSeconds)
        try container.encode(defaultResolution, forKey: .defaultResolution)
        try container.encode(defaultFrameRate, forKey: .defaultFrameRate)
        try container.encode(audioSampleRate, forKey: .audioSampleRate)
        try container.encode(audioBufferSamples, forKey: .audioBufferSamples)
        try container.encode(duckingThresholdDb, forKey: .duckingThresholdDb)
        try container.encode(duckingReleaseMs, forKey: .duckingReleaseMs)
        try container.encode(controlAPIEnabled, forKey: .controlAPIEnabled)
        try container.encode(controlAPIPort, forKey: .controlAPIPort)
        try container.encode(webSocketEnabled, forKey: .webSocketEnabled)
        try container.encode(oscEnabled, forKey: .oscEnabled)
        try container.encode(oscPort, forKey: .oscPort)
        try container.encode(midiEnabled, forKey: .midiEnabled)
        try container.encode(copyMediaIntoBundle, forKey: .copyMediaIntoBundle)
        try container.encode(thumbnailPosterPercent, forKey: .thumbnailPosterPercent)
        try container.encode(waveformSamplesPerSecond, forKey: .waveformSamplesPerSecond)
        try container.encode(isoCodec, forKey: .isoCodec)
        try container.encode(autoSplit, forKey: .autoSplit)
        try container.encode(groupLabels, forKey: .groupLabels)
        try container.encode(ndiOutputName, forKey: .ndiOutputName)
        try container.encode(virtualCameraEnabled, forKey: .virtualCameraEnabled)
        try container.encode(blendWidth, forKey: .blendWidth)
        try container.encode(blendGamma, forKey: .blendGamma)
        try container.encode(showAlignmentPattern, forKey: .showAlignmentPattern)
        try container.encode(multiViewer, forKey: .multiViewer)
        try container.encode(youtubeRedirectURI, forKey: .youtubeRedirectURI)
        try container.encode(linkedinRedirectURI, forKey: .linkedinRedirectURI)
        try container.encode(xRedirectURI, forKey: .xRedirectURI)
        try container.encode(facebookRedirectURI, forKey: .facebookRedirectURI)
    }

    var assignedMultiViewerDisplayIndex: Int? {
        screens.first(where: { $0.isEnabled && $0.targetType == .multiViewer })?.displayIndex
    }

    func oauthRedirectURI(for platform: StreamPlatform) -> String {
        switch platform {
        case .youtube: youtubeRedirectURI
        case .linkedin: linkedinRedirectURI
        case .twitter: xRedirectURI
        case .facebook: facebookRedirectURI
        case .customRtmp, .srt: StreamOAuthConfiguration.n8nRedirectURI
        }
    }
}
