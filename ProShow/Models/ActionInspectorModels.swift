import Foundation

enum ActionInspectorTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case layers, audio, stage, timers, messages, props, macros, backstage, matrix

    /// Tabs shown on the operator desk (legacy stage/matrix remain for saved workspace state).
    static let deskTabs: [ActionInspectorTab] = [
        .layers, .audio, .timers, .messages, .props, .macros, .backstage,
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layers: "Layers"
        case .audio: "Audio"
        case .stage: "Stage"
        case .timers: "Timers"
        case .messages: "Messages"
        case .props: "Props"
        case .macros: "Macros"
        case .backstage: "Backstage"
        case .matrix: "Matrix"
        }
    }

    var systemImage: String {
        switch self {
        case .layers: "square.3.layers.3d"
        case .audio: "waveform"
        case .stage: "rectangle.split.2x1"
        case .timers: "timer"
        case .messages: "paperplane.fill"
        case .props: "square.on.square"
        case .macros: "m.square.fill"
        case .backstage: "person.2.fill"
        case .matrix: "rectangle.split.3x3"
        }
    }
}

enum PreviewFeed: String, CaseIterable, Identifiable, Codable, Sendable {
    case audience
    case stage
    case stream
    case matrix

    static let operatorFeeds: [PreviewFeed] = [.audience, .stream]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audience: "Preview"
        case .stage: "Stage Display"
        case .stream: "Live"
        case .matrix: "MultiViewer"
        }
    }
}

enum ClearStripAction: String, CaseIterable, Identifiable, Sendable {
    case audio, messages, props, all, slide, media, videoInput

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Hide Audio"
        case .messages: "Hide Messages"
        case .props: "Hide Props"
        case .all: "Hide All"
        case .slide: "Hide Slide"
        case .media: "Hide Media"
        case .videoInput: "Hide Video"
        }
    }

    var restoreTitle: String {
        switch self {
        case .audio: "Show Audio"
        case .messages: "Show Messages"
        case .props: "Show Props"
        case .all: "Show All"
        case .slide: "Show Slide"
        case .media: "Show Media"
        case .videoInput: "Show Video"
        }
    }

    /// Stable program-layer glyph (visibility toggles via dimming + eye badge, not slash icons).
    var layerIcon: String {
        switch self {
        case .audio: "speaker.wave.2.fill"
        case .messages: "bubble.left.and.bubble.right.fill"
        case .props: "square.on.square"
        case .all: "square.stack.3d.up.fill"
        case .slide: "doc.plaintext.fill"
        case .media: "photo.on.rectangle.angled"
        case .videoInput: "video.fill"
        }
    }

    var layerName: String {
        switch self {
        case .audio: "audio"
        case .messages: "messages"
        case .props: "props"
        case .all: "all"
        case .slide: "slide"
        case .media: "media"
        case .videoInput: "video_input"
        }
    }

    /// Program stack layer this strip toggles (visibility). Nil for global actions.
    var linkedRenderLayer: RenderLayer? {
        switch self {
        case .media: .media
        case .videoInput: .videoInput
        case .slide: .slide
        case .messages: .messages
        case .props: .props
        default: nil
        }
    }
}

struct ProShowProp: Identifiable, Hashable, Codable, Sendable, Equatable {
    enum AutoClearMode: Hashable, Codable, Sendable, Equatable {
        case never
        case afterDelay(seconds: Double)
        case onNextSlide
    }

    var id: UUID
    var name: String
    var elements: [CanvasObject]
    var transitionDuration: Double
    var autoClearMode: AutoClearMode
    var isActive: Bool
    var collectionName: String
    var transition: String
    /// When to force-fetch live quotes for this prop's canvas objects (show / operator, not only the editor).
    var liveQuoteRefresh: PropLiveQuoteRefresh = .onEnter

