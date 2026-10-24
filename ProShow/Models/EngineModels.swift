import Foundation

/// Eight-layer program stack, bottom (1) to top (8).
enum RenderLayer: Int, CaseIterable, Codable, Sendable, Identifiable {
    case screenColor = 1
    case videoInput = 2
    case media = 3
    case slide = 4
    case announcements = 5
    case props = 6
    case messages = 7
    case mask = 8

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .screenColor: "Screen"
        case .videoInput: "Video Input"
        case .media: "Media"
        case .slide: "Slide"
        case .announcements: "Announcements"
        case .props: "Props"
        case .messages: "Messages"
        case .mask: "Mask"
        }
    }

    var stackDomain: String {
        switch self {
        case .screenColor: "Base color"
        case .videoInput: "Camera / audio bed"
        case .media: "Persistent media"
        case .slide: "Slide text"
        case .announcements: "Announcements"
        case .props: "Props & graphics"
        case .messages: "Messages"
        case .mask: "Alert / mask"
        }
    }

    var systemImage: String {
        switch self {
        case .screenColor: "rectangle.fill"
        case .videoInput: "video.fill"
        case .media: "film"
        case .slide: "rectangle.on.rectangle"
        case .announcements: "megaphone.fill"
        case .props: "square.on.square"
        case .messages: "text.bubble.fill"
        case .mask: "circle.lefthalf.filled"
        }
    }

    var carriesAudio: Bool {
        switch self {
        case .videoInput, .media, .slide, .props: true
        default: false
        }
    }

    var apiName: String {
        switch self {
        case .screenColor: "screen_color"
        case .videoInput: "video_input"
        case .media: "media"
        case .slide: "slide"
        case .announcements: "announcements"
        case .props: "props"
        case .messages: "messages"
        case .mask: "mask"
        }
    }

    func hasContent(in stack: RenderStack) -> Bool {
        switch self {
        case .screenColor:
            stack.screenColorHex.uppercased() != "#000000"
        case .videoInput:
            stack.videoInput != nil
        case .media:
            stack.media != nil
        case .slide:
            !stack.slideCanvas.isEmpty || !stack.slideElements.isEmpty
        case .announcements:
            !(stack.announcement?.isEmpty ?? true)
        case .props:
            !stack.activeProps.isEmpty
        case .messages:
            !(stack.message?.isEmpty ?? true) || !stack.messages.isEmpty || stack.chatOverlay != nil
        case .mask:
            stack.maskEnabled
        }
    }

    func contentSummary(in stack: RenderStack) -> String {
        switch self {
        case .screenColor:
            stack.screenColorHex.uppercased()
        case .videoInput:
            stack.videoInput?.label ?? "Empty"
        case .media:
            stack.media?.title ?? "Empty"
        case .slide:
            if !stack.slideCanvas.isEmpty { "\(stack.slideCanvas.count) objects" }
            else if let first = stack.slideElements.first { first.text }
            else { "Empty" }
        case .announcements:
            stack.announcement ?? "Empty"
        case .props:
            stack.activeProps.isEmpty ? "Empty" : stack.activeProps.joined(separator: ", ")
        case .messages:
            stack.message ?? "Empty"
        case .mask:
            stack.maskEnabled ? stack.mask.kind : "Off"
        }
    }

    static func parse(_ name: String) -> RenderLayer? {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        switch key {
        case "video", "cam", "camera", "videoinput": return .videoInput
        default: break
        }
        return allCases.first { $0.apiName == key || String($0.rawValue) == key }
    }
}

struct SlideElement: Hashable, Codable, Sendable {
    var text: String
    var alignment: String

    init(text: String, alignment: String = "center") {
        self.text = text
        self.alignment = alignment
    }

