#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct MediaLoaderTests {
    @Test
    func imageAction_setsFilePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try TestSupport.writePNGFixture(in: dir)
        let inspected = MediaLoader.inspect(url: url)
        let item = MediaBinItem(title: "Still", kind: .image, tintHex: "#000000", source: .resources, filePath: url.path)
        let action = MediaLoader.action(from: item, inspected: inspected)
        #expect(action.filePath == url.path)
        #expect(action.isImage)
        #expect(!MediaLoader.hasVideoTrack(at: url))
        #expect(!MediaLoader.hasVideoTrack(at: URL(fileURLWithPath: "/tmp/proshow-missing-\(UUID().uuidString).mp4")))
    }

    @Test @MainActor
    func missingFile_doesNotCrash() {
        let url = URL(fileURLWithPath: "/tmp/proshow-missing-\(UUID().uuidString).png")
        let result = MediaLoader.inspect(url: url)
        if case .missing = result {
            #expect(true)
        } else {
            Issue.record("Expected missing result")
        }
        let controller = TestSupport.sampleController()
        let item = MediaBinItem(title: "Gone", kind: .image, tintHex: "#111111", source: .resources, filePath: url.path)
        controller.triggerMedia(item)
        #expect(controller.compositor.stack.media == nil)
        #expect(controller.mediaAlert?.contains("Missing") == true)
    }

    @Test @MainActor
    func importMedia_readsFixture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try TestSupport.writePNGFixture(in: dir)
        let controller = TestSupport.sampleController()
        let item = controller.importMedia(url: url)
        #expect(item?.kind == .image)
        #expect(item?.filePath != nil)
        if let path = item?.filePath {
            #expect(MediaPath.resolve(path, projectRoot: controller.mediaProjectRoot) != nil || FileManager.default.fileExists(atPath: path))
        }
    }

    @Test @MainActor
    func importMedia_persistsAcrossStudioRestore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try TestSupport.writePNGFixture(in: dir, name: "house-still.png")
        let controller = TestSupport.sampleController()
        let imported = controller.importMedia(url: url)
        #expect(imported != nil)
        let snapshot = controller.studioSnapshot()
        #expect(snapshot.importedMedia.contains(where: { $0.id == imported?.id }))
        #expect(snapshot.mediaCollections.contains(where: { collection in
            collection.items.contains(where: { $0.id == imported?.id })
        }))

        let restored = TestSupport.sampleController()
        restored.installStudio(snapshot)
        #expect(restored.importedMedia.contains(where: { $0.id == imported?.id }))
        #expect(restored.allMediaItems.contains(where: { $0.title == "house-still" }))
        #expect(restored.mediaArtworkURL(for: restored.allMediaItems.first(where: { $0.id == imported?.id }) ?? imported!) != nil)
    }

    @Test @MainActor
    func importMedia_survivesSeedStudioInstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try TestSupport.writePNGFixture(in: dir, name: "persisted-still.png")
        let controller = TestSupport.sampleController()
        let imported = controller.importMedia(url: url)
        #expect(imported != nil)
        controller.installStudio(DefaultSeedData.studioManifest())
        controller.restoreMediaLibrary()
        #expect(controller.allMediaItems.contains(where: { $0.id == imported?.id }))
        #expect(controller.mediaArtworkURL(for: controller.allMediaItems.first(where: { $0.id == imported?.id }) ?? imported!) != nil)
    }

    @Test
    func resolve_joinsProjectRelativePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try TestSupport.writePNGFixture(in: root.appendingPathComponent("Assets/Media"), name: "still.png")
        let previousRoot = MediaPath.currentProjectRoot
        MediaPath.currentProjectRoot = nil
        #expect(MediaPath.resolve("Assets/Media/still.png", projectRoot: root)?.path == url.path)
        #expect(MediaPath.resolve("Assets/Media/still.png", projectRoot: nil) == nil)
        #expect(MediaPath.resolve("/no/such/proshow-file.png", projectRoot: root) == nil)
        MediaPath.currentProjectRoot = previousRoot
    }

    @Test @MainActor
    func triggerMedia_playsProjectRelativeVideo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let video = try AssetPreview.writeSolidVideo(
            to: root.appendingPathComponent("Assets/Videos/countdown.mp4"),
            width: 160,
            height: 90,
            seconds: 0.4,
            fps: 10
        )
        let controller = TestSupport.sampleController()
        controller.playback.projectRoot = root
        let item = MediaBinItem(
            title: "Relative Clip",
            kind: .video(duration: "0:00.40"),
            tintHex: "#112233",
            source: .resources,
            filePath: "Assets/Videos/countdown.mp4"
        )
        controller.triggerMedia(item)
        #expect(controller.mediaAlert == nil)
        #expect(controller.compositor.stack.media?.title == "Relative Clip")
        #expect(controller.playback.fileURL == video)
        #expect(controller.playback.usesFilePlayer)
    }

    @Test @MainActor
    func rebindingSameMedia_doesNotResetPlayhead() {
        let engine = MediaPlaybackEngine()
        let media = TestSupport.mediaAction(title: "Loop")
        engine.load(media)
        engine.playhead = 14.5
        engine.load(media, restart: false)
        #expect(engine.playhead == 14.5)
        #expect(engine.mediaID == media.id)
        #expect(engine.isBound(to: media))
    }

    @Test @MainActor
    func loadDifferentMedia_resetsPlayhead() {
        let engine = MediaPlaybackEngine()
        let first = TestSupport.mediaAction(title: "A")
        let second = TestSupport.mediaAction(title: "B")
        engine.load(first)
        engine.playhead = 8
        engine.load(second)
        #expect(engine.playhead == 0)
        #expect(engine.mediaID == second.id)
        #expect(engine.isBound(to: second))
    }

    @Test @MainActor
    func sharesClock_matchesRelativeAbsolutePlaceholderAndMediaID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("worship-loop.mp4")
        try Data("clip".utf8).write(to: url)
        let mediaID = UUID()
        let engine = MediaPlaybackEngine()
        engine.projectRoot = dir
        let media = MediaAction(
            id: mediaID,
            title: "Worship Loop",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: url.path,
            placeholderLetter: "A"
        )
        engine.load(media)
        engine.playhead = 17

        #expect(engine.sharesClock(withPath: "worship-loop.mp4"))
        #expect(engine.sharesClock(withPath: url.path))
        #expect(engine.sharesClock(withPath: mediaID.uuidString))
        #expect(engine.sharesClock(withPlaceholder: "A"))
        #expect(engine.sharesClock(withPath: "placeholder://A"))

        var rebuilt = media
        rebuilt.id = UUID()
        rebuilt.filePath = "worship-loop.mp4"
        engine.load(rebuilt, restart: false)
        #expect(abs(engine.playhead - 17) < 0.01)
        #expect(engine.sharesClock(with: rebuilt))

        let source = AssignedMediaSource(
            sourceID: "media-\(mediaID.uuidString)",
            name: "Worship Loop",
            sourceType: .mediaFile,
            category: .mediaFiles,
            connectionString: "worship-loop.mp4",
            placeholderLetter: "A",
            mediaItemID: mediaID
        )
        #expect(engine.sharesClock(with: source))

        var plate = CanvasObject(name: "Background", kind: .image, bounds: .canvas)
        plate.id = mediaID
        plate.fill.type = .image
        plate.fill.imageURI = "Assets/Videos/worship-loop.mp4"
        #expect(engine.sharesClock(with: plate))

        let unbound = MediaPlaybackEngine()
        unbound.projectRoot = dir
        var fileOnly = media
        fileOnly.placeholderLetter = nil
        unbound.load(fileOnly)
        unbound.adoptPlaceholders(["A", "B"])
        #expect(unbound.sharesClock(withPlaceholder: "A"))
        #expect(unbound.sharesClock(withPlaceholder: "b"))
        #expect(!unbound.sharesClock(withPlaceholder: "C"))
    }
}
