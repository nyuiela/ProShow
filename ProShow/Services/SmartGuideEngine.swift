import Foundation
import CoreGraphics

/// Edge/center alignment guides, canvas midlines, and equal-spacing snap hints.
enum SmartGuideEngine {
    static let alignmentThreshold: CGFloat = 6
    static let spacingMatchThreshold: CGFloat = 4
    static let guideColorHex = "#FF0055"

    static func compute(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        others: [CanvasBounds],
        canvas: CanvasBounds,
        config: CanvasGridConfig,
        bypass: Bool,
        userGuides: [UserGuideLine] = []
    ) -> LayoutSnapResult {
        if bypass {
            return LayoutSnapResult(x: x, y: y, state: LayoutSnapState())
        }

        var nextX = x
        var nextY = y
        var guides: [SmartGuideLine] = []
        var badges: [EqualSpacingBadge] = []

        if config.isSnapToGridEnabled {
            let grid = SnapToGridEngine.snapPoint(
                x: nextX,
                y: nextY,
                gridSize: config.gridSizePoints
            )
            nextX = grid.x
            nextY = grid.y
        }

        if config.isSmartGuidesEnabled {
            let aligned = alignSnap(
                x: nextX,
                y: nextY,
                width: width,
                height: height,
                others: others,
                canvas: canvas,
                userGuides: config.snapToUserGuides ? userGuides : []
            )
            nextX = aligned.x
            nextY = aligned.y
            guides = aligned.guides

            let spaced = equalSpacingSnap(
                x: nextX,
                y: nextY,
                width: width,
                height: height,
                others: others
            )
            nextX = spaced.x
            nextY = spaced.y
            badges = spaced.badges
        }

        return LayoutSnapResult(
            x: nextX,
            y: nextY,
            state: LayoutSnapState(
                activeGuides: guides,
                spacingBadges: badges,
                snappedX: nextX,
                snappedY: nextY
            )
        )
    }

    private static func alignSnap(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        others: [CanvasBounds],
        canvas: CanvasBounds,
        userGuides: [UserGuideLine]
    ) -> (x: Double, y: Double, guides: [SmartGuideLine]) {
        var nextX = x
        var nextY = y
        var guides: [SmartGuideLine] = []
        let threshold = Double(alignmentThreshold)

        let canvasXTargets = [0.0, canvas.width / 2, canvas.width]
        let canvasYTargets = [0.0, canvas.height / 2, canvas.height]
        let userXTargets = userGuides.filter { $0.axis == .vertical }.map { Double($0.position) }
        let userYTargets = userGuides.filter { $0.axis == .horizontal }.map { Double($0.position) }
        let staticXTargets = others.flatMap { [$0.x, $0.x + $0.width / 2, $0.x + $0.width] } + userXTargets
        let staticYTargets = others.flatMap { [$0.y, $0.y + $0.height / 2, $0.y + $0.height] } + userYTargets

        let activeXEdges = [x, x + width / 2, x + width]
        let activeYEdges = [y, y + height / 2, y + height]

        if let hit = bestEdgeSnap(activeEdges: activeXEdges, targets: canvasXTargets + staticXTargets, threshold: threshold) {
            nextX += hit.delta
            let userAligned = userXTargets.contains(where: { abs($0 - hit.target) < 0.001 })
            guides.append(
                verticalGuide(
                    x: hit.target,
                    canvasHeight: canvas.height,
                    canvasAligned: canvasXTargets.contains(hit.target) || userAligned
                )
            )
        }

        if let hit = bestEdgeSnap(activeEdges: activeYEdges, targets: canvasYTargets + staticYTargets, threshold: threshold) {
            nextY += hit.delta
            let userAligned = userYTargets.contains(where: { abs($0 - hit.target) < 0.001 })
            guides.append(
                horizontalGuide(
                    y: hit.target,
                    canvasWidth: canvas.width,
                    canvasAligned: canvasYTargets.contains(hit.target) || userAligned
                )
            )
        }

        return (nextX, nextY, guides)
    }

    private struct EdgeHit {
        var delta: Double
        var target: Double
    }

    private static func bestEdgeSnap(
        activeEdges: [Double],
        targets: [Double],
        threshold: Double
    ) -> EdgeHit? {
        var best: EdgeHit?
        for edge in activeEdges {
            for target in targets {
                let delta = target - edge
                if abs(delta) <= threshold {
                    if best == nil || abs(delta) < abs(best!.delta) {
                        best = EdgeHit(delta: delta, target: target)
                    }
                }
            }
        }
        return best
    }

    private static func verticalGuide(x: Double, canvasHeight: Double, canvasAligned: Bool) -> SmartGuideLine {
        SmartGuideLine(
            direction: .vertical(x: CGFloat(x)),
            startPoint: CGPoint(x: x, y: 0),
            endPoint: CGPoint(x: x, y: canvasHeight),
            canvasAligned: canvasAligned
        )
    }

