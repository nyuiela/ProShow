import Foundation

extension Notification.Name {
    static let proShowProjectSaveStateChanged = Notification.Name("proshow.project-save-state-changed")
    static let proShowControlOpenProject = Notification.Name("proshow.control.open-project")
    static let proShowControlCloseProject = Notification.Name("proshow.control.close-project")
}

/// On-disk `.proshow` package: manifest, workspace state, libraries, playlists, assets, WAL.
struct ProjectBundle: Equatable, Sendable {
    var root: URL
    var manifest: ProShowProject
    var state: ProShowWorkspaceState

    var projectURL: URL { root.appendingPathComponent("project.json") }
    var stateURL: URL { root.appendingPathComponent("state.json") }
    var journalURL: URL { root.appendingPathComponent("journal.wal") }
    var librariesURL: URL { root.appendingPathComponent("Libraries", isDirectory: true) }
    var playlistsURL: URL { root.appendingPathComponent("Playlists", isDirectory: true) }
    var assetsURL: URL { root.appendingPathComponent("Assets", isDirectory: true) }
    var imagesURL: URL { assetsURL.appendingPathComponent("Images", isDirectory: true) }
    var videosURL: URL { assetsURL.appendingPathComponent("Videos", isDirectory: true) }
    var mediaURL: URL { assetsURL.appendingPathComponent("Media", isDirectory: true) }
    var audioURL: URL { assetsURL.appendingPathComponent("Audio", isDirectory: true) }
    var transcodedURL: URL { root.appendingPathComponent("Transcoded", isDirectory: true) }
    var thumbnailsURL: URL { transcodedURL.appendingPathComponent("Thumbnails", isDirectory: true) }
    var waveformsURL: URL { transcodedURL.appendingPathComponent("Waveforms", isDirectory: true) }

    var libraryStore: LibraryStore { LibraryStore(root: librariesURL, fileExtension: "prolib") }

