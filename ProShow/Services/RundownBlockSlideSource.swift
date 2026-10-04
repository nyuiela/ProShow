import Foundation

/// What fills the `.program` slide for a runtime outline row (one active source).
enum RundownBlockSlideSourceKind: Equatable, Sendable {
    case blank
    case webPage(String)
    case camera
    case mediaBin(UUID)
    case mediaFile(String)
    case playlistItem(UUID)
    case presentationSlide(showID: UUID, slideID: UUID)

    /// References a slide in another playlist/deck — not a `.program` file copy.
    var isLinkedToExternalPresentation: Bool {
        switch self {
        case .presentationSlide, .playlistItem: true
        default: false
        }
    }
}

enum RundownBlockSlideSource {
    private static let showKey = "linkedPresentationShowID"
    private static let slideKey = "linkedPresentationSlideID"

    static func resolve(_ block: RundownBlock) -> RundownBlockSlideSourceKind {
        if let showID = block.linkedPresentationShowID,
           let slideID = block.linkedPresentationSlideID {
            return .presentationSlide(showID: showID, slideID: slideID)
        }
        if let id = block.linkedMediaBinItemID { return .mediaBin(id) }
        if let path = block.linkedMediaFilePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return .mediaFile(path)
        }
        if let id = block.linkedPlaylistId { return .playlistItem(id) }
        let cut = RundownProgramCut.resolve(block)
        if cut.picture == .camera { return .camera }
        if let url = cut.pageURL { return .webPage(url) }
        return .blank
    }

    @MainActor
    static func summary(for block: RundownBlock, controller: ShowController) -> String {
        switch resolve(block) {
        case .blank:
            return "Blank slide — script and overlays only"
        case .webPage(let url):
            return "Web page · \(ProgramPageViewport.displayHost(for: url))"
        case .camera:
            return "Camera slide — edit in `.program`"
        case .mediaBin(let id):
            if let item = controller.allMediaItems.first(where: { $0.id == id }) {
                return "Media · \(item.title)"
            }
            return "Media bin item"
        case .mediaFile(let path):
            return "File · \((path as NSString).lastPathComponent)"
        case .playlistItem(let id):
            if let item = controller.playlist.items.first(where: { $0.id == id }),
               let showID = item.showID,
               let show = controller.show(matching: showID),
               let slide = show.allSlides.first {
                return linkedSlideSummary(showID: show.id, slideID: slide.id, controller: controller)
                    + " (\(item.title))"
            }
            if let item = controller.playlist.items.first(where: { $0.id == id }) {
                return "Linked playlist · \(item.title)"
            }
            return "Linked playlist item"
        case .presentationSlide(let showID, let slideID):
            return linkedSlideSummary(showID: showID, slideID: slideID, controller: controller)
        }
    }

    @MainActor
    private static func linkedSlideSummary(showID: UUID, slideID: UUID, controller: ShowController) -> String {
        let show = controller.show(matching: showID)
        let slide = show?.slide(id: slideID)
        let slideLabel = slide.map { s in
            s.title.isEmpty ? "Slide" : s.title
        } ?? "Slide"
        let showName = show?.name ?? "Presentation"
        return "Linked slide · \(showName) · \(slideLabel)"
    }

    static func clearBindings(on block: inout RundownBlock) {
        block.linkedPlaylistId = nil
        block.linkedMediaBinItemID = nil
        block.linkedMediaFilePath = nil
        block.linkedPresentationShowID = nil
        block.linkedPresentationSlideID = nil
        block.screenDirections = []
        block.linkCues = []
    }

    static func apply(_ kind: RundownBlockSlideSourceKind, to block: inout RundownBlock) {
        clearBindings(on: &block)
        switch kind {
        case .blank:
            break
        case .webPage(let url):
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = PromptWebsiteURL.canonical(trimmed) ?? trimmed
            guard !canonical.isEmpty else { return }
            block.screenDirections = [
                ScreenDirection(kind: .url, label: ProgramPageViewport.displayHost(for: canonical), url: canonical),
            ]
            block.linkCues = [LinkCue(label: canonical, url: canonical)]
            block.videoCue = OutlineScriptCompiler.videoCueSummary(block.screenDirections)
        case .camera:
            block.screenDirections = [ScreenDirection(kind: .camera, label: "Camera")]
            block.videoCue = OutlineScriptCompiler.videoCueSummary(block.screenDirections)
        case .mediaBin(let id):
            block.linkedMediaBinItemID = id
        case .mediaFile(let path):
            block.linkedMediaFilePath = path
        case .playlistItem(let id):
            block.programSlideID = nil
            block.linkedPlaylistId = id
        case .presentationSlide(let showID, let slideID):
            block.programSlideID = nil
            block.linkedPresentationShowID = showID
            block.linkedPresentationSlideID = slideID
            block.screenDirections = [
                ScreenDirection(kind: .slide, label: "Linked slide", url: nil),
            ]
        }
    }

    static func apply(discovered item: DiscoveredSourceItem, webURL: String?, to block: inout RundownBlock) {
        if item.id == "rundown-slide-blank" {
            apply(.blank, to: &block)
            return
        }
        if item.id.hasPrefix("presentation-slide-"), let raw = item.connectionString {
            let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let showID = UUID(uuidString: parts[0]), let slideID = UUID(uuidString: parts[1]) {
                apply(.presentationSlide(showID: showID, slideID: slideID), to: &block)
                return
            }
        }
        switch item.sourceType {
        case .webPage:
            let url = webURL ?? item.connectionString ?? ""
            apply(.webPage(url), to: &block)
        case .systemCamera:
            apply(.camera, to: &block)
        case .mediaFile:
            if item.id.hasPrefix("media-"), let uuid = UUID(uuidString: String(item.id.dropFirst("media-".count))) {
                apply(.mediaBin(uuid), to: &block)
            } else if let path = item.connectionString {
                apply(.mediaFile(path), to: &block)
            }
        case .libraryShow:
            if item.id.hasPrefix("playlist-item-"), let uuid = UUID(uuidString: String(item.id.dropFirst("playlist-item-".count))) {
                apply(.playlistItem(uuid), to: &block)
            }
        default:
            break
        }
    }
}

extension RundownBlock {
    var linkedPresentationShowID: UUID? {
        get { extensions["linkedPresentationShowID"].flatMap(UUID.init(uuidString:)) }
        set { extensions["linkedPresentationShowID"] = newValue?.uuidString }
    }

    var linkedPresentationSlideID: UUID? {
        get { extensions["linkedPresentationSlideID"].flatMap(UUID.init(uuidString:)) }
        set { extensions["linkedPresentationSlideID"] = newValue?.uuidString }
    }
}
