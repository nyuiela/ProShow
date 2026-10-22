#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct OutlineScriptCompilerTests {
    private let sample = """
    FORMAT 1
    SHOW Stellar 14: Mon 5 Oct, intro, 16:00-17:00 GMT
    DATE 2026-10-05
    HARDSTART 2026-10-05T16:00:00Z

    ITEM 1
    TITLE What Stellar is
    TYPE Keynote Speaker
    START 2026-10-05T16:00:00Z
    DURATION 60
    LOCK hard
    TALENT Kaleel
    AUDIO Kaleel, host mic.
    LOWERTHIRD on
    CUE 0 NEXT MINUTE

    SAY
    Good afternoon. I am Kaleel.
    [PAUSE:1]
    This hour is the map. What Stellar is, where the opportunities are, which libraries you will touch, and how funding works.

    SHOW
    camera
    slide Stellar 14 title
    note Title slide only. Do not take the trial Intro item.

    LINKS
    Luma series | https://luma.com/ptk31d3s | say no | take no

    NOTES
    Git and pull requests are a separate hour. They are not on this clock.
    """

    @Test
    func format1_splitsSpokenCopyFromScreenAndLinks() throws {
        let kaleel = TalentProfile(fullName: "Kaleel", titleOrRole: "Host")
        let compiled = try OutlineScriptCompiler.compile(sample, talent: [kaleel])
        let block = try #require(compiled.document.rundownBlocks.first)
        #expect(compiled.warnings.isEmpty)
        #expect(compiled.document.showTitle == "Stellar 14: Mon 5 Oct, intro, 16:00-17:00 GMT")
        #expect(compiled.document.outlineFormat == 1)
        #expect(block.scriptBody == "Good afternoon. I am Kaleel.\n[PAUSE:1]\nThis hour is the map. What Stellar is, where the opportunities are, which libraries you will touch, and how funding works.")
        #expect(!block.scriptBody.contains("http"))
        #expect(!block.scriptBody.contains("ON SCREEN"))
        #expect(block.screenDirections.map(\.kind) == [.camera, .slide, .note])
        #expect(block.screenDirections[1].label == "Stellar 14 title")
        #expect(block.linkCues.first?.label == "Luma series")
        #expect(block.linkCues.first?.speakOnAir == false)
        #expect(block.linkCues.first?.autoTake == false)
        #expect(block.linkedPlaylistId == nil)
        #expect(block.referenceNotes.contains("separate hour"))
        #expect(block.videoCue == "Camera. Slide: Stellar 14 title.")
        #expect(block.autoFireLowerThirdOnStart)
        #expect(block.isHardTimeLocked)
        #expect(block.assignedTalentIds == [kaleel.id])
        #expect(block.customCueTriggers.map(\.stageMessage) == ["NEXT MINUTE"])
        #expect(block.customCueTriggers.first?.triggerOffsetSeconds == 0)
    }

    @Test
    func unknownTalent_failsTheCompile() {
        #expect(throws: OutlineScriptError.unknownTalent("Kaleel")) {
            try OutlineScriptCompiler.compile(sample, talent: [])
        }
    }

    @Test
    func legacyLabeledScript_movesLabelsOutOfTheSpokenBody() {
        var block = RundownBlock(itemNumber: "001", title: "Welcome", segmentType: .opener, plannedDurationSeconds: 60)
        block.scriptBody = """
        KALEEL:
        The code of conduct is stellar.org/foundation/code-of-conduct. If something is off, tell me in this chat.

        ON SCREEN:
        Camera. Title slide: Stellar 14.

        LINKS TO SAY:
        https://stellar.org/foundation/code-of-conduct

        REFERENCE:
        Stellar code of conduct.
        """
        let inherited = [StageCueTrigger(triggerOffsetSeconds: -60, stageMessage: "1 MINUTE REMAINING")]
        OutlineScriptCompiler.splitLegacyLabeledScript(&block, documentCues: inherited)
        #expect(block.scriptBody == "The code of conduct is stellar.org/foundation/code-of-conduct. If something is off, tell me in this chat.")
        #expect(block.screenDirections.map(\.kind) == [.camera, .slide])
        #expect(block.screenDirections[1].label == "Stellar 14")
        #expect(block.linkCues.first?.speakOnAir == true)
        #expect(block.linkCues.first?.autoTake == false)
        #expect(block.referenceNotes == "Stellar code of conduct.")
        #expect(block.customCueTriggers.first?.stageMessage == "NEXT MINUTE")
        #expect(block.customCueTriggers.first?.triggerOffsetSeconds == 0)
    }

    @Test
    func oldProgram_opensWithoutNewKeysAndKeepsTheScript() throws {
        let json = """
        {
          "showTitle": "Legacy",
          "rundownBlocks": [
            {
              "title": "Welcome",
              "segmentType": "Opener / Intro",
              "plannedDurationSeconds": 180,
              "scriptBody": "Stand by.\\n[PAUSE:1]\\nRoll the opener."
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(ProgramDocumentModel.self, from: Data(json.utf8))
        let block = try #require(loaded.rundownBlocks.first)
        #expect(loaded.outlineFormat == 1)
        #expect(block.scriptBody == "Stand by.\n[PAUSE:1]\nRoll the opener.")
        #expect(block.screenDirections.isEmpty)
        #expect(block.linkCues.isEmpty)
        #expect(block.referenceNotes == "")
        #expect(block.extensions.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(loaded)
        let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let savedBlock = (saved?["rundownBlocks"] as? [[String: Any]])?.first
        #expect(saved?["outlineFormat"] as? Int == 1)
        #expect(savedBlock?["scriptBody"] as? String == block.scriptBody)
        #expect(savedBlock?["screenDirections"] as? [Any] != nil)
        #expect(savedBlock?["extensions"] as? [String: String] == [:])
    }

    @Test
    func nextCut_usesCameraOrThePage() throws {
        let kaleel = TalentProfile(fullName: "Kaleel", titleOrRole: "Host")
        let compiled = try OutlineScriptCompiler.compile(sample, talent: [kaleel])
        let block = try #require(compiled.document.rundownBlocks.first)
        let cameraCut = RundownProgramCut.resolve(block)
        #expect(cameraCut.picture == .camera)
        #expect(cameraCut.effectivePicture == .camera)
        #expect(cameraCut.pageURL == "https://luma.com/ptk31d3s")

        var screen = RundownBlock(itemNumber: "002", title: "Foundation", segmentType: .keynote, plannedDurationSeconds: 60)
        screen.screenDirections = [
            ScreenDirection(kind: .url, label: "Foundation", url: "http://stellar.org/foundation")
        ]
        let screenCut = RundownProgramCut.resolve(screen)
        #expect(screenCut.effectivePicture == .display)
        #expect(screenCut.pageURL == "http://stellar.org/foundation")

        var bare = RundownBlock(itemNumber: "003", title: "Page", segmentType: .keynote, plannedDurationSeconds: 60)
        bare.linkCues = [LinkCue(label: "Foundation", url: "stellar.org/foundation")]
        let bareCut = RundownProgramCut.resolve(bare)
        #expect(bareCut.picture == nil)
        #expect(bareCut.effectivePicture == .display)
        #expect(bareCut.pageURL == "https://stellar.org/foundation")

        var displayWord = RundownBlock(itemNumber: "004", title: "Desk", segmentType: .keynote, plannedDurationSeconds: 60)
        displayWord.screenDirections = [ScreenDirection(kind: .unknown, label: "display", rawKind: "display")]
        #expect(RundownProgramCut.resolve(displayWord).effectivePicture == .display)
    }

    @Test func readablePageZoom_fitsWidthNotFullScrollHeight() {
        let viewW = 1920.0
        let wideShort = ProgramPageViewport.readablePageZoom(viewWidth: viewW, pageWidth: 960)
        #expect(wideShort == 1)

        let typical = ProgramPageViewport.readablePageZoom(viewWidth: viewW, pageWidth: 1440)
        #expect(typical == 1)

        let veryWide = ProgramPageViewport.readablePageZoom(viewWidth: viewW, pageWidth: 3840)
        #expect(veryWide == 0.5)

        let fullPageShrink = min(viewW / 1920, 1080 / 8000)
        let readable = ProgramPageViewport.readablePageZoom(viewWidth: viewW, pageWidth: 1920)
        #expect(readable == 1)
        #expect(readable > fullPageShrink)
    }

    @Test func samePage_ignoresTrailingSlashAndFragment() {
        #expect(PromptWebsiteURL.samePage(
            "https://communityfund.stellar.org",
            "https://communityfund.stellar.org/"
        ))
        #expect(PromptWebsiteURL.samePage(
            "https://communityfund.stellar.org",
            "https://communityfund.stellar.org/#awards"
        ))
        #expect(!PromptWebsiteURL.samePage(
            "https://communityfund.stellar.org",
            "https://stellar.org"
        ))
    }
}

@Suite struct CameraRowBackgroundTests {
    /// Camera row with its own designed canvas: full-frame background art plus a camera well.
    private func designedCameraModel(slideBackground: Bool, boardBackground: Bool) -> (ProgramDocumentModel, UUID) {
        var model = ProgramDocumentModel.sundayMorningSample()
        let id = model.rundownBlocks[1].programSlideID ?? UUID()
        model.rundownBlocks[1].programSlideID = id
        model.rundownBlocks[1].screenDirections = [ScreenDirection(kind: .camera, label: "Camera")]
        var slide = cameraRowTestSlide(id: id, title: model.rundownBlocks[1].title, itemNumber: model.rundownBlocks[1].itemNumber)
        slide.isBlank = false
        slide.backgroundEnabled = slideBackground
        slide.backgroundHex = "#F4ECDD"
        var art = CanvasObject(name: "Background", kind: .image, bounds: .canvas, zIndex: 0, text: "", fillHex: "#F4ECDD")
        art.visibleOnAudience = true
        slide.canvas[0].bounds = CanvasBounds(x: 2896, y: 360, width: 800, height: 800)
        slide.canvas.insert(art, at: 0)
        slide.editorCanvases = [
            EditorCanvasFrame(id: UUID(), name: "Stream", width: 3840, height: 2160, originX: 0, originY: 0,
                              isPrimary: true, backgroundEnabled: boardBackground, backgroundHex: "#F4ECDD"),
        ]
        model.programSlides = [slide]
        return (model, id)
    }

    @Test
    func staleLibraryProgramShowGoesOnAirFromRepairedDocument() {
        var (model, id) = designedCameraModel(slideBackground: false, boardBackground: true)
        let stale = ProgramOutlinePresentation.makeShow(from: model)
        _ = ProgramOutlinePresentation.repairStoredProgramDocument(in: &model)
        #expect(stale.slide(id: id)?.backgroundEnabled == false)
        let onAir = ProgramOutlinePresentation.currentShow(for: stale, document: model)
        #expect(onAir.slide(id: id)?.backgroundEnabled == true)
        let other = Show(id: UUID(), name: "Other", groups: [])
        #expect(ProgramOutlinePresentation.currentShow(for: other, document: model).id == other.id)
    }

    @Test
    func repairKeepsDesignedCameraRowBackground() {
        var (model, id) = designedCameraModel(slideBackground: true, boardBackground: true)
        ProgramOutlinePresentation.repairStoredProgramDocument(in: &model)
        let slide = model.programSlides.first { $0.id == id }!
        #expect(slide.backgroundEnabled)
        #expect(slide.audienceCanvas().contains { $0.name == "Background" })
    }

    @Test
    func repairRestoresBackgroundAnEarlierReopenFlipped() {
        var (model, id) = designedCameraModel(slideBackground: false, boardBackground: true)
        #expect(!model.programSlides[0].audienceCanvas().contains { $0.name == "Background" })
        let changed = ProgramOutlinePresentation.repairStoredProgramDocument(in: &model)
        #expect(changed)
        let slide = model.programSlides.first { $0.id == id }!
        #expect(slide.backgroundEnabled)
        #expect(slide.audienceCanvas().contains { $0.name == "Background" })
    }

    @Test
    func repairKeepsTransparentBoardTransparent() {
        var (model, id) = designedCameraModel(slideBackground: false, boardBackground: false)
        ProgramOutlinePresentation.repairStoredProgramDocument(in: &model)
        #expect(model.programSlides.first { $0.id == id }!.backgroundEnabled == false)
    }

    @Test
    func syncKeepsDesignedCameraRowBackground() {
        var (model, id) = designedCameraModel(slideBackground: true, boardBackground: true)
        ProgramOutlinePresentation.syncProgramSlide(at: 1, in: &model)
        #expect(model.programSlides.first { $0.id == id }!.backgroundEnabled)
    }
}

private func cameraRowTestSlide(id: UUID, title: String, itemNumber: String) -> Slide {
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