    static func isBundle(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path)
    }

    static func create(at url: URL, name: String, seed: Show? = nil, playlist: Playlist? = nil) throws -> ProjectBundle {
        try prepareTree(at: url)
        let now = Date()
        var settings = ProjectSettings.default
        settings.name = name
        var manifest = ProShowProject(name: name, createdAt: now, updatedAt: now, settings: settings, studio: DefaultSeedData.emptyStudioManifest())
        var state = ProShowWorkspaceState.default
        if let seed {
            manifest.activePresentationId = seed.id
        }
        if let playlist {
            manifest.activePlaylistId = playlist.id
            state.sidebar.selectedPlaylistId = playlist.id.uuidString
            state.sidebar.selectedLibraryId = DefaultSeedData.defaultContentLibraryID.uuidString
        }
        let bundle = ProjectBundle(root: url, manifest: manifest, state: state)
        try bundle.writeManifest()
        try bundle.writeState()
        if let seed {
            try bundle.libraryStore.save(seed)
        }
        if let playlist {
            try bundle.savePlaylist(playlist)
        }
        return bundle
    }

    static func open(at url: URL) throws -> ProjectBundle {
        guard isBundle(at: url) else {
            throw ProjectStoreError.notAProject
        }
        try prepareTree(at: url)
        let manifest = try ProjectJSON.decoder.decode(ProShowProject.self, from: Data(contentsOf: url.appendingPathComponent("project.json")))
        let stateData = try? Data(contentsOf: url.appendingPathComponent("state.json"))
        let state = stateData.flatMap { try? ProjectJSON.decoder.decode(ProShowWorkspaceState.self, from: $0) } ?? .default
        var bundle = ProjectBundle(root: url, manifest: manifest, state: state)
        try bundle.replayJournalIfNeeded()
        return bundle
    }

    func writeAtomic(data: Data, to url: URL) throws {
        try AtomicPersistenceEngine.writeData(data, to: url)
    }

    func writeManifest() throws {
        try writeAtomic(data: ProjectJSON.encoder.encode(manifest), to: projectURL)
    }

    func writeState() throws {
        try writeAtomic(data: ProjectJSON.encoder.encode(state), to: stateURL)
    }

    func relativePath(for url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.lastPathComponent
    }

    func resolveAssetURL(_ stored: String) -> URL {
        if stored.hasPrefix("/") {
            return URL(fileURLWithPath: stored)
        }
        return root.appendingPathComponent(stored)
    }

    func savePlaylist(_ playlist: Playlist) throws {
        try FileManager.default.createDirectory(at: playlistsURL, withIntermediateDirectories: true)
        let url = playlistsURL.appendingPathComponent("\(playlist.id.uuidString).prolist")
        try AtomicPersistenceEngine.writeData(ProjectJSON.encoder.encode(playlist), to: url)
    }

    func replacePlaylists(with playlists: [Playlist]) throws {
        if let files = try? FileManager.default.contentsOfDirectory(at: playlistsURL, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "prolist" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        for playlist in playlists {
            try savePlaylist(playlist)
        }
    }

    func loadPlaylists() -> [Playlist] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: playlistsURL, includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "prolist" else { return nil }
            return try? ProjectJSON.decoder.decode(Playlist.self, from: Data(contentsOf: url))
        }
    }

    mutating func appendWAL(_ operation: WALOperation) throws {
        let journal = WALJournal(url: journalURL)
        try journal.append(operation)
    }

    func hasUncommittedJournal() -> Bool {
        FileManager.default.fileExists(atPath: journalURL.path)
    }

    mutating func replayJournalIfNeeded() throws {
        guard hasUncommittedJournal() else { return }
        let operations = try WALJournal(url: journalURL).readAll()
        for operation in operations {
            try apply(operation)
        }
        try commit()
    }

    mutating func apply(_ operation: WALOperation) throws {
        switch operation {
        case .upsertLibrary(let show):
            try libraryStore.save(show)
            manifest.activePresentationId = show.id
        case .upsertPlaylist(let playlist):
            try savePlaylist(playlist)
            manifest.activePlaylistId = playlist.id
        case .updateManifest(let next):
            manifest = next
        case .updateState(let next):
            state = next
        case .importAsset(let relativePath):
            let dest = resolveAssetURL(relativePath)
            if FileManager.default.fileExists(atPath: dest.path),
               !manifest.importedAssets.contains(relativePath) {
                manifest.importedAssets.append(relativePath)
            }
        }
        manifest.updatedAt = Date()
    }

    mutating func commit() throws {
        try writeManifest()
        try writeState()
        try WALJournal(url: journalURL).remove()
    }

    func embedAsset(from url: URL, copy: Bool = true) throws -> URL {
        let inspected = MediaLoader.inspect(url: url)
        let destinationDirectory: URL
        switch inspected {
        case .image: destinationDirectory = imagesURL
        case .video: destinationDirectory = mediaURL
        case .audio: destinationDirectory = audioURL
        default:
            let ext = url.pathExtension.lowercased()
            destinationDirectory = ["mp3", "wav", "aac", "m4a"].contains(ext) ? audioURL : mediaURL
        }
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let dest = destinationDirectory.appendingPathComponent(uniqueName(for: url.lastPathComponent, in: destinationDirectory))
        if copy {
            try Self.copyImportedFile(from: url, to: dest)
        } else {
            try FileManager.default.createSymbolicLink(at: dest, withDestinationURL: url)
        }
        return dest
    }

    static func copyImportedFile(from url: URL, to dest: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            let data = try Data(contentsOf: url)
            try data.write(to: dest, options: .atomic)
        }
    }

    private func uniqueName(for filename: String, in directory: URL) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        var candidate = filename
        var index = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            index += 1
        }
        return candidate
    }

    private static func prepareTree(at url: URL) throws {
        let folders = [
            url,
            url.appendingPathComponent("Libraries", isDirectory: true),
            url.appendingPathComponent("Libraries/Themes", isDirectory: true),
            url.appendingPathComponent("Playlists", isDirectory: true),
            url.appendingPathComponent("Assets/Images", isDirectory: true),
            url.appendingPathComponent("Assets/Videos", isDirectory: true),
            url.appendingPathComponent("Assets/Media", isDirectory: true),
            url.appendingPathComponent("Assets/Audio", isDirectory: true),
            url.appendingPathComponent("Transcoded/Thumbnails", isDirectory: true),
            url.appendingPathComponent("Transcoded/Waveforms", isDirectory: true),
        ]
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

enum ProjectStoreError: Error, Equatable {
    case notAProject
}

/// Length-prefixed JSON write-ahead log (`journal.wal`).
struct WALJournal: Sendable {
    var url: URL

    func append(_ operation: WALOperation) throws {
        let payload = try ProjectJSON.encoder.encode(operation)
        var record = Data()
        var length = UInt32(payload.count).bigEndian
        record.append(Data(bytes: &length, count: 4))
        record.append(payload)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: record)
        } else {
            try record.write(to: url, options: .atomic)
        }
    }

    func readAll() throws -> [WALOperation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var operations: [WALOperation] = []
        var offset = 0
        while offset + 4 <= data.count {
            let length = UInt32(data[offset]) << 24
                | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8
                | UInt32(data[offset + 3])
            offset += 4
            let end = offset + Int(length)
            guard end <= data.count else { break }
            let payload = data.subdata(in: offset..<end)
            if let operation = try? ProjectJSON.decoder.decode(WALOperation.self, from: payload) {
                operations.append(operation)
            }
            offset = end
        }
        return operations
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

@MainActor
final class AutoSaveEngine {
    var delayNanoseconds: UInt64 = 500_000_000
    private var pending: Task<Void, Never>?
    private(set) var commitCount = 0
    private(set) var pendingChanges = false

    /// True when WAL or pending commit has not been flushed to `project.json` / libraries.
    var isDirty: Bool {
        pendingChanges || bundle.hasUncommittedJournal()
    }
    var pendingShow: Show?
    var pendingState: ProShowWorkspaceState?
    var pendingPlaylist: Playlist?
    var bundle: ProjectBundle

    init(bundle: ProjectBundle, delayNanoseconds: UInt64 = 500_000_000) {
        self.bundle = bundle
        self.delayNanoseconds = delayNanoseconds
    }

    func record(_ operation: WALOperation) throws {
        try bundle.appendWAL(operation)
        try bundle.apply(operation)
        switch operation {
        case .upsertLibrary(let show):
            if pendingShow?.id == show.id { pendingShow = nil }
        case .upsertPlaylist(let playlist):
            if pendingPlaylist?.id == playlist.id { pendingPlaylist = nil }
        case .updateState:
            pendingState = nil
        case .updateManifest, .importAsset:
            break
        }
        pendingChanges = true
        scheduleCommit()
    }

    func markDirty(show: Show? = nil, state: ProShowWorkspaceState? = nil, playlist: Playlist? = nil) {
        pendingChanges = true
        if let show { pendingShow = show }
        if let state { pendingState = state }
        if let playlist { pendingPlaylist = playlist }
        scheduleCommit()
    }

    func scheduleCommit() {
        pending?.cancel()
        let delay = delayNanoseconds
        pending = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            try? self?.commitToDisk()
        }
    }

    func commitToDisk() throws {
        AtomicPersistenceEngine.flushPendingImmediately()
        guard pendingChanges || bundle.hasUncommittedJournal() else { return }
        // Only flush a snapshot that no later journal write replaced. Replaying
        // the earlier copy put deleted shapes and old source assignments back.
        if let show = pendingShow {
            try bundle.libraryStore.save(show)
            bundle.manifest.activePresentationId = show.id
        }
        if let playlist = pendingPlaylist {
            try bundle.savePlaylist(playlist)
            bundle.manifest.activePlaylistId = playlist.id
        }
        if let state = pendingState {
            bundle.state = state
        }
        bundle.manifest.updatedAt = Date()
        try bundle.commit()
        pendingChanges = false
        pendingShow = nil
        pendingState = nil
        pendingPlaylist = nil
        commitCount += 1
        NotificationCenter.default.post(name: .proShowProjectSaveStateChanged, object: nil)
    }

    func commitNow() throws {
        pending?.cancel()
        pending = nil
        if !pendingChanges && !bundle.hasUncommittedJournal() {
            pendingChanges = true
        }
        try commitToDisk()
    }

    func flushPendingSaves() throws {
        try commitNow()
    }

    /// Synchronous flush for app termination (must run on MainActor).
    func flushToDiskOnQuit() throws {
        pending?.cancel()
        pending = nil
        if !pendingChanges && !bundle.hasUncommittedJournal() {
            return
        }
        if !pendingChanges {
            pendingChanges = true
        }
        try commitToDisk()
    }
}

