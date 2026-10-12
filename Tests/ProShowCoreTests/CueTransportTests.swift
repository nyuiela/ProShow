#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct CueTransportTests {
    @Test @MainActor
    func makeCue_indexZero_matchesDisplayText() {
        let controller = TestSupport.sampleController()
        let slide = controller.show.allSlides[0]
        let cue = controller.makeCue(for: slide, index: 0)
        #expect(cue.slideIndex == 0)
        #expect(cue.layers.slideText?.first?.text == slide.displayText)
    }

    @Test @MainActor
    func blankSlide_hasEmptySlideText() {
        let blank = Slide(title: "Blank", isBlank: true)
        let cue = OutputCue.make(slide: blank, presentationId: UUID(), index: 3)
        #expect(cue.layers.slideText?.isEmpty == true)
    }

    @Test @MainActor
    func goLive_setsLiveIndexZero() {
        let controller = TestSupport.sampleController()
        controller.goLive(slideID: controller.show.allSlides[0].id)
        #expect(controller.liveIndex == 0)
        #expect(controller.compositor.stack.slideElements.isEmpty == false)
    }

    @Test @MainActor
    func advance_staysOnLast() {
        let controller = TestSupport.sampleController()
        let last = controller.show.allSlides.last!
        controller.goLive(slideID: last.id)
        controller.advance()
        #expect(controller.liveSlideID == last.id)
    }

    @Test @MainActor
    func previous_staysOnFirst() {
        let controller = TestSupport.sampleController()
        let first = controller.show.allSlides[0]
        controller.goLive(slideID: first.id)
        controller.goPrevious()
        #expect(controller.liveSlideID == first.id)
    }

    @Test @MainActor
    func disableSlide_isSkippedOnAdvance() {
        let controller = TestSupport.sampleController()
        let slides = controller.show.allSlides
        guard slides.count >= 3 else { return }
        controller.goLive(slideID: slides[0].id)
        controller.toggleSlideDisabled(id: slides[1].id)
        controller.advance()
        #expect(controller.liveSlideID == slides[2].id)
        #expect(controller.show.slide(id: slides[1].id)?.isDisabled == true)
    }

    @Test @MainActor
    func slideClipboard_cutCopyPasteAndStyle() {
        let controller = TestSupport.sampleController()
        let first = controller.show.allSlides[0]
        let before = controller.show.allSlides.count
        controller.copySlideTextStyle(id: first.id)
        controller.setSlideLabel("Chorus", id: first.id)
        controller.pasteSlideTextStyle(id: first.id)
        #expect(controller.canPasteSlideStyle)
        #expect(controller.show.slide(id: first.id)?.label == "Chorus")

        controller.copySlides([first.id])
        controller.pasteSlides(after: first.id)
        #expect(controller.show.allSlides.count == before + 1)

        let copied = controller.show.allSlides[1]
        controller.cutSlides([copied.id])
        #expect(controller.show.allSlides.count == before)
        #expect(controller.canPasteSlides)
    }

    @Test @MainActor
    func moveSlide_createsDestinationGroup() {
        let controller = TestSupport.sampleController()
        let slide = controller.show.allSlides[0]
        controller.moveSlide(slide.id, toGroupNamed: "Bridge")
        #expect(controller.show.groups.contains(where: { $0.name == "Bridge" && $0.slides.contains(where: { $0.id == slide.id }) }))
    }

    @Test @MainActor
    func mediaContext_duplicateRenameScaleAndCleanup() {
        let controller = TestSupport.sampleController()
        controller.openMediaPane(source: .playlists, collectionID: DeskSampleData.stellarPlaylistID)
        let original = controller.visibleMediaItems[0]
        let startCount = controller.visibleMediaItems.count
        controller.duplicateMedia(id: original.id)
        #expect(controller.visibleMediaItems.count == startCount + 1)
        controller.renameMedia(id: original.id, to: "Renamed Loop")
        #expect(controller.mediaItem(id: original.id)?.title == "Renamed Loop")
        controller.setMediaScaling("Fit", id: original.id)
        #expect(controller.mediaItem(id: original.id)?.scaling == "Fit")
        controller.cleanUpMedia(by: "Name")
        let titles = controller.visibleMediaItems.map(\.title)
        #expect(titles == titles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        controller.copyMedia([original.id])
        controller.pasteMedia()
        #expect(controller.visibleMediaItems.count == startCount + 2)
        controller.deleteMedia([original.id])
        #expect(controller.mediaItem(id: original.id) == nil)
    }

    @Test @MainActor
    func moveSlide_beforeTarget_reordersAcrossGroups() {
        let controller = TestSupport.sampleController()
        let slides = controller.show.allSlides
        guard slides.count >= 3 else { return }
        let moving = slides[2]
        let target = slides[0]
        controller.moveSlide(moving.id, before: target.id)
        #expect(controller.show.allSlides.first?.id == moving.id)
        #expect(controller.selectedSlideID == moving.id)
    }

    @Test @MainActor
    func applyWorkspaceDrop_slideMovesToEnd() {
        let controller = TestSupport.sampleController()
        let first = controller.show.allSlides[0]
        let payload = WorkspaceDragPayload.slide(id: first.id, title: first.title)
        #expect(controller.applyWorkspaceDrop(payload, before: nil))
        #expect(controller.show.allSlides.last?.id == first.id)
    }

    @Test @MainActor
    func applyWorkspaceDrop_mediaInsertsSlideAtTarget() {
        let controller = TestSupport.sampleController()
        controller.openMediaPane(source: .playlists, collectionID: DeskSampleData.stellarPlaylistID)
        guard let item = controller.visibleMediaItems.first else { return }
        let target = controller.show.allSlides[0]
        let before = controller.show.allSlides.count
        let payload = WorkspaceDragPayload.media(item)
        #expect(controller.applyWorkspaceDrop(payload, insertAfter: target.id))
        #expect(controller.show.allSlides.count == before + 1)
        #expect(controller.show.allSlides.first?.id == target.id)
        let inserted = controller.show.allSlides.dropFirst().first
        #expect(inserted?.title == item.title)
        #expect(inserted?.displayText.isEmpty == true)
        #expect(inserted?.previewSummary == item.kindLabel)
        #expect(inserted?.actions.contains(where: { $0.contains(item.title) }) == true)
        #expect(inserted?.mediaAction?.title == item.title)
        #expect(inserted?.isProgramMediaCue == true)
        #expect(SlideElement.from(slide: inserted!).isEmpty)
        #expect(inserted?.showsLinkedProgramMediaUnderCanvas == true)
    }

    @Test
    func linkedProgramMediaUnderCanvas_survivesCanvasText() {
        var slide = Slide(title: "Video + title")
        slide.backgroundEnabled = false
        slide.mediaAction = MediaAction(
            id: UUID(),
            title: "loop.mp4",
            tintHex: "#112233",
            duration: "1:00",
            isImage: false,
            filePath: "/tmp/loop.mp4"
        )
        #expect(slide.isProgramMediaCue)
        #expect(slide.showsLinkedProgramMediaUnderCanvas)
        slide.canvas.append(
            CanvasObject(
                name: "Title",
                kind: .text,
                bounds: CanvasBounds(x: 100, y: 100, width: 400, height: 80),
                text: "Hello"
            )
        )
        #expect(!slide.isProgramMediaCue)
        #expect(slide.showsLinkedProgramMediaUnderCanvas)
    }

    @Test @MainActor
    func applyWorkspaceDrop_placeholderInsertsLabeledSlide() {
        let controller = TestSupport.sampleController()
        let before = controller.show.allSlides.count
        let payload = WorkspaceDragPayload(kind: .placeholder, id: "A", name: "A", extra: "#D8F5D0")
        #expect(controller.applyWorkspaceDrop(payload, before: nil))
        #expect(controller.show.allSlides.count == before + 1)
        let inserted = controller.selectedSlideID.flatMap { controller.show.slide(id: $0) }
        #expect(inserted?.title == "Placeholder A")
        #expect(inserted?.label == "A")
    }

    @Test @MainActor
    func handleDeskDrop_mediaOnSlides_insertsSlide() {
        let controller = TestSupport.sampleController()
        controller.openMediaPane(source: .playlists, collectionID: DeskSampleData.stellarPlaylistID)
        guard let item = controller.visibleMediaItems.first else { return }
        let before = controller.show.allSlides.count
        #expect(controller.handleDeskDrop(payload: .media(item), files: [], role: .slides))
        #expect(controller.show.allSlides.count == before + 1)
        #expect(controller.selectedSlideID.flatMap { controller.show.slide(id: $0) }?.title == item.title)
        #expect(controller.draggingPayload == nil)
    }

    @Test @MainActor
    func handleDeskDrop_mediaOnEditor_assignsSource() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        let added = controller.editors.addObject(.image)
        controller.openMediaPane(source: .playlists, collectionID: DeskSampleData.stellarPlaylistID)
        guard let item = controller.visibleMediaItems.first else { return }
        #expect(controller.handleDeskDrop(payload: .media(item), files: [], role: .editor))
        let updated = controller.editors.selectedDocument?.objects.first(where: { $0.id == added.id })
        #expect(updated?.assignedSource?.name == item.title)
    }

    @Test @MainActor
    func handleDeskDrop_filesOnMediaBin_importOnly() throws {
        let controller = TestSupport.sampleController()
        let beforeSlides = controller.show.allSlides.count
        let beforeMedia = controller.importedMedia.count
        let url = try TestSupport.writePNGFixture(
            in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
        #expect(controller.handleDeskDrop(payload: nil, files: [url], role: .mediaBin))
        #expect(controller.show.allSlides.count == beforeSlides)
        #expect(controller.importedMedia.count == beforeMedia + 1)
    }

    @Test @MainActor
    func handleDeskDrop_ignore_isNoOp() {
        let controller = TestSupport.sampleController()
        let before = controller.show.allSlides.count
        #expect(controller.handleDeskDrop(
            payload: WorkspaceDragPayload(kind: .media, id: UUID().uuidString, name: "X"),
            files: [],
            role: .ignore
        ) == false)
        #expect(controller.show.allSlides.count == before)
    }

    @Test
    func workspaceDragPayload_roundTrip() {
        let payload = WorkspaceDragPayload(kind: .placeholder, id: "A", name: "A", extra: "#D8F5D0")
        let parsed = WorkspaceDragPayload.parse(payload.token)
        #expect(parsed?.kind == .placeholder)
        #expect(parsed?.name == "A")
        #expect(parsed?.extra == "#D8F5D0")
    }

    @Test
    func slide_decodesLegacyPayloadWithoutCueFields() throws {
        let id = UUID()
        let json = Data("""
        {"id":"\(id.uuidString)","title":"Hello","lines":["Hello"],"notes":"","isBlank":false,"alignment":"center","elements":[]}
        """.utf8)
        let slide = try JSONDecoder().decode(Slide.self, from: json)
        #expect(slide.isDisabled == false)
        #expect(slide.transition == "Cut")
        #expect(slide.label.isEmpty)
    }
}
