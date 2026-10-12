#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct ActionStackTests {
    @Test @MainActor
    func testSlideSwitchPreservesBackgroundVideoPlayhead() {
        let controller = TestSupport.sampleController()
        let media = MediaAction(
            id: UUID(),
            title: "Abstract_Blue_Loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/abstract_blue_loop.mp4"
        )
        let first = controller.addSlide(named: "Video + Text")
        let second = controller.addSlide(named: "Text Only")
        controller.configureSlide(id: first.id) {
            $0.lines = ["Verse one"]
            $0.mediaAction = media
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: second.id) {
            $0.lines = ["Quote card"]
            $0.mediaAction = nil
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 14.2)
        #expect(abs(controller.playback.playhead - 14.2) < 0.05)

        controller.goLive(slideID: second.id)
        #expect(abs(controller.playback.playhead - 14.2) < 0.05)
        #expect(controller.playback.hasProgramClock)
        #expect(controller.compositor.stack.media?.filePath == media.filePath)
        #expect(controller.compositor.stack.slideElements.contains(where: { $0.text.contains("Quote") }))

        controller.goLive(slideID: first.id)
        #expect(abs(controller.playback.playhead - 14.2) < 0.05)
        #expect(controller.playback.hasProgramClock)
        #expect(controller.liveStack.isSlideActive(slideID: first.id))
    }

    @Test @MainActor
    func testLayerLockingPreventsMediaOverride() {
        let controller = TestSupport.sampleController()
        let videoA = MediaAction(
            id: UUID(),
            title: "VideoA.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/video-a.mp4"
        )
        let videoB = MediaAction(
            id: UUID(),
            title: "VideoB.mp4",
            tintHex: "#334455",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/video-b.mp4"
        )
        let first = controller.addSlide(named: "A")
        let second = controller.addSlide(named: "B")
        controller.configureSlide(id: first.id) {
            $0.mediaAction = videoA
            $0.backgroundEnabled = false
        }
        controller.configureSlide(id: second.id) {
            $0.mediaAction = videoB
            $0.backgroundEnabled = false
        }

        controller.goLive(slideID: first.id)
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 11)
        controller.setActionLayerLocked(.media, locked: true)

        controller.goLive(slideID: second.id)
        #expect(controller.compositor.stack.media?.filePath == videoA.filePath)
        #expect(abs(controller.playback.playhead - 11) < 0.05)
        #expect(controller.isActionLayerLocked(.media))

        controller.setActionLayerLocked(.media, locked: false)
        controller.goLive(slideID: second.id)
        #expect(controller.compositor.stack.media?.filePath == videoB.filePath)
        #expect(controller.playback.playhead < 0.05)
    }

    @Test
    func evaluator_preservesWhenSlideHasNoMediaAction() {
        let loop = MediaAction(id: UUID(), title: "loop.mp4", tintHex: "#000000", duration: "1:00.00", isImage: false, filePath: "/tmp/loop.mp4")
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: nil) == .preserve)
        #expect(MediaActionEvaluator.evaluate(current: loop, incoming: .clearLayerCue()) == .clear)
    }
}