struct PreferenceStore: Sendable {
    var url: URL

    static func applicationSupport() -> PreferenceStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return PreferenceStore(url: base.appendingPathComponent("ProShow/preferences.json"))
    }

    static func temporary() -> PreferenceStore {
        PreferenceStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("ProShowPrefs-\(UUID().uuidString).json"))
    }

    func load() -> AppLaunchPreferences {
        guard let data = try? Data(contentsOf: url),
              var prefs = try? ProjectJSON.decoder.decode(AppLaunchPreferences.self, from: data)
        else { return .default }
        if prefs.launchPrefsVersion < AppLaunchPreferences.currentLaunchPrefsVersion {
            prefs.recent = []
            prefs.lastProjectPath = nil
            prefs.alwaysOpenLastProject = false
            prefs.launchPrefsVersion = AppLaunchPreferences.currentLaunchPrefsVersion
            try? save(prefs)
        }
        return prefs
    }

    func save(_ preferences: AppLaunchPreferences) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicPersistenceEngine.writeData(ProjectJSON.encoder.encode(preferences), to: url)
    }

    func remember(project: ProShowProject, at url: URL) throws -> AppLaunchPreferences {
        var prefs = load()
        prefs.lastProjectPath = url.path
        let entry = RecentProject(id: project.id, name: project.name, path: url.path, lastOpenedAt: Date())
        prefs.recent.removeAll { $0.path == url.path || $0.id == project.id }
        prefs.recent.insert(entry, at: 0)
        if prefs.recent.count > 12 { prefs.recent = Array(prefs.recent.prefix(12)) }
        try save(prefs)
        return prefs
    }
}

