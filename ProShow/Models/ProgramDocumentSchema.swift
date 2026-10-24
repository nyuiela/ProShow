import Foundation

public enum SegmentType: String, Codable, CaseIterable, Sendable {
    case opener = "Opener / Intro"
    case keynote = "Keynote Speaker"
    case panel = "Panel Discussion"
    case mediaVideo = "Video Playback"
    case qAndA = "Q&A Session"
    case breakItem = "Break / Intermission"
    case worship = "Worship / Music"
    case closer = "Closing / Outro"

    var systemImage: String {
        switch self {
        case .opener: "film"
        case .keynote: "mic.fill"
        case .panel: "person.3.fill"
        case .mediaVideo: "play.rectangle.fill"
        case .qAndA: "questionmark.bubble.fill"
        case .breakItem: "cup.and.saucer.fill"
        case .worship: "music.note"
        case .closer: "flag.checkered"
        }
    }

    /// Full-row tint when idle (Shoflo-style segment color coding).
    var rowTintHex: String {
        switch self {
        case .opener: "#3D3A1A"
        case .keynote: "#3A1F3D"
        case .panel: "#1F2F3D"
        case .mediaVideo: "#1A3D28"
        case .qAndA: "#1F3A3D"
        case .breakItem: "#2A2A2E"
        case .worship: "#1A2F3D"
        case .closer: "#2E2A1A"
        }
    }

    var prefersUppercaseTitle: Bool {
        switch self {
        case .keynote, .opener, .closer: true
        default: false
        }
    }
}

public struct TalentProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var fullName: String
    public var titleOrRole: String
    public var organization: String
    public var headshotImagePath: String?
    public var lowerThirdTemplateId: String?
    public var microphoneChannelName: String?
    public var speakerNotes: String?

    public init(
        fullName: String,
        titleOrRole: String = "",
        organization: String = "",
        headshotImagePath: String? = nil,
        lowerThirdTemplateId: String? = nil,
        microphoneChannelName: String? = nil,
        speakerNotes: String? = nil
    ) {
        self.fullName = fullName
        self.titleOrRole = titleOrRole
        self.organization = organization
        self.headshotImagePath = headshotImagePath
        self.lowerThirdTemplateId = lowerThirdTemplateId
        self.microphoneChannelName = microphoneChannelName
        self.speakerNotes = speakerNotes
    }
}

public struct StageCueTrigger: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var triggerOffsetSeconds: Int
    public var stageMessage: String
    public var flashScreen: Bool = false
    public var triggerMacroId: UUID?

    public init(
        triggerOffsetSeconds: Int,
        stageMessage: String,
        flashScreen: Bool = false,
        triggerMacroId: UUID? = nil
    ) {
        self.triggerOffsetSeconds = triggerOffsetSeconds
        self.stageMessage = stageMessage
        self.flashScreen = flashScreen
        self.triggerMacroId = triggerMacroId
    }
}

public enum ScreenDirectionKind: String, Codable, Sendable {
    case camera
    case slide
    case url
    case layout
    case note
    case unknown
}

public struct ScreenDirection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: ScreenDirectionKind
    public var label: String
    public var url: String?
    public var rawKind: String?

    public init(
        id: UUID = UUID(),
        kind: ScreenDirectionKind,
        label: String,
        url: String? = nil,
        rawKind: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.url = url
        self.rawKind = rawKind
    }
}

public struct LinkCue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var url: String
    public var speakOnAir: Bool
    public var autoTake: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        url: String,
        speakOnAir: Bool = false,
        autoTake: Bool = false
    ) {
        self.id = id
        self.label = label
        self.url = url
        self.speakOnAir = speakOnAir
        self.autoTake = autoTake
    }
}

