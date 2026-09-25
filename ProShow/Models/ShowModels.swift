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

/// One cue / slide shown to the audience.
struct Slide: Identifiable, Hashable, Codable, Sendable {
    var id: SlideID
    var title: String
    var lines: [String]
    var notes: String
    var isBlank: Bool

    init(
        id: SlideID = UUID(),
        title: String = "",
        lines: [String] = [],
        notes: String = "",
        isBlank: Bool = false
    ) {
        self.id = id
        self.title = title
        self.lines = lines
        self.notes = notes
        self.isBlank = isBlank
    }

    var displayText: String {
        if isBlank { return "" }
        let body = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if body.isEmpty { return title }
        return body.joined(separator: "\n")
    }

    var previewSummary: String {
        if isBlank { return "(Blank)" }
        if let first = lines.first(where: { !$0.isEmpty }) { return first }
        if !title.isEmpty { return title }
        return "(Empty)"
    }
}

/// Ordered rundown of shows / items for a service.
struct Playlist: Identifiable, Hashable, Codable, Sendable {
    var id: PlaylistID
    var name: String
    var items: [PlaylistItem]

    init(
        id: PlaylistID = UUID(),
        name: String,
        items: [PlaylistItem] = []
    ) {
        self.id = id
        self.name = name
        self.items = items
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
