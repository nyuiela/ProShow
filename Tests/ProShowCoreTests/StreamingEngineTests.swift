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
struct StreamingEngineTests {
    @Test @MainActor
    func emptyDirectURL_fails() {
        let engine = StreamingEngine()
        engine.config.useCloudRelay = false
        engine.config.destinationURL = ""
        #expect(engine.start() == false)
        #expect(engine.state == .failed)
    }

    @Test @MainActor
    func startStop_withMockTransport() {
        let engine = StreamingEngine()
        let transport = MockStreamTransport()
        engine.transport = transport
        engine.config.useCloudRelay = true
        engine.config.destinationURL = "rtmps://relay.local/live/test"
        #expect(engine.start())
        #expect(engine.state == .live)
        #expect(transport.connectCount == 1)
        #expect(engine.encoderSettings?.width == 1280)
        #expect(engine.encoderSettings?.height == 720)
        #expect(engine.encoderSettings?.framerate == 30)
        #expect(engine.encoderSettings?.bitrateKbps == 2_500)
        #expect(engine.encoderSettings?.keyframeIntervalSec == 2)
        engine.stop()
        #expect(engine.state == .idle)
        #expect(transport.disconnectCount == 1)
    }

    @Test
    func encoderSettings_matchContract() {
        let settings = ProgramEncoderSettings.from(RtmpStreamConfig.default)
        #expect(settings.codec == "H264")
        #expect(settings.width == 1920)
        #expect(settings.height == 1080)
        #expect(settings.bitrateKbps == 5500)
        #expect(settings.audioCodec == "AAC")
    }

    @Test
    func rtmpClient_parsesURLAndBuildsHandshake() {
        let dest = RTMPClient.parseURL("rtmps://relay.local/live/church")
        #expect(dest?.host == "relay.local")
        #expect(dest?.secure == true)
        #expect(dest?.port == 443)
        #expect(dest?.app == "live")
        #expect(dest?.stream == "church")
        let handshake = RTMPClient.handshakeC0C1()
        #expect(handshake.count == 1537)
        #expect(handshake.first == 0x03)
        #expect(RTMPClient.flvHeader().starts(with: [0x46, 0x4C, 0x56]))
    }

    @Test
    func rtmpClient_answersPingWithSameTimestamp() {
        let request = RTMPClient.pingRequest(timestamp: 0x11223344)
        var state = RTMPChunkReader.State()
        #expect(RTMPChunkReader.consume(request, state: &state) == [.ping(0x11223344)])
        let response = RTMPClient.pingResponse(timestamp: 0x11223344)
        #expect(response.contains(0x07))
        #expect(response.contains(0x11))
        #expect(!RTMPChunkReader.consume(response, state: &state).contains(.ping(0x11223344)))
    }

    @Test @MainActor
    func streamHealth_failsWhenTransportDrops() {
        let engine = StreamingEngine()
        let transport = MockStreamTransport()
        engine.transport = transport
        engine.config.useCloudRelay = true
        engine.config.destinationURL = "rtmps://relay.local/live/test"
        #expect(engine.start())
        #expect(engine.state == .live)
        transport.forceDrop()
        engine.noteTransportHealth()
        #expect(engine.state == .failed)
        #expect(engine.lastError?.localizedCaseInsensitiveContains("dropped") == true)
    }

