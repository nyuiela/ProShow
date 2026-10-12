import Foundation

/// Top-level library bucket that owns ordered playlists (sidebar hierarchy root).
struct ContentLibrary: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    /// Unused label kept so older files still open. Not shown, and not required.
    var typeName: String
    var playlistIDs: [UUID]

    init(id: UUID = UUID(), name: String, typeName: String = "", playlistIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.typeName = typeName
        self.playlistIDs = playlistIDs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, typeName, playlistIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Library"
        typeName = try container.decodeIfPresent(String.self, forKey: .typeName) ?? ""
        playlistIDs = try container.decodeIfPresent([UUID].self, forKey: .playlistIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(typeName, forKey: .typeName)
        try container.encode(playlistIDs, forKey: .playlistIDs)
    }
}

/// Sidebar library / playlist / media navigation stubs for the operator desk chrome.
struct LibraryFolder: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var systemImage: String
    var children: [LibraryFolder]
}

struct LibraryShowItem: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String
    var subtitle: String
    var isActive: Bool
    var showID: ShowID?
}

struct MediaBinItem: Identifiable, Hashable, Codable {
    enum Kind: Hashable, Codable {
        case video(duration: String)
        case audio(duration: String)
        case image
        case camera(label: String)
        case microphone(label: String)
        case placeholder
    }

    var id = UUID()
    var title: String
    var kind: Kind
    var tintHex: String
    var source: MediaSourceID
    var filePath: String?
    var collectionID: UUID?
    var transition: String
    var behavior: String
    var scaling: String
    var alphaType: String
    var playbackBehavior: String
    var loopBehavior: String
    var endBehavior: String
    var nextCue: String

    init(
        id: UUID = UUID(),
        title: String,
        kind: Kind,
        tintHex: String,
        source: MediaSourceID,
        filePath: String? = nil,
        collectionID: UUID? = nil,
        transition: String = "Cut",
        behavior: String = "Normal",
        scaling: String = "Fill",
        alphaType: String = "None",
        playbackBehavior: String = "Play",
        loopBehavior: String = "Loop",
        endBehavior: String = "Stop",
        nextCue: String = "None"
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.tintHex = tintHex
        self.source = source
        self.filePath = filePath
        self.collectionID = collectionID
        self.transition = transition
        self.behavior = behavior
        self.scaling = scaling
        self.alphaType = alphaType
        self.playbackBehavior = playbackBehavior
        self.loopBehavior = loopBehavior
        self.endBehavior = endBehavior
        self.nextCue = nextCue
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, tintHex, source, filePath, collectionID
        case transition, behavior, scaling, alphaType
        case playbackBehavior, loopBehavior, endBehavior, nextCue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(Kind.self, forKey: .kind)
        tintHex = try container.decodeIfPresent(String.self, forKey: .tintHex) ?? "#333333"
        source = try container.decodeIfPresent(MediaSourceID.self, forKey: .source) ?? .resources
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        collectionID = try container.decodeIfPresent(UUID.self, forKey: .collectionID)
        transition = try container.decodeIfPresent(String.self, forKey: .transition) ?? "Cut"
        behavior = try container.decodeIfPresent(String.self, forKey: .behavior) ?? "Normal"
        scaling = try container.decodeIfPresent(String.self, forKey: .scaling) ?? "Fill"
        alphaType = try container.decodeIfPresent(String.self, forKey: .alphaType) ?? "None"
        playbackBehavior = try container.decodeIfPresent(String.self, forKey: .playbackBehavior) ?? "Play"
        loopBehavior = try container.decodeIfPresent(String.self, forKey: .loopBehavior) ?? "Loop"
        endBehavior = try container.decodeIfPresent(String.self, forKey: .endBehavior) ?? "Stop"
        nextCue = try container.decodeIfPresent(String.self, forKey: .nextCue) ?? "None"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(tintHex, forKey: .tintHex)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(collectionID, forKey: .collectionID)
        try container.encode(transition, forKey: .transition)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(scaling, forKey: .scaling)
        try container.encode(alphaType, forKey: .alphaType)
        try container.encode(playbackBehavior, forKey: .playbackBehavior)
        try container.encode(loopBehavior, forKey: .loopBehavior)
        try container.encode(endBehavior, forKey: .endBehavior)
        try container.encode(nextCue, forKey: .nextCue)
    }

    func copyAsNew() -> MediaBinItem {
        var copy = self
        copy.id = UUID()
        return copy
    }

    var kindLabel: String {
        switch kind {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .placeholder: "Placeholder"
        }
    }

