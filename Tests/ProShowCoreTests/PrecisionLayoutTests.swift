#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct PrecisionLayoutTests {
    @Test
    func snapToGrid_magneticRadius() {
        #expect(SnapToGridEngine.snapIfNear(15, gridSize: 16) == 16)
        #expect(SnapToGridEngine.snapIfNear(22, gridSize: 16) == 22)
        #expect(SnapToGridEngine.snap(33, gridSize: 16) == 32)
    }

    @Test
    func smartGuide_centerAlignsToCanvas() {
        let canvas = CanvasBounds(x: 0, y: 0, width: 1920, height: 1080)
        let result = SmartGuideEngine.compute(
            x: 958,
            y: 100,
            width: 40,
            height: 20,
            others: [],
            canvas: canvas,
            config: CanvasGridConfig(isSnapToGridEnabled: false, isSmartGuidesEnabled: true),
            bypass: false
        )
        #expect(abs(result.x - 940) < 0.001)
        #expect(result.state.activeGuides.contains(where: {
            if case .vertical(let x) = $0.direction { return abs(x - 960) < 0.5 }
            return false
        }))
    }

    @Test
    func contextBar_flipsBelowWhenNearTop() {
        let placement = ContextBarPositionCalculator.placement(
            selection: CanvasBounds(x: 100, y: 10, width: 80, height: 40),
            scale: 1,
            canvasOrigin: CGPoint(x: 0, y: 0),
            panOffset: .zero,
            viewportSize: CGSize(width: 800, height: 600),
            barSize: CGSize(width: 280, height: 34)
        )
        #expect(placement.anchor == .below)
        #expect(placement.origin.y >= 10 + 40 + 12 - 0.5)
    }

    @Test
    @MainActor
    func userGuide_deleteOffCanvasOrOnRuler() {
        let engine = GuideLineEngine()
        let canvas = CGSize(width: 1920, height: 1080)
        #expect(engine.shouldRemoveUserGuide(position: -20, axis: .horizontal, canvasSize: canvas, droppedInRuler: false))
        #expect(engine.shouldRemoveUserGuide(position: 1100, axis: .horizontal, canvasSize: canvas, droppedInRuler: false))
        #expect(engine.shouldRemoveUserGuide(position: 400, axis: .vertical, canvasSize: canvas, droppedInRuler: true))
        #expect(!engine.shouldRemoveUserGuide(position: 400, axis: .vertical, canvasSize: canvas, droppedInRuler: false))
        #expect(!engine.shouldRemoveUserGuide(position: 500, axis: .horizontal, canvasSize: canvas, droppedInRuler: false))
    }

    @Test
    func userGuide_droppedOnOriginatingRuler_onlyMatchingStrip() {
        let engine = GuideLineEngine()
        #expect(engine.droppedOnOriginatingRuler(axis: .vertical, workbenchPoint: CGPoint(x: 12, y: 400)))
        #expect(!engine.droppedOnOriginatingRuler(axis: .vertical, workbenchPoint: CGPoint(x: 12, y: 8)))
        #expect(!engine.droppedOnOriginatingRuler(axis: .vertical, workbenchPoint: CGPoint(x: 200, y: 400)))
        #expect(engine.droppedOnOriginatingRuler(axis: .horizontal, workbenchPoint: CGPoint(x: 200, y: 10)))
        #expect(!engine.droppedOnOriginatingRuler(axis: .horizontal, workbenchPoint: CGPoint(x: 200, y: 80)))
        #expect(!engine.droppedOnOriginatingRuler(axis: .horizontal, workbenchPoint: CGPoint(x: 8, y: 10)))
    }

    @Test
    func videoResizePreviewScaler_mapsBottomRightHandleResize() {
        let original = CanvasBounds(x: 100, y: 100, width: 200, height: 100)
        let live = CanvasBounds(x: 100, y: 100, width: 300, height: 150)
        let transform = VideoResizePreviewScaler.computePreviewTransform(originalBounds: original, liveBounds: live)
        let mapped = CGRect(x: 100, y: 100, width: 200, height: 100).applying(transform)
        #expect(abs(mapped.width - 300) < 0.01)
        #expect(abs(mapped.height - 150) < 0.01)
        #expect(abs(mapped.minX - 100) < 0.01)
        #expect(abs(mapped.minY - 100) < 0.01)
    }

    @Test
    func userGuide_keepsOnCanvasPositionWhenReleasedOffArtboard() {
        let engine = GuideLineEngine()
        let canvas = CGSize(width: 1920, height: 1080)
        let resolved = engine.resolvedUserGuidePositionAfterDrag(
            releasePosition: -40,
            storedPosition: 640,
            axis: .vertical,
            canvasSize: canvas,
            droppedInRuler: false
        )
        #expect(resolved == 640)
    }

    @Test
    func editorDocument_persistsUserGuides() throws {
        let guide = UserGuideLine(axis: .vertical, position: 640)
        let document = EditorDocument(name: "Slide", kind: .presentation, userGuides: [guide])
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(EditorDocument.self, from: data)
        #expect(decoded.userGuides == [guide])
    }

    @Test
    func smartGuide_snapsToUserGuideLine() {
        let canvas = CanvasBounds(x: 0, y: 0, width: 1920, height: 1080)
        let userGuides = [UserGuideLine(axis: .vertical, position: 400)]
        let result = SmartGuideEngine.compute(
            x: 395,
            y: 100,
            width: 40,
            height: 20,
            others: [],
            canvas: canvas,
            config: CanvasGridConfig(isSnapToGridEnabled: false, isSmartGuidesEnabled: true, snapToUserGuides: true),
            bypass: false,
            userGuides: userGuides
        )
        #expect(abs(result.x - 360) < 0.001)
    }

    @Test
    func alignmentController_distributeHorizontal() {
        var objects = [
            CanvasObject(name: "A", kind: .rectangle, bounds: CanvasBounds(x: 0, y: 0, width: 10, height: 10), zIndex: 1),
            CanvasObject(name: "B", kind: .rectangle, bounds: CanvasBounds(x: 20, y: 0, width: 10, height: 10), zIndex: 2),
            CanvasObject(name: "C", kind: .rectangle, bounds: CanvasBounds(x: 80, y: 0, width: 10, height: 10), zIndex: 3),
        ]
        AlignmentController.distribute(.horizontal, elements: &objects)
        let xs = objects.map(\.transform.x).sorted()
        let gapA = xs[1] - (xs[0] + 10)
        let gapB = xs[2] - (xs[1] + 10)
        #expect(abs(gapA - gapB) < 0.001)
    }
}
