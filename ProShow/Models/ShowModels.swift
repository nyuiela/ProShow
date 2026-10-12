import Foundation

/// Unique identifier for show graph nodes.
typealias ShowID = UUID
typealias SlideID = UUID
typealias GroupID = UUID
typealias PlaylistID = UUID

/// A worship / presentation show: named collection of slide groups.
struct Show: Identifiable, Hashable, Codable, Sendable {
    var id: ShowID
    var name: String
    var createdAt: Date
    var groups: [SlideGroup]
    var notes: String

    init(
        id: ShowID = UUID(),
        name: String,
        createdAt: Date = .now,
        groups: [SlideGroup] = [],
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.groups = groups
        self.notes = notes
    }

    var allSlides: [Slide] {
        groups.flatMap(\.slides)
    }

    func slide(id: SlideID) -> Slide? {
        allSlides.first { $0.id == id }
    }

    func indexOfSlide(id: SlideID) -> Int? {
        allSlides.firstIndex { $0.id == id }
    }

    mutating func updateSlide(id: SlideID, _ body: (inout Slide) -> Void) {
        for groupIndex in groups.indices {
            if let slideIndex = groups[groupIndex].slides.firstIndex(where: { $0.id == id }) {
                body(&groups[groupIndex].slides[slideIndex])
                return
            }
        }
    }
}

/// A labeled sequence of slides (Verse, Chorus, Bridge, Title, etc.).
struct SlideGroup: Identifiable, Hashable, Codable, Sendable {
    var id: GroupID
    var name: String
    var colorHex: String
    var slides: [Slide]

    init(
        id: GroupID = UUID(),
        name: String,
        colorHex: String = "#5B8DEF",
        slides: [Slide] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.slides = slides
    }
}

struct SlideCanvasElement: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var text: String
    var alignment: String
    var x: Double
    var y: Double

    init(id: UUID = UUID(), text: String, alignment: String = "center", x: Double = 0.5, y: Double = 0.5) {
        self.id = id
        self.text = text
        self.alignment = alignment
        self.x = x
        self.y = y
    }
}

/// One cue / slide shown to the audience.
struct Slide: Identifiable, Hashable, Codable, Sendable {
    var id: SlideID
    var title: String
    var lines: [String]
    var notes: String
    var isBlank: Bool
    var alignment: String
    var elements: [SlideCanvasElement]
    var canvas: [CanvasObject]
    var isDisabled: Bool
    var theme: String
    var themeVariantID: UUID?
    var themeApplication: ThemeApplicationMode
    var transition: String
    var hotKey: String
    var label: String
    var actions: [String]
    var nextTimer: String
    var backgroundEnabled: Bool
    var backgroundHex: String
    var mediaAction: MediaAction?
    var forceResetMedia: Bool
    /// Additional artboards on this slide. Empty until a canvas is added or the main canvas is moved.
    var editorCanvases: [EditorCanvasFrame]

    init(
        id: SlideID = UUID(),
        title: String = "",
        lines: [String] = [],
        notes: String = "",
        isBlank: Bool = false,
        alignment: String = "center",
        elements: [SlideCanvasElement] = [],
        canvas: [CanvasObject] = [],
        isDisabled: Bool = false,
        theme: String = "Default",
        themeVariantID: UUID? = nil,
        themeApplication: ThemeApplicationMode = .auto,
        transition: String = "Cut",
        hotKey: String = "",
        label: String = "",
        actions: [String] = [],
        nextTimer: String = "",
        backgroundEnabled: Bool = true,
        backgroundHex: String = "#000000",
        mediaAction: MediaAction? = nil,
        forceResetMedia: Bool = false,
        editorCanvases: [EditorCanvasFrame] = []
    ) {
        self.id = id
        self.title = title
        self.lines = lines
        self.notes = notes
        self.isBlank = isBlank
        self.alignment = alignment
        self.elements = elements
        self.canvas = canvas
        self.isDisabled = isDisabled
        self.theme = theme
        self.themeVariantID = themeVariantID
        self.themeApplication = themeApplication
        self.transition = transition
        self.hotKey = hotKey
        self.label = label
        self.actions = actions
        self.nextTimer = nextTimer
        self.backgroundEnabled = backgroundEnabled
        self.backgroundHex = backgroundHex
        self.mediaAction = mediaAction
        self.forceResetMedia = forceResetMedia
        self.editorCanvases = editorCanvases
    }