    static func from(slide: Slide) -> [SlideElement] {
        guard !slide.isBlank, !slide.isProgramMediaCue else { return [] }
        let canvasText = slide.canvas.filter(\.isTextLike).filter(\.visibleOnAudience).sorted { $0.transform.y < $1.transform.y }
        if !canvasText.isEmpty {
            return canvasText.map {
                SlideElement(text: StageDisplayEngine.stripChordTokens($0.displayText), alignment: $0.textLayout.horizontalAlign.rawValue)
            }
        }
        if !slide.elements.isEmpty {
            return slide.elements.map {
                SlideElement(text: StageDisplayEngine.stripChordTokens($0.text), alignment: $0.alignment)
            }
        }
        if slide.hasGraphicCanvas { return [] }
        let body = StageDisplayEngine.stripChordTokens(slide.displayText)
        guard !body.isEmpty else { return [] }
        return [SlideElement(text: body, alignment: slide.alignment)]
    }
}

struct PropCanvas: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var objects: [CanvasObject]
    var canvasWidth: Double
    var canvasHeight: Double
    var buildStartedAt: Date?
    var buildClearStartedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        objects: [CanvasObject],
        canvasWidth: Double = 3840,
        canvasHeight: Double = 2160,
        buildStartedAt: Date? = nil,
        buildClearStartedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.objects = objects
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.buildStartedAt = buildStartedAt
        self.buildClearStartedAt = buildClearStartedAt
    }

    var isClearing: Bool { buildClearStartedAt != nil }

    func buildClock(frame: Int = 0) -> BuildClock {
        BuildClock(
            startedAt: buildClearStartedAt ?? buildStartedAt,
            unlockedClickOrder: .max,
            clickTimes: [:],
            autoplayClicks: true,
            frame: frame,
            isLeaving: isClearing
        )
    }

    var buildPhases: Set<BuildPhase> {
        isClearing ? [.buildOut] : [.buildIn, .action]
    }
}

struct MediaAction: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var tintHex: String
    var duration: String?
    var isImage: Bool
    var filePath: String?
    var placeholderLetter: String? = nil
    var audioMuted: Bool? = nil
    var forceReset: Bool = false
    var clearsLayer: Bool = false
    /// Hold: keeps playing across slides until cleared or replaced by different media.
    var hold: Bool = false

    init(
        id: UUID,
        title: String,
        tintHex: String,
        duration: String? = nil,
        isImage: Bool,
        filePath: String? = nil,
        placeholderLetter: String? = nil,
        audioMuted: Bool? = nil,
        forceReset: Bool = false,
        clearsLayer: Bool = false,
        hold: Bool = false
    ) {
        self.id = id
        self.title = title
        self.tintHex = tintHex
        self.duration = duration
        self.isImage = isImage
        self.filePath = filePath
        self.placeholderLetter = placeholderLetter
        self.audioMuted = audioMuted
        self.forceReset = forceReset
        self.clearsLayer = clearsLayer
        self.hold = hold
    }

    static func clearLayerCue() -> MediaAction {
        MediaAction(id: UUID(), title: "Clear Media", tintHex: "#000000", isImage: true, clearsLayer: true)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, tintHex, duration, isImage, filePath, placeholderLetter, audioMuted, forceReset, clearsLayer, hold
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        tintHex = try container.decode(String.self, forKey: .tintHex)
        duration = try container.decodeIfPresent(String.self, forKey: .duration)
        isImage = try container.decode(Bool.self, forKey: .isImage)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        placeholderLetter = try container.decodeIfPresent(String.self, forKey: .placeholderLetter)
        audioMuted = try container.decodeIfPresent(Bool.self, forKey: .audioMuted)
        forceReset = try container.decodeIfPresent(Bool.self, forKey: .forceReset) ?? false
        clearsLayer = try container.decodeIfPresent(Bool.self, forKey: .clearsLayer) ?? false
        hold = try container.decodeIfPresent(Bool.self, forKey: .hold) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(tintHex, forKey: .tintHex)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encode(isImage, forKey: .isImage)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(placeholderLetter, forKey: .placeholderLetter)
        try container.encodeIfPresent(audioMuted, forKey: .audioMuted)
        if forceReset { try container.encode(forceReset, forKey: .forceReset) }
        if clearsLayer { try container.encode(clearsLayer, forKey: .clearsLayer) }
        if hold { try container.encode(hold, forKey: .hold) }
    }

    var isAudioMuted: Bool { audioMuted == true }

    var fileURL: URL? {
        resolvedFileURL(projectRoot: nil)
    }

    func resolvedFileURL(projectRoot: URL?) -> URL? {
        MediaPath.resolve(filePath, projectRoot: projectRoot)
    }
}

