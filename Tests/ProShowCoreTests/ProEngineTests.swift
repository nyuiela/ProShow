#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
import Foundation
import Testing

@Suite
struct ProEngineTests {
    @Test
    func queues_useDedicatedLabelsAndQoS() {
        #expect(ProShowQueues.metalRenderQueue.label == "com.proshow.metal.render")
        #expect(ProShowQueues.videoDisplayLinkQueue.label == "com.proshow.video.displaylink")
        #expect(ProShowQueues.videoIngestQueue.label == "com.proshow.video.ingest")
        #expect(ProShowQueues.encoderQueue.label == "com.proshow.video.encoder")
        #expect(ProShowQueues.diskIOQueue.label == "com.proshow.disk.io")
        #expect(ProShowQueues.metalRenderQueue.qos == .userInteractive)
        #expect(ProShowQueues.videoDisplayLinkQueue.qos == .userInteractive)
        #expect(ProShowQueues.videoIngestQueue.qos == .userInitiated)
        #expect(ProShowQueues.encoderQueue.qos == .userInitiated)
        #expect(ProShowQueues.diskIOQueue.qos == .utility)
    }

    @Test
    func tripleBuffer_wrapsAfterThreeSlots() {
        let gate = TripleBufferManager.Gate()
        #expect(TripleBufferManager.maxBuffersInFlight == 3)
        #expect(gate.tryBeginFrame() == 1)
        #expect(gate.tryBeginFrame() == 2)
        #expect(gate.tryBeginFrame() == 0)
        #expect(gate.tryBeginFrame() == nil)
        gate.endFrame()
        #expect(gate.tryBeginFrame() == 1)
        gate.endFrame()
        gate.endFrame()
        gate.endFrame()
    }

    @Test
    func assetCache_evictsOnMemoryPressure() {
        let cache = AssetCacheManager(totalCostLimit: 1024, countLimit: 4)
        cache.setObject(NSString(string: "frame"), forKey: "slide-1", cost: 64)
        #expect((cache.object(forKey: "slide-1") as? NSString) == "frame")
        cache.handleMemoryPressure()
        #expect(cache.object(forKey: "slide-1") == nil)
        #expect(cache.storedCount == 0)
    }

    @Test
    func hardwareEncoder_requestsHardwareAcceleration() {
        let encoder = HardwareVideoEncoder()
        encoder.setupSession(width: 320, height: 180, fps: 30, bitrateKbps: 800)
        #expect(encoder.isPrepared)
        #expect(encoder.usesHardwareAcceleratedEncoder)
        #if canImport(CoreVideo)
        guard let pixel = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 320, height: 180) else {
            encoder.teardown()
            return
        }
        encoder.encode(pixelBuffer: pixel, presentationTime: 0)
        encoder.flushPendingEncodes()
        #expect(encoder.encodedFrameCount >= 1)
        #endif
        encoder.teardown()
        #expect(encoder.isPrepared == false)
    }

    @Test @MainActor
    func streamingStart_preparesHardwareEncoderAndEncodesLiveFrames() {
        let engine = StreamingEngine()
        let transport = MockStreamTransport()
        engine.transport = transport
        engine.config.useCloudRelay = true
        engine.config.destinationURL = "rtmps://relay.local/live/test"
        engine.config.width = 320
        engine.config.height = 180
        #expect(engine.start())
        #expect(engine.hardwareEncoder.isPrepared)
        #expect(engine.hardwareEncoder.usesHardwareAcceleratedEncoder)
        #expect(engine.hardwareEncoder.onEncoded != nil)
        #if canImport(CoreVideo)
        let before = transport.bytesWritten
        let pixel = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 320, height: 180)
        engine.encodeProgramFrame(pixelBuffer: pixel, now: Date())
        engine.hardwareEncoder.flushPendingEncodes()
        if pixel != nil {
            #expect(engine.hardwareEncoder.encodedFrameCount >= 1)
            #expect(transport.bytesWritten > before)
        }
        #endif
        engine.stop()
        #expect(engine.hardwareEncoder.isPrepared == false)
    }

    @Test @MainActor
    func compositor_ingestsPixelBufferThroughZeroCopyPath() {
        let compositor = CompositorEngine()
        let renderer = ProgramTextureRenderer()
        #if canImport(CoreVideo)
        let pixel = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 64, height: 36)
        compositor.advanceFrame(playhead: 0, renderer: renderer, pixelBuffer: pixel)
        if pixel != nil, ZeroCopyMetalPipeline().isReady {
            #expect(renderer.backend == "metal-zerocopy")
            #expect(renderer.textureAllocated)
        }
        #endif
        #expect(compositor.lastFrame != nil)
    }

    @Test @MainActor
    func ingestInject_exposesPixelBufferToProgramTick() {
        let controller = TestSupport.sampleController()
        #if canImport(CoreVideo)
        let pixel = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 64, height: 36)
        if let last = controller.videoInputs.lastFrame, let pixel {
            controller.videoInputs.ingest.inject(last, pixelBuffer: pixel)
            #expect(controller.videoInputs.lastPixelBuffer != nil)
            controller.tickProgram()
            if ZeroCopyMetalPipeline().isReady {
                #expect(controller.programRenderer.backend == "metal-zerocopy")
            }
        }
        #endif
    }
}