    /// Time-based transport chrome (waveform, timecode) — not stills or live inputs.
    var showsPlaybackTransport: Bool {
        switch kind {
        case .video, .audio: true
        case .image, .camera, .microphone, .placeholder: false
        }
    }

    var durationSort: String {
        switch kind {
        case let .video(duration), let .audio(duration): return duration
        default: return ""
        }
    }
}

struct MediaLibraryDocument: Hashable, Codable {
    var collections: [MediaCollection]
    var imported: [MediaBinItem]
    var contentLibraries: [ContentLibrary]

    init(
        collections: [MediaCollection] = [],
        imported: [MediaBinItem] = [],
        contentLibraries: [ContentLibrary] = []
    ) {
        self.collections = collections
        self.imported = imported
        self.contentLibraries = contentLibraries
    }

    enum CodingKeys: String, CodingKey {
        case collections, imported, contentLibraries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collections = try container.decodeIfPresent([MediaCollection].self, forKey: .collections) ?? []
        imported = try container.decodeIfPresent([MediaBinItem].self, forKey: .imported) ?? []
        contentLibraries = try container.decodeIfPresent([ContentLibrary].self, forKey: .contentLibraries) ?? []
    }
}

struct MediaCollection: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var source: MediaSourceID
    var items: [MediaBinItem]

    init(id: UUID = UUID(), name: String, source: MediaSourceID, items: [MediaBinItem] = []) {
        self.id = id
        self.name = name
        self.source = source
        self.items = items
    }
}

extension Array where Element == MediaCollection {
    var withoutLegacyProContent: [MediaCollection] {
        filter { $0.name.caseInsensitiveCompare("ProContent") != .orderedSame }
    }
}

struct PropItem: Identifiable, Hashable {
    var id = UUID()
    var name: String
}

struct BiblePassage: Identifiable, Hashable, Codable, Sendable {
    var id: String { reference }
    var reference: String
    var text: String
}

enum DeskSampleData {
    static let libraryFolders: [LibraryFolder] = []

    static let playlists: [LibraryFolder] = [
        LibraryFolder(name: "Program", systemImage: "list.bullet.rectangle", children: []),
    ]

    static let playlistItems: [LibraryShowItem] = []

    static let mediaSources: [MediaSourceID] = MediaSourceID.allCases

    static let mediaBin: [MediaBinItem] = DefaultSeedData.mediaItems()

    static let props: [PropItem] = [
        PropItem(name: "Logo Bug"),
        PropItem(name: "Emergency Alert Message"),
    ]

    static let themes = ["Lyric Standard", "Lower Third", "Talk Point", "Default", "Lyrics", "Title"]

    static let biblePassages: [BiblePassage] = [
        BiblePassage(reference: "John 1:1", text: "In the beginning was the Word, and the Word was with God, and the Word was God."),
        BiblePassage(reference: "Psalm 23:1", text: "The Lord is my shepherd; I shall not want."),
        BiblePassage(reference: "Philippians 4:13", text: "I can do all things through Christ which strengtheneth me."),
    ]

    static let collections = ["Default Collection", "Program", "Archive"]

    static let slideTransitions = ["Cut", "Dissolve", "Push", "Fade", "Wipe"]
    static let slideLabels = ["Verse", "Chorus", "Pre-Chorus", "Bridge", "Tag", "Title", "Blank"]
    static let slideActions = ["Clear All", "Clear Slide", "Clear Media", "Go Live"]
    static let mediaBehaviors = ["Normal", "Background", "Foreground"]
    static let mediaScaling = ["Fill", "Fit", "Stretch"]
    static let mediaAlphaTypes = ["None", "Alpha Key", "Luma Key"]
    static let mediaPlayback = ["Play", "Pause", "Stop"]
    static let mediaLoop = ["Loop", "Play Once"]
    static let mediaEnd = ["Stop", "Hold Last Frame", "Next Cue"]
    static let mediaCleanup = ["Name", "Kind", "Duration"]

    static let programMediaID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC1")!
    static let stellarPlaylistID = programMediaID
    static let defaultPlaylistID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC2")!

    static func defaultMediaCollections() -> [MediaCollection] {
        emptyMediaCollections()
    }

    static func emptyMediaCollections() -> [MediaCollection] {
        [
            MediaCollection(id: defaultPlaylistID, name: "Program", source: .playlists, items: []),
            MediaCollection(id: programMediaID, name: "Program Media", source: .playlists, items: []),
            MediaCollection(name: "Library", source: .libraries, items: []),
            MediaCollection(name: "Resources", source: .resources, items: []),
            MediaCollection(name: "Video Inputs", source: .videoInputs, items: []),
            MediaCollection(name: "Audio Inputs", source: .audioInputs, items: []),
        ]
    }
}
