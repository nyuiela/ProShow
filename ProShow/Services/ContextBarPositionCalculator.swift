import CoreGraphics
import Foundation

enum ContextBarAnchor: Equatable {
    case above
    case below
}

struct ContextBarPlacement: Equatable {
    var origin: CGPoint
    var anchor: ContextBarAnchor
}

enum ContextBarPositionCalculator {
    static let barHeight: CGFloat = 34
    static let offset: CGFloat = 12
    static let viewportTopMargin: CGFloat = 40

    /// Maps canvas-space selection bounds to workspace coordinates for the context bar's top-leading corner.
    static func placement(
        selection: CanvasBounds,
        scale: CGFloat,
        canvasOrigin: CGPoint,
        panOffset: CGSize,
        viewportSize: CGSize,
        barSize: CGSize
    ) -> ContextBarPlacement {
        let selMinX = canvasOrigin.x + panOffset.width + selection.minX * scale
        let selMinY = canvasOrigin.y + panOffset.height + selection.minY * scale
        let selW = selection.width * scale
        let selH = selection.height * scale

        let centerX = selMinX + selW / 2
        let aboveTop = selMinY - barSize.height - offset
        let anchor: ContextBarAnchor
        let topY: CGFloat
        if aboveTop < viewportTopMargin {
            anchor = .below
            topY = selMinY + selH + offset
        } else {
            anchor = .above
            topY = aboveTop
        }

        var leadingX = centerX - barSize.width / 2
        let maxX = max(0, viewportSize.width - barSize.width)
        leadingX = min(max(0, leadingX), maxX)

        var clampedTop = topY
        let maxY = max(0, viewportSize.height - barSize.height)
        clampedTop = min(max(0, clampedTop), maxY)

        return ContextBarPlacement(origin: CGPoint(x: leadingX, y: clampedTop), anchor: anchor)
    }
}
