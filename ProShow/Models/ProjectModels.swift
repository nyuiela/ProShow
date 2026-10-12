import Foundation

enum ProjectJSON {
    static let schemaVersion = "1.0.0"

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct DisplayResolution: Hashable, Codable, Sendable {
    var width: Int
    var height: Int

    static let res4K = DisplayResolution(width: 3840, height: 2160)
    static let res1080p = DisplayResolution(width: 1920, height: 1080)
    static let res720p = DisplayResolution(width: 1280, height: 720)
    static let resVertical1080 = DisplayResolution(width: 1080, height: 1920)

    static let hd1080 = res1080p
    static let uhd4K = res4K

    var aspectRatioLabel: String {
        if width * 9 == height * 16 { return "16:9" }
        if width * 16 == height * 9 { return "9:16" }
        if width * 3 == height * 4 { return "4:3" }
        if width * 9 == height * 21 { return "21:9" }
        return "Custom"
    }
}

typealias ProjectResolution = DisplayResolution

enum TargetFrameRate: Int, Codable, CaseIterable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps5994 = 59
    case fps60 = 60

    var title: String {
        switch self {
        case .fps24: "24"
        case .fps30: "30"
        case .fps5994: "59.94"
        case .fps60: "60"
        }
    }

    var nominal: Double {
        switch self {
        case .fps24: 24
        case .fps30: 30
        case .fps5994: 59.94
        case .fps60: 60
        }
    }

    var encoderFPS: Int { rawValue }

    var frameInterval: TimeInterval { 1.0 / nominal }

    var gopFrames: Int { encoderFPS * 2 }
}

enum ProjectOutputPreset: String, CaseIterable, Identifiable, Sendable {
    case ultraHD60 = "4K 60fps Ultra HD"
    case ultraHD30 = "4K 30fps Ultra HD"
    case fullHD60 = "1080p 60fps Full HD"
    case fullHD30 = "1080p 30fps Full HD"
    case vertical60 = "1080x1920 60fps Vertical (Mobile)"
    case custom = "Custom"

    var id: String { rawValue }

    var resolution: DisplayResolution? {
        switch self {
        case .ultraHD60, .ultraHD30: .res4K
        case .fullHD60, .fullHD30: .res1080p
        case .vertical60: .resVertical1080
        case .custom: nil
        }
    }

    var frameRate: TargetFrameRate? {
        switch self {
        case .ultraHD60, .fullHD60, .vertical60: .fps60
        case .ultraHD30, .fullHD30: .fps30
        case .custom: nil
        }
    }

    static func matching(_ settings: ProjectSettings) -> ProjectOutputPreset {
        allCases.first(where: { preset in
            guard let resolution = preset.resolution, let frameRate = preset.frameRate else { return false }
            return resolution == settings.resolution && frameRate == settings.frameRate
        }) ?? .custom
    }
}

struct ProjectSettings: Hashable, Codable, Sendable {
    enum Aspect: String, Codable, Sendable {
        case sixteenByNine = "16:9"
        case nineBySixteen = "9:16"
        case fourByThree = "4:3"
        case twentyOneByNine = "21:9"
        case custom = "Custom"
    }

    var name: String
    var resolution: DisplayResolution
    var frameRate: TargetFrameRate
    var aspectRatio: String
    var scaleContentOnResolutionChange: Bool
    var targetAspect: Aspect
    var baseResolution: ProjectResolution
    var defaultTransitionDurationMs: Int
    var audioSampleRate: Int
    /// Security-scoped bookmark for the linked `.program` package.
    var programFileBookmark: Data?
    /// Path fallback when the bookmark cannot be resolved.
    var programFilePath: String?
    /// Camera frames larger than the output, for crop and zoom. Off matches the show size.
    var captureAboveOutput: Bool

    static var `default`: ProjectSettings {
        let resolution = CaptureBudget.factoryResolution()
        return ProjectSettings(
            name: "Default",
            resolution: resolution,
            frameRate: CaptureBudget.factoryFrameRate(),
            aspectRatio: "16:9",
            scaleContentOnResolutionChange: true,
            targetAspect: .sixteenByNine,
            baseResolution: resolution,
            defaultTransitionDurationMs: 1000,
            audioSampleRate: 48000
        )
    }