    init(
        id: UUID = UUID(),
        name: String,
        elements: [CanvasObject] = [],
        transitionDuration: Double = 0.5,
        autoClearMode: AutoClearMode = .never,
        isActive: Bool = false,
        collectionName: String = "Default Collection",
        transition: String = "Dissolve",
        liveQuoteRefresh: PropLiveQuoteRefresh = .onEnter
    ) {
        self.id = id
        self.name = name
        self.elements = elements
        self.transitionDuration = transitionDuration
        self.autoClearMode = autoClearMode
        self.isActive = isActive
        self.collectionName = collectionName
        self.transition = transition
        self.liveQuoteRefresh = liveQuoteRefresh
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        elements = try container.decodeIfPresent([CanvasObject].self, forKey: .elements) ?? []
        transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 0.5
        autoClearMode = try container.decodeIfPresent(ProShowProp.AutoClearMode.self, forKey: .autoClearMode) ?? .never
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        collectionName = try container.decodeIfPresent(String.self, forKey: .collectionName) ?? "Default Collection"
        transition = try container.decodeIfPresent(String.self, forKey: .transition) ?? "Dissolve"
        liveQuoteRefresh = try container.decodeIfPresent(PropLiveQuoteRefresh.self, forKey: .liveQuoteRefresh) ?? .onEnter
    }

    enum CodingKeys: String, CodingKey {
        case id, name, elements, transitionDuration, autoClearMode, isActive, collectionName, transition, liveQuoteRefresh
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(elements, forKey: .elements)
        try container.encode(transitionDuration, forKey: .transitionDuration)
        try container.encode(autoClearMode, forKey: .autoClearMode)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(collectionName, forKey: .collectionName)
        try container.encode(transition, forKey: .transition)
        try container.encode(liveQuoteRefresh, forKey: .liveQuoteRefresh)
    }

    var autoClearTitle: String { autoClearMode.title }
}

extension ProShowProp.AutoClearMode {
    var title: String {
        switch self {
        case .never: "Never"
        case .onNextSlide: "On Next Slide"
        case .afterDelay(let seconds): "After \(Int(seconds))s"
        }
    }

    static func parse(_ title: String) -> ProShowProp.AutoClearMode {
        switch title {
        case "On Next Slide": return .onNextSlide
        case let value where value.hasPrefix("After"):
            let digits = value.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? 5
            return .afterDelay(seconds: Double(digits))
        default:
            return .never
        }
    }
}

enum MacroAction: Hashable, Codable, Sendable, Equatable {
    case clearLayer(layerName: String)
    case triggerScene(sceneId: UUID)
    case setStageLayout(layoutId: UUID)
    case startTimer(timerId: UUID)
    case stopTimer(timerId: UUID)
    case resetTimer(timerId: UUID)
    case triggerProp(propId: UUID)
    case playAudioTrack(trackId: UUID)
    case playSoundboard(padId: UUID)
    case playVideo(mediaId: UUID)
    case setAudienceLook(lookName: String)
    case startStream
    case stopStream
    case startISO
    case stopISO
    case muteAudio
}

struct ProShowMacro: Identifiable, Hashable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var colorHex: String
    var actions: [MacroAction]

    init(id: UUID = UUID(), name: String, colorHex: String = "#3B82F6", actions: [MacroAction] = []) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.actions = actions
    }
}

struct ProShowMessage: Identifiable, Hashable, Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var templateText: String
    var dynamicValues: [String: String]
    var displayDuration: Double
    var isActive: Bool

    init(
        id: UUID = UUID(),
        title: String,
        templateText: String,
        dynamicValues: [String: String] = [:],
        displayDuration: Double = 8,
        isActive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.templateText = templateText
        self.dynamicValues = dynamicValues
        self.displayDuration = displayDuration
        self.isActive = isActive
    }

    func resolvedText(now: Date = Date()) -> String {
        MessageTokenParser.resolve(templateText, values: dynamicValues, now: now)
    }
}

enum InspectorTimerKind: String, Hashable, Codable, Sendable, CaseIterable {
    case countdown
    case countdownToTime
    case elapsed

