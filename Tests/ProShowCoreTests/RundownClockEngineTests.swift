#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct RundownClockEngineTests {
    @Test @MainActor
    func drift_isZeroAtHardStart() {
        let engine = RundownClockEngine()
        var program = ProgramDocumentModel.sundayMorningSample()
        program.hardStartTime = Date()
        engine.loadProgram(program)
        engine.startShow()
        let drift = engine.cumulativeDriftSeconds
        #expect(abs(drift) < 2.0)
    }

    @Test @MainActor
    func advance_movesActiveIndex() {
        let engine = RundownClockEngine()
        engine.loadProgram(ProgramDocumentModel.sundayMorningSample())
        engine.startShow()
        #expect(engine.activeBlockIndex == 0)
        engine.advanceToNextBlock()
        #expect(engine.activeBlockIndex == 1)
        #expect(engine.program?.rundownBlocks[0].isCompleted == true)
    }

    @Test
    func documentRoundTrip() throws {
        let model = ProgramDocumentModel.sundayMorningSample()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProgramDocumentStore.save(model, to: dir)
        let loaded = try ProgramDocumentStore.load(from: dir)
        #expect(loaded.rundownBlocks.count == model.rundownBlocks.count)
        #expect(loaded.talentDatabase.first?.fullName == model.talentDatabase.first?.fullName)
    }

    @Test
    func programOutlinePresentation_materializesPageSlidesOnly() {
        var model = ProgramDocumentModel.sundayMorningSample()
        model.rundownBlocks[0].screenDirections = [
            ScreenDirection(kind: .url, label: "Luma", url: "https://luma.com/event")
        ]
        model.rundownBlocks[1].screenDirections = [ScreenDirection(kind: .camera, label: "Cam 1")]
        ProgramOutlinePresentation.syncProgramSlides(in: &model)
        #expect(model.rundownBlocks[0].programSlideID != nil)
        #expect(model.rundownBlocks[1].programSlideID != nil)
        #expect(model.programSlides.count == 2)
        let show = ProgramOutlinePresentation.makeShow(from: model)
        #expect(show.allSlides.count == 2)
        #expect(show.allSlides[0].canvas.first?.kind == .browser)

        var displayOnly = RundownBlock(itemNumber: "003", title: "Desk", segmentType: .keynote, plannedDurationSeconds: 60)
        displayOnly.screenDirections = [ScreenDirection(kind: .unknown, label: "display", rawKind: "display")]
        model.rundownBlocks.append(displayOnly)
        ProgramOutlinePresentation.syncProgramSlides(in: &model)
        #expect(model.rundownBlocks[2].programSlideID == nil)
        #expect(model.programSlides.count == 2)

        var scriptOnly = RundownBlock(itemNumber: "006", title: "Script", segmentType: .keynote, plannedDurationSeconds: 90)
        RundownBlockSlideSource.apply(.blank, to: &scriptOnly)
        model.rundownBlocks.append(scriptOnly)
        ProgramOutlinePresentation.syncProgramSlides(in: &model)
        #expect(model.rundownBlocks.last?.programSlideID == nil)
        #expect(ProgramOutlinePresentation.makeShow(from: model).allSlides.count == 2)

        let block = model.rundownBlocks[0]
        let url = ProgramOutlinePresentation.resolvedPageURL(for: block, in: model)
        #expect(url == "https://luma.com/event")
        #expect(ProgramOutlinePresentation.programSlide(for: block, in: model)?.canvas.first?.kind == .browser)

        let libraryShowID = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        let librarySlideID = UUID(uuidString: "B2C3D4E5-F6A7-8901-BCDE-F12345678901")!
        var librarySlide = Slide(id: librarySlideID, title: "Keynote opener", label: "1")
        var browser = CanvasObject(name: "Browser", kind: .browser, bounds: .canvas)
        browser.assignedSource = AssignedMediaSource(
            sourceID: "https://example.com/deck",
            name: "example.com",
            sourceType: .webPage,
            category: .network,
            connectionString: "https://example.com/deck",
            tintHex: "#000000"
        )
        browser.fill.type = .image
        browser.fill.imageURI = "https://example.com/deck"
        librarySlide.canvas = [browser]
        let libraryShow = Show(
            id: libraryShowID,
            name: "Sunday Keynote",
            groups: [SlideGroup(name: "Main", colorHex: "#333333", slides: [librarySlide])]
        )

        var linkedRow = RundownBlock(itemNumber: "004", title: "Guest deck", segmentType: .keynote, plannedDurationSeconds: 300)
        linkedRow.linkedPresentationShowID = libraryShowID
        linkedRow.linkedPresentationSlideID = librarySlideID
        model.rundownBlocks.append(linkedRow)
        let ownedBefore = model.programSlides.count
        ProgramOutlinePresentation.syncProgramSlides(
            in: &model,
            showLookup: { id in id == libraryShowID ? libraryShow : nil }
        )
        let linked = model.rundownBlocks.last!
        #expect(linked.programSlideID == nil)
        #expect(linked.linkedPresentationShowID == libraryShowID)
        #expect(linked.linkedPresentationSlideID == librarySlideID)
        #expect(model.programSlides.count == ownedBefore)
        #expect(ProgramOutlinePresentation.makeShow(from: model).allSlides.count == ownedBefore)
        let resolved = ProgramOutlinePresentation.programSlide(
            for: linked,
            in: model,
            showLookup: { id in id == libraryShowID ? libraryShow : nil }
        )
        #expect(resolved?.id == librarySlideID)
        #expect(ProgramOutlinePresentation.resolvedPageURL(
            for: linked,
            in: model,
            showLookup: { id in id == libraryShowID ? libraryShow : nil }
        ) == "https://example.com/deck")

        var ownedCamera = RundownBlock(itemNumber: "005", title: "Host cam", segmentType: .keynote, plannedDurationSeconds: 120)
        ownedCamera.programSlideID = UUID(uuidString: "C3C3C3C3-C3C3-C3C3-C3C3-C3C3C3C3C3C3")!
        ownedCamera.linkedPresentationShowID = libraryShowID
        ownedCamera.linkedPresentationSlideID = librarySlideID
        ownedCamera.screenDirections = [ScreenDirection(kind: .camera, label: "Camera")]
        var staleModel = ProgramDocumentModel.sundayMorningSample()
        staleModel.rundownBlocks = [ownedCamera]
        ProgramOutlinePresentation.sanitizeOutlineSlideBindings(in: &staleModel)
        #expect(staleModel.rundownBlocks[0].linkedPresentationSlideID == nil)
        #expect(RundownBlockSlideSource.resolve(staleModel.rundownBlocks[0]) == .camera)

        var staleCamera = ProgramDocumentModel.sundayMorningSample()
        staleCamera.rundownBlocks[1].screenDirections = [ScreenDirection(kind: .camera, label: "Camera")]
        var broken = makeCameraProgramSlide(
            id: staleCamera.rundownBlocks[1].programSlideID ?? UUID(),
            title: staleCamera.rundownBlocks[1].title,
            itemNumber: staleCamera.rundownBlocks[1].itemNumber
        )
        broken.canvas.insert(
            CanvasObject(name: "Browser", kind: .browser, bounds: .canvas, zIndex: 1, text: "", fillHex: "#000"),
            at: 0
        )
        staleCamera.programSlides = [broken]
        staleCamera.rundownBlocks[1].programSlideID = broken.id
        let repaired = ProgramOutlinePresentation.repairStoredProgramDocument(in: &staleCamera)
        #expect(repaired)
        let fixed = staleCamera.programSlides.first(where: { $0.id == broken.id })
        #expect(fixed?.canvas.contains(where: { $0.kind == .videoInput }) == true)
        #expect(fixed?.canvas.contains(where: { $0.kind.isBrowserLike }) != true)
    }

    @Test
    func programOutline_assignCameraAndMediaCreatesSlidesInRundownOrder() {
        var model = ProgramDocumentModel.sundayMorningSample()
        let cameraIndex = 1
        for index in model.rundownBlocks.indices {
            model.rundownBlocks[index].programSlideID = nil
        }
        var cameraBlock = model.rundownBlocks[cameraIndex]
        let cameraSlideID = UUID()
        RundownBlockSlideSource.apply(.camera, to: &cameraBlock)
        cameraBlock.programSlideID = cameraSlideID
        cameraBlock.screenDirections = [
            ScreenDirection(kind: .camera, label: "Front camera", url: "avf://front"),
        ]
        model.rundownBlocks[cameraIndex] = cameraBlock
        model.programSlides = [
            Slide(
                id: cameraSlideID,
                title: cameraBlock.title,
                lines: [],
                isBlank: true,
                canvas: [],
                themeApplication: .native,
                backgroundEnabled: false
            ),
        ]

        ProgramOutlinePresentation.syncProgramSlide(
            at: cameraIndex,
            in: &model,
            rebuildFromSource: true
        )

        let cameraSlide = model.programSlides.first(where: { $0.id == cameraSlideID })
        #expect(cameraSlide?.isBlank == false)
        #expect(cameraSlide?.canvas.contains(where: { $0.kind == .videoInput }) == true)
        #expect(cameraSlide?.canvas.first?.assignedSource?.connectionString == "avf://front")

        var kept = cameraSlide!
        kept.canvas[0].assignedSource = AssignedMediaSource(
            sourceID: "ndi://studio",
            name: "Studio NDI",
            sourceType: .ndiSource,
            category: .videoCapture,
            connectionString: "ndi://studio"
        )
        model.programSlides[model.programSlides.firstIndex(where: { $0.id == cameraSlideID })!] = kept
        model.rundownBlocks[cameraIndex].screenDirections = [ScreenDirection(kind: .camera, label: "Camera")]
        ProgramOutlinePresentation.syncProgramSlide(
            at: cameraIndex,
            in: &model,
            rebuildFromSource: true
        )
        let preserved = model.programSlides.first(where: { $0.id == cameraSlideID })
        #expect(preserved?.canvas.first?.assignedSource?.connectionString == "ndi://studio")

        var shown = ProgramDocumentModel.sundayMorningSample()
        let slideID = shown.rundownBlocks[0].programSlideID ?? UUID()
        shown.rundownBlocks[0].programSlideID = slideID
        shown.rundownBlocks[0].screenDirections = [ScreenDirection(kind: .camera, label: "Camera")]
        var assignedSlide = Slide(id: slideID, title: shown.rundownBlocks[0].title, lines: [], isBlank: false, canvas: [])
        var video = CanvasObject(name: "Studio NDI", kind: .videoInput, bounds: .canvas, zIndex: 0, text: "", fillHex: "#000000")
        video.assignedSource = AssignedMediaSource(
            sourceID: "ndi://studio",
            name: "Studio NDI",
            sourceType: .ndiSource,
            category: .videoCapture,
            connectionString: "ndi://studio"
        )
        assignedSlide.canvas = [video]
        shown.programSlides = [assignedSlide]
        let show = Show(id: ProgramOutlinePresentation.showID, name: ".program", groups: [SlideGroup(name: "Program", colorHex: "#000", slides: [assignedSlide])])
        ProgramOutlinePresentation.applyShow(show, to: &shown)
        #expect(shown.rundownBlocks[0].screenDirections.first?.url == "ndi://studio")

        var mediaBlock = RundownBlock(itemNumber: "009", title: "Bumper", segmentType: .keynote, plannedDurationSeconds: 30)
        RundownBlockSlideSource.apply(.mediaFile("/tmp/bumper.mp4"), to: &mediaBlock)
        model.rundownBlocks.append(mediaBlock)
        ProgramOutlinePresentation.syncProgramSlide(
            at: model.rundownBlocks.count - 1,
            in: &model,
            rebuildFromSource: true
        )
        let media = model.programSlides.first(where: { $0.id == model.rundownBlocks.last?.programSlideID })
        #expect(media?.isBlank == false)
        #expect(media?.mediaAction?.filePath == "/tmp/bumper.mp4")

        model.programSlides.reverse()
        let ordered = ProgramOutlinePresentation.makeShow(from: model).allSlides.map(\.id)
        let expected = model.rundownBlocks.compactMap(\.programSlideID)
        #expect(ordered == expected)
    }
}

private func makeCameraProgramSlide(id: UUID, title: String, itemNumber: String) -> Slide {
    var slide = Slide(
        id: id,
        title: title,
        lines: [],
        notes: "",
        isBlank: true,
        canvas: [],
        label: itemNumber,
        backgroundEnabled: false,
        backgroundHex: "#000000"
    )
    var object = CanvasObject(
        name: "Camera",
        kind: .videoInput,
        bounds: .canvas,
        zIndex: 0,
        text: "",
        fillHex: "#000000"
    )
    object.visibleOnAudience = true
    slide.canvas = [object]
    return slide
}
