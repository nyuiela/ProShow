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
        #expect(model.rundownBlocks[2].programSlideID != nil)
        #expect(model.programSlides.count == 3)

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
    }
}
