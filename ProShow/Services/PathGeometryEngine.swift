import Foundation
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum PathGeometryEngine {
    struct Point: Hashable, Sendable {
        var x: Double
        var y: Double
    }

    static func flatten(_ path: VectorPath, samples: Int = 8) -> [Point] {
        guard path.nodes.count >= 2 else {
            return path.nodes.map { Point(x: $0.x, y: $0.y) }
        }
        var points: [Point] = []
        let count = path.closed ? path.nodes.count : path.nodes.count - 1
        for index in 0..<count {
            let start = path.nodes[index]
            let end = path.nodes[(index + 1) % path.nodes.count]
            points.append(Point(x: start.x, y: start.y))
            if start.kind != .corner || end.kind != .corner {
                let c1 = Point(x: start.outX == 0 && start.outY == 0 ? start.x : start.outX, y: start.outX == 0 && start.outY == 0 ? start.y : start.outY)
                let c2 = Point(x: end.inX == 0 && end.inY == 0 ? end.x : end.inX, y: end.inX == 0 && end.inY == 0 ? end.y : end.inY)
                for step in 1..<samples {
                    let t = Double(step) / Double(samples)
                    points.append(cubic(start: Point(x: start.x, y: start.y), c1: c1, c2: c2, end: Point(x: end.x, y: end.y), t: t))
                }
            }
        }
        if !path.closed, let last = path.nodes.last {
            points.append(Point(x: last.x, y: last.y))
        }
        return points
    }

    static func contains(_ path: VectorPath, x: Double, y: Double) -> Bool {
        contains(flatten(path), x: x, y: y)
    }

    static func contains(_ polygon: [Point], x: Double, y: Double) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[j]
            let dy = b.y - a.y
            if abs(dy) > 0.0000001 {
                let intersect = ((a.y > y) != (b.y > y))
                    && (x < (b.x - a.x) * (y - a.y) / dy + a.x)
                if intersect { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func hitTest(_ path: VectorPath, x: Double, y: Double, strokeWidth: Double = 2) -> Bool {
        if contains(path, x: x, y: y) { return true }
        let points = flatten(path)
        guard points.count >= 2 else { return false }
        let tolerance = max(strokeWidth / 2, 2)
        for index in 0..<(points.count - (path.closed ? 0 : 1)) {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            if distance(x, y, a, b) <= tolerance { return true }
        }
        return false
    }

    static func hitTest(_ object: CanvasObject, x: Double, y: Double) -> Bool {
        if let path = object.vectorPath, path.nodes.count >= 2 {
            return hitTest(path, x: x, y: y, strokeWidth: max(object.stroke.width, 4))
        }
        return x >= object.bounds.x
            && y >= object.bounds.y
            && x <= object.bounds.x + object.bounds.width
            && y <= object.bounds.y + object.bounds.height
    }

    static func bounds(of path: VectorPath) -> CanvasBounds {
        let points = flatten(path)
        guard let first = points.first else {
            return CanvasBounds(x: 0, y: 0, width: 1, height: 1)
        }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CanvasBounds(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    static func booleanPath(_ a: VectorPath, _ b: VectorPath, operation: BooleanOperation, resolution: Int = 72) -> VectorPath {
        if let boxA = axisAlignedRect(a), let boxB = axisAlignedRect(b) {
            return booleanRects(boxA, boxB, operation: operation)
        }
        let boxA = bounds(of: a)
        let boxB = bounds(of: b)
        let minX = min(boxA.x, boxB.x) - 1
        let minY = min(boxA.y, boxB.y) - 1
        let maxX = max(boxA.x + boxA.width, boxB.x + boxB.width) + 1
        let maxY = max(boxA.y + boxA.height, boxB.y + boxB.height) + 1
        let cols = max(8, resolution)
        let rows = max(8, resolution)
        let cellW = (maxX - minX) / Double(cols)
        let cellH = (maxY - minY) / Double(rows)
        var grid = Array(repeating: false, count: cols * rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let x = minX + (Double(col) + 0.5) * cellW
                let y = minY + (Double(row) + 0.5) * cellH
                let inA = contains(a, x: x, y: y)
                let inB = contains(b, x: x, y: y)
                let filled: Bool
                switch operation {
                case .union: filled = inA || inB
                case .intersect: filled = inA && inB
                case .subtract: filled = inA && !inB
                case .exclude: filled = inA != inB
                }
                grid[row * cols + col] = filled
            }
        }
        return contour(grid: grid, cols: cols, rows: rows, originX: minX, originY: minY, cellW: cellW, cellH: cellH)
    }

    static func blendModeName(_ mode: LayerBlendMode?) -> String {
        (mode ?? .normal).rawValue
    }

    private static func cubic(start: Point, c1: Point, c2: Point, end: Point, t: Double) -> Point {
        let u = 1 - t
        let x = u * u * u * start.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * end.x
        let y = u * u * u * start.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * end.y
        return Point(x: x, y: y)
    }

    private static func distance(_ x: Double, _ y: Double, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = max((dx * dx + dy * dy).squareRoot(), 0.0001)
        let t = min(1, max(0, ((x - a.x) * dx + (y - a.y) * dy) / (length * length)))
        let px = a.x + t * dx
        let py = a.y + t * dy
        return ((x - px) * (x - px) + (y - py) * (y - py)).squareRoot()
    }

    private static func axisAlignedRect(_ path: VectorPath) -> CanvasBounds? {
        guard path.nodes.count == 4, path.nodes.allSatisfy({ $0.kind == .corner }) else { return nil }
        let xs = path.nodes.map(\.x)
        let ys = path.nodes.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let uniqueX = Set(xs.map { ($0 * 1000).rounded() / 1000 })
        let uniqueY = Set(ys.map { ($0 * 1000).rounded() / 1000 })
        guard uniqueX.count == 2, uniqueY.count == 2, maxX > minX, maxY > minY else { return nil }
        return CanvasBounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func booleanRects(_ a: CanvasBounds, _ b: CanvasBounds, operation: BooleanOperation) -> VectorPath {
        let ix = max(a.x, b.x)
        let iy = max(a.y, b.y)
        let ix2 = min(a.x + a.width, b.x + b.width)
        let iy2 = min(a.y + a.height, b.y + b.height)
        let overlaps = ix2 > ix && iy2 > iy
        switch operation {
        case .union:
            return CanvasTransformEngine.rectanglePath(bounds: CanvasTransformEngine.boolean(a, b, operation: .union))
        case .intersect:
            guard overlaps else { return VectorPath(nodes: [], closed: true) }
            return CanvasTransformEngine.rectanglePath(bounds: CanvasBounds(x: ix, y: iy, width: ix2 - ix, height: iy2 - iy))
        case .subtract:
            return subtractRect(a, clipped: CanvasBounds(x: ix, y: iy, width: max(0, ix2 - ix), height: max(0, iy2 - iy)), overlaps: overlaps)
        case .exclude:
            if !overlaps {
                return CanvasTransformEngine.rectanglePath(bounds: a)
            }
            return subtractRect(a, clipped: CanvasBounds(x: ix, y: iy, width: ix2 - ix, height: iy2 - iy), overlaps: true)
        }
    }

    private static func subtractRect(_ a: CanvasBounds, clipped b: CanvasBounds, overlaps: Bool) -> VectorPath {
        if !overlaps {
            return CanvasTransformEngine.rectanglePath(bounds: a)
        }
        let ax2 = a.x + a.width
        let ay2 = a.y + a.height
        let bx2 = b.x + b.width
        let by2 = b.y + b.height
        if b.x <= a.x && b.y <= a.y && bx2 >= ax2 && by2 >= ay2 {
            return VectorPath(nodes: [], closed: true)
        }
        var points: [Point] = []
        let cutLeft = b.x <= a.x + 0.0001
        let cutRight = bx2 >= ax2 - 0.0001
        let cutTop = b.y <= a.y + 0.0001
        let cutBottom = by2 >= ay2 - 0.0001
        if cutTop && cutRight && !cutLeft && !cutBottom {
            points = [Point(x: a.x, y: a.y), Point(x: b.x, y: a.y), Point(x: b.x, y: by2), Point(x: ax2, y: by2), Point(x: ax2, y: ay2), Point(x: a.x, y: ay2)]
        } else if cutTop && cutLeft && !cutRight && !cutBottom {
            points = [Point(x: bx2, y: a.y), Point(x: ax2, y: a.y), Point(x: ax2, y: ay2), Point(x: a.x, y: ay2), Point(x: a.x, y: by2), Point(x: bx2, y: by2)]
        } else if cutBottom && cutRight && !cutLeft && !cutTop {
            points = [Point(x: a.x, y: a.y), Point(x: ax2, y: a.y), Point(x: ax2, y: b.y), Point(x: b.x, y: b.y), Point(x: b.x, y: ay2), Point(x: a.x, y: ay2)]
        } else if cutBottom && cutLeft && !cutRight && !cutTop {
            points = [Point(x: a.x, y: a.y), Point(x: ax2, y: a.y), Point(x: ax2, y: ay2), Point(x: bx2, y: ay2), Point(x: bx2, y: b.y), Point(x: a.x, y: b.y)]
        } else if cutRight && !cutLeft && !cutTop && !cutBottom {
            points = [Point(x: a.x, y: a.y), Point(x: ax2, y: a.y), Point(x: ax2, y: b.y), Point(x: b.x, y: b.y), Point(x: b.x, y: by2), Point(x: ax2, y: by2), Point(x: ax2, y: ay2), Point(x: a.x, y: ay2)]
        } else if cutLeft && !cutRight && !cutTop && !cutBottom {
            points = [Point(x: a.x, y: a.y), Point(x: ax2, y: a.y), Point(x: ax2, y: ay2), Point(x: a.x, y: ay2), Point(x: a.x, y: by2), Point(x: bx2, y: by2), Point(x: bx2, y: b.y), Point(x: a.x, y: b.y)]
        } else if cutTop && !cutBottom && !cutLeft && !cutRight {
            points = [Point(x: a.x, y: a.y), Point(x: b.x, y: a.y), Point(x: b.x, y: by2), Point(x: bx2, y: by2), Point(x: bx2, y: a.y), Point(x: ax2, y: a.y), Point(x: ax2, y: ay2), Point(x: a.x, y: ay2)]
        } else if cutBottom && !cutTop && !cutLeft && !cutRight {
            points = [Point(x: a.x, y: a.y), Point(x: ax2, y: a.y), Point(x: ax2, y: ay2), Point(x: bx2, y: ay2), Point(x: bx2, y: b.y), Point(x: b.x, y: b.y), Point(x: b.x, y: ay2), Point(x: a.x, y: ay2)]
        } else {
            return CanvasTransformEngine.rectanglePath(bounds: a)
        }
        return VectorPath(nodes: points.map { PathNode(x: $0.x, y: $0.y) }, closed: true)
    }

    private static func contour(
        grid: [Bool],
        cols: Int,
        rows: Int,
        originX: Double,
        originY: Double,
        cellW: Double,
        cellH: Double
    ) -> VectorPath {
        func filled(_ col: Int, _ row: Int) -> Bool {
            guard col >= 0, row >= 0, col < cols, row < rows else { return false }
            return grid[row * cols + col]
        }
        struct GPoint: Hashable {
            var c: Int
            var r: Int
        }
        var outgoing: [GPoint: GPoint] = [:]
        for row in 0..<rows {
            for col in 0..<cols where filled(col, row) {
                if !filled(col - 1, row) {
                    outgoing[GPoint(c: col, r: row + 1)] = GPoint(c: col, r: row)
                }
                if !filled(col, row - 1) {
                    outgoing[GPoint(c: col, r: row)] = GPoint(c: col + 1, r: row)
                }
                if !filled(col + 1, row) {
                    outgoing[GPoint(c: col + 1, r: row)] = GPoint(c: col + 1, r: row + 1)
                }
                if !filled(col, row + 1) {
                    outgoing[GPoint(c: col + 1, r: row + 1)] = GPoint(c: col, r: row + 1)
                }
            }
        }
        guard var current = outgoing.keys.first else {
            return VectorPath(nodes: [], closed: true)
        }
        let start = current
        var nodes: [PathNode] = []
        var seen = Set<GPoint>()
        repeat {
            nodes.append(PathNode(x: originX + Double(current.c) * cellW, y: originY + Double(current.r) * cellH))
            seen.insert(current)
            guard let next = outgoing[current], !seen.contains(next) || next == start else { break }
            current = next
        } while current != start && nodes.count < cols * rows * 4
        if nodes.count < 3 {
            return VectorPath(nodes: [], closed: true)
        }
        return VectorPath(nodes: nodes, closed: true)
    }
}