    private static func horizontalGuide(y: Double, canvasWidth: Double, canvasAligned: Bool) -> SmartGuideLine {
        SmartGuideLine(
            direction: .horizontal(y: CGFloat(y)),
            startPoint: CGPoint(x: 0, y: y),
            endPoint: CGPoint(x: canvasWidth, y: y),
            canvasAligned: canvasAligned
        )
    }

    private static func equalSpacingSnap(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        others: [CanvasBounds]
    ) -> (x: Double, y: Double, badges: [EqualSpacingBadge]) {
        guard others.count >= 2 else { return (x, y, []) }
        var nextX = x
        var nextY = y
        var badges: [EqualSpacingBadge] = []

        let h = horizontalSpacingSnap(x: x, width: width, others: others)
        if let snapX = h.snappedX {
            nextX = snapX
            badges.append(contentsOf: h.badges)
        }

        let v = verticalSpacingSnap(y: y, height: height, others: others)
        if let snapY = v.snappedY {
            nextY = snapY
            badges.append(contentsOf: v.badges)
        }

        return (nextX, nextY, badges)
    }

    private static func horizontalSpacingSnap(
        x: Double,
        width: Double,
        others: [CanvasBounds]
    ) -> (snappedX: Double?, badges: [EqualSpacingBadge]) {
        let sorted = others.sorted { $0.x < $1.x }
        let referenceGaps: [Double] = zip(sorted, sorted.dropFirst()).map { left, right in
            right.x - (left.x + left.width)
        }.filter { $0 >= 0 }

        guard !referenceGaps.isEmpty else { return (nil, []) }

        let leftNeighbor = sorted.last(where: { $0.x + $0.width <= x + 0.001 })
        let rightNeighbor = sorted.first(where: { $0.x >= x + width - 0.001 })

        if let left = leftNeighbor, let right = rightNeighbor {
            let gapLeft = x - (left.x + left.width)
            let gapRight = right.x - (x + width)
            if abs(gapLeft - gapRight) <= Double(spacingMatchThreshold), gapLeft >= 0, gapRight >= 0 {
                let equal = (gapLeft + gapRight) / 2
                let snappedX = left.x + left.width + equal
                let midY = max(left.y, min(left.y + left.height, right.y + right.height / 2))
                let badge = EqualSpacingBadge(
                    bounds: CGRect(
                        x: left.x + left.width + equal / 2 - 28,
                        y: midY - 10,
                        width: 56,
                        height: 20
                    ),
                    gapPx: CGFloat(equal.rounded()),
                    axis: .horizontal
                )
                return (snappedX, [badge])
            }
        }

        for gap in referenceGaps {
            if let left = leftNeighbor {
                let candidate = left.x + left.width + gap
                if abs(x - candidate) <= Double(spacingMatchThreshold) {
                    let badge = EqualSpacingBadge(
                        bounds: CGRect(x: candidate - 28, y: left.y + left.height / 2 - 10, width: 56, height: 20),
                        gapPx: CGFloat(gap.rounded()),
                        axis: .horizontal
                    )
                    return (candidate, [badge])
                }
            }
        }
        return (nil, [])
    }

    private static func verticalSpacingSnap(
        y: Double,
        height: Double,
        others: [CanvasBounds]
    ) -> (snappedY: Double?, badges: [EqualSpacingBadge]) {
        let sorted = others.sorted { $0.y < $1.y }
        let referenceGaps: [Double] = zip(sorted, sorted.dropFirst()).map { top, bottom in
            bottom.y - (top.y + top.height)
        }.filter { $0 >= 0 }

        guard !referenceGaps.isEmpty else { return (nil, []) }

        let topNeighbor = sorted.last(where: { $0.y + $0.height <= y + 0.001 })
        let bottomNeighbor = sorted.first(where: { $0.y >= y + height - 0.001 })

        if let top = topNeighbor, let bottom = bottomNeighbor {
            let gapTop = y - (top.y + top.height)
            let gapBottom = bottom.y - (y + height)
            if abs(gapTop - gapBottom) <= Double(spacingMatchThreshold), gapTop >= 0, gapBottom >= 0 {
                let equal = (gapTop + gapBottom) / 2
                let snappedY = top.y + top.height + equal
                let badge = EqualSpacingBadge(
                    bounds: CGRect(x: top.x + top.width / 2 - 28, y: top.y + top.height + equal / 2 - 10, width: 56, height: 20),
                    gapPx: CGFloat(equal.rounded()),
                    axis: .vertical
                )
                return (snappedY, [badge])
            }
        }

        for gap in referenceGaps {
            if let top = topNeighbor {
                let candidate = top.y + top.height + gap
                if abs(y - candidate) <= Double(spacingMatchThreshold) {
                    let badge = EqualSpacingBadge(
                        bounds: CGRect(x: top.x + top.width / 2 - 28, y: candidate - 10, width: 56, height: 20),
                        gapPx: CGFloat(gap.rounded()),
                        axis: .vertical
                    )
                    return (candidate, [badge])
                }
            }
        }
        return (nil, [])
    }
}