public struct RundownBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var itemNumber: String
    public var title: String
    public var segmentType: SegmentType
    public var plannedDurationSeconds: TimeInterval
    public var isHardTimeLocked: Bool = false
    public var hardStartTime: Date?

    public var assignedTalentIds: [UUID] = []
    public var linkedPlaylistId: UUID?
    /// Media bin item in the current project (Layer 3 take).
    public var linkedMediaBinItemID: UUID?
    public var linkedMediaFilePath: String?

    public var stageDisplayLayoutId: String?
    public var autoFireLowerThirdOnStart: Bool = true
    public var customCueTriggers: [StageCueTrigger] = []

    public var actualStartTime: Date?
    public var actualEndTime: Date?
    public var isCompleted: Bool = false

    public var scriptBody: String = ""
    public var audioCue: String = ""
    public var videoCue: String = ""

    /// Outline authoring version. Spoken copy stays in `scriptBody`.
    public var outlineFormat: Int = 1
    public var screenDirections: [ScreenDirection] = []
    public var linkCues: [LinkCue] = []
    /// Operator-only. Not spoken, not drawn on program output, not exported to CueLog.
    public var referenceNotes: String = ""
    /// Slide stored in the `.program` file when this outline row takes the screen.
    var programSlideID: UUID?
    /// Unused bag for the next experiment. The clock, mixer, and CueLog export ignore it.
    public var extensions: [String: String] = [:]
    /// Auto-advance stops at the end of this item. Nil: decided by `RundownAutoAdvanceRules`.
    public var stopHere: Bool?
    /// How the prompter paces this item. Nil: `PromptPacingMode.defaultMode`.
    public var promptPacing: PromptPacingMode?

    public init(
        itemNumber: String,
        title: String,
        segmentType: SegmentType,
        plannedDurationSeconds: TimeInterval,
        assignedTalentIds: [UUID] = []
    ) {
        self.itemNumber = itemNumber
        self.title = title
        self.segmentType = segmentType
        self.plannedDurationSeconds = plannedDurationSeconds
        self.assignedTalentIds = assignedTalentIds
    }
}

/// Prompter pacing for one outline item.
public enum PromptPacingMode: String, Codable, CaseIterable, Sendable {
    /// Words per minute chosen so the script fills the planned duration (120 to 240).
    case fitDuration
    /// The prompter's own words per minute from its settings.
    case prompterSpeed

    public static let defaultMode: PromptPacingMode = .fitDuration
    public static let wpmRange: ClosedRange<Int> = 120...240
}

public struct ProgramRunEngineState: Codable, Equatable, Sendable {
    public var activeBlockIndex: Int?
    public var isShowRunning: Bool = false
    public var showStartedAt: Date?
    public var cumulativeDriftSeconds: TimeInterval = 0
}

