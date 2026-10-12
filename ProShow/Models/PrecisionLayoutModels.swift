import Foundation
import CoreGraphics

public enum GuideAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct UserGuideLine: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var axis: GuideAxis
    public var position: CGFloat
    public var isLocked: Bool = false

    public init(id: UUID = UUID(), axis: GuideAxis, position: CGFloat, isLocked: Bool = false) {
        self.id = id
        self.axis = axis
        self.position = position
        self.isLocked = isLocked
    }
}

public enum GuideDirection: Equatable, Sendable {
    case horizontal(y: CGFloat)
    case vertical(x: CGFloat)
}

public struct SmartGuideLine: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var direction: GuideDirection
    public var startPoint: CGPoint
    public var endPoint: CGPoint
    public var canvasAligned: Bool

    public init(
        direction: GuideDirection,
        startPoint: CGPoint,
        endPoint: CGPoint,
        canvasAligned: Bool = false
    ) {
        self.direction = direction
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.canvasAligned = canvasAligned
    }
}

public struct EqualSpacingBadge: Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var bounds: CGRect
    public var gapPx: CGFloat
    public var axis: Axis

    public enum Axis: Sendable {
        case horizontal
        case vertical
    }
}

public struct LayoutSnapState: Equatable, Sendable {
    public var activeGuides: [SmartGuideLine] = []
    public var spacingBadges: [EqualSpacingBadge] = []
    public var snappedX: Double?
    public var snappedY: Double?

    public init(
        activeGuides: [SmartGuideLine] = [],
        spacingBadges: [EqualSpacingBadge] = [],
        snappedX: Double? = nil,
        snappedY: Double? = nil
    ) {
        self.activeGuides = activeGuides
        self.spacingBadges = spacingBadges
        self.snappedX = snappedX
        self.snappedY = snappedY
    }

    /// Legacy overlay bridge.
    var legacyGuides: [SmartGuide] {
        activeGuides.compactMap { line in
            switch line.direction {
            case .vertical(let x):
                return SmartGuide(vertical: true, position: Double(x), canvasAligned: line.canvasAligned)
            case .horizontal(let y):
                return SmartGuide(vertical: false, position: Double(y), canvasAligned: line.canvasAligned)
            }
        }
    }
}

public struct CanvasGridConfig: Codable, Equatable, Sendable {
    public var isGridVisible: Bool = true
    public var isSnapToGridEnabled: Bool = true
    public var isSmartGuidesEnabled: Bool = true
    /// Base layout unit (Figma / Sketch default pixel grid).
    public var gridSizePoints: CGFloat = 8
    public var showBroadcastSafeAreas: Bool = false
    public var showHeaderFooterGuides: Bool = false
    public var showColumnLayoutGrid: Bool = false
    public var showCanvasMinimap: Bool = true
    public var snapToUserGuides: Bool = true

    public static let gridPresets: [CGFloat] = [8, 16, 32, 64]

    public init(
        isGridVisible: Bool = true,
        isSnapToGridEnabled: Bool = true,
        isSmartGuidesEnabled: Bool = true,
        gridSizePoints: CGFloat = 8,
        showBroadcastSafeAreas: Bool = false,
        showHeaderFooterGuides: Bool = false,
        showColumnLayoutGrid: Bool = false,
        showCanvasMinimap: Bool = true,
        snapToUserGuides: Bool = true
    ) {
        self.isGridVisible = isGridVisible
        self.isSnapToGridEnabled = isSnapToGridEnabled
        self.isSmartGuidesEnabled = isSmartGuidesEnabled
        self.gridSizePoints = gridSizePoints
        self.showBroadcastSafeAreas = showBroadcastSafeAreas
        self.showHeaderFooterGuides = showHeaderFooterGuides
        self.showColumnLayoutGrid = showColumnLayoutGrid
        self.showCanvasMinimap = showCanvasMinimap
        self.snapToUserGuides = snapToUserGuides
    }

    enum CodingKeys: String, CodingKey {
        case isGridVisible, isSnapToGridEnabled, isSmartGuidesEnabled, gridSizePoints
        case showBroadcastSafeAreas, showHeaderFooterGuides, showColumnLayoutGrid
        case showCanvasMinimap, snapToUserGuides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isGridVisible = try container.decodeIfPresent(Bool.self, forKey: .isGridVisible) ?? true
        isSnapToGridEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSnapToGridEnabled) ?? true
        isSmartGuidesEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSmartGuidesEnabled) ?? true
        gridSizePoints = try container.decodeIfPresent(CGFloat.self, forKey: .gridSizePoints) ?? 8
        showBroadcastSafeAreas = try container.decodeIfPresent(Bool.self, forKey: .showBroadcastSafeAreas) ?? false
        showHeaderFooterGuides = try container.decodeIfPresent(Bool.self, forKey: .showHeaderFooterGuides) ?? false
        showColumnLayoutGrid = try container.decodeIfPresent(Bool.self, forKey: .showColumnLayoutGrid) ?? false
        showCanvasMinimap = try container.decodeIfPresent(Bool.self, forKey: .showCanvasMinimap) ?? true
        snapToUserGuides = try container.decodeIfPresent(Bool.self, forKey: .snapToUserGuides) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isGridVisible, forKey: .isGridVisible)
        try container.encode(isSnapToGridEnabled, forKey: .isSnapToGridEnabled)
        try container.encode(isSmartGuidesEnabled, forKey: .isSmartGuidesEnabled)
        try container.encode(gridSizePoints, forKey: .gridSizePoints)
        try container.encode(showBroadcastSafeAreas, forKey: .showBroadcastSafeAreas)
        try container.encode(showHeaderFooterGuides, forKey: .showHeaderFooterGuides)
        try container.encode(showColumnLayoutGrid, forKey: .showColumnLayoutGrid)
        try container.encode(showCanvasMinimap, forKey: .showCanvasMinimap)
        try container.encode(snapToUserGuides, forKey: .snapToUserGuides)
    }
}

public struct LayoutSnapResult: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var state: LayoutSnapState
}