    @Test
    func rtmpClient_appendsStreamKeyWhenPathHasNone() {
        var config = RtmpStreamConfig.default
        config.useCloudRelay = false
        config.destinationURL = "rtmp://a.rtmp.youtube.com/live2"
        config.streamKey = "xxxx-yyyy-zzzz"
        let dest = RTMPClient.resolve(config)
        #expect(dest?.app == "live2")
        #expect(dest?.stream == "xxxx-yyyy-zzzz")
        let packet = RTMPClient.videoMessage(.sequenceHeader(Data([1, 2, 3, 4])))
        #expect(packet.contains(0x17))
        let configs = RTMPClient.fanoutConfigs(from: RtmpStreamConfig(
            sourceDisplayId: "Audience_Screen_1",
            destinationURL: "rtmp://a.rtmp.youtube.com/live2",
            streamKey: "one",
            codec: "H264",
            width: 1920,
            height: 1080,
            framerate: 30,
            bitrateKbps: 5500,
            keyframeIntervalSec: 2,
            audioCodec: "AAC",
            audioBitrateKbps: 128,
            sampleRateHz: 48000,
            channels: 2,
            useCloudRelay: true,
            relayDestinations: [
                RelayDestination(name: "YouTube", url: "rtmp://a.rtmp.youtube.com/live2", streamKey: "one"),
                RelayDestination(name: "X", url: "rtmp://va.pscp.tv/x", streamKey: "two"),
            ]
        ))
        #expect(configs.count == 2)
        #expect(configs.map(\.streamKey).sorted() == ["one", "two"])
        let meta = RTMPClient.metadataMessage(width: 1920, height: 1080, framerate: 30, videoBitrateKbps: 5500)
        let metaText = String(decoding: meta, as: UTF8.self)
        #expect(metaText.contains("onMetaData"))
        #expect(metaText.contains("@setDataFrame"))
        let header = RTMPClient.audioMessage(.sequenceHeader)
        #expect(header.contains(0xAF))
        #expect(header.contains(0x11))
        let silence = RTMPClient.audioMessage(.accessUnit(timestampMs: 21))
        #expect(silence.contains(0xAF))
        #expect(silence.contains(0x01))
        #expect(String(decoding: RTMPClient.commandFCPublish("key"), as: UTF8.self).contains("FCPublish"))
        #expect(String(decoding: RTMPClient.commandReleaseStream("key"), as: UTF8.self).contains("releaseStream"))
        #expect(AACSilenceEncoder.frame().count >= 6)
    }

    @Test
    func programAudio_encodesQueuedPCMInsteadOfSilence() {
        ProgramAACEncoder.reset()
        let tone: [Float] = (0..<4096).map { index in
            Float(sin(2 * Double.pi * 440 * Double(index) / 48_000))
        }
        ProgramPCMBridge.enqueueMono(tone, sampleRate: 48_000)
        let first = ProgramAACEncoder.nextAccessUnit()
        let silence = AACSilenceEncoder.frame()
        #expect(first.count >= 6)
        #expect(first != silence)
        ProgramAACEncoder.reset()
    }

    @Test
    func programAudio_previewPumpFeedsMonitorMixWithoutAAC() {
        ProgramAACEncoder.reset()
        let slide = [Float](repeating: 0.12, count: 4096)
        ProgramAACEncoder.enqueueInterleavedStereo(slide, role: .slide)
        ProgramAACEncoder.pumpPreviewMonitorMix()
        let monitor = ProgramPCMBridge.consumeInterleavedStereo(frameCount: 1024)
        #expect(monitor.contains { abs($0) > 0.01 })
        ProgramAACEncoder.reset()
    }

    @Test
    func programStreamAudioClock_matchesAACFrameDuration() {
        #expect(ProgramStreamAudioClock.framesPerAccessUnit == 1024)
        #expect(ProgramStreamAudioClock.interleavedSamplesPerAccessUnit == 2048)
        let ms0 = ProgramStreamAudioClock.timestampMs(forAccessUnitIndex: 0)
        let ms1 = ProgramStreamAudioClock.timestampMs(forAccessUnitIndex: 1)
        #expect(ms0 == 0)
        #expect(ms1 == 21)
        let ms48 = ProgramStreamAudioClock.timestampMs(forAccessUnitIndex: 48)
        #expect(ms48 == 1_024)
    }

    @Test
    func programAudio_mixesWhenSlideLaneShorterThanMic() {
        ProgramAACEncoder.reset()
        let mic = [Float](repeating: 0.15, count: 4096)
        let slide = [Float](repeating: 0.08, count: 512)
        ProgramAACEncoder.enqueueInterleavedStereo(mic, role: .microphone)
        ProgramAACEncoder.enqueueInterleavedStereo(slide, role: .slide)
        let encoded = ProgramAACEncoder.nextAccessUnit()
        let silence = AACSilenceEncoder.frame()
        #expect(encoded != silence)
        ProgramAACEncoder.reset()
    }