    enum CodingKeys: String, CodingKey {
        case id, title, lines, notes, isBlank, alignment, elements, canvas
        case isDisabled, theme, themeVariantID, themeApplication, transition, hotKey, label, actions, nextTimer
        case backgroundEnabled, backgroundHex, mediaAction, forceResetMedia, editorCanvases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SlideID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isBlank = try container.decodeIfPresent(Bool.self, forKey: .isBlank) ?? false
        alignment = try container.decodeIfPresent(String.self, forKey: .alignment) ?? "center"
        elements = try container.decodeIfPresent([SlideCanvasElement].self, forKey: .elements) ?? []
        canvas = try container.decodeIfPresent([CanvasObject].self, forKey: .canvas) ?? []
        isDisabled = try container.decodeIfPresent(Bool.self, forKey: .isDisabled) ?? false
        theme = try container.decodeIfPresent(String.self, forKey: .theme) ?? "Default"
        themeVariantID = try container.decodeIfPresent(UUID.self, forKey: .themeVariantID)
        themeApplication = try container.decodeIfPresent(ThemeApplicationMode.self, forKey: .themeApplication) ?? .auto
        transition = try container.decodeIfPresent(String.self, forKey: .transition) ?? "Cut"
        hotKey = try container.decodeIfPresent(String.self, forKey: .hotKey) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
        nextTimer = try container.decodeIfPresent(String.self, forKey: .nextTimer) ?? ""
        backgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true
        backgroundHex = try container.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#000000"
        mediaAction = try container.decodeIfPresent(MediaAction.self, forKey: .mediaAction)
        forceResetMedia = try container.decodeIfPresent(Bool.self, forKey: .forceResetMedia) ?? false
        editorCanvases = try container.decodeIfPresent([EditorCanvasFrame].self, forKey: .editorCanvases) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(lines, forKey: .lines)
        try container.encode(notes, forKey: .notes)
        try container.encode(isBlank, forKey: .isBlank)
        try container.encode(alignment, forKey: .alignment)
        try container.encode(elements, forKey: .elements)
        try container.encode(canvas, forKey: .canvas)
        try container.encode(isDisabled, forKey: .isDisabled)
        try container.encode(theme, forKey: .theme)
        try container.encodeIfPresent(themeVariantID, forKey: .themeVariantID)
        try container.encode(themeApplication, forKey: .themeApplication)
        try container.encode(transition, forKey: .transition)
        try container.encode(hotKey, forKey: .hotKey)
        try container.encode(label, forKey: .label)
        try container.encode(actions, forKey: .actions)
        try container.encode(nextTimer, forKey: .nextTimer)
        try container.encode(backgroundEnabled, forKey: .backgroundEnabled)
        try container.encode(backgroundHex, forKey: .backgroundHex)
        try container.encodeIfPresent(mediaAction, forKey: .mediaAction)
        try container.encode(forceResetMedia, forKey: .forceResetMedia)
        if !editorCanvases.isEmpty {
            try container.encode(editorCanvases, forKey: .editorCanvases)
        }
    }

    func copyAsNew() -> Slide {
        var copy = self
        copy.id = UUID()
        return copy
    }

    var paintsOpaqueBackground: Bool {
        backgroundEnabled && !isBlank
    }

    func audienceCanvas(
        width: Double = CanvasConfig.width,
        height: Double = CanvasConfig.height,
        variantOverrideID: UUID? = nil,
        applicationOverride: ThemeApplicationMode? = nil
    ) -> [CanvasObject] {
        let sources: [CanvasObject]
        if let variantOverrideID,
           let variant = ThemeVariantRegistry.variant(id: variantOverrideID) {
            var mode = applicationOverride ?? themeApplication
            if mode == .native { mode = .replace }
            if let resolved = ThemeResolver.resolvedCanvas(for: self, variant: variant, application: mode) {
                sources = resolved
            } else {
                sources = resolvedCanvasBeforeAudienceFilter()
            }
        } else {
            sources = resolvedCanvasBeforeAudienceFilter()
        }
        return sources.filter { object in
            guard object.isFullBleedBackground(canvasWidth: width, canvasHeight: height) else { return true }
            if object.kind.isBrowserLike { return true }
            if object.kind == .videoInput { return true }
            if object.rendersLiveVideoInputOnCanvas { return true }
            if AssignedMediaSource.pathLooksLikeVideo(object.fill.imageURI) { return true }
            return paintsOpaqueBackground
        }
    }

    var hasGraphicCanvas: Bool {
        canvas.contains { !$0.isTextLike && $0.visibleOnAudience }
    }

    /// Transparent slide with linked Layer 3 media — editor draws video/image under canvas objects.
    var showsLinkedProgramMediaUnderCanvas: Bool {
        guard let mediaAction, !mediaAction.clearsLayer else { return false }
        return !paintsOpaqueBackground
    }

