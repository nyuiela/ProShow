#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct ParityTests {
    @Test @MainActor
    func timersAndMessages_areFirstClass() {
        let engine = CompositorEngine()
        engine.setTimers([OutputTimer(id: UUID(), name: "Service", seconds: 90)])
        engine.setMessages([OutputMessage(id: UUID(), text: "Welcome")])
        #expect(engine.stack.timers.first?.name == "Service")
        #expect(engine.stack.messages.first?.text == "Welcome")
        #expect(engine.stack.message == "Welcome")
        #expect(engine.stack.isVisible(.messages, onStage: false))
        engine.setMaskEnabled(true)
        #expect(engine.stack.mask.enabled)
        #expect(engine.stack.mask.kind == "vignette")
    }

    @Test @MainActor
    func editCanvas_persistsElements() throws {
        let store = LibraryStore.temporary()
        let controller = TestSupport.sampleController(store: store)
        controller.select(controller.show.allSlides[0].id)
        controller.updateSelectedSlide(alignment: "left")
        controller.addCanvasElement(text: "Title block", alignment: "left")
        #expect(controller.selectedSlide?.alignment == "left")
        #expect(controller.selectedSlide?.elements.contains(where: { $0.text == "Title block" }) == true)
        let reloaded = store.loadAll().first(where: { $0.id == controller.show.id })
        #expect(reloaded?.allSlides.first?.alignment == "left")
        #expect(reloaded?.allSlides.first?.elements.isEmpty == false)
    }

    @Test
    func videoInputKinds_activateWithoutHardware() {
        let camera = VideoInputSource(id: UUID(), label: "Mac Cam", kind: .camera)
        let ndi = VideoInputSource(id: UUID(), label: "NDI 1", kind: .ndi, endpoint: "ndi://studio")
        let rtsp = VideoInputSource(id: UUID(), label: "Deck", kind: .rtsp, endpoint: "rtsp://127.0.0.1/in")
        let card = VideoInputSource(id: UUID(), label: "SDI", kind: .captureCard)
        #expect(VideoInputRuntime.activate(camera) != .unsupported("x"))
        if case .unsupported = VideoInputRuntime.activate(ndi) { #expect(true) } else { Issue.record("NDI should be unsupported in CI") }
        if case .unsupported = VideoInputRuntime.activate(rtsp) { #expect(true) } else { Issue.record("RTSP should be unsupported in CI") }
        if case .unsupported = VideoInputRuntime.activate(card) { #expect(true) } else { Issue.record("Capture card should be unsupported in CI") }
        #expect(VideoInputRuntime.deactivate(camera))
    }

    @Test @MainActor
    func videoInput_setsLayerWithoutCrash() {
        let controller = TestSupport.sampleController()
        let source = VideoInputSource(id: UUID(), label: "Mac Cam", kind: .camera)
        controller.activateVideoInput(source)
        #expect(controller.compositor.stack.videoInput?.label == "Mac Cam")
        controller.deactivateVideoInput()
        #expect(controller.compositor.stack.isCleared(.videoInput))
    }

    @Test @MainActor
    func relayFanOut_staysSingleEncode() {
        let engine = StreamingEngine()
        let transport = MockStreamTransport()
        engine.transport = transport
        engine.setRelayDestinations([
            RelayDestination(name: "YouTube", url: "rtmps://a.relay/live", streamKey: "yt"),
            RelayDestination(name: "Facebook", url: "rtmps://a.relay/live", streamKey: "fb"),
        ])
        #expect(engine.config.outboundURLs.count == 2)
        #expect(engine.start())
        #expect(transport.connectCount == 1)
        #expect(engine.encoderSettings?.width == 1920)
        engine.stop()
        #expect(transport.disconnectCount == 1)
    }

    @Test
    func screenCatalog_lookNames() {
        #expect(ScreenCatalog.look(named: AudienceLookConfig.alphaKey.name).alphaKeySlideOnly)
        #expect(!ScreenCatalog.availableScreens().isEmpty)
    }
}
