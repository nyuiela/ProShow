import Foundation

/// Sidebar library / playlist / media navigation stubs for the operator desk chrome.
struct LibraryFolder: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var systemImage: String
    var children: [LibraryFolder]
}

struct LibraryShowItem: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var isActive: Bool
}

struct MediaBinItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case video(duration: String)
        case image
        case camera(label: String)
        case placeholder
    }

    var id = UUID()
    var title: String
    var kind: Kind
    var tintHex: String
}

struct PropItem: Identifiable, Hashable {
    var id = UUID()
    var name: String
}

enum DeskSampleData {
    static let libraryFolders: [LibraryFolder] = [
        LibraryFolder(name: "Stellar", systemImage: "folder.fill", children: []),
        LibraryFolder(name: "Sample 1", systemImage: "folder.fill", children: []),
        LibraryFolder(name: "Church", systemImage: "folder.fill", children: []),
    ]

    static let playlists: [LibraryFolder] = [
        LibraryFolder(name: "Playlist", systemImage: "list.bullet.rectangle", children: []),
        LibraryFolder(name: "Sample Playlist", systemImage: "list.bullet.rectangle", children: []),
    ]

    static let playlistItems: [LibraryShowItem] = [
        LibraryShowItem(title: "Alaba", isActive: false),
        LibraryShowItem(title: "intro", isActive: false),
        LibraryShowItem(title: "stellar slides_peter okai", isActive: true),
    ]

    static let mediaSources: [LibraryFolder] = [
        LibraryFolder(name: "ProContent", systemImage: "sparkles.tv", children: []),
        LibraryFolder(
            name: "Playlists",
            systemImage: "rectangle.stack",
            children: [
                LibraryFolder(name: "Stellar", systemImage: "folder", children: []),
                LibraryFolder(name: "Resources", systemImage: "folder", children: []),
            ]
        ),
        LibraryFolder(name: "Sample Content", systemImage: "photo.on.rectangle", children: []),
        LibraryFolder(name: "Video Inputs", systemImage: "video", children: []),
    ]

    static let mediaBin: [MediaBinItem] = [
        MediaBinItem(title: "Worship Loop", kind: .video(duration: "04:12.00"), tintHex: "#1B3A4B"),
        MediaBinItem(title: "Stellar Open", kind: .video(duration: "24:34.72"), tintHex: "#3A2A1B"),
        MediaBinItem(title: "Crowd Wide", kind: .image, tintHex: "#2A2A3A"),
        MediaBinItem(title: "Input 2 Mac Cam", kind: .camera(label: "Input 2"), tintHex: "#1A1A1A"),
        MediaBinItem(title: "Logo Bug", kind: .image, tintHex: "#2A3A2A"),
        MediaBinItem(title: "Lower Third", kind: .placeholder, tintHex: "#333333"),
    ]

    static let props: [PropItem] = [
        PropItem(name: "Prop"),
        PropItem(name: "Prop 1"),
    ]
}