enum VideoInputKind: String, Hashable, Codable, Sendable {
    case camera
    case ndi
    case rtsp
    case captureCard
    case screenShare
    case continuity
    case webrtc
}

struct VideoInputSource: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var label: String
    var kind: VideoInputKind
    var endpoint: String?

    init(id: UUID, label: String, kind: VideoInputKind = .camera, endpoint: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.endpoint = endpoint
    }
}

struct AudioTrack: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var title: String
}

struct MacroCommand: Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case clearLayer
        case triggerSlide
        case setLook
    }

    var kind: Kind
    var layer: RenderLayer?
    var slideIndex: Int?
    var lookName: String?
}

struct MacroScript: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var commands: [MacroCommand]
}

struct AudienceLookConfig: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var audienceLayers: [RenderLayer]
    var stageLayers: [RenderLayer]
    var alphaKeySlideOnly: Bool

    static let fullStack = AudienceLookConfig(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA1")!,
        name: "Full",
        audienceLayers: RenderLayer.allCases,
        stageLayers: RenderLayer.allCases,
        alphaKeySlideOnly: false
    )

    static let slideAndMedia = AudienceLookConfig(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA2")!,
        name: "Slide + Media",
        audienceLayers: [.screenColor, .media, .slide, .props, .messages, .mask],
        stageLayers: RenderLayer.allCases,
        alphaKeySlideOnly: false
    )

    static let alphaKey = AudienceLookConfig(
        id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAA3")!,
        name: "Slide Alpha",
        audienceLayers: [.slide],
        stageLayers: [.screenColor, .slide, .messages],
        alphaKeySlideOnly: true
    )
}

struct StageLookConfig: Hashable, Codable, Sendable {
    var showCurrent: Bool
    var showNext: Bool
    var showNotes: Bool
    var showClock: Bool

    static let standard = StageLookConfig(
        showCurrent: true,
        showNext: true,
        showNotes: true,
        showClock: true
    )
}

struct CueLayers: Hashable, Codable, Sendable {
    var slideText: [SlideElement]?
    var slideCanvas: [CanvasObject]? = nil
    var canvasWidth: Double? = nil
    var canvasHeight: Double? = nil
    var slideBackgroundEnabled: Bool? = nil
    var slideBackgroundHex: String? = nil
    var mediaAction: MediaAction?
    var videoInputAction: VideoInputSource?
    var audioAction: AudioTrack?
    var macroAction: [MacroScript]?
    var lookAction: AudienceLookConfig?
}

/// Program trigger contract — one cue fires independent layer actions.
struct OutputCue: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var presentationId: UUID
    var slideIndex: Int
    var layers: CueLayers
}

struct OutputTimer: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var seconds: Int
}

struct OutputMessage: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var text: String
}

struct MaskPath: Hashable, Codable, Sendable {
    var enabled: Bool
    var kind: String
}

enum OutputScreenRole: String, Hashable, Codable, Sendable {
    case audience
    case stage
}

