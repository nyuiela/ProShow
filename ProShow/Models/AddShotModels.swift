import Foundation

public enum AddShotCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case all = "All"
    case favorites = "Favorites"
    case placeholders = "Placeholders"
    case videoCapture = "Video Capture"
    case audioCapture = "Audio Capture"
    case mediaFiles = "Media Files"
    case network = "Network"
    case screenCapture = "Screen Capture"
    case overlays = "Overlays"
    case backgrounds = "Backgrounds"
    case templates = "Templates"
    case shots = "Shots"
    case slides = "Slides"
    case webPages = "Web Browser"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .all: "squareshape.split.3x3"
        case .favorites: "star"
        case .placeholders: "a.square"
        case .videoCapture: "video"
        case .audioCapture: "speaker.wave.2"
        case .mediaFiles: "film.stack"
        case .network: "network"
        case .screenCapture: "desktopcomputer"
        case .overlays: "tag"
        case .backgrounds: "paintpalette"
        case .templates: "rectangle.3.group"
        case .shots: "film"
        case .slides: "rectangle.on.rectangle.angled"
        case .webPages: "globe"
        }
    }
}

public enum SourceType: String, Codable, Sendable {
    case systemCamera
    case systemMicrophone
    case systemAudioCapture
    case systemDisplay
    case systemWindow
    case ndiSource
    case srtStream
    case webPage
    case rendezvousGuest
    case mediaFile
    case libraryShow
    case solidColor
    case templateLayout
    case placeholderSlot

    var showsDevicePreview: Bool {
        switch self {
        case .systemCamera, .systemDisplay, .systemWindow:
            true
        default:
            false
        }
    }

    /// Cameras and displays only play if they exist as a live shot on a master layer.
    var needsMainLayerShot: Bool {
        switch self {
        case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .srtStream, .rendezvousGuest:
            true
        default:
            false
        }
    }
}

public enum PlaceholderLetter: String, CaseIterable, Codable, Sendable {
    case A, B, C, D, E, F, G, H, I

    public var tintIndex: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    /// `A`, `Placeholder B`, or `placeholder://A`.
    public static func parse(_ raw: String) -> PlaceholderLetter? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("placeholder://") {
            return PlaceholderLetter(rawValue: String(trimmed.dropFirst("placeholder://".count)).uppercased())
        }
        if lower.hasPrefix("placeholder ") {
            let rest = trimmed.dropFirst("placeholder ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return PlaceholderLetter(rawValue: rest.uppercased())
        }
        return PlaceholderLetter(rawValue: trimmed.uppercased())
    }
}

public enum PlaceholderUse: String, Codable, Sendable {
    case unmapped
    case prop
    case screen
    case media
    case camera
    case slide
}

public struct PlaceholderBinding: Hashable, Codable, Sendable {
    public var letter: String
    public var use: PlaceholderUse
    public var targetID: String?
    public var targetName: String?

    public init(
        letter: String,
        use: PlaceholderUse = .unmapped,
        targetID: String? = nil,
        targetName: String? = nil
    ) {
        self.letter = letter.uppercased()
        self.use = use
        self.targetID = targetID
        self.targetName = targetName
    }
}

public struct PlaceholderSlotSpec: Hashable, Sendable {
    public var letter: PlaceholderLetter
    public var tintHex: String

    public static let catalog: [PlaceholderSlotSpec] = [
        .init(letter: .A, tintHex: "#D8F5D0"),
        .init(letter: .B, tintHex: "#FFD6E0"),
        .init(letter: .C, tintHex: "#C8F4F0"),
        .init(letter: .D, tintHex: "#FFE9A8"),
        .init(letter: .E, tintHex: "#FFD0B8"),
        .init(letter: .F, tintHex: "#D4D0FF"),
        .init(letter: .G, tintHex: "#C8E6FF"),
        .init(letter: .H, tintHex: "#E8F5C8"),
        .init(letter: .I, tintHex: "#F0E0D0"),
    ]
}