@MainActor
@Observable
final class AppSession {
    enum Phase: Equatable {
        case startMenu
        case desk
    }

    var phase: Phase = .startMenu
    var controller: ShowController
    var preferences: AppLaunchPreferences
    var autosave: AutoSaveEngine?
    var projectURL: URL?
    var isLaunching = false
    var launchError: String?
    let preferenceStore: PreferenceStore

    init(preferenceStore: PreferenceStore = .applicationSupport(), shiftHeld: Bool = false) {
        self.preferenceStore = preferenceStore
        self.preferences = preferenceStore.load()
        self.controller = ShowController.bootstrap()
        switch LaunchPolicy.decide(preferences: preferences, shiftHeld: shiftHeld) {
        case .startMenu:
            phase = .startMenu
        case .open(let url):
            if (try? openProject(at: url)) != nil {
                phase = .desk
            } else {
                phase = .startMenu
            }
        }
    }

    @discardableResult
    func createProject(name: String, at url: URL) throws -> ProjectBundle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileTitle = ProShowProjectNaming.bundleFileTitle(for: url)
        let effectiveName = fileTitle.isEmpty ? (trimmed.isEmpty ? "Untitled Program" : trimmed) : fileTitle
        let show = DefaultSeedData.blankShow(name: effectiveName)
        let hierarchy = DefaultSeedData.defaultLibraryHierarchy()
        let bundle = try ProjectBundle.create(at: url, name: effectiveName, seed: show, playlist: hierarchy.playlist)
        try attach(bundle: bundle)
        return bundle
    }

    func createProjectFromMenu(name: String, at url: URL) {
        beginLaunch {
            _ = try self.createProject(name: name, at: url)
        }
    }

    func openProjectFromMenu(at url: URL) {
        beginLaunch {
            try self.openProject(at: url)
        }
    }

    private func beginLaunch(_ work: @escaping () throws -> Void) {
        guard !isLaunching else { return }
        isLaunching = true
        launchError = nil
        Task { @MainActor in
            await Task.yield()
            do {
                try work()
            } catch {
                launchError = error.localizedDescription
                phase = .startMenu
            }
            isLaunching = false
        }
    }

    private func installSeedAssets(into bundle: ProjectBundle) throws {
        if Thread.isMainThread {
            var captured: Error?
            let lock = DispatchSemaphore(value: 0)
            ProShowQueues.diskIOQueue.async {
                do {
                    _ = try DefaultSeedData.installAssets(into: bundle)
                } catch {
                    captured = error
                }
                lock.signal()
            }
            while lock.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            if let captured { throw captured }
        } else {
            _ = try DefaultSeedData.installAssets(into: bundle)
        }
    }

    func openProject(at url: URL) throws {
        let bundle = try ProjectBundle.open(at: url)
        try attach(bundle: bundle)
    }

    func attach(bundle: ProjectBundle) throws {
        controller.releaseProgramFileAccess()
        var resolved = bundle
        if ProShowProjectNaming.syncManifestNameWithBundle(&resolved.manifest, bundleRoot: resolved.root) {
            try resolved.writeManifest()
        }
        try resolved.replayJournalIfNeeded()
        let store = resolved.libraryStore
        var shows = store.loadAll()
        var playlists = resolved.loadPlaylists()
        let replacedLegacy = DefaultSeedData.isLegacyChurchDemoLibrary(shows)
            || DefaultSeedData.isBundledSeedLibrary(shows)
        if replacedLegacy {
            DefaultSeedData.clearLibrary(store)
            let blank = DefaultSeedData.blankShow(name: resolved.manifest.name)
            try store.save(blank)
            shows = [blank]
            let freshPlaylist = DefaultSeedData.emptyPlaylist()
            try resolved.replacePlaylists(with: [freshPlaylist])
            playlists = [freshPlaylist]
            resolved.manifest.activePresentationId = blank.id
            resolved.manifest.activePlaylistId = freshPlaylist.id
            resolved.manifest.studio = DefaultSeedData.emptyStudioManifest()
            resolved.manifest.updatedAt = Date()
            try resolved.writeManifest()
        }
        let fallbackShow = DefaultSeedData.blankShow(name: resolved.manifest.name)
        let fallbackPlaylist = DefaultSeedData.emptyPlaylist()
        let show = shows.first(where: { $0.id == resolved.manifest.activePresentationId })
            ?? shows.first
            ?? fallbackShow
        let playlist = playlists.first(where: { $0.id == resolved.manifest.activePlaylistId })
            ?? playlists.first
            ?? fallbackPlaylist
        controller = ShowController(show: show, playlist: playlist, store: store, persistOnInit: false)
        autosave = AutoSaveEngine(bundle: resolved)
        projectURL = resolved.root
        preferences = try preferenceStore.remember(project: resolved.manifest, at: resolved.root)
        controller.projectAutosave = autosave
        controller.backstage.applyProject(key: resolved.manifest.id.uuidString)
        controller.playback.projectRoot = resolved.root
        MediaPath.currentProjectRoot = resolved.root
        // Do not treat empty `scenes` as “no studio” — props/macros/messages live in `studio.inspector`
        // and are saved with empty scenes for typical projects.
        let studioForAttach: StudioManifest = {
            if replacedLegacy || DefaultSeedData.isLegacyChurchDemoStudio(resolved.manifest.studio) {
                return DefaultSeedData.emptyStudioManifest()
            }
            return resolved.manifest.studio
        }()
        controller.installStudio(studioForAttach)
        controller.applyWorkspaceState(resolved.state)
        controller.libraryShows = shows.isEmpty ? [show] : shows
        if let libraryUUID = UUID(uuidString: resolved.state.sidebar.selectedLibraryId) {
            controller.selectedContentLibraryID = libraryUUID
        }
        let missingHierarchy = controller.contentLibraries.isEmpty
        controller.ensureLibraryHierarchyLoaded(projectPlaylists: playlists)
        if replacedLegacy {
            controller.mediaCollections = DeskSampleData.emptyMediaCollections()
            controller.libraryFolders = []
            controller.contentLibraries = [DefaultSeedData.defaultContentLibrary(playlistIDs: controller.allPlaylists.map(\.id))]
            controller.selectedContentLibraryID = DefaultSeedData.defaultContentLibraryID
            controller.selectedCollectionID = DeskSampleData.defaultPlaylistID
            controller.importedMedia = []
        }
        controller.syncLibraryItemsPublic()
        if replacedLegacy || missingHierarchy {
            controller.persistLibraryHierarchy()
        }
        controller.hydrateSeedMedia()
        controller.applyProjectSettings(resolved.manifest.settings, persist: false, rescaleFrom: resolved.manifest.settings)
        controller.restoreLinkedProgram()
        var matrix = resolved.manifest.streamMatrix
        matrix.projectId = resolved.manifest.id
        controller.streamMatrix = matrix
        controller.applyActiveStreamMatrix()
        autosave?.delayNanoseconds = UInt64(controller.deviceSettings.document.walFlushSeconds * 1_000_000_000)
        controller.deviceSettings.applyAppearance()
        controller.applyThemeProjectSettings(resolved.manifest.themeSettings)
        controller.reloadThemeLibrary()
        controller.applyTheme(preferences.selectedTheme)
        launchError = nil
        phase = .desk
    }

    func closeToStartMenu() {
        controller.releaseProgramFileAccess()
        controller.shutdownProjectCapture()
        persistWorkspace()
        try? autosave?.commitNow()
        autosave = nil
        projectURL = nil
        controller.projectAutosave = nil
        phase = .startMenu
    }

    var projectDisplayName: String {
        guard let autosave else { return controller.projectDisplayName }
        return ProShowProjectNaming.resolvedDisplayName(
            manifestName: autosave.bundle.manifest.name,
            bundleRoot: autosave.bundle.root
        )
    }

    var projectHasUnsavedChanges: Bool {
        controller.documentState.isDirty || (autosave?.isDirty ?? false)
    }

    @discardableResult
    func saveProject() -> Bool {
        guard phase == .desk, autosave != nil else { return false }
        persistWorkspace()
        do {
            try controller.flushPendingSaves()
            controller.bumpProjectSaveRevision()
            return true
        } catch {
            launchError = error.localizedDescription
            return false
        }
    }

    func flushToDiskOnQuit() {
        guard phase == .desk else { return }
        persistWorkspace()
        try? autosave?.flushToDiskOnQuit()
    }

    func persistWorkspace() {
        guard let autosave else { return }
        controller.rehydrateFromEditor(persist: false)
        var manifest = autosave.bundle.manifest
        manifest.activePresentationId = controller.show.id
        manifest.activePlaylistId = controller.playlist.id
        manifest.studio = controller.studioSnapshot()
        manifest.settings = controller.projectSettings
        controller.streamMatrix.projectId = manifest.id
        manifest.streamMatrix = controller.streamMatrix
        manifest.updatedAt = Date()
        try? autosave.record(.updateManifest(manifest))
        try? autosave.record(.updateState(controller.captureWorkspaceState()))
        try? autosave.record(.upsertLibrary(controller.show))
        for playlist in controller.allPlaylists {
            try? autosave.record(.upsertPlaylist(playlist))
        }
    }
}
