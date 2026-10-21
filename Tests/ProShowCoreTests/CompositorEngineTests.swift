#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct CompositorEngineTests {
    @Test
    func audienceCanvas_keepsFullBleedVideoWhenTransparent() {
        var plate = CanvasObject(
            name: "Media",
            kind: .image,
            bounds: CanvasBounds(x: 0, y: 0, width: CanvasConfig.width, height: CanvasConfig.height),
            zIndex: 0,
            text: ""
        )
        plate.fill.type = .image
        plate.fill.imageURI = "/tmp/old-loop.mp4"
        let lyric = CanvasObject(
            name: "Lyric",
            kind: .text,
            bounds: .centered(width: 1600, height: 200),
            zIndex: 1,
            text: "Grace"
        )
        let slide = Slide(
            title: "Chorus",
            lines: ["Grace"],
            canvas: [plate, lyric],
            backgroundEnabled: false
        )
        let canvas = slide.audienceCanvas()
        #expect(slide.paintsOpaqueBackground == false)
        #expect(canvas.count == 2)
        #expect(canvas.contains(where: { $0.text == "Grace" }))
        #expect(canvas.contains(where: { $0.isFullBleedBackground(canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height) }))
        let cue = OutputCue.make(slide: slide, presentationId: UUID(), index: 0)
        #expect(cue.layers.slideBackgroundEnabled == false)
        #expect(cue.layers.slideCanvas?.contains(where: { $0.isFullBleedBackground(canvasWidth: CanvasConfig.width, canvasHeight: CanvasConfig.height) }) == true)
    }

    @Test
    func audienceCanvas_keepsFullBleedBrowserOnTransparentSlides() {
        var browser = CanvasObject(
            name: "Browser",
            kind: .browser,
            bounds: .canvas,
            zIndex: 0,
            fillHex: "#000000"
        )
        browser.assignedSource = AssignedMediaSource(
            sourceID: "https://example.com",
            name: "Example",
            sourceType: .webPage,
            category: .network,
            connectionString: "https://example.com",
            tintHex: "#000000"
        )
        browser.fill.type = .image
        browser.fill.imageURI = "https://example.com"
        let text = CanvasObject(
            name: "Title",
            kind: .text,
            bounds: .centered(width: 800, height: 120),
            zIndex: 1,
            text: "Hello"
        )
        let slide = Slide(
            title: "Page",
            lines: [],
            isBlank: true,
            canvas: [browser, text],
            backgroundEnabled: true
        )
        let canvas = slide.audienceCanvas()
        #expect(canvas.count == 2)
        #expect(canvas.contains(where: { $0.kind.isBrowserLike }))
        #expect(canvas.contains(where: { $0.text == "Hello" }))
    }

    @Test
    func transparentSlide_doesNotPaintProgramMediaBackdrop() {
        var stack = RenderStack.idle
        stack.media = TestSupport.mediaAction()
        stack.slideBackgroundEnabled = false
        stack.slideElements = [SlideElement(text: "Grace")]
        #expect(stack.drawsProgramMediaBackdrop(onStage: false) == true)

        stack.slideBackgroundEnabled = true
        #expect(stack.drawsProgramMediaBackdrop(onStage: false) == true)

        stack.slideBackgroundEnabled = false
        stack.slideElements = []
        #expect(stack.drawsProgramMediaBackdrop(onStage: false) == true)

        stack.slideElements = [SlideElement(text: "Grace")]
        stack.cleared.insert(RenderLayer.slide.rawValue)
        #expect(stack.drawsProgramMediaBackdrop(onStage: false) == true)
    }

    @Test @MainActor
    func triggerCue_slideOnly_leavesMedia() {
        let engine = CompositorEngine()
        let media = TestSupport.mediaAction()
        engine.triggerCue(
            OutputCue(id: UUID(), presentationId: UUID(), slideIndex: 0, layers: CueLayers(mediaAction: media))
        )
        engine.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 1,
                layers: CueLayers(slideText: [SlideElement(text: "Grace")])
            )
        )
        #expect(engine.stack.media?.title == "Loop")
        #expect(engine.stack.slideElements.first?.text == "Grace")
        #expect(!engine.stack.isCleared(.media))
    }

    @Test @MainActor
    func clearMedia_hidesLayer3_keepsSlide() {
        let engine = CompositorEngine()
        engine.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 0,
                layers: CueLayers(
                    slideText: [SlideElement(text: "Stay")],
                    mediaAction: TestSupport.mediaAction()
                )
            )
        )
        engine.clear(.media)
        #expect(engine.stack.isCleared(.media))
        #expect(!engine.stack.isVisible(.media, onStage: false))
        #expect(engine.stack.media?.title == "Loop")
        #expect(engine.stack.slideElements.first?.text == "Stay")
        #expect(engine.stack.isVisible(.slide, onStage: false))
        engine.restore(.media)
        #expect(!engine.stack.isCleared(.media))
        #expect(engine.stack.isVisible(.media, onStage: false))
        #expect(engine.stack.media?.title == "Loop")
    }

    @Test @MainActor
    func lookAlphaKey_hidesMediaOnAudience_keepsSlide() {
        let engine = CompositorEngine()
        engine.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 0,
                layers: CueLayers(
                    slideText: [SlideElement(text: "Alpha")],
                    mediaAction: TestSupport.mediaAction(),
                    lookAction: .alphaKey
                )
            )
        )
        #expect(engine.stack.isVisible(.slide, onStage: false))
        #expect(!engine.stack.isVisible(.media, onStage: false))
        #expect(engine.stack.isVisible(.slide, onStage: true))
    }

    @Test @MainActor
    func clearDefaultLayers_clearsSlideMediaVideoInput() {
        let engine = CompositorEngine()
        engine.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 0,
                layers: CueLayers(
                    slideText: [SlideElement(text: "A")],
                    mediaAction: TestSupport.mediaAction(),
                    videoInputAction: VideoInputSource(id: UUID(), label: "Cam")
                )
            )
        )
        engine.clearDefaultLayers()
        #expect(engine.stack.isCleared(.slide))
        #expect(engine.stack.isCleared(.media))
        #expect(engine.stack.isCleared(.videoInput))
    }

    @Test @MainActor
    func toggleProp_addsThenRemoves() {
        let engine = CompositorEngine()
        engine.toggleProp("Bug")
        #expect(engine.stack.activeProps == ["Bug"])
        engine.toggleProp("Bug")
        #expect(engine.stack.activeProps.isEmpty)
    }

    @Test @MainActor
    func audioAction_doesNotOverwriteMessages() {
        let engine = CompositorEngine()
        engine.setMessage("Alert")
        engine.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 0,
                layers: CueLayers(audioAction: AudioTrack(id: UUID(), title: "Pad"))
            )
        )
        #expect(engine.stack.audio?.title == "Pad")
        #expect(engine.stack.message == "Alert")
    }

    @Test @MainActor
    func assignLook_toScreen2_doesNotChangePrimaryUntilScreen1() {
        let engine = CompositorEngine()
        engine.assignLook(.alphaKey, toScreenID: "screen-2")
        #expect(engine.look(forScreenID: "screen-2").name == AudienceLookConfig.alphaKey.name)
        #expect(engine.stack.look.name == AudienceLookConfig.fullStack.name)
        engine.assignLook(.slideAndMedia, toScreenID: "screen-1")
        #expect(engine.stack.look.name == AudienceLookConfig.slideAndMedia.name)
    }

    @Test
    func videoOnlyStreamEncode_eligibleForFullFrameScreenShare() {
        var stack = RenderStack.idle
        stack.videoInput = VideoInputSource(
            id: UUID(),
            label: "Display",
            kind: .screenShare,
            endpoint: "sck://display/0"
        )
        #expect(
            ProgramOutputComposer.eligibleForVideoOnlyStreamEncode(
                stack: stack,
                propCanvases: [],
                programTransition: nil
            )
        )
        stack.slideCanvas = [
            CanvasObject(name: "Title", kind: .text, bounds: CanvasBounds(x: 0, y: 0, width: 400, height: 80))
        ]
        #expect(
            !ProgramOutputComposer.eligibleForVideoOnlyStreamEncode(
                stack: stack,
                propCanvases: [],
                programTransition: nil
            )
        )
    }

    @Test
    func liveVideoRouting_slideOnlyLookUsesProgramInputOnCanvas() {
        var stack = RenderStack.idle
        stack.videoInput = VideoInputSource(
            id: UUID(),
            label: "Display",
            kind: .screenShare,
            endpoint: "sck://display/1"
        )
        stack.look = .alphaKey
        let camera = AssignedMediaSource(
            sourceID: "cam",
            name: "Camera",
            sourceType: .systemCamera,
            category: .videoCapture,
            connectionString: "avf://cam"
        )
        #expect(!stack.isVisible(.videoInput, onStage: false))
        #expect(
            ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: camera,
                objectKind: .rectangle,
                programInput: stack.videoInput,
                showsProgramVideoLayer: stack.isVisible(.videoInput, onStage: false)
            )
        )
    }

    @Test
    func liveVideoRouting_broadcastForcesProgramVideoOnCameraSlots() {
        let screen = VideoInputSource(
            id: UUID(),
            label: "Display",
            kind: .screenShare,
            endpoint: "sck://display/1"
        )
        let camera = AssignedMediaSource(
            sourceID: "cam",
            name: "Camera",
            sourceType: .systemCamera,
            category: .videoCapture,
            connectionString: "avf://cam"
        )
        #expect(
            !ProgramLiveVideoRouting.broadcastCanvasUsesProgramVideo(
                assigned: camera,
                objectKind: .rectangle,
                programInput: screen
            )
        )
    }

    @Test
    func liveVideoRouting_broadcastKeepsDisplayAssignment() {
        let screen = VideoInputSource(
            id: UUID(),
            label: "Display",
            kind: .screenShare,
            endpoint: "sck://display/1"
        )
        let display = AssignedMediaSource(
            sourceID: "display",
            name: "Display",
            sourceType: .systemDisplay,
            category: .videoCapture,
            connectionString: "sck://display/99"
        )
        #expect(
            !ProgramLiveVideoRouting.broadcastCanvasUsesProgramVideo(
                assigned: display,
                objectKind: .rectangle,
                programInput: screen
            )
        )
    }

    @Test
    func liveVideoRouting_videoWellShowsProgramCameraWhileLayerIsVisible() {
        var stack = RenderStack.idle
        stack.videoInput = VideoInputSource(
            id: UUID(),
            label: "FaceTime",
            kind: .camera,
            endpoint: "avf://built-in"
        )
        #expect(stack.isVisible(.videoInput, onStage: false))
        #expect(
            ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: nil,
                objectKind: .videoInput,
                programInput: stack.videoInput,
                showsProgramVideoLayer: true
            )
        )
        let same = AssignedMediaSource(
            sourceID: "avf://built-in",
            name: "FaceTime",
            sourceType: .systemCamera,
            category: .videoCapture,
            connectionString: "avf://built-in"
        )
        #expect(
            ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: same,
                objectKind: .videoInput,
                programInput: stack.videoInput,
                showsProgramVideoLayer: true
            )
        )
        let other = AssignedMediaSource(
            sourceID: "ndi://other",
            name: "Other",
            sourceType: .ndiSource,
            category: .videoCapture,
            connectionString: "ndi://other"
        )
        #expect(
            !ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: other,
                objectKind: .videoInput,
                programInput: stack.videoInput,
                showsProgramVideoLayer: true
            )
        )
    }

    @Test
    func liveVideoRouting_fullStackKeepsAssignedCameraOnCanvas() {
        var stack = RenderStack.idle
        stack.videoInput = VideoInputSource(
            id: UUID(),
            label: "Display",
            kind: .screenShare,
            endpoint: "sck://display/1"
        )
        let camera = AssignedMediaSource(
            sourceID: "cam",
            name: "Camera",
            sourceType: .systemCamera,
            category: .videoCapture,
            connectionString: "avf://cam"
        )
        #expect(stack.isVisible(.videoInput, onStage: false))
        #expect(
            !ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: camera,
                objectKind: .rectangle,
                programInput: stack.videoInput,
                showsProgramVideoLayer: stack.isVisible(.videoInput, onStage: false)
            )
        )
    }

    @Test
    func liveVideoRouting_previewWellsKeepTheirOwnDevice() {
        let screen = VideoInputSource(id: UUID(), label: "Display", kind: .screenShare, endpoint: "sck://display/1")
        let camera = AssignedMediaSource(
            sourceID: "cam", name: "Camera", sourceType: .systemCamera,
            category: .videoCapture, connectionString: "avf://cam", placeholderLetter: "A"
        )
        let display = AssignedMediaSource(
            sourceID: "display", name: "Display", sourceType: .systemDisplay,
            category: .videoCapture, connectionString: "sck://display/1", placeholderLetter: "B"
        )
        let emptySlot = AssignedMediaSource(
            sourceID: "placeholder-A", name: "A", sourceType: .placeholderSlot,
            category: .placeholders, connectionString: "placeholder://A", placeholderLetter: "A"
        )
        for layer in [true, false] {
            // Camera well beside a screen-share slide input keeps the camera.
            #expect(!ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: camera, objectKind: .videoInput, programInput: screen,
                showsProgramVideoLayer: layer, wellsKeepOwnDevice: true))
            #expect(!ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: camera, objectKind: .rectangle, programInput: screen,
                showsProgramVideoLayer: layer, wellsKeepOwnDevice: true))
            // Same device shares the slide input.
            #expect(ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: display, objectKind: .videoInput, programInput: screen,
                showsProgramVideoLayer: layer, wellsKeepOwnDevice: true))
            // Unassigned video well shares it; an unfilled placeholder does not.
            #expect(ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: nil, objectKind: .videoInput, programInput: screen,
                showsProgramVideoLayer: layer, wellsKeepOwnDevice: true))
            #expect(!ProgramLiveVideoRouting.canvasUsesProgramInput(
                assigned: emptySlot, objectKind: .videoInput, programInput: screen,
                showsProgramVideoLayer: layer, wellsKeepOwnDevice: true))
        }
    }
}
