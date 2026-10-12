import Foundation
import CoreGraphics

/// Fixed-interval grid snapping with magnetic pull radius.
enum SnapToGridEngine {
    static let magneticRadius: CGFloat = 6

    static func snap(_ value: Double, gridSize: CGFloat) -> Double {
        guard gridSize > 0 else { return value }
        let g = Double(gridSize)
        return (value / g).rounded() * g
    }

    /// Snaps only when within `threshold` of a grid line (Figma-style magnetic grid).
    static func snapIfNear(_ raw: Double, gridSize: CGFloat, threshold: CGFloat = magneticRadius) -> Double {
        guard gridSize > 0 else { return raw }
        let target = snap(raw, gridSize: gridSize)
        if abs(raw - target) <= Double(threshold) { return target }
        return raw
    }

    static func snapPoint(
        x: Double,
        y: Double,
        gridSize: CGFloat,
        threshold: CGFloat = magneticRadius
    ) -> (x: Double, y: Double) {
        (
            snapIfNear(x, gridSize: gridSize, threshold: threshold),
            snapIfNear(y, gridSize: gridSize, threshold: threshold)
        )
    }
}
