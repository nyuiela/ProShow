#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct SmartMeasurementEngineTests {
    @Test
    func testNonOverlappingElementsGapCalculation() {
        let selected = CanvasBounds(x: 80, y: 40, width: 200, height: 60)
        let hovered = CanvasBounds(x: 80, y: 124, width: 180, height: 40)
        let state = SmartMeasurementEngine.calculateOverlayState(
            optionHeld: true,
            selectedID: UUID(),
            hoveredID: UUID(),
            selectedBounds: selected,
            targetBounds: hovered,
            measuringToCanvas: false
        )
        let vertical = state.measurementVectors.first { $0.id == "gap-v" }
        #expect(vertical != nil)
        #expect(abs((vertical?.distancePx ?? 0) - 24) < 0.001)
        #expect(vertical?.labelText == "24 px")
        #expect(vertical?.isVertical == true)
        #expect(state.targetDimensionLabel == "180 × 40")
        #expect(state.projectionLines.count >= 2)
    }

    @Test
    func testCanvasEdgeFallbackMeasurement() {
        let selected = CanvasBounds(x: 240, y: 120, width: 200, height: 80)
        let canvas = CanvasBounds(x: 0, y: 0, width: 1920, height: 1080)
        let state = SmartMeasurementEngine.calculateOverlayState(
            optionHeld: true,
            selectedID: UUID(),
            hoveredID: nil,
            selectedBounds: selected,
            targetBounds: canvas,
            measuringToCanvas: true
        )
        let byID = Dictionary(uniqueKeysWithValues: state.measurementVectors.map { ($0.id, $0.distancePx) })
        #expect(abs((byID["edge-top"] ?? 0) - 120) < 0.001)
        #expect(abs((byID["edge-left"] ?? 0) - 240) < 0.001)
        #expect(abs((byID["edge-bottom"] ?? 0) - 880) < 0.001)
        #expect(abs((byID["edge-right"] ?? 0) - 1480) < 0.001)
        #expect(state.hoveredElementId == nil)
        #expect(state.targetDimensionLabel == "1920 × 1080")
        #expect(state.projectionLines.isEmpty)
    }

    @Test
    func optionReleased_clearsVectors() {
        let selected = CanvasBounds(x: 10, y: 10, width: 40, height: 40)
        let other = CanvasBounds(x: 10, y: 80, width: 40, height: 20)
        let state = SmartMeasurementEngine.calculateOverlayState(
            optionHeld: false,
            selectedID: UUID(),
            hoveredID: UUID(),
            selectedBounds: selected,
            targetBounds: other,
            measuringToCanvas: false
        )
        #expect(state.measurementVectors.isEmpty)
        #expect(state.isActive == false)
    }
}
