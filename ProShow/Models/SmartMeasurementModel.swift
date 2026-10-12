import Foundation
import CoreGraphics

struct SmartMeasurementVector: Identifiable, Equatable, Sendable {
    var id: String
    var startPoint: CGPoint
    var endPoint: CGPoint
    var distancePx: Double
    var labelText: String
    var isVertical: Bool
}

struct SmartMeasurementOverlayState: Equatable, Sendable {
    var isOptionKeyHeld: Bool = false
    var selectedElementId: UUID? = nil
    var hoveredElementId: UUID? = nil

    var selectedBounds: CGRect = .zero
    var targetBounds: CGRect = .zero

    var measurementVectors: [SmartMeasurementVector] = []
    var projectionLines: [CGPoint] = []
    var targetDimensionLabel: String? = nil
    var targetDimensionPosition: CGPoint = .zero

    var isActive: Bool {
        isOptionKeyHeld && selectedElementId != nil && !measurementVectors.isEmpty
    }
}