    /// Media bin / playlist cue: drives Layer 3 only — no lyrics or slide fill over the video.
    var isProgramMediaCue: Bool {
        guard let mediaAction, !mediaAction.clearsLayer else { return false }
        if isBlank { return false }
        let hasLines = lines.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasLines { return false }
        if hasGraphicCanvas { return false }
        if canvas.contains(where: { $0.isTextLike && $0.visibleOnAudience }) { return false }
        return true
    }

    var displayText: String {
        if isBlank { return "" }
        if isProgramMediaCue { return "" }
        let body = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !body.isEmpty { return body.joined(separator: "\n") }
        if hasGraphicCanvas { return "" }
        return title
    }

    var previewSummary: String {
        if isBlank { return "(Blank)" }
        if let first = lines.first(where: { !$0.isEmpty }) { return first }
        if hasGraphicCanvas {
            if !label.isEmpty { return label }
            if let action = actions.first {
                if action.hasPrefix("Placeholder") { return "Placeholder" }
                if action.hasPrefix("Color") { return "Color" }
                if action.hasPrefix("Shot") { return "Shot" }
                if action.hasPrefix("Media") { return "Media" }
            }
            return "Media"
        }
        if !title.isEmpty { return title }
        return "(Empty)"
    }
}

/// Ordered rundown of shows / items for a service.
struct Playlist: Identifiable, Hashable, Codable, Sendable {
    var id: PlaylistID
    var name: String
    /// Unused label kept so older files still open. Not shown, and not required.
    var typeName: String
    var items: [PlaylistItem]

    init(
        id: PlaylistID = UUID(),
        name: String,
        typeName: String = "",
        items: [PlaylistItem] = []
    ) {
        self.id = id
        self.name = name
        self.typeName = typeName
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case id, name, typeName, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(PlaylistID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Playlist"
        typeName = try container.decodeIfPresent(String.self, forKey: .typeName) ?? ""
        items = try container.decodeIfPresent([PlaylistItem].self, forKey: .items) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(typeName, forKey: .typeName)
        try container.encode(items, forKey: .items)
    }
}

enum PlaylistItemKind: String, Hashable, Codable, Sendable {
    case show
    case spacer
    case note
}

/// One row in a service order / playlist.
struct PlaylistItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var kind: PlaylistItemKind
    var title: String
    var showID: ShowID?
    var detail: String

    init(
        id: UUID = UUID(),
        kind: PlaylistItemKind,
        title: String,
        showID: ShowID? = nil,
        detail: String = ""
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.showID = showID
        self.detail = detail
    }
}

/// Convenience alias matching ProPresenter / FreeShow vocabulary.
typealias ServiceOrder = Playlist

/// Drag token for slides, media, shots, and placeholders on the cue grid.
struct WorkspaceDragPayload: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case slide
        case media
        case shot
        case placeholder
        case color
    }

    var kind: Kind
    var id: String
    var name: String
    var extra: String

    init(kind: Kind, id: String, name: String, extra: String = "") {
        self.kind = kind
        self.id = id
        self.name = name
        self.extra = extra
    }

    var token: String {
        [kind.rawValue, id, name.replacingOccurrences(of: "|", with: "/"), extra]
            .joined(separator: "|")
    }

    static func parse(_ token: String) -> WorkspaceDragPayload? {
        let parts = token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, let kind = Kind(rawValue: parts[0]) else { return nil }
        return WorkspaceDragPayload(
            kind: kind,
            id: parts[1],
            name: parts[2],
            extra: parts.count > 3 ? parts[3...].joined(separator: "|") : ""
        )
    }

    static func slide(id: SlideID, title: String) -> WorkspaceDragPayload {
        WorkspaceDragPayload(kind: .slide, id: id.uuidString, name: title)
    }

    static func media(_ item: MediaBinItem) -> WorkspaceDragPayload {
        if case .placeholder = item.kind {
            return WorkspaceDragPayload(kind: .placeholder, id: item.id.uuidString, name: item.title, extra: item.tintHex)
        }
        return WorkspaceDragPayload(kind: .media, id: item.id.uuidString, name: item.title, extra: item.tintHex)
    }

    static func shot(_ shot: LayerShot) -> WorkspaceDragPayload {
        WorkspaceDragPayload(kind: .shot, id: shot.id.uuidString, name: shot.name, extra: shot.source.tintHex ?? "")
    }
}

enum WorkspaceDragPasteboard {
    static var active: WorkspaceDragPayload?
}

enum DeskDropRole: String, Sendable {
    case slides
    case editor
    case mediaBin
    case ignore
}