public struct ProgramDocumentModel: Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var showTitle: String = "Sunday Morning Service"
    public var scheduledDate: Date = Date()
    public var hardStartTime: Date = Date()
    public var targetDurationSeconds: TimeInterval = 3600

    public var talentDatabase: [TalentProfile] = []
    public var rundownBlocks: [RundownBlock] = []
    public var runState: ProgramRunEngineState = ProgramRunEngineState()

    public var defaultStageCueTriggers: [StageCueTrigger] = [
        StageCueTrigger(triggerOffsetSeconds: 60, stageMessage: "1 MINUTE REMAINING"),
        StageCueTrigger(triggerOffsetSeconds: 30, stageMessage: "WRAP UP", flashScreen: true),
        StageCueTrigger(triggerOffsetSeconds: 0, stageMessage: "TIME EXPIRED", flashScreen: true),
    ]

    /// Outline authoring version for this document.
    public var outlineFormat: Int = 1
    /// Slides owned by this `.program` file (shown under the `.program` playlist item).
    var programSlides: [Slide] = []

    public static func sundayMorningSample(calendar: Calendar = .current) -> ProgramDocumentModel {
        let talentJane = TalentProfile(
            fullName: "Dr. Jane Doe",
            titleOrRole: "Senior Vice President",
            organization: "Acme Corp"
        )
        let talentWorship = TalentProfile(fullName: "Worship Team", titleOrRole: "Music Ministry", organization: "")
        var doc = ProgramDocumentModel()
        doc.showTitle = "Sunday Morning Service"
        doc.talentDatabase = [talentJane, talentWorship]
        var opener = RundownBlock(itemNumber: "101", title: "Service Opener Video", segmentType: .opener, plannedDurationSeconds: 180)
        opener.videoCue = "Roll bumper — full program"
        opener.scriptBody = "Stand by for house lights down.\n\n[FADE TO BLACK]\n\nRoll opener package to air."

        var worship = RundownBlock(
            itemNumber: "102",
            title: "Worship — Songs 1 & 2",
            segmentType: .worship,
            plannedDurationSeconds: 720,
            assignedTalentIds: [talentWorship.id]
        )
        worship.audioCue = "Band — all mics live"
        worship.scriptBody = "Song 1: Build the room energy.\n\n[WAIT FOR CONGREGATION STANDING]\n\nSong 2: Transition on musical cue only."

        var keynote = RundownBlock(
            itemNumber: "103",
            title: "Welcome & Keynote",
            segmentType: .keynote,
            plannedDurationSeconds: 1500,
            assignedTalentIds: [talentJane.id]
        )
        keynote.audioCue = "Dr. Jane Doe — Lav 1"
        keynote.videoCue = "Cam 1 — wide stage"
        keynote.scriptBody = """
        Good morning — welcome to Sunday service.

        [WAIT 5 SECONDS]

        Today we celebrate our veterans and their families.

        Please welcome Dr. Jane Doe, Senior Vice President at Acme Corp.
        """

        var qa = RundownBlock(itemNumber: "104", title: "Q&A Discussion", segmentType: .qAndA, plannedDurationSeconds: 600)
        qa.scriptBody = "Moderator takes first question from aisle mic 2.\n\n[STAGE HAND — HANDHELD TO ROW 3]"

        var breakBlock = RundownBlock(itemNumber: "105", title: "Intermission Break", segmentType: .breakItem, plannedDurationSeconds: 600)
        breakBlock.scriptBody = "House lights to 50%. Hold bed music under lobby feed."

        doc.rundownBlocks = [opener, worship, keynote, qa, breakBlock]
        doc.talentDatabase[0].microphoneChannelName = "Lav 1"
        doc.talentDatabase[0].speakerNotes = "Keynote — lower third on walk-on"
        var start = doc.scheduledDate
        start = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: start) ?? start
        doc.hardStartTime = start
        doc.targetDurationSeconds = doc.rundownBlocks.reduce(0) { $0 + $1.plannedDurationSeconds }
        return doc
    }
}

extension ScreenDirection {
    private enum CodingKeys: String, CodingKey {
        case id, kind, label, url, rawKind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encode(url, forKey: .url)
        try container.encode(rawKind, forKey: .rawKind)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url)
        let kindToken = try container.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        if let known = ScreenDirectionKind(rawValue: kindToken) {
            kind = known
            rawKind = try container.decodeIfPresent(String.self, forKey: .rawKind)
        } else {
            kind = .unknown
            rawKind = try container.decodeIfPresent(String.self, forKey: .rawKind) ?? kindToken
        }
    }
}

extension LinkCue {
    private enum CodingKeys: String, CodingKey {
        case id, label, url, speakOnAir, autoTake
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(url, forKey: .url)
        try container.encode(speakOnAir, forKey: .speakOnAir)
        try container.encode(autoTake, forKey: .autoTake)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        speakOnAir = try container.decodeIfPresent(Bool.self, forKey: .speakOnAir) ?? false
        autoTake = try container.decodeIfPresent(Bool.self, forKey: .autoTake) ?? false
    }
}

