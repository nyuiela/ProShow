import Foundation
import Observation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(CoreMedia)
import CoreMedia
#endif

/// Exclusive highlight for the left workspace capsule (Show, Edit, Map, …).
enum WorkspaceToolbarSelection: String, Equatable, Sendable {
    case show
    case edit
    case rundown
    case map
    case props
    case more
}

enum OperatorMode: String, CaseIterable, Identifiable, Hashable {
    case show, edit, reflow, rundown, bible, widgets, map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .show: "Show"
        case .edit: "Edit"
        case .reflow: "Reflow"
        case .rundown: "Rundown"
        case .bible: "Bible"
        case .widgets: "Widgets"
        case .map: "Map Matrix"
        }
    }
}

enum SlideLayoutMode: String, CaseIterable, Identifiable {
    case grid, list, outline
    var id: String { rawValue }
}

enum MediaSourceID: String, CaseIterable, Identifiable, Codable, Sendable {
    case playlists, libraries, resources, sampleContent, videoInputs, audioInputs

    var id: String { rawValue }

    static let defaultSidebarOrder: [MediaSourceID] = [
        .playlists, .libraries, .resources, .sampleContent, .videoInputs, .audioInputs,
    ]

    var title: String {
        switch self {
        case .playlists: "Playlists"
        case .libraries: "Libraries"
        case .resources: "Resources"
        case .sampleContent: "Sample Content"
        case .videoInputs: "Video Inputs"
        case .audioInputs: "Audio"
        }
    }

