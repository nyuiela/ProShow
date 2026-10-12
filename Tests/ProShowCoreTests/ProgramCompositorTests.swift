#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing
#if canImport(CoreVideo)
import CoreVideo
#endif

@Suite
struct ProgramCompositorTests {
    @Test @MainActor
    func sharedPlayback_seekAndDockUseTheSameClock() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        #expect(controller.playback.duration == 300)
        #expect(controller.inspector.transport.duration == 300)
        #expect(controller.playback.isPlaying)
        controller.inspector.seekTransport(to: 20)
        #expect(abs(controller.playback.playhead - 20) < 0.01)
        #expect(abs(controller.inspector.transport.playhead - 20) < 0.01)
        controller.inspector.skipTransport(seconds: -15)
        #expect(abs(controller.playback.playhead - 5) < 0.01)
        controller.inspector.jumpToNextMarker()
        #expect(controller.playback.playhead == 150)
        #expect(controller.inspector.transport.playhead == 150)
    }

    @Test @MainActor
    func tickProgram_advancesFrameWithPlayheadAndMeters() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        controller.inspector.pauseTransport()
        controller.inspector.seekTransport(to: 12)
        controller.tickProgram(now: Date())
        let frame = controller.compositor.lastFrame
        #expect(frame != nil)
        #expect(abs((frame?.playhead ?? -1) - 12) < 0.01)
        #expect(frame?.mediaTitle == "Starting Soon")
        #expect(frame?.visibleLayers.contains(RenderLayer.media.rawValue) == true)
        #expect(frame?.outputWidth == controller.compositor.outputWidth)
        #expect((frame?.leftMeter ?? 0) >= 0)
        #expect(controller.programRenderer.matches(controller.compositor.metalTextureDescriptor))
        ProShowQueues.programClockQueue.sync {}
        #if canImport(CoreVideo)
        #expect(controller.compositor.masterProgramOutputBuffer != nil)
        #endif
    }

    @Test @MainActor
    func logicalClock_pausesAtEndWhenLoopOff() {
        let engine = MediaPlaybackEngine()
        engine.load(TestSupport.mediaAction(title: "Clip"))
        #expect(engine.duration == 60)
        engine.toggleLoop()
        #expect(engine.isLooping == false)
        engine.seek(to: 60)
        #expect(engine.isPlaying == false)
        #expect(engine.playhead == 60)
    }

    @Test @MainActor
    func rasterizer_compositesVisibleLayers() {
        let compositor = CompositorEngine()
        compositor.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 0,
                layers: CueLayers(
                    slideText: [SlideElement(text: "Grace")],
                    mediaAction: TestSupport.mediaAction()
                )
            )
        )
        compositor.setMessage("Alert")
        compositor.toggleProp("Logo Bug")
        let raster = ProgramRasterizer.composite(
            stack: compositor.stack,
            width: 32,
            height: 18,
            playhead: 4,
            filters: VideoFilterEngine()
        )
        #expect(raster.coveredLayers.contains(RenderLayer.media.rawValue))
        #expect(raster.coveredLayers.contains(RenderLayer.slide.rawValue))
        #expect(raster.coveredLayers.contains(RenderLayer.messages.rawValue))
        #expect(raster.coveredLayers.contains(RenderLayer.props.rawValue))
        let center = raster.pixel(x: 16, y: 9)
        #expect(center.r > 0.5)
    }

    @Test @MainActor
    func chromaFallback_clearsGreenKeyInRaster() {
        let compositor = CompositorEngine()
        compositor.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 0,
                layers: CueLayers(videoInputAction: VideoInputSource(id: UUID(), label: "Cam"))
            )
        )
        let filters = VideoFilterEngine()
        let raster = ProgramRasterizer.composite(
            stack: compositor.stack,
            width: 16,
            height: 16,
            playhead: 0,
            filters: filters
        )
        #expect(raster.coveredLayers.contains(RenderLayer.videoInput.rawValue))
        let keyed = raster.pixel(x: 8, y: 2)
        #expect(keyed.g < 0.1)
        #expect(keyed.r < 0.1)
    }

    @Test @MainActor
    func previewFeedSwitch_doesNotReloadProgramMedia() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        controller.inspector.seekTransport(to: 24)
        let playhead = controller.playback.playhead
        let mediaID = controller.playback.mediaID
        controller.selectPreviewFeed(.stage)
        controller.tickProgram()
        controller.selectPreviewFeed(.stream)
        controller.tickProgram()
        controller.selectPreviewFeed(.audience)
        controller.tickProgram()
        #expect(controller.playback.mediaID == mediaID)
        #expect(controller.playback.isPlaying)
        #expect(abs(controller.playback.playhead - playhead) < 1.5)
        #expect(controller.compositor.stack.look.name == AudienceLookConfig.fullStack.name)
    }

    @Test @MainActor
    func transportDock_seeksAndPausesSharedPlayback() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        controller.inspector.seekTransport(to: 40)
        controller.tickProgram()
        #expect(abs(controller.playback.playhead - 40) < 0.05)
        #expect(abs(controller.inspector.transport.playhead - 40) < 0.05)
        controller.inspector.skipTransport(seconds: 15)
        controller.tickProgram()
        #expect(abs(controller.playback.playhead - 55) < 0.05)
        controller.transportPlayPause()
        #expect(controller.playback.isPlaying == false)
        #expect(abs(controller.playback.playhead - 55) < 0.05)
        controller.transportPlayPause()
        #expect(controller.playback.isPlaying)
        #expect(abs(controller.playback.playhead - 55) < 0.05)
    }

    @Test @MainActor
    func pausePlay_keepsSinglePlayerIdentity() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        let first = ObjectIdentifier(controller.playback)
        controller.transportPlayPause()
        #expect(controller.playback.isPlaying == false)
        controller.transportPlayPause()
        #expect(controller.playback.isPlaying)
        #expect(ObjectIdentifier(controller.playback) == first)
        #expect(controller.isMediaPlaying == controller.playback.isPlaying)
    }

    @Test
    func previewFeedTitles_keepPreviewDistinctFromLive() {
        #expect(PreviewFeed.audience.title == "Preview")
        #expect(PreviewFeed.stream.title == "Live")
        #expect(PreviewFeed.operatorFeeds == [.audience, .stream])
    }

    @Test
    func programComposite_drawsScreenShareAtSlideEnter() throws {
        #if canImport(CoreVideo)
        var object = CanvasObject(
            name: "MacBook",
            kind: .videoInput,
            bounds: .canvas
        )
        object.visibleOnAudience = true
        object.assignedSource = AssignedMediaSource(
            sourceID: "display",
            name: "MacBook",
            sourceType: .systemDisplay,
            category: .screenCapture,
            connectionString: "sck://display/1"
        )
        object.buildSteps = [
            ElementBuildStep(
                elementId: object.id,
                phase: .buildIn,
                effect: .dissolve,
                trigger: .onSlideEnter,
                sequenceOrder: 1,
                durationSeconds: 0.5
            ),
        ]
        var stack = RenderStack.idle
        stack.slideCanvas = [object]
        stack.slideCanvasWidth = CanvasConfig.width
        stack.slideCanvasHeight = CanvasConfig.height
        stack.slideBackgroundEnabled = true
        stack.slideBackgroundHex = "#000000"

        let onAir = ProgramOutputComposer.shared.render(
            stack: stack,
            width: 320,
            height: 180,
            video: nil,
            pip: nil,
            media: nil,
            videoFrame: nil,
            objectLivePixels: [object.id: Self.solidBGRA(width: 32, height: 32, b: 0, g: 0, r: 255, a: 255)],
            buildPlayback: BuildPlayback.live(elapsed: 0, unlockedClickOrder: 0, clickTimes: [:]),
            matchOnAirVisibility: true
        )
        let buffer = try #require(onAir?.buffer)
        #expect(Self.peakChannel(in: buffer, channel: 2, x0: 40, y0: 20, x1: 280, y1: 160) > 200)
        #expect(Self.peakChannel(in: buffer, channel: 0, x0: 40, y0: 20, x1: 280, y1: 160) < 40)
        #endif
    }

    @Test
    func programComposite_drawsBrowserPageOnMediaBackdrop() throws {
        #if canImport(CoreVideo)
        var browser = CanvasObject(
            name: "Browser",
            kind: .browser,
            bounds: .canvas
        )
        browser.visibleOnAudience = true
        browser.assignedSource = AssignedMediaSource(
            sourceID: "https://example.com",
            name: "example.com",
            sourceType: .webPage,
            category: .network,
            connectionString: "https://example.com",
            tintHex: "#000000"
        )
        browser.fill.type = .image
        browser.fill.imageURI = "https://example.com"
        var stack = RenderStack.idle
        stack.slideCanvas = [browser]
        stack.slideCanvasWidth = CanvasConfig.width
        stack.slideCanvasHeight = CanvasConfig.height
        stack.slideBackgroundEnabled = false
        stack.media = MediaAction(
            id: RundownPageMedia.id,
            title: "https://example.com",
            tintHex: "#000000",
            isImage: true
        )

        let pagePlate = try #require(
            ProgramPageViewport.loadingPlatePixelBuffer(label: "example.com")
        )
        let onAir = ProgramOutputComposer.shared.render(
            stack: stack,
            width: 320,
            height: 180,
            video: nil,
            pip: nil,
            media: pagePlate,
            videoFrame: nil,
            objectLivePixels: [browser.id: Self.solidBGRA(width: 64, height: 64, b: 40, g: 40, r: 40, a: 255)],
            buildPlayback: BuildPlayback.preview(elapsed: 120),
            matchOnAirVisibility: true
        )
        let buffer = try #require(onAir?.buffer)
        #expect(Self.peakChannel(in: buffer, channel: 0, x0: 20, y0: 20, x1: 300, y1: 160) > 30)
        #endif
    }

    #if canImport(CoreVideo)
    private static func peakChannel(in buffer: CVPixelBuffer, channel: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let xMin = max(0, min(x0, x1))
        let xMax = min(width - 1, max(x0, x1))
        let yMin = max(0, min(y0, y1))
        let yMax = min(height - 1, max(y0, y1))
        var peak = 0
        for y in yMin...yMax {
            let row = pixels.advanced(by: y * stride)
            for x in xMin...xMax {
                peak = max(peak, Int(row[x * 4 + channel]))
            }
        }
        return peak
    }

    private static func solidBGRA(width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8, a: UInt8) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixel = buffer!
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let line = base.advanced(by: row * stride)
            for col in 0..<width {
                let offset = col * 4
                line[offset] = b
                line[offset + 1] = g
                line[offset + 2] = r
                line[offset + 3] = a
            }
        }
        return pixel
    }
    #endif
}