extension RundownBlock {
    private enum CodingKeys: String, CodingKey {
        case id, itemNumber, title, segmentType, plannedDurationSeconds, isHardTimeLocked, hardStartTime
        case assignedTalentIds, linkedPlaylistId, linkedMediaBinItemID, linkedMediaFilePath
        case stageDisplayLayoutId, autoFireLowerThirdOnStart, customCueTriggers
        case actualStartTime, actualEndTime, isCompleted
        case scriptBody, audioCue, videoCue
        case outlineFormat, screenDirections, linkCues, referenceNotes, programSlideID, extensions
        case stopHere, promptPacing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        itemNumber = try container.decodeIfPresent(String.self, forKey: .itemNumber) ?? ""
        title = try container.decode(String.self, forKey: .title)
        segmentType = try container.decode(SegmentType.self, forKey: .segmentType)
        plannedDurationSeconds = try container.decode(TimeInterval.self, forKey: .plannedDurationSeconds)
        isHardTimeLocked = try container.decodeIfPresent(Bool.self, forKey: .isHardTimeLocked) ?? false
        hardStartTime = try container.decodeIfPresent(Date.self, forKey: .hardStartTime)
        assignedTalentIds = try container.decodeIfPresent([UUID].self, forKey: .assignedTalentIds) ?? []
        linkedPlaylistId = try container.decodeIfPresent(UUID.self, forKey: .linkedPlaylistId)
        linkedMediaBinItemID = try container.decodeIfPresent(UUID.self, forKey: .linkedMediaBinItemID)
        linkedMediaFilePath = try container.decodeIfPresent(String.self, forKey: .linkedMediaFilePath)
        stageDisplayLayoutId = try container.decodeIfPresent(String.self, forKey: .stageDisplayLayoutId)
        autoFireLowerThirdOnStart = try container.decodeIfPresent(Bool.self, forKey: .autoFireLowerThirdOnStart) ?? true
        customCueTriggers = try container.decodeIfPresent([StageCueTrigger].self, forKey: .customCueTriggers) ?? []
        actualStartTime = try container.decodeIfPresent(Date.self, forKey: .actualStartTime)
        actualEndTime = try container.decodeIfPresent(Date.self, forKey: .actualEndTime)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        scriptBody = try container.decodeIfPresent(String.self, forKey: .scriptBody) ?? ""
        audioCue = try container.decodeIfPresent(String.self, forKey: .audioCue) ?? ""
        videoCue = try container.decodeIfPresent(String.self, forKey: .videoCue) ?? ""
        outlineFormat = try container.decodeIfPresent(Int.self, forKey: .outlineFormat) ?? 1
        screenDirections = try container.decodeIfPresent([ScreenDirection].self, forKey: .screenDirections) ?? []
        linkCues = try container.decodeIfPresent([LinkCue].self, forKey: .linkCues) ?? []
        referenceNotes = try container.decodeIfPresent(String.self, forKey: .referenceNotes) ?? ""
        programSlideID = try container.decodeIfPresent(UUID.self, forKey: .programSlideID)
        extensions = try container.decodeIfPresent([String: String].self, forKey: .extensions) ?? [:]
        stopHere = try container.decodeIfPresent(Bool.self, forKey: .stopHere)
        promptPacing = (try? container.decodeIfPresent(PromptPacingMode.self, forKey: .promptPacing)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(itemNumber, forKey: .itemNumber)
        try container.encode(title, forKey: .title)
        try container.encode(segmentType, forKey: .segmentType)
        try container.encode(plannedDurationSeconds, forKey: .plannedDurationSeconds)
        try container.encode(isHardTimeLocked, forKey: .isHardTimeLocked)
        try container.encode(hardStartTime, forKey: .hardStartTime)
        try container.encode(assignedTalentIds, forKey: .assignedTalentIds)
        try container.encode(linkedPlaylistId, forKey: .linkedPlaylistId)
        try container.encode(linkedMediaBinItemID, forKey: .linkedMediaBinItemID)
        try container.encode(linkedMediaFilePath, forKey: .linkedMediaFilePath)
        try container.encode(stageDisplayLayoutId, forKey: .stageDisplayLayoutId)
        try container.encode(autoFireLowerThirdOnStart, forKey: .autoFireLowerThirdOnStart)
        try container.encode(customCueTriggers, forKey: .customCueTriggers)
        try container.encode(actualStartTime, forKey: .actualStartTime)
        try container.encode(actualEndTime, forKey: .actualEndTime)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encode(scriptBody, forKey: .scriptBody)
        try container.encode(audioCue, forKey: .audioCue)
        try container.encode(videoCue, forKey: .videoCue)
        try container.encode(outlineFormat, forKey: .outlineFormat)
        try container.encode(screenDirections, forKey: .screenDirections)
        try container.encode(linkCues, forKey: .linkCues)
        try container.encode(referenceNotes, forKey: .referenceNotes)
        try container.encodeIfPresent(programSlideID, forKey: .programSlideID)
        try container.encode(extensions, forKey: .extensions)
        try container.encodeIfPresent(stopHere, forKey: .stopHere)
        try container.encodeIfPresent(promptPacing, forKey: .promptPacing)
    }
}

extension ProgramDocumentModel {
    private enum CodingKeys: String, CodingKey {
        case id, showTitle, scheduledDate, hardStartTime, targetDurationSeconds
        case talentDatabase, rundownBlocks, runState, defaultStageCueTriggers, outlineFormat, programSlides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        showTitle = try container.decodeIfPresent(String.self, forKey: .showTitle) ?? "Sunday Morning Service"
        scheduledDate = try container.decodeIfPresent(Date.self, forKey: .scheduledDate) ?? Date()
        hardStartTime = try container.decodeIfPresent(Date.self, forKey: .hardStartTime) ?? Date()
        targetDurationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .targetDurationSeconds) ?? 3600
        talentDatabase = try container.decodeIfPresent([TalentProfile].self, forKey: .talentDatabase) ?? []
        rundownBlocks = try container.decodeIfPresent([RundownBlock].self, forKey: .rundownBlocks) ?? []
        runState = try container.decodeIfPresent(ProgramRunEngineState.self, forKey: .runState) ?? ProgramRunEngineState()
        defaultStageCueTriggers = try container.decodeIfPresent([StageCueTrigger].self, forKey: .defaultStageCueTriggers) ?? [
            StageCueTrigger(triggerOffsetSeconds: 60, stageMessage: "1 MINUTE REMAINING"),
            StageCueTrigger(triggerOffsetSeconds: 30, stageMessage: "WRAP UP", flashScreen: true),
            StageCueTrigger(triggerOffsetSeconds: 0, stageMessage: "TIME EXPIRED", flashScreen: true),
        ]
        outlineFormat = try container.decodeIfPresent(Int.self, forKey: .outlineFormat) ?? 1
        programSlides = try container.decodeIfPresent([Slide].self, forKey: .programSlides) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(showTitle, forKey: .showTitle)
        try container.encode(scheduledDate, forKey: .scheduledDate)
        try container.encode(hardStartTime, forKey: .hardStartTime)
        try container.encode(targetDurationSeconds, forKey: .targetDurationSeconds)
        try container.encode(talentDatabase, forKey: .talentDatabase)
        try container.encode(rundownBlocks, forKey: .rundownBlocks)
        try container.encode(runState, forKey: .runState)
        try container.encode(defaultStageCueTriggers, forKey: .defaultStageCueTriggers)
        try container.encode(outlineFormat, forKey: .outlineFormat)
        try container.encode(programSlides, forKey: .programSlides)
    }
}

public enum ProgramDocumentFormat {
    public static let jsonFilename = "program.json"
    public static let fileExtension = "program"
}
