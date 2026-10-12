import Foundation

enum ElementContainerKind: String, Codable, Sendable {
    case leafElement
    case groupContainer
}

/// Named container for grouped canvas objects. Children keep `CanvasObject.groupID`.
struct CanvasGroupNode: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var containerKind: ElementContainerKind
    var childElementIds: [UUID]
    var bounds: CanvasBounds
    var rotationDegrees: Double
    var opacity: Double
    var isLocked: Bool
    var isHidden: Bool

    init(
        id: UUID = UUID(),
        name: String = "Group",
        containerKind: ElementContainerKind = .groupContainer,
        childElementIds: [UUID] = [],
        bounds: CanvasBounds = CanvasBounds(x: 0, y: 0, width: 0, height: 0),
        rotationDegrees: Double = 0,
        opacity: Double = 1,
        isLocked: Bool = false,
        isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.containerKind = containerKind
        self.childElementIds = childElementIds
        self.bounds = bounds
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
        self.isLocked = isLocked
        self.isHidden = isHidden
    }
}

/// One visible row in the editor Objects outline (folder or leaf).
enum ObjectTreeItem: Identifiable, Hashable, Sendable {
    case group(id: UUID, name: String, childIDs: [UUID], isExpanded: Bool)
    case object(CanvasObject, depth: Int)

    var id: UUID {
        switch self {
        case .group(let id, _, _, _): return id
        case .object(let object, _): return object.id
        }
    }

    var representedObjectIDs: [UUID] {
        switch self {
        case .group(_, _, let childIDs, _): return childIDs
        case .object(let object, _): return [object.id]
        }
    }

    var depth: Int {
        switch self {
        case .group: return 0
        case .object(_, let depth): return depth
        }
    }
}

extension CanvasObject {
    var parentGroupId: UUID? {
        get { groupID }
        set { groupID = newValue }
    }
}

extension CanvasBounds {
    static func union(_ bounds: [CanvasBounds]) -> CanvasBounds? {
        guard let first = bounds.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for box in bounds.dropFirst() {
            minX = min(minX, box.x)
            minY = min(minY, box.y)
            maxX = max(maxX, box.x + box.width)
            maxY = max(maxY, box.y + box.height)
        }
        return CanvasBounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func intersects(_ other: CanvasBounds) -> Bool {
        overlapsX(other) && overlapsY(other)
    }

    static func fromCorners(x1: Double, y1: Double, x2: Double, y2: Double) -> CanvasBounds {
        let minX = min(x1, x2)
        let minY = min(y1, y2)
        return CanvasBounds(x: minX, y: minY, width: abs(x2 - x1), height: abs(y2 - y1))
    }
}