    var title: String {
        switch self {
        case .countdown: "Countdown"
        case .countdownToTime: "Count Down to Time"
        case .elapsed: "Elapsed Time"
        }
    }
}

struct InspectorTimer: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var kind: InspectorTimerKind
    var durationSeconds: Int
    var targetHour: Int
    var targetMinute: Int
    var remainingSeconds: Int
    var elapsedSeconds: Int
    var isRunning: Bool
    var overrunThresholdSeconds: Int
    var isOverrun: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kind: InspectorTimerKind = .countdown,
        durationSeconds: Int = 900,
        targetHour: Int = 11,
        targetMinute: Int = 30,
        remainingSeconds: Int? = nil,
        elapsedSeconds: Int = 0,
        isRunning: Bool = false,
        overrunThresholdSeconds: Int = 120,
        isOverrun: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.targetHour = targetHour
        self.targetMinute = targetMinute
        self.remainingSeconds = remainingSeconds ?? durationSeconds
        self.elapsedSeconds = elapsedSeconds
        self.isRunning = isRunning
        self.overrunThresholdSeconds = overrunThresholdSeconds
        self.isOverrun = isOverrun
    }

    var displaySeconds: Int {
        switch kind {
        case .elapsed: elapsedSeconds
        case .countdown, .countdownToTime: remainingSeconds
        }
    }
}

struct InspectorAudioTrack: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    var volume: Double
    var crossfadeSeconds: Double
    var destination: AudioOutputBus
    var isPlaying: Bool

    init(
        id: UUID = UUID(),
        title: String,
        volume: Double = 0.8,
        crossfadeSeconds: Double = 1.5,
        destination: AudioOutputBus = .both,
        isPlaying: Bool = false
    ) {
        self.id = id
        self.title = title
        self.volume = volume
        self.crossfadeSeconds = crossfadeSeconds
        self.destination = destination
        self.isPlaying = isPlaying
    }
}

struct StageLayoutPreset: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var look: StageLookConfig

    static let currentNext = StageLayoutPreset(
        id: ActionSeedID.layoutCurrentNext,
        name: "Current + Next Text",
        look: StageLookConfig(showCurrent: true, showNext: true, showNotes: false, showClock: false)
    )

    static let clockTimers = StageLayoutPreset(
        id: ActionSeedID.layoutClock,
        name: "Clock & Timers",
        look: StageLookConfig(showCurrent: false, showNext: false, showNotes: false, showClock: true)
    )

    static let grid = StageLayoutPreset(
        id: ActionSeedID.layoutGrid,
        name: "Grid View",
        look: StageLookConfig(showCurrent: true, showNext: true, showNotes: true, showClock: true)
    )

    static let notesOnly = StageLayoutPreset(
        id: ActionSeedID.layoutNotes,
        name: "Stage Notes Only",
        look: StageLookConfig(showCurrent: false, showNext: false, showNotes: true, showClock: false)
    )

    static let all: [StageLayoutPreset] = [.currentNext, .clockTimers, .grid, .notesOnly]
}

struct MediaTransportState: Hashable, Codable, Sendable {
    var title: String
    var duration: TimeInterval
    var playhead: TimeInterval
    var isPlaying: Bool
    var isLooping: Bool
    var markers: [TimeInterval]

    static let idle = MediaTransportState(
        title: "No media",
        duration: 0,
        playhead: 0,
        isPlaying: false,
        isLooping: true,
        markers: []
    )

    var remaining: TimeInterval { max(0, duration - playhead) }
}

enum MessageTokenParser {
    static func resolve(_ template: String, values: [String: String], now: Date = Date()) -> String {
        var merged = values
        if merged["Time"] == nil {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            merged["Time"] = formatter.string(from: now)
        }
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let close = template[index...].firstIndex(of: "}") {
                let keyStart = template.index(after: index)
                let key = String(template[keyStart..<close])
                output += merged[key] ?? "{\(key)}"
                index = template.index(after: close)
            } else {
                output.append(template[index])
                index = template.index(after: index)
            }
        }
        return output
    }
}