public struct SolidColorSwatch: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var hex: String

    public init(id: String, name: String, hex: String) {
        self.id = id
        self.name = name
        self.hex = hex
    }

    public static let factory: [SolidColorSwatch] = [
        .init(id: "color-stage-black", name: "Stage Black", hex: "#000000"),
        .init(id: "color-white", name: "White", hex: "#FFFFFF"),
        .init(id: "color-warm-white", name: "Warm White", hex: "#F4E8D0"),
        .init(id: "color-screen-red", name: "Screen Red", hex: "#C41E3A"),
        .init(id: "color-screen-blue", name: "Screen Blue", hex: "#1B4F9C"),
        .init(id: "color-screen-green", name: "Screen Green", hex: "#1B7A3A"),
        .init(id: "color-lemon", name: "Lemon", hex: "#FAD32E"),
        .init(id: "color-tangerine", name: "Tangerine", hex: "#FF6B29"),
        .init(id: "color-blush", name: "Blush", hex: "#FF8CB8"),
        .init(id: "color-aqua", name: "Aqua", hex: "#3DE0D1"),
    ]
}

public struct DiscoveredSourceItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var category: AddShotCategory
    public var groupName: String
    public var sourceType: SourceType
    public var connectionString: String?
    public var isFavorite: Bool
    public var isConnected: Bool
    public var tintHex: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        category: AddShotCategory,
        groupName: String,
        sourceType: SourceType,
        connectionString: String? = nil,
        isFavorite: Bool = false,
        isConnected: Bool = true,
        tintHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.groupName = groupName
        self.sourceType = sourceType
        self.connectionString = connectionString
        self.isFavorite = isFavorite
        self.isConnected = isConnected
        self.tintHex = tintHex
    }

    public var placeholderLetter: String? {
        guard sourceType == .placeholderSlot else { return nil }
        let token = connectionString?.split(separator: "/").last.map(String.init) ?? name
        return PlaceholderLetter(rawValue: token) != nil ? token : nil
    }
}

public struct SourceGroup: Identifiable, Equatable, Sendable {
    public var groupName: String
    public var items: [DiscoveredSourceItem]

    public var id: String { groupName }

    public init(groupName: String, items: [DiscoveredSourceItem]) {
        self.groupName = groupName
        self.items = items
    }
}

public enum AudioFollowMode: String, Codable, Sendable, CaseIterable {
    case alwaysOn
    case followSlide
}

public struct LayerShot: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var source: DiscoveredSourceItem
    public var isCopy: Bool
    public var createdAt: Date
    public var audioMuted: Bool? = nil
    /// nil = always on. `.followSlide`: heard only while the slide it was taken on is live.
    public var audioFollow: AudioFollowMode? = nil
    /// Slide this shot's audio follows (set with Follow Slide). nil with followSlide = always heard.
    public var audioFollowSlideID: UUID? = nil

    public init(
        id: UUID = UUID(),
        name: String,
        source: DiscoveredSourceItem,
        isCopy: Bool = false,
        createdAt: Date = Date(),
        audioMuted: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.isCopy = isCopy
        self.createdAt = createdAt
        self.audioMuted = audioMuted
    }

    public var isAudioMuted: Bool { audioMuted == true }
}

public struct MasterLayer: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var index: Int
    public var title: String
    public var shots: [LayerShot]
    public var liveShotID: UUID?

    public init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        shots: [LayerShot] = [],
        liveShotID: UUID? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.shots = shots
        self.liveShotID = liveShotID
    }

    public static var defaults: [MasterLayer] {
        (1...5).map { index in
            MasterLayer(index: index, title: "Main Layer \(index)")
        }
    }
}

enum AddShotPurpose: String, Hashable, Codable, Sendable {
    case addToLayer
    case assignToSelectedObjects
    /// Same catalog as assign-to-object, but applies to a rundown outline row’s program slide link.
    case assignRundownProgramSlide

    var title: String {
        switch self {
        case .addToLayer: "Add Shot"
        case .assignToSelectedObjects, .assignRundownProgramSlide: "Assign Source"
        }
    }

    var confirmTitle: String {
        switch self {
        case .addToLayer: "Add"
        case .assignToSelectedObjects, .assignRundownProgramSlide: "Assign"
        }
    }