    init(
        name: String = "Default",
        resolution: DisplayResolution = CaptureBudget.factoryResolution(),
        frameRate: TargetFrameRate = CaptureBudget.factoryFrameRate(),
        aspectRatio: String = "16:9",
        scaleContentOnResolutionChange: Bool = true,
        targetAspect: Aspect = .sixteenByNine,
        baseResolution: ProjectResolution = .uhd4K,
        defaultTransitionDurationMs: Int = 1000,
        audioSampleRate: Int = 48000,
        programFileBookmark: Data? = nil,
        programFilePath: String? = nil,
        captureAboveOutput: Bool = false
    ) {
        self.name = name
        self.resolution = resolution
        self.frameRate = frameRate
        self.aspectRatio = aspectRatio
        self.scaleContentOnResolutionChange = scaleContentOnResolutionChange
        self.targetAspect = targetAspect
        self.baseResolution = baseResolution
        self.defaultTransitionDurationMs = defaultTransitionDurationMs
        self.audioSampleRate = audioSampleRate
        self.programFileBookmark = programFileBookmark
        self.programFilePath = programFilePath
        self.captureAboveOutput = captureAboveOutput
        syncDerivedFields()
    }

    mutating func applyPreset(_ preset: ProjectOutputPreset) {
        guard let resolution = preset.resolution, let frameRate = preset.frameRate else { return }
        self.resolution = resolution
        self.frameRate = frameRate
        syncDerivedFields()
    }

    mutating func syncDerivedFields() {
        baseResolution = resolution
        aspectRatio = resolution.aspectRatioLabel
        targetAspect = Aspect(rawValue: aspectRatio) ?? .custom
    }

    enum CodingKeys: String, CodingKey {
        case name, resolution, frameRate, aspectRatio, scaleContentOnResolutionChange
        case targetAspect, baseResolution, defaultTransitionDurationMs, audioSampleRate
        case programFileBookmark, programFilePath, captureAboveOutput
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Default"
        let legacy = try container.decodeIfPresent(ProjectResolution.self, forKey: .baseResolution)
        resolution = try container.decodeIfPresent(DisplayResolution.self, forKey: .resolution) ?? legacy ?? .res4K
        frameRate = try container.decodeIfPresent(TargetFrameRate.self, forKey: .frameRate) ?? .fps60
        scaleContentOnResolutionChange = try container.decodeIfPresent(Bool.self, forKey: .scaleContentOnResolutionChange) ?? true
        targetAspect = try container.decodeIfPresent(Aspect.self, forKey: .targetAspect) ?? .sixteenByNine
        aspectRatio = try container.decodeIfPresent(String.self, forKey: .aspectRatio) ?? targetAspect.rawValue
        baseResolution = legacy ?? resolution
        defaultTransitionDurationMs = try container.decodeIfPresent(Int.self, forKey: .defaultTransitionDurationMs) ?? 1000
        audioSampleRate = try container.decodeIfPresent(Int.self, forKey: .audioSampleRate) ?? 48000
        programFileBookmark = try container.decodeIfPresent(Data.self, forKey: .programFileBookmark)
        programFilePath = try container.decodeIfPresent(String.self, forKey: .programFilePath)
        captureAboveOutput = try container.decodeIfPresent(Bool.self, forKey: .captureAboveOutput) ?? false
        syncDerivedFields()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(resolution, forKey: .resolution)
        try container.encode(frameRate, forKey: .frameRate)
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encode(scaleContentOnResolutionChange, forKey: .scaleContentOnResolutionChange)
        try container.encode(targetAspect, forKey: .targetAspect)
        try container.encode(baseResolution, forKey: .baseResolution)
        try container.encode(defaultTransitionDurationMs, forKey: .defaultTransitionDurationMs)
        try container.encode(audioSampleRate, forKey: .audioSampleRate)
        try container.encodeIfPresent(programFileBookmark, forKey: .programFileBookmark)
        try container.encodeIfPresent(programFilePath, forKey: .programFilePath)
        try container.encode(captureAboveOutput, forKey: .captureAboveOutput)
    }
}

