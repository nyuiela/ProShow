#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreMedia
import Foundation
import Testing

@Suite
struct LiveEditorSyncTests {
    @Test @MainActor
    func testEditingLiveSlideDoesNotResetVideoPlayhead() {
        let controller = TestSupport.sampleController()
        let mediaID = UUID()
        let media = MediaAction(
            id: mediaID,
            title: "abstract_loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/abstract_loop.mp4"
        )
        let slide = controller.addSlide(named: "Live Lyric")
        controller.configureSlide(id: slide.id) {
            $0.mediaAction = media
            $0.backgroundEnabled = false
            $0.lines = ["Original lyric"]
        }

        controller.goLive(slideID: slide.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 18)
        let openedAt = controller.playback.playhead
        #expect(abs(openedAt - 18) < 0.05)

        controller.openInEditor(slideId: slide.id)
        #expect(controller.isSandboxEditingLive)
        #expect(!controller.isEditorAttachedToLive)
        #expect(controller.playback.playhead >= openedAt - 0.02)
        #expect(abs(controller.playback.playhead - openedAt) < 0.2)
        #expect(CMTimeGetSeconds(controller.transportClock.getCurrentTimecode(for: RenderLayer.media.rawValue)) >= 17)

        guard let textID = controller.editors.selectedDocument?.objects.first(where: \.isTextLike)?.id else {
            Issue.record("Expected a text object on the live slide")
            return
        }
        controller.editors.setInlineText("Updated lyric", id: textID)
        #expect(controller.playback.playhead >= openedAt - 0.02)
        #expect(abs(controller.playback.playhead - openedAt) < 0.2)
        #expect(controller.playback.sharesClock(with: media))
        #expect(controller.editorWorkspaceMedia(for: controller.editors.selectedDocument)?.id == mediaID)
        #expect(controller.editorUsesSharedProgramClock())
        #expect(controller.editorFollowsLiveBuilds)
        #expect(controller.editorAnimationMode() == .liveClock)
        #expect(controller.editorBuildClock().startedAt != nil)
        #expect(controller.editorBuildClock().startedAt == controller.liveBuildClock().startedAt)
    }

    @Test @MainActor
    func testSamePlaceholderOnAnotherSlideSharesProgramClock() {
        let controller = TestSupport.sampleController()
        let media = MediaAction(
            id: UUID(),
            title: "worship-loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/worship-loop.mp4",
            placeholderLetter: "A"
        )
        let live = controller.addSlide(named: "Live Loop")
        controller.configureSlide(id: live.id) {
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }
        let other = controller.addSlide(named: "Same Slot")
        controller.openInEditor(slideId: other.id)
        _ = controller.editors.addObject(.image)
        controller.assignSourceToSelectedEditorObjects(
            DiscoveredSourceItem(
                id: "placeholder-A",
                name: "A",
                category: .placeholders,
                groupName: "Placeholders",
                sourceType: .placeholderSlot,
                connectionString: "placeholder://A",
                tintHex: "#D8F5D0"
            )
        )

        controller.goLive(slideID: live.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 12)
        controller.refreshProgramClockBindings()
        controller.openInEditor(slideId: other.id)

        #expect(controller.playback.sharesClock(withPlaceholder: "A"))
        #expect(controller.editorUsesSharedProgramClock())
        #expect(abs(controller.playback.playhead - 12) < 0.2)
        if let object = controller.editors.selectedDocument?.objects.first(where: { $0.assignedPlaceholderLetter == "A" }) {
            #expect(controller.playback.sharesClock(with: object))
        } else {
            Issue.record("Expected a placeholder A object on the other slide")
        }
    }

    @Test @MainActor
    func testCanvasVideoBindsProgramClockWithoutRestart() {
        let controller = TestSupport.sampleController()
        let slide = controller.addSlide(named: "Inset Clip")
        var plate = CanvasObject(
            name: "Loop",
            kind: .image,
            bounds: CanvasBounds(x: 120, y: 80, width: 640, height: 360)
        )
        plate.fill.type = .image
        plate.fill.imageURI = "/tmp/worship-loop.mp4"
        controller.configureSlide(id: slide.id) {
            $0.canvas = [plate]
            $0.backgroundEnabled = false
        }

        let action = controller.resolvedAssociatedMedia(for: controller.show.slide(id: slide.id)!)
        #expect(action?.filePath == "/tmp/worship-loop.mp4")
        #expect(AssignedMediaSource.pathLooksLikeVideo(action?.filePath))

        controller.goLive(slideID: slide.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 9)
        let playhead = controller.playback.playhead
        controller.ensureProgramMediaClock()
        controller.setMode(.map)
        controller.tickProgram()
        controller.setMode(.edit)
        controller.tickProgram()
        #expect(controller.playback.sharesClock(withPath: "/tmp/worship-loop.mp4"))
        #expect(abs(controller.playback.playhead - playhead) < 0.25)
        #expect(controller.playback.loadGeneration == 1 || controller.playback.sharesClock(with: action))
    }

