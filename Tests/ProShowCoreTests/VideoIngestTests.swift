#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct VideoIngestTests {
    @Test @MainActor
    func enumerate_includesCamerasAndScreens() {
        let engine = VideoInputEngine()
        let devices = engine.enumeratePhysicalDevices()
        #expect(devices.contains(where: { $0.kind == .camera }))
        #expect(devices.contains(where: { $0.kind == .screenShare }))
        #expect(devices.contains(where: { $0.id == StudioSeedID.camera }))
        #expect(devices.contains(where: { $0.id == StudioSeedID.screen }))
    }

    @Test @MainActor
    func cameraStart_publishesAvFoundationFrameOnLayer2() {
        let controller = TestSupport.sampleController()
        #expect(controller.videoInputs.lastFrame?.backend == "avfoundation")
        #expect(controller.videoInputs.lastFrame?.sourceID == StudioSeedID.camera)
        #expect(controller.compositor.stack.videoInput?.label == "Presenter Camera")
        controller.tickProgram()
        #expect(controller.compositor.lastVideoFrame?.backend == "avfoundation")
        #expect(controller.compositor.lastFrame?.visibleLayers.contains(RenderLayer.videoInput.rawValue) == true)
    }

    @Test @MainActor
    func screenShare_usesScreenCaptureKitBackend() {
        let engine = VideoIngestEngine()
        let source = StudioVideoSource(id: StudioSeedID.screen, label: "Display", kind: .screenShare, endpoint: "sck://display/0")
        #expect(engine.start(source) == .started)
        #expect(engine.lastFrame?.backend == "screenCaptureKit")
        let preset = engine.screenCapturePreset()
        #expect(preset.width == engine.outputWidth)
        #expect(preset.height == engine.outputHeight)
        #expect(preset.capturesAudio)
    }

    @Test
    func screenShareAudio_staysOutWhileAssignedMicIsLive() {
        ProgramAACEncoder.flush(role: .microphone)
        ProgramAACEncoder.flush(role: .desktop)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.microphone, open: true)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.desktop, open: true)
        let voice: [Float] = [0.2, -0.2, 0.15, -0.1]
        ProgramStreamAudioGates.enqueueCapture(role: .microphone, mono: voice, sampleRate: 48_000)
        ProgramStreamAudioGates.enqueueCapture(role: .desktop, mono: [0.9, -0.9, 0.8, -0.7], sampleRate: 48_000)
        let lanes = ProgramAACEncoder.laneDepthSummary()
        #expect(lanes.contains("mic"))
        #expect(!lanes.contains("desk"))
        ProgramAACEncoder.flush(role: .microphone)
        ProgramAACEncoder.flush(role: .desktop)
    }

    @Test @MainActor
    func register_absorbsSeedCameraAndKeepsOneDevice() {
        let engine = VideoInputEngine()
        engine.install([
            StudioVideoSource(id: StudioSeedID.camera, label: "Presenter Camera", kind: .camera),
            StudioVideoSource(id: StudioSeedID.cameraB, label: "Guest Camera", kind: .continuity),
            StudioVideoSource(id: StudioSeedID.screen, label: "Display Capture", kind: .screenShare, endpoint: "sck://display/0"),
        ])
        let first = StudioVideoSource(
            id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
            label: "MacBook Pro Camera",
            kind: .camera,
            endpoint: "avf://legacy-uuid"
        )
        let second = StudioVideoSource(
            id: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            label: "MacBook Pro Camera",
            kind: .camera,
            endpoint: "avf://new-style-uuid"
        )
        engine.register(first)
        engine.register(second)
        let cameras = engine.sources.filter { $0.kind == .camera }
        #expect(cameras.count == 1)
        #expect(cameras.first?.id == StudioSeedID.camera)
        #expect(cameras.first?.label == "MacBook Pro Camera")
        #expect(engine.source(id: first.id)?.endpoint == "avf://new-style-uuid")
        #expect(engine.attachedSources.filter { $0.kind == .camera }.count == 1)
        #expect(!engine.attachedSources.contains(where: { $0.isHardwarePlaceholder }))
    }

    @Test @MainActor
    func reconcile_keepsAttachedHardwareAndDropsHistory() {
        let engine = VideoInputEngine()
        engine.install([
            StudioVideoSource(id: StudioSeedID.camera, label: "Presenter Camera", kind: .camera),
            StudioVideoSource(id: StudioSeedID.screen, label: "Display Capture", kind: .screenShare, endpoint: "sck://display/0"),
        ])
        engine.register(
            StudioVideoSource(label: "Old USB Camera", kind: .camera, endpoint: "avf://gone")
        )
        engine.register(
            StudioVideoSource(label: "Old USB Camera", kind: .camera, endpoint: "avf://gone-again")
        )
        let live = StudioVideoSource(
            id: StudioSeedID.camera,
            label: "MacBook Pro Camera",
            kind: .camera,
            endpoint: "avf://built-in"
        )
        let display = StudioVideoSource(
            id: StudioSeedID.screen,
            label: "Entire Display — Built-in",
            kind: .screenShare,
            endpoint: "sck://display/1"
        )
        engine.reconcile(with: [live, display], includeNDI: false)
        #expect(Set(engine.attachedSources.map(\.label)) == ["MacBook Pro Camera", "Entire Display — Built-in"])
        #expect(!engine.sources.contains(where: { $0.endpoint == "avf://gone" }))
        #expect(!engine.sources.contains(where: { $0.isHardwarePlaceholder }))
    }

    @Test
    func seedPlaceholder_isNotABindableHardwareEndpoint() {
        let seed = StudioVideoSource(id: StudioSeedID.camera, label: "Presenter Camera", kind: .camera)
        #expect(!seed.hasBindableHardwareEndpoint)
        let bound = StudioVideoSource(
            id: StudioSeedID.camera,
            label: "Mac Camera",
            kind: .camera,
            endpoint: "avf://mac-cam"
        )
        #expect(bound.hasBindableHardwareEndpoint)
        let ndiAddress = StudioVideoSource(
            label: "CAMERA (NDI)",
            kind: .ndi,
            endpoint: "192.168.1.20:5961"
        )
        #expect(ndiAddress.hasBindableHardwareEndpoint)
    }

    @Test @MainActor
    func start_seedCameraWithoutEndpoint_doesNotOpenHardware() {
        let engine = VideoIngestEngine()
        engine.hardwareEnabled = true
        let seed = StudioVideoSource(id: StudioSeedID.camera, label: "Presenter Camera", kind: .camera)
        #expect(engine.start(seed) == .started)
        #expect(engine.hardwareStartCount == 0)
        #expect(engine.lastFrame?.backend == "avfoundation")
    }

    @Test @MainActor
    func inject_bumpsFrameRevisionForDisplayPreview() {
        let engine = VideoIngestEngine()
        let before = engine.frameRevision
        engine.inject(
            VideoIngestFrame(
                sourceID: StudioSeedID.screen,
                label: "Built-in Display",
                kind: .screenShare,
                width: 1920,
                height: 1080,
                timestamp: 1,
                backend: "screenCaptureKit",
                sample: RGBA8(r: 0.1, g: 0.2, b: 0.3, a: 1)
            )
        )
        #expect(engine.frameRevision == before + 1)
    }

    @Test @MainActor
    func start_cameraThenScreen_keepsBothLanesAndDoesNotRestart() {
        let engine = VideoIngestEngine()
        engine.hardwareEnabled = true
        let camera = StudioVideoSource(
            id: StudioSeedID.camera,
            label: "Mac Camera",
            kind: .camera,
            endpoint: "avf://mac-cam"
        )
        let display = StudioVideoSource(
            id: StudioSeedID.screen,
            label: "Built-in Display",
            kind: .screenShare,
            endpoint: "sck://display/1"
        )
        #expect(engine.start(camera) == .started)
        let afterCamera = engine.hardwareStartCount
        #expect(engine.isRunning(camera))
        #expect(engine.start(display) == .started)
        #expect(engine.isRunning(camera))
        #expect(engine.isRunning(display))
        #expect(engine.hardwareStartCount == afterCamera + 1)
        let afterBoth = engine.hardwareStartCount
        #expect(engine.start(camera) == .started)
        #expect(engine.start(display) == .started)
        #expect(engine.hardwareStartCount == afterBoth)
        #expect(engine.isRunning(endpoint: "avf://mac-cam", sourceID: "avf-video-mac-cam"))
        #expect(engine.isRunning(endpoint: "sck://display/1", sourceID: "sck-display-1"))
    }

    @Test @MainActor
    func start_sameCameraNameDifferentUniqueID_doesNotRestartHardware() {
        let engine = VideoIngestEngine()
        engine.hardwareEnabled = true
        let first = StudioVideoSource(
            id: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
            label: "MacBook Pro Camera",
            kind: .camera,
            endpoint: "avf://legacy-uuid"
        )
        let second = StudioVideoSource(
            id: UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!,
            label: "MacBook Pro Camera",
            kind: .camera,
            endpoint: "avf://new-style-uuid"
        )
        #expect(engine.start(first) == .started)
        let starts = engine.hardwareStartCount
        #expect(engine.start(second) == .started)
        #expect(engine.hardwareStartCount == starts)
        #expect(engine.isRunning(first))
        #expect(engine.isRunning(second))
        #expect(engine.isRunning(endpoint: "avf://legacy-uuid", sourceID: nil))
        #expect(engine.isRunning(endpoint: "avf://new-style-uuid", sourceID: nil))
    }

    @Test
    func captureDevicePairing_matchesCompanionMicrophones() {
        #if canImport(AVFoundation)
        #expect(CaptureDevicePairing.pairsCamera(videoName: "MacBook Pro Camera", audioName: "MacBook Pro Microphone"))
        #expect(CaptureDevicePairing.pairsCamera(videoName: "Kaleel's iPhone Camera", audioName: "Kaleel's iPhone Microphone"))
        #expect(CaptureDevicePairing.pairsCamera(videoName: "USB Audio Device", audioName: "USB Audio Device Microphone"))
        #expect(!CaptureDevicePairing.pairsCamera(videoName: "FaceTime HD Camera", audioName: "Display Audio"))
        #endif
    }

    @Test
    func ndiVirtualDevices_areRejectedByCatalog() {
        #expect(SystemVideoDeviceCatalog.isUnsafeCaptureDevice(name: "NDI Virtual Input", uniqueID: "abc"))
        #expect(SystemVideoDeviceCatalog.isUnsafeCaptureDevice(name: "NewTek NDI", uniqueID: "ndi-1"))
        #expect(!SystemVideoDeviceCatalog.isUnsafeCaptureDevice(name: "FaceTime HD Camera", uniqueID: "usb-1"))
    }

    @Test
    func ndiRtspWebRTC_stayUnsupported() {
        let ndi = VideoInputSource(id: UUID(), label: "NDI 1", kind: .ndi, endpoint: "ndi://studio")
        let rtsp = VideoInputSource(id: UUID(), label: "Deck", kind: .rtsp, endpoint: "rtsp://127.0.0.1/in")
        let guest = VideoInputSource(id: UUID(), label: "Guest", kind: .webrtc, endpoint: "wss://room")
        if case .unsupported = VideoInputRuntime.activate(ndi) { #expect(true) } else { Issue.record("NDI should stay unsupported") }
        if case .unsupported = VideoInputRuntime.activate(rtsp) { #expect(true) } else { Issue.record("RTSP should stay unsupported") }
        if case .unsupported = VideoInputRuntime.activate(guest) { #expect(true) } else { Issue.record("WebRTC should stay unsupported") }
    }

    @Test @MainActor
    func injectFrame_compositesOnLayer2() {
        let compositor = CompositorEngine()
        compositor.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: UUID(),
                slideIndex: 0,
                layers: CueLayers(videoInputAction: VideoInputSource(id: UUID(), label: "Cam", kind: .camera))
            )
        )
        let frame = VideoIngestFrame(
            sourceID: UUID(),
            label: "Cam",
            kind: .camera,
            width: 1920,
            height: 1080,
            timestamp: 0,
            backend: "avfoundation",
            sample: RGBA8(r: 0.8, g: 0.2, b: 0.1, a: 1)
        )
        compositor.advanceFrame(playhead: 0, videoFrame: frame)
        #expect(compositor.lastVideoFrame?.backend == "avfoundation")
        let pixel = compositor.lastRaster?.pixel(x: 8, y: 2)
        #expect((pixel?.r ?? 0) > 0.5)
    }
}