    var systemImage: String {
        switch self {
        case .playlists: "list.bullet.rectangle"
        case .libraries: "folder.fill"
        case .resources: "internaldrive"
        case .sampleContent: "square.stack.3d.up.fill"
        case .videoInputs: "video.fill"
        case .audioInputs: "waveform"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "proContent" {
            self = .resources
            return
        }
        guard let value = MediaSourceID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown media source \(raw)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var hasChildCollections: Bool {
        switch self {
        case .playlists, .libraries: true
        default: false
        }
    }
}

/// Live show orchestrator: desk chrome + compositor + search + stream session.
@MainActor
@Observable
final class ShowController {
    private(set) var show: Show
    var playlist: Playlist
    var allPlaylists: [Playlist] = []
    var contentLibraries: [ContentLibrary] = []
    var selectedContentLibraryID: UUID?

    let compositor = CompositorEngine()
    let streaming = StreamingEngine()
    let editors = EditorEngine()
    let scenes = SceneManager()
    let videoInputs = VideoInputEngine()
    let filters = VideoFilterEngine()
    let audioMatrix = AudioMatrixEngine()
    let soundboard = SoundboardStore()
    let isoRecorder = IsoRecorder()
    let chat = LiveChatEngine()
    let virtualCamera = VirtualCameraSink()
    let backstage = ProShowBackstageEngine()
    let meetingBridge = MeetingSdkBridge()
    var chatStream: LiveChatStreamManager?
    var virtualCameraOutput: VirtualCameraOutputService?
    let backstageSignaling = BackstageSignalingEngine()
    let guestWebRTCIngest = BackstageWebRTCIngestEngine()
    let liveKitDesk = LiveKitDeskBridge()
    /// Keeps the program composite running so guests can watch Program while the social stream is off.
    var liveKitGuestReturnActive = false
    let virtualAudioLoopback = VirtualAudioLoopbackService()
    var backstageGuestSourceIndex = 0
    let inspector = ActionInspectorEngine()
    let playback = MediaPlaybackEngine()
    let transportClock = LiveTransportClock()
    let programRenderer = ProgramTextureRenderer()
    let transitionShaders = TransitionShaderEngine()
    let stingerPlayer = StingerPlayer()
    let audioIO = AudioIOEngine()
    let studioAudio = ShowAudioController()
    let store: LibraryStore
    let liveStack = LiveStackState()

    var libraryShows: [Show] = []
    var libraryItems: [LibraryShowItem] = []
    var libraryFolders: [LibraryFolder] = []
    var importedMedia: [MediaBinItem] = []
    var mediaCollections: [MediaCollection] = DeskSampleData.emptyMediaCollections()
    var selectedCollectionID: UUID? = DeskSampleData.defaultPlaylistID
    var mediaFilterQuery: String = ""
    var expandedMediaSources: Set<MediaSourceID> = [.playlists, .libraries]
    var mediaSourceOrder: [MediaSourceID] = MediaSourceID.defaultSidebarOrder
    var slideTransitionSeconds: Double = 0.6
    var slideThumbZoom: Double = 0.45
    var isMediaPlaying: Bool = false
    var mediaAlert: String?
    var selectedScreenID: String = "screen-1"
    /// Runtime title-bar control. Shows the prompt as the right sidebar.
    var showsPromptSidebar: Bool = false
    var videoInputRunning: Bool = false

    var selectedSlideID: SlideID?
    var liveSlideID: SlideID?
    var activeSlideBuildStepIndex: Int = 0
    var liveBuildStartedAt: Date?
    var liveBuildClickTimes: [Int: Double] = [:]
    var isPreviewingBuilds: Bool = false
    var previewBuildStartedAt: Date?
    var isEditorLockedToLive: Bool = true
    var hasSandboxChanges: Bool = false
    var liveBuildChangeTimes: [UUID: Double] = [:]
    var sandboxChangeTimes: [UUID: Double] = [:]
    var propBuildStartedAt: [UUID: Date] = [:]
    var propBuildClearStartedAt: [UUID: Date] = [:]
    var slideLeaveStartedAt: Date?
    var slideLeaveTargetID: SlideID?
    @ObservationIgnored private var isCompletingSlideLeave = false
    @ObservationIgnored private var sandboxBaseline: [UUID: CanvasObject] = [:]
    var isAudienceCleared: Bool = false
    /// Selection when the layers panel drives the program canvas outside the editor.
    var compositionPanelSelectedIDs: Set<UUID> = []
    /// When set, `RootView` presents a destructive-action confirmation dialog.
    var deskDestructiveConfirmRequest: DeskDestructiveConfirmAction?

    var operatorMode: OperatorMode = .show
    /// True only while the canvas editor is the visible workspace — not while a
    /// presentation session is kept mounted behind Show / Map.
    var isCanvasEditorPresented: Bool {
        editors.isOpen && (operatorMode == .edit || editors.kind != .presentation)
    }
    var slideLayoutMode: SlideLayoutMode = .grid
    var selectedTheme: String = "Default"
    var selectedMediaSource: MediaSourceID = .playlists
    var selectedPlaylistItemTitle: String
    var libraryQuery: String = ""
    var isSearchOpen: Bool = false
    var isTextInspectorOpen: Bool = false
    var isAudienceOutputOn: Bool = true
    var isStageOutputOn: Bool = true
    var isStreamOutputOn: Bool = false
    var isMultiViewerOn: Bool = false
    var reflowBuffer: String = ""
    var bibleQuery: String = ""
    var searchIndex = SearchIndex()
    var workspaceLayout: ProShowWorkspaceState = .default
    var draggingPayload: WorkspaceDragPayload?
    var projectAutosave: AutoSaveEngine?
    var documentState = ShowDocumentStateEngine()
    var slideClipboard: [Slide] = []
    var slideStyleClipboard: SlideTextStyle?
    var mediaClipboard: [MediaBinItem] = []
    var selectedMediaItemID: UUID?
    var isMediaInspectorOpen: Bool = false
    var projectSettings: ProjectSettings = .default
    var isProjectSettingsOpen: Bool = false
    var streamMatrix = ProjectStreamMatrix()
    let deviceSettings: SettingsStore
    var stageDocument: EditorDocument?
    var masterLayers: [MasterLayer] = MasterLayer.defaults
    var soloedProgramLayer: RenderLayer?
    var addShotLayerIndex: Int = 0
    var isAddShotOpen: Bool = false
    var addShotPurpose: AddShotPurpose = .addToLayer
    /// When set, the next Add Shot confirmation replaces this shot instead of appending.
    var addShotReplaceTarget: (shotID: UUID, layerIndex: Int)?
    var customSolidColors: [SolidColorSwatch] = []
    var placeholderBindings: [String: PlaceholderBinding] = [:]
    var placeholderMatrix = PlaceholderMatrixEngine()
    var placeholderRoutes: [PlaceholderRoute] = []
    var textFields: [ShowTextField] = []
    var liveQuotes = LiveQuoteEngine()
    /// Optional hook when props start, enter, or leave (e.g. custom quote prefetch).
    @ObservationIgnored var onPropLifecycle: ((UUID, PropLifecyclePhase, [CanvasObject]) -> Void)?
    /// Bumps when `liveQuotes` mutates so output surfaces refresh `dynamicText` (nested engine is not always tracked).
    private(set) var liveQuotePresentationStamp: UInt64 = 0
    /// Latest single-pass dynamic text + revision for program outputs.
    var latestProgramRenderSnapshot: ProgramRenderSnapshot?
    /// Bumps when `FrameRevisionClock` advances (SwiftUI monitor `.id` + invalidation).
    var programFrameRevisionStamp: UInt64 = 0
    /// Bumps when project save/dirty state changes so desk chrome can refresh the ⚪ indicator.
    private(set) var projectSaveRevision: UInt64 = 0
    @ObservationIgnored var programFrame: Int = 0
    @ObservationIgnored private var programClock: Timer?
    @ObservationIgnored private var programClockIntervalActive: TimeInterval?
    @ObservationIgnored private var lastRecordEncodeSubmitAt = Date.distantPast
    @ObservationIgnored var lastLiveQuoteRefreshAt = Date.distantPast
    @ObservationIgnored var lastMarketTickerFeedAt = Date.distantPast
    @ObservationIgnored var liveQuoteRefreshMinInterval: TimeInterval = 0.5
    @ObservationIgnored private var programClockIdleTicks = 0
    @ObservationIgnored private var lastProgramMutationAt = Date.distantPast
    @ObservationIgnored private var programOutputInFlight = false
    @ObservationIgnored private var lastLiveHoldFramePublishAt = Date.distantPast
    /// Owned snapshot for CFR hold duplicates when composite skips a tick. The buffer lives in `LastPublishedStreamFrame`.
    #if os(macOS)
    @ObservationIgnored var streamCapturePrivacyEngaged = false
    @ObservationIgnored var displayCaptureExclusionRefreshPending = false
    #endif
    #if canImport(CoreVideo)
    @ObservationIgnored private var pendingProgramOutput: ProgramOutputWorkItem?
    #endif
    @ObservationIgnored private var isAdvancingProgram = false
    @ObservationIgnored private var firedCountdownLinks: Set<String> = []
    var isProgramMonitorPaused = false
    var hasMountedMapWorkspace = false
    var hasMountedRundownWorkspace = false
    var lastPreFlight: PreFlightReport?
    var isPreFlightPresented = false
    var preFlightIntent: PreFlightIntent = .inspect
    var pendingGoLiveSlideID: SlideID?
    var audioClockSnapshot = AudioClockSnapshot()
    var stageDisplayLayout = StageDisplayLayout.standard
    var stageAlertBanner: String = ""
    var programDocument: ProgramDocumentModel = ProgramDocumentModel()
    /// Security-scoped URL kept alive for the linked `.program` package.
    var programFileAccessURL: URL?
    /// External graph nodes and feeds publish here. Canvas text reads them with `{graph:key}`.
    var dataLinkGraph: [String: String] = [:]
    var programDocumentURL: URL?
    /// Outline item shown in the rundown list and the detached prompt.
    var rundownFocusedBlockIndex: Int = 0 {
        didSet {
            prefetchRundownPageFrames(near: rundownFocusedBlockIndex)
        }
    }
    /// The virtual `.program` playlist item (outline slides in rundown order).
    var isProgramPlaylistItemSelected = false
    let rundownClock = RundownClockEngine()
    var rundownStageSegmentTitle: String?
    var rundownStageCountdownText: String?
    var rundownStageNextCue: String?
    var isGoLiveSetupPresented = false
    var isProvisioningStreams = false
    var broadcastMetadata = BroadcastMetadata.default
    var lastBroadcastError: String?
    @ObservationIgnored private var soloVisibilitySnapshot: (cleared: Set<Int>, audioMuted: Bool)?
    @ObservationIgnored var isPersistingProgramDocument = false
    @ObservationIgnored var armedMarketTickerFeedKeys: Set<String> = []
    var themePacksStorage: [ProShowThemePack] = [ProShowThemePack.builtIn]
    var themeSettingsStorage = ThemeProjectSettings.default

    init(
        show: Show,
        playlist: Playlist,
        store: LibraryStore = .applicationSupport(),
        persistOnInit: Bool = true,
        deviceSettings: SettingsStore = .shared
    ) {
        self.show = show
        self.playlist = playlist
        self.store = store
        self.deviceSettings = deviceSettings
        self.selectedSlideID = show.allSlides.first?.id
        self.selectedPlaylistItemTitle = show.name
        if persistOnInit {
            try? store.save(show)
        }
        compositor.replaceOutputScreens(ScreenCatalog.availableScreens())
        libraryShows = store.loadAll()
        if libraryShows.isEmpty { libraryShows = [show] }
        syncLibraryItems()
        rebuildSearchIndex()
        editors.onDocumentsChanged = { [weak self] in
            self?.handleEditorDocumentsChanged()
        }
        inspector.attachPlayback(playback)
        transportClock.attach(playback: playback)
        studioAudio.attach(matrix: audioMatrix, io: audioIO, playback: playback)
        videoInputs.ingest.onCaptureAudio = { role, samples, rate in
            ProgramStreamAudioGates.enqueueCapture(role: role, mono: samples, sampleRate: rate)
        }
        videoInputs.ingest.onCaptureAudioPeak = { [weak self] role, db in
            Task { @MainActor in
                self?.audioIO.injectPeak(role: role, db: db)
            }
        }
        installStudio(DefaultSeedData.emptyStudioManifest())
        restoreMediaLibrary()
        ensureLibraryHierarchyLoaded(projectPlaylists: [])
        syncThemeCatalog()
        applyProjectSettings(.default, persist: false, rescaleFrom: .default)
        applyLocalPreviewRenderQuality()
        videoInputs.ingest.configureOutput(
            width: projectSettings.resolution.width,
            height: projectSettings.resolution.height,
            fps: projectSettings.frameRate.encoderFPS,
            captureAboveOutput: projectSettings.captureAboveOutput
        )
        MultiDeviceIngestManager.shared.attach(ingest: videoInputs.ingest)
        videoInputs.ingest.placeholderFrameNotifier = { [weak self] sourceKey, hasSignal in
            Task { @MainActor in
                guard let self else { return }
                for placeholder in self.placeholderMatrix.placeholders {
                    if placeholder.primarySourceId == sourceKey || placeholder.failoverSourceId == sourceKey {
                        self.placeholderMatrix.noteFrame(id: placeholder.id, hasSignal: hasSignal)
                    }
                }
            }
        }
        liveQuotes.onQuotesUpdated = { [weak self] in
            guard let self else { return }
            liveQuotePresentationStamp &+= 1
            syncMarketTickerFromLiveQuotes()
            _ = prepareAtomicProgramTick(now: Date())
            if streaming.isLive || isoRecorder.isRecording || wantsEncodedPreview {
                noteProgramMutation()
            }
            evaluateProgramClockState()
        }
        configureRundownEngine()
        loadProgramDocument(programDocument)
        configureOutputBusSubscriptions()
        configureVideoFrameInvalidation()
        configureDocumentStateSubscriptions()
        bootstrapBackstageServices()
    }

    private func configureDocumentStateSubscriptions() {
        NotificationCenter.default.addObserver(
            forName: .proShowProjectSaveStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            documentState.markCleanAfterSuccessfulSave()
            bumpProjectSaveRevision()
        }
    }

    func syncMarketTickerFromLiveQuotes() {
        #if os(macOS)
        LiveQuoteTickerBridge.sync(
            quotes: liveQuotes.quotes,
            canvasObjects: liveCanvasObjects()
        )
        #endif
    }

    static func loadSample() -> ShowController {
        bootstrap()
    }

    static func bootstrap(store: LibraryStore = .applicationSupport()) -> ShowController {
        var loaded = store.loadAll()
        if DefaultSeedData.isBundledSeedLibrary(loaded) || DefaultSeedData.isLegacyChurchDemoLibrary(loaded) {
            DefaultSeedData.clearLibrary(store)
            loaded = []
        }
        if !loaded.isEmpty {
            let playlist = Playlist(
                name: "Library",
                items: loaded.map { PlaylistItem(kind: .show, title: $0.name, showID: $0.id) }
            )
            return ShowController(show: loaded[0], playlist: playlist, store: store, persistOnInit: false)
        }
        let show = DefaultSeedData.blankShow()
        let hierarchy = DefaultSeedData.defaultLibraryHierarchy()
        let controller = ShowController(show: show, playlist: hierarchy.playlist, store: store, persistOnInit: false)
        controller.allPlaylists = [hierarchy.playlist]
        controller.contentLibraries = [hierarchy.library]
        controller.selectedContentLibraryID = hierarchy.library.id
        return controller
    }

    func enableLiveIO() {
        videoInputs.hardwareEnabled = true
        audioIO.hardwareEnabled = true
        videoInputs.refreshDevices()
        reconcileMasterLayerShots()
        compositor.syncVideoInputs(from: videoInputs)
        if streaming.transport == nil {
            streaming.transport = RTMPStreamTransport()
        }
        syncNDIProgramOutput()
        bindUnassignedProgramCameras()
    }

    func syncNDIProgramOutput() {
        let settings = deviceSettings.document
        let screenWantsNDI = settings.screens.contains { $0.isEnabled && $0.targetType == .ndiOutput }
        let enabled = screenWantsNDI || stageDisplayLayout.ndiOutputEnabled
        NDIProgramSender.shared.sync(enabled: enabled, name: settings.ndiOutputName)
    }

    /// Remove duplicate live-input shots created before upsert dedupe (same camera/display identity).
    func reconcileMasterLayerShots() {
        for index in masterLayers.indices {
            _ = dedupeLiveShots(onLayer: index)
        }
    }

    var selectedSlide: Slide? {
        guard let selectedSlideID else { return nil }
        return show.slide(id: selectedSlideID)
    }

    var liveSlide: Slide? {
        guard isAudienceOutputOn, !isAudienceCleared else { return nil }
        guard let liveSlideID else { return nil }
        return show.slide(id: liveSlideID)
    }

    var nextSlide: Slide? {
        let slides = show.allSlides
        guard let liveIndex, liveIndex + 1 < slides.count else { return nil }
        return slides[liveIndex + 1]
    }

    /// Edit monitor. A selected cue that is not already on air wins; otherwise the next `.program` outline slide.
    var operatorPreviewSlide: Slide? {
        let chosen: Slide?
        if let selected = selectedSlide, selected.id != liveSlideID {
            chosen = selected
        } else {
            chosen = nextProgramOutlineSlide
        }
        guard let chosen else { return nil }
        return preparedOperatorPreviewSlide(chosen)
    }

    /// Next outline cue after whatever is on air. Independent of which presentation is open for editing.
    var nextProgramOutlineSlide: Slide? {
        let document = rundownClock.program ?? programDocument
        let slides = ProgramOutlinePresentation.makeShow(from: document).allSlides
        guard !slides.isEmpty else { return nil }
        if let liveSlideID, let index = slides.firstIndex(where: { $0.id == liveSlideID }) {
            let nextIndex = slides.index(after: index)
            guard slides.indices.contains(nextIndex) else { return nil }
            return slides[nextIndex]
        }
        return slides.first { $0.id != liveSlideID }
    }

    private func preparedOperatorPreviewSlide(_ slide: Slide) -> Slide {
        let document = rundownClock.program ?? programDocument
        guard document.programSlides.contains(where: { $0.id == slide.id }) else { return slide }
        return ProgramOutlinePresentation.airPrepareSlide(slide, in: document)
    }

    /// File audio for the preview cue. Stays off the program mix and the encoder.
    func operatorPreviewAudioURL() -> URL? {
        guard let slide = operatorPreviewSlide else { return nil }
        guard let media = resolvedAssociatedMedia(for: slide),
              !media.clearsLayer,
              !media.isImage,
              !media.isAudioMuted
        else { return nil }
        return media.resolvedFileURL(projectRoot: mediaProjectRoot)
    }

    func followOperatorPreviewAudio(_ active: Bool) {
        if active {
            ProgramAudioMonitorBridge.shared.setActive(false)
            PreviewCueMonitor.shared.play(url: operatorPreviewAudioURL())
        } else {
            PreviewCueMonitor.shared.stop()
        }
    }

    var selectedIndex: Int? {
        guard let selectedSlideID else { return nil }
        return show.indexOfSlide(id: selectedSlideID)
    }

    var liveIndex: Int? {
        guard let liveSlideID else { return nil }
        return show.indexOfSlide(id: liveSlideID)
    }

    var isBroadcasting: Bool {
        liveSlideID != nil && isAudienceOutputOn && !isAudienceCleared
    }

    var isMediaLayerCleared: Bool {
        compositor.stack.isCleared(.media)
    }

    var isDefaultLayerCleared: Bool {
        compositor.stack.isCleared(.slide)
            && compositor.stack.isCleared(.media)
            && compositor.stack.isCleared(.videoInput)
    }

    var statusAlerts: [DeskStatusAlert] {
        var alerts: [DeskStatusAlert] = []
        if let mediaAlert {
            alerts.append(DeskStatusAlert(title: "Media", detail: mediaAlert))
        }
        if streaming.state == .failed, let error = streaming.lastError {
            alerts.append(DeskStatusAlert(title: "Stream", detail: ProShowCopy.error(for: error)))
        }
        if streaming.isLive {
            alerts.append(DeskStatusAlert(title: "Stream", detail: streaming.statusLine))
        }
        if let report = lastPreFlight {
            for finding in report.findings where finding.severity == .fail {
                alerts.append(DeskStatusAlert(title: finding.title, detail: finding.detail))
            }
        }
        return alerts
    }

    var searchHits: [SearchHit] {
        searchIndex.query(libraryQuery)
    }

    var bibleHits: [BiblePassage] {
        guard BibleEngine.hasTranslationPackage else { return [] }
        return BibleEngine.lookup(bibleQuery, passages: BibleEngine.installedPassages)
    }

    var liveStageDocument: EditorDocument {
        if editors.kind == .stage, let selected = editors.selectedDocument {
            var preview = selected
            StageThemeBridge.applyRuntimeLayout(to: &preview, layout: stageDisplayLayout)
            return preview
        }
        return StageThemeBridge.resolvedLiveDocument(
            variant: activeStageVariant(),
            stored: stageDocument,
            layout: stageDisplayLayout,
            fallbackLook: compositor.stack.stageLook
        )
    }

    var allowsSampleReload: Bool { projectAutosave == nil }

    var indexedCues: [IndexedCue] {
        var result: [IndexedCue] = []
        var number = 0
        for group in show.groups {
            for (offset, slide) in group.slides.enumerated() {
                number += 1
                result.append(IndexedCue(number: number, group: group, slide: slide, isGroupLead: offset == 0))
            }
        }
        return result
    }

    var programOutputEnabled: Bool {
        isAudienceOutputOn && !isAudienceCleared
    }

    func select(_ slideID: SlideID) {
        selectedSlideID = slideID
        sanitizeSlideOnDisk(id: slideID)
        if let slide = show.slide(id: slideID) {
            prepareSlidePreviewCapture(for: slide)
        }
        if isCanvasEditorPresented {
            editors.syncPresentation(from: show, selectedSlideID: slideID)
        }
    }

    @discardableResult
    func runPreFlight(intent: PreFlightIntent, handshake: StreamHandshakeProbing? = nil) -> PreFlightReport {
        preFlightIntent = intent
        let report = PreFlightEngine.scan(controller: self, intent: intent, handshake: handshake)
        lastPreFlight = report
        return report
    }

    func requestGoLive(slideID: SlideID? = nil) {
        pendingGoLiveSlideID = slideID
        let report = runPreFlight(intent: .goLive, handshake: nil)
        if report.canProceed {
            goLive(slideID: slideID)
            return
        }
        isPreFlightPresented = true
    }

    func requestStartStream() {
        let report = runPreFlight(intent: .startStream, handshake: TCPStreamHandshakeProbe())
        if report.canProceed {
            Task { _ = await startBroadcastForArmedAccounts() }
            return
        }
        isPreFlightPresented = true
    }

    func confirmPreFlight() {
        guard let lastPreFlight, lastPreFlight.canProceed else { return }
        isPreFlightPresented = false
        switch preFlightIntent {
        case .goLive:
            goLive(slideID: pendingGoLiveSlideID)
        case .startStream:
            Task { _ = await startBroadcastForArmedAccounts() }
        case .inspect:
            break
        }
    }

    func openPreFlight() {
        dismissDeskWorkspaceSheets()
        _ = runPreFlight(intent: .inspect, handshake: nil)
        isPreFlightPresented = true
    }

    func goLive(slideID: SlideID? = nil) {
        if editors.kind == .presentation {
            rehydrateFromEditor(persist: true, force: true)
        }
        let target = slideID ?? selectedSlideID
        guard let target, var slide = show.slide(id: target),
              let index = show.indexOfSlide(id: target)
        else { return }
        if show.id == ProgramOutlinePresentation.showID {
            let doc = rundownClock.program ?? programDocument
            slide = ProgramOutlinePresentation.airPrepareSlide(slide, in: doc)
            if ProgramOutlinePresentation.pageURL(in: slide) != nil {
                takeProgramOutlineSlideLive(slideID: target)
                return
            }
            if compositor.stack.media?.id == RundownPageMedia.id {
                compositor.dismissRundownPage()
                ProgramPageRaster.shared.load(nil)
            }
        }
        if !isCompletingSlideLeave {
            if let liveSlideID, liveSlideID == target, slideLeaveStartedAt != nil {
                cancelSlideLeave()
                resetLiveBuildClock()
                refreshLiveStack()
                return
            }
            if slideLeaveStartedAt != nil {
                slideLeaveTargetID = target
                return
            }
            if shouldPlayOutgoingBuildOut(to: target) {
                beginSlideLeave(to: target)
                return
            }
        }
        isCompletingSlideLeave = false
        cancelSlideLeave()
        liveSlideID = target
        selectedSlideID = target
        isAudienceCleared = false
        isAudienceOutputOn = true
        let autoClearing = inspector.props.compactMap { prop -> UUID? in
            guard prop.isActive, case .onNextSlide = prop.autoClearMode else { return nil }
            return prop.id
        }
        inspector.applyAutoClearOnNextSlide()
        for id in autoClearing {
            _ = beginPropExit(id: id)
        }
        syncActivePropsToCompositor()
        let incomingMedia = resolvedAssociatedMedia(for: slide)
        let decision = MediaActionEvaluator.evaluate(
            current: liveMediaWithHoldState(),
            incoming: incomingMedia,
            projectRoot: mediaProjectRoot,
            layerLocked: compositor.isLayerLocked(.media)
        )
        compositor.captureOutgoingForTransition()
        if compositor.isLayerLocked(.slide) {
            compositor.triggerCue(
                OutputCue(id: slide.id, presentationId: show.id, slideIndex: index, layers: CueLayers())
            )
        } else {
            compositor.triggerCue(makeCue(for: slide, index: index))
        }
        applyMediaLayerDecision(decision)
        if !compositor.isLayerLocked(.videoInput) {
            ensureSlideLiveInputsOnMainLayer(slide)
            compositor.restore(.videoInput)
        }
        executeLinkedSlideMacros(slide)
        beginBoundTransition(presetID: slide.transition, workspace: .slideInspector, incomingSceneID: scenes.activeSceneID)
        resetLiveBuildClock()
        refreshLiveStack()
        attachEditorToLiveIfNeeded()
        evaluateProgramClockState()
        if decision == .clear {
            applyProgramAudioMute()
        } else {
            armProgramAudio()
        }
    }

    func resetLiveBuildClock(at date: Date = Date()) {
        cancelSlideLeave()
        liveBuildStartedAt = date
        activeSlideBuildStepIndex = 0
        liveBuildClickTimes = [:]
        liveBuildChangeTimes = [:]
        sandboxChangeTimes = [:]
        isPreviewingBuilds = false
        previewBuildStartedAt = nil
        firedCountdownLinks = []
        transportClock.bind(slideID: liveSlideID, liveBuildStartedAt: date, programFrame: programFrame)
        applyCountdownBuildLinks(now: date)
        if let liveSlideID {
            emitSlideLifecycle(.enter(liveSlideID), at: date)
        }
    }

    func shouldPlayOutgoingBuildOut(to target: SlideID) -> Bool {
        guard let liveSlideID, liveSlideID != target else { return false }
        guard !compositor.isLayerLocked(.slide) else { return false }
        return BuildAnimationEngine.authoredBuildOutDuration(in: liveBuildObjects) > 0.02
    }

    func beginSlideLeave(to target: SlideID, at date: Date = Date()) {
        slideLeaveStartedAt = date
        slideLeaveTargetID = target
        liveBuildStartedAt = date
        liveBuildClickTimes = [:]
        liveBuildChangeTimes = [:]
        applyCountdownBuildLinks(now: date)
        evaluateProgramClockState()
        refreshLiveStack()
    }

    func cancelSlideLeave() {
        slideLeaveStartedAt = nil
        slideLeaveTargetID = nil
    }

    func completeSlideLeaveIfNeeded(now: Date = Date()) {
        guard let started = slideLeaveStartedAt, let target = slideLeaveTargetID else { return }
        let duration = BuildAnimationEngine.authoredBuildOutDuration(in: liveBuildObjects)
        guard now.timeIntervalSince(started) >= duration else { return }
        isCompletingSlideLeave = true
        slideLeaveStartedAt = nil
        slideLeaveTargetID = nil
        goLive(slideID: target)
    }

    var isEditingLiveSlide: Bool {
        guard editors.isOpen, editors.kind == .presentation else { return false }
        let slideID = editors.selectedDocument?.slideID ?? selectedSlideID
        guard let slideID, let liveSlideID, slideID == liveSlideID else { return false }
        return isAudienceOutputOn && !isAudienceCleared
    }

    var isEditingLiveProp: Bool {
        guard editors.kind == .props, let id = editors.selectedDocumentID else { return false }
        if propBuildClearStartedAt[id] != nil { return true }
        return inspector.props.contains { $0.id == id && $0.isActive }
    }

    /// Editor, Map, and program monitors share the audience clock when they show the live slide or the same placeholder/file.
    func editorUsesSharedProgramClock(for document: EditorDocument? = nil) -> Bool {
        guard playback.hasProgramClock else { return false }
        if isEditingLiveSlide { return true }
        let document = document ?? editors.selectedDocument
        if let media = editorWorkspaceMedia(for: document), playback.sharesClock(with: media) {
            return true
        }
        return document?.objects.contains { playback.sharesClock(with: $0) } == true
    }

    func refreshProgramClockBindings() {
        var letters: [String] = []
        if let letter = compositor.stack.media?.placeholderLetter {
            letters.append(letter)
        }
        for placeholder in placeholderMatrix.placeholders {
            guard let mapped = resolvedAssignedSource(forPlaceholder: placeholder.letter) else { continue }
            if playback.sharesClock(with: mapped) {
                letters.append(placeholder.letter)
            }
        }
        playback.adoptPlaceholders(letters)
    }

    var isEditorAttachedToLive: Bool {
        isEditingLiveSlide && isEditorLockedToLive
    }

    var isSandboxEditingLive: Bool {
        isEditingLiveSlide && !isEditorLockedToLive
    }

    var liveMediaSession: LiveMediaSession? {
        guard isEditorAttachedToLive else { return nil }
        return transportClock.activeMediaSession
    }

    /// Editor never keys Layer 3 under a transparent canvas. Checkerboard means
    /// keyed; program video stays on audience and the right-pane monitor.
    func showsEditorProgramMediaPlate(for document: EditorDocument?) -> Bool {
        _ = document
        return false
    }

    func editorWorkspaceMedia(for document: EditorDocument?) -> MediaAction? {
        guard let document, document.kind == .presentation else { return nil }
        let linked: MediaAction?
        if let slideID = document.slideID, let slide = show.slide(id: slideID) {
            linked = resolvedAssociatedMedia(for: slide)
        } else {
            linked = nil
        }
        if isEditingLiveSlide, let program = compositor.stack.media, !program.clearsLayer {
            if let linked, MediaActionEvaluator.isSameAsset(program, linked, projectRoot: mediaProjectRoot) {
                return program
            }
            if mediaPaneSelectionMatches(program) {
                return program
            }
            return linked
        }
        return linked
    }

    func setEditorLockedToLive(_ locked: Bool) {
        if locked, isSandboxEditingLive, hasSandboxChanges {
            applySandboxChanges()
        }
        isEditorLockedToLive = locked
        if locked, isEditingLiveSlide, let slide = liveSlide {
            applyLiveSceneDelta(for: slide)
        }
        if !locked {
            snapshotSandboxBaseline()
        }
    }

    func applySandboxChanges() {
        rehydrateFromEditor(persist: true, force: true)
        let changed = changedSandboxElementIDs()
        recordOnChange(changed, sandbox: false)
        if let slide = liveSlide {
            applyLiveSceneDelta(for: slide)
        }
        hasSandboxChanges = false
        snapshotSandboxBaseline()
    }

    func handleEditorDocumentsChanged() {
        if editors.kind == .theme {
            syncThemePackFromEditor(persist: true)
            noteProgramMutation()
            return
        }
        if editors.kind == .stage {
            syncStagePackFromEditor(persist: true)
            persistLiveStageDocument()
            noteProgramMutation()
            return
        }
        if editors.kind == .props {
            syncPropsFromEditor()
            persistStudio()
            noteProgramMutation()
            return
        }
        rehydrateFromEditor(persist: false)
        applyCountdownBuildLinks()
        if isEditingLiveSlide {
            recordOnChange(changedSandboxElementIDs(), sandbox: false)
            snapshotSandboxBaseline()
            if let slide = liveSlide {
                if show.id == ProgramOutlinePresentation.showID,
                   let page = ProgramOutlinePresentation.pageURL(in: slide) {
                    ProgramPageRaster.shared.load(page)
                }
                applyLiveSceneDelta(for: slide)
            }
        }
        noteProgramMutation()
    }

    func snapshotSandboxBaseline() {
        let objects = editors.selectedDocument?.objects ?? []
        sandboxBaseline = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        if !hasSandboxChanges {
            sandboxChangeTimes = [:]
        }
    }

    func changedSandboxElementIDs() -> Set<UUID> {
        let current = editors.selectedDocument?.objects ?? []
        var ids: Set<UUID> = []
        for object in current {
            if let prior = sandboxBaseline[object.id] {
                if object.text != prior.text
                    || object.bounds != prior.bounds
                    || object.transform != prior.transform
                    || object.fill != prior.fill
                    || object.token != prior.token
                    || object.opacity != prior.opacity {
                    ids.insert(object.id)
                }
            } else {
                ids.insert(object.id)
            }
        }
        return ids
    }

    private func recordOnChange(_ ids: Set<UUID>, sandbox: Bool) {
        guard !ids.isEmpty else { return }
        let origin = liveBuildStartedAt ?? Date()
        let elapsed = max(0, Date().timeIntervalSince(origin))
        if sandbox {
            for id in ids { sandboxChangeTimes[id] = elapsed }
        } else {
            for id in ids { liveBuildChangeTimes[id] = elapsed }
        }
    }

    func attachEditorToLiveIfNeeded() {
        transportClock.bind(
            slideID: liveSlideID,
            liveBuildStartedAt: liveBuildStartedAt,
            programFrame: programFrame
        )
    }

    func openInEditor(slideId: UUID) {
        select(slideId)
        if liveSlideID == slideId {
            isEditorLockedToLive = true
            hasSandboxChanges = false
        }
        setMode(.edit)
        attachEditorToLiveIfNeeded()
        snapshotSandboxBaseline()
    }

    func previewSlideBuilds(at date: Date = Date()) {
        isPreviewingBuilds = true
        previewBuildStartedAt = date
        firedCountdownLinks = []
        applyCountdownBuildLinks(now: date)
    }

    func liveBuildClock() -> BuildClock {
        BuildClock(
            startedAt: liveBuildStartedAt,
            unlockedClickOrder: activeSlideBuildStepIndex,
            clickTimes: liveBuildClickTimes,
            autoplayClicks: false,
            frame: programFrame,
            changeTimes: liveBuildChangeTimes,
            isLeaving: slideLeaveStartedAt != nil
        )
    }

    var editorFollowsLiveBuilds: Bool {
        isEditingLiveSlide || isEditingLiveProp || isPreviewingBuilds
    }

    func editorAnimationMode() -> AnimationEvaluationMode {
        editorFollowsLiveBuilds ? .liveClock : .editorDesign
    }

    func editorBuildPhaseFilter() -> Set<BuildPhase>? {
        if slideLeaveStartedAt != nil { return [.buildOut] }
        guard isEditingLiveProp, !isPreviewingBuilds, let id = editors.selectedDocumentID else { return nil }
        return propBuildClearStartedAt[id] == nil ? [.buildIn, .action] : [.buildOut]
    }

    func editorBuildClock() -> BuildClock {
        if isEditingLiveProp, let id = editors.selectedDocumentID {
            return propBuildClock(id: id)
        }
        if isEditingLiveSlide {
            return liveBuildClock()
        }
        guard isPreviewingBuilds else { return .idle }
        return BuildClock(
            startedAt: previewBuildStartedAt,
            unlockedClickOrder: .max,
            clickTimes: [:],
            autoplayClicks: true,
            frame: programFrame
        )
    }

    func propBuildClock(id: UUID) -> BuildClock {
        BuildClock(
            startedAt: propBuildClearStartedAt[id] ?? propBuildStartedAt[id],
            unlockedClickOrder: .max,
            clickTimes: [:],
            autoplayClicks: true,
            frame: programFrame,
            isLeaving: propBuildClearStartedAt[id] != nil
        )
    }

    /// Props on RTMP must not inherit slide build-out or stale build-out from an old `startedAt`.
    func propEncodePlayback(for canvas: PropCanvas, now: Date) -> BuildPlayback {
        let clock = canvas.buildClock(frame: programFrame)
        if canvas.isClearing {
            return clock.playback(now: now)
        }
        let live = clock.playback(now: now)
        guard live.isArmed else {
            return BuildPlayback.preview(elapsed: 86_400)
        }
        let buildInSpan = BuildAnimationEngine.authoredBuildInDuration(in: canvas.objects)
        if live.elapsed > buildInSpan + 0.05 {
            return BuildPlayback.preview(elapsed: max(live.elapsed, buildInSpan + 1))
        }
        return live
    }

    func beginPropEnter(id: UUID, at date: Date = Date()) {
        propBuildStartedAt[id] = date
        propBuildClearStartedAt[id] = nil
        applyCountdownBuildLinks(now: date)
        emitPropLifecycle(id: id, phase: .enter, at: date)
    }

    @discardableResult
    func beginPropExit(id: UUID, at date: Date = Date()) -> Bool {
        let objects = inspector.props.first(where: { $0.id == id })?.elements ?? []
        let duration = BuildAnimationEngine.authoredBuildOutDuration(in: objects)
        emitPropLifecycle(id: id, phase: .leave, at: date)
        guard duration > 0.02 else {
            finishPropBuild(id: id)
            return false
        }
        propBuildClearStartedAt[id] = date
        applyCountdownBuildLinks(now: date)
        return true
    }

    func applyCountdownBuildLinks(now: Date = Date()) {
        let objects = countdownLinkObjects()
        guard !objects.isEmpty else { return }
        for object in objects where object.kind == .timerCountdown {
            guard let timerID = object.timerID ?? inspector.timers.first?.id else { continue }
            let playback = countdownPlayback(for: object, now: now)
            let resetLink = object.resolvedCountdownResetOn
            let startLink = object.resolvedCountdownStartOn
            if resetLink != .none, isCountdownLinkSatisfied(resetLink, object: object, playback: playback) {
                let key = "\(object.id.uuidString)-reset-\(resetLink.rawValue)"
                if firedCountdownLinks.insert(key).inserted {
                    _ = inspector.resetTimer(id: timerID)
                }
            }
            if startLink != .none, isCountdownLinkSatisfied(startLink, object: object, playback: playback) {
                let key = "\(object.id.uuidString)-start-\(startLink.rawValue)"
                if firedCountdownLinks.insert(key).inserted {
                    applyCountdownStart(timerID: timerID, link: startLink)
                }
            }
        }
    }

    private func applyCountdownStart(timerID: UUID, link: CountdownBuildLink) {
        switch link {
        case .onSlideEnter, .onBuildIn:
            _ = inspector.restartTimer(id: timerID)
        case .onClick, .onAction, .onBuildOut:
            _ = inspector.startTimer(id: timerID)
        case .none:
            break
        }
    }

    private func countdownLinkObjects() -> [CanvasObject] {
        var objects = liveBuildObjects
        if isEditingLiveSlide, editors.kind == .presentation, let document = editors.selectedDocument {
            let editorIDs = Set(document.objects.map(\.id))
            objects.removeAll { editorIDs.contains($0.id) }
            objects.append(contentsOf: document.objects)
        }
        for prop in inspector.props where prop.isActive || propBuildClearStartedAt[prop.id] != nil {
            objects.append(contentsOf: prop.elements)
        }
        if isPreviewingBuilds, editors.kind == .presentation, let document = editors.selectedDocument {
            let previewIDs = Set(document.objects.map(\.id))
            if !objects.contains(where: { previewIDs.contains($0.id) }) {
                objects.append(contentsOf: document.objects)
            }
        }
        return objects
    }

    private func countdownPlayback(for object: CanvasObject, now: Date) -> BuildPlayback {
        if let prop = inspector.props.first(where: { $0.elements.contains(where: { $0.id == object.id }) }) {
            return propBuildClock(id: prop.id).playback(now: now)
        }
        if isPreviewingBuilds {
            return editorBuildClock().playback(now: now)
        }
        return liveBuildClock().playback(now: now)
    }

    private func isCountdownLinkSatisfied(
        _ link: CountdownBuildLink,
        object: CanvasObject,
        playback: BuildPlayback
    ) -> Bool {
        guard playback.isArmed else { return false }
        switch link {
        case .none:
            return false
        case .onSlideEnter:
            return !playback.isLeaving
        case .onClick:
            if object.resolvedBuildSteps.contains(where: {
                $0.trigger.resolved(for: $0.phase) == .onClick && playback.clickTimes[$0.sequenceOrder] != nil
            }) {
                return true
            }
            return !playback.clickTimes.isEmpty
        case .onBuildIn:
            return hasStartedBuildPhase(.buildIn, object: object, playback: playback, implicitIfMissing: true)
        case .onAction:
            return hasStartedBuildPhase(.action, object: object, playback: playback, implicitIfMissing: false)
        case .onBuildOut:
            return hasStartedBuildPhase(.buildOut, object: object, playback: playback, implicitIfMissing: false)
        }
    }

    private func hasStartedBuildPhase(
        _ phase: BuildPhase,
        object: CanvasObject,
        playback: BuildPlayback,
        implicitIfMissing: Bool
    ) -> Bool {
        let steps = object.resolvedBuildSteps.filter { $0.phase == phase }
        if steps.isEmpty {
            return implicitIfMissing
        }
        let starts = BuildAnimationEngine.startTimes(for: object.resolvedBuildSteps, playback: playback)
        return steps.contains { step in
            guard let start = starts[step.id] else { return false }
            return playback.elapsed + 0.0001 >= start
        }
    }

    func finishPropBuild(id: UUID) {
        propBuildStartedAt[id] = nil
        propBuildClearStartedAt[id] = nil
    }

    func finishAllPropBuilds() {
        propBuildStartedAt.removeAll()
        propBuildClearStartedAt.removeAll()
    }

    func reconcilePropBuildClocks(now: Date = Date()) {
        var changed = false
        for prop in inspector.props {
            if prop.isActive {
                if propBuildStartedAt[prop.id] == nil {
                    beginPropEnter(id: prop.id, at: now)
                    changed = true
                }
            } else if propBuildStartedAt[prop.id] != nil, propBuildClearStartedAt[prop.id] == nil {
                _ = beginPropExit(id: prop.id, at: now)
                changed = true
            }
        }
        if changed {
            evaluateProgramClockState()
            syncActivePropsToCompositor()
        }
    }

    func tickPropBuildClears(now: Date = Date()) {
        let expired = propBuildClearStartedAt.compactMap { id, started -> UUID? in
            let objects = inspector.props.first(where: { $0.id == id })?.elements ?? []
            let duration = BuildAnimationEngine.authoredBuildOutDuration(in: objects)
            return now.timeIntervalSince(started) >= duration ? id : nil
        }
        guard !expired.isEmpty else { return }
        for id in expired {
            finishPropBuild(id: id)
        }
        syncActivePropsToCompositor()
        refreshLiveStack()
    }

    var liveBuildObjects: [CanvasObject] {
        guard let liveSlideID, let slide = show.slide(id: liveSlideID) else {
            return compositor.stack.slideCanvas ?? []
        }
        return resolvedCanvasObjects(audienceCanvasForProgram(prepareSlideForProgramCue(slide)))
    }

    func nextPendingOnClickBuild() -> ElementBuildStep? {
        BuildAnimationEngine.pendingOnClickSteps(in: liveBuildObjects)
            .first { $0.sequenceOrder > activeSlideBuildStepIndex }
    }

    func executeBuildStep(_ step: ElementBuildStep, at date: Date = Date()) {
        activeSlideBuildStepIndex = step.sequenceOrder
        let origin = liveBuildStartedAt ?? date
        liveBuildClickTimes[step.sequenceOrder] = max(0, date.timeIntervalSince(origin))
        applyCountdownBuildLinks(now: date)
    }

    func makeCue(for slide: Slide, index: Int) -> OutputCue {
        let cleaned = prepareSlideForProgramCue(sanitizeSlide(slide))
        let canvas = audienceCanvasForProgram(cleaned)
        let mediaOnly = cleaned.isProgramMediaCue
        return OutputCue(
            id: cleaned.id,
            presentationId: show.id,
            slideIndex: index,
            layers: CueLayers(
                slideText: SlideElement.from(slide: cleaned),
                slideCanvas: canvas.isEmpty ? nil : resolvedCanvasObjects(canvas),
                canvasWidth: CanvasConfig.width,
                canvasHeight: CanvasConfig.height,
                slideBackgroundEnabled: mediaOnly ? false : cleaned.paintsOpaqueBackground,
                slideBackgroundHex: cleaned.backgroundHex
            )
        )
    }

    func resolvedCanvasObjects(_ objects: [CanvasObject]) -> [CanvasObject] {
        objects.map { object in
            guard let letter = object.assignedPlaceholderLetter,
                  let mapped = resolvedAssignedSource(forPlaceholder: letter)
            else { return object }
            var next = object
            next.applyAssignedSource(mapped)
            return next
        }
    }

    func advance() {
        if let nextStep = nextPendingOnClickBuild() {
            executeBuildStep(nextStep)
            return
        }
        let slides = show.allSlides
        guard !slides.isEmpty else { return }
        let current = selectedIndex ?? liveIndex ?? -1
        if let next = slides.enumerated().first(where: { $0.offset > current && !$0.element.isDisabled }) {
            goLive(slideID: next.element.id)
        }
    }

    func goPrevious() {
        let slides = show.allSlides
        guard !slides.isEmpty else { return }
        let current = selectedIndex ?? liveIndex ?? 0
        if let prev = slides.enumerated().reversed().first(where: { $0.offset < current && !$0.element.isDisabled }) {
            goLive(slideID: prev.element.id)
        }
    }

    func triggerIndex(_ index: Int) {
        let slides = show.allSlides
        guard slides.indices.contains(index) else { return }
        goLive(slideID: slides[index].id)
    }

    @discardableResult
    func triggerSlide(presentationID: UUID?, index: Int) -> Bool {
        if let presentationID, presentationID != show.id {
            loadPresentation(id: presentationID)
            guard show.id == presentationID else { return false }
        }
        let slides = show.allSlides
        guard slides.indices.contains(index) else { return false }
        triggerIndex(index)
        return true
    }

    func clearAudience() {
        isAudienceCleared = true
        compositor.clear(.slide)
        refreshLiveStack()
    }

    func restoreAudience() {
        isAudienceCleared = false
        isAudienceOutputOn = true
        compositor.restore(.slide)
        if liveSlideID == nil {
            liveSlideID = selectedSlideID
        }
        if let liveSlideID, let slide = show.slide(id: liveSlideID), let index = show.indexOfSlide(id: liveSlideID) {
            compositor.triggerCue(makeCue(for: slide, index: index))
        }
        refreshLiveStack()
    }

    func toggleSearch() {
        isSearchOpen.toggle()
        if !isSearchOpen { libraryQuery = "" }
    }

    func toggleTextInspector() {
        if editors.isOpen {
            editors.inspectorTab = .text
            isTextInspectorOpen = true
        } else {
            setMode(.edit)
            editors.inspectorTab = .text
            isTextInspectorOpen = true
        }
    }

    /// Type shown beside the presentation title. Comes from the presentation’s slides, not the live look.
    var presentationContentType: String {
        let theme = show.allSlides.first?.theme.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !theme.isEmpty { return theme }
        return selectedTheme
    }

    /// Sets the presentation type on every slide in the open presentation. Does not cut the live bus.
    func setPresentationContentType(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, show.id != ProgramOutlinePresentation.showID else { return }
        selectedTheme = trimmed
        let variantID = ThemeVariantRegistry.variant(named: trimmed)?.id
        for groupIndex in show.groups.indices {
            for slideIndex in show.groups[groupIndex].slides.indices {
                show.groups[groupIndex].slides[slideIndex].theme = trimmed
                show.groups[groupIndex].slides[slideIndex].themeVariantID = variantID
            }
        }
        if editors.kind == .presentation {
            editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
        }
        persistCurrentShow()
    }

    func applyTheme(_ name: String) {
        selectedTheme = name
        if let look = ThemeVariantRegistry.audienceLook(forThemeName: name) {
            compositor.setAudienceLook(look)
        } else {
            switch name {
            case "Scripture": compositor.setAudienceLook(.alphaKey)
            case "Lyrics": compositor.setAudienceLook(.slideAndMedia)
            default: compositor.setAudienceLook(.fullStack)
            }
        }
    }

    func setMode(_ mode: OperatorMode) {
        dismissDeskWorkspaceSheets()
        var next = mode
        switch next {
        case .reflow, .widgets:
            next = .show
        default:
            break
        }
        if next == .bible, !BibleEngine.hasTranslationPackage {
            next = .show
        }
        let leavingEdit = operatorMode == .edit && next != .edit
        if leavingEdit {
            rehydrateFromEditor(persist: true, force: true)
            try? flushPendingSaves()
        } else if operatorMode != .edit && next == .edit {
            try? flushPendingSaves()
        }
        operatorMode = next
        if streaming.isLive || isoRecorder.isRecording {
            evaluateProgramClockState()
        }
        if next == .edit {
            if editors.kind != .presentation || editors.documents.isEmpty {
                openEditor(.presentation)
            }
        } else if editors.isOpen {
            if !leavingEdit {
                rehydrateFromEditor(persist: true)
            }
            editors.close()
        }
        if next == .map {
            hasMountedMapWorkspace = true
            refreshPlaceholderRoutes()
        }
        if next == .rundown {
            hasMountedRundownWorkspace = true
        }
    }

    func openEditor(_ kind: EditorKind) {
        dismissDeskWorkspaceSheets()
        if kind != .presentation,
           operatorMode == .map || operatorMode == .rundown || operatorMode == .bible {
            operatorMode = .show
        }
        if editors.kind == kind, !editors.documents.isEmpty {
            if kind == .theme {
                openThemeEditor()
                attachEditorToLiveIfNeeded()
                return
            }
            if kind == .presentation {
                editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
            }
            if kind == .presentation, let selectedSlideID,
               let match = editors.documents.first(where: { $0.slideID == selectedSlideID }) {
                editors.selectDocument(match.id)
            }
            attachEditorToLiveIfNeeded()
            return
        }
        if editors.kind == .presentation && kind != .presentation {
            rehydrateFromEditor(persist: true)
        }
        if editors.kind == .stage && kind != .stage {
            syncStagePackFromEditor(persist: true)
            persistLiveStageDocument()
        }
        if editors.kind == .theme && kind != .theme {
            syncThemePackFromEditor(persist: true)
        }
        if editors.kind == .props && kind != .props {
            syncPropsFromEditor()
            persistStudio()
        }
        if kind == .presentation {
            operatorMode = .edit
        }
        if streaming.isLive || isoRecorder.isRecording {
            evaluateProgramClockState()
        }
        if kind == .props {
            inspector.collapseDuplicateNamedProps()
        }
        if kind == .theme {
            openThemeEditor()
        } else if kind == .stage {
            openStageEditor()
        } else {
            editors.open(kind, show: show, selectedSlideID: selectedSlideID, props: inspector.props)
        }
        if kind == .stage, stageDocument == nil, let first = editors.selectedDocument {
            stageDocument = first
        }
        attachEditorToLiveIfNeeded()
        if kind == .presentation, liveSlideID == selectedSlideID {
            isEditorLockedToLive = true
            hasSandboxChanges = false
            snapshotSandboxBaseline()
        }
    }

    func closeEditor() {
        if editors.kind == .stage {
            syncStagePackFromEditor(persist: true)
        }
        persistLiveStageDocument()
        rehydrateFromEditor(persist: true, force: true)
        editors.close()
        if operatorMode == .edit {
            operatorMode = .show
        }
    }

    func persistLiveStageDocument() {
        if editors.kind == .stage, let selected = editors.selectedDocument {
            stageDocument = selected
            themeProjectSettings.activeStageVariantID = selected.id
            compositor.setStageLook(StageThemeBridge.inferLook(from: selected.objects))
            projectAutosave?.bundle.manifest.themeSettings = themeProjectSettings
            projectAutosave?.markDirty()
        }
    }

    func rehydrateFromEditor(persist: Bool = false, force: Bool = false) {
        let didSyncProps = editors.kind == .props
        syncPropsFromEditor()
        var next = show
        let changed = editors.rehydrate(into: &next)
        if !changed.isEmpty {
            show = next
            for slideID in changed {
                sanitizeSlideOnDisk(id: slideID)
                documentState.noteDocumentMutation(entityId: slideID)
                UnifiedCacheRegistry.shared.invalidate(entityId: slideID)
            }
            editors.purgeObjects { documentState.isTombstoned($0) }
            refreshLiveOutput(for: changed)
        }
        if persist {
            persistCurrentShow()
        }
        if didSyncProps, force || (editors.dragOrigins.isEmpty && editors.activeHandle == nil) {
            persistStudio()
        }
    }

    func syncPropsFromEditor() {
        guard editors.kind == .props else { return }
        for document in editors.documents {
            inspector.upsertProp(from: document)
        }
        inspector.collapseDuplicateNamedProps()
        let keep = Set(inspector.props.map(\.id))
        if editors.documents.contains(where: { !keep.contains($0.id) }) {
            let selectedID = editors.selectedDocumentID
            let selectedName = editors.selectedDocument?.name
            editors.documents.removeAll { !keep.contains($0.id) }
            if let selectedID, keep.contains(selectedID) {
                editors.selectedDocumentID = selectedID
            } else if let selectedName, let match = editors.documents.first(where: { $0.name == selectedName }) {
                editors.selectDocument(match.id)
            } else {
                editors.selectedDocumentID = editors.documents.first?.id
            }
        }
        syncActivePropsToCompositor()
    }

    func editProp(id: UUID) {
        inspector.selectProp(id: id)
        openEditor(.props)
        if editors.documents.contains(where: { $0.id == id }) {
            editors.selectDocument(id)
        }
    }

    func addEditableProp(named name: String = "New Prop") -> ProShowProp {
        let prop = inspector.addProp(name: name)
        if editors.kind == .props, !editors.documents.contains(where: { $0.id == prop.id }) {
            editors.insertDocument(from: prop)
        }
        syncActivePropsToCompositor()
        persistStudio()
        return prop
    }

    func assignPropCollection(id: UUID, collection: String) {
        inspector.setPropCollection(id: id, collection: collection)
        if editors.kind == .props,
           let index = editors.documents.firstIndex(where: { $0.id == id }) {
            editors.documents[index].collectionName = collection
        }
        persistStudio()
    }

    func setSelectedPropCollection(_ name: String) {
        inspector.selectedCollection = name
        inspector.ensureCollectionExists(name)
        persistStudio()
    }

    func refreshLiveOutput(for changed: Set<SlideID>) {
        guard let liveSlideID, changed.contains(liveSlideID),
              let slide = show.slide(id: liveSlideID)
        else { return }
        applyLiveSceneDelta(for: slide)
    }

    func applyLiveSceneDelta(for slide: Slide) {
        let cleaned = sanitizeSlide(slide)
        if show.id == ProgramOutlinePresentation.showID {
            if let page = ProgramOutlinePresentation.pageURL(in: cleaned) {
                ProgramPageRaster.shared.load(page)
                compositor.setProgramPageMediaBackdrop(page)
            } else {
                compositor.dismissRundownPage()
                ProgramPageRaster.shared.load(nil)
            }
        }
        let prepared = prepareSlideForProgramCue(cleaned)
        let canvas = resolvedCanvasObjects(audienceCanvasForProgram(prepared))
        let mediaOnly = prepared.isProgramMediaCue
        compositor.applyLiveSceneDelta(
            LiveSceneDelta(
                slideID: prepared.id,
                canvas: canvas,
                slideText: SlideElement.from(slide: prepared),
                backgroundEnabled: mediaOnly ? false : prepared.paintsOpaqueBackground,
                backgroundHex: prepared.backgroundHex,
                canvasWidth: CanvasConfig.width,
                canvasHeight: CanvasConfig.height
            )
        )
        if ProShowFeatureFlags.multiDestinationRoutingV1 {
            streaming.notePhoneCanvas(prepared.editorCanvases)
        }
        let incoming = resolvedAssociatedMedia(for: cleaned)
        let decision = MediaActionEvaluator.evaluate(
            current: compositor.stack.media,
            incoming: incoming,
            projectRoot: mediaProjectRoot,
            layerLocked: compositor.isLayerLocked(.media)
        )
        switch decision {
        case .preserve:
            if let incoming {
                playback.load(incoming, restart: false)
                inspector.syncTransportFromPlayback()
            }
        case .replace, .clear:
            applyMediaLayerDecision(decision)
        }
        if show.id == ProgramOutlinePresentation.showID,
           ProgramOutlinePresentation.pageURL(in: cleaned) == nil,
           !compositor.isLayerLocked(.videoInput) {
            ensureSlideLiveInputsOnMainLayer(cleaned)
            compositor.restore(.videoInput)
        }
    }

    func publishCurrentPhoneCanvas() {
        guard ProShowFeatureFlags.multiDestinationRoutingV1 else { return }
        rehydrateFromEditor(persist: false)
        guard let id = liveSlideID ?? selectedSlideID, let slide = show.slide(id: id) else { return }
        streaming.notePhoneCanvas(prepareSlideForProgramCue(slide).editorCanvases)
    }

    func pushEditorLive() {
        rehydrateFromEditor(persist: true, force: true)
        guard let action = editors.commitLive(selectedSlideID: selectedSlideID) else { return }
        switch action {
        case .goLive(let id):
            goLive(slideID: id)
        case .setStageLook(let look):
            compositor.setStageLook(look)
            if !isStageOutputOn { isStageOutputOn = true }
        case .applyTheme(let name):
            applyTheme(name)
        case .setMessage(let text):
            compositor.setMessage(text)
        case .toggleProp(let name):
            compositor.toggleProp(name)
        case .setMask(let enabled, let invert, let kind):
            compositor.setMask(enabled: enabled, invert: invert, kind: kind)
        }
    }

    @discardableResult
    func addSlide(named name: String = "Untitled") -> Slide {
        let slide = Slide(
            title: name,
            lines: [],
            isBlank: true,
            themeApplication: .native,
            backgroundEnabled: false
        )
        if let selected = selectedSlideID,
           let groupIndex = show.groups.firstIndex(where: { $0.slides.contains(where: { $0.id == selected }) }) {
            show.groups[groupIndex].slides.append(slide)
        } else if let groupIndex = show.groups.indices.last {
            show.groups[groupIndex].slides.append(slide)
        } else {
            show.groups.append(SlideGroup(name: "Group", slides: [slide]))
        }
        selectedSlideID = slide.id
        persistCurrentShow()
        return slide
    }

    func addEditorSlide() {
        rehydrateFromEditor(persist: true)
        _ = addSlide(named: "Slide \(show.allSlides.count + 1)")
        editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
    }

    func toggleMediaClear() {
        if compositor.stack.isCleared(.media) {
            compositor.restore(.media)
        } else {
            compositor.clear(.media)
        }
        refreshLiveStack()
    }

    func toggleDefaultClear() {
        if isDefaultLayerCleared {
            compositor.restoreDefaultLayers()
        } else {
            compositor.clearDefaultLayers()
        }
    }

    func toggleAudienceOutput() {
        isAudienceOutputOn.toggle()
        if isAudienceOutputOn, isAudienceCleared, liveSlideID != nil {
            isAudienceCleared = false
        }
        refreshLiveStack()
    }

    func toggleStageOutput() {
        isStageOutputOn.toggle()
    }

    func toggleStreamOutput() {
        isStreamOutputOn.toggle()
    }

    func toggleMultiViewer() {
        isMultiViewerOn.toggle()
    }

    var multiViewerLayout: MultiViewerLayout {
        deviceSettings.document.multiViewer
    }

    var multiViewerFormatLabel: String {
        let rate = deviceSettings.document.defaultFrameRate.title
        return "\(compositor.outputWidth)×\(compositor.outputHeight) \(rate)"
    }

    func multiViewerFormatLabel(for tile: MultiViewerTileConfig) -> String {
        let rate = deviceSettings.document.defaultFrameRate.title
        switch tile.type {
        case .phoneProgram, .phonePreview:
            return "\(PhoneEncodeTemplate.width)×\(PhoneEncodeTemplate.height) \(rate)"
        default:
            return multiViewerFormatLabel
        }
    }

    var liveProgramSourceId: String? {
        compositor.stack.videoInput?.id.uuidString
    }

    var nextPreviewSourceIds: Set<String> {
        guard let slide = operatorPreviewSlide else { return [] }
        var ids = Set<String>()
        for object in slide.audienceCanvas() {
            if let source = object.assignedSource {
                if !source.sourceID.isEmpty { ids.insert(source.sourceID) }
                if let media = source.mediaItemID { ids.insert(media.uuidString) }
            }
        }
        return ids
    }

    func multiViewerTally(for tile: MultiViewerTileConfig) -> MultiViewerTally {
        switch tile.type {
        case .program, .phoneProgram:
            return (isBroadcasting || programOutputEnabled) ? .program : .standby
        case .preview, .phonePreview:
            return operatorPreviewSlide == nil ? .standby : .preview
        case .cameraInput, .displayShare:
            if liveProgramSourceId == tile.sourceId { return .program }
            if nextPreviewSourceIds.contains(tile.sourceId) { return .preview }
            return .standby
        case .stageMonitor:
            return isStageOutputOn ? .preview : .standby
        case .audioMeterBridge:
            return .standby
        }
    }

    func multiViewerVideoSource(id: String) -> StudioVideoSource? {
        videoInputs.sources.first { $0.id.uuidString == id }
    }

    func multiViewerAssignableSources(for type: MultiTileType) -> [StudioVideoSource] {
        switch type {
        case .displayShare:
            return videoInputs.sources.filter { $0.kind == .screenShare }
        case .cameraInput:
            return videoInputs.sources.filter { $0.kind != .screenShare }
        default:
            return videoInputs.sources
        }
    }

    func multiViewerPeakDb(for tile: MultiViewerTileConfig) -> Double {
        let master = max(audioMatrix.master.peakLeft, audioMatrix.master.peakRight)
        switch tile.type {
        case .program, .phoneProgram, .audioMeterBridge:
            return master
        case .preview, .phonePreview:
            return max(PreviewCueMonitor.shared.leftPeakDb, PreviewCueMonitor.shared.rightPeakDb)
        case .cameraInput, .displayShare:
            return audioMatrix.channel(role: .desktop)?.peak ?? master
        case .stageMonitor:
            return audioMatrix.channel(role: .slide)?.peak ?? -120
        }
    }

    var multiViewerMeterChannels: [MultiViewerMeterChannel] {
        var rows: [MultiViewerMeterChannel] = [
            MultiViewerMeterChannel(id: "master-l", name: "Master L", db: audioMatrix.master.peakLeft, holdDb: audioMatrix.master.peakHoldDb, isMuted: audioMatrix.master.muted),
            MultiViewerMeterChannel(id: "master-r", name: "Master R", db: audioMatrix.master.peakRight, holdDb: audioMatrix.master.peakHoldDb, isMuted: audioMatrix.master.muted),
        ]
        for channel in audioMatrix.channels.prefix(14) {
            rows.append(
                MultiViewerMeterChannel(
                    id: channel.id.uuidString,
                    name: channel.name,
                    db: channel.peak,
                    holdDb: channel.peakHoldDb ?? channel.peak,
                    isMuted: channel.muted
                )
            )
        }
        while rows.count < 16 {
            rows.append(MultiViewerMeterChannel(id: "empty-\(rows.count)", name: "CH \(rows.count + 1)", db: -120, holdDb: -120))
        }
        return rows
    }

    func ensureMultiViewerLayout() {
        if deviceSettings.document.multiViewer.tiles.isEmpty {
            resetMultiViewerFromSources()
        }
    }

    func resetMultiViewerFromSources() {
        let grid = deviceSettings.document.multiViewer.grid
        mutateMultiViewer {
            $0 = .studioDefault(
                sources: videoInputs.sources,
                grid: grid,
                includePhone: ProShowFeatureFlags.multiDestinationRoutingV1
            )
        }
    }

    func setMultiViewerGrid(_ grid: MultiViewerGrid) {
        mutateMultiViewer { layout in
            layout.grid = grid
            if layout.tiles.count > grid.capacity {
                layout.tiles = Array(layout.orderedTiles.prefix(grid.capacity))
                layout.reindex()
            }
        }
    }

    func addMultiViewerTile() {
        mutateMultiViewer { layout in
            guard layout.tiles.count < layout.grid.capacity else { return }
            layout.tiles.append(
                MultiViewerTileConfig(
                    type: .cameraInput,
                    customTitle: "Input \(layout.tiles.count + 1)",
                    gridPositionIndex: layout.tiles.count
                )
            )
        }
    }

    func removeMultiViewerTile(id: UUID) {
        mutateMultiViewer { layout in
            layout.tiles.removeAll { $0.id == id }
            layout.reindex()
        }
    }

    func moveMultiViewerTile(id: UUID, by offset: Int) {
        mutateMultiViewer { layout in
            guard let index = layout.orderedTiles.firstIndex(where: { $0.id == id }) else { return }
            let destination = index + offset
            guard layout.tiles.indices.contains(destination) else { return }
            var ordered = layout.orderedTiles
            ordered.swapAt(index, destination)
            layout.tiles = ordered
            layout.reindex()
        }
    }

    func updateMultiViewerTile(id: UUID, mutate: (inout MultiViewerTileConfig) -> Void) {
        mutateMultiViewer { layout in
            guard let index = layout.tiles.firstIndex(where: { $0.id == id }) else { return }
            mutate(&layout.tiles[index])
        }
    }

    private func mutateMultiViewer(_ body: (inout MultiViewerLayout) -> Void) {
        var layout = deviceSettings.document.multiViewer
        body(&layout)
        deviceSettings.document.multiViewer = layout
        deviceSettings.save()
    }

    /// Full off-screen composite only while streaming, recording, or the Stream window wants encode parity.
    var streamEncodePreviewEnabled = false
    var wantsEncodedPreview: Bool {
        evaluateOutputMode().requiresOffScreenComposite
    }

    func mediaAction(from item: MediaBinItem) -> MediaAction {
        let duration: String?
        switch item.kind {
        case let .video(value), let .audio(value): duration = value
        default: duration = nil
        }
        return MediaAction(
            id: item.id,
            title: item.title,
            tintHex: item.tintHex,
            duration: duration,
            isImage: item.kind == .image,
            filePath: item.filePath,
            placeholderLetter: placeholderLetter(from: item)
        )
    }

    func mediaPaneSelectionMatches(_ media: MediaAction) -> Bool {
        guard let id = selectedMediaItemID, let item = mediaItem(id: id) else { return false }
        return MediaActionEvaluator.isSameAsset(mediaAction(from: item), media, projectRoot: mediaProjectRoot)
    }

    func liveLinkedProgramMedia() -> MediaAction? {
        guard let slide = liveSlide else { return nil }
        guard let linked = resolvedAssociatedMedia(for: slide), !linked.clearsLayer else { return nil }
        return linked
    }

    func shouldProtectLiveLinkedMedia(from item: MediaBinItem) -> Bool {
        guard let linked = liveLinkedProgramMedia() else { return false }
        return !MediaActionEvaluator.isSameAsset(mediaAction(from: item), linked, projectRoot: mediaProjectRoot)
    }

    /// Bin tap selects. A live slide's linked file keeps Layer 3 unless `takeProgram` is set.
    func selectMediaInPane(_ item: MediaBinItem, takeProgram: Bool = false) {
        selectedMediaItemID = item.id
        triggerMedia(item, takeProgram: takeProgram)
    }

    func triggerMedia(_ item: MediaBinItem, takeProgram: Bool = false) {
        selectedMediaItemID = item.id
        if compositor.isLayerLocked(.media) { return }
        if !takeProgram {
            if shouldProtectLiveLinkedMedia(from: item) {
                return
            }
            if playback.sharesClock(with: mediaAction(from: item)) {
                return
            }
        }
        if case .camera = item.kind {
            if let discovered = discoveredLiveInput(from: item) {
                _ = ensureLiveInputOnMainLayer(discovered)
            }
            selectedMediaSource = .videoInputs
            refreshLiveStack()
            return
        }
        if case .microphone = item.kind {
            activateDedicatedMicrophone(discoveredSource(from: item))
            selectedMediaSource = .audioInputs
            refreshLiveStack()
            return
        }
        if let path = item.filePath {
            if let url = MediaPath.resolve(path, projectRoot: mediaProjectRoot) {
                let inspected = MediaLoader.inspect(url: url)
                if case .missing = inspected {
                    if path.hasPrefix("/") {
                        mediaAlert = "Missing media file: \(path)"
                        return
                    }
                } else {
                    mediaAlert = nil
                    applyMediaLayerDecision(.replace(MediaLoader.action(from: item, inspected: inspected)))
                    refreshLiveStack()
                    return
                }
            } else if path.hasPrefix("/") {
                mediaAlert = "Missing media file: \(path)"
                return
            }
        }
        applyMediaLayerDecision(.replace(mediaAction(from: item)))
        refreshLiveStack()
    }

    private func bindLiveMedia() {
        isMediaPlaying = playback.isPlaying
        armProgramAudio()
        tickProgram()
    }

    func resolvedAssociatedMedia(for slide: Slide) -> MediaAction? {
        var resolved = slide
        resolved.canvas = resolvedCanvasObjects(slide.canvas)
        guard var action = resolved.associatedMediaAction() else { return nil }
        if action.clearsLayer { return action }
        if (action.filePath == nil || action.filePath?.isEmpty == true),
           let item = allMediaItems.first(where: { $0.title.caseInsensitiveCompare(action.title) == .orderedSame }) {
            action.id = item.id
            action.filePath = item.filePath
            action.isImage = item.kind == .image
            if case let .video(duration) = item.kind {
                action.duration = duration
            }
        }
        return resolveProgramMediaPlaceholders(action)
    }

    func ensureProgramMediaClock() {
        guard isAudienceOutputOn, !isAudienceCleared, let slide = liveSlide else { return }
        guard let incoming = resolvedAssociatedMedia(for: slide), !incoming.clearsLayer else { return }
        if playback.sharesClock(with: incoming) {
            playback.load(incoming, restart: false)
            refreshProgramClockBindings()
            return
        }
        if !playback.hasProgramClock {
            applyMediaLayerDecision(.replace(incoming))
        }
    }

    /// Live Layer 3 media with Hold taken from the slide cue that owns it (Hold can change while live).
    private func liveMediaWithHoldState() -> MediaAction? {
        guard var current = compositor.stack.media else { return nil }
        let root = mediaProjectRoot
        current.hold = show.groups.contains { group in
            group.slides.contains { slide in
                guard let cue = slide.mediaAction, cue.hold, !cue.clearsLayer else { return false }
                return MediaActionEvaluator.isSameAsset(cue, current, projectRoot: root)
            }
        }
        return current
    }

    private func applyMediaLayerDecision(_ decision: MediaLayerDecision) {
        switch decision {
        case .preserve:
            if let current = compositor.stack.media {
                compositor.restore(.media)
                playback.load(current, restart: false)
                inspector.syncTransportFromPlayback()
            }
        case .replace(let media):
            ProgramStreamAudioGates.setHardwareCaptureOpen(.slide, open: true)
            compositor.transitionLayer(.media, to: media, transitionDuration: 0.5)
            playback.load(media, restart: true)
            inspector.syncTransportFromPlayback()
            isMediaPlaying = playback.isPlaying
        case .clear:
            compositor.clearProgramMedia()
            compositor.clear(.media)
            playback.load(nil)
            inspector.bindMedia(nil)
            isMediaPlaying = false
        }
        refreshProgramClockBindings()
        if decision == .clear {
            applyProgramAudioMute()
        } else {
            armProgramAudio()
        }
    }

    func armProgramAudio() {
        inspector.bindMedia(resolvedProgramMedia() ?? compositor.stack.media)
        applyProgramAudioMute()
        studioAudio.tick(streamEncodeActive: streaming.isLive || isoRecorder.isRecording)
        primeProgramMediaAudioPipeline()
        if playback.isPlaying, !playback.isMuted {
            playback.play()
        }
    }

    /// Slide PCM + stream gates after Layer 3 loads (program-mix headphones use the tap, not local volume).
    func primeProgramMediaAudioPipeline() {
        guard compositor.stack.media != nil else { return }
        ProgramStreamAudioGates.setHardwareCaptureOpen(.slide, open: true)
        ProgramStreamAudioGates.sync(from: audioMatrix)
        AudioMatrixReconciler.enforceProgramAudioGates(controller: self)
        publishProgramMediaAudioPuller()
        tickProgram()
    }

    func publishProgramMediaAudioPuller() {
        let programMixMonitor = ProgramAudioMonitorBridge.shared.isRunning
            && AudioMonitoringEngine.shared.monitorMode == .programMix
        let feedsSlidePCM = playback.isPlaying && !playback.isMuted
            && (playback.mixGain > 0.0001 || programMixMonitor)
        ProgramAudioPuller.publish(
            url: playback.fileURL,
            playhead: playback.playhead,
            isPlaying: feedsSlidePCM
        )
    }

    private func executeLinkedSlideMacros(_ slide: Slide) {
        for raw in slide.actions {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("macro:") else { continue }
            let name = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  let macro = inspector.macros.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            else { continue }
            _ = triggerMacro(id: macro.id)
        }
    }

    func refreshLiveStack() {
        liveStack.activeBaseColor = compositor.stack.screenColorHex
        if let input = compositor.stack.videoInput, compositor.stack.isVisible(.videoInput, onStage: false) {
            liveStack.activeVideoInput = LiveLayerItem(id: input.id, name: input.label)
        } else {
            liveStack.activeVideoInput = nil
        }
        if let media = compositor.stack.media, compositor.stack.isVisible(.media, onStage: false) {
            liveStack.activeMedia = LiveLayerItem(id: media.id, name: media.title, thumbnailURI: media.filePath)
        } else {
            liveStack.activeMedia = nil
        }
        if let slide = liveSlide {
            liveStack.activeSlide = LiveLayerItem(
                id: slide.id,
                name: slide.title.isEmpty ? "Slide" : slide.title
            )
        } else {
            liveStack.activeSlide = nil
        }
        if let pip = compositor.stack.pipInput {
            liveStack.activePip = LiveLayerItem(id: pip.id, name: pip.label)
        } else {
            liveStack.activePip = nil
        }
        syncLiveKitTally()
        liveStack.activeProps = inspector.props.filter(\.isActive).map {
            LiveLayerItem(id: $0.id, name: $0.name)
        }
        liveStack.activeMessages = inspector.messages.filter(\.isActive).map {
            LiveLayerItem(id: $0.id, name: $0.title)
        }
        if compositor.stack.chatOverlay?.visible == true {
            let card = compositor.stack.chatOverlay!
            liveStack.activeOverlays = [LiveLayerItem(id: card.message.id, name: card.message.author)]
        } else if let announcement = compositor.stack.announcement, !announcement.isEmpty {
            liveStack.activeOverlays = [LiveLayerItem(id: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC8")!, name: announcement)]
        } else {
            liveStack.activeOverlays = []
        }
    }

    func isProgramMediaPlaying(_ item: MediaBinItem) -> Bool {
        guard item.showsPlaybackTransport else { return false }
        guard !compositor.stack.isCleared(.media), let media = compositor.stack.media else { return false }
        if liveStack.isMediaActive(mediaID: item.id) { return true }
        if liveStack.isMediaNamed(item.title) { return true }
        if playback.isPlayingFile(at: item.filePath) { return true }
        return MediaActionEvaluator.isSameAsset(
            media,
            MediaAction(
                id: item.id,
                title: item.title,
                tintHex: item.tintHex,
                isImage: item.kind == .image,
                filePath: item.filePath
            ),
            projectRoot: mediaProjectRoot
        )
    }

    func configureSlide(id: SlideID, _ body: (inout Slide) -> Void) {
        mutateSlide(id: id, body)
    }

    /// Prefer the mapped file behind a placeholder so preview and audience share one clock.
    func resolvedProgramMedia() -> MediaAction? {
        guard let media = compositor.stack.media else { return nil }
        return resolveProgramMediaPlaceholders(media)
    }

    private func resolveProgramMediaPlaceholders(_ media: MediaAction) -> MediaAction {
        var next = media
        if let letter = next.placeholderLetter,
           let mapped = resolvedAssignedSource(forPlaceholder: letter),
           let path = mapped.connectionString {
            next.title = mapped.name
            next.filePath = path
            next.isImage = !mapped.looksLikeVideo
            if mapped.audioMuted == true { next.audioMuted = true }
        }
        if isPlaceholderAudioMuted(next.placeholderLetter) || liveMutedShotFeeds(next) {
            next.audioMuted = true
        }
        return next
    }

    func syncProgramPlayback() {
        inspector.syncTransportFromPlayback()
    }

    var showsPhoneCanvasMonitor: Bool {
        ProShowFeatureFlags.multiDestinationRoutingV1
    }

    func phoneCanvasBoard(on slide: Slide?) -> EditorCanvasFrame? {
        guard let slide else { return nil }
        return slide.editorCanvases.first {
            !$0.isPrimary && CanvasResolution.screenFamily(width: $0.width, height: $0.height) == .phone
        }
    }

    func selectPhonePreviewFeed(_ feed: PreviewFeed) {
        let normalized: PreviewFeed = PreviewFeed.operatorFeeds.contains(feed) ? feed : .stream
        inspector.phonePreviewFeed = normalized
        if normalized == .audience {
            followOperatorPreviewAudio(true)
        }
    }

    func selectPreviewFeed(_ feed: PreviewFeed) {
        let normalized = PreviewFeed.operatorFeeds.contains(feed) ? feed : .audience
        inspector.previewFeed = normalized
    }

    /// Keeps saved workspace state off retired desk surfaces (stage/matrix preview, legacy tabs).
    func sanitizeOperatorInspectorPresentation() {
        if !PreviewFeed.operatorFeeds.contains(inspector.previewFeed) {
            selectPreviewFeed(.audience)
        }
        if !PreviewFeed.operatorFeeds.contains(inspector.phonePreviewFeed) {
            selectPhonePreviewFeed(.stream)
        }
        if !ActionInspectorTab.deskTabs.contains(inspector.selectedTab) {
            inspector.selectedTab = .layers
        }
        if operatorMode == .reflow || operatorMode == .widgets {
            operatorMode = .show
        }
    }

    /// Start or stop the 30 Hz program timer based on whether anything on-air needs ticks.
    func evaluateProgramClockState(now: Date = Date()) {
        if isProgramClockActiveNeeded(now: now) {
            ensureProgramClockRunning(now: now)
        } else {
            suspendProgramClock()
        }
    }

    func startProgramClock() {
        evaluateProgramClockState()
    }

    func stopProgramClock() {
        suspendProgramClock()
    }

    private func isProgramClockActiveNeeded(now: Date = Date()) -> Bool {
        isProgramRenderNeeded(now: now)
    }

    private func programClockInterval() -> TimeInterval {
        let mode = evaluateOutputMode()
        guard mode.requiresOffScreenComposite else { return 1.0 / 30.0 }
        switch mode {
        case .live, .liveAndRecording:
            return 1.0 / Double(max(1, streaming.config.framerate))
        default:
            return 1.0 / Double(max(1, mode.targetFrameRate))
        }
    }

    private func ensureProgramClockRunning(now: Date = Date()) {
        let interval = programClockInterval()
        if programClock != nil, programClockIntervalActive != interval {
            suspendProgramClock()
        }
        if programClock == nil {
            programClockIntervalActive = interval
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.handleProgramClockTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            programClock = timer
        }
        programClockIdleTicks = 0
        tickProgram(now: now)
    }

    private func suspendProgramClock() {
        programClock?.invalidate()
        programClock = nil
        programClockIntervalActive = nil
        programClockIdleTicks = 0
    }

    var projectHasUnsavedChanges: Bool {
        documentState.isDirty || (projectAutosave?.isDirty ?? false)
    }

    var projectDisplayName: String {
        guard let projectAutosave else { return projectSettings.name }
        return ProShowProjectNaming.resolvedDisplayName(
            manifestName: projectAutosave.bundle.manifest.name,
            bundleRoot: projectAutosave.bundle.root
        )
    }

    private func handleProgramClockTick(now: Date = Date()) {
        guard isProgramRenderNeeded(now: now) else {
            suspendProgramClock()
            return
        }
        tickProgram(now: now)
    }

    private func isProgramRenderNeeded(now: Date) -> Bool {
        if streaming.isLive || isoRecorder.isRecording { return true }
        if liveKitGuestReturnActive { return true }
        if wantsEncodedPreview { return true }
        if playback.isPlaying || stingerPlayer.isPlaying { return true }
        if compositor.programTransition?.isActive == true { return true }
        if liveBuildStartedAt != nil || !propBuildStartedAt.isEmpty { return true }
        if inspector.timers.contains(where: \.isRunning) { return true }
        if now.timeIntervalSince(lastProgramMutationAt) < 1.5 { return true }
        if compositor.stack.isVisible(.videoInput, onStage: false),
           let input = compositor.stack.videoInput,
           videoInputs.isRunning(endpoint: input.endpoint, sourceID: input.id.uuidString)
        {
            return true
        }
        if !stackActiveLoopingMarketProps().isEmpty {
            return true
        }
        return false
    }

    private func stackActiveLoopingMarketProps() -> [CanvasObject] {
        guard compositor.stack.isVisible(.props, onStage: false) else { return [] }
        return compositor.propCanvases
            .filter { compositor.stack.activeProps.contains($0.name) }
            .flatMap(\.objects)
            .filter { object in
                object.visibleOnAudience
                    && object.textLayout.isLooping
                    && (MarketTickerRouting.usesColoredStrip(object)
                        || MarketTickerRouting.usesStaticColoredLiveQuote(object))
            }
    }

    func noteProgramMutation() {
        lastProgramMutationAt = Date()
        evaluateProgramClockState()
    }

    /// Off-screen SwiftUI snapshot only when a consumer actually needs encoded pixels.
    var needsOffScreenProgramSurfaceCapture: Bool {
        guard ProgramSurfaceGrabber.useAudienceSurfaceForLiveStreamEncode else { return false }
        return streaming.isLive || isoRecorder.isRecording || virtualCamera.isPublished
    }

    func bumpProjectSaveRevision() {
        projectSaveRevision &+= 1
    }

    func tickProgram(now: Date = Date()) {
        guard !isAdvancingProgram else { return }
        isAdvancingProgram = true
        defer { isAdvancingProgram = false }
        inspector.tick(now: now)
        applyCountdownBuildLinks(now: now)
        syncMediaBackedCountdowns()
        reconcilePropBuildClocks(now: now)
        streaming.noteTransportHealth()
        if streaming.isLive {
            StreamAudioPipelineDiagnostics.updateLaneDepths(ProgramAACEncoder.laneDepthSummary())
            StreamAudioPipelineDiagnostics.periodicEmitIfNeeded(isLive: true)
            streaming.streamEngineV2.noteTelemetry()
        }
        syncProgramPlayback()
        compositor.tickTransition(now: now)
        tickPropBuildClears(now: now)
        completeSlideLeaveIfNeeded(now: now)
        if stingerPlayer.isPlaying {
            stingerPlayer.tick(deltaMs: Int((1.0 / 30.0) * 1000))
        }
        tickPlaceholderFailover()
        syncTextFieldsFromCanvas()
        if isoRecorder.isRecording && !streaming.isLive {
            liveQuoteRefreshMinInterval = 1.25
        } else {
            liveQuoteRefreshMinInterval = 0.5
        }
        refreshLiveQuotes(now: now)
        ensureProgramMarketTickerFeeds(now: now)
        refreshRundownTick()
        applyProgramAudioMute()
        syncLiveAudioCapture()
        ProgramStreamAudioGates.sync(from: audioMatrix)
        publishProgramMediaAudioPuller()
        audioIO.tick(playback: playback, soundboard: soundboard, matrix: audioMatrix)
        let streamEncodeActive = streaming.isLive || isoRecorder.isRecording
        PreviewProgramAudioPump.setEncodingSuppressed(streamEncodeActive)
        studioAudio.tick(streamEncodeActive: streamEncodeActive)
        let left = max(audioMatrix.monitorMixLevel(), playback.outputLevel)
        let right = max(audioMatrix.streamMixLevel(), playback.outputLevel)
        compositor.syncVideoInputs(from: videoInputs)
        let mediaPixels = rundownPagePixelBuffer() ?? programMediaPixelBufferForEncode()
        let showsProgramVideo = compositor.stack.isVisible(.videoInput, onStage: false)
        let videoPixels = showsProgramVideo
            ? compositor.stack.videoInput.flatMap { videoInputs.pixelBuffer(for: $0) }
            : nil
        let pipPixels = compositor.stack.pipInput.flatMap { videoInputs.pixelBuffer(for: $0) }
        let programVideoFrame = showsProgramVideo
            ? compositor.stack.videoInput.flatMap { videoInputs.frame(for: $0) }
            : nil
        compositor.advanceFrame(
            playhead: playback.playhead,
            now: now,
            leftMeter: left,
            rightMeter: right,
            filters: filters,
            renderer: programRenderer,
            videoFrame: programVideoFrame,
            pixelBuffer: mediaPixels ?? videoPixels
        )
        let renderSnapshot = prepareAtomicProgramTick(now: now)
        if wantsEncodedPreview {
            submitProgramOutput(
                stack: stackForProgramEncode(compositor.stack),
                width: compositor.outputWidth,
                height: compositor.outputHeight,
                video: videoPixels,
                pip: pipPixels,
                media: mediaPixels,
                videoFrame: programVideoFrame,
                now: now,
                snapshot: renderSnapshot
            )
        }
        isMediaPlaying = playback.isPlaying
        evaluateProgramClockState(now: now)
        syncStreamCapturePrivacyIfNeeded()
        programFrame &+= 1
        transportClock.programFrame = programFrame
        transportClock.liveBuildStartedAt = liveBuildStartedAt
        transportClock.boundSlideID = liveSlideID
    }

    /// The minute's page, snapshotted so the stream matches the audience picture.
    private func rundownPagePixelBuffer() -> CVPixelBuffer? {
        if let url = compositor.rundownPageURL {
            return ProgramPageRaster.shared.displayBuffer(for: url)
        }
        if compositor.stack.media?.id == RundownPageMedia.id {
            let url = compositor.stack.media?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else { return nil }
            return ProgramPageRaster.shared.displayBuffer(for: url)
        }
        return nil
    }

    /// Latest program-media frame for RTMP/ISO (keeps last frame when paused; SwiftUI preview may still show video).
    private func programMediaPixelBufferForEncode() -> CVPixelBuffer? {
        guard compositor.stack.media != nil, !compositor.stack.media!.clearsLayer else { return nil }
        guard playback.canPresentVideo else { return nil }
        return playback.copyLatestPixelBuffer()
    }

    func pixelBufferForCanvasLiveObject(
        _ object: CanvasObject,
        programVideo: CVPixelBuffer?,
        stack: RenderStack,
        onStage: Bool = false,
        forBroadcast: Bool = false
    ) -> CVPixelBuffer? {
        _ = forBroadcast
        if object.kind.isBrowserLike || object.assignedSource?.sourceType == .webPage {
            guard let url = Self.browserPageURL(for: object) else { return nil }
            return ProgramPageRaster.shared.displayBuffer(for: url)
        }
        let showsProgramVideoLayer = stack.isVisible(.videoInput, onStage: onStage)
        if let assigned = object.assignedSource, let buffer = liveBuffer(for: assigned) {
            return buffer
        }
        if ProgramLiveVideoRouting.canvasUsesProgramInput(
            assigned: object.assignedSource,
            objectKind: object.kind,
            programInput: stack.videoInput,
            showsProgramVideoLayer: showsProgramVideoLayer
        ) {
            return programVideo
        }
        return nil
    }

    /// Lane lookup the thumbnail uses: connection, then the hardware id capture actually publishes.
    private func liveBuffer(for assigned: AssignedMediaSource) -> CVPixelBuffer? {
        let trimmed = assigned.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint = trimmed.isEmpty ? nil : trimmed
        let kind = Self.studioKind(for: assigned.sourceType, endpoint: endpoint)
        if let buffer = videoInputs.pixelBuffer(matching: endpoint, sourceID: assigned.sourceID, kind: kind) {
            return buffer
        }
        if kind != nil, let buffer = videoInputs.pixelBuffer(matching: endpoint, sourceID: assigned.sourceID, kind: nil) {
            return buffer
        }
        if let endpoint {
            let alias = HardwareSourceIdentity.uuid(for: endpoint).uuidString
            if alias != assigned.sourceID,
               let buffer = videoInputs.pixelBuffer(matching: endpoint, sourceID: alias, kind: nil) {
                return buffer
            }
            if let buffer = LivePixelHub.shared.current(endpoint: endpoint, sourceID: alias) {
                return buffer
            }
        }
        return LivePixelHub.shared.current(endpoint: endpoint, sourceID: assigned.sourceID)
    }

    private static func browserPageURL(for object: CanvasObject) -> String? {
        let raw = object.assignedSource?.connectionString ?? object.fill.imageURI
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let canonical = PromptWebsiteURL.canonical(trimmed) { return canonical }
        return trimmed
    }

    private static func studioKind(for sourceType: SourceType, endpoint: String?) -> StudioVideoKind? {
        if let endpoint {
            if endpoint.hasPrefix("sck://") { return .screenShare }
            if endpoint.hasPrefix("ndi://") { return .ndi }
            if endpoint.hasPrefix("avf://") { return .camera }
        }
        switch sourceType {
        case .systemDisplay, .systemWindow: return .screenShare
        case .systemCamera: return .camera
        case .ndiSource: return .ndi
        default: return nil
        }
    }

    private func configureVideoFrameInvalidation() {
        NotificationCenter.default.addObserver(
            forName: .proShowVideoFrameInvalidated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if streaming.isLive || isoRecorder.isRecording { return }
            compositor.programOutput.invalidate()
        }
    }

    private func submitProgramOutput(
        stack: RenderStack,
        width: Int,
        height: Int,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        media: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?,
        now: Date,
        snapshot: ProgramRenderSnapshot
    ) {
        let outputMode = evaluateOutputMode()
        guard outputMode.requiresOffScreenComposite else { return }
        #if canImport(CoreVideo)
        if programOutputInFlight, outputMode.isLive {
            streaming.telemetry.recordSkippedCompositeFrame()
            mergePendingProgramOutputWhileCompositeBusy(
                stack: stack,
                video: video,
                pip: pip,
                media: media,
                videoFrame: videoFrame,
                now: now,
                snapshot: snapshot,
                outputMode: outputMode
            )
            return
        } else if programOutputInFlight {
            streaming.telemetry.recordSkippedCompositeFrame()
            let activePropCanvases = compositor.propCanvases.filter { stack.activeProps.contains($0.name) }
            if !emitStreamCFRHoldFrameWhileCompositeBusy(
                now: now,
                outputMode: outputMode,
                snapshot: snapshot,
                stack: stack,
                video: video,
                pip: pip,
                videoFrame: videoFrame,
                programTransition: compositor.programTransition,
                propCanvases: activePropCanvases
            ) {
                streaming.hardwareEncoder.advanceScheduledFrames(1)
            }
        }
        let contract = currentProgramRenderContract()
        if outputMode.isRecording {
            let minInterval = 1.0 / Double(max(1, contract.frameRate))
            if now.timeIntervalSince(lastRecordEncodeSubmitAt) < minInterval * 0.92 {
                return
            }
        }
        lastRecordEncodeSubmitAt = now
        let compositeWidth = contract.width
        let compositeHeight = contract.height
        let deliverWidth = contract.width
        let deliverHeight = contract.height
        let streamLive = outputMode.isLive
        let activePropCanvases = compositor.propCanvases.filter { stack.activeProps.contains($0.name) }
        let objectLivePixels = programObjectLivePixelsForEncode(
            stack: stack,
            programVideo: video,
            propCanvases: activePropCanvases,
            inFlight: programOutputInFlight
        )
        let buildClock = liveBuildClock()
        let slideLivePlayback = buildClock.playback(now: now)
        let slideEncodePlayback = BuildAnimationEngine.broadcastPlayback(
            from: slideLivePlayback,
            canvasObjects: stack.slideCanvas
        )
        var propBuildPlayback: [UUID: BuildPlayback] = [:]
        for canvas in activePropCanvases {
            let propLive = propEncodePlayback(for: canvas, now: now)
            propBuildPlayback[canvas.id] = BuildAnimationEngine.broadcastPlayback(
                from: propLive,
                canvasObjects: canvas.objects
            )
        }
        #if os(macOS)
        let marketStreamItems = MarketDataStreamEngine.shared.items
        let tickerColors = TickerConfigStore.shared.colorConfig
        #else
        let marketStreamItems: [MarketTickerItem] = []
        let tickerColors = TickerColorConfig()
        #endif
        pendingProgramOutput = ProgramOutputWorkItem(
            stack: stack,
            compositeWidth: compositeWidth,
            compositeHeight: compositeHeight,
            deliverWidth: deliverWidth,
            deliverHeight: deliverHeight,
            video: video,
            pip: pip,
            media: media,
            videoFrame: videoFrame,
            textContext: snapshot.dynamicText,
            propCanvases: activePropCanvases,
            objectLivePixels: objectLivePixels,
            buildPlayback: slideEncodePlayback,
            buildPhaseFilter: slideLeaveStartedAt != nil ? [.buildOut] : nil,
            renderNow: now,
            programTransition: compositor.programTransition,
            propBuildPlayback: propBuildPlayback,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColors,
            streamLive: streamLive,
            captureProgram: outputMode.isRecording,
            presentationTime: now.timeIntervalSinceReferenceDate,
            hostTime: CMClockGetTime(CMClockGetHostTimeClock()),
            audienceSurfaceBuffer: nil,
            outputMode: outputMode,
            renderContract: contract,
            frameRevision: snapshot.revision
        )
        drainProgramOutputIfNeeded()
        #endif
    }

    #if canImport(CoreVideo)
    private struct ProgramOutputWorkItem {
        var stack: RenderStack
        var compositeWidth: Int
        var compositeHeight: Int
        var deliverWidth: Int
        var deliverHeight: Int
        var video: CVPixelBuffer?
        var pip: CVPixelBuffer?
        var media: CVPixelBuffer?
        var videoFrame: VideoIngestFrame?
        var textContext: DynamicTextContext?
        var propCanvases: [PropCanvas]
        var objectLivePixels: [UUID: CVPixelBuffer]
        var buildPlayback: BuildPlayback
        var buildPhaseFilter: Set<BuildPhase>?
        var renderNow: Date
        var programTransition: ProgramTransitionState?
        var propBuildPlayback: [UUID: BuildPlayback]
        var marketStreamItems: [MarketTickerItem]
        var tickerColorConfig: TickerColorConfig
        var streamLive: Bool
        var captureProgram: Bool
        var presentationTime: TimeInterval
        var hostTime: CMTime
        var audienceSurfaceBuffer: CVPixelBuffer?
        var outputMode: ProgramOutputMode
        var renderContract: ProgramRenderContract
        var frameRevision: UInt64
    }

    private func programObjectLivePixelsForEncode(
        stack: RenderStack,
        programVideo: CVPixelBuffer?,
        propCanvases: [PropCanvas],
        inFlight: Bool
    ) -> [UUID: CVPixelBuffer] {
        if inFlight, streaming.isLive || isoRecorder.isRecording,
           let prior = pendingProgramOutput?.objectLivePixels, !prior.isEmpty {
            return prior
        }
        if inFlight, let prior = pendingProgramOutput?.objectLivePixels, !prior.isEmpty {
            return patchProgramObjectLivePixels(
                prior,
                stack: stack,
                programVideo: programVideo,
                propCanvases: propCanvases
            )
        }
        return buildProgramObjectLivePixels(
            stack: stack,
            programVideo: programVideo,
            propCanvases: propCanvases
        )
    }

    private func patchProgramObjectLivePixels(
        _ prior: [UUID: CVPixelBuffer],
        stack: RenderStack,
        programVideo: CVPixelBuffer?,
        propCanvases: [PropCanvas]
    ) -> [UUID: CVPixelBuffer] {
        var pixels = prior
        func patch(_ objects: [CanvasObject]) {
            for object in objects where object.visibleOnAudience {
                if object.kind.isBrowserLike || object.assignedSource?.sourceType == .webPage {
                    guard let url = Self.browserPageURL(for: object) else { continue }
                    if let buffer = ProgramPageRaster.shared.displayBuffer(for: url) {
                        pixels[object.id] = ProgramOutputComposer.snapshot(buffer)
                    }
                    continue
                }
                guard ProgramOutputComposer.needsLiveVideoPixel(for: object) else { continue }
                if let buffer = pixelBufferForCanvasLiveObject(
                    object,
                    programVideo: programVideo,
                    stack: stack,
                    forBroadcast: true
                ) {
                    pixels[object.id] = ProgramOutputComposer.snapshot(buffer)
                }
            }
        }
        patch(stack.slideCanvas)
        for canvas in propCanvases {
            patch(canvas.objects)
        }
        return pixels
    }

    private func buildProgramObjectLivePixels(
        stack: RenderStack,
        programVideo: CVPixelBuffer?,
        propCanvases: [PropCanvas]
    ) -> [UUID: CVPixelBuffer] {
        var pixels: [UUID: CVPixelBuffer] = [:]
        func collect(_ objects: [CanvasObject]) {
            for object in objects where object.visibleOnAudience {
                if object.kind.isBrowserLike || object.assignedSource?.sourceType == .webPage {
                    guard let url = Self.browserPageURL(for: object) else { continue }
                    if let buffer = ProgramPageRaster.shared.displayBuffer(for: url) {
                        pixels[object.id] = ProgramOutputComposer.snapshot(buffer)
                    }
                    continue
                }
                guard ProgramOutputComposer.needsLiveVideoPixel(for: object) else { continue }
                if let buffer = pixelBufferForCanvasLiveObject(
                    object,
                    programVideo: programVideo,
                    stack: stack,
                    forBroadcast: true
                ) {
                    pixels[object.id] = ProgramOutputComposer.snapshot(buffer)
                }
            }
        }
        collect(stack.slideCanvas)
        for canvas in propCanvases {
            collect(canvas.objects)
        }
        return pixels
    }

    /// Re-encode the last program frame (or cheap video-layer blit) so CFR timestamps always carry a video tag.
    @discardableResult
    private func emitStreamCFRHoldFrameWhileCompositeBusy(
        now: Date,
        outputMode: ProgramOutputMode,
        snapshot: ProgramRenderSnapshot,
        stack: RenderStack,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?,
        programTransition: ProgramTransitionState?,
        propCanvases: [PropCanvas]? = nil
    ) -> Bool {
        guard outputMode.isLive || outputMode.isRecording else { return false }
        let contract = currentProgramRenderContract()
        let minInterval = 1.0 / Double(max(1, contract.frameRate))
        guard now.timeIntervalSince(lastLiveHoldFramePublishAt) >= minInterval * 0.92 else { return false }

        let work = pendingProgramOutput
        let props = propCanvases ?? work?.propCanvases
            ?? compositor.propCanvases.filter { stack.activeProps.contains($0.name) }
        let deliverWidth = work?.deliverWidth ?? contract.width
        let deliverHeight = work?.deliverHeight ?? contract.height
        let fallback = resolvedStreamFallbackSnapshot()
        guard fallback != nil || video != nil || work?.video != nil else { return false }

        lastLiveHoldFramePublishAt = now
        streaming.telemetry.recordStreamCFRHoldFrame()
        streaming.markLastEncodeSource(.cfrHoldDuplicate)

        let stackForHold = work?.stack ?? stack
        let videoForHold = work?.video ?? video
        let pipForHold = work?.pip ?? pip
        let frameForHold = work?.videoFrame ?? videoFrame
        let transition = work?.programTransition ?? programTransition
        let suppressVideoOnlyBlit = slideLeaveStartedAt != nil || liveBuildStartedAt != nil
        let videoOnlyEligible = !suppressVideoOnlyBlit
            && ProgramOutputComposer.eligibleForVideoOnlyStreamEncode(
                stack: stackForHold,
                propCanvases: props,
                programTransition: transition
            )
            && videoForHold != nil

        if !videoOnlyEligible, let fallback {
            publishProgramOutputFrame(
                buffer: fallback,
                now: now,
                outputMode: outputMode,
                contract: contract,
                frameRevision: snapshot.revision,
                rememberStreamSnapshot: true
            )
            return true
        }

        ProShowQueues.metalRenderQueue.async { [weak self] in
            let buffer = ProgramOutputComposer.shared.makeStreamHoldFrame(
                stack: stackForHold,
                width: deliverWidth,
                height: deliverHeight,
                video: videoForHold,
                pip: pipForHold,
                videoFrame: frameForHold,
                propCanvases: props,
                programTransition: transition,
                fallback: fallback,
                suppressVideoOnlyBlit: suppressVideoOnlyBlit
            ) ?? fallback
            guard let buffer else { return }
            Task { @MainActor in
                self?.publishProgramOutputFrame(
                    buffer: buffer,
                    now: now,
                    outputMode: outputMode,
                    contract: contract,
                    frameRevision: snapshot.revision,
                    rememberStreamSnapshot: true
                )
            }
        }
        return true
    }

    private func publishProgramOutputFrame(
        buffer: CVPixelBuffer,
        now: Date,
        outputMode: ProgramOutputMode,
        contract: ProgramRenderContract,
        frameRevision: UInt64,
        rememberStreamSnapshot: Bool
    ) {
        if rememberStreamSnapshot {
            rememberLastPublishedStreamFrame(buffer)
        }
        ProgramOutputBus.shared.publish(payload: ProgramOutputBus.FramePayload(
            pixelBuffer: buffer,
            presentationTime: now.timeIntervalSinceReferenceDate,
            hostTime: CMClockGetTime(CMClockGetHostTimeClock()),
            mode: outputMode,
            renderContract: contract,
            frameRevision: frameRevision
        ))
    }

    private func resolvedStreamFallbackSnapshot() -> CVPixelBuffer? {
        if let last = LastPublishedStreamFrame.current() { return last }
        guard let current = compositor.programOutput.current() else { return nil }
        let snap = ProgramOutputComposer.snapshot(current)
        LastPublishedStreamFrame.remember(snap)
        return snap
    }

    private func rememberLastPublishedStreamFrame(_ buffer: CVPixelBuffer) {
        LastPublishedStreamFrame.remember(buffer)
    }

    #if canImport(CoreVideo)
    private func mergePendingProgramOutputWhileCompositeBusy(
        stack: RenderStack,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        media: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?,
        now: Date,
        snapshot: ProgramRenderSnapshot,
        outputMode: ProgramOutputMode
    ) {
        let contract = currentProgramRenderContract()
        let activePropCanvases = compositor.propCanvases.filter { stack.activeProps.contains($0.name) }
        let buildClock = liveBuildClock()
        let slideEncodePlayback = BuildAnimationEngine.broadcastPlayback(
            from: buildClock.playback(now: now),
            canvasObjects: stack.slideCanvas
        )
        var propBuildPlayback: [UUID: BuildPlayback] = [:]
        for canvas in activePropCanvases {
            let propLive = propEncodePlayback(for: canvas, now: now)
            propBuildPlayback[canvas.id] = BuildAnimationEngine.broadcastPlayback(
                from: propLive,
                canvasObjects: canvas.objects
            )
        }
        let objectLivePixels = programObjectLivePixelsForEncode(
            stack: stack,
            programVideo: video,
            propCanvases: activePropCanvases,
            inFlight: true
        )
        if var existing = pendingProgramOutput {
            existing.stack = stack
            existing.video = video
            existing.pip = pip
            existing.media = media
            existing.videoFrame = videoFrame
            existing.textContext = snapshot.dynamicText
            existing.propCanvases = activePropCanvases
            existing.objectLivePixels = objectLivePixels
            existing.buildPlayback = slideEncodePlayback
            existing.buildPhaseFilter = slideLeaveStartedAt != nil ? [.buildOut] : nil
            existing.renderNow = now
            existing.programTransition = compositor.programTransition
            existing.propBuildPlayback = propBuildPlayback
            existing.presentationTime = now.timeIntervalSinceReferenceDate
            existing.hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            existing.frameRevision = snapshot.revision
            pendingProgramOutput = existing
            return
        }
        #if os(macOS)
        let marketStreamItems = MarketDataStreamEngine.shared.items
        let tickerColors = TickerConfigStore.shared.colorConfig
        #else
        let marketStreamItems: [MarketTickerItem] = []
        let tickerColors = TickerColorConfig()
        #endif
        pendingProgramOutput = ProgramOutputWorkItem(
            stack: stack,
            compositeWidth: contract.width,
            compositeHeight: contract.height,
            deliverWidth: contract.width,
            deliverHeight: contract.height,
            video: video,
            pip: pip,
            media: media,
            videoFrame: videoFrame,
            textContext: snapshot.dynamicText,
            propCanvases: activePropCanvases,
            objectLivePixels: objectLivePixels,
            buildPlayback: slideEncodePlayback,
            buildPhaseFilter: slideLeaveStartedAt != nil ? [.buildOut] : nil,
            renderNow: now,
            programTransition: compositor.programTransition,
            propBuildPlayback: propBuildPlayback,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColors,
            streamLive: outputMode.isLive,
            captureProgram: outputMode.isRecording,
            presentationTime: now.timeIntervalSinceReferenceDate,
            hostTime: CMClockGetTime(CMClockGetHostTimeClock()),
            audienceSurfaceBuffer: nil,
            outputMode: outputMode,
            renderContract: contract,
            frameRevision: snapshot.revision
        )
    }
    #endif

    private func publishLiveHoldFrame(
        buffer: CVPixelBuffer,
        now: Date,
        outputMode: ProgramOutputMode,
        contract: ProgramRenderContract,
        frameRevision: UInt64
    ) {
        let payload = ProgramOutputBus.FramePayload(
            pixelBuffer: buffer,
            presentationTime: now.timeIntervalSinceReferenceDate,
            hostTime: CMClockGetTime(CMClockGetHostTimeClock()),
            mode: outputMode,
            renderContract: contract,
            frameRevision: frameRevision
        )
        ProShowQueues.programClockQueue.async {
            ProgramOutputBus.shared.publish(payload: payload)
        }
    }

    private func drainProgramOutputIfNeeded() {
        guard !programOutputInFlight, let work = pendingProgramOutput else { return }
        pendingProgramOutput = nil
        programOutputInFlight = true
        let store = compositor.programOutput
        let propCanvases = work.propCanvases
        let objectLivePixels = work.objectLivePixels
        let phoneBoard = streaming.phoneEncodeBoard()
        let phonePixels: [UUID: CVPixelBuffer]
        if let phoneBoard {
            var probe = work.stack
            probe.slideCanvas = phoneBoard.objects
            phonePixels = buildProgramObjectLivePixels(
                stack: probe,
                programVideo: work.video,
                propCanvases: []
            )
        } else {
            phonePixels = [:]
        }
        streaming.markLastEncodeSource(.programComposite)
        let suppressStreamFastPath = slideLeaveStartedAt != nil || liveBuildStartedAt != nil
        ProShowQueues.programCompositeQueue.async { [weak self] in
            defer {
                Task { @MainActor in
                    self?.programOutputInFlight = false
                    self?.drainProgramOutputIfNeeded()
                }
            }
            let fallback = store.current()
            let videoOwned = work.video.map(ProgramOutputComposer.snapshot)
            let pipOwned = work.pip.map(ProgramOutputComposer.snapshot)
            let mediaOwned = work.media.map(ProgramOutputComposer.snapshot)
            let useVideoOnlyFastPath = ProgramOutputComposer.eligibleForVideoOnlyStreamEncode(
                stack: work.stack,
                propCanvases: propCanvases,
                programTransition: work.programTransition,
                suppressFastPath: suppressStreamFastPath
            )
            let rendered: (buffer: CVPixelBuffer, covered: [Int])?
            if useVideoOnlyFastPath, videoOwned != nil {
                rendered = ProgramOutputComposer.shared.renderVideoLayerProgramFrame(
                    stack: work.stack,
                    width: work.deliverWidth,
                    height: work.deliverHeight,
                    video: videoOwned,
                    pip: pipOwned,
                    videoFrame: work.videoFrame
                )
            } else {
                rendered = ProgramOutputComposer.shared.render(
                    stack: work.stack,
                    width: work.compositeWidth,
                    height: work.compositeHeight,
                    video: videoOwned,
                    pip: pipOwned,
                    media: mediaOwned,
                    videoFrame: work.videoFrame,
                    textContext: work.textContext,
                    liveVideoForObject: nil,
                    propCanvases: propCanvases,
                    objectLivePixels: objectLivePixels,
                    buildPlayback: work.buildPlayback,
                    buildPhaseFilter: work.buildPhaseFilter,
                    renderNow: work.renderNow,
                    programTransition: work.programTransition,
                    propBuildPlayback: work.propBuildPlayback,
                    marketStreamItems: work.marketStreamItems,
                    tickerColorConfig: work.tickerColorConfig,
                    fallbackBuffer: fallback,
                    matchOnAirVisibility: true
                )
            }
            guard let rendered else {
                if (work.captureProgram || work.streamLive), let fallback {
                    ProgramOutputBus.shared.publish(payload: ProgramOutputBus.FramePayload(
                        pixelBuffer: fallback,
                        presentationTime: work.presentationTime,
                        hostTime: work.hostTime,
                        mode: work.outputMode,
                        renderContract: work.renderContract,
                        frameRevision: work.frameRevision
                    ))
                }
                return
            }
            let delivered = rendered.buffer
            store.set(delivered, coveredLayers: rendered.covered)
            if work.streamLive || work.captureProgram {
                LastPublishedStreamFrame.remember(delivered)
            }
            #if canImport(CoreVideo)
            VideoInvalidationEngine.shared.storeBuffer(
                delivered,
                forKey: ProgramOutputComposer.previewEndpoint,
                revision: work.frameRevision
            )
            #endif
            ProgramOutputBus.shared.publish(payload: ProgramOutputBus.FramePayload(
                pixelBuffer: delivered,
                presentationTime: work.presentationTime,
                hostTime: work.hostTime,
                mode: work.outputMode,
                renderContract: work.renderContract,
                frameRevision: work.frameRevision
            ))
            if let phoneBoard, let phoneFrame = ProgramOutputComposer.shared.renderSlideBoard(
                objects: phoneBoard.objects,
                canvasWidth: phoneBoard.width,
                canvasHeight: phoneBoard.height,
                backgroundEnabled: phoneBoard.backgroundEnabled,
                backgroundHex: phoneBoard.backgroundHex,
                width: PhoneEncodeTemplate.width,
                height: PhoneEncodeTemplate.height,
                textContext: work.textContext,
                objectLivePixels: phonePixels,
                buildPlayback: work.buildPlayback,
                renderNow: work.renderNow,
                marketStreamItems: work.marketStreamItems,
                tickerColorConfig: work.tickerColorConfig
            ) {
                PhoneComposedFrame.shared.store(phoneFrame)
            }
        }
    }
    #endif

    func openAddShot(layerIndex: Int = 0) {
        addShotPurpose = .addToLayer
        addShotLayerIndex = min(max(0, layerIndex), max(masterLayers.count - 1, 0))
        isAddShotOpen = true
    }

    func openAddShotToAssign() {
        addShotPurpose = .assignToSelectedObjects
        isAddShotOpen = true
    }

    func closeAddShot() {
        isAddShotOpen = false
        addShotPurpose = .addToLayer
        addShotReplaceTarget = nil
    }

    func completeAddShot(_ item: DiscoveredSourceItem, asCopy: Bool) {
        if let target = addShotReplaceTarget, !asCopy {
            replaceShotSource(shotID: target.shotID, layerIndex: target.layerIndex, with: item)
            closeAddShot()
            return
        }
        switch addShotPurpose {
        case .addToLayer:
            _ = addShot(item, asCopy: asCopy)
        case .assignToSelectedObjects:
            assignSourceToSelectedEditorObjects(item)
        case .assignRundownProgramSlide:
            break
        }
        closeAddShot()
    }

    func assignSourceToSelectedEditorObjects(_ item: DiscoveredSourceItem) {
        let assignable = editors.selectedObjects.filter(\.acceptsAssignedSource)
        if assignable.isEmpty {
            _ = editors.addObject(editorObjectKind(for: item))
        } else if assignable.count != editors.selectedObjects.count {
            editors.selectedObjectIDs = Set(assignable.map(\.id))
        }
        let mediaID = mediaItem(for: item)?.id
        let assigned = AssignedMediaSource.from(item, mediaItemID: mediaID)
        let existingLetters = editors.selectedObjects.compactMap(\.assignedPlaceholderLetter)
        editors.mutateSelectedObjects { $0.applyAssignedSource(assigned) }
        if item.sourceType == .placeholderSlot, let letter = item.placeholderLetter {
            if placeholderBindings[letter] == nil {
                bindPlaceholder(letter: letter, use: .unmapped)
            }
        } else {
            for letter in existingLetters {
                assignDiscoveredSource(item, toPlaceholder: letter)
            }
        }
        rehydrateFromEditor(persist: true)
        syncPropsFromEditor()
        if item.sourceType.needsMainLayerShot {
            _ = ensureLiveInputOnMainLayer(item)
        }
    }

    func clearAssignedSourceOnSelectedObjects() {
        editors.mutateSelectedObjects { $0.clearAssignedSource() }
        rehydrateFromEditor(persist: true)
        syncPropsFromEditor()
    }

    func toggleEditorObjectAudio(id: UUID) {
        toggleEditorObjectAudio(ids: [id])
    }

    func toggleEditorObjectAudio(ids: [UUID]) {
        editors.toggleAudioMute(ids: ids)
        rehydrateFromEditor(persist: false)
        applyProgramAudioMute()
        tickProgram()
    }

    func setSelectedObjectsAudioMuted(_ muted: Bool) {
        editors.mutateSelectedObjects { $0.audioMuted = muted }
        rehydrateFromEditor(persist: false)
        applyProgramAudioMute()
        tickProgram()
    }

    private func editorObjectKind(for item: DiscoveredSourceItem) -> CanvasObjectKind {
        if editors.kind == .props { return .prop }
        switch item.sourceType {
        case .systemCamera, .ndiSource, .srtStream, .rendezvousGuest, .systemAudioCapture, .systemDisplay, .systemWindow:
            return .videoInput
        case .webPage:
            return .browser
        default:
            return .image
        }
    }

    private func placeholderUse(for item: DiscoveredSourceItem) -> PlaceholderUse {
        switch item.sourceType {
        case .mediaFile, .libraryShow: .media
        case .systemCamera, .ndiSource, .srtStream, .rendezvousGuest, .systemDisplay, .systemWindow: .camera
        case .solidColor: .screen
        case .placeholderSlot where item.placeholderLetter == nil: .prop
        case .templateLayout: .slide
        default: .media
        }
    }

    @discardableResult
    func addShot(_ item: DiscoveredSourceItem, asCopy: Bool, layerIndex: Int? = nil) -> LayerShot {
        let index = layerIndex ?? addShotLayerIndex
        let clamped = min(max(0, index), max(masterLayers.count - 1, 0))
        if !asCopy, item.sourceType.needsMainLayerShot {
            return upsertLiveShot(item, layerIndex: clamped, goLive: true)
        }
        var source = item
        if asCopy {
            source.id = "\(item.id)-copy-\(UUID().uuidString)"
        }
        let shot = LayerShot(
            name: asCopy ? "\(item.name) Copy" : item.name,
            source: source,
            isCopy: asCopy
        )
        var layers = masterLayers
        layers[clamped].shots.append(shot)
        layers[clamped].liveShotID = shot.id
        masterLayers = layers
        routeAddedShot(shot, goLive: true)
        return shot
    }

    /// Reuse an existing live-input shot on a layer when hardware identity matches (no duplicate rows).
    @discardableResult
    func upsertLiveShot(_ item: DiscoveredSourceItem, layerIndex: Int, goLive: Bool) -> LayerShot {
        let clamped = min(max(0, layerIndex), max(masterLayers.count - 1, 0))
        var layers = masterLayers
        if let existingIndex = layers[clamped].shots.firstIndex(where: { !$0.isCopy && Self.sameLiveInput($0.source, item) }) {
            var shot = layers[clamped].shots[existingIndex]
            let priorSourceName = shot.source.name
            shot.source = mergeLiveSource(stored: shot.source, latest: item)
            if shot.name == priorSourceName {
                shot.name = item.name
            }
            layers[clamped].shots[existingIndex] = shot
            if goLive {
                layers[clamped].liveShotID = shot.id
            }
            masterLayers = layers
            routeAddedShot(shot, goLive: goLive)
            return shot
        }
        let shot = LayerShot(name: item.name, source: item, isCopy: false)
        layers[clamped].shots.append(shot)
        if goLive {
            layers[clamped].liveShotID = shot.id
        }
        masterLayers = layers
        routeAddedShot(shot, goLive: goLive)
        return shot
    }

    @discardableResult
    func ensureLiveInputOnMainLayer(_ item: DiscoveredSourceItem) -> LayerShot? {
        guard item.sourceType.needsMainLayerShot, masterLayers.indices.contains(0) else { return nil }
        return upsertLiveShot(item, layerIndex: 0, goLive: true)
    }

    func ensureSlideLiveInputsOnMainLayer(_ slide: Slide) {
        var items = liveInputItems(on: slide)
        if items.isEmpty,
           resolvedCanvasObjects(slide.canvas).contains(where: { $0.kind == .videoInput }),
           let source = preferredProgramCameraSource() {
            items = [discoveredLiveInput(from: source)]
        }
        for item in items {
            _ = ensureLiveInputOnMainLayer(item)
        }
    }

    /// Thumbnails and rundown previews — start capture without taking a new program cue.
    func prepareSlidePreviewCapture(for slide: Slide) {
        var items = liveInputItems(on: slide)
        if items.isEmpty,
           resolvedCanvasObjects(slide.canvas).contains(where: { $0.kind == .videoInput }),
           let source = preferredProgramCameraSource() {
            items = [discoveredLiveInput(from: source)]
        }
        guard !items.isEmpty else { return }
        for item in items where item.sourceType.needsMainLayerShot {
            _ = upsertLiveShot(item, layerIndex: 0, goLive: false)
            warmLiveCaptureForPreview(item)
        }
        compositor.syncVideoInputs(from: videoInputs)
    }

    func previewVideoInput(for slide: Slide, forThumbnail: Bool = false) -> VideoInputSource? {
        if !forThumbnail, let live = compositor.stack.videoInput { return live }
        for item in liveInputItems(on: slide) {
            if let input = videoInputSource(from: LayerShot(name: item.name, source: item, isCopy: false)) {
                return input
            }
        }
        if resolvedCanvasObjects(slide.canvas).contains(where: { $0.kind == .videoInput }),
           let source = preferredProgramCameraSource() {
            return VideoInputSource(
                id: source.id,
                label: source.label,
                kind: source.kind.videoInputKind,
                endpoint: source.endpoint
            )
        }
        return nil
    }

    private func warmLiveCaptureForPreview(_ item: DiscoveredSourceItem) {
        switch item.sourceType {
        case .systemCamera, .ndiSource, .systemDisplay, .systemWindow:
            enableLiveIO()
            let kind: VideoInputKind = {
                switch item.sourceType {
                case .ndiSource: .ndi
                case .systemDisplay, .systemWindow: .screenShare
                default: .camera
                }
            }()
            let input = VideoInputSource(
                id: HardwareSourceIdentity.uuid(for: item.connectionString ?? item.id),
                label: item.name,
                kind: kind,
                endpoint: item.connectionString
            )
            videoInputs.register(
                StudioVideoSource(
                    id: input.id,
                    label: input.label,
                    kind: StudioVideoKind(videoInput: kind),
                    endpoint: input.endpoint
                )
            )
            videoInputs.rearmLiveCapture(for: input)
        default:
            break
        }
    }

    /// Default live camera for outline `.program` slides with an unassigned video region.
    func preferredProgramCameraSource() -> StudioVideoSource? {
        videoInputs.sources.first { $0.kind != .screenShare }
    }

    private func liveInputItems(on slide: Slide) -> [DiscoveredSourceItem] {
        var items: [DiscoveredSourceItem] = []
        func append(_ item: DiscoveredSourceItem) {
            guard item.sourceType.needsMainLayerShot else { return }
            if !items.contains(where: { Self.sameLiveInput($0, item) }) {
                items.append(item)
            }
        }
        for object in resolvedCanvasObjects(slide.canvas) {
            if let assigned = object.assignedSource {
                append(assigned.asDiscoveredItem())
            }
        }
        if let action = slide.mediaAction, !action.clearsLayer {
            if let media = allMediaItems.first(where: {
                $0.id == action.id || $0.title.caseInsensitiveCompare(action.title) == .orderedSame
            }), let item = discoveredLiveInput(from: media) {
                append(item)
            } else if let item = discoveredLiveInput(from: action) {
                append(item)
            }
        }
        return items
    }

    private func discoveredLiveInput(from item: MediaBinItem) -> DiscoveredSourceItem? {
        switch item.kind {
        case .camera(let label):
            if let video = videoInputs.sources.first(where: { $0.id == item.id || $0.label == label }) {
                return discoveredLiveInput(from: video)
            }
            return DiscoveredSourceItem(
                id: item.id.uuidString,
                name: label,
                category: .videoCapture,
                groupName: "Video Inputs",
                sourceType: .systemCamera,
                connectionString: item.filePath,
                tintHex: item.tintHex
            )
        case .microphone(let label):
            return DiscoveredSourceItem(
                id: item.id.uuidString,
                name: label,
                category: .audioCapture,
                groupName: "Audio Inputs",
                sourceType: .systemMicrophone,
                connectionString: item.filePath,
                tintHex: item.tintHex
            )
        default:
            return discoveredLiveInput(fromMediaPath: item.filePath, title: item.title, id: item.id.uuidString)
        }
    }

    private func discoveredLiveInput(from action: MediaAction) -> DiscoveredSourceItem? {
        discoveredLiveInput(fromMediaPath: action.filePath, title: action.title, id: action.id.uuidString)
    }

    private func discoveredLiveInput(from source: StudioVideoSource) -> DiscoveredSourceItem {
        let type = Self.sourceType(for: source.kind)
        return DiscoveredSourceItem(
            id: source.endpoint ?? source.id.uuidString,
            name: source.label,
            category: type == .systemDisplay || type == .systemWindow ? .screenCapture : .videoCapture,
            groupName: type == .systemDisplay ? "Displays" : "System Device",
            sourceType: type,
            connectionString: source.endpoint
        )
    }

    private func discoveredLiveInput(fromMediaPath path: String?, title: String, id: String) -> DiscoveredSourceItem? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("avf://") {
            return DiscoveredSourceItem(
                id: "avf-video-\(path.dropFirst("avf://".count))",
                name: title,
                category: .videoCapture,
                groupName: "System Device",
                sourceType: .systemCamera,
                connectionString: path
            )
        }
        if path.hasPrefix("sck://display/") {
            return DiscoveredSourceItem(
                id: "sck-display-\(path.dropFirst("sck://display/".count))",
                name: title,
                category: .screenCapture,
                groupName: "Displays",
                sourceType: .systemDisplay,
                connectionString: path
            )
        }
        if path.hasPrefix("sck://window/") {
            return DiscoveredSourceItem(
                id: "sck-window-\(path.dropFirst("sck://window/".count))",
                name: title,
                category: .screenCapture,
                groupName: "Windows",
                sourceType: .systemWindow,
                connectionString: path
            )
        }
        if path.hasPrefix("ndi://") {
            return DiscoveredSourceItem(
                id: id,
                name: title,
                category: .network,
                groupName: "NDI™ Source",
                sourceType: .ndiSource,
                connectionString: path
            )
        }
        return nil
    }

    private static func sameLiveInput(_ lhs: DiscoveredSourceItem, _ rhs: DiscoveredSourceItem) -> Bool {
        if let left = lhs.connectionString, let right = rhs.connectionString, !left.isEmpty, left == right {
            return true
        }
        if lhs.id == rhs.id { return true }
        if lhs.sourceType == .systemCamera, rhs.sourceType == .systemCamera {
            return CameraIdentity.isSameCamera(
                endpointA: lhs.connectionString,
                nameA: lhs.name,
                endpointB: rhs.connectionString,
                nameB: rhs.name
            )
        }
        return false
    }

    private func mergeLiveSource(stored: DiscoveredSourceItem, latest: DiscoveredSourceItem) -> DiscoveredSourceItem {
        var merged = stored
        merged.id = latest.id
        merged.name = latest.name
        merged.category = latest.category
        merged.groupName = latest.groupName
        merged.sourceType = latest.sourceType
        if let connection = latest.connectionString, !connection.isEmpty {
            merged.connectionString = connection
        }
        if let tint = latest.tintHex {
            merged.tintHex = tint
        }
        return merged
    }

    func latestDiscoveredItem(matching item: DiscoveredSourceItem) -> DiscoveredSourceItem? {
        if item.sourceType == .systemCamera {
            if let video = videoInputs.sources.first(where: { source in
                CameraIdentity.isSameCamera(
                    endpointA: source.endpoint,
                    nameA: source.label,
                    endpointB: item.connectionString,
                    nameB: item.name
                )
            }) {
                return discoveredLiveInput(from: video)
            }
        }
        if let endpoint = item.connectionString, !endpoint.isEmpty,
           let video = videoInputs.sources.first(where: { $0.endpoint == endpoint }) {
            return discoveredLiveInput(from: video)
        }
        if let video = videoInputs.sources.first(where: { $0.id.uuidString == item.id || $0.label == item.name }) {
            return discoveredLiveInput(from: video)
        }
        return nil
    }

    func refreshLiveShot(_ shotID: UUID, layerIndex: Int) {
        guard masterLayers.indices.contains(layerIndex),
              masterLayers[layerIndex].shots.contains(where: { $0.id == shotID }) else { return }
        enableLiveIO()
        videoInputs.refreshDevices()
        var layers = masterLayers
        guard let shotIndex = layers[layerIndex].shots.firstIndex(where: { $0.id == shotID }) else { return }
        var shot = layers[layerIndex].shots[shotIndex]
        let priorSourceName = shot.source.name
        if let latest = latestDiscoveredItem(matching: shot.source) {
            shot.source = mergeLiveSource(stored: shot.source, latest: latest)
            if shot.name == priorSourceName {
                shot.name = latest.name
            }
        }
        layers[layerIndex].shots[shotIndex] = shot
        masterLayers = layers
        let isLive = layers[layerIndex].liveShotID == shotID
        if isLive {
            routeAddedShot(shot, goLive: true)
        }
        compositor.syncVideoInputs(from: videoInputs)
        refreshPlaceholderRoutes()
    }

    func renameShot(_ shotID: UUID, layerIndex: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, masterLayers.indices.contains(layerIndex) else { return }
        var layers = masterLayers
        guard let index = layers[layerIndex].shots.firstIndex(where: { $0.id == shotID }) else { return }
        layers[layerIndex].shots[index].name = trimmed
        masterLayers = layers
    }

    func duplicateShot(_ shotID: UUID, layerIndex: Int) {
        guard masterLayers.indices.contains(layerIndex),
              let shot = masterLayers[layerIndex].shots.first(where: { $0.id == shotID }) else { return }
        _ = addShot(shot.source, asCopy: true, layerIndex: layerIndex)
    }

    func openReplaceShot(shotID: UUID, layerIndex: Int) {
        addShotReplaceTarget = (shotID, layerIndex)
        addShotPurpose = .addToLayer
        addShotLayerIndex = min(max(0, layerIndex), max(masterLayers.count - 1, 0))
        isAddShotOpen = true
    }

    func replaceShotSource(shotID: UUID, layerIndex: Int, with item: DiscoveredSourceItem) {
        guard masterLayers.indices.contains(layerIndex) else { return }
        var layers = masterLayers
        guard let index = layers[layerIndex].shots.firstIndex(where: { $0.id == shotID }) else { return }
        var shot = layers[layerIndex].shots[index]
        let priorLabel = shot.name
        let priorSourceName = shot.source.name
        shot.source = item
        if priorLabel == priorSourceName || priorLabel.isEmpty {
            shot.name = item.name
        }
        layers[layerIndex].shots[index] = shot
        let wasLive = layers[layerIndex].liveShotID == shotID
        masterLayers = layers
        if item.sourceType.needsMainLayerShot {
            _ = dedupeLiveShots(onLayer: layerIndex, keeping: shotID)
        }
        if wasLive {
            takeShotLive(shot, layerIndex: layerIndex)
        }
    }

    /// Collapse duplicate live-input shots after replace/rescan (keeps `keepID` if provided).
    @discardableResult
    private func dedupeLiveShots(onLayer layerIndex: Int, keeping keepID: UUID? = nil) -> Int {
        guard masterLayers.indices.contains(layerIndex) else { return 0 }
        var layers = masterLayers
        var kept: [LayerShot] = []
        var removed = 0
        for shot in layers[layerIndex].shots {
            if shot.isCopy {
                kept.append(shot)
                continue
            }
            if let matchIndex = kept.firstIndex(where: { !$0.isCopy && Self.sameLiveInput($0.source, shot.source) }) {
                if keepID == shot.id {
                    kept[matchIndex] = shot
                } else if keepID == kept[matchIndex].id {
                    removed += 1
                } else {
                    removed += 1
                    if layers[layerIndex].liveShotID == shot.id {
                        layers[layerIndex].liveShotID = kept[matchIndex].id
                    }
                }
            } else {
                kept.append(shot)
            }
        }
        if removed > 0 {
            layers[layerIndex].shots = kept
            masterLayers = layers
        }
        return removed
    }

    private func isLiveInputRunning(_ item: DiscoveredSourceItem) -> Bool {
        guard item.sourceType.needsMainLayerShot else { return false }
        if item.sourceType == .systemCamera {
            return videoInputs.hasLiveCamera(endpoint: item.connectionString, sourceID: item.id, name: item.name)
        }
        return videoInputs.isRunning(endpoint: item.connectionString, sourceID: item.id)
    }

    func takeShotLive(_ shot: LayerShot, layerIndex: Int) {
        guard masterLayers.indices.contains(layerIndex) else { return }
        var layers = masterLayers
        layers[layerIndex].liveShotID = shot.id
        masterLayers = layers
        routeAddedShot(shot, goLive: true)
        reconcileAudioCaptureGraph()
    }

    func selectMasterLayer(at index: Int) {
        addShotLayerIndex = min(max(0, index), max(masterLayers.count - 1, 0))
    }

    func renameMasterLayer(at index: Int, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard masterLayers.indices.contains(index), !trimmed.isEmpty else { return }
        var layers = masterLayers
        layers[index].title = trimmed
        masterLayers = layers
        refreshPlaceholderRoutes()
    }

    func clearLiveShot(layerIndex: Int) {
        guard masterLayers.indices.contains(layerIndex) else { return }
        var layers = masterLayers
        layers[layerIndex].liveShotID = nil
        masterLayers = layers
        reconcileAudioCaptureGraph()
    }

    func removeShot(_ shotID: UUID, layerIndex: Int) {
        guard masterLayers.indices.contains(layerIndex) else { return }
        var layers = masterLayers
        layers[layerIndex].shots.removeAll { $0.id == shotID }
        if layers[layerIndex].liveShotID == shotID {
            layers[layerIndex].liveShotID = nil
        }
        masterLayers = layers
        reconcileAudioCaptureGraph()
    }

    private func routeAddedShot(_ shot: LayerShot, goLive: Bool = false) {
        let source = shot.source
        switch source.sourceType {
        case .systemCamera, .ndiSource, .systemDisplay, .systemWindow:
            enableLiveIO()
            let kind: VideoInputKind = {
                switch source.sourceType {
                case .ndiSource: .ndi
                case .systemDisplay, .systemWindow: .screenShare
                default: .camera
                }
            }()
            let input = VideoInputSource(
                id: HardwareSourceIdentity.uuid(for: source.connectionString ?? source.id),
                label: source.name,
                kind: kind,
                endpoint: source.connectionString
            )
            videoInputs.register(
                StudioVideoSource(
                    id: input.id,
                    label: input.label,
                    kind: StudioVideoKind(videoInput: kind),
                    endpoint: input.endpoint
                )
            )
            if goLive {
                activateVideoInput(input)
            }
            if goLive {
                reconcileAudioCaptureGraph()
            }
        case .systemAudioCapture:
            enableLiveIO()
            if goLive {
                audioMatrix.duckingEnabled = true
                ensureSystemDesktopAudioCapture()
            }
        case .mediaFile:
            if let item = mediaItem(for: source) {
                if goLive { triggerMedia(item, takeProgram: true) }
            } else if let path = source.connectionString {
                let url = URL(fileURLWithPath: path)
                if let imported = importMedia(url: url), goLive {
                    triggerMedia(imported, takeProgram: true)
                }
            }
        case .libraryShow:
            if goLive, let token = source.connectionString {
                if let id = UUID(uuidString: token), libraryShows.contains(where: { $0.id == id }) {
                    loadPresentation(id: id)
                } else {
                    selectedPlaylistItemTitle = source.name
                }
            }
        case .solidColor:
            let hex = source.connectionString ?? source.tintHex ?? "#000000"
            compositor.setScreenColor(hex)
            if goLive {
                compositor.triggerCue(
                    OutputCue(
                        id: shot.id,
                        presentationId: show.id,
                        slideIndex: liveIndex ?? 0,
                        layers: CueLayers(
                            mediaAction: MediaAction(
                                id: shot.id,
                                title: source.name,
                                tintHex: hex,
                                isImage: false
                            )
                        )
                    )
                )
                bindLiveMedia()
            }
        case .placeholderSlot:
            if let letter = source.placeholderLetter {
                if placeholderBindings[letter] == nil {
                    bindPlaceholder(letter: letter, use: .unmapped)
                }
                if let binding = placeholderBindings[letter], binding.use != .unmapped {
                    applyPlaceholderBinding(binding, goLive: goLive)
                } else if goLive {
                    takeUnmappedPlaceholderLive(letter: letter, source: source, shot: shot)
                }
            }
            if goLive, inspector.props.contains(where: { $0.name == source.name }) {
                compositor.toggleProp(source.name)
            }
        case .rendezvousGuest, .srtStream, .webPage:
            videoInputs.register(
                StudioVideoSource(
                    label: source.name,
                    kind: source.sourceType == .webPage ? .webrtc : .rtsp,
                    endpoint: source.connectionString
                )
            )
        case .systemMicrophone:
            enableLiveIO()
            if goLive {
                activateDedicatedMicrophone(shot.source)
            }
        case .templateLayout:
            break
        }
    }

    func activateDedicatedMicrophone(_ item: DiscoveredSourceItem) {
        enableLiveIO()
        AudioMatrixReconciler.enforceProgramAudioGates(controller: self)
        let endpoint = item.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if endpoint.isEmpty {
            audioIO.startCaptureIfNeeded()
            return
        }
        videoInputs.startDedicatedMicrophone(endpoint: endpoint, label: item.name)
    }

    private func ensureSystemDesktopAudioCapture() {
        let display = StudioVideoSource(
            id: StudioSeedID.screen,
            label: "System Audio",
            kind: .screenShare,
            endpoint: "sck://display/0"
        )
        _ = videoInputs.ingest.start(display)
    }

    @discardableResult
    func addSolidColor(name: String, hex: String) -> SolidColorSwatch {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.hasPrefix("#") { cleaned = "#\(cleaned)" }
        let swatch = SolidColorSwatch(
            id: "color-custom-\(UUID().uuidString)",
            name: trimmed.isEmpty ? cleaned.uppercased() : trimmed,
            hex: cleaned.uppercased()
        )
        customSolidColors.append(swatch)
        return swatch
    }

    func resolvedAssignedSource(forPlaceholder letter: String) -> AssignedMediaSource? {
        guard let placeholder = placeholderMatrix.placeholders.first(where: { $0.letter.uppercased() == letter.uppercased() }) else { return nil }
        var source = assignedSource(for: placeholder)
        guard source.sourceType != .placeholderSlot else { return nil }
        if placeholder.isAudioMuted {
            source.audioMuted = true
        }
        return source
    }

    func isPlaceholderAudioMuted(_ letter: String?) -> Bool {
        guard let letter, !letter.isEmpty else { return false }
        return placeholderMatrix.placeholders.first(where: { $0.letter.uppercased() == letter.uppercased() })?.isAudioMuted == true
    }

    func togglePlaceholderAudio(id: String) {
        updatePlaceholder(id) { $0.audioMuted = !($0.audioMuted == true) }
        applyProgramAudioMute()
        tickProgram()
    }

    func isProgramLayerAudioMuted(_ layer: RenderLayer) -> Bool {
        compositor.isLayerAudioMuted(layer)
    }

    func toggleProgramLayerAudio(_ layer: RenderLayer) {
        compositor.toggleLayerAudio(layer)
        if layer == .videoInput {
            let muted = compositor.isLayerAudioMuted(.videoInput)
            syncLiveShotsAudioMutedForProgramVideoInput()
            if muted {
                if let shot = primaryLiveHardwareShotMatchingProgramVideoInput() {
                    applyHardwareCaptureAudioMute(for: shot, muted: true)
                } else {
                    silenceProgramVideoInputHardwareCapture()
                }
            } else {
                unmuteProgramVideoInputHardwareMatrix()
                if let shot = primaryLiveHardwareShotMatchingProgramVideoInput() {
                    restoreLiveShotHardwareAudio(for: shot)
                }
            }
            reconcileAudioCaptureGraph()
        }
        applyProgramAudioMute()
        ProgramStreamAudioGates.sync(from: audioMatrix)
        tickProgram()
    }

    func canMuteProgramLayer(_ layer: RenderLayer) -> Bool {
        guard layer.carriesAudio, !compositor.stack.isCleared(layer) else { return false }
        switch layer {
        case .media:
            guard let media = compositor.stack.media else { return false }
            return !media.isImage && !media.clearsLayer
        case .videoInput:
            return compositor.stack.videoInput != nil
        case .slide:
            return playback.hasProgramClock && compositor.stack.media != nil
        case .props:
            return !compositor.stack.activeProps.isEmpty
        default:
            return layer.hasContent(in: compositor.stack)
        }
    }

    func renderLayerForProgramElement(_ elementID: UUID) -> RenderLayer? {
        guard let row = programLayerRow(id: elementID) else { return nil }
        switch row.target {
        case .programMedia: return .media
        case .programVideoInput: return .videoInput
        case .slideLyric, .slideCanvasObject: return .slide
        case .propCanvasObject, .activeProp: return .props
        case .outputMessage: return .messages
        }
    }

    func toggleProgramElementAudio(id elementID: UUID) {
        guard let layer = renderLayerForProgramElement(elementID), canMuteProgramLayer(layer) else { return }
        toggleProgramLayerAudio(layer)
    }

    func masterLayerLiveShotCarriesAudio(layerIndex: Int) -> Bool {
        guard masterLayers.indices.contains(layerIndex),
              let liveID = masterLayers[layerIndex].liveShotID,
              let shot = masterLayers[layerIndex].shots.first(where: { $0.id == liveID })
        else { return false }
        return liveShotSourceCarriesAudio(shot.source)
    }

    func isLiveShotAudioMuted(layerIndex: Int) -> Bool {
        guard masterLayers.indices.contains(layerIndex),
              let liveID = masterLayers[layerIndex].liveShotID,
              let shot = masterLayers[layerIndex].shots.first(where: { $0.id == liveID })
        else { return false }
        return shot.isAudioMuted
    }

    func toggleLiveShotAudio(layerIndex: Int) {
        guard masterLayers.indices.contains(layerIndex),
              let liveID = masterLayers[layerIndex].liveShotID,
              let shotIndex = masterLayers[layerIndex].shots.firstIndex(where: { $0.id == liveID })
        else { return }
        guard liveShotSourceCarriesAudio(masterLayers[layerIndex].shots[shotIndex].source) else { return }
        var layers = masterLayers
        let muted = !(layers[layerIndex].shots[shotIndex].audioMuted == true)
        layers[layerIndex].shots[shotIndex].audioMuted = muted
        masterLayers = layers
        let shot = layers[layerIndex].shots[shotIndex]
        if shot.source.sourceType.needsMainLayerShot {
            compositor.setLayerAudioMuted(.videoInput, muted: muted)
        }
        applyHardwareCaptureAudioMute(for: shot, muted: muted)
        if muted {
            applyProgramAudioMute()
            reconcileAudioCaptureGraph()
        } else {
            restoreLiveShotHardwareAudio(for: shot)
            applyProgramAudioMute()
            reconcileAudioCaptureGraph()
        }
        ProgramStreamAudioGates.sync(from: audioMatrix)
        tickProgram()
    }

    private func setLiveShotAudioMuted(layerIndex: Int, muted: Bool) {
        guard masterLayers.indices.contains(layerIndex),
              let liveID = masterLayers[layerIndex].liveShotID,
              let shotIndex = masterLayers[layerIndex].shots.firstIndex(where: { $0.id == liveID })
        else { return }
        var layers = masterLayers
        layers[layerIndex].shots[shotIndex].audioMuted = muted
        masterLayers = layers
    }

    private func syncLiveShotsAudioMutedForProgramVideoInput() {
        let muted = compositor.isLayerAudioMuted(.videoInput)
        for (index, layer) in masterLayers.enumerated() {
            guard let liveID = layer.liveShotID,
                  let shot = layer.shots.first(where: { $0.id == liveID }),
                  shot.source.sourceType.needsMainLayerShot
            else { continue }
            setLiveShotAudioMuted(layerIndex: index, muted: muted)
        }
    }

    private func primaryLiveHardwareShotMatchingProgramVideoInput() -> LayerShot? {
        guard compositor.stack.videoInput != nil else { return nil }
        for layer in masterLayers {
            guard let liveID = layer.liveShotID,
                  let shot = layer.shots.first(where: { $0.id == liveID }),
                  shot.source.sourceType.needsMainLayerShot,
                  liveShotFeedsProgramVideoInput(shot)
            else { continue }
            return shot
        }
        return nil
    }

    private func liveShotFeedsProgramVideoInput(_ shot: LayerShot) -> Bool {
        guard let input = compositor.stack.videoInput else { return false }
        if let endpoint = shot.source.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines),
           !endpoint.isEmpty,
           let inputEndpoint = input.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !inputEndpoint.isEmpty,
           endpoint == inputEndpoint {
            return true
        }
        if let shotID = UUID(uuidString: shot.source.id), shotID == input.id { return true }
        return shot.source.name == input.label
    }

    private func applyHardwareCaptureAudioMute(for shot: LayerShot, muted: Bool) {
        guard let role = hardwareCaptureRole(for: shot.source.sourceType) else { return }
        if let channel = audioMatrix.channel(role: role) {
            audioMatrix.setMute(id: channel.id, muted: muted)
        }
    }

    private func liveShotSourceCarriesAudio(_ source: DiscoveredSourceItem) -> Bool {
        switch source.sourceType {
        case .systemMicrophone, .systemDisplay, .systemWindow, .systemAudioCapture,
             .ndiSource, .srtStream, .mediaFile, .libraryShow:
            return true
        default:
            return false
        }
    }

    private func videoInputSource(from shot: LayerShot) -> VideoInputSource? {
        let source = shot.source
        guard source.sourceType.needsMainLayerShot else { return nil }
        let kind: VideoInputKind = {
            switch source.sourceType {
            case .ndiSource: return .ndi
            case .systemDisplay, .systemWindow: return .screenShare
            default: return .camera
            }
        }()
        return VideoInputSource(
            id: HardwareSourceIdentity.uuid(for: source.connectionString ?? source.id),
            label: source.name,
            kind: kind,
            endpoint: source.connectionString
        )
    }

    private func restoreLiveShotHardwareAudio(for shot: LayerShot) {
        guard liveShotSourceCarriesAudio(shot.source) else { return }
        enableLiveIO()
        if let input = videoInputSource(from: shot) {
            videoInputs.register(
                StudioVideoSource(
                    id: input.id,
                    label: input.label,
                    kind: StudioVideoKind(videoInput: input.kind),
                    endpoint: input.endpoint
                )
            )
            videoInputs.rearmLiveCapture(for: input)
        }
        if let role = hardwareCaptureRole(for: shot.source.sourceType) {
            ProgramStreamAudioGates.setHardwareCaptureOpen(role, open: true)
        }
    }

    private func hardwareCaptureRole(for sourceType: SourceType) -> AudioChannelRole? {
        switch sourceType {
        case .systemMicrophone:
            // Camera layers carry no audio; the Mic channel belongs to Mic layers only.
            return .microphone
        case .systemDisplay, .systemWindow, .systemAudioCapture:
            return .desktop
        default:
            return nil
        }
    }

    private func silenceProgramVideoInputHardwareCapture() {
        for role in [AudioChannelRole.microphone, .desktop] {
            audioMatrix.channel(role: role).map { audioMatrix.setMute(id: $0.id, muted: true) }
        }
    }

    private func unmuteProgramVideoInputHardwareMatrix() {
        for role in [AudioChannelRole.microphone, .desktop] {
            audioMatrix.channel(role: role).map { audioMatrix.setMute(id: $0.id, muted: false) }
        }
    }

    func applyProgramAudioMute() {
        playback.setMuted(isProgramMediaMuted)
    }

    private func syncLiveAudioCapture() {
        // Only an explicit, unmuted, live mic shot without a device endpoint uses the system input tap.
        if audioIO.hardwareEnabled, liveMicrophoneShots().contains(where: { micEndpoint($0).isEmpty }) {
            audioIO.startCaptureIfNeeded()
            return
        }
        audioIO.stopCapture()
    }

    private func micEndpoint(_ shot: LayerShot) -> String {
        shot.source.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Live, unmuted microphone shots on the program layers.
    func liveMicrophoneShots() -> [LayerShot] {
        masterLayers.compactMap { layer in
            guard let liveID = layer.liveShotID,
                  let shot = layer.shots.first(where: { $0.id == liveID }),
                  shot.source.sourceType == .systemMicrophone,
                  !shot.isAudioMuted
            else { return nil }
            return shot
        }
    }

    /// True when a mic is reaching program, room and stream. Drives the tally pill.
    var isProgramMicLive: Bool {
        ProgramAudioGatePolicy.derive(from: masterLayers).microphone && !audioIO.programMuted
    }

    func resumeLiveMicrophoneCapture() {
        for shot in liveMicrophoneShots() {
            let endpoint = micEndpoint(shot)
            if endpoint.isEmpty {
                audioIO.startCaptureIfNeeded()
            } else {
                videoInputs.startDedicatedMicrophone(endpoint: endpoint, label: shot.source.name)
            }
        }
    }

    func reconcileAudioCaptureGraph() {
        AudioMatrixReconciler.reconcile(controller: self)
        syncLiveAudioCapture()
    }

    func refreshAndFlushAudioDevices() {
        videoInputs.refreshDevices()
        AudioMatrixReconciler.purgeAllPCMQueues()
        ProgramStreamAudioGates.setHardwareCaptureOpen(.microphone, open: false)
        ProgramStreamAudioGates.setHardwareCaptureOpen(.desktop, open: false)
        ProgramPCMBridge.clearMonitorRing()
        audioIO.stopCapture()
        AudioMatrixReconciler.reconcile(controller: self)
        syncLiveAudioCapture()
        noteProgramMutation()
        tickProgram()
    }

    func detachHardwareAudio(for role: AudioChannelRole) {
        switch role {
        case .microphone:
            for key in videoInputs.ingest.liveCaptureLaneKeys() where key.hasPrefix("avf://") || key.hasPrefix("audio:") {
                videoInputs.ingest.stopAudioCapture(endpoint: key, sourceID: nil)
            }
            audioIO.stopCapture()
        case .desktop:
            for key in videoInputs.ingest.liveCaptureLaneKeys() where key.hasPrefix("sck://") {
                videoInputs.ingest.stopAudioCapture(endpoint: key, sourceID: nil)
            }
        case .guest, .slide, .soundboard:
            break
        }
        if let channel = audioMatrix.channel(role: role) {
            audioMatrix.setMute(id: channel.id, muted: true)
        }
        ProgramStreamAudioGates.flushCaptureRole(role)
        syncLiveAudioCapture()
        tickProgram()
    }

    var isProgramMediaMuted: Bool {
        if audioIO.programMuted || compositor.stack.audioMuted { return true }
        if compositor.isLayerAudioMuted(.media) { return true }
        // Slide layer mute silences slide audio when no media layer owns playback.
        if compositor.isLayerAudioMuted(.slide), compositor.stack.media == nil || compositor.stack.isCleared(.media) {
            return true
        }
        if compositor.stack.isCleared(.media) {
            if let media = compositor.stack.media, !media.clearsLayer, !media.isAudioMuted,
               !compositor.isLayerAudioMuted(.media) {
                return false
            }
            let slideCarriesProgramAudio = liveSlide != nil
                && playback.hasProgramClock
                && !compositor.stack.isCleared(.slide)
                && isAudienceOutputOn
                && !isAudienceCleared
            if !slideCarriesProgramAudio { return true }
        }
        if let media = compositor.stack.media {
            if media.isAudioMuted { return true }
            if isPlaceholderAudioMuted(media.placeholderLetter) { return true }
            if liveMutedShotFeeds(media) { return true }
        }
        return false
    }

    private func liveMutedShotFeeds(_ media: MediaAction) -> Bool {
        masterLayers.contains { layer in
            guard let liveID = layer.liveShotID,
                  let shot = layer.shots.first(where: { $0.id == liveID }),
                  shot.isAudioMuted
            else { return false }
            if let letter = media.placeholderLetter, shot.source.placeholderLetter == letter { return true }
            if let path = media.filePath, shot.source.connectionString == path { return true }
            return false
        }
    }

    func mappedMedia(forPlaceholder letter: String) -> MediaBinItem? {
        guard let binding = placeholderBindings[letter.uppercased()],
              binding.use == .media || binding.use == .camera,
              let targetID = binding.targetID
        else { return nil }
        if let uuid = UUID(uuidString: targetID) {
            return allMediaItems.first { $0.id == uuid }
        }
        return allMediaItems.first { $0.id.uuidString == targetID }
    }

    func assignDiscoveredSource(_ item: DiscoveredSourceItem, toPlaceholder letter: String) {
        guard let target = placeholderTargetID(for: item) else { return }
        bindPlaceholder(
            letter: letter,
            use: placeholderUse(for: item),
            targetID: target,
            targetName: item.name
        )
        if let placeholder = placeholderMatrix.placeholders.first(where: { $0.letter.uppercased() == letter.uppercased() }) {
            propagatePlaceholderMapping(placeholder)
        }
    }

    func bindPlaceholder(letter: String, use: PlaceholderUse, targetID: String? = nil, targetName: String? = nil) {
        let key = letter.uppercased()
        let resolvedTarget = targetID.flatMap { canonicalPlaceholderTargetID($0) } ?? targetID
        placeholderBindings[key] = PlaceholderBinding(
            letter: key,
            use: use,
            targetID: resolvedTarget,
            targetName: targetName
        )
        guard let index = placeholderMatrix.placeholders.firstIndex(where: { $0.letter.uppercased() == key }) else { return }
        let nextSource = (use == .unmapped) ? nil : resolvedTarget
        let previous = placeholderMatrix.placeholders[index].primarySourceId
        var placeholder = placeholderMatrix.placeholders[index]
        placeholder.primarySourceId = nextSource
        placeholderMatrix.placeholders[index] = placeholder
        guard previous != nextSource else { return }
        propagatePlaceholderMapping(placeholder)
    }

    private func placeholderTargetID(for item: DiscoveredSourceItem) -> String? {
        if let video = videoSource(matching: item.id) ?? item.connectionString.flatMap({ videoSource(matching: $0) }) {
            return video.id.uuidString
        }
        if let mediaID = mediaItem(for: item)?.id {
            return mediaID.uuidString
        }
        if UUID(uuidString: item.id) != nil {
            return item.id
        }
        return item.connectionString
    }

    private func canonicalPlaceholderTargetID(_ sourceID: String) -> String? {
        if let video = videoSource(matching: sourceID) {
            return video.id.uuidString
        }
        if let uuid = UUID(uuidString: sourceID), allMediaItems.contains(where: { $0.id == uuid }) {
            return uuid.uuidString
        }
        return nil
    }

    private func videoSource(matching sourceID: String) -> StudioVideoSource? {
        if let uuid = UUID(uuidString: sourceID),
           let video = videoInputs.sources.first(where: { $0.id == uuid }) {
            return video
        }
        return videoInputs.sources.first { source in
            source.endpoint == sourceID || source.id.uuidString == sourceID
        }
    }

    var placeholderSourceChoices: [PlaceholderSourceChoice] {
        var seen = Set<String>()
        var choices: [PlaceholderSourceChoice] = []
        for (index, source) in videoInputs.sources.enumerated() {
            let id = source.id.uuidString
            guard seen.insert(id).inserted else { continue }
            choices.append(
                PlaceholderSourceChoice(
                    id: id,
                    name: source.label,
                    subtitle: Self.deviceSubtitle(source.kind),
                    symbolName: Self.deviceSymbol(source.kind),
                    tintHex: Self.deviceTint(index),
                    group: .device
                )
            )
        }
        for item in allMediaItems {
            let id = item.id.uuidString
            guard seen.insert(id).inserted else { continue }
            choices.append(
                PlaceholderSourceChoice(
                    id: id,
                    name: item.title,
                    subtitle: Self.mediaSubtitle(item.kind),
                    symbolName: Self.mediaSymbol(item.kind),
                    tintHex: item.tintHex,
                    filePath: item.filePath,
                    previewKind: Self.previewKind(item.kind),
                    group: .media
                )
            )
        }
        return choices
    }

    private static func deviceSubtitle(_ kind: StudioVideoKind) -> String {
        switch kind {
        case .camera: "Camera"
        case .continuity: "Continuity Camera"
        case .captureCard: "Capture card"
        case .screenShare: "Display share"
        case .ndi: "NDI"
        case .webrtc: "WebRTC"
        case .rtsp: "RTSP"
        }
    }

    private static func deviceSymbol(_ kind: StudioVideoKind) -> String {
        switch kind {
        case .camera, .continuity: "video.fill"
        case .captureCard: "cable.connector"
        case .screenShare: "display"
        case .ndi, .webrtc, .rtsp: "dot.radiowaves.left.and.right"
        }
    }

    private static func deviceTint(_ index: Int) -> String {
        ["#C8E6FF", "#FFD6E0", "#FFE9A8", "#D4D0FF", "#C8F4F0", "#FFD0B8"][abs(index) % 6]
    }

    private static func mediaSubtitle(_ kind: MediaBinItem.Kind) -> String {
        switch kind {
        case .video(let duration): duration.isEmpty ? "Video file" : "Video · \(duration)"
        case .audio(let duration): duration.isEmpty ? "Audio file" : "Audio · \(duration)"
        case .image: "Still image"
        case .camera(let label): label
        case .microphone(let label): label
        case .placeholder: "Library item"
        }
    }

    private static func previewKind(_ kind: MediaBinItem.Kind) -> PlaceholderSourceChoice.PreviewKind {
        switch kind {
        case .video: .video
        case .audio: .video
        case .image: .image
        case .camera: .camera
        case .microphone: .camera
        case .placeholder: .placeholder
        }
    }

    private static func mediaSymbol(_ kind: MediaBinItem.Kind) -> String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .placeholder: "square.dashed"
        }
    }

    func updatePlaceholder(_ id: String, _ body: (inout PlaceholderConfiguration) -> Void) {
        guard let index = placeholderMatrix.placeholders.firstIndex(where: { $0.id == id }) else { return }
        var next = placeholderMatrix.placeholders[index]
        body(&next)
        placeholderMatrix.placeholders[index] = next
        syncPlaceholderBinding(placeholderMatrix.placeholders[index])
        persistStudio()
        refreshPlaceholderRoutes()
    }

    /// Live program + active props only — avoids scanning every slide each program tick (record / encode load).
    func quoteCanvasObjects() -> [CanvasObject] {
        var seen = Set<UUID>()
        var objects: [CanvasObject] = []
        func append(_ batch: [CanvasObject]) {
            for object in batch where seen.insert(object.id).inserted {
                objects.append(object)
            }
        }
        append(compositor.stack.slideCanvas)
        if let liveSlideID, let slide = show.slide(id: liveSlideID) {
            append(resolvedCanvasObjects(slide.audienceCanvas()))
        }
        append(liveStageDocument.objects)
        for prop in inspector.props where prop.isActive || propBuildClearStartedAt[prop.id] != nil {
            append(resolvedCanvasObjects(prop.elements))
        }
        for canvas in compositor.propCanvases where compositor.stack.activeProps.contains(canvas.name) {
            append(canvas.objects)
        }
        return objects
    }

    func liveCanvasObjects() -> [CanvasObject] {
        var seen = Set<UUID>()
        var objects: [CanvasObject] = []
        func append(_ batch: [CanvasObject]) {
            for object in batch where seen.insert(object.id).inserted {
                objects.append(object)
            }
        }

        append(compositor.stack.slideCanvas)
        if let liveSlideID, let slide = show.slide(id: liveSlideID) {
            append(resolvedCanvasObjects(slide.audienceCanvas()))
        }
        for slide in show.allSlides where slide.id != liveSlideID {
            append(slide.canvas)
        }
        if isCanvasEditorPresented, editors.isOpen, !isSandboxEditingLive {
            append(editors.documents.flatMap(\.objects))
        }
        append(liveStageDocument.objects)
        for prop in inspector.props where prop.isActive || propBuildClearStartedAt[prop.id] != nil {
            append(resolvedCanvasObjects(prop.elements))
        }
        for canvas in compositor.propCanvases where compositor.stack.activeProps.contains(canvas.name) {
            append(canvas.objects)
        }
        return objects
    }

    func publishGraphValue(_ value: String, for key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        dataLinkGraph[trimmed] = value
        tickProgram()
    }

    func dynamicTextContext(now: Date = Date()) -> DynamicTextContext {
        let payload = StagePayload.make(controller: self)
        var fields = Dictionary(uniqueKeysWithValues: textFields.map { ($0.normalizedKey, $0.value) })
        let outline = outlineLinkState()
        let media = mediaLinkState()
        let timecode = broadcastTimecode(at: now)
        mergeLinkFields(outline: outline, media: media, timecode: timecode, into: &fields)
        fields["time.now"] = DynamicTextEngine.formatDate(now, format: "h:mm:ss a", timeZone: .current)
        if let timer = inspector.timers.first(where: \.isRunning) ?? inspector.timers.first {
            fields["timer.countdown"] = CountdownFormatCatalog.format(
                timer.displaySeconds,
                token: CountdownFormatCatalog.default
            )
            let elapsed = max(0, timer.durationSeconds - timer.displaySeconds)
            fields["timer.elapsed"] = CountdownFormatCatalog.format(
                elapsed,
                token: CountdownFormatCatalog.default
            )
        }
        return DynamicTextContext(
            now: now,
            timeZone: .current,
            fields: fields,
            quotes: liveQuotes.quotes,
            copyright: editors.copyright,
            currentSlide: payload.current,
            nextSlide: payload.next,
            notes: payload.notes,
            timerText: inspector.timers.first.map {
                CountdownFormatCatalog.format($0.displaySeconds, token: CountdownFormatCatalog.default)
            },
            timers: inspector.timers,
            mediaRemainingSeconds: media.remainingSeconds,
            mediaDurationSeconds: media.durationSeconds,
            liveQuotesInitialLoadPending: liveQuotes.isAwaitingFirstQuotePayload,
            outline: outline,
            mediaLink: media,
            broadcastTimecode: timecode,
            graphValues: dataLinkGraph
        )
    }

    private func mergeLinkFields(
        outline: OutlineLinkState,
        media: MediaLinkState,
        timecode: String,
        into fields: inout [String: String]
    ) {
        func put(_ key: String, _ value: String) {
            guard !value.isEmpty else { return }
            fields[key] = value
        }
        put("segment.title", outline.segmentTitle)
        put("segment.link", outline.segmentLink)
        put("segment.url", outline.segmentLink)
        if !outline.segmentTitle.isEmpty {
            fields["segment.duration"] = CountdownFormatCatalog.format(
                outline.plannedDurationSeconds,
                token: CountdownFormatCatalog.default
            )
        }
        put("speaker.name", outline.speakerName)
        put("speaker.role", outline.speakerRole)
        put("speaker.title", outline.speakerRole)
        put("speaker.org", outline.speakerOrganization)
        put("next.title", outline.nextTitle)
        put("next.speaker", outline.nextSpeakerName)
        if !outline.speakerName.isEmpty, fields["Speaker"] == nil || fields["Speaker"]?.isEmpty == true {
            fields["Speaker"] = outline.speakerName
        }
        put("media.name", media.name)
        if !media.name.isEmpty || media.durationSeconds > 0 {
            fields["media.elapsed"] = CountdownFormatCatalog.format(media.elapsedSeconds, token: CountdownFormatCatalog.default)
            fields["media.remaining"] = CountdownFormatCatalog.format(media.remainingSeconds, token: CountdownFormatCatalog.default)
            fields["media.duration"] = CountdownFormatCatalog.format(media.durationSeconds, token: CountdownFormatCatalog.default)
        }
        fields["timecode"] = timecode
        for pair in dataLinkGraph where !pair.value.isEmpty {
            fields["graph:\(pair.key)"] = pair.value
        }
    }

    private func outlineLinkState() -> OutlineLinkState {
        let doc = rundownClock.program ?? programDocument
        let blocks = doc.rundownBlocks
        let showHasStarted = blocks.contains { $0.actualStartTime != nil }
        let index: Int? = {
            if let active = rundownClock.activeBlockIndex, blocks.indices.contains(active) { return active }
            if !showHasStarted, !blocks.isEmpty { return 0 }
            return nil
        }()
        guard let index else { return OutlineLinkState() }
        let block = blocks[index]
        let talent = talentProfile(for: block, in: doc)
        let next = blocks.indices.contains(index + 1) ? blocks[index + 1] : nil
        let plannedThrough = blocks.prefix(index + 1).reduce(0.0) { $0 + $1.plannedDurationSeconds }
        let plannedEnd: Date? = {
            if let hard = block.hardStartTime {
                return hard.addingTimeInterval(block.plannedDurationSeconds)
            }
            if let start = block.actualStartTime {
                return start.addingTimeInterval(block.plannedDurationSeconds)
            }
            return doc.hardStartTime.addingTimeInterval(plannedThrough)
        }()
        let segmentLink = ProgramOutlinePresentation.resolvedPageURL(
            for: block,
            in: doc,
            showLookup: { [self] id in show(matching: id) }
        ) ?? ""
        return OutlineLinkState(
            segmentLink: segmentLink,
            segmentTitle: block.title,
            speakerName: talent?.fullName ?? "",
            speakerRole: talent?.titleOrRole ?? "",
            speakerOrganization: talent?.organization ?? "",
            plannedDurationSeconds: Int(block.plannedDurationSeconds.rounded()),
            plannedEnd: plannedEnd,
            nextTitle: next?.title ?? "",
            nextSpeakerName: next.flatMap { talentProfile(for: $0, in: doc)?.fullName } ?? "",
            upcoming: blocks.dropFirst(index + 1).prefix(8).map { item in
                OutlineAgendaItem(
                    title: item.title,
                    speakerName: talentProfile(for: item, in: doc)?.fullName ?? ""
                )
            }
        )
    }

    private func talentProfile(for block: RundownBlock, in doc: ProgramDocumentModel) -> TalentProfile? {
        guard let talentID = block.assignedTalentIds.first else { return nil }
        return doc.talentDatabase.first { $0.id == talentID }
    }

    private func mediaLinkState() -> MediaLinkState {
        let clock = programMediaClock()
        let elapsed = playback.duration > 0.05
            ? Int(playback.playhead.rounded(.towardZero))
            : max(0, clock.duration - clock.remaining)
        let name = compositor.stack.media?.title
            ?? liveSlideID.flatMap { show.slide(id: $0)?.associatedMediaAction()?.title }
            ?? ""
        return MediaLinkState(
            name: name,
            remainingSeconds: clock.remaining,
            elapsedSeconds: elapsed,
            durationSeconds: clock.duration
        )
    }

    private func broadcastTimecode(at now: Date) -> String {
        let origin = streaming.startedAt ?? rundownClock.program?.runState.showStartedAt
        return StreamingEngine.broadcastTimecode(from: origin, now: now)
    }

    func programMediaClock() -> (remaining: Int, duration: Int, isPlaying: Bool) {
        if playback.duration > 0.05 {
            return (
                Int(playback.remaining.rounded(.towardZero)),
                Int(playback.duration.rounded(.towardZero)),
                playback.isPlaying
            )
        }
        let media = compositor.stack.media ?? liveSlideID.flatMap { show.slide(id: $0)?.associatedMediaAction() }
        if let media, !media.isImage {
            let duration = Int(MediaDurationParser.seconds(from: media.duration).rounded(.towardZero))
            return (duration, duration, false)
        }
        return (0, 0, false)
    }

    func syncMediaBackedCountdowns() {
        var ids = Set<UUID>()
        for object in countdownLinkObjects() where object.kind == .timerCountdown && object.resolvedCountdownValueSource == .programMedia {
            if let id = object.timerID ?? inspector.timers.first?.id {
                ids.insert(id)
            }
        }
        guard !ids.isEmpty else { return }
        let clock = programMediaClock()
        for id in ids {
            inspector.followProgramMedia(id: id, remaining: clock.remaining, duration: clock.duration)
        }
    }

    func boundCountdownTimer(for object: CanvasObject) -> InspectorTimer? {
        inspector.timer(id: object.timerID)
    }

    @discardableResult
    func ensureCountdownTimer(named name: String = "Program Timer") -> InspectorTimer {
        inspector.timer(id: nil) ?? inspector.addTimer(name: name, kind: .countdown, seconds: 300)
    }

    func finishAddingLiveObject(_ object: CanvasObject) {
        if object.kind == .textField {
            ensureTextField(key: DynamicTextEngine.fieldKey(for: object))
        }
        if object.kind == .timerCountdown {
            let timer = ensureCountdownTimer()
            editors.mutateSelectedObjects { candidate in
                if candidate.id == object.id {
                    candidate.timerID = timer.id
                    if candidate.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        candidate.token = CountdownFormatCatalog.default
                    }
                }
            }
        }
    }

