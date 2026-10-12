import Foundation
import Testing

@Suite
struct CanvasLayerPanelTests {
    @Test
    func layerKind_mapsCanvasObjectKinds() {
        #expect(LayerKind.from(kind: .videoInput) == .camera)
        #expect(LayerKind.from(kind: .text) == .text)
        #expect(LayerKind.from(kind: .rectangle) == .shape)
    }

    @Test @MainActor
    func compositionPanel_usesProgramStackInShowMode() {
        let controller = TestSupport.sampleController()
        controller.setMode(.show)
        controller.goLive(slideID: controller.show.allSlides[0].id)
        let slide = controller.show.allSlides[0]
        guard !slide.canvas.isEmpty else { return }
        #expect(!controller.compositionCanvasObjects.isEmpty)
    }

    @Test @MainActor
    func compositionPanel_ignoresLibrarySelectionWhenLive() {
        let controller = TestSupport.sampleController()
        let slides = controller.show.allSlides
        guard slides.count >= 2 else { return }
        let live = slides[0]
        let other = slides[1]
        controller.setMode(.show)
        controller.goLive(slideID: live.id)
        controller.selectSlide(id: other.id)
        let liveNames = Set(live.canvas.map(\.name))
        let otherNames = Set(other.canvas.map(\.name))
        guard !liveNames.isEmpty, liveNames != otherNames else { return }
        let panelNames = Set(controller.compositionCanvasObjects.map(\.name))
        #expect(panelNames.isSubset(of: liveNames) || !controller.compositor.stack.slideCanvas.isEmpty)
        #expect(!panelNames.isSubset(of: otherNames.subtracting(liveNames)))
    }

    @Test
    func layerStore_ordersFrontToBack() {
        let objects = [
            CanvasObject(name: "Back", kind: .rectangle, bounds: .centered(width: 100, height: 100), zIndex: 1),
            CanvasObject(name: "Front", kind: .text, bounds: .centered(width: 200, height: 80), zIndex: 3),
        ]
        let items = CanvasLayerStore.layerItems(from: objects)
        #expect(items.first?.name == "Front")
        #expect(items.last?.name == "Back")
    }
}