    @Test
    func programPCMBridge_exposesMonitorRingForVirtualAudio() {
        ProgramAACEncoder.reset()
        let tone: [Float] = [0.25, -0.25, 0.5]
        ProgramPCMBridge.enqueueMono(tone, sampleRate: 48_000)
        ProgramAACEncoder.pumpPreviewMonitorMix()
        let pulled = ProgramPCMBridge.consumeInterleavedStereo(frameCount: 3)
        #expect(pulled.count == 6)
        #expect(abs(pulled[0] - 0.25) < 0.001)
        #expect(abs(pulled[1] - 0.25) < 0.001)
        #expect(abs(pulled[4] - 0.5) < 0.001)
    }

    @Test
    func encoder_keepsOnEncodedAcrossSetup() {
        let encoder = HardwareVideoEncoder()
        var packets = 0
        encoder.onEncoded = { _ in packets += 1 }
        encoder.setupSession(width: 320, height: 180, fps: 30, bitrateKbps: 800)
        #expect(encoder.onEncoded != nil)
        #if canImport(CoreVideo)
        if let pixel = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 320, height: 180) {
            encoder.encode(pixelBuffer: pixel, presentationTime: 0)
            encoder.flushPendingEncodes()
            #expect(packets >= 1)
        }
        #endif
        encoder.teardown()
    }

    @Test
    func broadcastTimecode_countsElapsedSeconds() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(StreamingEngine.broadcastTimecode(from: nil, now: start) == "00:00:00")
        #expect(StreamingEngine.broadcastTimecode(from: start, now: start.addingTimeInterval(65)) == "00:01:05")
    }

    @Test @MainActor
    func start_requiresStreamKeyForDirectRTMP() {
        let engine = StreamingEngine()
        engine.transport = MockStreamTransport()
        engine.config.useCloudRelay = false
        engine.config.destinationURL = "rtmp://a.rtmp.youtube.com/live2"
        engine.config.streamKey = ""
        #expect(engine.start() == false)
        #expect(engine.state == .failed)
        #expect(engine.isLive == false)
        #expect(engine.lastError?.contains("stream key") == true)
    }

    @Test @MainActor
    func liveTransport_rejectsMissingStreamName() {
        let client = RTMPStreamTransport()
        #expect(client.connectCount == 0)
        #expect(throws: (any Error).self) {
            try client.connect(config: RtmpStreamConfig.default)
        }
        #expect(client.connectCount == 0)
        #expect(client.isReady == false)
    }

    @Test @MainActor
    func programSurfaceGrabber_isNilWithoutAudienceWindow() {
        #expect(ProgramSurfaceGrabber.capture(width: 320, height: 180) == nil)
    }

    @Test @MainActor
    func encodeProgramFrame_usesCompositorBufferNotRawCamera() async {
        let controller = TestSupport.sampleController()
        controller.compositor.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: controller.show.id,
                slideIndex: 0,
                layers: CueLayers(
                    slideText: [SlideElement(text: "Grace")],
                    videoInputAction: VideoInputSource(id: UUID(), label: "Cam", kind: .camera)
                )
            )
        )
        #if canImport(CoreVideo)
        let camera = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 64, height: 36)
        if let camera {
            controller.videoInputs.ingest.inject(
                VideoIngestFrame(
                    sourceID: StudioSeedID.camera,
                    label: "Cam",
                    kind: .camera,
                    width: 64,
                    height: 36,
                    timestamp: 1,
                    backend: "avfoundation",
                    sample: RGBA8(r: 0.1, g: 0.8, b: 0.2, a: 1)
                ),
                pixelBuffer: camera
            )
        }
        #endif
        let transport = MockStreamTransport()
        controller.streaming.transport = transport
        controller.streaming.config.useCloudRelay = true
        controller.streaming.config.destinationURL = "rtmps://relay.local/live/test"
        ProgramSurfaceGrabber.useAudienceSurfaceForLiveStreamEncode = false
        defer { ProgramSurfaceGrabber.useAudienceSurfaceForLiveStreamEncode = true }
        #expect(controller.streaming.start())
        controller.tickProgram()
        ProShowQueues.programClockQueue.sync {}
        #expect(controller.streaming.lastEncodeSource == .programComposite)
        #if canImport(CoreVideo)
        #expect(controller.compositor.masterProgramOutputBuffer != nil)
        #expect(controller.compositor.programOutput.lastCoveredLayers.contains(RenderLayer.slide.rawValue))
        #endif
        controller.streaming.stop()
    }

    @Test @MainActor
    func encodeProgramFrame_doesNotDependOnWindowSnapshot() {
        #expect(ProgramSurfaceGrabber.capture(width: 320, height: 180) == nil)
        let controller = TestSupport.sampleController()
        controller.compositor.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: controller.show.id,
                slideIndex: 0,
                layers: CueLayers(slideText: [SlideElement(text: "On Air")])
            )
        )
        controller.streaming.transport = MockStreamTransport()
        controller.streaming.config.useCloudRelay = true
        controller.streaming.config.destinationURL = "rtmps://relay.local/live/test"
        ProgramSurfaceGrabber.useAudienceSurfaceForLiveStreamEncode = false
        defer { ProgramSurfaceGrabber.useAudienceSurfaceForLiveStreamEncode = true }
        #expect(controller.streaming.start())
        controller.tickProgram()
        ProShowQueues.programClockQueue.sync {}
        #expect(controller.streaming.lastEncodeSource == .programComposite)
        #if canImport(CoreVideo)
        #expect(controller.compositor.masterProgramOutputBuffer != nil)
        #endif
        controller.streaming.stop()
    }

    @Test @MainActor
    func encodeProgramFrame_cleanFeedUsesCameraBuffer() {
        let engine = StreamingEngine()
        engine.transport = MockStreamTransport()
        engine.config.useCloudRelay = true
        engine.config.destinationURL = "rtmps://relay.local/live/test"
        engine.usesCleanFeed = true
        #expect(engine.start())
        #if canImport(CoreVideo)
        if let camera = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 32, height: 18) {
            engine.encodeProgramFrame(pixelBuffer: camera, source: .cleanFeed)
            #expect(engine.lastEncodeSource == .cleanFeed)
        }
        #endif
        engine.stop()
    }

    @Test @MainActor
    func streamMonitor_publishesEncodedPreviewWhenLive() {
        let controller = TestSupport.sampleController()
        #expect(!controller.wantsEncodedPreview)
        controller.streaming.transport = MockStreamTransport()
        controller.streaming.config.useCloudRelay = true
        controller.streaming.config.destinationURL = "rtmps://relay.local/live/test"
        #expect(controller.streaming.start())
        controller.tickProgram()
        ProShowQueues.programClockQueue.sync {}
        #expect(controller.wantsEncodedPreview)
        #if canImport(CoreVideo)
        #expect(controller.compositor.masterProgramOutputBuffer != nil)
        #endif
        controller.streaming.stop()
    }

    @Test
    func streamVideoCFR_quantizesPresentationTimeAndTimestamps() {
        #if canImport(CoreMedia)
        let fps: Int32 = 30
        let pts0 = StreamVideoCFRClock.presentationTime(frameIndex: 0, fps: fps)
        let pts1 = StreamVideoCFRClock.presentationTime(frameIndex: 1, fps: fps)
        let step = CMTimeSubtract(pts1, pts0)
        #expect(step.value == 1)
        #expect(step.timescale == 30)
        #expect(StreamVideoCFRClock.frameDuration(fps: fps) == step)
        #expect(StreamVideoCFRClock.timestampMs(frameIndex: 0, fps: fps) == 0)
        #expect(StreamVideoCFRClock.timestampMs(frameIndex: 1, fps: fps) == 33)
        #expect(StreamVideoCFRClock.timestampMs(frameIndex: 30, fps: fps) == 1_000)
        #endif
    }

    @Test
    func rtmp_onMetaData_includesExplicitFramerate() {
        let payload = RTMPStreamTransport.createOnMetaDataPayload(
            width: 1920,
            height: 1080,
            fps: 30,
            bitrateKbps: 5500
        )
        let text = String(decoding: payload, as: UTF8.self)
        #expect(text.contains("onMetaData"))
        #expect(text.contains("@setDataFrame"))
        #expect(text.contains("framerate"))
    }

    @Test
    func mediaClock_stampsAudioOnOneGrid() {
        let clock = MediaClockAnchor()
        clock.reset()
        let first = clock.nextAudioPresentationTime()
        let second = clock.nextAudioPresentationTime()
        #expect(first.isValid)
        #expect(CMTimeCompare(second, first) > 0)
        let step = CMTimeSubtract(second, first)
        #expect(step.value == 1024)
        #expect(step.timescale == 48_000)
        let video = clock.currentPresentationTime()
        #expect(video.isValid)
        #expect(CMTimeCompare(video, .zero) >= 0)
        clock.clear()
        let idle = clock.nextAudioPresentationTime()
        #expect(idle.value == 0)
    }

    @Test
    func endpointQueue_dropsDeltasUntilNextKeyframe() {
        let lock = NSLock()
        var held: [@Sendable () -> Void] = []
        let queue = RTMPEndpointQueue(endpointId: "b", maxPending: 3) { _, done in
            lock.lock()
            held.append(done)
            lock.unlock()
        }
        for _ in 0..<20 {
            queue.enqueue(Data([0x27]), kind: .video(keyframe: false))
        }
        queue.sync()
        #expect(queue.droppedTagCount > 0)
        let acceptedBeforeKey = queue.acceptedTagCount
        queue.enqueue(Data([0x27]), kind: .video(keyframe: false))
        queue.enqueue(Data([0xAF]), kind: .audio)
        queue.sync()
        #expect(queue.acceptedTagCount == acceptedBeforeKey + 1)
        queue.enqueue(Data([0x17]), kind: .video(keyframe: true))
        queue.sync()
        #expect(queue.acceptedTagCount == acceptedBeforeKey + 2)
        lock.lock()
        let completions = held
        held.removeAll()
        lock.unlock()
        for done in completions {
            done()
        }
        queue.cancel()
    }

    @Test
    func endpointQueue_keepsAudioWhenVideoBacksUp() {
        let lock = NSLock()
        var held: [@Sendable () -> Void] = []
        let queue = RTMPEndpointQueue(endpointId: "audio", maxPending: 2) { _, done in
            lock.lock()
            held.append(done)
            lock.unlock()
        }
        for _ in 0..<16 {
            queue.enqueue(Data([0xAF]), kind: .audio)
            queue.enqueue(Data([0x27]), kind: .video(keyframe: false))
        }
        queue.sync()
        #expect(queue.droppedAudioTagCount == 0)
        #expect(queue.droppedTagCount > 0)
        lock.lock()
        let completions = held
        lock.unlock()
        for done in completions { done() }
        queue.cancel()
    }

    @Test
    func endpointQueue_capsAudioTags() {
        let lock = NSLock()
        var held: [@Sendable () -> Void] = []
        let queue = RTMPEndpointQueue(endpointId: "audio-cap", maxPending: 120) { _, done in
            lock.lock()
            held.append(done)
            lock.unlock()
        }
        for _ in 0..<40 {
            queue.enqueue(Data([0xAF]), kind: .audio)
        }
        queue.sync()
        #expect(queue.droppedAudioTagCount == 2)
        lock.lock()
        let completions = held
        lock.unlock()
        for done in completions { done() }
        queue.cancel()
    }

    @Test
    func masterClock_videoAndAudioPTSAreRational() {
        let clock = MasterClock(t0: .zero)
        let video = clock.videoPTS(frameIndex: 30, fpsNum: 30, fpsDen: 1)
        #expect(video.value == 30)
        #expect(video.timescale == 30)
        #expect(clock.flvMilliseconds(video) == 1_000)
        let audio = clock.audioPTS(sampleCount: 1024)
        #expect(audio.value == 1024)
        #expect(audio.timescale == 48_000)
        let first = clock.claimVideoFrame()
        let second = clock.claimVideoFrame()
        #expect(first == 0)
        #expect(second == 1)
    }

    @Test
    func audioMixer_starvedLaneStillEmitsFullBlock() {
        let mixer = AudioMixer()
        let clock = MasterClock(t0: .zero)
        let ready = DispatchSemaphore(value: 0)
        mixer.onBlock = { samples, _ in
            #expect(samples.count == 2048)
            #expect(samples.contains { $0 > 0 })
            ready.signal()
        }
        mixer.mixOnce(clock: clock) {
            var tone = [Float](repeating: 0, count: 2048)
            for index in stride(from: 0, to: 2048, by: 2) {
                tone[index] = 0.25
            }
            mixer.absorb(tone, role: .microphone, gain: 1)
            mixer.absorb([Float](repeating: 0, count: 64), role: .desktop, gain: 1)
        }
        #expect(ready.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func sendQueue_dropsPFramesAndKeepsAudio() {
        let queue = StreamSendQueue(endpointId: "test", dropThreshold: 0.01, maxDuration: 5)
        var sentAudio = 0
        var sentVideo = 0
        var held: [() -> Void] = []
        queue.transmit = { packet, done in
            switch packet.kind {
            case .audio: sentAudio += 1
            case .video: sentVideo += 1
            }
            held.append(done)
        }
        let audio = StreamV2Packet(kind: .audio, pts: CMTime(value: 0, timescale: 1000), payload: Data([1]))
        let lateAudio = StreamV2Packet(kind: .audio, pts: CMTime(value: 800, timescale: 1000), payload: Data([1]))
        let delta = StreamV2Packet(kind: .video(keyframe: false), pts: CMTime(value: 400, timescale: 1000), payload: Data([2]))
        queue.enqueue(audio)
        queue.enqueue(delta)
        queue.enqueue(lateAudio)
        queue.sync()
        #expect(sentAudio == 2)
        #expect(sentVideo == 0)
        #expect(queue.droppedPFrameCount >= 1)
    }

    #if canImport(AVFoundation) && canImport(CoreVideo)
    @Test
    func passthroughRecorder_writesEncoderSamplesWithoutPixelAppend() {
        let encoder = HardwareVideoEncoder()
        encoder.setupSession(width: 320, height: 180, fps: 30, bitrateKbps: 800)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proshow-passthrough-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        guard case let .success(recorder) = ProgramVideoFileRecorder.makePassthrough(
            url: url,
            width: 320,
            height: 180,
            fps: 30
        ) else {
            encoder.teardown()
            return
        }
        #expect(recorder.isPassthrough)
        if let pixel = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 320, height: 180) {
            recorder.append(pixel, presentationTime: 0)
            recorder.flushPending()
            #expect(recorder.framesWritten == 0)
            encoder.onEncodedSample = { sample in
                recorder.appendEncodedVideoSample(sample)
            }
            encoder.encode(pixelBuffer: pixel, presentationTime: 0)
            encoder.flushPendingEncodes()
            recorder.flushPending()
            #expect(recorder.framesWritten >= 1)
        }
        let finished = DispatchSemaphore(value: 0)
        recorder.finish { _, _ in
            finished.signal()
        }
        finished.wait()
        encoder.teardown()
    }
    #endif

    @Test
    func laneKey_ignoresBitrateAndSplitsFrameRate() {
        let preset = StreamEncoderConfig.preset720p30Saver()
        let youtube = LaneMember(id: UUID(), screen: .stream, scaleMode: .fit, bitrateBps: 6_000_000, ceilingBps: 8_000_000)
        let twitch = LaneMember(id: UUID(), screen: .stream, scaleMode: .fill, bitrateBps: 4_000_000, ceilingBps: 6_000_000)
        let third = LaneMember(id: UUID(), screen: .stream, scaleMode: .fit, bitrateBps: 2_500_000, ceilingBps: 3_000_000)
        let plan = EncodeLaneGrouper.group(members: [youtube, twitch, third], streamPreset: preset)
        #expect(plan.lanes.count == 1)
        #expect(plan.lanes[0].targetBitrateBps == 2_500_000)
        #expect(plan.lanes[0].scaleMode == .fit)
        #expect(plan.refusedIDs.isEmpty)

        var sixty = twitch
        sixty.frameRate = 60
        sixty.id = UUID()
        let split = EncodeLaneGrouper.group(members: [youtube, sixty], streamPreset: preset)
        #expect(split.lanes.count == 2)
        #expect(split.lanes.map(\.key.frameRate).sorted() == [30, 60])
    }

    @Test
    func laneGrouper_phoneIsSecondLane_wallDoesNotEncode_thirdIsRefused() {
        let preset = StreamEncoderConfig(
            width: 1920, height: 1080, frameRate: 30, targetBitrateBps: 4_500_000, maxBitrateCeilingBps: 5_400_000
        )
        let stream = LaneMember(id: UUID(), screen: .stream, scaleMode: .fit, bitrateBps: 4_500_000, ceilingBps: 5_400_000)
        let phone = LaneMember(id: UUID(), screen: .phone, scaleMode: .fill, bitrateBps: 8_000_000, ceilingBps: 8_000_000)
        let wall = LaneMember(id: UUID(), screen: .wall, scaleMode: .fit, bitrateBps: 1_000_000, ceilingBps: 1_000_000)
        let custom = LaneMember(id: UUID(), screen: .custom, scaleMode: .fit, bitrateBps: 3_000_000, ceilingBps: 3_000_000, width: 1080, height: 1080)
        let plan = EncodeLaneGrouper.group(members: [stream, phone, wall, custom], streamPreset: preset)
        #expect(plan.lanes.count == 2)
        #expect(plan.lanes.map(\.role) == [.stream, .phone])
        #expect(plan.lanes[1].key.width == 1080)
        #expect(plan.lanes[1].key.height == 1920)
        #expect(plan.lanes[1].key.frameRate == 30)
        #expect(plan.displayOnlyIDs == [wall.id])
        #expect(plan.refusedIDs == [custom.id])
        #expect(plan.lanes[1].targetBitrateBps == 8_000_000)
    }

    @Test
    func missingPhoneCanvas_alwaysFits_presentKeepsFill() {
        #expect(PhoneSlideRouting.state(boards: []) == .absent)
        #expect(PhoneSlideRouting.scaleMode(requested: .fill, state: .absent) == .fit)
        #expect(PhoneSlideRouting.scaleMode(requested: .fill, state: .linked) == .fit)
        let phone = EditorCanvasFrame(
            id: UUID(),
            name: "Phone",
            width: 1080,
            height: 1920,
            originX: 0,
            originY: 0,
            isPrimary: false
        )
        #expect(PhoneSlideRouting.state(boards: [phone]) == .present)
        #expect(PhoneSlideRouting.scaleMode(requested: .fill, state: .present) == .fill)
        let fit = FrameScale.placement(sourceWidth: 1920, sourceHeight: 1080, destWidth: 1080, destHeight: 1920, mode: .fit)
        #expect(fit.height < 1920)
        #expect(fit.upscaled == false)
        let up = FrameScale.placement(sourceWidth: 1280, sourceHeight: 720, destWidth: 1920, destHeight: 1080, mode: .fit)
        #expect(up.upscaled)
    }

    @Test
    func legacyDestination_decodesWithoutScreenField() throws {
        let account = StreamAccount(accountName: "YouTube", platform: .youtube)
        let data = try JSONEncoder().encode(account)
        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        object.removeValue(forKey: "screenId")
        object.removeValue(forKey: "scaleMode")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(StreamAccount.self, from: legacy)
        #expect(decoded.screenKind == .stream)
        #expect(decoded.scaleMode == .fit)
        var phone = decoded
        phone.screenId = DestinationScreenKind.phone.rawValue
        phone.scaleMode = .fill
        let again = try JSONDecoder().decode(StreamAccount.self, from: JSONEncoder().encode(phone))
        #expect(again.screenKind == .phone)
        #expect(again.scaleMode == .fill)
        let quiet = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any] ?? [:]
        #expect(quiet["screenId"] == nil)
        #expect(quiet["scaleMode"] == nil)
    }
}