    @Test @MainActor
    func testOpaqueEditorCanvasHidesProgramMediaPlate() {
        let controller = TestSupport.sampleController()
        let slide = controller.addSlide(named: "Black Slide")
        controller.configureSlide(id: slide.id) {
            $0.backgroundEnabled = true
            $0.backgroundHex = "#000000"
            $0.mediaAction = MediaAction(
                id: UUID(),
                title: "loop.mp4",
                tintHex: "#112233",
                duration: "1:00.00",
                isImage: false,
                filePath: "/tmp/worship-loop.mp4"
            )
        }
        controller.goLive(slideID: slide.id)
        controller.openInEditor(slideId: slide.id)
        let document = controller.editors.selectedDocument
        #expect(document?.backgroundEnabled == true)
        #expect(controller.showsEditorProgramMediaPlate(for: document) == false)

        controller.editors.mutateSelectedDocument { $0.backgroundEnabled = false }
        #expect(controller.editors.selectedDocument?.backgroundFill.isTransparent == true)
        #expect(controller.showsEditorProgramMediaPlate(for: controller.editors.selectedDocument) == false)
    }

    @Test @MainActor
    func testSandboxEditsDoNotReachLiveUntilApply() {
        let controller = TestSupport.sampleController()
        let mediaID = UUID()
        let media = MediaAction(
            id: mediaID,
            title: "abstract_loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/abstract_loop.mp4"
        )
        let slide = controller.addSlide(named: "Live Patch")
        controller.configureSlide(id: slide.id) {
            $0.mediaAction = media
            $0.backgroundEnabled = false
            $0.lines = ["Before patch"]
        }

        controller.goLive(slideID: slide.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 14)
        controller.openInEditor(slideId: slide.id)

        let mediaRevision = controller.compositor.mediaRevision
        let loadGeneration = controller.playback.loadGeneration
        let playhead = controller.playback.playhead
        let slideRevision = controller.compositor.slideRevision

        guard let textID = controller.editors.selectedDocument?.objects.first(where: \.isTextLike)?.id else {
            Issue.record("Expected a text object on the live slide")
            return
        }
        controller.editors.setInlineText("Patched live", id: textID)
        #expect(controller.hasSandboxChanges)
        #expect(controller.compositor.slideRevision == slideRevision)
        #expect(!(controller.compositor.stack.slideCanvas ?? []).contains { $0.text.contains("Patched live") })
        #expect(controller.compositor.mediaRevision == mediaRevision)
        #expect(controller.playback.loadGeneration == loadGeneration)
        #expect(abs(controller.playback.playhead - playhead) < 0.2)

        controller.applySandboxChanges()
        let liveCanvas = (controller.compositor.stack.slideCanvas ?? []).contains { $0.text.contains("Patched live") }
        let liveText = controller.compositor.stack.slideElements.contains { $0.text.contains("Patched live") }
        #expect(liveText || liveCanvas)
        #expect(controller.compositor.slideRevision > slideRevision)
        #expect(controller.compositor.mediaRevision == mediaRevision)
        #expect(controller.playback.loadGeneration == loadGeneration)
        #expect(controller.compositor.stack.media?.id == mediaID)
        #expect(!controller.hasSandboxChanges)
    }

    @Test @MainActor
    func testLiveEditorUsesAudienceBuildClockNotRestPose() {
        let controller = TestSupport.sampleController()
        let slide = controller.addSlide(named: "Animated Live")
        controller.configureSlide(id: slide.id) {
            $0.lines = ["Fade in"]
        }
        controller.openInEditor(slideId: slide.id)
        #expect(controller.editorAnimationMode() == .editorDesign)
        #expect(controller.editorFollowsLiveBuilds == false)

        controller.goLive(slideID: slide.id)
        controller.openInEditor(slideId: slide.id)
        #expect(controller.isEditingLiveSlide)
        #expect(controller.editorFollowsLiveBuilds)
        #expect(controller.editorAnimationMode() == .liveClock)
        let editorClock = controller.editorBuildClock()
        let audienceClock = controller.liveBuildClock()
        #expect(editorClock.startedAt == audienceClock.startedAt)
        #expect(editorClock.clickTimes == audienceClock.clickTimes)
        #expect(
            BuildAnimationEngine.shouldTickLive(
                mode: controller.editorAnimationMode(),
                clock: editorClock,
                objectID: UUID()
            )
        )
    }

    @Test @MainActor
    func testBinSelectOtherMediaDoesNotStealLiveLinkedClock() {
        let controller = TestSupport.sampleController()
        let linked = MediaAction(
            id: UUID(),
            title: "worship-loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/worship-loop.mp4"
        )
        let slide = controller.addSlide(named: "Linked Loop")
        controller.configureSlide(id: slide.id) {
            $0.mediaAction = linked
            $0.backgroundEnabled = false
        }
        controller.goLive(slideID: slide.id)
        controller.openInEditor(slideId: slide.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 8)
        let playhead = controller.playback.playhead
        let generation = controller.playback.loadGeneration
        let programID = controller.compositor.stack.media?.id

        let other = MediaBinItem(
            title: "b-roll.mp4",
            kind: .video(duration: "0:12.00"),
            tintHex: "#334455",
            source: .playlists,
            filePath: "b-roll.mp4"
        )
        controller.importedMedia.append(other)
        controller.selectMediaInPane(other)

        #expect(controller.selectedMediaItemID == other.id)
        #expect(controller.playback.sharesClock(with: linked))
        #expect(controller.playback.loadGeneration == generation)
        #expect(abs(controller.playback.playhead - playhead) < 0.25)
        #expect(controller.compositor.stack.media?.id == programID)
        #expect(controller.showsEditorProgramMediaPlate(for: controller.editors.selectedDocument) == false)
        #expect(controller.editorWorkspaceMedia(for: controller.editors.selectedDocument)?.filePath == linked.filePath)

        controller.selectMediaInPane(other, takeProgram: true)
        #expect(controller.compositor.stack.media?.filePath == "b-roll.mp4")
        #expect(controller.playback.loadGeneration > generation)
    }
}
