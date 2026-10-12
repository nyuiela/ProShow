#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct SceneManagerTests {
    @Test @MainActor
    func defaultScenes_switchByHotkeyAndPersist() throws {
        let controller = TestSupport.sampleController()
        #expect(controller.scenes.scenes.map(\.name) == [
            "Camera",
            "Camera + Deck",
            "Interview",
            "Display + Camera",
        ])
        #expect(controller.triggerSceneHotkey("2"))
        #expect(controller.scenes.activeSceneID == StudioSeedID.presenterDeck)
        #expect(controller.compositor.stack.pipInput?.label == "Presenter Camera")
        #expect(controller.compositor.stack.pipBounds == .pipLowerRight)

        #expect(controller.triggerSceneHotkey("3"))
        #expect(controller.compositor.stack.primaryBounds == .leftHalf)
        #expect(controller.compositor.stack.pipBounds == .rightHalf)

        #expect(controller.triggerSceneHotkey("4"))
        #expect(controller.audioMatrix.duckingEnabled)
        #expect(controller.videoInputs.activePIPID == StudioSeedID.camera)

        let listed = controller.handleControl(method: "GET", path: "/v1/scenes")
        #expect(listed.0 == 200)
        #expect(listed.1.contains("Camera"))

        let triggered = controller.handleControl(
            method: "POST",
            path: "/v1/scenes/\(StudioSeedID.solo.uuidString)/trigger"
        )
        #expect(triggered.0 == 200)
        #expect(controller.scenes.activeSceneID == StudioSeedID.solo)
    }

    @Test @MainActor
    func liveIO_doesNotOpenSeedCameraWhenSwitchingScenes() {
        let controller = TestSupport.sampleController()
        let bound = StudioVideoSource(
            id: UUID(),
            label: "MacBook Camera",
            kind: .camera,
            endpoint: "avf://mac-cam"
        )
        controller.videoInputs.register(bound)
        controller.enableLiveIO()
        #expect(controller.videoInputs.activatePrimary(bound.id) == .started)
        let starts = controller.videoInputs.ingest.hardwareStartCount
        #expect(controller.triggerSceneHotkey("1"))
        #expect(controller.videoInputs.ingest.hardwareStartCount == starts)
        #expect(controller.videoInputs.isRunning(bound))
    }

    @Test @MainActor
    func projectBundle_restoresScenesAndMix() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        var bundle = try ProjectBundle.create(at: url, name: "Studio")
        #expect(bundle.manifest.studio.scenes.count == 4)
        #expect(bundle.manifest.studio.videoSources.count == 3)
        #expect(bundle.manifest.studio.soundboard.isEmpty == false)

        let controller = ShowController(
            show: SampleContent.sundayMorningService().show,
            playlist: SampleContent.sundayMorningService().playlist,
            persistOnInit: false
        )
        controller.installStudio(bundle.manifest.studio)
        #expect(controller.triggerScene(id: StudioSeedID.screenShare))
        bundle.manifest.studio = controller.studioSnapshot()
        bundle.state.activeSceneId = StudioSeedID.screenShare.uuidString
        try bundle.writeManifest()
        try bundle.writeState()

        let opened = try ProjectBundle.open(at: url)
        #expect(opened.manifest.studio.activeSceneID == StudioSeedID.screenShare)
        #expect(opened.state.activeSceneId == StudioSeedID.screenShare.uuidString)
        #expect(opened.manifest.studio.scenes.contains(where: { $0.duckDesktopAudio }))
        #expect(opened.manifest.studio.scenes.first(where: { $0.id == StudioSeedID.presenterDeck })?.pipBounds == .pipLowerRight)
    }

    @Test
    func legacyProjectJSON_decodesWithoutStudio() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "Legacy",
          "version": "1.0.0",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z",
          "settings": {
            "targetAspect": "16:9",
            "baseResolution": { "width": 3840, "height": 2160 },
            "defaultTransitionDurationMs": 1000,
            "audioSampleRate": 48000
          }
        }
        """
        let project = try ProjectJSON.decoder.decode(ProShowProject.self, from: Data(json.utf8))
        #expect(project.studio.scenes.isEmpty)
        #expect(project.name == "Legacy")
    }
}
