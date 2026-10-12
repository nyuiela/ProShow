#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct ProjectStoreTests {
    @Test
    func createBundle_writesExpectedTree() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        let blank = DefaultSeedData.blankShow(name: "Sunday")
        let playlist = DefaultSeedData.emptyPlaylist()
        let bundle = try ProjectBundle.create(at: url, name: "Sunday", seed: blank, playlist: playlist)
        #expect(FileManager.default.fileExists(atPath: bundle.projectURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.stateURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.librariesURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.playlistsURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.imagesURL.path))
        #expect(FileManager.default.fileExists(atPath: bundle.mediaURL.path))
        #expect(bundle.manifest.settings.baseResolution == .uhd4K)
        #expect(bundle.manifest.name == "Sunday")
        #expect(bundle.manifest.version == "1.0.0")
        #expect(!bundle.libraryStore.loadAll().isEmpty)
    }

    @Test
    func saveLoad_roundTripManifestAndState() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        var bundle = try ProjectBundle.create(at: url, name: "Midweek")
        bundle.state.activeModule = .BIBLE
        bundle.state.preview.audienceOutputEnabled = false
        bundle.manifest.settings.audioSampleRate = 44100
        try bundle.writeManifest()
        try bundle.writeState()
        let opened = try ProjectBundle.open(at: url)
        #expect(opened.manifest.name == "Midweek")
        #expect(opened.state.activeModule == .BIBLE)
        #expect(opened.state.preview.audienceOutputEnabled == false)
        #expect(opened.manifest.settings.audioSampleRate == 44100)
    }

    @Test
    func walReplay_restoresUncommittedLibrary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        var bundle = try ProjectBundle.create(at: url, name: "Crash")
        let extra = Show(name: "Recovered", groups: [SlideGroup(name: "A", slides: [Slide(lines: ["Hello"])])])
        try bundle.appendWAL(.upsertLibrary(extra))
        #expect(bundle.hasUncommittedJournal())
        let opened = try ProjectBundle.open(at: url)
        #expect(opened.libraryStore.loadAll().contains(where: { $0.id == extra.id }))
        #expect(!opened.hasUncommittedJournal())
    }

    @Test @MainActor
    func autosave_commitClearsJournal() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        let bundle = try ProjectBundle.create(at: url, name: "Auto")
        let engine = AutoSaveEngine(bundle: bundle, delayNanoseconds: 0)
        try engine.record(.updateState(.default))
        try engine.commitNow()
        #expect(!engine.bundle.hasUncommittedJournal())
        #expect(engine.commitCount >= 1)
    }

    @Test
    func launchPreferences_decodesMissingThemeAsDefault() throws {
        let data = Data(#"{"alwaysOpenLastProject":false,"recent":[]}"#.utf8)
        let prefs = try ProjectJSON.decoder.decode(AppLaunchPreferences.self, from: data)
        #expect(prefs.selectedTheme == "Default")
    }

    @Test
    func launchPolicy_shiftOrMissingShowsMenu() {
        let prefs = AppLaunchPreferences(alwaysOpenLastProject: true, lastProjectPath: "/tmp/missing.proshow", recent: [])
        #expect(LaunchPolicy.decide(preferences: prefs, shiftHeld: false, fileExists: { _ in false }) == .startMenu)
        #expect(LaunchPolicy.decide(preferences: prefs, shiftHeld: true, fileExists: { _ in true }) == .startMenu)
    }

    @Test
    func launchPolicy_reopensLastWhenEnabled() {
        let path = "/tmp/Sunday.proshow"
        let prefs = AppLaunchPreferences(alwaysOpenLastProject: true, lastProjectPath: path, recent: [])
        #expect(LaunchPolicy.decide(preferences: prefs, shiftHeld: false, fileExists: { $0.path == path }) == .open(URL(fileURLWithPath: path)))
        var off = prefs
        off.alwaysOpenLastProject = false
        #expect(LaunchPolicy.decide(preferences: off, shiftHeld: false, fileExists: { _ in true }) == .startMenu)
    }

    @Test
    func embedAsset_copiesIntoImages() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        let bundle = try ProjectBundle.create(at: url, name: "Media")
        let png = try TestSupport.writePNGFixture(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let dest = try bundle.embedAsset(from: png)
        #expect(dest.path.contains("/Assets/Images/"))
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(bundle.relativePath(for: dest).hasPrefix("Assets/"))
        #expect(!bundle.relativePath(for: dest).hasPrefix("/"))
    }

    @Test @MainActor
    func autosave_markDirtyFlushesOnDemand() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        let bundle = try ProjectBundle.create(at: url, name: "Flush")
        let engine = AutoSaveEngine(bundle: bundle, delayNanoseconds: 60_000_000_000)
        let show = SampleContent.sundayMorningService().show
        engine.markDirty(show: show, state: .default)
        #expect(engine.pendingChanges)
        try engine.flushPendingSaves()
        #expect(!engine.pendingChanges)
        #expect(engine.commitCount >= 1)
        #expect(bundle.libraryStore.loadAll().contains(where: { $0.id == show.id }))
    }

    @Test
    func canvasConfig_isNative4K() {
        #expect(CanvasConfig.width == 3840)
        #expect(CanvasConfig.height == 2160)
        #expect(CanvasConfig.majorTick == 500)
        #expect(CanvasConfig.minorTick == 100)
        #expect(abs(CanvasConfig.scale1080 - 0.5) < 0.0001)
        #expect(abs(CanvasConfig.outputScale(displayWidth: 1920) - 0.5) < 0.0001)
        #expect(CanvasBounds.canvas.width == 3840)
        #expect(ProjectSettings.default.baseResolution == CaptureBudget.factoryResolution())
    }

    @Test
    func defaultSeed_has4KLibrariesAndPlaylist() {
        let shows = DefaultSeedData.allLibraryShows()
        #expect(shows.contains(where: { $0.name == "Hold" }))
        #expect(shows.contains(where: { $0.name == "Talk" }))
        #expect(shows.contains(where: { $0.name == "Lyrics" }))
        #expect(shows.contains(where: { $0.name == "End Card" }))
        #expect(shows.contains(where: { $0.name == "Lower Thirds" }))
        let lyrics = shows.first(where: { $0.name == "Lyrics" })
        #expect((lyrics?.allSlides.count ?? 0) >= 4)
        #expect(lyrics?.allSlides.first?.canvas.isEmpty == false)
        let playlist = DefaultSeedData.starterPlaylist(shows: shows)
        #expect(playlist.name == "Program")
        #expect(playlist.items.contains(where: { $0.title.contains("Starting Soon") }))
        let lyric = DefaultSeedData.themeObjects(for: "Lyric Standard")
        #expect(lyric.first?.typography.fontSize == 96)
        #expect(lyric.first?.textOutline.enabled == true)
        let lower = DefaultSeedData.themeObjects(for: "Lower Third")
        #expect(lower.contains(where: { $0.bounds.x == 200 && $0.bounds.y == 1600 }))
        let props = DefaultSeedData.propDocuments()
        #expect(props.contains(where: { $0.name == "Logo Bug" }))
        #expect(props.contains(where: { $0.objects.contains(where: { $0.bounds.x == 3400 }) }))
    }

    @Test
    func legacyDetector_replacesOnlyChurchDemoLibraries() {
        #expect(DefaultSeedData.isLegacyChurchDemoLibrary([
            Show(name: "Sunday Morning", groups: []),
            Show(name: "Amazing Grace", groups: []),
        ]))
        #expect(!DefaultSeedData.isLegacyChurchDemoLibrary([
            Show(name: "Sunday Morning", groups: []),
            Show(name: "Youth Night", groups: []),
        ]))
        #expect(!DefaultSeedData.isLegacyChurchDemoLibrary([
            Show(name: "Hold", groups: []),
            Show(name: "Talk", groups: []),
        ]))
    }

    @Test @MainActor
    func bootstrap_replacesLegacyChurchDemoLibrary() throws {
        let store = LibraryStore.temporary()
        try store.save(Show(name: "Sunday Morning", groups: [SlideGroup(name: "A", slides: [Slide(lines: ["Old"])])]))
        try store.save(Show(name: "Amazing Grace", groups: [SlideGroup(name: "A", slides: [Slide(lines: ["Hymn"])])]))
        let controller = ShowController.bootstrap(store: store)
        #expect(controller.show.name == "Hold")
        #expect(store.loadAll().contains(where: { $0.name == "Talk" }))
        #expect(!store.loadAll().contains(where: { $0.name == "Sunday Morning" }))
        #expect(controller.playlist.name == "Program")
    }

    @Test @MainActor
    func attach_replacesLegacyChurchDemoLibrary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        let sunday = Show(name: "Sunday Morning", groups: [SlideGroup(name: "A", slides: [Slide(lines: ["Old"])])])
        let hymn = Show(name: "Amazing Grace", groups: [SlideGroup(name: "A", slides: [Slide(lines: ["Hymn"])])])
        let bundle = try ProjectBundle.create(at: url, name: "Old Demo", seed: sunday)
        try bundle.libraryStore.save(hymn)
        let session = AppSession(preferenceStore: PreferenceStore.temporary(), shiftHeld: true)
        try session.attach(bundle: try ProjectBundle.open(at: url))
        #expect(session.controller.libraryShows.contains(where: { $0.name == "Hold" }))
        #expect(session.controller.libraryShows.contains(where: { $0.name == "Talk" }))
        #expect(!session.controller.libraryShows.contains(where: { $0.name == "Sunday Morning" }))
        #expect(session.controller.playlist.name == "Program")
        #expect(session.controller.scenes.scenes.map(\.name).contains("Camera"))
    }

    @Test @MainActor
    func session_createOpenRemembersRecent() throws {
        let prefs = PreferenceStore.temporary()
        let session = AppSession(preferenceStore: prefs, shiftHeld: true)
        #expect(session.phase == .startMenu)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        try session.createProject(name: "Youth", at: url)
        #expect(session.phase == .desk)
        #expect(session.controller.audioIO.isRunning == false)
        #expect(session.preferences.recent.contains(where: { $0.name == "Youth" }))
        session.closeToStartMenu()
        #expect(session.phase == .startMenu)
        try session.openProject(at: url)
        #expect(session.controller.show.allSlides.isEmpty == false)
    }

    @Test @MainActor
    func workspaceState_roundTripOnController() {
        let controller = TestSupport.sampleController()
        controller.operatorMode = .reflow
        controller.isAudienceOutputOn = false
        controller.selectedScreenID = "screen-2"
        let state = controller.captureWorkspaceState()
        #expect(state.activeModule == .REFLOW)
        #expect(state.preview.audienceOutputEnabled == false)
        let other = TestSupport.sampleController()
        other.applyWorkspaceState(state)
        #expect(other.operatorMode == .reflow)
        #expect(other.isAudienceOutputOn == false)
        #expect(other.selectedScreenID == "screen-2")
    }

    @Test
    func importAsset_recordsRelativePathOnReplay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).proshow")
        var bundle = try ProjectBundle.create(at: url, name: "Assets")
        let png = try TestSupport.writePNGFixture(in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let dest = try bundle.embedAsset(from: png)
        let relative = bundle.relativePath(for: dest)
        try bundle.appendWAL(.importAsset(relativePath: relative))
        let opened = try ProjectBundle.open(at: url)
        #expect(opened.manifest.importedAssets.contains(relative))
        #expect(FileManager.default.fileExists(atPath: opened.resolveAssetURL(relative).path))
    }

    @Test
    func projectNaming_prefersBundleTitleWhenManifestIsUntitledProgram() {
        let root = URL(fileURLWithPath: "/tmp/My Sunday Service.proshow")
        #expect(ProShowProjectNaming.resolvedDisplayName(manifestName: "Untitled Program", bundleRoot: root) == "My Sunday Service")
    }

    @Test
    func projectNaming_syncManifestFromBundleFilename() {
        var manifest = ProShowProject(name: "Untitled Program")
        let root = URL(fileURLWithPath: "/Volumes/Shows/Easter 2026.proshow")
        let changed = ProShowProjectNaming.syncManifestNameWithBundle(&manifest, bundleRoot: root)
        #expect(changed)
        #expect(manifest.name == "Easter 2026")
    }

    @Test
    func projectNaming_keepsCustomManifestTitle() {
        var manifest = ProShowProject(name: "Broadcast Master")
        let root = URL(fileURLWithPath: "/tmp/RenamedOnDisk.proshow")
        let changed = ProShowProjectNaming.syncManifestNameWithBundle(&manifest, bundleRoot: root)
        #expect(!changed)
        #expect(manifest.name == "Broadcast Master")
    }
}