struct ProShowProject: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var version: String
    var createdAt: Date
    var updatedAt: Date
    var settings: ProjectSettings
    var activePlaylistId: UUID?
    var activePresentationId: UUID?
    var studio: StudioManifest
    var importedAssets: [String]
    var streamMatrix: ProjectStreamMatrix
    var themeSettings: ThemeProjectSettings

    init(
        id: UUID = UUID(),
        name: String,
        version: String = ProjectJSON.schemaVersion,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        settings: ProjectSettings = .default,
        activePlaylistId: UUID? = nil,
        activePresentationId: UUID? = nil,
        studio: StudioManifest = .empty,
        importedAssets: [String] = [],
        streamMatrix: ProjectStreamMatrix? = nil,
        themeSettings: ThemeProjectSettings = .default
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.settings = settings
        self.activePlaylistId = activePlaylistId
        self.activePresentationId = activePresentationId
        self.studio = studio
        self.importedAssets = importedAssets
        self.streamMatrix = streamMatrix ?? ProjectStreamMatrix(projectId: id)
        self.themeSettings = themeSettings
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, createdAt, updatedAt, settings
        case activePlaylistId, activePresentationId, studio
        case scenes, soundboard, videoSources, importedAssets, streamMatrix, themeSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        settings = try container.decode(ProjectSettings.self, forKey: .settings)
        activePlaylistId = try container.decodeIfPresent(UUID.self, forKey: .activePlaylistId)
        activePresentationId = try container.decodeIfPresent(UUID.self, forKey: .activePresentationId)
        if let nested = try container.decodeIfPresent(StudioManifest.self, forKey: .studio) {
            studio = nested
        } else {
            studio = StudioManifest(
                scenes: try container.decodeIfPresent([ProShowScene].self, forKey: .scenes) ?? [],
                soundboard: try container.decodeIfPresent([SoundboardPad].self, forKey: .soundboard) ?? [],
                videoSources: try container.decodeIfPresent([StudioVideoSource].self, forKey: .videoSources) ?? [],
                audioChannels: [],
                activeSceneID: nil
            )
        }
        importedAssets = try container.decodeIfPresent([String].self, forKey: .importedAssets) ?? []
        streamMatrix = try container.decodeIfPresent(ProjectStreamMatrix.self, forKey: .streamMatrix)
            ?? ProjectStreamMatrix(projectId: id)
        themeSettings = try container.decodeIfPresent(ThemeProjectSettings.self, forKey: .themeSettings) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(activePlaylistId, forKey: .activePlaylistId)
        try container.encodeIfPresent(activePresentationId, forKey: .activePresentationId)
        try container.encode(studio, forKey: .studio)
        try container.encode(studio.scenes, forKey: .scenes)
        try container.encode(studio.soundboard, forKey: .soundboard)
        try container.encode(studio.videoSources, forKey: .videoSources)
        try container.encode(importedAssets, forKey: .importedAssets)
        try container.encode(streamMatrix, forKey: .streamMatrix)
        try container.encode(themeSettings, forKey: .themeSettings)
    }
}

enum WorkspaceModule: String, Codable, Sendable {
    case SHOW, EDIT, REFLOW, RUNDOWN, BIBLE, WIDGETS, MAP

    var operatorMode: OperatorMode {
        switch self {
        case .SHOW: .show
        case .EDIT: .edit
        case .REFLOW: .reflow
        case .RUNDOWN: .rundown
        case .BIBLE: .bible
        case .WIDGETS: .widgets
        case .MAP: .map
        }
    }

    init(mode: OperatorMode) {
        switch mode {
        case .show: self = .SHOW
        case .edit: self = .EDIT
        case .reflow: self = .REFLOW
        case .rundown: self = .RUNDOWN
        case .bible: self = .BIBLE
        case .widgets: self = .WIDGETS
        case .map: self = .MAP
        }
    }
}

enum MediaDrawerTab: String, Codable, Sendable {
    case PLAYLISTS, RESOURCES, INPUTS, AUDIO

    var source: MediaSourceID {
        switch self {
        case .PLAYLISTS: .playlists
        case .RESOURCES: .resources
        case .INPUTS: .videoInputs
        case .AUDIO: .audioInputs
        }
    }

