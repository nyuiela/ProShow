import Foundation

enum CanvasTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case pointer, direct, text, rectangle, ellipse, placeholder, pen, bend, scissors, hand, zoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pointer: "Move"
        case .direct: "Direct Select"
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .placeholder: "Placeholder"
        case .pen: "Pen"
        case .bend: "Bend"
        case .scissors: "Scissors"
        case .hand: "Hand"
        case .zoom: "Zoom"
        }
    }

    var shortcut: String {
        switch self {
        case .pointer: "V"
        case .direct: "A"
        case .text: "T"
        case .rectangle: "R"
        case .ellipse: "O"
        case .placeholder: "P"
        case .pen: "⇧P"
        case .bend: "⇧B"
        case .scissors: "⇧C"
        case .hand: "H"
        case .zoom: "Z"
        }
    }

    var insertionKind: CanvasObjectKind? {
        switch self {
        case .text: .text
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .placeholder: .image
        default: nil
        }
    }

    var pansCanvas: Bool {
        self == .hand
    }
}

enum TransformHandle: String, CaseIterable, Identifiable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, rotation, origin, cornerRadius

    var id: String { rawValue }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        default: false
        }
    }

    var isMidpoint: Bool {
        switch self {
        case .top, .right, .bottom, .left: true
        default: false
        }
    }
}

enum PathNodeKind: String, CaseIterable, Codable, Sendable {
    case corner, smooth, symmetric
}

enum StrokeCap: String, CaseIterable, Identifiable, Codable, Sendable {
    case butt, round, square
    var id: String { rawValue }
    var title: String { rawValue.capitalized + " Cap" }
}

enum StrokeJoin: String, CaseIterable, Identifiable, Codable, Sendable {
    case miter, round, bevel
    var id: String { rawValue }
    var title: String { rawValue.capitalized + " Join" }
}

enum StrokeMarker: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, stealth, circle, diamond, barbed
    var id: String { rawValue }
}

enum BooleanOperation: String, CaseIterable, Identifiable, Codable, Sendable {
    case union, subtract, intersect, exclude
    var id: String { rawValue }
}

enum TextFrameMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case autoWidth, autoHeight, fixed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .autoWidth: "Auto Width"
        case .autoHeight: "Auto Height"
        case .fixed: "Fixed Size"
        }
    }
}

enum AutoLayoutDirection: String, CaseIterable, Codable, Sendable {
    case horizontal, vertical
}

enum AutoLayoutSizing: String, CaseIterable, Codable, Sendable {
    case fixed, hug, fill
}

enum NinePointAlign: String, CaseIterable, Identifiable, Codable, Sendable {
    case topLeft, topCenter, topRight, centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight
    var id: String { rawValue }
}

enum LayerBlendMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case normal, dissolve
    case darken, multiply, colorBurn, linearBurn
    case lighten, screen, colorDodge, linearDodge
    case overlay, softLight, hardLight, vividLight, linearLight
    case difference, exclusion, subtract, divide
    case hue, saturation, color, luminosity

    var id: String { rawValue }
}

struct PathNode: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var x: Double
    var y: Double
    var inX: Double
    var inY: Double
    var outX: Double
    var outY: Double
    var kind: PathNodeKind

    init(id: UUID = UUID(), x: Double, y: Double, inX: Double = 0, inY: Double = 0, outX: Double = 0, outY: Double = 0, kind: PathNodeKind = .corner) {
        self.id = id
        self.x = x
        self.y = y
        self.inX = inX
        self.inY = inY
        self.outX = outX
        self.outY = outY
        self.kind = kind
    }
}

struct VectorPath: Hashable, Codable, Sendable {
    var nodes: [PathNode]
    var closed: Bool

    static let empty = VectorPath(nodes: [], closed: false)
}

struct CornerRadii: Hashable, Codable, Sendable {
    var topLeft: Double
    var topRight: Double
    var bottomRight: Double
    var bottomLeft: Double

    static func uniform(_ value: Double) -> CornerRadii {
        CornerRadii(topLeft: value, topRight: value, bottomRight: value, bottomLeft: value)
    }

    var maxRadius: Double {
        max(topLeft, topRight, bottomRight, bottomLeft)
    }
}

struct AutoLayoutFrame: Hashable, Codable, Sendable {
    var enabled: Bool
    var direction: AutoLayoutDirection
    var padding: TextBoxMargins
    var gap: Double
    var wrap: Bool
    var childSizing: AutoLayoutSizing
    var alignment: NinePointAlign

    static let `default` = AutoLayoutFrame(
        enabled: true,
        direction: .horizontal,
        padding: TextBoxMargins(top: 16, bottom: 16, left: 24, right: 24),
        gap: 12,
        wrap: false,
        childSizing: .hug,
        alignment: .centerLeft
    )
}

struct TextRun: Hashable, Codable, Sendable, Identifiable {
    var id: UUID
    var text: String
    var fontFamily: String
    var fontSize: Double
    var color: String
    var tracking: Double

    init(id: UUID = UUID(), text: String, fontFamily: String = "Inter", fontSize: Double = 48, color: String = "#FFFFFF", tracking: Double = 0) {
        self.id = id
        self.text = text
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.color = color
        self.tracking = tracking
    }
}

struct SmartGuide: Hashable, Sendable {
    var vertical: Bool
    var position: Double
    var canvasAligned: Bool
}

struct DistanceReadout: Hashable, Sendable {
    var dx: Double
    var dy: Double
    var gapX: Double
    var gapY: Double
}

struct GradientMidpoint: Hashable, Codable, Sendable {
    var afterStop: Int
    var position: Double
}