    func bindSelectedCountdowns(to timerID: UUID) {
        editors.mutateSelectedObjects { object in
            guard object.kind == .timerCountdown else { return }
            object.timerID = timerID
        }
        inspector.selectedTimerID = timerID
    }

    @discardableResult
    func addTimerForSelectedCountdowns() -> InspectorTimer {
        let timer = inspector.addTimer(name: "Countdown \(inspector.timers.count + 1)", kind: .countdown, seconds: 300)
        bindSelectedCountdowns(to: timer.id)
        persistStudio()
        return timer
    }

    func syncTextFieldsFromCanvas() {
        for key in DynamicTextEngine.fieldKeys(in: liveCanvasObjects()) {
            ensureTextField(key: key, persist: false)
        }
    }

    @discardableResult
    func ensureTextField(key: String, persist: Bool = true) -> ShowTextField {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = textFields.first(where: { $0.normalizedKey.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let field = ShowTextField(key: trimmed.isEmpty ? "Text" : trimmed)
        textFields.append(field)
        if persist { persistStudio() }
        return field
    }

    func setTextField(_ key: String, value: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = textFields.firstIndex(where: { $0.normalizedKey.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            textFields[index].value = value
        } else {
            textFields.append(ShowTextField(key: trimmed, value: value))
        }
        persistStudio()
    }

    func addTextField(named key: String = "Speaker") {
        var candidate = key
        var index = 2
        while textFields.contains(where: { $0.normalizedKey.caseInsensitiveCompare(candidate) == .orderedSame }) {
            candidate = "\(key) \(index)"
            index += 1
        }
        textFields.append(ShowTextField(key: candidate))
        persistStudio()
    }

    func addMapGraphNode(kind: RoutingNodeKind) {
        _ = placeholderMatrix.addGraphNode(kind: kind)
        persistStudio()
    }

    func performMapGraphCommand(_ command: NodeGraphCommand) {
        let matrix = placeholderMatrix
        switch command {
        case .palette:
            matrix.isGraphPaletteOpen = true
        case .selectAll:
            matrix.selectGraphNodes(Set(matrix.graphPlacements.map(\.id)))
        case .deselect:
            matrix.isGraphPaletteOpen = false
            matrix.renamingGraphNodeID = nil
            matrix.highlightedGraphLinkID = nil
            matrix.selectGraphNodes([])
        case .duplicate:
            duplicateSelectedMapNodes()
        case .delete:
            deleteSelectedMapNodes()
        case .zoomFit, .zoomOne, .toggleMinimap:
            NotificationCenter.default.post(name: .proShowMapViewport, object: command)
        case .bypass:
            toggleSelectedMapFlag(\.isBypassed)
        case .mute:
            toggleSelectedMapFlag(\.isMuted)
        case .liveLock:
            toggleSelectedMapFlag(\.isLiveLocked)
        case .rename:
            matrix.renamingGraphNodeID = matrix.selectedGraphNodeID
        case .group:
            groupSelectedMapNodes()
        case .ungroup:
            ungroupSelectedMapBackdrop()
        case .tidy:
            matrix.graphPlacements = NodeGraphGeometry.tidy(matrix.graphPlacements)
            persistStudio()
        case .spacePan:
            matrix.graphSpaceHeld = true
        }
    }

    func addMapCommandItem(_ item: NodeCommandItem, at point: CGPoint) {
        switch item.kind {
        case .source(let id):
            _ = placeholderMatrix.addGraphNode(kind: .inputSource, x: point.x, y: point.y, assignedSourceId: id)
        case .placeholder(let letter):
            let placeholderID = placeholderMatrix.ensurePlaceholder(letter: letter)
            _ = placeholderMatrix.addGraphNode(
                kind: .placeholder,
                x: point.x,
                y: point.y,
                assignedPlaceholderID: placeholderID
            )
        case .filter(let filter):
            let node = placeholderMatrix.addGraphNode(
                kind: .processFilter,
                x: point.x,
                y: point.y,
                title: filter.title,
                filterID: filter.rawValue
            )
            spliceHighlightedOrOverlapping(id: node.id)
        case .layer(let index):
            _ = placeholderMatrix.addGraphNode(kind: .masterLayer, x: point.x, y: point.y, assignedLayerIndex: index)
        case .scene(let id):
            _ = placeholderMatrix.addGraphNode(kind: .scene, x: point.x, y: point.y, assignedSceneID: id)
        case .backdrop:
            groupSelectedMapNodes(at: point)
        case .stickyNote:
            _ = placeholderMatrix.addGraphNode(kind: .stickyNote, x: point.x, y: point.y, title: "Note")
        case .passThrough:
            let node = placeholderMatrix.addGraphNode(kind: .passThrough, x: point.x, y: point.y, title: "Pin")
            spliceHighlightedOrOverlapping(id: node.id)
        }
        placeholderMatrix.isGraphPaletteOpen = false
        placeholderMatrix.highlightedGraphLinkID = nil
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func deleteSelectedMapNodes() {
        let ids = placeholderMatrix.selectedGraphNodeIDs
        guard !ids.isEmpty else { return }
        placeholderMatrix.removeGraphNodes(ids)
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func duplicateSelectedMapNodes() {
        let ids = placeholderMatrix.selectedGraphNodeIDs
        let result = NodeGraphGeometry.duplicate(placeholderMatrix.graphPlacements, ids: ids)
        placeholderMatrix.graphPlacements.append(contentsOf: result.items)
        var extraLinks: [MapGraphLink] = []
        for link in placeholderMatrix.graphLinks {
            if let from = result.map[link.fromPlacementID], let to = result.map[link.toPlacementID] {
                extraLinks.append(MapGraphLink(fromPlacementID: from, toPlacementID: to, pins: link.pins))
            }
        }
        placeholderMatrix.graphLinks.append(contentsOf: extraLinks)
        placeholderMatrix.selectGraphNodes(Set(result.items.map(\.id)))
        persistStudio()
    }

    func toggleSelectedMapFlag(_ key: WritableKeyPath<MapGraphPlacement, Bool>) {
        for id in placeholderMatrix.selectedGraphNodeIDs {
            placeholderMatrix.mutateGraphNode(id: id) { $0[keyPath: key].toggle() }
        }
        syncGraphFilterBypass()
        persistStudio()
    }

    func groupSelectedMapNodes(at point: CGPoint? = nil) {
        let selected = placeholderMatrix.graphPlacements.filter { placeholderMatrix.selectedGraphNodeIDs.contains($0.id) }
        guard let backdrop = NodeGraphGeometry.groupBackdrop(around: selected) else {
            if let point {
                placeholderMatrix.graphBackdrops.append(
                    MapBackdropGroup(title: "Backdrop", x: point.x, y: point.y, width: 320, height: 220)
                )
            }
            persistStudio()
            return
        }
        placeholderMatrix.graphBackdrops.append(backdrop)
        persistStudio()
    }

    func ungroupSelectedMapBackdrop() {
        let ids = placeholderMatrix.selectedGraphNodeIDs
        placeholderMatrix.graphBackdrops.removeAll { group in
            !Set(group.childIDs).isDisjoint(with: ids)
        }
        persistStudio()
    }

    func moveMapBackdrop(id: UUID, x: Double, y: Double) {
        guard let index = placeholderMatrix.graphBackdrops.firstIndex(where: { $0.id == id }) else { return }
        let dx = x - placeholderMatrix.graphBackdrops[index].x
        let dy = y - placeholderMatrix.graphBackdrops[index].y
        placeholderMatrix.graphBackdrops[index].x = x
        placeholderMatrix.graphBackdrops[index].y = y
        let children = Set(placeholderMatrix.graphBackdrops[index].childIDs)
        placeholderMatrix.graphPlacements = NodeGraphGeometry.translate(
            placements: placeholderMatrix.graphPlacements,
            ids: children,
            dx: dx,
            dy: dy
        )
        persistStudio()
    }

    func toggleMapBackdropCollapsed(id: UUID) {
        guard let index = placeholderMatrix.graphBackdrops.firstIndex(where: { $0.id == id }) else { return }
        placeholderMatrix.graphBackdrops[index].isCollapsed.toggle()
        persistStudio()
    }

    func sliceMapWires(from: CGPoint, to: CGPoint, portPositions: [UUID: CGPoint]) {
        let snapshot = mapRoutingSnapshot()
        let cut = Set(NodeGraphGeometry.laserCuts(from: from, to: to, connections: snapshot.connections, portPositions: portPositions))
        guard !cut.isEmpty else { return }
        placeholderMatrix.removeGraphLinks(matching: cut, snapshot: snapshot)
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func spliceMapNodeIfNeeded(id: UUID) {
        let snapshot = mapRoutingSnapshot()
        guard let node = snapshot.allNodes.first(where: { $0.id == id }) else { return }
        let frame = CGRect(x: node.canvasX, y: node.canvasY, width: MapGraphMetrics.nodeWidth, height: MapGraphMetrics.nodeHeight)
        guard let link = NodeGraphGeometry.overlappingLink(
            nodeFrame: frame,
            links: placeholderMatrix.graphLinks,
            nodes: snapshot.allNodes
        ) else { return }
        placeholderMatrix.graphLinks = NodeGraphGeometry.splice(nodeID: id, onto: link, links: placeholderMatrix.graphLinks)
        applyGraphLinkActions(touching: id)
        persistStudio()
    }

    func spliceHighlightedOrOverlapping(id: UUID) {
        if let linkID = placeholderMatrix.highlightedGraphLinkID,
           let link = placeholderMatrix.graphLinks.first(where: { $0.id == linkID })
        {
            placeholderMatrix.graphLinks = NodeGraphGeometry.splice(nodeID: id, onto: link, links: placeholderMatrix.graphLinks)
            applyGraphLinkActions(touching: id)
            persistStudio()
            return
        }
        spliceMapNodeIfNeeded(id: id)
    }

    func addMapReroutePin(at viewPoint: CGPoint, canvasPoint: CGPoint? = nil, portPositions: [UUID: CGPoint]) {
        let snapshot = mapRoutingSnapshot()
        guard let wire = NodeGraphGeometry.hitWire(at: viewPoint, connections: snapshot.connections, portPositions: portPositions) else { return }
        let drop = canvasPoint ?? viewPoint
        let pin = placeholderMatrix.addGraphNode(kind: .passThrough, x: drop.x - 16, y: drop.y - 16, title: "Pin")
        if let from = snapshot.allNodes.first(where: { node in node.outputPorts.contains { $0.id == wire.startPortId } }),
           let to = snapshot.allNodes.first(where: { node in node.inputPorts.contains { $0.id == wire.endPortId } }),
           let link = placeholderMatrix.graphLinks.first(where: { $0.fromPlacementID == from.id && $0.toPlacementID == to.id })
        {
            placeholderMatrix.graphLinks = NodeGraphGeometry.splice(nodeID: pin.id, onto: link, links: placeholderMatrix.graphLinks)
        }
        persistStudio()
    }

    func swapMapLink(at point: CGPoint, portPositions: [UUID: CGPoint]) {
        let snapshot = mapRoutingSnapshot()
        guard let wire = NodeGraphGeometry.hitWire(at: point, connections: snapshot.connections, portPositions: portPositions),
              let from = snapshot.allNodes.first(where: { node in node.outputPorts.contains { $0.id == wire.startPortId } }),
              let to = snapshot.allNodes.first(where: { node in node.inputPorts.contains { $0.id == wire.endPortId } }),
              let index = placeholderMatrix.graphLinks.firstIndex(where: { $0.fromPlacementID == from.id && $0.toPlacementID == to.id })
        else { return }
        placeholderMatrix.graphLinks[index] = NodeGraphGeometry.swap(placeholderMatrix.graphLinks[index])
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func renameMapGraphNode(id: UUID, title: String) {
        placeholderMatrix.mutateGraphNode(id: id) { $0.title = title }
        placeholderMatrix.renamingGraphNodeID = nil
        persistStudio()
    }

    func moveMapGraphNode(id: UUID, x: Double, y: Double) {
        placeholderMatrix.moveGraphNode(id: id, x: x, y: y)
    }

    func artworkURL(forSource choice: PlaceholderSourceChoice) -> URL? {
        guard let uuid = UUID(uuidString: choice.id), let item = mediaItem(id: uuid) else { return nil }
        return mediaArtworkURL(for: item)
    }

    func assignMapGraphSource(id: UUID, sourceId: String?) {
        placeholderMatrix.assignGraphSource(id: id, sourceId: sourceId)
        applyGraphLinkActions(touching: id)
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func assignMapGraphPlaceholder(id: UUID, letter: String?) {
        let placeholderID = letter.map { placeholderMatrix.ensurePlaceholder(letter: $0) }
        placeholderMatrix.assignGraphPlaceholder(id: id, placeholderID: placeholderID)
        applyGraphLinkActions(touching: id)
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func assignMapGraphLayer(id: UUID, layerIndex: Int?) {
        placeholderMatrix.assignGraphLayer(id: id, layerIndex: layerIndex)
        applyGraphLinkActions(touching: id)
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func assignMapGraphScene(id: UUID, sceneID: UUID?) {
        placeholderMatrix.assignGraphScene(id: id, sceneID: sceneID)
        applyGraphLinkActions(touching: id)
        persistStudio()
        refreshPlaceholderRoutes()
    }

    func applyMapCable(
        from startPortId: UUID,
        toLocation: CGPoint,
        snappedPortId: UUID?,
        portPositions: [UUID: CGPoint]
    ) {
        let snapshot = mapRoutingSnapshot()
        let allowed = NodeRoutingGraph.validTargetPortIDs(from: startPortId, nodes: snapshot.allNodes)
        let targetPortId = snappedPortId ?? NodeRoutingGraph.findSnapTargetPort(
            near: toLocation,
            portPositions: portPositions,
            excluding: startPortId,
            allowed: allowed
        )
        if let targetPortId,
           let connection = NodeRoutingGraph.validateAndCreateConnection(
            fromPort: startPortId,
            toPort: targetPortId,
            nodes: snapshot.allNodes
           ),
           let fromNode = NodeRoutingGraph.node(containing: connection.startPortId, in: snapshot.allNodes),
           let toNode = NodeRoutingGraph.node(containing: connection.endPortId, in: snapshot.allNodes)
        {
            placeholderMatrix.upsertGraphLink(from: fromNode.id, to: toNode.id)
            if let action = NodeRoutingGraph.action(for: connection, nodes: snapshot.allNodes) {
                applyNodeRouting(action)
            } else {
                persistStudio()
            }
            return
        }
        if let startNode = NodeRoutingGraph.node(containing: startPortId, in: snapshot.allNodes),
           let port = NodeRoutingGraph.port(startPortId, in: snapshot.allNodes)
        {
            placeholderMatrix.removeGraphLinks(fromPort: startNode.id, isOutput: port.isOutput)
        }
        if let action = NodeRoutingGraph.disconnectAction(fromPort: startPortId, nodes: snapshot.allNodes) {
            applyNodeRouting(action)
        } else {
            persistStudio()
        }
    }

    func bindPlaceholderToMasterLayer(placeholderId: String, layerIndex: Int) {
        applyNodeRouting(.mapLayer(placeholderID: placeholderId, layerIndex: layerIndex))
    }

    func syncGraphFilterBypass() {
        filters.bypassProcessing = placeholderMatrix.graphPlacements.contains {
            $0.kind == .processFilter && $0.isBypassed
        }
    }

    private func mapRoutingSnapshot() -> NodeRoutingSnapshot {
        NodeRoutingGraph.build(
            sources: placeholderSourceChoices,
            videoSources: videoInputs.sources,
            placeholders: placeholderMatrix.placeholders,
            usingFailover: placeholderMatrix.usingFailover,
            layers: masterLayers,
            scenes: scenes.scenes,
            placements: placeholderMatrix.graphPlacements,
            links: placeholderMatrix.graphLinks
        )
    }

    private func applyGraphLinkActions(touching id: UUID) {
        let snapshot = mapRoutingSnapshot()
        for link in placeholderMatrix.graphLinks where link.fromPlacementID == id || link.toPlacementID == id {
            if let action = NodeRoutingGraph.action(for: link, nodes: snapshot.allNodes) {
                applyNodeRouting(action)
            }
        }
    }

    func applyNodeRouting(_ action: NodeRoutingAction) {
        switch action {
        case .mapSource(let sourceId, let placeholderID):
            placeholderMatrix.select(placeholderID)
            updatePlaceholder(placeholderID) { $0.primarySourceId = sourceId }
            reroutePlaceholder(placeholderID)
        case .mapLayer(let placeholderID, let layerIndex):
            placeholderMatrix.select(placeholderID)
            updatePlaceholder(placeholderID) { $0.targetMasterLayerIndex = layerIndex }
            reroutePlaceholder(placeholderID)
        case .mapScene(let placeholderID, let sceneID):
            placeholderMatrix.select(placeholderID)
            if let placeholder = placeholderMatrix.placeholders.first(where: { $0.id == placeholderID }),
               let sourceID = (placeholder.primarySourceId ?? placeholder.failoverSourceId).flatMap(UUID.init(uuidString:)),
               let index = scenes.scenes.firstIndex(where: { $0.id == sceneID })
            {
                scenes.scenes[index].primarySourceID = sourceID
            }
            if let scene = scenes.switchTo(sceneID) {
                scenes.apply(scene, compositor: compositor, video: videoInputs, audio: audioMatrix)
            }
            persistStudio()
            refreshPlaceholderRoutes()
        case .unmapSource(let placeholderID):
            updatePlaceholder(placeholderID) { $0.primarySourceId = nil }
            reroutePlaceholder(placeholderID)
        case .unmapLayer(let placeholderID):
            updatePlaceholder(placeholderID) { $0.targetMasterLayerIndex = nil }
            persistStudio()
            refreshPlaceholderRoutes()
        }
    }

    func reroutePlaceholder(_ id: String) {
        guard let placeholder = placeholderMatrix.placeholders.first(where: { $0.id == id }) else { return }
        syncPlaceholderBinding(placeholder)
        propagatePlaceholderMapping(placeholder)
        applyPlaceholderFilters(placeholder)
        if let layerIndex = placeholder.targetMasterLayerIndex {
            _ = ensurePlaceholderShot(letter: placeholder.letter, layerIndex: layerIndex)
        }
        presentMappedLiveInput(placeholder)
        withdrawPlaceholderFromProgram(placeholder)
        refreshPlaceholderRoutes()
        persistStudio()
    }

    func refreshPlaceholderRoutes() {
        let sourceNames = Dictionary(placeholderSourceChoices.map { ($0.id, $0.name) }, uniquingKeysWith: { _, latest in latest })
        let layerNames = Dictionary(masterLayers.map { ($0.index, $0.title) }, uniquingKeysWith: { _, latest in latest })
        placeholderRoutes = placeholderMatrix.routes(sourceNames: sourceNames, layerNames: layerNames)
        refreshProgramClockBindings()
    }

    func swapPlaceholderPreview() {
        guard let selected = placeholderMatrix.selected else { return }
        let next: PlaceholderState = selected.state == .activeLive ? .activePreview : .activeLive
        firePlaceholderEvent(placeholderMatrix.setState(id: selected.id, next), for: selected.id)
        refreshPlaceholderRoutes()
    }

    func simulatePlaceholderSignalDrop(id: String) {
        placeholderMatrix.simulateSignalDrop(id: id)
        tickPlaceholderFailover()
    }

    func tickPlaceholderFailover() {
        let stalled = InputFailoverEngine.shared.stalledPlaceholderIDs(
            placeholders: placeholderMatrix.placeholders,
            alreadyOnFailover: placeholderMatrix.usingFailover
        )
        var fired: [UUID] = []
        for id in stalled {
            placeholderMatrix.usingFailover.insert(id)
            if let placeholder = placeholderMatrix.placeholders.first(where: { $0.id == id }),
               let macro = placeholder.onFailoverMacroId {
                placeholderMatrix.lastFiredMacros[.onFailover] = macro
                fired.append(macro)
            }
        }
        fired.append(contentsOf: placeholderMatrix.evaluateFailover())
        for macroID in Set(fired) {
            _ = triggerMacro(id: macroID)
        }
        if !fired.isEmpty {
            if let selected = placeholderMatrix.selected, placeholderMatrix.usingFailover.contains(selected.id) {
                routePlaceholderToProgram(selected, useFailover: true)
            }
            refreshPlaceholderRoutes()
        }
    }

    private func firePlaceholderEvent(_ event: PlaceholderMacroEvent?, for id: String) {
        guard let event,
              let placeholder = placeholderMatrix.placeholders.first(where: { $0.id == id }),
              let macroID = PlaceholderMatrix.macroID(for: placeholder, event: event)
        else { return }
        _ = triggerMacro(id: macroID)
    }

    private func syncPlaceholderBinding(_ placeholder: PlaceholderConfiguration) {
        let sourceID = placeholderMatrix.usingFailover.contains(placeholder.id)
            ? placeholder.failoverSourceId
            : placeholder.primarySourceId
        guard let sourceID else {
            bindPlaceholder(letter: placeholder.letter, use: .unmapped)
            return
        }
        if let video = videoSource(matching: sourceID) {
            bindPlaceholder(letter: placeholder.letter, use: .camera, targetID: video.id.uuidString, targetName: video.label)
        } else if let uuid = UUID(uuidString: sourceID), allMediaItems.contains(where: { $0.id == uuid }) {
            let name = allMediaItems.first { $0.id == uuid }?.title
            bindPlaceholder(letter: placeholder.letter, use: .media, targetID: sourceID, targetName: name)
        }
    }

    private func assignedSource(for placeholder: PlaceholderConfiguration) -> AssignedMediaSource {
        let letter = placeholder.letter
        let binding = placeholderBindings[letter.uppercased()]
        let sourceID = placeholderMatrix.usingFailover.contains(placeholder.id)
            ? placeholder.failoverSourceId
            : (placeholder.primarySourceId ?? binding?.targetID)
        if let sourceID {
            if let video = videoSource(matching: sourceID) {
                return AssignedMediaSource(
                    sourceID: video.id.uuidString,
                    name: video.label,
                    sourceType: Self.sourceType(for: video.kind),
                    category: .videoCapture,
                    connectionString: video.endpoint ?? video.id.uuidString,
                    placeholderLetter: letter
                )
            }
            if let uuid = UUID(uuidString: sourceID), let item = allMediaItems.first(where: { $0.id == uuid }) {
                if case .camera(let label) = item.kind {
                    return AssignedMediaSource(
                        sourceID: item.id.uuidString,
                        name: label,
                        sourceType: .systemCamera,
                        category: .videoCapture,
                        connectionString: item.filePath ?? item.id.uuidString,
                        tintHex: item.tintHex,
                        placeholderLetter: letter,
                        mediaItemID: item.id
                    )
                }
                return AssignedMediaSource(
                    sourceID: "media-\(item.id.uuidString)",
                    name: item.title,
                    sourceType: .mediaFile,
                    category: .mediaFiles,
                    connectionString: item.filePath,
                    tintHex: item.tintHex,
                    placeholderLetter: letter,
                    mediaItemID: item.id
                )
            }
        }
        return AssignedMediaSource(
            sourceID: "placeholder-\(letter)",
            name: letter,
            sourceType: .placeholderSlot,
            category: .placeholders,
            connectionString: "placeholder://\(letter)",
            tintHex: placeholder.fallbackColorHex,
            placeholderLetter: letter
        )
    }

    /// The matrix id is the assignment. Slides keep the placeholder letter and resolve it when drawn.
    private func propagatePlaceholderMapping(_ placeholder: PlaceholderConfiguration) {
        refreshPlaceholderRoutes()
        let target = liveSlideID ?? selectedSlideID
        guard let target, let slide = show.slide(id: target), let index = show.indexOfSlide(id: target) else { return }
        compositor.triggerCue(makeCue(for: slide, index: index))
    }

    @discardableResult
    private func ensurePlaceholderShot(letter: String, layerIndex: Int) -> LayerShot? {
        guard let arrayIndex = masterLayers.firstIndex(where: { $0.index == layerIndex }) else { return nil }
        if let existing = masterLayers[arrayIndex].shots.first(where: { $0.source.placeholderLetter == letter }) {
            return existing
        }
        let hex = PlaceholderSlotSpec.catalog.first { $0.letter.rawValue == letter }?.tintHex ?? "#D8F5D0"
        let shot = LayerShot(
            name: letter,
            source: DiscoveredSourceItem(
                id: "placeholder-\(letter)",
                name: letter,
                category: .placeholders,
                groupName: "Placeholders",
                sourceType: .placeholderSlot,
                connectionString: "placeholder://\(letter)",
                tintHex: hex
            )
        )
        var layers = masterLayers
        layers[arrayIndex].shots.append(shot)
        masterLayers = layers
        return shot
    }

    private static func sourceType(for kind: StudioVideoKind) -> SourceType {
        switch kind {
        case .ndi: .ndiSource
        case .rtsp: .srtStream
        case .webrtc: .rendezvousGuest
        case .screenShare: .systemDisplay
        default: .systemCamera
        }
    }

    private func presentMappedLiveInput(_ placeholder: PlaceholderConfiguration) {
        guard let binding = placeholderBindings[placeholder.letter], binding.use == .camera,
              let targetID = binding.targetID,
              let uuid = UUID(uuidString: targetID),
              let source = videoInputs.sources.first(where: { $0.id == uuid })
        else { return }
        activateVideoInput(
            VideoInputSource(
                id: source.id,
                label: source.label,
                kind: source.kind.videoInputKind,
                endpoint: source.endpoint
            ),
            presentOnProgram: false
        )
    }

    private func withdrawPlaceholderFromProgram(_ placeholder: PlaceholderConfiguration) {
        let source = assignedSource(for: placeholder)
        if let media = compositor.stack.media {
            let sameLetter = media.placeholderLetter == placeholder.letter
            let sameFile = source.connectionString.map { media.filePath == $0 } ?? false
            let sameMappedTitle = source.isMappedFill && media.title == source.name
            if sameLetter || sameFile || sameMappedTitle {
                compositor.clearProgramMedia()
                playback.load(nil)
                bindLiveMedia()
            }
        }
        if let id = UUID(uuidString: source.sourceID), compositor.stack.videoInput?.id == id {
            compositor.clearProgramVideoInput()
        }
        let target = liveSlideID ?? selectedSlideID
        if let target, let slide = show.slide(id: target), let index = show.indexOfSlide(id: target) {
            compositor.triggerCue(makeCue(for: slide, index: index))
        }
    }

    private func applyPlaceholderFilters(_ placeholder: PlaceholderConfiguration) {
        if placeholder.chromaKeyEnabled {
            filters.chroma.smoothness = placeholder.chromaKeySmoothness
            filters.grade.backgroundBlur = placeholder.backgroundBlurRadius
        }
    }

    private func routePlaceholderToProgram(_ placeholder: PlaceholderConfiguration, useFailover: Bool = false) {
        let sourceID = useFailover || placeholderMatrix.usingFailover.contains(placeholder.id)
            ? placeholder.failoverSourceId
            : placeholder.primarySourceId
        if let sourceID, let uuid = UUID(uuidString: sourceID),
           let source = videoInputs.sources.first(where: { $0.id == uuid }) {
            activateVideoInput(
                VideoInputSource(id: source.id, label: source.label, kind: source.kind.videoInputKind, endpoint: source.endpoint),
                presentOnProgram: false
            )
        }
        if let layerIndex = placeholder.targetMasterLayerIndex,
           let layer = masterLayers.first(where: { $0.index == layerIndex }),
           let shot = layer.shots.first(where: { $0.source.placeholderLetter == placeholder.letter }) {
            takeShotLive(shot, layerIndex: masterLayers.firstIndex(where: { $0.id == layer.id }) ?? 0)
        }
        applyPlaceholderFilters(placeholder)
    }

    var allMediaItems: [MediaBinItem] {
        mediaCollections.flatMap(\.items) + importedMedia
    }

    private func placeholderLetter(from item: MediaBinItem) -> String? {
        guard item.kind == .placeholder else { return nil }
        if let path = item.filePath, path.hasPrefix("placeholder://") {
            let token = String(path.dropFirst("placeholder://".count))
            if PlaceholderLetter(rawValue: token) != nil { return token }
        }
        return PlaceholderLetter(rawValue: item.title) != nil ? item.title : nil
    }

    private func takeUnmappedPlaceholderLive(letter: String, source: DiscoveredSourceItem, shot: LayerShot) {
        let item: MediaBinItem
        if let existing = allMediaItems.first(where: {
            $0.kind == .placeholder && ($0.title == letter || $0.filePath == "placeholder://\(letter)")
        }) {
            item = existing
        } else {
            let created = MediaBinItem(
                title: letter,
                kind: .placeholder,
                tintHex: source.tintHex ?? "#D8F5D0",
                source: .resources,
                filePath: "placeholder://\(letter)"
            )
            importedMedia.append(created)
            persistMediaLibrary()
            item = created
        }
        compositor.triggerCue(
            OutputCue(
                id: shot.id,
                presentationId: show.id,
                slideIndex: liveIndex ?? 0,
                layers: CueLayers(mediaAction: mediaAction(from: item))
            )
        )
        bindLiveMedia()
        refreshLiveStack()
    }

    private func mediaItem(for source: DiscoveredSourceItem) -> MediaBinItem? {
        if let path = source.connectionString {
            if let match = allMediaItems.first(where: { $0.filePath == path }) {
                return match
            }
        }
        if source.id.hasPrefix("media-"),
           let uuid = UUID(uuidString: String(source.id.dropFirst("media-".count))) {
            return allMediaItems.first { $0.id == uuid }
        }
        return nil
    }

    private func applyPlaceholderBinding(_ binding: PlaceholderBinding, goLive: Bool) {
        guard goLive else { return }
        switch binding.use {
        case .unmapped:
            break
        case .prop:
            if let name = binding.targetName {
                compositor.toggleProp(name)
            }
        case .screen:
            if let hex = binding.targetID {
                compositor.setScreenColor(hex)
            }
        case .media:
            if let id = binding.targetID, let uuid = UUID(uuidString: id),
               let item = allMediaItems.first(where: { $0.id == uuid }) {
                triggerMedia(item, takeProgram: true)
            }
        case .camera:
            if let id = binding.targetID, let uuid = UUID(uuidString: id),
               let source = videoInputs.sources.first(where: { $0.id == uuid }) {
                activateVideoInput(
                    VideoInputSource(id: source.id, label: source.label, kind: source.kind.videoInputKind, endpoint: source.endpoint),
                    presentOnProgram: false
                )
            } else if let id = binding.targetID, let uuid = UUID(uuidString: id) {
                activateVideoInput(VideoInputSource(id: uuid, label: binding.targetName ?? "Camera"), presentOnProgram: false)
            }
        case .slide:
            if let id = binding.targetID, let uuid = UUID(uuidString: id),
               let slide = show.allSlides.first(where: { $0.id == uuid }) {
                self.goLive(slideID: slide.id)
            }
        }
    }

    func activateVideoInput(_ source: VideoInputSource, presentOnProgram: Bool = true) {
        let alreadyRunning = videoInputs.hasLiveCamera(
            endpoint: source.endpoint,
            sourceID: source.id.uuidString,
            name: source.label
        ) || videoInputs.isRunning(endpoint: source.endpoint, sourceID: source.id.uuidString)
        let alreadyOnProgram = compositor.stack.videoInput.map { current in
            current.id == source.id
                || (source.endpoint != nil && current.endpoint == source.endpoint)
                || CameraIdentity.isSameCamera(
                    endpointA: current.endpoint,
                    nameA: current.label,
                    endpointB: source.endpoint,
                    nameB: source.label
                )
        } ?? false
        videoInputs.register(
            StudioVideoSource(
                id: source.id,
                label: source.label,
                kind: StudioVideoKind(videoInput: source.kind),
                endpoint: source.endpoint
            )
        )
        let liveSource = videoInputs.source(id: source.id)?.inputSource ?? source
        if alreadyRunning {
            videoInputRunning = true
            compositor.syncVideoInputs(from: videoInputs)
            if presentOnProgram, !alreadyOnProgram {
                compositor.triggerCue(
                    OutputCue(
                        id: liveSource.id,
                        presentationId: show.id,
                        slideIndex: liveIndex ?? 0,
                        layers: CueLayers(videoInputAction: liveSource)
                    )
                )
                tickProgram()
            }
            if alreadyOnProgram || !presentOnProgram {
                return
            }
        }
        switch videoInputs.activatePrimary(source.id) {
        case .started:
            mediaAlert = nil
            videoInputRunning = true
        case .denied(let message), .unsupported(let message):
            mediaAlert = message
            videoInputRunning = false
        }
        if presentOnProgram {
            compositor.triggerCue(
                OutputCue(
                    id: liveSource.id,
                    presentationId: show.id,
                    slideIndex: liveIndex ?? 0,
                    layers: CueLayers(videoInputAction: liveSource)
                )
            )
            compositor.syncVideoInputs(from: videoInputs)
        } else if compositor.stack.videoInput?.id == source.id {
            compositor.clearProgramVideoInput()
        }
        tickProgram()
    }

    /// Stops capture, the live stream, file playback, and off-screen page views before the project object graph goes away.
    func shutdownProjectCapture() {
        streaming.stop()
        playback.releaseForProjectClose()
        stingerPlayer.stop()
        videoInputs.stop()
        compositor.programOutput.invalidate()
        #if canImport(CoreVideo)
        LastPublishedStreamFrame.clear()
        StreamHoldFrameCache.clear()
        LatestFrameSlot.shared.clear()
        ProgramFramePool.reset()
        CameraFrameCopy.reset()
        #endif
        #if os(macOS)
        ProgramPageRaster.shared.releaseOffscreenWebViews()
        #endif
    }

    func deactivateVideoInput() {
        if let input = compositor.stack.videoInput {
            _ = VideoInputRuntime.deactivate(input)
        }
        videoInputs.stop()
        videoInputRunning = false
        compositor.clear(.videoInput)
        reconcileAudioCaptureGraph()
        tickProgram()
    }

    func importMedia(url: URL) -> MediaBinItem? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let inspected = MediaLoader.inspect(url: url)
        if case .missing = inspected {
            mediaAlert = "Missing media file: \(url.path)"
            return nil
        }
        mediaAlert = nil
        let kind: MediaBinItem.Kind
        switch inspected {
        case .image: kind = .image
        case .video(_, let duration): kind = .video(duration: duration)
        case .audio(_, let duration): kind = .audio(duration: duration)
        default: kind = .placeholder
        }
        var item = MediaBinItem(
            title: url.deletingPathExtension().lastPathComponent,
            kind: kind,
            tintHex: "#1B3A4B",
            source: .resources,
            filePath: url.path
        )
        if let stored = persistImportedFile(from: url, inspected: inspected) {
            item.filePath = stored
        }
        importedMedia.append(item)
        addMediaToSelectedCollection(item)
        rebuildSearchIndex()
        persistMediaLibrary()
        return item
    }

    @discardableResult
    private func persistImportedFile(from url: URL, inspected: MediaLoadResult) -> String? {
        if let autosave = projectAutosave, let embedded = try? autosave.bundle.embedAsset(from: url) {
            let relative = autosave.bundle.relativePath(for: embedded)
            try? autosave.record(.importAsset(relativePath: relative))
            writeMediaThumbnail(from: embedded, inspected: inspected)
            MediaPath.currentProjectRoot = autosave.bundle.root
            return relative
        }
        let dest = standaloneImportURL(for: url)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectBundle.copyImportedFile(from: url, to: dest)
            writeMediaThumbnail(from: dest, inspected: inspected)
            return dest.path
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
    }

    private func writeMediaThumbnail(from mediaURL: URL, inspected: MediaLoadResult) {
        let thumb = mediaThumbnailURL(for: mediaURL)
        try? FileManager.default.createDirectory(at: thumb.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch inspected {
        case .image:
            _ = try? AssetPreview.writeThumbnail(from: mediaURL, to: thumb)
        case .video:
            _ = try? AssetPreview.writeVideoPoster(from: mediaURL, to: thumb)
        default:
            break
        }
    }

    private func standaloneImportURL(for url: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("ProShow/ImportedMedia", isDirectory: true)
        let name = url.lastPathComponent
        let dest = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return folder.appendingPathComponent(ext.isEmpty ? "\(stem)-\(UUID().uuidString)" : "\(stem)-\(UUID().uuidString).\(ext)")
    }

    func persistMediaLibrary() {
        persistCurrentShow()
        mediaCollections = mediaCollections.withoutLegacyProContent
        let document = MediaLibraryDocument(
            collections: mediaCollections,
            imported: importedMedia,
            contentLibraries: contentLibraries
        )
        guard let data = try? JSONEncoder().encode(document) else { return }
        for url in mediaLibraryURLs {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        try? projectAutosave?.commitNow()
    }

    func restoreMediaLibrary(from manifest: StudioManifest? = nil) {
        var collections = mediaCollections
        var imported = importedMedia
        var libraries: [ContentLibrary] = contentLibraries
        var newestStamp = Date.distantPast
        var foundLibraryFile = false
        for url in mediaLibraryURLs {
            guard let data = try? Data(contentsOf: url),
                  let document = try? JSONDecoder().decode(MediaLibraryDocument.self, from: data)
            else { continue }
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard !foundLibraryFile || stamp >= newestStamp else { continue }
            foundLibraryFile = true
            newestStamp = stamp
            collections = document.collections
            imported = document.imported
            libraries = document.contentLibraries
        }
        if let manifest {
            imported = mergeMediaItems(imported, manifest.importedMedia)
            collections = mergeMediaCollections(collections, manifest.mediaCollections)
        }
        if !collections.isEmpty {
            mediaCollections = collections.withoutLegacyProContent
        }
        importedMedia = imported
        if !libraries.isEmpty {
            contentLibraries = libraries
        }
    }

    private func mergeMediaItems(_ existing: [MediaBinItem], _ incoming: [MediaBinItem]) -> [MediaBinItem] {
        if existing.isEmpty { return incoming }
        var merged = existing
        let seen = Set(existing.map(\.id))
        merged.append(contentsOf: incoming.filter { !seen.contains($0.id) })
        return merged
    }

    private func mergeMediaCollections(_ existing: [MediaCollection], _ incoming: [MediaCollection]) -> [MediaCollection] {
        if existing.isEmpty { return incoming }
        var merged = existing
        for collection in incoming {
            if let index = merged.firstIndex(where: { $0.id == collection.id }) {
                merged[index].items = mergeMediaItems(merged[index].items, collection.items)
            } else if let index = merged.firstIndex(where: { $0.source == collection.source && $0.name == collection.name }) {
                merged[index].items = mergeMediaItems(merged[index].items, collection.items)
            } else {
                merged.append(collection)
            }
        }
        return merged
    }

    private var mediaLibraryURL: URL {
        mediaLibraryURLs[0]
    }

    private var mediaLibraryURLs: [URL] {
        var urls: [URL] = []
        if let root = projectAutosave?.bundle.librariesURL {
            urls.append(root.appendingPathComponent("media-library.json"))
        }
        urls.append(store.root.appendingPathComponent("media-library.json"))
        return urls
    }

    func openMediaPane(source: MediaSourceID, collectionID: UUID? = nil) {
        selectedMediaSource = source
        if source == .videoInputs || source == .audioInputs {
            videoInputs.refreshDevices()
        }
        if let collectionID {
            selectedCollectionID = collectionID
        } else if source.hasChildCollections {
            selectedCollectionID = nil
        } else if source == .videoInputs || source == .audioInputs {
            selectedCollectionID = nil
        } else {
            selectedCollectionID = collections(for: source).first?.id
        }
        expandedMediaSources.insert(source)
    }

    var orderedMediaSources: [MediaSourceID] {
        let known = Set(MediaSourceID.allCases)
        var order = mediaSourceOrder.filter { known.contains($0) }
        order.append(contentsOf: MediaSourceID.allCases.filter { !order.contains($0) })
        return order
    }

    func moveMediaSources(fromOffsets: IndexSet, toOffset: Int) {
        var order = orderedMediaSources
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
        mediaSourceOrder = order
    }

    func collections(for source: MediaSourceID) -> [MediaCollection] {
        mediaCollections.filter { $0.source == source }
    }

    var selectedMediaCollection: MediaCollection? {
        guard let selectedCollectionID else { return nil }
        return mediaCollections.first { $0.id == selectedCollectionID }
    }

    var visibleMediaItems: [MediaBinItem] {
        let items: [MediaBinItem]
        if let selected = selectedMediaCollection {
            items = selected.items
        } else {
            switch selectedMediaSource {
            case .resources:
                items = resourcesPaneItems()
            case .videoInputs:
                items = liveVideoInputMediaItems()
            case .audioInputs:
                items = liveAudioInputMediaItems()
            default:
                items = collections(for: selectedMediaSource).flatMap(\.items)
            }
        }
        let query = mediaFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func resourcesPaneItems() -> [MediaBinItem] {
        var merged = collections(for: .resources).flatMap(\.items)
        var seen = Set(merged.map(\.id))
        for item in importedMedia where item.source == .resources {
            guard seen.insert(item.id).inserted else { continue }
            merged.append(item)
        }
        return merged
    }

    private func liveVideoInputMediaItems() -> [MediaBinItem] {
        let stored = collections(for: .videoInputs).flatMap(\.items)
        let live = videoInputs.attachedSources.enumerated().map { index, source in
            MediaBinItem(
                id: source.id,
                title: source.label,
                kind: .camera(label: source.label),
                tintHex: Self.deviceTint(index),
                source: .videoInputs,
                filePath: source.endpoint
            )
        }
        return mergeLiveMediaItems(stored: stored, live: live)
    }

    private func liveAudioInputMediaItems() -> [MediaBinItem] {
        let stored = collections(for: .audioInputs).flatMap(\.items)
        let live = SystemAudioDeviceCatalog().microphones().map { device in
            MediaBinItem(
                id: HardwareSourceIdentity.uuid(for: device.endpoint),
                title: device.name,
                kind: .microphone(label: device.name),
                tintHex: "#2A3A4B",
                source: .audioInputs,
                filePath: device.endpoint
            )
        }
        return mergeLiveMediaItems(stored: stored, live: live)
    }

    private func mergeLiveMediaItems(stored: [MediaBinItem], live: [MediaBinItem]) -> [MediaBinItem] {
        guard !live.isEmpty else { return stored }
        var byID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        for item in live {
            byID[item.id] = item
        }
        let liveIDs = Set(live.map(\.id))
        let trailing = stored.filter { !liveIDs.contains($0.id) }
        return live + trailing
    }

    var visibleMediaFolders: [MediaCollection] {
        guard selectedCollectionID == nil, selectedMediaSource.hasChildCollections else { return [] }
        let query = mediaFilterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let folders = collections(for: selectedMediaSource)
        guard !query.isEmpty else { return folders }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func addMediaPlaylist(named name: String) -> MediaCollection {
        let collection = MediaCollection(name: name, source: .playlists)
        mediaCollections.append(collection)
        openMediaPane(source: .playlists, collectionID: collection.id)
        return collection
    }

    func addMediaLibrary(named name: String) -> MediaCollection {
        addFolder(named: name)
        let collection = MediaCollection(name: name, source: .libraries)
        mediaCollections.append(collection)
        openMediaPane(source: .libraries, collectionID: collection.id)
        return collection
    }

    func addMediaToSelectedCollection(_ item: MediaBinItem) {
        var stored = item
        stored.source = selectedMediaSource
        stored.collectionID = selectedCollectionID
        if let id = selectedCollectionID, let index = mediaCollections.firstIndex(where: { $0.id == id }) {
            mediaCollections[index].items.append(stored)
            return
        }
        if let index = mediaCollections.firstIndex(where: { $0.source == selectedMediaSource }) {
            mediaCollections[index].items.append(stored)
            return
        }
        mediaCollections.append(MediaCollection(name: selectedMediaSource.title, source: selectedMediaSource, items: [stored]))
    }

    func addFolder(named name: String) {
        libraryFolders.append(LibraryFolder(name: name, systemImage: "folder.fill", children: []))
    }

    func updateSelectedSlide(alignment: String? = nil, elements: [SlideCanvasElement]? = nil) {
        guard let selectedSlideID,
              let groupIndex = show.groups.firstIndex(where: { $0.slides.contains(where: { $0.id == selectedSlideID }) }),
              let slideIndex = show.groups[groupIndex].slides.firstIndex(where: { $0.id == selectedSlideID })
        else { return }
        if let alignment {
            show.groups[groupIndex].slides[slideIndex].alignment = alignment
        }
        if let elements {
            show.groups[groupIndex].slides[slideIndex].elements = elements
        }
        persistCurrentShow()
    }

    func addCanvasElement(text: String, alignment: String = "center") {
        guard let selectedSlideID,
              let groupIndex = show.groups.firstIndex(where: { $0.slides.contains(where: { $0.id == selectedSlideID }) }),
              let slideIndex = show.groups[groupIndex].slides.firstIndex(where: { $0.id == selectedSlideID })
        else { return }
        show.groups[groupIndex].slides[slideIndex].elements.append(
            SlideCanvasElement(text: text, alignment: alignment)
        )
        persistCurrentShow()
    }

    func triggerBible(_ passage: BiblePassage) {
        let slide = BibleEngine.slide(from: passage)
        compositor.triggerCue(
            OutputCue(
                id: slide.id,
                presentationId: show.id,
                slideIndex: liveIndex ?? 0,
                layers: CueLayers(slideText: SlideElement.from(slide: slide))
            )
        )
        isAudienceCleared = false
        isAudienceOutputOn = true
        operatorMode = .show
    }

    func applyReflow() {
        let group = ReflowEngine.slides(from: reflowBuffer, groupName: "Reflow")
        guard !group.slides.isEmpty else { return }
        show.groups.append(group)
        selectedSlideID = group.slides.first?.id
        operatorMode = .show
        persistCurrentShow()
        rebuildSearchIndex()
    }

    func captureWorkspaceState() -> ProShowWorkspaceState {
        ProShowWorkspaceState(
            activeModule: WorkspaceModule(mode: operatorMode),
            sidebar: .init(
                visible: workspaceLayout.sidebar.visible,
                width: workspaceLayout.sidebar.width,
                selectedLibraryId: selectedContentLibraryID?.uuidString ?? contentLibraries.first?.id.uuidString ?? "",
                selectedPlaylistId: playlist.id.uuidString
            ),
            mediaDrawer: .init(
                visible: workspaceLayout.mediaDrawer.visible,
                height: workspaceLayout.mediaDrawer.height,
                activeTab: MediaDrawerTab(source: selectedMediaSource),
                zoomLevel: workspaceLayout.mediaDrawer.zoomLevel,
                sourceOrder: mediaSourceOrder.map(\.rawValue)
            ),
            inspectorPane: .init(
                visible: workspaceLayout.inspectorPane.visible,
                activeTab: InspectorTab(actionTab: inspector.selectedTab)
            ),
            preview: .init(
                audienceOutputEnabled: isAudienceOutputOn,
                stageOutputEnabled: isStageOutputOn,
                selectedScreenId: selectedScreenID
            ),
            activeSceneId: scenes.activeSceneID?.uuidString ?? "",
            studioReady: true
        )
    }

    func applyWorkspaceState(_ state: ProShowWorkspaceState) {
        workspaceLayout = state
        if let libraryUUID = UUID(uuidString: state.sidebar.selectedLibraryId),
           !state.sidebar.selectedLibraryId.isEmpty {
            selectedContentLibraryID = libraryUUID
        }
        let restored = state.activeModule.operatorMode
        operatorMode = (restored == .bible && !BibleEngine.hasTranslationPackage) ? .show : restored
        selectedMediaSource = state.mediaDrawer.activeTab.source
        if !state.mediaDrawer.sourceOrder.isEmpty {
            mediaSourceOrder = state.mediaDrawer.sourceOrder.compactMap(MediaSourceID.init(rawValue:))
        }
        isAudienceOutputOn = state.preview.audienceOutputEnabled
        isStageOutputOn = state.preview.stageOutputEnabled
        selectedScreenID = state.preview.selectedScreenId
        inspector.selectedTab = state.inspectorPane.activeTab.actionTab
        sanitizeOperatorInspectorPresentation()
        if let sceneID = UUID(uuidString: state.activeSceneId),
           let scene = scenes.scenes.first(where: { $0.id == sceneID }) {
            scenes.apply(scene, compositor: compositor, video: videoInputs, audio: audioMatrix)
        }
    }

    func syncLibraryItemsPublic() {
        syncLibraryItems()
        syncPlaylistItemTitlesFromLibraryShows()
    }

    func addPresentation(named name: String, type: String = "Default") -> Show {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Untitled" : trimmedName
        let resolvedType = trimmedType.isEmpty ? "Default" : trimmedType
        var slide = Slide(title: resolvedName, lines: [resolvedName], theme: resolvedType)
        if resolvedType != "Default" {
            slide.canvas = DefaultSeedData.themeObjects(for: resolvedType)
            slide.themeVariantID = ThemeVariantRegistry.variant(named: resolvedType)?.id
        }
        let created = Show(
            name: resolvedName,
            groups: [SlideGroup(name: "Title", slides: [slide])]
        )
        libraryShows.append(created)
        try? store.save(created)
        try? projectAutosave?.record(.upsertLibrary(created))
        syncLibraryItems()
        rebuildSearchIndex()
        return created
    }

    func renamePresentation(id: ShowID, to name: String, persistShowFile: Bool = true) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = libraryShows.firstIndex(where: { $0.id == id })
        else { return }
        libraryShows[index].name = trimmed
        syncPlaylistTitles(forPresentation: id, to: trimmed)
        if show.id == id {
            show.name = trimmed
            selectedPlaylistItemTitle = trimmed
            if persistShowFile {
                persistCurrentShow()
            }
        } else if persistShowFile {
            try? store.save(libraryShows[index])
            try? projectAutosave?.record(.upsertLibrary(libraryShows[index]))
        }
    }

    func syncPlaylistTitles(forPresentation showID: ShowID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for playlistIndex in allPlaylists.indices {
            for itemIndex in allPlaylists[playlistIndex].items.indices {
                guard allPlaylists[playlistIndex].items[itemIndex].showID == showID else { continue }
                allPlaylists[playlistIndex].items[itemIndex].title = trimmed
            }
        }
        syncActivePlaylistFromStore()
    }

    func deletePresentation(id: ShowID, removeFromPlaylistsOnly: Bool = false) {
        for index in allPlaylists.indices {
            allPlaylists[index].items.removeAll { $0.showID == id }
        }
        syncActivePlaylistFromStore()
        if removeFromPlaylistsOnly {
            syncLibraryItems()
            rebuildSearchIndex()
            return
        }
        libraryShows.removeAll { $0.id == id }
        try? store.delete(id: id)
        if show.id == id, let nextShowID = playlist.items.compactMap(\.showID).first {
            loadPresentation(id: nextShowID)
        } else if show.id == id, let next = libraryShows.first {
            loadPresentation(id: next.id)
        }
        syncLibraryItems()
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    func loadPresentation(id: ShowID) {
        if show.id != id {
            rehydrateFromEditor(persist: true)
        }
        let loaded = store.loadAll()
        libraryShows = loaded.isEmpty ? libraryShows : loaded
        guard let found = libraryShows.first(where: { $0.id == id }) else { return }
        clearProgramPlaylistSelection()
        show = found
        selectedSlideID = found.allSlides.first?.id
        selectedPlaylistItemTitle = found.name
        if editors.kind == .presentation {
            editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
        }
        syncLibraryItems()
    }

    func loadProgramOutlinePresentation() {
        if show.id == ProgramOutlinePresentation.showID {
            syncProgramOutlineFromActiveShowIfNeeded()
        }
        let doc = rundownClock.program ?? programDocument
        let built = ProgramOutlinePresentation.makeShow(from: doc)
        show = built
        if selectedSlideID == nil || built.slide(id: selectedSlideID!) == nil {
            selectedSlideID = built.allSlides.first?.id
        }
        if let index = libraryShows.firstIndex(where: { $0.id == built.id }) {
            libraryShows[index] = built
        } else {
            libraryShows.append(built)
        }
        // Opening .program is an edit selection. The live stack stays until Take Live or Next.
        editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
    }

    /// Rundown / `.program` page cues — air picture uses the page raster on the media layer.
    func takeProgramOutlineSlideLive(slideID: UUID) {
        if show.id == ProgramOutlinePresentation.showID {
            syncProgramOutlineFromActiveShowIfNeeded()
        } else {
            let doc = rundownClock.program ?? programDocument
            show = ProgramOutlinePresentation.makeShow(from: doc)
        }
        guard var slide = show.slide(id: slideID) else { return }
        let doc = rundownClock.program ?? programDocument
        slide = ProgramOutlinePresentation.airPrepareSlide(slide, in: doc)
        selectedSlideID = slideID

        guard let page = ProgramOutlinePresentation.pageURL(in: slide),
              let index = show.indexOfSlide(id: slideID)
        else {
            compositor.dismissRundownPage()
            ProgramPageRaster.shared.load(nil)
            if compositor.stack.media?.id == RundownPageMedia.id {
                compositor.clearProgramMedia()
            }
            goLive(slideID: slideID)
            return
        }

        if liveSlideID == slideID, ProgramPageRaster.shared.isPageShowing(page) {
            applyLiveSceneDelta(for: slide)
            refreshLiveStack()
            return
        }

        cancelSlideLeave()
        liveSlideID = slideID
        selectedSlideID = slideID
        isAudienceCleared = false
        isAudienceOutputOn = true
        compositor.dismissRundownPage()
        ProgramPageRaster.shared.load(page)
        compositor.captureOutgoingForTransition()
        compositor.triggerCue(makeCue(for: slide, index: index))
        let incoming = resolvedAssociatedMedia(for: slide)
        let decision = MediaActionEvaluator.evaluate(
            current: compositor.stack.media,
            incoming: incoming,
            projectRoot: mediaProjectRoot,
            layerLocked: compositor.isLayerLocked(.media)
        )
        applyMediaLayerDecision(decision)
        compositor.setProgramPageMediaBackdrop(page)
        compositor.clearProgramVideoInput()
        compositor.clear(.videoInput)
        resetLiveBuildClock()
        refreshLiveStack()
        evaluateProgramClockState()
    }

    func importPresentation(data: Data, pathExtension: String = "") throws -> Show {
        let imported: Show
        if ["pro", "pro5", "pro6", "pro7"].contains(pathExtension.lowercased()) {
            throw ImportReflowError.unsupportedProPresenter
        }
        if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) || data.starts(with: [0x50, 0x4b, 0x05, 0x06]) {
            imported = try PresentationImport.parsePPTX(data)
        } else if pathExtension.lowercased() == "json" || pathExtension.isEmpty {
            imported = try PresentationImport.parseJSON(data)
        } else {
            imported = try ImportReflowEngine.import(data: data, name: "Imported", pathExtension: pathExtension)
        }
        try store.save(imported)
        libraryShows.append(imported)
        try? projectAutosave?.record(.upsertLibrary(imported))
        syncLibraryItems()
        rebuildSearchIndex()
        return imported
    }

    var canPasteSlides: Bool { !slideClipboard.isEmpty }
    var canPasteSlideStyle: Bool { slideStyleClipboard != nil }
    var canPasteMedia: Bool { !mediaClipboard.isEmpty }

    func quickEditSlide(id: SlideID) {
        openInEditor(slideId: id)
        editors.inspectorTab = .text
        isTextInspectorOpen = true
    }

    func editSlide(id: SlideID) {
        openInEditor(slideId: id)
    }

    func toggleSlideDisabled(id: SlideID) {
        mutateSlide(id: id) { $0.isDisabled.toggle() }
    }

    func applyTheme(_ name: String, to slideID: SlideID) {
        mutateSlide(id: slideID) { slide in
            slide.theme = name
            if let variant = ThemeVariantRegistry.variant(named: name) {
                slide.themeVariantID = variant.id
                if slide.themeApplication == .auto {
                    slide.themeApplication = slide.canvas.isEmpty ? .auto : .replace
                }
            } else {
                slide.themeVariantID = nil
            }
        }
        applyTheme(name)
    }

    func setSlideTransition(_ name: String, id: SlideID) {
        mutateSlide(id: id) { $0.transition = name }
        if let match = Double(name.replacingOccurrences(of: "s", with: "")) {
            slideTransitionSeconds = match
        }
    }

    func setSlideHotKey(_ key: String, id: SlideID) {
        mutateSlide(id: id) { $0.hotKey = key }
    }

    func setSlideNextTimer(_ name: String, id: SlideID) {
        mutateSlide(id: id) { $0.nextTimer = name }
    }

    func addSlideAction(_ name: String, id: SlideID) {
        mutateSlide(id: id) { $0.actions.append(name) }
        switch name {
        case "Go Live":
            goLive(slideID: id)
        default:
            break
        }
    }

    func addMediaAction(to slideID: SlideID, item: MediaBinItem? = nil) {
        let media = item ?? visibleMediaItems.first
        guard let media else {
            openMediaPane(source: selectedMediaSource)
            return
        }
        mutateSlide(id: slideID) { $0.actions.append("Media: \(media.title)") }
        triggerMedia(media, takeProgram: true)
    }

    func moveSlide(_ id: SlideID, before targetID: SlideID) {
        guard show.id != ProgramOutlinePresentation.showID else { return }
        guard id != targetID, let from = slideLocation(id), let to = slideLocation(targetID) else { return }
        var groups = show.groups
        let slide = groups[from.group].slides.remove(at: from.slide)
        var destGroup = to.group
        var destIndex = to.slide
        if from.group == destGroup, from.slide < destIndex {
            destIndex -= 1
        }
        destIndex = min(max(0, destIndex), groups[destGroup].slides.count)
        groups[destGroup].slides.insert(slide, at: destIndex)
        if groups.count > 1 {
            groups.removeAll { $0.slides.isEmpty }
        }
        show.groups = groups
        selectedSlideID = id
        persistCurrentShow()
    }

    func moveSlideToEnd(_ id: SlideID) {
        guard show.id != ProgramOutlinePresentation.showID else { return }
        guard let from = slideLocation(id), let lastGroup = show.groups.indices.last else { return }
        var groups = show.groups
        let slide = groups[from.group].slides.remove(at: from.slide)
        let dest = from.group == lastGroup ? lastGroup : groups.indices.last ?? lastGroup
        groups[dest].slides.append(slide)
        if groups.count > 1 {
            groups.removeAll { $0.slides.isEmpty }
        }
        show.groups = groups
        selectedSlideID = id
        persistCurrentShow()
    }

    func reorderCues(from offsets: IndexSet, to destination: Int) {
        guard show.id != ProgramOutlinePresentation.showID else { return }
        let cues = indexedCues
        guard let source = offsets.first, cues.indices.contains(source) else { return }
        let moving = cues[source].slide.id
        if destination >= cues.count {
            moveSlideToEnd(moving)
            return
        }
        guard cues.indices.contains(destination) else { return }
        moveSlide(moving, before: cues[destination].slide.id)
    }

    func beginWorkspaceDrag(_ payload: WorkspaceDragPayload) {
        draggingPayload = payload
        WorkspaceDragPasteboard.active = payload
    }

    func endWorkspaceDrag() {
        draggingPayload = nil
        WorkspaceDragPasteboard.active = nil
    }

    @discardableResult
    func handleDeskDrop(payload: WorkspaceDragPayload?, files: [URL], role: DeskDropRole) -> Bool {
        defer { endWorkspaceDrag() }
        switch role {
        case .ignore:
            return false
        case .mediaBin:
            return importDroppedFiles(files, placeInShow: false, assignEditor: false)
        case .editor:
            if let payload { return applyEditorWorkspaceDrop(payload) }
            return importDroppedFiles(files, placeInShow: false, assignEditor: true)
        case .slides:
            if let payload { return applyWorkspaceDrop(payload, before: nil) }
            return importDroppedFiles(files, placeInShow: true, assignEditor: false)
        }
    }

    @discardableResult
    func applyEditorWorkspaceDrop(_ payload: WorkspaceDragPayload) -> Bool {
        switch payload.kind {
        case .media:
            guard let mediaID = UUID(uuidString: payload.id), let item = mediaItem(id: mediaID) else { return false }
            assignSourceToSelectedEditorObjects(discoveredSource(from: item))
            return true
        case .shot:
            guard let shotID = UUID(uuidString: payload.id),
                  let shot = masterLayers.flatMap(\.shots).first(where: { $0.id == shotID })
            else { return false }
            assignSourceToSelectedEditorObjects(shot.source)
            return true
        case .placeholder:
            let letter = payload.name
            let hex = payload.extra.isEmpty ? "#D8F5D0" : payload.extra
            assignSourceToSelectedEditorObjects(
                DiscoveredSourceItem(
                    id: "placeholder-\(letter)",
                    name: letter,
                    category: .placeholders,
                    groupName: "Placeholders",
                    sourceType: .placeholderSlot,
                    connectionString: "placeholder://\(letter)",
                    tintHex: hex
                )
            )
            return true
        case .slide, .color:
            return applyWorkspaceDrop(payload, before: nil)
        }
    }

    private func discoveredSource(from item: MediaBinItem) -> DiscoveredSourceItem {
        DiscoveredSourceItem(
            id: "media-\(item.id.uuidString)",
            name: item.title,
            category: .mediaFiles,
            groupName: "Media",
            sourceType: {
                switch item.kind {
                case .image, .video, .audio: return .mediaFile
                case .camera: return .systemCamera
                case .microphone: return .systemMicrophone
                case .placeholder: return .placeholderSlot
                }
            }(),
            connectionString: item.filePath ?? item.id.uuidString,
            tintHex: item.tintHex
        )
    }

    @discardableResult
    private func importDroppedFiles(_ files: [URL], placeInShow: Bool, assignEditor: Bool) -> Bool {
        var imported: [MediaBinItem] = []
        for url in files {
            if let item = importMedia(url: url) {
                imported.append(item)
            }
        }
        guard !imported.isEmpty else { return false }
        if assignEditor, let last = imported.last {
            assignSourceToSelectedEditorObjects(discoveredSource(from: last))
        }
        if placeInShow {
            for item in imported {
                _ = applyWorkspaceDrop(.media(item), before: nil)
            }
        }
        return true
    }

    @discardableResult
    func applyWorkspaceDrop(
        _ payload: WorkspaceDragPayload,
        before targetID: SlideID? = nil,
        insertAfter afterID: SlideID? = nil
    ) -> Bool {
        guard show.id != ProgramOutlinePresentation.showID else { return false }
        switch payload.kind {
        case .slide:
            guard let id = UUID(uuidString: payload.id) else { return false }
            if let targetID {
                moveSlide(id, before: targetID)
            } else {
                moveSlideToEnd(id)
            }
            return true
        case .media:
            guard let mediaID = UUID(uuidString: payload.id), let item = mediaItem(id: mediaID) else { return false }
            let slide = insertMediaCueSlide(from: item, after: afterID)
            goLive(slideID: slide.id)
            return true
        case .shot:
            guard let shotID = UUID(uuidString: payload.id),
                  let found = masterLayers.enumerated().compactMap({ index, layer -> (Int, LayerShot)? in
                      layer.shots.first(where: { $0.id == shotID }).map { (index, $0) }
                  }).first
            else { return false }
            insertContentSlide(title: found.1.name, label: found.1.source.placeholderLetter ?? "", action: "Shot: \(found.1.name)", tintHex: found.1.source.tintHex ?? "#1B3A4B", before: targetID)
            takeShotLive(found.1, layerIndex: found.0)
            return true
        case .placeholder:
            let letter = payload.name
            let hex = payload.extra.isEmpty ? "#D8F5D0" : payload.extra
            insertContentSlide(title: "Placeholder \(letter)", label: letter, action: "Placeholder: \(letter)", tintHex: hex, before: targetID)
            let source = DiscoveredSourceItem(
                id: "placeholder-\(letter)",
                name: letter,
                category: .placeholders,
                groupName: "Placeholders",
                sourceType: .placeholderSlot,
                connectionString: "placeholder://\(letter)",
                tintHex: hex
            )
            _ = addShot(source, asCopy: false)
            return true
        case .color:
            let hex = payload.extra.isEmpty ? "#000000" : payload.extra
            insertContentSlide(title: payload.name, label: "Color", action: "Color: \(payload.name)", tintHex: hex, before: targetID)
            compositor.setScreenColor(hex)
            return true
        }
    }

    @discardableResult
    func insertContentSlide(
        title: String,
        label: String,
        action: String,
        tintHex: String,
        before targetID: SlideID?,
        linkedMedia: MediaAction? = nil
    ) -> Slide {
        var slide = Slide(title: title, lines: [], label: label, actions: [action])
        if let linkedMedia {
            slide.mediaAction = linkedMedia
        } else {
            slide.canvas = [
                CanvasObject(
                    name: title,
                    kind: .rectangle,
                    bounds: CanvasBounds(x: 0, y: 0, width: CanvasConfig.width, height: CanvasConfig.height),
                    zIndex: 0,
                    text: "",
                    fillHex: tintHex
                ),
            ]
        }
        if let targetID, let loc = slideLocation(targetID) {
            show.groups[loc.group].slides.insert(slide, at: loc.slide)
        } else if let selected = selectedSlideID, let loc = slideLocation(selected) {
            show.groups[loc.group].slides.insert(slide, at: loc.slide + 1)
        } else if let last = show.groups.indices.last {
            show.groups[last].slides.append(slide)
        } else {
            show.groups.append(SlideGroup(name: "Group", slides: [slide]))
        }
        selectedSlideID = slide.id
        persistCurrentShow()
        return slide
    }

    /// Adds a playlist/media bin item as a new slide cue (linked `mediaAction`), never mutating an existing slide.
    @discardableResult
    func insertMediaCueSlide(from item: MediaBinItem, after anchorID: SlideID?) -> Slide {
        var slide = Slide(
            title: item.title,
            lines: [],
            label: item.kindLabel,
            actions: ["Media: \(item.title)"],
            backgroundEnabled: false,
            mediaAction: mediaAction(from: item)
        )
        if let anchorID, let loc = slideLocation(anchorID) {
            let insertIndex = min(loc.slide + 1, show.groups[loc.group].slides.count)
            show.groups[loc.group].slides.insert(slide, at: insertIndex)
        } else if let lastGroup = show.groups.indices.last {
            show.groups[lastGroup].slides.append(slide)
        } else {
            show.groups.append(SlideGroup(name: "Group", slides: [slide]))
        }
        selectedSlideID = slide.id
        persistCurrentShow()
        return slide
    }

    func moveSlide(_ id: SlideID, toGroupNamed name: String) {
        guard show.id != ProgramOutlinePresentation.showID else { return }
        guard let loc = slideLocation(id) else { return }
        let slide = show.groups[loc.group].slides.remove(at: loc.slide)
        if let dest = show.groups.firstIndex(where: { $0.name == name }) {
            show.groups[dest].slides.append(slide)
        } else {
            show.groups.append(SlideGroup(name: name, slides: [slide]))
        }
        persistCurrentShow()
    }

    func setSlideLabel(_ name: String, id: SlideID) {
        mutateSlide(id: id) { $0.label = name }
    }

    func copySlideTextStyle(id: SlideID) {
        guard let slide = show.slide(id: id) else { return }
        slideStyleClipboard = SlideTextStyle(alignment: slide.alignment, theme: slide.theme)
    }

    func pasteSlideTextStyle(id: SlideID) {
        guard let style = slideStyleClipboard else { return }
        mutateSlide(id: id) {
            $0.alignment = style.alignment
            $0.theme = style.theme
        }
    }

    func copySlides(_ ids: [SlideID]) {
        slideClipboard = ids.compactMap { show.slide(id: $0) }
    }

    func cutSlides(_ ids: [SlideID]) {
        copySlides(ids)
        deleteSlides(ids)
    }

    func pasteSlides(after id: SlideID) {
        guard !slideClipboard.isEmpty, let loc = slideLocation(id) else { return }
        let copies = slideClipboard.map { $0.copyAsNew() }
        show.groups[loc.group].slides.insert(contentsOf: copies, at: loc.slide + 1)
        selectedSlideID = copies.last?.id
        persistCurrentShow()
    }

    func deleteSlides(_ ids: [SlideID]) {
        let doomed = Set(ids)
        for id in ids {
            documentState.recordDeletion(entityId: id)
        }
        for index in show.groups.indices {
            show.groups[index].slides.removeAll { doomed.contains($0.id) }
        }
        if show.groups.count > 1 {
            show.groups.removeAll { $0.slides.isEmpty }
        }
        if selectedSlideID.map(doomed.contains) == true {
            selectedSlideID = show.allSlides.first?.id
        }
        if liveSlideID.map(doomed.contains) == true {
            liveSlideID = nil
        }
        persistCurrentShow()
    }

    func mediaItem(id: UUID) -> MediaBinItem? {
        mediaCollections.flatMap(\.items).first { $0.id == id }
            ?? importedMedia.first { $0.id == id }
    }

    func inspectMedia(id: UUID) {
        selectedMediaItemID = id
        isMediaInspectorOpen = true
    }

    func setMediaTransition(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.transition = name }
    }

    func setMediaBehavior(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.behavior = name }
    }

    func setMediaScaling(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.scaling = name }
    }

    func setMediaAlphaType(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.alphaType = name }
    }

    func setMediaPlayback(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.playbackBehavior = name }
    }

    func setMediaLoop(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.loopBehavior = name }
    }

    func setMediaEndBehavior(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.endBehavior = name }
    }

    func setMediaNextCue(_ name: String, id: UUID) {
        mutateMedia(id: id) { $0.nextCue = name }
    }

    func copyMedia(_ ids: [UUID]) {
        mediaClipboard = ids.compactMap(mediaItem(id:))
    }

    func cutMedia(_ ids: [UUID]) {
        copyMedia(ids)
        deleteMedia(ids)
    }

    func pasteMedia() {
        guard !mediaClipboard.isEmpty else { return }
        for item in mediaClipboard {
            addMediaToSelectedCollection(item.copyAsNew())
        }
        selectedMediaItemID = mediaClipboard.last.map { _ in
            visibleMediaItems.last?.id
        } ?? selectedMediaItemID
    }

    func duplicateMedia(id: UUID) {
        guard let item = mediaItem(id: id) else { return }
        addMediaToSelectedCollection(item.copyAsNew())
    }

    func renameMedia(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateMedia(id: id) { $0.title = trimmed }
    }

    func deleteMedia(_ ids: [UUID]) {
        let doomed = Set(ids)
        for index in mediaCollections.indices {
            mediaCollections[index].items.removeAll { doomed.contains($0.id) }
        }
        importedMedia.removeAll { doomed.contains($0.id) }
        if selectedMediaItemID.map(doomed.contains) == true {
            selectedMediaItemID = nil
        }
        persistMediaLibrary()
    }

    func cleanUpMedia(by key: String) {
        let sort: (MediaBinItem, MediaBinItem) -> Bool = { lhs, rhs in
            switch key {
            case "Kind":
                return lhs.kindLabel.localizedCaseInsensitiveCompare(rhs.kindLabel) == .orderedAscending
            case "Duration":
                return lhs.durationSort.localizedStandardCompare(rhs.durationSort) == .orderedAscending
            default:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        if let id = selectedCollectionID, let index = mediaCollections.firstIndex(where: { $0.id == id }) {
            mediaCollections[index].items.sort(by: sort)
            return
        }
        for index in mediaCollections.indices where mediaCollections[index].source == selectedMediaSource {
            mediaCollections[index].items.sort(by: sort)
        }
    }

    var mediaProjectRoot: URL? {
        projectAutosave?.bundle.root ?? playback.projectRoot
    }

    func mediaFileURL(id: UUID) -> URL? {
        MediaPath.resolve(mediaItem(id: id)?.filePath, projectRoot: mediaProjectRoot)
    }

    func mediaArtworkURL(for item: MediaBinItem) -> URL? {
        guard let resolved = MediaPath.resolve(item.filePath, projectRoot: mediaProjectRoot) else { return nil }
        switch item.kind {
        case .image:
            return resolved
        case .video:
            let thumb = mediaThumbnailURL(for: resolved)
            if FileManager.default.fileExists(atPath: thumb.path) {
                return thumb
            }
            if (try? AssetPreview.writeVideoPoster(from: resolved, to: thumb)) != nil {
                return thumb
            }
            return nil
        default:
            return nil
        }
    }

    func mediaThumbnailURL(for mediaURL: URL) -> URL {
        let name = mediaURL.deletingPathExtension().lastPathComponent + ".png"
        if let thumbs = projectAutosave?.bundle.thumbnailsURL {
            return thumbs.appendingPathComponent(name)
        }
        if let root = mediaProjectRoot {
            return root
                .appendingPathComponent("Transcoded/Thumbnails", isDirectory: true)
                .appendingPathComponent(name)
        }
        return mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("Thumbs", isDirectory: true)
            .appendingPathComponent(name)
    }

    func hydrateSeedMedia() {
        playback.projectRoot = mediaProjectRoot ?? playback.projectRoot
        MediaPath.currentProjectRoot = playback.projectRoot
        restoreMediaLibrary()
        hydrateSoundboardWaveforms()
        rebuildSearchIndex()
    }

    func hydrateSoundboardWaveforms() {
        guard let root = mediaProjectRoot else { return }
        var pads = soundboard.pads
        for index in pads.indices {
            let name = URL(fileURLWithPath: pads[index].relativePath).deletingPathExtension().lastPathComponent
            let json = root.appendingPathComponent("Transcoded/Waveforms/\(name).json")
            if let data = try? Data(contentsOf: json),
               let peaks = try? JSONDecoder().decode([Double].self, from: data),
               !peaks.isEmpty {
                pads[index].waveform = peaks
                continue
            }
            let audio = MediaPath.resolve(pads[index].relativePath, projectRoot: root)
            if let audio, let peaks = try? AssetPreview.waveformPeaks(fromAudioFile: audio) {
                pads[index].waveform = peaks.map(Double.init)
            }
        }
        soundboard.install(pads)
    }

    func persistCurrentShow() {
        if editors.kind == .presentation {
            var next = show
            let changed = editors.rehydrate(into: &next)
            if !changed.isEmpty {
                show = next
            }
        }
        noteProgramMutation()
        documentState.noteDocumentMutation(entityId: show.id)
        bumpProjectSaveRevision()
        syncProgramOutlineFromActiveShowIfNeeded()
        if show.id == ProgramOutlinePresentation.showID {
            persistProgramEdits()
        } else {
            try? store.save(show)
        }
        if let index = libraryShows.firstIndex(where: { $0.id == show.id }) {
            libraryShows[index] = show
        }
        if let autosave = projectAutosave {
            autosave.markDirty(show: show, state: captureWorkspaceState(), playlist: playlist)
            try? autosave.record(.upsertLibrary(show))
            try? autosave.record(.updateState(captureWorkspaceState()))
            persistStudio(to: autosave)
        }
    }

    func flushPendingSaves() throws {
        persistCurrentShow()
        try projectAutosave?.flushPendingSaves()
    }

    func syncLibraryItems() {
        libraryItems = playlist.items.map { item in
            LibraryShowItem(
                id: item.id,
                title: item.title,
                subtitle: item.detail,
                isActive: item.showID == show.id,
                showID: item.showID
            )
        }
    }

    func muteRemoteAudio(channel: Int?, muted: Bool) -> Bool {
        if let channel {
            if let layer = RenderLayer(rawValue: channel) {
                compositor.setLayerAudioMuted(layer, muted: muted)
                applyProgramAudioMute()
                return true
            }
            if audioMatrix.channels.indices.contains(channel) {
                audioMatrix.setMute(id: audioMatrix.channels[channel].id, muted: muted)
                return true
            }
            return false
        }
        audioMatrix.muteProgram(muted)
        audioIO.muteProgram(muted)
        applyProgramAudioMute()
        return true
    }

    func switchCameraInput(sourceID: String) -> Bool {
        let needle = sourceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }
        for (index, layer) in masterLayers.enumerated() {
            if let shot = layer.shots.first(where: {
                $0.source.id.lowercased() == needle
                    || $0.source.name.lowercased() == needle
                    || $0.source.connectionString?.lowercased() == needle
            }) {
                takeShotLive(shot, layerIndex: index)
                return true
            }
        }
        return false
    }

    func clearLayer(named name: String) -> Bool {
        let key = name.lowercased().replacingOccurrences(of: "-", with: "_")
        if let index = Int(key), let layer = RenderLayer(rawValue: index) {
            hideLayer(layer)
            return true
        }
        if key.hasPrefix("layer"), let index = Int(key.dropFirst(5)), let layer = RenderLayer(rawValue: index) {
            hideLayer(layer)
            return true
        }
        if key == "audio" {
            toggleAudioMute()
            return true
        }
        if key == "all" || key == "clear_all" {
            toggleAllLayers()
            return true
        }
        guard let layer = RenderLayer.parse(name) else { return false }
        toggleLayer(layer)
        return true
    }

    func toggleLayer(_ layer: RenderLayer) {
        if compositor.stack.isCleared(layer) {
            restoreLayer(layer)
        } else {
            hideLayer(layer)
        }
    }

    func hideLayer(_ layer: RenderLayer) {
        compositor.clear(layer)
        if layer == .media {
            applyProgramAudioMute()
        }
        if layer == .videoInput {
            reconcileAudioCaptureGraph()
        }
        tickProgram()
    }

    func isActionLayerLocked(_ layer: RenderLayer) -> Bool {
        compositor.isLayerLocked(layer)
    }

    func setActionLayerLocked(_ layer: RenderLayer, locked: Bool) {
        compositor.setLayerLocked(layer, locked: locked)
    }

    func toggleActionLayerLock(_ layer: RenderLayer) {
        compositor.toggleLayerLock(layer)
    }

    func clearActionLayer(_ layer: RenderLayer) {
        emptyProgramLayer(layer)
    }

    var actionStackSlots: [LayerSlotState] {
        let transport = playback.snapshot()
        return RenderLayer.allCases.reversed().map { layer in
            let stack = compositor.stack
            let cleared = stack.isCleared(layer)
            var playhead: TimeInterval?
            var duration: TimeInterval?
            var playing = false
            if layer == .media, stack.media != nil, !cleared {
                playhead = transport.playhead
                duration = transport.duration
                playing = transport.isPlaying
            }
            return LayerSlotState(
                layer: layer,
                isLocked: compositor.isLayerLocked(layer),
                isCleared: cleared,
                isActive: !cleared && layer.hasContent(in: stack),
                title: layer.title,
                detail: layer.contentSummary(in: stack),
                playhead: playhead,
                duration: duration,
                isPlaying: playing
            )
        }
    }

    func restoreLayer(_ layer: RenderLayer) {
        compositor.restore(layer)
        switch layer {
        case .slide:
            isAudienceCleared = false
        case .media:
            applyProgramAudioMute()
        case .videoInput:
            videoInputRunning = compositor.stack.videoInput != nil
        case .props, .messages, .announcements, .mask, .screenColor:
            break
        }
        tickProgram()
    }

    func soloProgramLayer(_ layer: RenderLayer) {
        if soloedProgramLayer == layer {
            endProgramSolo(restoring: true)
            return
        }
        if soloVisibilitySnapshot == nil {
            soloVisibilitySnapshot = (compositor.stack.cleared, compositor.stack.audioMuted)
        }
        soloedProgramLayer = layer
        for other in RenderLayer.allCases where other != layer {
            compositor.clear(other)
        }
        compositor.restore(layer)
        tickProgram()
    }

    func endProgramSolo(restoring: Bool) {
        let snapshot = soloVisibilitySnapshot
        soloedProgramLayer = nil
        soloVisibilitySnapshot = nil
        if restoring, let snapshot {
            compositor.replaceVisibility(cleared: snapshot.cleared, audioMuted: snapshot.audioMuted)
            tickProgram()
        }
    }

    func emptyProgramLayer(_ layer: RenderLayer) {
        switch layer {
        case .screenColor:
            compositor.setScreenColor("#000000")
        case .videoInput:
            compositor.clearProgramVideoInput()
            compositor.clear(.videoInput)
            videoInputRunning = false
            reconcileAudioCaptureGraph()
        case .media:
            compositor.clearProgramMedia()
            compositor.clear(.media)
            inspector.pauseTransport()
            inspector.bindMedia(nil)
            isMediaPlaying = false
            playback.load(nil)
        case .slide:
            cancelSlideLeave()
            compositor.clearProgramSlide()
        case .announcements:
            compositor.setAnnouncement(nil)
        case .props:
            inspector.deactivateAllProps()
            finishAllPropBuilds()
            syncActivePropsToCompositor()
        case .messages:
            hideInspectorMessage()
            compositor.setChatOverlay(nil)
        case .mask:
            compositor.setMaskEnabled(false)
        }
        tickProgram()
        refreshLiveStack()
    }

    func toggleAllLayers() {
        let allHidden = RenderLayer.allCases.allSatisfy { compositor.stack.isCleared($0) }
            && (compositor.stack.audioMuted || audioIO.programMuted)
        if allHidden {
            restoreAllLayers()
        } else {
            hideAllLayers()
        }
    }

    func hideAllLayers() {
        endProgramSolo(restoring: false)
        compositor.clearAllLayers()
        audioIO.muteProgram(true)
        audioMatrix.muteProgram(true)
        applyProgramAudioMute()
        tickProgram()
        refreshLiveStack()
    }

    func restoreAllLayers() {
        endProgramSolo(restoring: false)
        compositor.restoreAllLayers()
        audioIO.muteProgram(false)
        audioMatrix.muteProgram(false)
        isAudienceCleared = false
        videoInputRunning = compositor.stack.videoInput != nil
        applyProgramAudioMute()
        tickProgram()
        refreshLiveStack()
    }

    func toggleAudioMute() {
        let muted = !(audioIO.programMuted || compositor.stack.audioMuted)
        if muted {
            compositor.clearAudio()
            audioIO.muteProgram(true)
            audioMatrix.muteProgram(true)
        } else {
            compositor.restoreAudio()
            audioIO.muteProgram(false)
            audioMatrix.muteProgram(false)
        }
        tickProgram()
    }

    @discardableResult
    func playSoundboardPad(_ id: UUID) -> Bool {
        guard soundboard.play(id), let pad = soundboard.pad(id: id) else { return false }
        audioIO.playPad(pad, fileURL: resolvedSoundboardURL(pad))
        tickProgram()
        return true
    }

    private func resolvedSoundboardURL(_ pad: SoundboardPad) -> URL? {
        guard !pad.relativePath.isEmpty else { return nil }
        if let root = projectAutosave?.bundle.root {
            let candidate = root.appendingPathComponent(pad.relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func clearAudio() {
        compositor.clearAudio()
        inspector.stopAudioTracks()
        soundboard.stopAll()
        audioIO.stopAllPads()
        audioIO.muteProgram(true)
        audioMatrix.muteProgram(true)
        tickProgram()
    }

    func clearAllLayers() {
        hideAllLayers()
    }

    func syncActivePropsToCompositor() {
        let live = inspector.props.filter { $0.isActive || propBuildClearStartedAt[$0.id] != nil }
        compositor.setActiveProps(
            live.map(\.name),
            canvases: live.map {
                PropCanvas(
                    id: $0.id,
                    name: $0.name,
                    objects: resolvedCanvasObjects($0.elements),
                    canvasWidth: CanvasConfig.width,
                    canvasHeight: CanvasConfig.height,
                    buildStartedAt: propBuildStartedAt[$0.id],
                    buildClearStartedAt: propBuildClearStartedAt[$0.id]
                )
            }
        )
    }

    @discardableResult
    func toggleInspectorProp(id: UUID, at date: Date = Date()) -> Bool {
        guard inspector.toggleProp(id: id, now: date) else { return false }
        if inspector.props.contains(where: { $0.id == id && $0.isActive }) {
            beginPropEnter(id: id, at: date)
            evaluateProgramClockState()
        } else {
            _ = beginPropExit(id: id, at: date)
        }
        syncActivePropsToCompositor()
        refreshLiveStack()
        return true
    }

    @discardableResult
    func showInspectorMessage(id: UUID) -> Bool {
        guard let text = inspector.showMessage(id: id) else { return false }
        compositor.setMessages([OutputMessage(id: id, text: text)])
        return true
    }

    func hideInspectorMessage(id: UUID? = nil) {
        inspector.hideMessage(id: id)
        compositor.setMessage(nil)
        compositor.setMessages([])
    }

    func applyStageLayout(id: UUID) {
        applyStageVariant(id)
    }

    func activateSearchHit(_ hit: SearchHit) {
        switch hit.kind {
        case .presentation:
            if hit.id.hasPrefix("show-"), let id = UUID(uuidString: String(hit.id.dropFirst(5))) {
                loadPresentation(id: id)
            } else if hit.id.hasPrefix("slide-"), let id = UUID(uuidString: String(hit.id.dropFirst(6))) {
                select(id)
            }
        case .media:
            if hit.id.hasPrefix("media-"), let id = UUID(uuidString: String(hit.id.dropFirst(6))),
               let item = mediaItem(id: id) {
                triggerMedia(item, takeProgram: true)
            }
        case .playlist:
            openMediaPane(source: .playlists)
        case .library:
            openMediaPane(source: .libraries)
        case .bible:
            guard BibleEngine.hasTranslationPackage else { return }
            if let passage = BibleEngine.lookup(hit.title, passages: BibleEngine.installedPassages).first {
                triggerBible(passage)
            }
        }
    }

    func transportPlayPause() {
        inspector.toggleTransport()
        isMediaPlaying = playback.isPlaying
        tickProgram()
    }

    func triggerMacro(id: UUID) -> Bool {
        if compositor.executeMacro(id: id, triggerSlide: { [weak self] index in
            self?.triggerIndex(index)
        }) {
            return true
        }
        return executeInspectorMacro(id: id)
    }

    @discardableResult
    func executeInspectorMacro(id: UUID) -> Bool {
        guard let macro = inspector.macros.first(where: { $0.id == id }) else { return false }
        inspector.lastExecutedMacroID = id
        inspector.selectedMacroID = id
        for action in macro.actions {
            applyMacroAction(action)
        }
        return true
    }

    func applyMacroAction(_ action: MacroAction) {
        switch action {
        case .clearLayer(let name):
            _ = clearLayer(named: name)
        case .triggerScene(let id):
            _ = triggerScene(id: id)
        case .setStageLayout(let id):
            applyStageLayout(id: id)
        case .startTimer(let id):
            _ = inspector.startTimer(id: id)
        case .stopTimer(let id):
            _ = inspector.stopTimer(id: id)
        case .resetTimer(let id):
            _ = inspector.resetTimer(id: id)
        case .triggerProp(let id):
            if let prop = inspector.props.first(where: { $0.id == id }), !prop.isActive {
                _ = toggleInspectorProp(id: id)
            } else {
                syncActivePropsToCompositor()
            }
        case .playAudioTrack(let id):
            if let track = inspector.playAudioTrack(id: id) {
                compositor.triggerCue(
                    OutputCue(
                        id: track.id,
                        presentationId: show.id,
                        slideIndex: liveIndex ?? 0,
                        layers: CueLayers(audioAction: AudioTrack(id: track.id, title: track.title))
                    )
                )
            }
        case .playSoundboard(let id):
            _ = playSoundboardPad(id)
        case .playVideo(let id):
            if let item = mediaItem(id: id) {
                triggerMedia(item, takeProgram: true)
            }
        case .setAudienceLook(let name):
            switch name {
            case AudienceLookConfig.alphaKey.name: compositor.setAudienceLook(.alphaKey)
            case AudienceLookConfig.slideAndMedia.name: compositor.setAudienceLook(.slideAndMedia)
            default: compositor.setAudienceLook(.fullStack)
            }
        case .startStream:
            Task { _ = await startBroadcastForArmedAccounts() }
        case .stopStream:
            streaming.stop()
        case .startISO:
            _ = startProgramRecording()
        case .stopISO:
            stopProgramRecording()
        case .muteAudio:
            clearAudio()
        }
    }

    func installStudio(_ manifest: StudioManifest) {
        videoInputs.install(manifest.videoSources)
        audioMatrix.install(manifest.audioChannels)
        soundboard.install(manifest.soundboard)
        scenes.install(manifest.scenes, activeID: manifest.activeSceneID)
        if let scene = scenes.activeScene {
            scenes.apply(scene, compositor: compositor, video: videoInputs, audio: audioMatrix)
        }
        inspector.install(manifest.inspector)
        restoreMediaLibrary(from: manifest)
        if !manifest.placeholderMatrix.isEmpty {
            placeholderMatrix.install(manifest.placeholderMatrix)
        }
        placeholderMatrix.installGraph(manifest.mapGraph, links: manifest.mapLinks, backdrops: manifest.mapBackdrops)
        refreshPlaceholderRoutes()
        if !manifest.textFields.isEmpty {
            textFields = manifest.textFields
        }
        syncTextFieldsFromCanvas()
        if videoInputs.hardwareEnabled {
            videoInputs.refreshDevices()
            compositor.syncVideoInputs(from: videoInputs)
        }
    }

    func studioSnapshot() -> StudioManifest {
        StudioManifest(
            scenes: scenes.scenes,
            soundboard: soundboard.pads,
            videoSources: videoInputs.sources,
            audioChannels: audioMatrix.channels,
            activeSceneID: scenes.activeSceneID,
            inspector: inspector.snapshot(),
            mediaCollections: mediaCollections.withoutLegacyProContent,
            importedMedia: importedMedia,
            placeholderMatrix: placeholderMatrix.placeholders,
            mapGraph: placeholderMatrix.graphPlacements,
            mapLinks: placeholderMatrix.graphLinks,
            mapBackdrops: placeholderMatrix.graphBackdrops,
            textFields: textFields
        )
    }

    func persistStudio(to autosave: AutoSaveEngine? = nil) {
        guard let engine = autosave ?? projectAutosave else { return }
        var manifest = engine.bundle.manifest
        streamMatrix.projectId = manifest.id
        manifest.studio = studioSnapshot()
        manifest.settings = projectSettings
        manifest.streamMatrix = streamMatrix
        manifest.updatedAt = Date()
        try? engine.record(.updateManifest(manifest))
        try? engine.record(.updateState(captureWorkspaceState()))
    }

    func setStreamDestination(_ id: UUID, enabled: Bool) {
        if let projectId = projectAutosave?.bundle.manifest.id {
            streamMatrix.projectId = projectId
        }
        if enabled {
            streamMatrix.activeAccountIds.insert(id)
        } else {
            streamMatrix.activeAccountIds.remove(id)
        }
        applyActiveStreamMatrix()
        persistStudio()
    }

    func applyActiveStreamMatrix() {
        let accounts = deviceSettings.document.accounts.filter { streamMatrix.isActive($0.id) }
        if accounts.count >= 2 {
            streaming.setRelayDestinations(accounts.map {
                RelayDestination(
                    id: $0.id,
                    name: $0.accountName,
                    url: $0.rtmpUrl,
                    streamKey: KeychainStreamVault.load(identifier: $0.keychainStreamKeyIdentifier) ?? ""
                )
            })
            if let primary = accounts.first {
                streaming.config.destinationURL = primary.rtmpUrl
                streaming.config.streamKey = KeychainStreamVault.load(identifier: primary.keychainStreamKeyIdentifier) ?? ""
            }
            return
        }
        streaming.config.useCloudRelay = false
        streaming.config.relayDestinations = []
        if let account = accounts.first {
            streaming.config.destinationURL = account.rtmpUrl
            streaming.config.streamKey = KeychainStreamVault.load(identifier: account.keychainStreamKeyIdentifier) ?? ""
        }
    }

    func persistProjectSettings() {
        persistStudio()
    }

    func applyProjectSettings(
        _ settings: ProjectSettings,
        persist: Bool = true,
        rescaleFrom previous: ProjectSettings? = nil
    ) {
        var next = settings
        if next.programFilePath == nil {
            next.programFilePath = projectSettings.programFilePath
        }
        if next.programFileBookmark == nil {
            next.programFileBookmark = projectSettings.programFileBookmark
        }
        next.syncDerivedFields()
        let from = previous ?? projectSettings
        let scale = CanvasConfig.scaleFactor(from: from.resolution, to: next.resolution)
        let shouldRescale = next.scaleContentOnResolutionChange && from.resolution != next.resolution
        if shouldRescale {
            show = CanvasRescaleEngine.rescale(show, by: scale)
            libraryShows = libraryShows.map { CanvasRescaleEngine.rescale($0, by: scale) }
            editors.applyCanvasSize(
                width: Double(next.resolution.width),
                height: Double(next.resolution.height),
                scaleObjects: true,
                scale: scale
            )
            scenes.scenes = scenes.scenes.map { scene in
                var scene = scene
                scene.primaryBounds = CanvasRescaleEngine.rescale(scene.primaryBounds, by: scale)
                if let pip = scene.pipBounds {
                    scene.pipBounds = CanvasRescaleEngine.rescale(pip, by: scale)
                }
                return scene
            }
        } else {
            editors.applyCanvasSize(
                width: Double(next.resolution.width),
                height: Double(next.resolution.height),
                scaleObjects: false,
                scale: 1
            )
        }
        projectSettings = next
        compositor.applyProjectSettings(next)
        programRenderer.ensureTextures(width: next.resolution.width, height: next.resolution.height)
        videoInputs.ingest.configureOutput(
            width: next.resolution.width,
            height: next.resolution.height,
            fps: next.frameRate.encoderFPS,
            captureAboveOutput: next.captureAboveOutput
        )
        streaming.applyProjectSettings(next)
        isoRecorder.width = next.resolution.width
        isoRecorder.height = next.resolution.height
        isoRecorder.fps = next.frameRate.encoderFPS
        virtualCamera.width = next.resolution.width
        virtualCamera.height = next.resolution.height
        virtualCamera.fps = next.frameRate.encoderFPS
        virtualCameraOutput?.syncProjectOutput(
            width: next.resolution.width,
            height: next.resolution.height,
            fps: next.frameRate.encoderFPS
        )
        if persist {
            persistCurrentShow()
        }
        applyLocalPreviewRenderQuality()
    }

    @discardableResult
    func triggerScene(id: UUID) -> Bool {
        guard let scene = scenes.scenes.first(where: { $0.id == id }) else { return false }
        let outgoing = scenes.activeSceneID
        compositor.captureOutgoingForTransition()
        scenes.apply(scene, compositor: compositor, video: videoInputs, audio: audioMatrix)
        beginBoundTransition(presetID: scene.transitionPresetID ?? "dissolve", workspace: .sceneManager, incomingSceneID: scene.id, outgoingSceneID: outgoing)
        persistStudio()
        return true
    }

    func applyTransitionPreset(_ preset: TransitionPreset, workspace: TransitionBindingWorkspace) {
        switch workspace {
        case .slideInspector:
            if let id = selectedSlideID {
                setSlideTransition(preset.id, id: id)
            }
            slideTransitionSeconds = Double(max(preset.defaultDurationMs, 0)) / 1000
            editors.mutateSelectedDocument {
                $0.transition = preset.id
                $0.transitionDuration = Double(preset.defaultDurationMs) / 1000
            }
        case .sceneManager:
            if let active = scenes.activeSceneID,
               let index = scenes.scenes.firstIndex(where: { $0.id == active })
            {
                scenes.scenes[index].transitionPresetID = preset.id
                persistStudio()
            }
        case .mapMatrix:
            controllerAssignMapTransition(preset)
        }
    }

    func beginBoundTransition(
        presetID: String,
        workspace: TransitionBindingWorkspace,
        incomingSceneID: UUID?,
        outgoingSceneID: UUID? = nil
    ) {
        let preset = TransitionCatalog.preset(id: presetID)
        let duration = resolvedTransitionDuration(preset: preset, workspace: workspace)
        if preset.category == .alphaStinger, let incoming = incomingSceneID {
            stingerPlayer.start(cue: .flameWipe, from: outgoingSceneID, to: incoming)
        }
        compositor.beginProgramTransition(preset: preset, duration: duration)
        if let shader = preset.shader {
            let from = TransitionImage.solid(RGBA8(r: 0.1, g: 0.1, b: 0.12, a: 1), width: 8, height: 8)
            let to = TransitionImage.solid(RGBA8(r: 0.42, g: 0.62, b: 0.88, a: 1), width: 8, height: 8)
            _ = transitionShaders.composite(
                effect: shader,
                from: from,
                to: to,
                uniforms: .make(progress: 0, duration: max(duration, 0.001), width: 8, height: 8, intensity: preset.intensity)
            )
        }
    }

    private func resolvedTransitionDuration(preset: TransitionPreset, workspace: TransitionBindingWorkspace) -> TimeInterval {
        if TransitionCatalog.preset(id: preset.id).id == "cut" { return 0 }
        if workspace == .slideInspector,
           let slideID = liveSlideID ?? selectedSlideID,
           let document = editors.documents.first(where: { $0.slideID == slideID }),
           document.transitionDuration > 0.02 {
            return document.transitionDuration
        }
        if slideTransitionSeconds > 0.02 {
            return slideTransitionSeconds
        }
        return Double(max(preset.defaultDurationMs, 0)) / 1000
    }

    private func controllerAssignMapTransition(_ preset: TransitionPreset) {
        guard let selected = placeholderMatrix.selected else { return }
        updatePlaceholder(selected.id) {
            $0.transitionPresetID = preset.id
            $0.entranceTransition = TransitionCatalog.physicsStyle(forPresetID: preset.id)
            $0.exitTransition = TransitionCatalog.physicsStyle(forPresetID: preset.id)
            $0.transitionDurationSec = Double(max(preset.defaultDurationMs, 1)) / 1000
        }
    }

    @discardableResult
    func triggerSceneHotkey(_ digit: String) -> Bool {
        guard let scene = scenes.triggerHotkey(digit) else { return false }
        return triggerScene(id: scene.id)
    }

    /// Measurement ingest only. Armed YouTube, LinkedIn, and X accounts stay unused.
    private static func loopbackStreamOverride(_ parsed: [String: String]) -> (url: String, key: String)? {
        let url = parsed["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let host = URL(string: url)?.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost"
        else { return nil }
        let key = parsed["key"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (url, key)
    }

    func handleControl(method: String, path: String, body: Data? = nil) -> (Int, String) {
        if !ControlHTTP.allowedMethod(for: path, method: method) {
            return (405, #"{"ok":false,"error":"method_not_allowed"}"#)
        }
        if let remote = RemoteControlBridge.parseREST(method: method, path: path, body: ControlHTTP.jsonObject(body)) {
            return RemoteControlBridge.apply(remote, to: self)
        }
        let parts = path.split(separator: "/").map(String.init)
        if method == "GET", path == "/docs" || path == "/docs/" {
            return (200, ControlAPIOpenAPI.html(port: ControlAPIServer.defaultPort))
        }
        if method == "GET", path == "/openapi.json" || path == "/docs/openapi.json" {
            return (200, ControlAPIOpenAPI.json(port: ControlAPIServer.defaultPort))
        }
        if method == "GET", parts == ["v1", "status"] {
            return (200, ControlJSON.encode([
                "ok": true,
                "is_streaming": streaming.isLive,
                "is_recording": isoRecorder.isRecording,
                "active_slide_index": liveIndex.map { $0 as Any } ?? NSNull(),
                "live_slide_id": liveSlideID?.uuidString ?? NSNull(),
                "show_id": show.id.uuidString,
                "ndi_available": NDIRuntime.isAvailable,
                "guest_return": liveKitGuestReturnActive,
                "guest_count": liveKitDesk.guests.count,
                "guest_status": liveKitDesk.status,
            ]))
        }
        if method == "GET", parts == ["v1", "presentation", "active", "next", "trigger"] {
            advance()
            return (200, ControlJSON.encode(["ok": true, "action": "next", "index": liveIndex.map { $0 as Any } ?? NSNull()]))
        }
        if method == "GET", parts == ["v1", "presentation", "active", "prev", "trigger"] {
            goPrevious()
            return (200, ControlJSON.encode(["ok": true, "action": "prev", "index": liveIndex.map { $0 as Any } ?? NSNull()]))
        }
        if method == "POST", parts == ["v1", "slides", "hold"] {
            let parsed = ControlHTTP.jsonObject(body)
            let slides = show.groups.flatMap(\.slides)
            guard let index = parsed["index"].flatMap(Int.init), slides.indices.contains(index),
                  slides[index].mediaAction != nil
            else { return (404, #"{"ok":false,"error":"no_media_cue"}"#) }
            let hold = parsed["hold"] == "true" || parsed["hold"] == "1"
            mutateSlide(id: slides[index].id) { $0.mediaAction?.hold = hold }
            return (200, ControlJSON.encode(["ok": true, "index": index, "hold": hold]))
        }
        if method == "POST", parts == ["v1", "slides", "trigger"] {
            let parsed = ControlHTTP.jsonObject(body)
            let presentationID = parsed["presentation_id"].flatMap(UUID.init(uuidString:))
            guard let index = parsed["index"].flatMap(Int.init) else {
                return (400, #"{"ok":false,"error":"missing_index"}"#)
            }
            let ok = triggerSlide(presentationID: presentationID, index: index)
            return (ok ? 200 : 404, ControlJSON.encode(["ok": ok, "action": "trigger_slide_index", "index": index]))
        }
        if method == "POST", parts == ["v1", "stream", "start"] || parts == ["v1", "capture", "start"] {
            let parsed = ControlHTTP.jsonObject(body)
            if let loopback = Self.loopbackStreamOverride(parsed) {
                streaming.config.useCloudRelay = false
                streaming.config.relayDestinations = []
                streaming.config.destinationURL = loopback.url
                streaming.config.streamKey = loopback.key
                let ok = streaming.start(ingestPolicies: [])
                publishCurrentPhoneCanvas()
                return (ok ? 200 : 400, ControlJSON.encode(["ok": ok, "state": streaming.state.rawValue, "is_streaming": streaming.isLive]))
            }
            let ok = streaming.start(ingestPolicies: PlatformIngestPolicy.policies(for: armedStreamAccounts()))
            publishCurrentPhoneCanvas()
            return (ok ? 200 : 400, ControlJSON.encode(["ok": ok, "state": streaming.state.rawValue, "is_streaming": streaming.isLive]))
        }
        if method == "POST", parts == ["v1", "stream", "stop"] || parts == ["v1", "capture", "stop"] {
            streaming.stop()
            return (200, #"{"ok":true,"state":"idle","is_streaming":false}"#)
        }
        if method == "POST", parts == ["v1", "record", "start"] {
            let ok = startProgramRecording()
            let path: Any = isoRecorder.programFileURL?.path ?? NSNull()
            return (200, ControlJSON.encode(["ok": ok, "is_recording": isoRecorder.isRecording, "path": path]))
        }
        if method == "POST", parts == ["v1", "project", "open"] {
            let parsed = ControlHTTP.jsonObject(body)
            let path = parsed["path"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty, ProjectBundle.isBundle(at: URL(fileURLWithPath: path)) else {
                return (400, #"{"ok":false,"error":"missing_project"}"#)
            }
            NotificationCenter.default.post(name: .proShowControlOpenProject, object: path)
            return (200, #"{"ok":true,"action":"open_project"}"#)
        }
        if method == "POST", parts == ["v1", "backstage", "disconnect"] {
            liveKitDesk.disconnect()
            return (200, ControlJSON.encode(["ok": true, "guest_status": liveKitDesk.status]))
        }
        if method == "POST", parts == ["v1", "backstage", "connect"] {
            let parsed = ControlHTTP.jsonObject(body)
            if ["1", "true"].contains(parsed["force"]?.lowercased() ?? "") {
                liveKitDesk.connect(roomSlug: backstage.room.roomSlug)
            } else {
                activateGuestRoomIfNeeded()
            }
            return (200, ControlJSON.encode([
                "ok": true,
                "guest_return": liveKitGuestReturnActive,
                "guest_count": liveKitDesk.guests.count,
                "guest_status": liveKitDesk.status,
            ]))
        }
        if method == "POST", parts == ["v1", "project", "close"] {
            NotificationCenter.default.post(name: .proShowControlCloseProject, object: nil)
            return (200, #"{"ok":true,"action":"close_project"}"#)
        }
        if method == "POST", parts == ["v1", "record", "stop"] {
            let path: Any = isoRecorder.programFileURL?.path ?? NSNull()
            stopProgramRecording()
            return (200, ControlJSON.encode(["ok": true, "is_recording": false, "path": path]))
        }
        if method == "POST", parts == ["v1", "market", "ticker"] {
            #if os(macOS)
            if let body {
                MarketDataStreamEngine.shared.ingestWebhookJSON(body)
            }
            #endif
            return (200, #"{"ok":true,"action":"market_ticker_ingest"}"#)
        }
        // /v1/presentation/active/{index}/trigger
        if method == "GET", parts == ["v1", "presentation", "active"] || (parts.count == 5 && parts[0] == "v1" && parts[1] == "presentation" && parts[2] == "active" && parts[4] == "trigger") {
            if parts.count == 5, let index = Int(parts[3]) {
                triggerIndex(index)
                return (200, #"{"ok":true,"action":"trigger","index":\#(index)}"#)
            }
        }
        // /v1/clear/layer/{layer_name}
        if method == "GET", parts.count == 4, parts[0] == "v1", parts[1] == "clear", parts[2] == "layer" {
            let ok = clearLayer(named: parts[3])
            return (ok ? 200 : 404, #"{"ok":\#(ok),"layer":"\#(parts[3])"}"#)
        }
        // /v1/library/{library_id}/{presentation_id}/trigger
        if method == "GET", parts.count == 5, parts[0] == "v1", parts[1] == "library", parts[4] == "trigger" {
            goLive()
            return (200, #"{"ok":true,"action":"library_trigger"}"#)
        }
        // /v1/macro/{macro_id}/trigger
        if method == "GET", parts.count == 4, parts[0] == "v1", parts[1] == "macro", parts[3] == "trigger" {
            guard let id = UUID(uuidString: parts[2]) else {
                return (400, #"{"ok":false,"error":"bad_macro_id"}"#)
            }
            let ok = triggerMacro(id: id)
            return (ok ? 200 : 404, #"{"ok":\#(ok)}"#)
        }
        if method == "GET", parts == ["v1", "health"] {
            return (200, #"{"ok":true,"service":"proshow-control"}"#)
        }
        if method == "GET", parts == ["v1", "scenes"] {
            let rows = scenes.scenes.map {
                #"{"id":"\#($0.id.uuidString)","name":"\#($0.name)","hotKey":"\#($0.hotKey)"}"#
            }.joined(separator: ",")
            return (200, #"{"ok":true,"active":"\#(scenes.activeSceneID?.uuidString ?? "")","scenes":[\#(rows)]}"#)
        }
        if parts.count == 4, parts[0] == "v1", parts[1] == "scenes", parts[3] == "trigger" {
            guard let id = UUID(uuidString: parts[2]) else {
                return (400, #"{"ok":false,"error":"bad_scene_id"}"#)
            }
            let ok = triggerScene(id: id)
            return (ok ? 200 : 404, #"{"ok":\#(ok),"action":"scene_trigger"}"#)
        }
        if method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "soundboard", parts[3] == "play" {
            guard let id = UUID(uuidString: parts[2]) else {
                return (400, #"{"ok":false,"error":"bad_pad_id"}"#)
            }
            let ok = playSoundboardPad(id)
            return (ok ? 200 : 404, #"{"ok":\#(ok),"action":"soundboard_play"}"#)
        }
        if method == "POST", parts == ["v1", "chat", "overlay"] {
            let parsed = ControlHTTP.jsonObject(body)
            let author = parsed["author"] ?? "Guest"
            let text = parsed["text"] ?? ""
            let platform = ChatPlatform(rawValue: parsed["platform"] ?? "twitch") ?? .twitch
            guard !text.isEmpty else {
                return (400, #"{"ok":false,"error":"missing_text"}"#)
            }
            let card = chat.pushOverlay(ChatMessage(platform: platform, author: author, text: text))
            compositor.setChatOverlay(card)
            return (200, #"{"ok":true,"action":"chat_overlay","author":"\#(author)"}"#)
        }
        if method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "chat", parts[2] == "ingest" {
            let platform = parts[3]
            guard let body else {
                return (400, #"{"ok":false,"error":"missing_body"}"#)
            }
            guard let message = chat.ingestWebhook(platform: platform, body: body) else {
                return (400, #"{"ok":false,"error":"invalid_webhook"}"#)
            }
            chatStream?.ingest(message)
            return (200, ControlJSON.encode(["ok": true, "action": "chat_ingest", "author": message.senderName]))
        }
        if method == "POST", parts.count == 4, parts[0] == "v1", parts[1] == "backstage", parts[3] == "signal" {
            let roomSlug = parts[2]
            return backstageSignaling.handleREST(body, roomSlug: roomSlug)
        }
        if method == "GET", parts == ["v1", "layers"] {
            let rows: [[String: Any]] = masterLayers.enumerated().map { index, layer in
                let live = layer.liveShotID.flatMap { id in layer.shots.first(where: { $0.id == id }) }
                return [
                    "index": index,
                    "live_type": live.map { $0.source.sourceType.rawValue } ?? NSNull(),
                    "audio_muted": live?.isAudioMuted ?? false,
                ]
            }
            return (200, ControlJSON.encode(["ok": true, "mic_live": isProgramMicLive, "layers": rows]))
        }
        if method == "POST", parts == ["v1", "layers", "program-mute"] {
            // Same call the program stack mute button makes.
            let parsed = ControlHTTP.jsonObject(body)
            guard let raw = parsed["layer"].flatMap(Int.init), let layer = RenderLayer(rawValue: raw) else {
                return (400, #"{"ok":false,"error":"missing_layer"}"#)
            }
            let can = canMuteProgramLayer(layer)
            if can { toggleProgramLayerAudio(layer) }
            return (200, ControlJSON.encode(["ok": true, "can_mute": can, "muted": isProgramLayerAudioMuted(layer), "media_muted": isProgramMediaMuted]))
        }
        if method == "POST", parts == ["v1", "layers", "mic"] {
            // Test hook: take the system mic live on a layer, or clear that layer.
            let parsed = ControlHTTP.jsonObject(body)
            guard let index = parsed["index"].flatMap(Int.init), masterLayers.indices.contains(index) else {
                return (400, #"{"ok":false,"error":"missing_index"}"#)
            }
            if parsed["live"] == "false" || parsed["live"] == "0" {
                var layers = masterLayers
                layers[index].liveShotID = nil
                masterLayers = layers
                reconcileAudioCaptureGraph()
            } else {
                let item = DiscoveredSourceItem(
                    name: "Microphone", category: .all, groupName: "Audio",
                    sourceType: .systemMicrophone, connectionString: parsed["endpoint"] ?? ""
                )
                let shot = LayerShot(name: "Microphone", source: item)
                var layers = masterLayers
                layers[index].shots.append(shot)
                masterLayers = layers
                takeShotLive(shot, layerIndex: index)
            }
            return (200, ControlJSON.encode(["ok": true, "mic_live": isProgramMicLive]))
        }
        if method == "POST", parts == ["v1", "layers", "mute"] {
            let parsed = ControlHTTP.jsonObject(body)
            guard let index = parsed["index"].flatMap(Int.init), masterLayers.indices.contains(index) else {
                return (400, #"{"ok":false,"error":"missing_index"}"#)
            }
            let want = parsed["muted"].map { $0 == "true" || $0 == "1" } ?? !isLiveShotAudioMuted(layerIndex: index)
            if isLiveShotAudioMuted(layerIndex: index) != want {
                toggleLiveShotAudio(layerIndex: index)
            }
            return (200, ControlJSON.encode(["ok": true, "index": index, "muted": isLiveShotAudioMuted(layerIndex: index), "mic_live": isProgramMicLive]))
        }
        if method == "GET", parts == ["v1", "audio", "meters"] {
            return (200, audioMatrix.metersJSON())
        }
        return (404, #"{"ok":false,"error":"not_found"}"#)
    }

    func reloadSample() {
        let blank = DefaultSeedData.blankShow()
        let hierarchy = DefaultSeedData.defaultLibraryHierarchy()
        show = blank
        playlist = hierarchy.playlist
        allPlaylists = [hierarchy.playlist]
        contentLibraries = [hierarchy.library]
        selectedContentLibraryID = hierarchy.library.id
        libraryShows = [blank]
        syncLibraryItems()
        selectedSlideID = show.allSlides.first?.id
        liveSlideID = nil
        isAudienceCleared = false
        isAudienceOutputOn = true
        isStageOutputOn = true
        operatorMode = .show
        selectedPlaylistItemTitle = show.name
        mediaCollections = DeskSampleData.emptyMediaCollections()
        importedMedia = []
        libraryFolders = []
        installStudio(DefaultSeedData.emptyStudioManifest())
        compositor.reset()
        streaming.stop()
        liveStack.reset()
        rebuildSearchIndex()
    }

    private func slideLocation(_ id: SlideID) -> (group: Int, slide: Int)? {
        for (groupIndex, group) in show.groups.enumerated() {
            if let slideIndex = group.slides.firstIndex(where: { $0.id == id }) {
                return (groupIndex, slideIndex)
            }
        }
        return nil
    }

    func mutateSlide(id: SlideID, _ body: (inout Slide) -> Void) {
        guard let loc = slideLocation(id) else { return }
        body(&show.groups[loc.group].slides[loc.slide])
        persistCurrentShow()
    }

    private func mutateMedia(id: UUID, _ body: (inout MediaBinItem) -> Void) {
        for collectionIndex in mediaCollections.indices {
            if let itemIndex = mediaCollections[collectionIndex].items.firstIndex(where: { $0.id == id }) {
                body(&mediaCollections[collectionIndex].items[itemIndex])
                return
            }
        }
        if let itemIndex = importedMedia.firstIndex(where: { $0.id == id }) {
            body(&importedMedia[itemIndex])
        }
    }

    func rebuildSearchIndex() {
        let media = mediaCollections.flatMap(\.items) + importedMedia
        searchIndex.rebuild(
            folders: contentLibraries.map {
                LibraryFolder(name: $0.name, systemImage: "folder.fill", children: [])
            },
            playlists: allPlaylists.map {
                LibraryFolder(name: $0.name, systemImage: "list.bullet.rectangle", children: [])
            },
            items: libraryItems,
            media: media,
            passages: BibleEngine.hasTranslationPackage ? BibleEngine.installedPassages : [],
            shows: libraryShows
        )
    }
}

struct IndexedCue: Identifiable {
    var number: Int
    var group: SlideGroup
    var slide: Slide
    var isGroupLead: Bool

    var id: SlideID { slide.id }
}

struct SlideTextStyle: Hashable, Codable, Sendable {
    var alignment: String
    var theme: String
}

struct DeskStatusAlert: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var detail: String
}