enum MediaDurationParser {
    static func seconds(from text: String?) -> TimeInterval {
        guard let text, !text.isEmpty else { return 0 }
        let cleaned = text.replacingOccurrences(of: ";", with: ":")
        let parts = cleaned.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        default: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
    }
}

enum ProgramTimecode {
    static func format(_ seconds: TimeInterval, fps: Double = 30) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        let frames = Int((clamped - floor(clamped)) * fps)
        if hours > 0 {
            return String(format: "%02d:%02d:%02d;%02d", hours, minutes, secs, frames)
        }
        return String(format: "%02d:%02d;%02d", minutes, secs, frames)
    }
}

struct ActionInspectorCatalog: Hashable, Codable, Sendable {
    static let defaultPropCollections = ["Default Collection", "Program", "Archive"]

    var props: [ProShowProp]
    var messages: [ProShowMessage]
    var macros: [ProShowMacro]
    var timers: [InspectorTimer]
    var audioTracks: [InspectorAudioTrack]
    var propCollections: [String]
    var selectedPropCollection: String

    init(
        props: [ProShowProp],
        messages: [ProShowMessage],
        macros: [ProShowMacro],
        timers: [InspectorTimer],
        audioTracks: [InspectorAudioTrack],
        propCollections: [String] = defaultPropCollections,
        selectedPropCollection: String = "Default Collection"
    ) {
        self.props = props
        self.messages = messages
        self.macros = macros
        self.timers = timers
        self.audioTracks = audioTracks
        self.propCollections = propCollections.isEmpty ? Self.defaultPropCollections : propCollections
        self.selectedPropCollection = selectedPropCollection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        props = try container.decode([ProShowProp].self, forKey: .props)
        messages = try container.decode([ProShowMessage].self, forKey: .messages)
        macros = try container.decode([ProShowMacro].self, forKey: .macros)
        timers = try container.decode([InspectorTimer].self, forKey: .timers)
        audioTracks = try container.decode([InspectorAudioTrack].self, forKey: .audioTracks)
        propCollections = try container.decodeIfPresent([String].self, forKey: .propCollections)
            ?? Self.defaultPropCollections
        selectedPropCollection = try container.decodeIfPresent(String.self, forKey: .selectedPropCollection)
            ?? "Default Collection"
    }

    enum CodingKeys: String, CodingKey {
        case props, messages, macros, timers, audioTracks, propCollections, selectedPropCollection
    }

    static let empty = ActionInspectorCatalog(
        props: [],
        messages: [],
        macros: [],
        timers: [],
        audioTracks: []
    )
}

enum ActionSeedID {
    static let logoProp = UUID(uuidString: "E11E0000-0000-4000-8000-000000000001")!
    static let alertProp = UUID(uuidString: "E11E0000-0000-4000-8000-000000000002")!
    static let deskCallMessage = UUID(uuidString: "E11E0000-0000-4000-8000-000000000011")!
    static let nurseryMessage = deskCallMessage
    static let showStartMacro = UUID(uuidString: "E11E0000-0000-4000-8000-000000000021")!
    static let talkMacro = UUID(uuidString: "E11E0000-0000-4000-8000-000000000022")!
    static let sermonMacro = talkMacro
    static let streamEndMacro = UUID(uuidString: "E11E0000-0000-4000-8000-000000000023")!
    static let serviceTimer = UUID(uuidString: "E11E0000-0000-4000-8000-000000000031")!
    static let bedTrack = UUID(uuidString: "E11E0000-0000-4000-8000-000000000041")!
    static let layoutCurrentNext = UUID(uuidString: "E11E0000-0000-4000-8000-000000000051")!
    static let layoutClock = UUID(uuidString: "E11E0000-0000-4000-8000-000000000052")!
    static let layoutGrid = UUID(uuidString: "E11E0000-0000-4000-8000-000000000053")!
    static let layoutNotes = UUID(uuidString: "E11E0000-0000-4000-8000-000000000054")!
}
