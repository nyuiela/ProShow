#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct LayerContinuityTests {
    @Test
    func evaluator_rulesPreserveReplaceAndClear() {
        let loop = MediaAction(id: UUID(), title: "abstract_loop.mp4", tintHex: "#112233", duration: "1:00.00", isImage: false, filePath: "/tmp/abstract_loop.mp4")
        var same = loop
        same.id = UUID()
        let nature = MediaAction(id: UUID(), title: "nature_loop.mp4", tintHex: "#112233", duration: "1:00.00", isImage: false, filePath: "/tmp/nature_loop.mp4")
        var reset = loop
        reset.forceReset = true

        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: same) == .preserve)
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: nil) == .preserve)
        let page = MediaAction(id: RundownPageMedia.id, title: "https://example.com", tintHex: "#000000", isImage: true)
        #expect(MediaActionEvaluator.evaluate(current: page, incoming: nil) == .clear)
        #expect(MediaActionEvaluator.evaluate(current: nil, incoming: nil) == .clear)
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: nature) == .replace(nature))
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: .clearLayerCue()) == .clear)
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: reset) == .replace(reset))
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: nature, layerLocked: true) == .preserve)
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: .clearLayerCue(), layerLocked: true) == .preserve)
    }

    @Test @MainActor
    func testSlideAdvancePreservesPlayingMediaPlayhead() {
        let controller = TestSupport.sampleController()
        let mediaID = UUID()
        let media = MediaAction(
            id: mediaID,
            title: "abstract_loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false
        )
        let first = controller.addSlide(named: "Verse 1")
        let second = controller.addSlide(named: "Verse 2")
        controller.configureSlide(id: first.id) {
            $0.lines = ["Amazing grace"]
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: second.id) {
            $0.lines = ["How sweet the sound"]
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        #expect(controller.liveStack.isMediaActive(mediaID: mediaID))
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 20)
        #expect(abs(controller.playback.playhead - 20) < 0.05)
        #expect(controller.playback.isBound(to: media))

        controller.goLive(slideID: second.id)
        #expect(abs(controller.playback.playhead - 20) < 0.05)
        #expect(controller.playback.isBound(to: media))
        #expect(controller.compositor.stack.media?.id == mediaID)
        #expect(controller.liveStack.isSlideActive(slideID: second.id))
        #expect(controller.liveStack.isMediaActive(mediaID: mediaID))
        #expect(!controller.liveStack.isSlideActive(slideID: first.id))

        controller.tickProgram()
        #expect(abs(controller.playback.playhead - 20) < 0.2)
        #expect(controller.playback.isBound(to: media))
    }

    @Test @MainActor
    func slideWithoutMedia_preservesBackgroundVideoPlayhead() {
        let controller = TestSupport.sampleController()
        let media = MediaAction(
            id: UUID(),
            title: "abstract_loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/abstract_loop.mp4"
        )
        let first = controller.addSlide(named: "Verse 1")
        let second = controller.addSlide(named: "Verse 2")
        controller.configureSlide(id: first.id) {
            $0.lines = ["Amazing grace"]
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: second.id) {
            $0.lines = ["How sweet the sound"]
            $0.mediaAction = nil
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 18)
        #expect(controller.playback.hasProgramClock)
        controller.goLive(slideID: second.id)

        #expect(controller.compositor.stack.media?.filePath == "/tmp/abstract_loop.mp4")
        #expect(!controller.compositor.stack.isCleared(.media))
        #expect(controller.compositor.stack.slideBackgroundEnabled == false)
        #expect(controller.compositor.stack.slideElements.contains(where: { $0.text.contains("How sweet") }))
        #expect(controller.playback.hasProgramClock)
        #expect(abs(controller.playback.playhead - 18) < 0.05)
        #expect(controller.liveStack.isMediaActive(mediaID: media.id) || controller.compositor.stack.media?.id == media.id)
        #expect(controller.liveStack.isSlideActive(slideID: second.id))
    }

    @Test @MainActor
    func sameFileOnNextSlide_keepsPlayheadEvenWhenIDsDiffer() {
        let controller = TestSupport.sampleController()
        let firstMedia = MediaAction(
            id: UUID(),
            title: "abstract_loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/abstract_loop.mp4"
        )
        var secondMedia = firstMedia
        secondMedia.id = UUID()
        let first = controller.addSlide(named: "Look A")
        let second = controller.addSlide(named: "Look B")
        controller.configureSlide(id: first.id) {
            $0.mediaAction = firstMedia
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: second.id) {
            $0.mediaAction = secondMedia
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 16)
        controller.goLive(slideID: second.id)

        #expect(abs(controller.playback.playhead - 16) < 0.05)
        #expect(controller.playback.hasProgramClock)
        #expect(controller.playback.isBound(to: secondMedia))
        #expect(controller.liveStack.isSlideActive(slideID: second.id))
    }

    @Test @MainActor
    func newBackground_restartsPlayhead() {
        let controller = TestSupport.sampleController()
        let firstMedia = MediaAction(id: UUID(), title: "abstract_loop.mp4", tintHex: "#112233", duration: "1:00.00", isImage: false)
        let nextMedia = MediaAction(id: UUID(), title: "nature_loop.mp4", tintHex: "#334455", duration: "1:00.00", isImage: false)
        let first = controller.addSlide(named: "Loop A")
        let second = controller.addSlide(named: "Loop B")
        controller.configureSlide(id: first.id) {
            $0.mediaAction = firstMedia
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: second.id) {
            $0.mediaAction = nextMedia
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 22)
        controller.goLive(slideID: second.id)

        #expect(controller.compositor.stack.media?.title == "nature_loop.mp4")
        #expect(controller.playback.playhead < 0.05)
        #expect(controller.liveStack.isMediaActive(mediaID: nextMedia.id))
    }

    @Test @MainActor
    func clearMediaCue_unloadsLayer3() {
        let controller = TestSupport.sampleController()
        let media = MediaAction(id: UUID(), title: "abstract_loop.mp4", tintHex: "#112233", duration: "1:00.00", isImage: false)
        let first = controller.addSlide(named: "With Media")
        let clear = controller.addSlide(named: "Clear")
        controller.configureSlide(id: first.id) {
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: clear.id) {
            $0.actions = ["Clear Media"]
            $0.lines = ["Announcement"]
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        controller.goLive(slideID: clear.id)

        #expect(controller.compositor.stack.media == nil)
        #expect(controller.compositor.stack.isCleared(.media))
        #expect(controller.liveStack.activeMedia == nil)
        #expect(controller.liveStack.isSlideActive(slideID: clear.id))
        #expect(controller.compositor.stack.slideBackgroundEnabled == false)
    }

    @Test @MainActor
    func forceReset_restartsSameAsset() {
        let controller = TestSupport.sampleController()
        let mediaID = UUID()
        let media = MediaAction(id: mediaID, title: "abstract_loop.mp4", tintHex: "#112233", duration: "1:00.00", isImage: false)
        let first = controller.addSlide(named: "Start")
        let reset = controller.addSlide(named: "Reset")
        controller.configureSlide(id: first.id) {
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: reset.id) {
            $0.mediaAction = media
            $0.forceResetMedia = true
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 25)
        controller.goLive(slideID: reset.id)

        #expect(controller.playback.playhead < 0.05)
        #expect(controller.compositor.stack.media?.id == mediaID)
        #expect(controller.liveStack.isMediaActive(mediaID: mediaID))
    }

    @Test @MainActor
    func switchingWorkspace_keepsProgramClock() {
        let controller = TestSupport.sampleController()
        let mediaID = UUID()
        let media = MediaAction(
            id: mediaID,
            title: "abstract_loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/abstract_loop.mp4",
            placeholderLetter: "A"
        )
        let slide = controller.addSlide(named: "Live Verse")
        controller.configureSlide(id: slide.id) {
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }
        controller.goLive(slideID: slide.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 21)
        #expect(abs(controller.playback.playhead - 21) < 0.05)

        controller.setMode(.edit)
        #expect(abs(controller.playback.playhead - 21) < 0.05)
        #expect(controller.playback.sharesClock(with: media))
        #expect(controller.playback.sharesClock(withPath: "/tmp/abstract_loop.mp4"))
        #expect(controller.playback.sharesClock(withPlaceholder: "A"))

        controller.setMode(.map)
        #expect(abs(controller.playback.playhead - 21) < 0.05)
        #expect(controller.playback.isBound(to: media))

        controller.setMode(.show)
        controller.tickProgram()
        #expect(abs(controller.playback.playhead - 21) < 0.2)
        #expect(controller.playback.sharesClock(with: media))
    }
}
