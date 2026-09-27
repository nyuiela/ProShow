#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreMedia
import Foundation
import Testing
#if canImport(CoreVideo)
import CoreVideo
#endif

@Suite
struct SharedTexturePipelineTests {
    @Test @MainActor
    func publisher_reusesIOSurfaceWithoutNewGeneration() {
        SharedTexturePublisher.shared.resetForTests()
        #if canImport(CoreVideo)
        guard let buffer = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 64, height: 36) else {
            return
        }
        let stamp = CMTime(seconds: 1, preferredTimescale: 600)
        SharedTexturePublisher.shared.publish(pixelBuffer: buffer, itemTime: stamp)
        let first = SharedTexturePublisher.shared.currentGeneration
        SharedTexturePublisher.shared.publish(pixelBuffer: buffer, itemTime: stamp)
        #expect(SharedTexturePublisher.shared.currentGeneration == first)
        #expect(SharedTexturePublisher.shared.hasNewFrame(since: first) == false)
        #expect(SharedTexturePublisher.shared.currentPixelBuffer() != nil)
        #if canImport(IOSurface)
        #expect(SharedTexturePublisher.shared.currentIOSurface() != nil)
        #endif
        #endif
    }

    @Test
    func presentationDedupe_skipsUnchangedItemTime() {
        let first = CMTime(seconds: 1.0, preferredTimescale: 24_000)
        let same = CMTime(seconds: 1.0, preferredTimescale: 24_000)
        let next = CMTime(seconds: 1.0 + 1.0 / 24.0, preferredTimescale: 24_000)
        #expect(OffThreadVideoPublisher.shouldPublish(presentationItemTime: first, lastPresentedItemTime: .invalid))
        #expect(OffThreadVideoPublisher.shouldPublish(presentationItemTime: same, lastPresentedItemTime: first) == false)
        #expect(OffThreadVideoPublisher.shouldPublish(presentationItemTime: next, lastPresentedItemTime: first))
    }

    @Test
    func publisher_acceptsDisplayLinkQueuePublish() {
        SharedTexturePublisher.shared.resetForTests()
        #if canImport(CoreVideo)
        guard let buffer = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 64, height: 36) else {
            return
        }
        let time = CMTime(seconds: 2, preferredTimescale: 600)
        var generation: UInt64 = 0
        ProShowQueues.videoDisplayLinkQueue.sync {
            SharedTexturePublisher.shared.publishFromBackgroundQueue(pixelBuffer: buffer, itemTime: time)
            generation = SharedTexturePublisher.shared.currentGeneration
            SharedTexturePublisher.shared.publishFromBackgroundQueue(pixelBuffer: buffer, itemTime: time)
        }
        #expect(generation >= 1)
        #expect(SharedTexturePublisher.shared.currentGeneration == generation)
        #endif
    }

    @Test @MainActor
    func publisher_recycledPointerAdvancesWhenPresentationTimeChanges() {
        SharedTexturePublisher.shared.resetForTests()
        #if canImport(CoreVideo)
        guard let buffer = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 64, height: 36) else {
            return
        }
        SharedTexturePublisher.shared.publish(pixelBuffer: buffer, itemTime: CMTime(seconds: 0, preferredTimescale: 24_000))
        let first = SharedTexturePublisher.shared.currentGeneration
        SharedTexturePublisher.shared.publish(pixelBuffer: buffer, itemTime: CMTime(seconds: 1, preferredTimescale: 24_000))
        #expect(SharedTexturePublisher.shared.currentGeneration == first + 1)
        #endif
    }

    @Test @MainActor
    func publisher_advancesWhenRecycledSurfaceHasNewItemTime() {
        SharedTexturePublisher.shared.resetForTests()
        #if canImport(CoreVideo)
        guard let buffer = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 64, height: 36) else {
            return
        }
        SharedTexturePublisher.shared.publish(pixelBuffer: buffer, itemTime: CMTime(seconds: 1, preferredTimescale: 600))
        let first = SharedTexturePublisher.shared.currentGeneration
        SharedTexturePublisher.shared.publish(pixelBuffer: buffer, itemTime: CMTime(seconds: 1.04, preferredTimescale: 600))
        #expect(SharedTexturePublisher.shared.currentGeneration == first + 1)
        #endif
    }

    @Test @MainActor
    func compositor_publishesIngestedBufferToSharedTexture() {
        SharedTexturePublisher.shared.resetForTests()
        let compositor = CompositorEngine()
        #if canImport(CoreVideo)
        guard let buffer = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 48, height: 27) else {
            return
        }
        compositor.advanceFrame(playhead: 1.5, pixelBuffer: buffer)
        #expect(SharedTexturePublisher.shared.currentPixelBuffer() != nil)
        #expect(SharedTexturePublisher.shared.currentGeneration >= 1)
        #endif
        #expect(compositor.lastFrame != nil)
    }

    @Test @MainActor
    func playback_routesFrameConsumersThroughPublisher() {
        SharedTexturePublisher.shared.resetForTests()
        let engine = MediaPlaybackEngine()
        var hits = 0
        let id = ObjectIdentifier(engine)
        engine.addFrameConsumer(id) { hits += 1 }
        #if canImport(CoreVideo)
        if let buffer = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 32, height: 18) {
            SharedTexturePublisher.shared.publish(pixelBuffer: buffer)
            #expect(hits == 1)
            #expect(engine.publishedPixelBuffer() != nil)
        }
        #endif
        engine.removeFrameConsumer(id)
    }

    @Test @MainActor
    func editorPlate_followsKeyedBackgroundFill() {
        let controller = TestSupport.sampleController()
        let slide = controller.addSlide(named: "Keyed")
        controller.configureSlide(id: slide.id) {
            $0.backgroundEnabled = false
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
        #expect(document?.backgroundFill.isTransparent == true)
        #expect(controller.showsEditorProgramMediaPlate(for: document) == false)

        controller.editors.mutateSelectedDocument { $0.backgroundEnabled = true }
        #expect(controller.editors.selectedDocument?.backgroundFill.isTransparent == false)
        #expect(controller.showsEditorProgramMediaPlate(for: controller.editors.selectedDocument) == false)
    }

    @Test @MainActor
    func transportClock_playheadDoesNotNeedObservedFrame() {
        let controller = TestSupport.sampleController()
        controller.inspector.seekTransport(to: 7)
        #expect(abs(controller.transportClock.currentPlayheadSeconds() - controller.playback.playhead) < 0.01)
        let before = controller.programFrame
        controller.tickProgram()
        #expect(controller.programFrame == before + 1)
        #expect(abs(controller.playback.displayPlayhead - controller.playback.playhead) < 0.25)
    }
}