    init(source: MediaSourceID) {
        switch source {
        case .playlists, .sampleContent: self = .PLAYLISTS
        case .libraries, .resources: self = .RESOURCES
        case .videoInputs: self = .INPUTS
        case .audioInputs: self = .AUDIO
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw {
        case "RESOURCES": self = .RESOURCES
        case "INPUTS": self = .INPUTS
        case "AUDIO": self = .AUDIO
        default: self = .PLAYLISTS
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum InspectorTab: String, Codable, Sendable {
    case LAYERS, PROPS, AUDIO, STAGE, LOOKS, TIMERS, MESSAGES, MACROS, BACKSTAGE, MATRIX

    var actionTab: ActionInspectorTab {
        switch self {
        case .LAYERS: .layers
        case .AUDIO: .audio
        case .STAGE: .stage
        case .TIMERS: .timers
        case .MESSAGES: .messages
        case .PROPS: .props
        case .LOOKS, .MACROS: .macros
        case .BACKSTAGE: .backstage
        case .MATRIX: .matrix
        }
    }

    init(actionTab: ActionInspectorTab) {
        switch actionTab {
        case .layers: self = .LAYERS
        case .audio: self = .AUDIO
        case .stage: self = .STAGE
        case .timers: self = .TIMERS
        case .messages: self = .MESSAGES
        case .props: self = .PROPS
        case .macros: self = .MACROS
        case .backstage: self = .BACKSTAGE
        case .matrix: self = .MATRIX
        }
    }
}

struct ProShowWorkspaceState: Hashable, Codable, Sendable {
    struct Sidebar: Hashable, Codable, Sendable {
        var visible: Bool
        var width: Double
        var selectedLibraryId: String
        var selectedPlaylistId: String
    }

    struct MediaDrawer: Hashable, Codable, Sendable {
        var visible: Bool
        var height: Double
        var activeTab: MediaDrawerTab
        var zoomLevel: Double
        var sourceOrder: [String]

        init(
            visible: Bool,
            height: Double,
            activeTab: MediaDrawerTab,
            zoomLevel: Double,
            sourceOrder: [String] = []
        ) {
            self.visible = visible
            self.height = height
            self.activeTab = activeTab
            self.zoomLevel = zoomLevel
            self.sourceOrder = sourceOrder
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            visible = try container.decode(Bool.self, forKey: .visible)
            height = try container.decode(Double.self, forKey: .height)
            activeTab = try container.decode(MediaDrawerTab.self, forKey: .activeTab)
            zoomLevel = try container.decode(Double.self, forKey: .zoomLevel)
            sourceOrder = try container.decodeIfPresent([String].self, forKey: .sourceOrder) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case visible, height, activeTab, zoomLevel, sourceOrder
        }
    }

    struct InspectorPane: Hashable, Codable, Sendable {
        var visible: Bool
        var activeTab: InspectorTab
    }

    struct Preview: Hashable, Codable, Sendable {
        var audienceOutputEnabled: Bool
        var stageOutputEnabled: Bool
        var selectedScreenId: String
    }

    var activeModule: WorkspaceModule
    var sidebar: Sidebar
    var mediaDrawer: MediaDrawer
    var inspectorPane: InspectorPane
    var preview: Preview
    var activeSceneId: String
    var studioReady: Bool

    static let `default` = ProShowWorkspaceState(
        activeModule: .SHOW,
        sidebar: Sidebar(visible: true, width: 240, selectedLibraryId: "", selectedPlaylistId: ""),
        mediaDrawer: MediaDrawer(visible: true, height: 200, activeTab: .PLAYLISTS, zoomLevel: 0.45),
        inspectorPane: InspectorPane(visible: true, activeTab: .PROPS),
        preview: Preview(audienceOutputEnabled: true, stageOutputEnabled: true, selectedScreenId: "screen-1"),
        activeSceneId: StudioSeedID.solo.uuidString,
        studioReady: true
    )

    enum CodingKeys: String, CodingKey {
        case activeModule, sidebar, mediaDrawer, inspectorPane, preview, activeSceneId, studioReady
    }

    init(
        activeModule: WorkspaceModule,
        sidebar: Sidebar,
        mediaDrawer: MediaDrawer,
        inspectorPane: InspectorPane,
        preview: Preview,
        activeSceneId: String = "",
        studioReady: Bool = true
    ) {
        self.activeModule = activeModule
        self.sidebar = sidebar
        self.mediaDrawer = mediaDrawer
        self.inspectorPane = inspectorPane
        self.preview = preview
        self.activeSceneId = activeSceneId
        self.studioReady = studioReady
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeModule = try container.decode(WorkspaceModule.self, forKey: .activeModule)
        sidebar = try container.decode(Sidebar.self, forKey: .sidebar)
        mediaDrawer = try container.decode(MediaDrawer.self, forKey: .mediaDrawer)
        inspectorPane = try container.decode(InspectorPane.self, forKey: .inspectorPane)
        preview = try container.decode(Preview.self, forKey: .preview)
        activeSceneId = try container.decodeIfPresent(String.self, forKey: .activeSceneId) ?? ""
        studioReady = try container.decodeIfPresent(Bool.self, forKey: .studioReady) ?? true
    }
}

struct RecentProject: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var lastOpenedAt: Date

    var url: URL { URL(fileURLWithPath: path) }
}

struct AppLaunchPreferences: Hashable, Codable, Sendable {
    static let currentLaunchPrefsVersion = 2

    var alwaysOpenLastProject: Bool
    var lastProjectPath: String?
    var recent: [RecentProject]
    var selectedTheme: String
    var launchPrefsVersion: Int

    static let `default` = AppLaunchPreferences(
        alwaysOpenLastProject: false,
        lastProjectPath: nil,
        recent: [],
        launchPrefsVersion: currentLaunchPrefsVersion
    )

    init(
        alwaysOpenLastProject: Bool,
        lastProjectPath: String?,
        recent: [RecentProject],
        selectedTheme: String = "Default",
        launchPrefsVersion: Int = currentLaunchPrefsVersion
    ) {
        self.alwaysOpenLastProject = alwaysOpenLastProject
        self.lastProjectPath = lastProjectPath
        self.recent = recent
        self.selectedTheme = selectedTheme
        self.launchPrefsVersion = launchPrefsVersion
    }

    enum CodingKeys: String, CodingKey {
        case alwaysOpenLastProject, lastProjectPath, recent, selectedTheme, launchPrefsVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alwaysOpenLastProject = try container.decode(Bool.self, forKey: .alwaysOpenLastProject)
        lastProjectPath = try container.decodeIfPresent(String.self, forKey: .lastProjectPath)
        recent = try container.decodeIfPresent([RecentProject].self, forKey: .recent) ?? []
        selectedTheme = try container.decodeIfPresent(String.self, forKey: .selectedTheme) ?? "Default"
        launchPrefsVersion = try container.decodeIfPresent(Int.self, forKey: .launchPrefsVersion) ?? 1
    }
}

enum LaunchDecision: Equatable, Sendable {
    case startMenu
    case open(URL)
}

enum LaunchPolicy {
    static func decide(
        preferences: AppLaunchPreferences,
        shiftHeld: Bool,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> LaunchDecision {
        if shiftHeld { return .startMenu }
        guard preferences.alwaysOpenLastProject,
              let path = preferences.lastProjectPath, !path.isEmpty
        else { return .startMenu }
        let url = URL(fileURLWithPath: path)
        return fileExists(url) ? .open(url) : .startMenu
    }
}

/// Keeps on-disk bundle folder names and `project.json` manifest titles aligned for UI chrome.
enum ProShowProjectNaming {
    private static let staleManifestNames: Set<String> = [
        "untitled program",
        "untitled",
        "default",
    ]

    static func bundleFileTitle(for bundleRoot: URL) -> String {
        if bundleRoot.pathExtension.lowercased() == "proshow" {
            return bundleRoot.deletingPathExtension().lastPathComponent
        }
        return bundleRoot.lastPathComponent
    }

    static func isStaleManifestName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return staleManifestNames.contains(trimmed.lowercased())
    }

    static func resolvedDisplayName(manifestName: String, bundleRoot: URL?) -> String {
        let fileTitle = bundleRoot.map(bundleFileTitle(for:)) ?? ""
        if isStaleManifestName(manifestName), !fileTitle.isEmpty {
            return fileTitle
        }
        let trimmed = manifestName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return fileTitle.isEmpty ? "Untitled Program" : fileTitle
    }

    @discardableResult
    static func syncManifestNameWithBundle(_ manifest: inout ProShowProject, bundleRoot: URL) -> Bool {
        let fileTitle = bundleFileTitle(for: bundleRoot)
        guard !fileTitle.isEmpty, isStaleManifestName(manifest.name) else { return false }
        guard manifest.name != fileTitle else { return false }
        manifest.name = fileTitle
        if isStaleManifestName(manifest.settings.name) {
            manifest.settings.name = fileTitle
        }
        manifest.updatedAt = Date()
        return true
    }
}

enum WALOperation: Codable, Sendable {
    case upsertLibrary(Show)
    case upsertPlaylist(Playlist)
    case updateManifest(ProShowProject)
    case updateState(ProShowWorkspaceState)
    case importAsset(relativePath: String)
}