    var isAssignFlow: Bool {
        switch self {
        case .assignToSelectedObjects, .assignRundownProgramSlide: true
        case .addToLayer: false
        }
    }
}

struct AssignedMediaSource: Hashable, Codable, Sendable {
    var sourceID: String
    var name: String
    var sourceType: SourceType
    var category: AddShotCategory
    var connectionString: String?
    var tintHex: String?
    var placeholderLetter: String?
    var mediaItemID: UUID?
    var audioMuted: Bool? = nil

    func asDiscoveredItem() -> DiscoveredSourceItem {
        DiscoveredSourceItem(
            id: sourceID,
            name: name,
            category: category,
            groupName: category.rawValue,
            sourceType: sourceType,
            connectionString: connectionString,
            tintHex: tintHex
        )
    }

    static func from(_ item: DiscoveredSourceItem, mediaItemID: UUID? = nil) -> AssignedMediaSource {
        AssignedMediaSource(
            sourceID: item.id,
            name: item.name,
            sourceType: item.sourceType,
            category: item.category,
            connectionString: item.connectionString,
            tintHex: item.tintHex,
            placeholderLetter: item.placeholderLetter,
            mediaItemID: mediaItemID
        )
    }

    var summary: String {
        if let placeholderLetter {
            return "Placeholder \(placeholderLetter)"
        }
        return name
    }

    var isMappedFill: Bool {
        sourceType != .placeholderSlot
    }

    var looksLikeVideo: Bool {
        Self.pathLooksLikeVideo(connectionString)
    }

    static func pathLooksLikeVideo(_ path: String?) -> Bool {
        let value = (path ?? "").lowercased()
        return [".mp4", ".mov", ".m4v", ".avi", ".mkv", ".webm", ".mts", ".m2ts"].contains { value.hasSuffix($0) }
    }
}

enum AddShotSearch {
    static func matches(_ item: DiscoveredSourceItem, query: String) -> Bool {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return true }
        let haystack = "\(item.name) \(item.groupName) \(item.category.rawValue) \(item.sourceType.rawValue)".lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Operator-facing layer names

extension SourceType {
    /// Short kind name shown to operators instead of the internal layer number.
    var layerKindName: String {
        switch self {
        case .systemCamera, .ndiSource, .srtStream: "Camera"
        case .systemMicrophone: "Mic"
        case .systemAudioCapture: "Audio"
        case .systemDisplay: "Screen"
        case .systemWindow: "Window"
        case .webPage: "Web"
        case .rendezvousGuest: "Guest"
        case .mediaFile: "Media"
        case .libraryShow, .templateLayout: "Slide"
        case .solidColor: "Color"
        case .placeholderSlot: "Placeholder"
        }
    }
}

extension MasterLayer {
    /// Default titles ("Main Layer 3") are internal. Anything else was typed by the operator.
    var hasDefaultTitle: Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        guard t.hasPrefix("Main Layer") else { return false }
        return Int(t.dropFirst("Main Layer".count).trimmingCharacters(in: .whitespaces)) != nil
    }

    var liveShot: LayerShot? {
        guard let liveShotID else { return nil }
        return shots.first { $0.id == liveShotID }
    }
}

extension Array where Element == MasterLayer {
    /// Content-based name: "Camera", "Mic", "Empty". Same kind twice adds the source
    /// name when it is short and distinct, else "Camera 2". The index stays internal.
    func displayName(at index: Int) -> String {
        guard indices.contains(index) else { return "Empty" }
        let layer = self[index]
        if !layer.hasDefaultTitle { return layer.title }
        guard let shot = layer.liveShot else { return "Empty" }
        let kind = shot.source.sourceType.layerKindName
        let sameKind = indices.filter { i in
            self[i].hasDefaultTitle && self[i].liveShot?.source.sourceType.layerKindName == kind
        }
        guard sameKind.count > 1 else { return kind }
        let name = shot.source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = sameKind.compactMap { self[$0].liveShot?.source.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !name.isEmpty, name.count <= 18, names.filter({ $0 == name }).count == 1 {
            return name
        }
        let position = (sameKind.firstIndex(of: index) ?? 0) + 1
        return position == 1 ? kind : "\(kind) \(position)"
    }
}
