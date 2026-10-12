import Foundation
import CoreGraphics

enum SmartMeasurementEngine {
    static let alignTolerance = 0.5
    static let skipThreshold = 0.5

    static func calculateOverlayState(
        optionHeld: Bool,
        selectedID: UUID?,
        hoveredID: UUID?,
        selectedBounds: CanvasBounds,
        targetBounds: CanvasBounds,
        measuringToCanvas: Bool
    ) -> SmartMeasurementOverlayState {
        var state = SmartMeasurementOverlayState(
            isOptionKeyHeld: optionHeld,
            selectedElementId: selectedID,
            hoveredElementId: measuringToCanvas ? nil : hoveredID,
            selectedBounds: selectedBounds.cgRect,
            targetBounds: targetBounds.cgRect
        )
        guard optionHeld, selectedID != nil else { return state }

        state.measurementVectors = vectors(from: selectedBounds, to: targetBounds)
        if !measuringToCanvas {
            state.projectionLines = projections(from: selectedBounds, to: targetBounds)
        }
        state.targetDimensionLabel = dimensionLabel(targetBounds)
        state.targetDimensionPosition = CGPoint(x: targetBounds.midX, y: targetBounds.maxY + 14)
        return state
    }

    static func formatDistance(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded())) px"
        }
        return String(format: "%.1f px", rounded)
    }

    static func dimensionLabel(_ bounds: CanvasBounds) -> String {
        let width = formatNumber(bounds.width)
        let height = formatNumber(bounds.height)
        return "\(width) × \(height)"
    }

    private static func formatNumber(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 0.05 {
            return "\(Int(rounded.rounded()))"
        }
        return String(format: "%.1f", rounded)
    }

    private static func vectors(from a: CanvasBounds, to b: CanvasBounds) -> [SmartMeasurementVector] {
        var items: [SmartMeasurementVector] = []
        if a.maxY < b.minY {
            items.append(
                vector(
                    id: "gap-v",
                    from: CGPoint(x: a.overlapMidX(with: b), y: a.maxY),
                    to: CGPoint(x: a.overlapMidX(with: b), y: b.minY),
                    vertical: true
                )
            )
        } else if a.minY > b.maxY {
            items.append(
                vector(
                    id: "gap-v",
                    from: CGPoint(x: a.overlapMidX(with: b), y: b.maxY),
                    to: CGPoint(x: a.overlapMidX(with: b), y: a.minY),
                    vertical: true
                )
            )
        } else {
            appendEdge(
                &items,
                id: "edge-top",
                from: CGPoint(x: a.overlapMidX(with: b), y: a.minY),
                to: CGPoint(x: a.overlapMidX(with: b), y: b.minY),
                vertical: true
            )
            appendEdge(
                &items,
                id: "edge-bottom",
                from: CGPoint(x: a.overlapMidX(with: b), y: a.maxY),
                to: CGPoint(x: a.overlapMidX(with: b), y: b.maxY),
                vertical: true
            )
        }

        if a.maxX < b.minX {
            items.append(
                vector(
                    id: "gap-h",
                    from: CGPoint(x: a.maxX, y: a.overlapMidY(with: b)),
                    to: CGPoint(x: b.minX, y: a.overlapMidY(with: b)),
                    vertical: false
                )
            )
        } else if a.minX > b.maxX {
            items.append(
                vector(
                    id: "gap-h",
                    from: CGPoint(x: b.maxX, y: a.overlapMidY(with: b)),
                    to: CGPoint(x: a.minX, y: a.overlapMidY(with: b)),
                    vertical: false
                )
            )
        } else {
            appendEdge(
                &items,
                id: "edge-left",
                from: CGPoint(x: a.minX, y: a.overlapMidY(with: b)),
                to: CGPoint(x: b.minX, y: a.overlapMidY(with: b)),
                vertical: false
            )
            appendEdge(
                &items,
                id: "edge-right",
                from: CGPoint(x: a.maxX, y: a.overlapMidY(with: b)),
                to: CGPoint(x: b.maxX, y: a.overlapMidY(with: b)),
                vertical: false
            )
        }
        return items
    }

    private static func appendEdge(
        _ items: inout [SmartMeasurementVector],
        id: String,
        from: CGPoint,
        to: CGPoint,
        vertical: Bool
    ) {
        let distance = vertical ? abs(to.y - from.y) : abs(to.x - from.x)
        guard distance >= skipThreshold else { return }
        items.append(vector(id: id, from: from, to: to, vertical: vertical))
    }

    private static func vector(id: String, from: CGPoint, to: CGPoint, vertical: Bool) -> SmartMeasurementVector {
        let distance = vertical ? abs(to.y - from.y) : abs(to.x - from.x)
        return SmartMeasurementVector(
            id: id,
            startPoint: from,
            endPoint: to,
            distancePx: distance,
            labelText: formatDistance(distance),
            isVertical: vertical
        )
    }

    private static func projections(from a: CanvasBounds, to b: CanvasBounds) -> [CGPoint] {
        var points: [CGPoint] = []
        if abs(a.minX - b.minX) <= alignTolerance {
            points.append(CGPoint(x: a.minX, y: min(a.minY, b.minY)))
            points.append(CGPoint(x: a.minX, y: max(a.maxY, b.maxY)))
        }
        if abs(a.maxX - b.maxX) <= alignTolerance {
            points.append(CGPoint(x: a.maxX, y: min(a.minY, b.minY)))
            points.append(CGPoint(x: a.maxX, y: max(a.maxY, b.maxY)))
        }
        if abs(a.minY - b.minY) <= alignTolerance {
            points.append(CGPoint(x: min(a.minX, b.minX), y: a.minY))
            points.append(CGPoint(x: max(a.maxX, b.maxX), y: a.minY))
        }
        if abs(a.maxY - b.maxY) <= alignTolerance {
            points.append(CGPoint(x: min(a.minX, b.minX), y: a.maxY))
            points.append(CGPoint(x: max(a.maxX, b.maxX), y: a.maxY))
        }
        return points
    }
}
