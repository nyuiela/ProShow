import Foundation
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum CanvasTransformEngine {
    static let snapRadius = 6.0
    static let rotationHandleOffset = 24.0
    static let angleIncrement = 15.0

    static func resize(
        _ bounds: CanvasBounds,
        handle: TransformHandle,
        deltaX: Double,
        deltaY: Double,
        lockAspect: Bool,
        fromCenter: Bool
    ) -> CanvasBounds {
        TransformHandleEngine.resize(
            bounds,
            handle: handle,
            deltaX: deltaX,
            deltaY: deltaY,
            lockAspect: lockAspect,
            fromCenter: fromCenter
        )
    }

    static func constrainAspect(_ lockAspect: Bool, shiftHeld: Bool) -> Bool {
        TransformHandleEngine.constrainAspect(lockAspect, shiftHeld: shiftHeld)
    }

    static func defaultLockAspect(for kind: CanvasObjectKind, locked: Bool) -> Bool {
        switch kind {
        case .image, .videoInput, .webView, .browser:
            return true
        default:
            return locked
        }
    }

    static func angle(from originX: Double, originY: Double, to x: Double, toY y: Double) -> Double {
        atan2(y - originY, x - originX) * 180 / .pi
    }

    static func rotate(from startAngle: Double, to currentAngle: Double, baseRotation: Double, snap15: Bool) -> Double {
        TransformHandleEngine.rotate(
            from: startAngle,
            to: currentAngle,
            baseRotation: baseRotation,
            snap15: snap15
        )
    }

    static func originPoint(in bounds: CanvasBounds, originX: Double, originY: Double) -> (x: Double, y: Double) {
        (bounds.x + bounds.width * originX, bounds.y + bounds.height * originY)
    }

    static func shear(_ bounds: CanvasBounds, handle: TransformHandle, delta: Double) -> (shearX: Double, shearY: Double) {
        switch handle {
        case .top, .bottom:
            return (delta / max(bounds.height, 1), 0)
        default:
            return (0, delta / max(bounds.width, 1))
        }
    }

    static func clampCornerRadius(_ radius: Double, bounds: CanvasBounds) -> Double {
        min(max(0, radius), min(bounds.width, bounds.height) / 2)
    }

    static func unlinkCorners(_ radius: Double) -> CornerRadii {
        .uniform(radius)
    }

    static func rectanglePath(bounds: CanvasBounds) -> VectorPath {
        VectorPath(
            nodes: [
                PathNode(x: bounds.x, y: bounds.y),
                PathNode(x: bounds.x + bounds.width, y: bounds.y),
                PathNode(x: bounds.x + bounds.width, y: bounds.y + bounds.height),
                PathNode(x: bounds.x, y: bounds.y + bounds.height),
            ],
            closed: true
        )
    }

    static func moveNode(_ path: VectorPath, id: UUID, x: Double, y: Double) -> VectorPath {
        var next = path
        guard let index = next.nodes.firstIndex(where: { $0.id == id }) else { return path }
        let dx = x - next.nodes[index].x
        let dy = y - next.nodes[index].y
        next.nodes[index].x = x
        next.nodes[index].y = y
        next.nodes[index].inX += dx
        next.nodes[index].inY += dy
        next.nodes[index].outX += dx
        next.nodes[index].outY += dy
        return next
    }

    static func setNodeKind(_ path: VectorPath, id: UUID, kind: PathNodeKind) -> VectorPath {
        var next = path
        guard let index = next.nodes.firstIndex(where: { $0.id == id }) else { return path }
        next.nodes[index].kind = kind
        if kind == .symmetric || kind == .smooth {
            let dx = next.nodes[index].outX - next.nodes[index].x
            let dy = next.nodes[index].outY - next.nodes[index].y
            next.nodes[index].inX = next.nodes[index].x - dx
            next.nodes[index].inY = next.nodes[index].y - dy
            if kind == .symmetric {
                next.nodes[index].inX = next.nodes[index].x - dx
                next.nodes[index].inY = next.nodes[index].y - dy
            }
        }
        return next
    }

    static func dragSmoothHandle(_ path: VectorPath, id: UUID, outX: Double, outY: Double) -> VectorPath {
        var next = path
        guard let index = next.nodes.firstIndex(where: { $0.id == id }) else { return path }
        next.nodes[index].outX = outX
        next.nodes[index].outY = outY
        if next.nodes[index].kind == .smooth || next.nodes[index].kind == .symmetric {
            let dx = outX - next.nodes[index].x
            let dy = outY - next.nodes[index].y
            let length = (dx * dx + dy * dy).squareRoot()
            let inLength: Double
            if next.nodes[index].kind == .symmetric {
                inLength = length
            } else {
                let ix = next.nodes[index].inX - next.nodes[index].x
                let iy = next.nodes[index].inY - next.nodes[index].y
                inLength = (ix * ix + iy * iy).squareRoot()
            }
            if length > 0 {
                next.nodes[index].inX = next.nodes[index].x - dx / length * inLength
                next.nodes[index].inY = next.nodes[index].y - dy / length * inLength
            }
        }
        return next
    }

    static func bendSegment(_ path: VectorPath, from: Int, deltaX: Double, deltaY: Double) -> VectorPath {
        guard path.nodes.count > 1 else { return path }
        let start = path.nodes[from]
        let end = path.nodes[(from + 1) % path.nodes.count]
        var next = path
        next.nodes[from].kind = .smooth
        next.nodes[from].outX = start.x + (end.x - start.x) / 3 + deltaX
        next.nodes[from].outY = start.y + (end.y - start.y) / 3 + deltaY
        let endIndex = (from + 1) % path.nodes.count
        next.nodes[endIndex].kind = .smooth
        next.nodes[endIndex].inX = end.x - (end.x - start.x) / 3 + deltaX
        next.nodes[endIndex].inY = end.y - (end.y - start.y) / 3 + deltaY
        return next
    }

    static func join(_ a: VectorPath, _ b: VectorPath) -> VectorPath {
        VectorPath(nodes: a.nodes + b.nodes, closed: false)
    }

    static func cut(_ path: VectorPath, at index: Int) -> [VectorPath] {
        guard path.nodes.indices.contains(index), path.nodes.count > 1 else { return [path] }
        let left = VectorPath(nodes: Array(path.nodes.prefix(index + 1)), closed: false)
        let right = VectorPath(nodes: Array(path.nodes.suffix(from: index)), closed: false)
        return [left, right]
    }

    static func boolean(_ a: CanvasBounds, _ b: CanvasBounds, operation: BooleanOperation) -> CanvasBounds {
        switch operation {
        case .union:
            let minX = min(a.x, b.x)
            let minY = min(a.y, b.y)
            let maxX = max(a.x + a.width, b.x + b.width)
            let maxY = max(a.y + a.height, b.y + b.height)
            return CanvasBounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .subtract:
            return a
        case .intersect:
            let minX = max(a.x, b.x)
            let minY = max(a.y, b.y)
            let maxX = min(a.x + a.width, b.x + b.width)
            let maxY = min(a.y + a.height, b.y + b.height)
            return CanvasBounds(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        case .exclude:
            return boolean(a, b, operation: .union)
        }
    }

    static func snap(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        others: [CanvasBounds],
        canvas: CanvasBounds,
        bypass: Bool
    ) -> (x: Double, y: Double, guides: [SmartGuide]) {
        let config = CanvasGridConfig(isGridVisible: false, isSnapToGridEnabled: false, isSmartGuidesEnabled: true)
        let result = SmartGuideEngine.compute(
            x: x,
            y: y,
            width: width,
            height: height,
            others: others,
            canvas: canvas,
            config: config,
            bypass: bypass
        )
        return (result.x, result.y, result.state.legacyGuides)
    }

    static func distance(from a: CanvasBounds, to b: CanvasBounds) -> DistanceReadout {
        let gapX: Double
        if a.x + a.width < b.x {
            gapX = b.x - (a.x + a.width)
        } else if b.x + b.width < a.x {
            gapX = a.x - (b.x + b.width)
        } else {
            gapX = 0
        }
        let gapY: Double
        if a.y + a.height < b.y {
            gapY = b.y - (a.y + a.height)
        } else if b.y + b.height < a.y {
            gapY = a.y - (b.y + b.height)
        } else {
            gapY = 0
        }
        return DistanceReadout(
            dx: (b.x + b.width / 2) - (a.x + a.width / 2),
            dy: (b.y + b.height / 2) - (a.y + a.height / 2),
            gapX: gapX,
            gapY: gapY
        )
    }

    static func equalGaps(_ items: [CanvasBounds], horizontal: Bool) -> [CanvasBounds] {
        let sorted = items.sorted { horizontal ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3, let first = sorted.first, let last = sorted.last else { return items }
        if horizontal {
            let span = (last.x + last.width) - first.x
            let occupied = sorted.reduce(0) { $0 + $1.width }
            let gap = (span - occupied) / Double(sorted.count - 1)
            var cursor = first.x
            return sorted.map { item in
                let next = CanvasBounds(x: cursor, y: item.y, width: item.width, height: item.height)
                cursor += item.width + gap
                return next
            }
        }
        let span = (last.y + last.height) - first.y
        let occupied = sorted.reduce(0) { $0 + $1.height }
        let gap = (span - occupied) / Double(sorted.count - 1)
        var cursor = first.y
        return sorted.map { item in
            let next = CanvasBounds(x: item.x, y: cursor, width: item.width, height: item.height)
            cursor += item.height + gap
            return next
        }
    }

    static func scaleGaps(_ gaps: [Double], delta: Double) -> [Double] {
        gaps.map { max(0, $0 + delta) }
    }

    static func autoLayout(
        children: [CanvasBounds],
        container: CanvasBounds,
        layout: AutoLayoutFrame
    ) -> (frame: CanvasBounds, children: [CanvasBounds]) {
        guard layout.enabled else { return (container, children) }
        let pad = layout.padding
        var cursorX = container.x + pad.left
        var cursorY = container.y + pad.top
        var rowHeight = 0.0
        var laid: [CanvasBounds] = []
        var maxX = cursorX
        var maxY = cursorY
        let innerWidth = max(1, container.width - pad.left - pad.right)
        for (index, child) in children.enumerated() {
            var width = child.width
            var height = child.height
            if layout.childSizing == .fill {
                if layout.direction == .horizontal {
                    width = max(1, (innerWidth - layout.gap * Double(max(children.count - 1, 0))) / Double(max(children.count, 1)))
                } else {
                    height = max(1, (container.height - pad.top - pad.bottom - layout.gap * Double(max(children.count - 1, 0))) / Double(max(children.count, 1)))
                }
            }
            if layout.wrap, layout.direction == .horizontal, cursorX + width > container.x + container.width - pad.right, index > 0 {
                cursorX = container.x + pad.left
                cursorY += rowHeight + layout.gap
                rowHeight = 0
            }
            laid.append(CanvasBounds(x: cursorX, y: cursorY, width: width, height: height))
            if layout.direction == .horizontal {
                cursorX += width + layout.gap
                rowHeight = max(rowHeight, height)
            } else {
                cursorY += height + layout.gap
            }
            maxX = max(maxX, laid[index].x + laid[index].width)
            maxY = max(maxY, laid[index].y + laid[index].height)
        }
        var frame = container
        if layout.childSizing == .hug {
            frame.width = max(1, maxX + pad.right - container.x)
            frame.height = max(1, maxY + pad.bottom - container.y)
        }
        return (frame, laid)
    }

    static func fittedTextBounds(text: String, fontSize: Double, mode: TextFrameMode, current: CanvasBounds) -> CanvasBounds {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 0
        let estimatedWidth = max(40, Double(longest) * fontSize * 0.55)
        let estimatedHeight = max(fontSize * 1.2, Double(max(lines.count, 1)) * fontSize * 1.2)
        switch mode {
        case .autoWidth:
            return CanvasBounds(x: current.x, y: current.y, width: estimatedWidth, height: estimatedHeight)
        case .autoHeight:
            return CanvasBounds(x: current.x, y: current.y, width: current.width, height: estimatedHeight)
        case .fixed:
            return current
        }
    }

    static func textOverflows(text: String, fontSize: Double, bounds: CanvasBounds) -> Bool {
        let needed = fittedTextBounds(text: text, fontSize: fontSize, mode: .autoHeight, current: bounds)
        return needed.height > bounds.height + 0.5 || needed.width > bounds.width + 0.5
    }

    static func convertTextToPath(text: String, bounds: CanvasBounds) -> VectorPath {
        convertTextToPath(text: text, bounds: bounds, fontFamily: "Helvetica", fontSize: max(12, bounds.height * 0.6))
    }

    static func convertTextToPath(
        text: String,
        bounds: CanvasBounds,
        fontFamily: String,
        fontSize: Double
    ) -> VectorPath {
        #if canImport(CoreText) && canImport(CoreGraphics)
        let resolved = fontFamily.isEmpty ? "Helvetica" : fontFamily
        let font = CTFontCreateWithName(resolved as CFString, fontSize, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, (text.isEmpty ? "A" : text) as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var nodes: [PathNode] = []
        for run in runs {
            let glyphCount = CTRunGetGlyphCount(run)
            var glyphs = Array(repeating: CGGlyph(), count: glyphCount)
            var positions = Array(repeating: CGPoint.zero, count: glyphCount)
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphCount), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: glyphCount), &positions)
            for index in 0..<glyphCount {
                guard let glyphPath = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                let offset = positions[index]
                apply(glyphPath, dx: bounds.x + Double(offset.x), dy: bounds.y + Double(offset.y), into: &nodes)
            }
        }
        if nodes.count >= 3 {
            return VectorPath(nodes: nodes, closed: true)
        }
        #endif
        var fallback: [PathNode] = []
        let letters = max(1, text.count)
        let width = bounds.width / Double(letters)
        for index in 0..<letters {
            let x = bounds.x + Double(index) * width
            fallback.append(contentsOf: rectanglePath(bounds: CanvasBounds(x: x, y: bounds.y, width: max(4, width * 0.7), height: bounds.height)).nodes)
        }
        return VectorPath(nodes: fallback, closed: true)
    }

    #if canImport(CoreGraphics)
    private static func apply(_ path: CGPath, dx: Double, dy: Double, into nodes: inout [PathNode]) {
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                nodes.append(PathNode(x: dx + Double(element.points[0].x), y: dy + Double(element.points[0].y)))
            case .addQuadCurveToPoint:
                nodes.append(
                    PathNode(
                        x: dx + Double(element.points[1].x),
                        y: dy + Double(element.points[1].y),
                        inX: dx + Double(element.points[0].x),
                        inY: dy + Double(element.points[0].y),
                        kind: .smooth
                    )
                )
            case .addCurveToPoint:
                nodes.append(
                    PathNode(
                        x: dx + Double(element.points[2].x),
                        y: dy + Double(element.points[2].y),
                        inX: dx + Double(element.points[1].x),
                        inY: dy + Double(element.points[1].y),
                        outX: dx + Double(element.points[0].x),
                        outY: dy + Double(element.points[0].y),
                        kind: .smooth
                    )
                )
            default:
                break
            }
        }
    }
    #endif
}
