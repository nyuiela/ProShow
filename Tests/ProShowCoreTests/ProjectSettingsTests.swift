#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct ProjectSettingsTests {
    @Test
    func testProjectSettingsResolutionPersistence() throws {
        let fourKURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        var fourK = try ProjectBundle.create(at: fourKURL, name: "Cinema")
        fourK.manifest.settings.resolution = .res4K
        fourK.manifest.settings.frameRate = .fps60
        fourK.manifest.settings.syncDerivedFields()
        try fourK.writeManifest()

        let verticalURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        var vertical = try ProjectBundle.create(at: verticalURL, name: "Shorts")
        vertical.manifest.settings.resolution = .resVertical1080
        vertical.manifest.settings.frameRate = .fps30
        vertical.manifest.settings.scaleContentOnResolutionChange = false
        vertical.manifest.settings.syncDerivedFields()
        try vertical.writeManifest()

        let opened4K = try ProjectBundle.open(at: fourKURL)
        #expect(opened4K.manifest.settings.resolution == .res4K)
        #expect(opened4K.manifest.settings.baseResolution == .uhd4K)
        #expect(opened4K.manifest.settings.frameRate == .fps60)
        #expect(opened4K.manifest.settings.aspectRatio == "16:9")

        let openedVertical = try ProjectBundle.open(at: verticalURL)
        #expect(openedVertical.manifest.settings.resolution == .resVertical1080)
        #expect(openedVertical.manifest.settings.frameRate == .fps30)
        #expect(openedVertical.manifest.settings.aspectRatio == "9:16")
        #expect(openedVertical.manifest.settings.scaleContentOnResolutionChange == false)
        #expect(openedVertical.manifest.settings.baseResolution.width == 1080)
        #expect(openedVertical.manifest.settings.baseResolution.height == 1920)
    }

    @Test @MainActor
    func testCanvasProportionalRescaling() {
        let controller = TestSupport.sampleController()
        var object = CanvasObject(
            name: "Title",
            kind: .text,
            bounds: CanvasBounds(x: 100, y: 80, width: 400, height: 200),
            fontSize: 48
        )
        object.stroke.width = 4
        object.textOutline.width = 2
        let doubled = CanvasRescaleEngine.rescale(object, by: 2)
        #expect(abs(doubled.bounds.width - 800) < 0.001)
        #expect(abs(doubled.bounds.height - 400) < 0.001)
        controller.editors.documents = [
            EditorDocument(
                name: "Slide",
                kind: .presentation,
                canvasWidth: 1920,
                canvasHeight: 1080,
                objects: [object]
            )
        ]

        var next = controller.projectSettings
        next.resolution = .res1080p
        next.frameRate = .fps30
        next.scaleContentOnResolutionChange = false
        controller.applyProjectSettings(next, persist: false, rescaleFrom: next)

        next.resolution = .res4K
        next.scaleContentOnResolutionChange = true
        controller.applyProjectSettings(next, persist: false)

        let scaled = controller.editors.documents[0].objects[0]
        #expect(abs(scaled.bounds.width - 800) < 0.001)
        #expect(abs(scaled.bounds.height - 400) < 0.001)
        #expect(abs(scaled.bounds.x - 200) < 0.001)
        #expect(abs(scaled.bounds.y - 160) < 0.001)
        #expect(abs(scaled.typography.fontSize - 96) < 0.001)
        #expect(abs(scaled.stroke.width - 8) < 0.001)
        #expect(controller.editors.documents[0].canvasWidth == 3840)
    }

    @Test @MainActor
    func testEncoderBitrateAndFrameIntervalAllocation() {
        var fourK60 = ProjectSettings.default
        fourK60.resolution = .res4K
        fourK60.frameRate = .fps60
        let ultra = EncoderBitrateProfile.allocation(for: fourK60)
        #expect(ultra.width == 3840)
        #expect(ultra.height == 2160)
        #expect(ultra.framerate == 60)
        #expect(ultra.bitrateKbps >= 15_000 && ultra.bitrateKbps <= 20_000)
        #expect(ultra.gopFrames == 120)
        #expect(abs(ultra.frameInterval - 1.0 / 60.0) < 0.0001)

        var fourK30 = fourK60
        fourK30.frameRate = .fps30
        let cinema = EncoderBitrateProfile.allocation(for: fourK30)
        #expect(cinema.bitrateKbps >= 10_000 && cinema.bitrateKbps <= 13_000)
        #expect(cinema.gopFrames == 60)
        #expect(abs(cinema.frameInterval - 1.0 / 30.0) < 0.0001)

        var hd60 = ProjectSettings.default
        hd60.resolution = .res1080p
        hd60.frameRate = .fps60
        let hd = EncoderBitrateProfile.allocation(for: hd60)
        #expect(hd.bitrateKbps >= 6_000 && hd.bitrateKbps <= 9_000)
        #expect(hd.gopFrames == 120)

        var hd30 = hd60
        hd30.frameRate = .fps30
        let hdCinematic = EncoderBitrateProfile.allocation(for: hd30)
        #expect(hdCinematic.bitrateKbps >= 4_000 && hdCinematic.bitrateKbps <= 6_000)
        #expect(hdCinematic.gopFrames == 60)

        var vertical = ProjectSettings.default
        vertical.resolution = .resVertical1080
        vertical.frameRate = .fps60
        let shorts = EncoderBitrateProfile.allocation(for: vertical)
        #expect(shorts.bitrateKbps >= 6_000 && shorts.bitrateKbps <= 8_000)

        let compositor = CompositorEngine()
        compositor.applyProjectSettings(fourK60)
        #expect(compositor.metalTextureDescriptor.width == 3840)
        #expect(compositor.metalTextureDescriptor.height == 2160)
        #expect(abs(compositor.frameInterval - 1.0 / 60.0) < 0.0001)

        compositor.applyProjectSettings(hd30)
        #expect(compositor.outputWidth == 1920)
        #expect(abs(compositor.frameInterval - 1.0 / 30.0) < 0.0001)
        #expect(abs(compositor.frameInterval - 0.0333) < 0.001)

        let streaming = StreamingEngine()
        streaming.applyProjectSettings(fourK60)
        #expect(streaming.lastAllocation?.width == 3840)
        #expect(streaming.lastAllocation?.framerate == 60)
        #expect(streaming.lastAllocation?.gopFrames == 120)
        #expect(streaming.config.width == 1280)
        #expect(streaming.config.framerate == 30)
        #expect(streaming.encoderSettings?.bitrateKbps == 2_500)

        let fps24 = ProjectSettings(resolution: .res1080p, frameRate: .fps24)
        #expect(abs(fps24.frameRate.frameInterval - 1.0 / 24.0) < 0.0001)
        #expect(abs(fps24.frameRate.frameInterval - 0.04166) < 0.001)
    }

    @Test
    func linkedProgramSurvivesProjectRelaunch() throws {
        let projectURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        var project = try ProjectBundle.create(at: projectURL, name: "Rundown")
        let programURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("program")
        var model = ProgramDocumentModel.sundayMorningSample()
        model.rundownBlocks[0].scriptBody = "Persisted script"
        try ProgramDocumentStore.save(model, to: programURL)
        project.manifest.settings.programFilePath = programURL.path
        project.manifest.settings.programFileBookmark = Data("bookmark".utf8)
        try project.writeManifest()

        let opened = try ProjectBundle.open(at: projectURL)
        #expect(opened.manifest.settings.programFilePath == programURL.path)
        #expect(opened.manifest.settings.programFileBookmark == Data("bookmark".utf8))
        let loaded = try ProgramDocumentStore.load(from: URL(fileURLWithPath: opened.manifest.settings.programFilePath ?? ""))
        #expect(loaded.rundownBlocks[0].scriptBody == "Persisted script")
        let fromJSON = try ProgramDocumentStore.load(from: programURL.appendingPathComponent("program.json"))
        #expect(fromJSON.rundownBlocks[0].scriptBody == "Persisted script")
    }
}