struct OutputScreen: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var lookName: String
    var role: OutputScreenRole
    /// Optional theme variant override for slide layer on this output.
    var themeVariantID: UUID?

    init(id: String, name: String, lookName: String, role: OutputScreenRole = .audience, themeVariantID: UUID? = nil) {
        self.id = id
        self.name = name
        self.lookName = lookName
        self.role = role
        self.themeVariantID = themeVariantID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lookName = try container.decode(String.self, forKey: .lookName)
        if let decoded = try container.decodeIfPresent(OutputScreenRole.self, forKey: .role) {
            role = decoded
        } else {
            role = (id.contains("stage") || lookName.lowercased().contains("stage")) ? .stage : .audience
        }
        themeVariantID = try container.decodeIfPresent(UUID.self, forKey: .themeVariantID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(lookName, forKey: .lookName)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(themeVariantID, forKey: .themeVariantID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, lookName, role, themeVariantID
    }
}

struct RenderStack: Hashable, Codable, Sendable {
    var screenColorHex: String
    var audioMuted: Bool = false
    var mutedAudioLayers: Set<Int>? = nil
    var videoInput: VideoInputSource?
    var media: MediaAction?
    var slideElements: [SlideElement]
    var slideCanvas: [CanvasObject] = []
    var slideCanvasWidth: Double = 3840
    var slideCanvasHeight: Double = 2160
    var slideBackgroundEnabled: Bool = true
    var slideBackgroundHex: String = "#000000"
    var announcement: String?
    var activeProps: [String]
    var message: String?
    var audio: AudioTrack?
    var messages: [OutputMessage]
    var timers: [OutputTimer]
    var mask: MaskPath
    var maskEnabled: Bool
    var cleared: Set<Int>
    var look: AudienceLookConfig
    var stageLook: StageLookConfig
    var outputScreens: [OutputScreen]
    var pipInput: VideoInputSource? = nil
    var pipBounds: CanvasRect = .pipLowerRight
    var primaryBounds: CanvasRect = .fullFrame
    var chatOverlay: ChatOverlayCard? = nil

    static let idle = RenderStack(
        screenColorHex: "#000000",
        audioMuted: false,
        videoInput: nil,
        media: nil,
        slideElements: [],
        announcement: nil,
        activeProps: [],
        message: nil,
        audio: nil,
        messages: [],
        timers: [],
        mask: MaskPath(enabled: false, kind: "vignette"),
        maskEnabled: false,
        cleared: [],
        look: .fullStack,
        stageLook: .standard,
        outputScreens: [
            OutputScreen(id: "screen-1", name: "Screen 1", lookName: AudienceLookConfig.fullStack.name, role: .audience),
            OutputScreen(id: "screen-2", name: "Stage", lookName: "Stage", role: .stage),
        ]
    )

    func isCleared(_ layer: RenderLayer) -> Bool {
        cleared.contains(layer.rawValue)
    }

    func isAudioMuted(_ layer: RenderLayer) -> Bool {
        mutedAudioLayers?.contains(layer.rawValue) == true
    }

    func isVisible(_ layer: RenderLayer, onStage: Bool) -> Bool {
        guard !isCleared(layer) else { return false }
        let allowed = onStage ? look.stageLayers : look.audienceLayers
        return allowed.contains(layer)
    }

    var visibleAudienceLayers: [Int] {
        RenderLayer.allCases.compactMap { isVisible($0, onStage: false) ? $0.rawValue : nil }
    }

    /// Layer 3 is an independent stack slot. It paints whenever it has media,
    /// including under transparent lyric slides. Opaque Layer 4 fills cover it.
    func drawsProgramMediaBackdrop(onStage: Bool) -> Bool {
        guard isVisible(.media, onStage: onStage), let media, !media.clearsLayer else { return false }
        return true
    }
}

/// When the audience look hides layer 2, slide canvas live regions still need the active program input.
/// A `.program` video well is the camera itself: it must paint that input even while layer 2 is up,
/// or the full-frame black shape covers the picture the thumbnail already shows.
enum ProgramLiveVideoRouting {
    static func canvasUsesProgramInput(
        assigned: AssignedMediaSource?,
        objectKind: CanvasObjectKind?,
        programInput: VideoInputSource?,
        showsProgramVideoLayer: Bool,
        wellsKeepOwnDevice: Bool = false
    ) -> Bool {
        guard let programInput else { return false }
        if wellsKeepOwnDevice {
            // Previews (editor, thumbnails, Phone monitor): resolve like the encode does. A lettered
            // placeholder with no source stays an empty slot, a well with its own camera or display keeps
            // it, and only unassigned wells or wells on the same device share the slide's input.
            // Before, one slide input was painted into every live well.
            if assigned?.sourceType == .placeholderSlot { return false }
            if hasOwnLiveDevice(assigned) {
                return programInputFeedsVideoWell(assigned: assigned, programInput: programInput)
            }
            return objectKind == .videoInput
        }
        if objectKind == .videoInput, programInputFeedsVideoWell(assigned: assigned, programInput: programInput) {
            return true
        }
        guard !showsProgramVideoLayer else { return false }
        return liveCanvasAssignment(assigned: assigned, objectKind: objectKind)
    }

    static func hasOwnLiveDevice(_ assigned: AssignedMediaSource?) -> Bool {
        switch assigned?.sourceType {
        case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .rendezvousGuest, .srtStream:
            return true
        default:
            return false
        }
    }

    /// Unassigned video wells, and wells aimed at the same device as the program input, share that picture.
    /// A well aimed at a different camera or display keeps its own assignment.
    static func programInputFeedsVideoWell(
        assigned: AssignedMediaSource?,
        programInput: VideoInputSource
    ) -> Bool {
        guard let assigned else { return true }
        switch assigned.sourceType {
        case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .rendezvousGuest, .srtStream:
            break
        default:
            return true
        }
        let connection = assigned.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint = programInput.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if connection.isEmpty || endpoint.isEmpty { return true }
        if connection == endpoint { return true }
        if let left = CameraIdentity.avfUniqueID(from: connection),
           let right = CameraIdentity.avfUniqueID(from: endpoint),
           left == right {
            return true
        }
        return false
    }

    /// Program camera stays on the video-input layer. It must not replace a screen share or other assigned media.
    static func broadcastCanvasUsesProgramVideo(
        assigned: AssignedMediaSource?,
        objectKind: CanvasObjectKind?,
        programInput: VideoInputSource?
    ) -> Bool {
        _ = assigned
        _ = objectKind
        _ = programInput
        return false
    }

    private static func liveCanvasAssignment(
        assigned: AssignedMediaSource?,
        objectKind: CanvasObjectKind?
    ) -> Bool {
        switch assigned?.sourceType {
        case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .rendezvousGuest, .srtStream:
            return true
        default:
            return objectKind == .videoInput
        }
    }
}

struct LayerSlotState: Identifiable, Hashable, Sendable {
    var layer: RenderLayer
    var isLocked: Bool
    var isCleared: Bool
    var isActive: Bool
    var title: String
    var detail: String
    var playhead: TimeInterval?
    var duration: TimeInterval?
    var isPlaying: Bool

    var id: Int { layer.rawValue }
}

struct RtmpStreamConfig: Hashable, Codable, Sendable {
    var sourceDisplayId: String
    var destinationURL: String
    var streamKey: String
    var codec: String
    var width: Int
    var height: Int
    var framerate: Int
    var bitrateKbps: Int
    var keyframeIntervalSec: Int
    var audioCodec: String
    var audioBitrateKbps: Int
    var sampleRateHz: Int
    var channels: Int
    var useCloudRelay: Bool
    var relayDestinations: [RelayDestination]

    static let `default` = RtmpStreamConfig(
        sourceDisplayId: "Audience_Screen_1",
        destinationURL: "rtmps://relay.local/live",
        streamKey: "",
        codec: "H264",
        width: 1920,
        height: 1080,
        framerate: 30,
        bitrateKbps: 5500,
        keyframeIntervalSec: 2,
        audioCodec: "AAC",
        audioBitrateKbps: 128,
        sampleRateHz: 48000,
        channels: 2,
        useCloudRelay: true,
        relayDestinations: []
    )

    var outboundURLs: [String] {
        if useCloudRelay, !relayDestinations.isEmpty {
            return relayDestinations.map(\.url).filter { !$0.isEmpty }
        }
        let primary = destinationURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return primary.isEmpty ? [] : [primary]
    }
}

struct RelayDestination: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var url: String
    var streamKey: String

    init(id: UUID = UUID(), name: String, url: String, streamKey: String = "") {
        self.id = id
        self.name = name
        self.url = url
        self.streamKey = streamKey
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, streamKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        streamKey = try container.decodeIfPresent(String.self, forKey: .streamKey) ?? ""
    }
}

enum StreamSessionState: String, Codable, Sendable {
    case idle
    case starting
    case live
    case stopping
    case failed
}

struct SearchHit: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case library, playlist, bible, media, presentation
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String
}
