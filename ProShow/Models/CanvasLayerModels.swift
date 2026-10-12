import Foundation
#if os(macOS)
import AppKit
#endif

enum LayerKind: String, Codable, Sendable {
    case video = "Video"
    case image = "Image"
    case text = "Text"
    case shape = "Shape"
    case camera = "Live Input"
    case placeholder = "Placeholder"
    case group = "Group"
    case slide = "Slide"
    case web = "Web"
    case other = "Object"

    var iconName: String {
        switch self {
        case .video: "video.fill"
        case .image: "photo.fill"
        case .text: "textformat"
        case .shape: "square.on.circle.fill"
        case .camera: "camera.fill"
        case .placeholder: "rectangle.dashed.and.paperclip"
        case .group: "folder.fill"
        case .slide: "doc.richtext.fill"
        case .web: "globe"
        case .other: "square.dashed"
        }
    }

    static func from(kind: CanvasObjectKind) -> LayerKind {
        switch kind {
        case .videoInput: .camera
        case .image: .image
        case .webView, .browser: .web
        case .text, .title, .subtitle, .currentSlide, .nextSlide, .stageNotes, .copyrightToken,
             .systemClock, .systemDate, .timerCountdown, .liveQuote, .textField:
            .text
        case .rectangle, .roundedRectangle, .ellipse, .line, .polygon, .pen, .bezier,
             .maskShape, .edgeBlend, .cutout, .prop:
            .shape
        default:
            .other
        }
    }
}

struct CanvasLayerItem: Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: LayerKind
    var kindDetail: String
    var isVisible: Bool
    var isLocked: Bool
    var zIndex: Int
    var parentGroupId: UUID?

    #if os(macOS)
    var thumbnailImage: NSImage?
    #endif

    init(
        id: UUID,
        name: String,
        kind: LayerKind,
        kindDetail: String,
        isVisible: Bool,
        isLocked: Bool,
        zIndex: Int,
        parentGroupId: UUID? = nil,
        thumbnailImage: NSImage? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.kindDetail = kindDetail
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.zIndex = zIndex
        self.parentGroupId = parentGroupId
        #if os(macOS)
        self.thumbnailImage = thumbnailImage
        #endif
    }
}
