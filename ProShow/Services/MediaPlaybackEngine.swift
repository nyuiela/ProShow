import Foundation
import CoreMedia
import CoreVideo
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreAudio)
import CoreAudio
#endif
#if canImport(MediaToolbox)
import MediaToolbox
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

struct MediaPlaybackProbeStats: Equatable {
    var control: String
    var rate: Float
    var playheadLabel: String
    var sourceFPS: Int
    var copied: Int
    var missed: Int
    var lastFrameAge: Double?
    var isWaiting: Bool

    var summaryLine: String {
        let ageText: String
        if let lastFrameAge {
            ageText = String(format: "%.1fs ago", lastFrameAge)
        } else {
            ageText = "never"
        }
        let headline: String
        if isWaiting {
            headline = "Buffering"
        } else if control.hasPrefix("playing") {
            headline = "Playing \(String(control.dropFirst("playing ".count)))"
        } else {
            headline = control.capitalized
        }
        return String(
            format: "%@ · src %d FPS · %@s · copied %d · decode fail %d · last frame %@",
            headline,
            sourceFPS,
            playheadLabel,
            copied,
            missed,
            ageText
        )
    }

    /// Operator desk probe — whole-second playhead, no per-frame counters (avoids UI flicker).
    var deskProbeDisplayLine: String {
        let transportHeadline: String
        if isWaiting {
            transportHeadline = "Buffering"
        } else if control.hasPrefix("playing") {
            transportHeadline = "Playing"
        } else {
            transportHeadline = control.capitalized
        }
        let playheadSeconds = Int((Double(playheadLabel) ?? 0).rounded())
        var chunks = [
            transportHeadline,
            "src \(sourceFPS) FPS",
            "\(playheadSeconds)s",
        ]
        if control.lowercased().contains("paused") {
            return chunks.joined(separator: " · ")
        }
        if let lastFrameAge, lastFrameAge > 0.25 {
            chunks.append("frame \(Int(lastFrameAge.rounded()))s ago")
        }
        if missed >= 5, copied >= 20 {
            let missRate = Double(missed) / Double(max(1, copied))
            if missRate > 0.12 {
                chunks.append(String(format: "decode fail %.0f%%", missRate * 100))
            }
        }
        return chunks.joined(separator: " · ")
    }
}

/// Single program-media clock. File-backed items use one shared AVPlayer;
/// items without a file keep a logical playhead so the dock still works.
@MainActor
@Observable
final class MediaPlaybackEngine {
    var title: String = MediaTransportState.idle.title
    var duration: TimeInterval = 0
    @ObservationIgnored var playhead: TimeInterval = 0
    @ObservationIgnored var displayPlayhead: TimeInterval = 0
    var isPlaying: Bool = false
    #if canImport(AVFoundation)
    var avPlaybackRate: Float { player.rate }
    #endif
    /// One line for the desk: player clock vs last copied frame. See Console category `playback`.
    var playbackProbe: String = ""
    var playbackStats: MediaPlaybackProbeStats?
    @ObservationIgnored private var lastPlaybackProbePublishAt: CFTimeInterval = 0
    var isLooping: Bool = true
    var markers: [TimeInterval] = []
    var mediaID: UUID?
    var fileURL: URL?
    var isImage: Bool = false
    private(set) var hasVideoTrack: Bool = false
    var isMuted: Bool = false
    var mixGain: Double = 1
    var projectRoot: URL?
    private(set) var boundFilePath: String?
    private(set) var boundPlaceholder: String?
    private(set) var boundPlaceholders: Set<String> = []

    #if canImport(AVFoundation)
    let player: AVPlayer = {
        let player = AVPlayer()
        player.defaultRate = 1
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        return player
    }()
    #endif

    private var logicalAnchor: Date?
    private var logicalPlayhead: TimeInterval = 0
    #if canImport(AVFoundation)
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    #endif

    var usesFilePlayer: Bool { fileURL != nil && !isImage }

    var remaining: TimeInterval { max(0, duration - playhead) }

    private(set) var loadGeneration: Int = 0
    #if canImport(AVFoundation)
    @ObservationIgnored private var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var cachedPixelBuffer: CVPixelBuffer?
    @ObservationIgnored private var videoOutputBridge: ProgramVideoOutputBridge?
    @ObservationIgnored private var framePublisher: OffThreadVideoPublisher?
    #endif

    var hasProgramClock: Bool { mediaID != nil || fileURL != nil || boundFilePath != nil }

    var canPresentVideo: Bool {
        usesFilePlayer || hasVideoTrack || AssignedMediaSource.pathLooksLikeVideo(boundFilePath) || AssignedMediaSource.pathLooksLikeVideo(fileURL?.path)
    }

    var currentTimecode: CMTime {
        #if canImport(AVFoundation)
        if usesFilePlayer {
            let time = player.currentTime()
            if time.isValid && !time.isIndefinite { return time }
        }
        #endif
        return CMTime(seconds: max(0, playhead), preferredTimescale: 600)
    }

    func isPlayingFile(at path: String?) -> Bool {
        sharesClock(withPath: path)
    }

    func isBound(to media: MediaAction?) -> Bool {
        sharesClock(with: media)
    }

    func sharesClock(with media: MediaAction?) -> Bool {
        switch media {
        case nil:
            return !hasProgramClock
        case let media?:
            if media.clearsLayer { return false }
            if let mediaID, media.id == mediaID { return true }
            if let current = boundMediaAction(),
               MediaActionEvaluator.isSameAsset(current, media, projectRoot: projectRoot) {
                return true
            }
            if sharesClock(withPath: media.filePath) { return true }
            if sharesClock(withPlaceholder: media.placeholderLetter) { return true }
            return false
        }
    }

    func sharesClock(with source: AssignedMediaSource) -> Bool {
        if let id = source.mediaItemID, id == mediaID { return true }
        if sharesClock(withPath: source.connectionString) { return true }
        if sharesClock(withPlaceholder: source.placeholderLetter) { return true }
        if let name = Optional(source.name), sharesClock(withTitle: name),
           source.sourceType == .mediaFile || source.sourceType == .libraryShow {
            return boundFilePath == nil || sharesClock(withPath: source.connectionString) || source.connectionString == nil
        }
        return false
    }

    func sharesClock(with object: CanvasObject) -> Bool {
        if object.id == mediaID { return true }
        if let assigned = object.assignedSource, sharesClock(with: assigned) { return true }
        if sharesClock(withPath: object.fill.imageURI) { return true }
        if sharesClock(withPlaceholder: object.assignedPlaceholderLetter) { return true }
        return false
    }

    func sharesClock(withPath path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        if path.hasPrefix("placeholder://"),
           sharesClock(withPlaceholder: path.split(separator: "/").last.map(String.init)) {
            return true
        }
        if let mediaID, UUID(uuidString: path) == mediaID { return true }
        if let boundFilePath, pathsMatch(boundFilePath, path) { return true }
        let incoming = resolveForMatch(path)
        if let incoming, let program = fileURL, pathsMatch(incoming, program) { return true }
        if let incoming, let boundFilePath, pathsMatch(incoming.path, boundFilePath) { return true }
        return false
    }

    func sharesClock(withPlaceholder letter: String?) -> Bool {
        guard let letter, !letter.isEmpty else { return false }
        if boundPlaceholders.contains(where: { $0.caseInsensitiveCompare(letter) == .orderedSame }) {
            return true
        }
        guard let boundPlaceholder, !boundPlaceholder.isEmpty else { return false }
        return boundPlaceholder.caseInsensitiveCompare(letter) == .orderedSame
    }

    func adoptPlaceholders(_ letters: [String]) {
        let cleaned = letters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        for letter in cleaned {
            boundPlaceholders.insert(letter.uppercased())
        }
        if boundPlaceholder == nil {
            boundPlaceholder = cleaned.first
        }
    }

    func sharesClock(withTitle name: String?) -> Bool {
        guard let name, !name.isEmpty, !title.isEmpty else { return false }
        return title.caseInsensitiveCompare(name) == .orderedSame
    }

    private func boundMediaAction() -> MediaAction? {
        guard hasProgramClock else { return nil }
        return MediaAction(
            id: mediaID ?? UUID(),
            title: title,
            tintHex: "#000000",
            isImage: isImage,
            filePath: boundFilePath ?? fileURL?.path,
            placeholderLetter: boundPlaceholder
        )
    }

    private func resolveForMatch(_ path: String) -> URL? {
        if let resolved = MediaPath.resolve(path, projectRoot: projectRoot) {
            return resolved
        }
        if path.hasPrefix("file:"), let url = URL(string: path) {
            return url
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if let root = projectRoot ?? MediaPath.currentProjectRoot {
            return root.appendingPathComponent(path)
        }
        return nil
    }

    private func pathsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        pathsMatch(lhs.standardizedFileURL.path, rhs.standardizedFileURL.path)
    }

    private func pathsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if left.caseInsensitiveCompare(right) == .orderedSame { return true }
        if left.lowercased().hasSuffix(right.lowercased()) || right.lowercased().hasSuffix(left.lowercased()) {
            return true
        }
        let leftName = URL(fileURLWithPath: lhs).lastPathComponent
        let rightName = URL(fileURLWithPath: rhs).lastPathComponent
        if leftName.compare(rightName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
           AssignedMediaSource.pathLooksLikeVideo(lhs) || AssignedMediaSource.pathLooksLikeVideo(rhs) {
            return true
        }
        return false
    }

    /// 0…1 peak of the program player tap. Silent when that tap has not delivered samples recently.
    var outputLevel: Double {
        let db = ProgramSlideAudioMeter.peakDb()
        guard db > -90 else { return 0 }
        return min(1, AudioDSP.linear(fromDb: db))
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyOutputGain()
    }

    func applyMixGain(_ linear: Double) {
        mixGain = max(0, min(1, linear))
        applyOutputGain()
    }

    func refreshPlaybackProbe() {
        #if canImport(AVFoundation)
        let seconds = CMTimeGetSeconds(player.currentTime())
        let shown = seconds.isFinite ? String(format: "%.1f", seconds) : "—"
        let control: String
        switch player.timeControlStatus {
        case .playing: control = String(format: "playing %.2fx", player.rate)
        case .waitingToPlayAtSpecifiedRate: control = "waiting"
        case .paused: control = "paused"
        @unknown default: control = "unknown"
        }
        let stats = framePublisher?.pullStats.snapshot()
        let copied = stats?.copied ?? 0
        let missed = stats?.missed ?? 0
        let srcFPS = framePublisher?.sourceNominalFPS ?? 30
        let lastAge: Double?
        if let last = stats?.lastCopiedAt, last > 0 {
            lastAge = CACurrentMediaTime() - last
        } else {
            lastAge = nil
        }
        let statsSnapshot = MediaPlaybackProbeStats(
            control: control,
            rate: player.rate,
            playheadLabel: shown,
            sourceFPS: srcFPS,
            copied: copied,
            missed: missed,
            lastFrameAge: lastAge,
            isWaiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        )
        let now = CACurrentMediaTime()
        let publishProbeUI: Bool = {
            guard let previous = playbackStats else { return true }
            if previous != statsSnapshot {
                let agesMatch: Bool = {
                    switch (previous.lastFrameAge, statsSnapshot.lastFrameAge) {
                    case (nil, nil): return true
                    case let (left?, right?): return abs(left - right) < 0.05
                    default: return false
                    }
                }()
                let onlyMissDelta = previous.copied == statsSnapshot.copied
                    && previous.missed != statsSnapshot.missed
                    && previous.playheadLabel == statsSnapshot.playheadLabel
                    && abs(previous.rate - statsSnapshot.rate) < 0.02
                    && previous.isWaiting == statsSnapshot.isWaiting
                    && agesMatch
                if onlyMissDelta, now - lastPlaybackProbePublishAt < 1.0 {
                    return false
                }
                return true
            }
            return false
        }()
        if publishProbeUI {
            lastPlaybackProbePublishAt = now
            playbackStats = statsSnapshot
            let line = statsSnapshot.summaryLine
            if line != playbackProbe {
                playbackProbe = line
            }
        }
        #else
        playbackStats = nil
        #endif
    }

    private func applyOutputGain() {
        #if canImport(AVFoundation)
        player.isMuted = isMuted
        let local = Double(AudioMonitoringEngine.shared.localSpeakerScalar)
        player.volume = isMuted ? 0 : Float(mixGain * local)
        if isPlaying, !isMuted, mixGain > 0.0001, player.timeControlStatus == .paused {
            player.play()
        }
        syncStreamAudioPuller()
        #endif
    }

    /// RTMP/recording starvation fallback must track AVPlayer time, not the program tick rate.
    private func syncStreamAudioPuller() {
        #if canImport(AVFoundation)
        guard usesFilePlayer else { return }
        let programMixMonitor = ProgramAudioMonitorBridge.shared.isRunning
            && AudioMonitoringEngine.shared.monitorMode == .programMix
        let feedsSlidePCM = isPlaying && !isMuted && (mixGain > 0.0001 || programMixMonitor)
        ProgramAudioPuller.publish(
            url: fileURL,
            playhead: playhead,
            isPlaying: feedsSlidePCM
        )
        #endif
    }

    func snapshot() -> MediaTransportState {
        MediaTransportState(
            title: title,
            duration: duration,
            playhead: playhead,
            isPlaying: isPlaying,
            isLooping: isLooping,
            markers: markers
        )
    }

    func load(_ media: MediaAction?, restart: Bool = true) {
        if !restart, sharesClock(with: media) {
            adoptMetadata(media)
            attachFrameOutputIfNeeded()
            return
        }
        loadGeneration &+= 1
        ProgramAACEncoder.flush(role: .slide)
        ProgramAudioPuller.noteSlideSourceChanged()
        detachPlayerObservers()
        detachFrameOutput()
        guard let media else {
            stop()
            title = MediaTransportState.idle.title
            duration = 0
            markers = []
            mediaID = nil
            fileURL = nil
            boundFilePath = nil
            boundPlaceholder = nil
            boundPlaceholders = []
            isImage = false
            hasVideoTrack = false
            return
        }
        let parsed = MediaDurationParser.seconds(from: media.duration)
        title = media.title
        duration = parsed > 0 ? parsed : (media.isImage ? 0 : 60)
        playhead = 0
        displayPlayhead = 0
        logicalPlayhead = 0
        mediaID = media.id
        fileURL = media.resolvedFileURL(projectRoot: projectRoot)
        boundFilePath = media.filePath ?? fileURL?.path
        boundPlaceholder = media.placeholderLetter
        boundPlaceholders = []
        if let letter = media.placeholderLetter, !letter.isEmpty {
            boundPlaceholders.insert(letter.uppercased())
        }
        isImage = media.isImage
        hasVideoTrack = fileURL.map { MediaLoader.hasVideoTrack(at: $0) }
            ?? AssignedMediaSource.pathLooksLikeVideo(boundFilePath)
        markers = duration > 0 ? [0, duration / 2] : [0]
        isPlaying = !media.isImage
        logicalAnchor = isPlaying ? Date() : nil
        #if canImport(AVFoundation)
        if usesFilePlayer, let url = fileURL {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            attachFrameOutput(to: item)
            attachPlayerObservers()
            applyOutputGain()
            adoptPlayerDurationIfAvailable()
            if isPlaying {
                player.play()
            } else {
                player.pause()
            }
            syncStreamAudioPuller()
        } else {
            player.replaceCurrentItem(with: nil)
        }
        #endif
    }

    private func adoptMetadata(_ media: MediaAction?) {
        guard let media else { return }
        if title != media.title { title = media.title }
        if mediaID != media.id { mediaID = media.id }
        let parsed = MediaDurationParser.seconds(from: media.duration)
        if parsed > 0, duration != parsed { duration = parsed }
        if isImage != media.isImage { isImage = media.isImage }
        if let path = media.filePath, !path.isEmpty, boundFilePath != path {
            boundFilePath = path
        }
        if fileURL == nil {
            fileURL = media.resolvedFileURL(projectRoot: projectRoot)
        }
        if let letter = media.placeholderLetter, !letter.isEmpty {
            if boundPlaceholder != letter {
                boundPlaceholder = letter
            }
            boundPlaceholders.insert(letter.uppercased())
        }
    }

    func play() {
        guard duration > 0 || isImage == false else { return }
        isPlaying = true
        logicalPlayhead = playhead
        logicalAnchor = Date()
        #if canImport(AVFoundation)
        if usesFilePlayer {
            player.play()
            startFramePull()
            syncStreamAudioPuller()
        }
        #endif
    }

    func pause() {
        isPlaying = false
        logicalAnchor = nil
        logicalPlayhead = playhead
        #if canImport(AVFoundation)
        if usesFilePlayer {
            player.pause()
            stopFramePull(requestNext: false)
            ProgramAACEncoder.flush(role: .slide)
            ProgramFileAudioReader.invalidateCache()
            syncStreamAudioPuller()
        }
        #endif
    }

    func toggle() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        pause()
        playhead = 0
        logicalPlayhead = 0
        #if canImport(AVFoundation)
        if usesFilePlayer {
            player.seek(to: .zero)
        }
        #endif
    }

    /// Drops the current item and its sample-buffer outputs. Called when a project closes.
    func releaseForProjectClose() {
        stop()
        #if canImport(AVFoundation)
        detachPlayerObservers()
        detachFrameOutput()
        player.replaceCurrentItem(with: nil)
        #endif
        fileURL = nil
        mediaID = nil
    }

    func seek(to seconds: TimeInterval) {
        let next = duration <= 0 ? 0 : min(max(0, seconds), duration)
        playhead = next
        displayPlayhead = next
        logicalPlayhead = next
        logicalAnchor = isPlaying ? Date() : nil
        if duration > 0, next >= duration, !isLooping {
            isPlaying = false
            logicalAnchor = nil
        }
        #if canImport(AVFoundation)
        if usesFilePlayer {
            framePublisher?.resetPresentationClock()
            let time = CMTime(seconds: next, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if isPlaying { player.play() } else { player.pause() }
            syncStreamAudioPuller()
        }
        #endif
    }

    func skip(seconds: TimeInterval) {
        seek(to: playhead + seconds)
    }

    func toggleLoop() {
        isLooping.toggle()
    }

    func jumpToNextMarker() {
        let upcoming = markers.filter { $0 > playhead + 0.05 }.sorted()
        if let next = upcoming.first {
            seek(to: next)
        } else if let first = markers.sorted().first {
            seek(to: first)
        }
    }

    func tick(now: Date = Date()) {
        #if canImport(AVFoundation)
        if usesFilePlayer {
            adoptPlayerDurationIfAvailable()
            refreshPlaybackProbe()
            let seconds = CMTimeGetSeconds(player.currentTime())
            if seconds.isFinite, seconds >= 0 {
                playhead = duration > 0 ? min(seconds, duration) : seconds
                publishDisplayPlayheadIfNeeded()
                syncStreamAudioPuller()
            }
            return
        }
        #endif
        guard isPlaying else { return }
        let anchor = logicalAnchor ?? now
        var next = logicalPlayhead + now.timeIntervalSince(anchor)
        if duration > 0, next >= duration {
            if isLooping {
                next = next.truncatingRemainder(dividingBy: duration)
                logicalPlayhead = next
                logicalAnchor = now
            } else {
                next = duration
                isPlaying = false
                logicalAnchor = nil
            }
        }
        playhead = next
        publishDisplayPlayheadIfNeeded()
    }

    private func publishDisplayPlayheadIfNeeded() {
        if abs(displayPlayhead - playhead) >= 0.2 || !isPlaying {
            displayPlayhead = playhead
        }
    }

    #if canImport(AVFoundation)
    private func adoptPlayerDurationIfAvailable() {
        guard let item = player.currentItem else { return }
        let seconds = CMTimeGetSeconds(item.duration)
        if seconds.isFinite, seconds > 0 {
            duration = seconds
            return
        }
        if let range = item.seekableTimeRanges.last?.timeRangeValue {
            let length = CMTimeGetSeconds(range.duration)
            if length.isFinite, length > 0 {
                duration = length
            }
        }
    }

    private func attachPlayerObservers() {
        detachPlayerObservers()
        itemStatusObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                self?.applyOutputGain()
                ProgramPlayerAudioTap.attach(to: item)
                if self?.isPlaying == true {
                    self?.player.play()
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                self.playhead = self.duration > 0 ? min(seconds, self.duration) : seconds
                self.publishDisplayPlayheadIfNeeded()
                self.syncStreamAudioPuller()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func handlePlaybackEnded() {
        if isLooping {
            seek(to: 0)
            play()
        } else {
            playhead = duration
            pause()
        }
    }

    private func detachPlayerObservers() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
    }

    private func attachFrameOutputIfNeeded() {
        guard videoOutput == nil, let item = player.currentItem else { return }
        attachFrameOutput(to: item)
    }

    private var previewPixelMaxWidth: Int = 0
    private var previewPixelMaxHeight: Int = 0

    func configureLocalPreviewPixelBudget(fullWidth: Int, fullHeight: Int, renderPercent: Double) {
        let contract = ProgramRenderContract(
            width: max(16, fullWidth),
            height: max(16, fullHeight),
            frameRate: 30,
            colorSpace: "sRGB"
        ).scaledForLocalPreview(percent: renderPercent)
        let changed = previewPixelMaxWidth != contract.width || previewPixelMaxHeight != contract.height
        previewPixelMaxWidth = contract.width
        previewPixelMaxHeight = contract.height
        guard changed, let item = player.currentItem else { return }
        attachFrameOutput(to: item)
    }

    private func videoOutputPixelBufferAttributes() -> [String: Any] {
        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        if previewPixelMaxWidth > 0, previewPixelMaxHeight > 0 {
            attributes[kCVPixelBufferWidthKey as String] = previewPixelMaxWidth
            attributes[kCVPixelBufferHeightKey as String] = previewPixelMaxHeight
        }
        return attributes
    }

    private func attachFrameOutput(to item: AVPlayerItem) {
        detachFrameOutput()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: videoOutputPixelBufferAttributes())
        let publisher = OffThreadVideoPublisher(videoOutput: output)
        let nominal = item.asset.tracks(withMediaType: .video).first?.nominalFrameRate ?? 30
        publisher.configureSourceNominalFrameRate(nominal)
        let bridge = ProgramVideoOutputBridge { [weak publisher] hostTime in
            publisher?.processDisplayLinkTick(hostTime: hostTime)
        }
        output.setDelegate(bridge, queue: ProShowQueues.videoDisplayLinkQueue)
        item.add(output)
        ProgramPlayerAudioTap.attach(to: item)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0)
        framePublisher = publisher
        videoOutputBridge = bridge
        videoOutput = output
        if isPlaying {
            startFramePull()
        }
    }

    private func detachFrameOutput() {
        stopFramePull(requestNext: false)
        if let videoOutput, let item = player.currentItem {
            videoOutput.setDelegate(nil, queue: nil)
            item.remove(videoOutput)
        }
        videoOutput = nil
        videoOutputBridge = nil
        framePublisher?.resetPresentationClock()
        framePublisher = nil
        cachedPixelBuffer = nil
    }

    private func startFramePull() {
        videoOutputBridge?.startPulling()
        videoOutput?.requestNotificationOfMediaDataChange(withAdvanceInterval: 0)
    }

    private func stopFramePull(requestNext: Bool) {
        videoOutputBridge?.stopPulling()
        if requestNext {
            videoOutput?.requestNotificationOfMediaDataChange(withAdvanceInterval: 0)
        }
    }

    func publishedPixelBuffer() -> CVPixelBuffer? {
        SharedTexturePublisher.shared.currentPixelBuffer() ?? cachedPixelBuffer
    }

    func addFrameConsumer(_ id: ObjectIdentifier, handler: @escaping () -> Void) {
        SharedTexturePublisher.shared.addConsumer(id, handler: handler)
    }

    func removeFrameConsumer(_ id: ObjectIdentifier) {
        SharedTexturePublisher.shared.removeConsumer(id)
    }

    func copyLatestPixelBuffer() -> CVPixelBuffer? {
        if let published = SharedTexturePublisher.shared.currentPixelBuffer() {
            cachedPixelBuffer = published
            return published
        }
        return cachedPixelBuffer
    }
    #else
    private func detachPlayerObservers() {}
    private func detachFrameOutput() {}
    private func attachFrameOutputIfNeeded() {}
    #endif
}

#if canImport(AVFoundation)
#if os(macOS)
import AppKit
#endif

final class ProgramVideoOutputBridge: NSObject, AVPlayerItemOutputPullDelegate, @unchecked Sendable {
    var onFrame: ((CFTimeInterval) -> Void)?
    private var pullingEnabled = false
    #if os(macOS)
    private var cvLink: CVDisplayLink?
    private var fallbackTimer: DispatchSourceTimer?
    private let pullLock = NSLock()
    private var pullQueued = false
    #endif
    #if os(iOS) || os(tvOS)
    private var link: CADisplayLink?
    #endif

    init(onFrame: @escaping (CFTimeInterval) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        guard pullingEnabled else { return }
        ensureDisplayLinkRunning()
        enqueueFrame()
    }

    func startPulling() {
        pullingEnabled = true
        ensureDisplayLinkRunning()
    }

    private func ensureDisplayLinkRunning() {
        guard pullingEnabled else { return }
        #if os(macOS)
        if cvLink != nil || fallbackTimer != nil { return }
        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link {
            cvLink = link
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, inNow, _, _, _ in
                guard let self else { return kCVReturnSuccess }
                let hostTime = CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(inNow.pointee.hostTime))
                self.pullLock.lock()
                let alreadyQueued = self.pullQueued
                self.pullQueued = true
                self.pullLock.unlock()
                guard !alreadyQueued else { return kCVReturnSuccess }
                ProShowQueues.videoDisplayLinkQueue.async { [weak self] in
                    guard let self else { return }
                    self.pullLock.lock()
                    self.pullQueued = false
                    self.pullLock.unlock()
                    self.onFrame?(hostTime.isFinite ? hostTime : 0)
                }
                return kCVReturnSuccess
            }
            CVDisplayLinkStart(link)
            return
        }
        startFallbackTimer()
        #else
        if link != nil { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(step))
        displayLink.add(to: .main, forMode: .common)
        self.link = displayLink
        #endif
    }

    func stopPulling() {
        pullingEnabled = false
        #if os(macOS)
        if let cvLink {
            CVDisplayLinkStop(cvLink)
        }
        cvLink = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
        pullLock.lock()
        pullQueued = false
        pullLock.unlock()
        #endif
        #if os(iOS) || os(tvOS)
        link?.invalidate()
        link = nil
        #endif
    }

    #if os(iOS) || os(tvOS)
    @objc private func step() {
        enqueueFrame()
    }
    #endif

    #if os(macOS)
    private func startFallbackTimer() {
        let timer = DispatchSource.makeTimerSource(queue: ProShowQueues.videoDisplayLinkQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            self?.onFrame?(CACurrentMediaTime())
        }
        timer.resume()
        fallbackTimer = timer
    }
    #endif

    private func enqueueFrame(displayTime: CVTimeStamp? = nil) {
        _ = displayTime
        ProShowQueues.videoDisplayLinkQueue.async { [weak self] in
            self?.onFrame?(CACurrentMediaTime())
        }
    }
}

enum ProgramPlayerAudioTap {
    private static let format = TapFormatBox()

    @MainActor
    static func attach(to item: AVPlayerItem) {
        #if canImport(MediaToolbox)
        if item.audioMix?.inputParameters.contains(where: { $0.audioTapProcessor != nil }) == true {
            return
        }
        let track = item.tracks.compactMap(\.assetTrack).first(where: { $0.mediaType == .audio })
            ?? item.asset.tracks(withMediaType: .audio).first
        guard let track else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: nil,
            init: { _, _, _ in },
            finalize: { _ in },
            prepare: { _, _, format in
                ProgramPlayerAudioTap.format.set(format)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var localFlags = MTAudioProcessingTapFlags()
                var frames = numberFrames
                MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, &localFlags, nil, &frames)
                numberFramesOut.pointee = frames
                flagsOut.pointee = localFlags
                let asbd = ProgramPlayerAudioTap.format.get()
                guard asbd.mSampleRate >= 8_000 else { return }
                let mono = PCMBridgeSamples.mono(
                    list: UnsafeMutableAudioBufferListPointer(bufferListInOut),
                    frames: Int(frames),
                    asbd: asbd
                )
                guard !mono.isEmpty else { return }
                ProgramPlayerAudioTap.deliver(mono, rate: asbd.mSampleRate)
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        ) == noErr, let tap else { return }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        #endif
    }

    #if canImport(MediaToolbox)
    private static let deliverQueue = DispatchQueue(label: "proshow.slide.audio", qos: .userInitiated)

    private static func deliver(_ mono: [Float], rate: Double) {
        deliverQueue.async {
            ProgramSlideAudioMeter.note(mono: mono, sampleRate: rate)
            ProgramStreamAudioGates.enqueueCapture(role: .slide, mono: mono, sampleRate: rate)
            ProgramAudioPuller.markLivePCM()
        }
    }
    #endif
}

/// Latest program-player PCM peak. Written from the audio tap, read on the program tick.
enum ProgramSlideAudioMeter {
    private static let lock = NSLock()
    private static var peakLinear: Float = 0
    private static var hostTime: CFAbsoluteTime = 0
    private static var window: [Float] = []
    private static var windowRate: Double = 48_000

    static func note(mono: [Float], sampleRate: Double) {
        var peak: Float = 0
        for sample in mono {
            peak = max(peak, abs(sample))
        }
        // A muted program player can push silence through the tap and hide the clip that is actually audible.
        guard peak > 0.000_1 else { return }
        let copy = mono.count > 1024 ? Array(mono.suffix(1024)) : mono
        lock.lock()
        peakLinear = peak
        hostTime = CFAbsoluteTimeGetCurrent()
        window = copy
        windowRate = sampleRate
        lock.unlock()
    }

    static func peakDb() -> Double {
        lock.lock()
        let peak = peakLinear
        let when = hostTime
        lock.unlock()
        if CFAbsoluteTimeGetCurrent() - when > 0.35 { return -120 }
        if peak <= 0.000_01 { return -120 }
        return 20 * log10(Double(peak))
    }

    static func spectrumWindow() -> (samples: [Float], sampleRate: Double)? {
        lock.lock()
        let samples = window
        let rate = windowRate
        let when = hostTime
        lock.unlock()
        guard !samples.isEmpty, CFAbsoluteTimeGetCurrent() - when < 0.35 else { return nil }
        return (samples, rate)
    }
}

/// Playhead of a video the operator can hear. Slot players and the program player both publish here.
enum AudibleVideoClock {
    private final class Token {}
    static let programID = ObjectIdentifier(Token())

    private struct Snap {
        var url: URL
        var playhead: TimeInterval
        var at: CFAbsoluteTime
    }

    private static let lock = NSLock()
    private static var clips: [ObjectIdentifier: Snap] = [:]

    static func note(id: ObjectIdentifier, url: URL?, playhead: TimeInterval, audible: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard audible, let url else {
            clips[id] = nil
            return
        }
        clips[id] = Snap(url: url, playhead: playhead, at: CFAbsoluteTimeGetCurrent())
    }

    static func latest() -> (url: URL, playhead: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        guard let best = clips.values.filter({ now - $0.at < 0.6 }).max(by: { $0.at < $1.at }) else { return nil }
        return (best.url, best.playhead)
    }
}

/// Samples the playing video file when the program-player tap is not delivering PCM.
enum ProgramSlideFileMeter {
    private static let queue = DispatchQueue(label: "proshow.slide-file-meter")
    private static let lock = NSLock()
    private static var inFlight = false
    private static var lastRequest: CFAbsoluteTime = 0
    #if canImport(AVFoundation)
    private static var file: AVAudioFile?
    private static var openURL: URL?
    #endif

    static func request(url: URL, playhead: TimeInterval) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if inFlight || now - lastRequest < 0.08 {
            lock.unlock()
            return
        }
        inFlight = true
        lastRequest = now
        lock.unlock()
        let seconds = playhead
        queue.async {
            defer {
                lock.lock()
                inFlight = false
                lock.unlock()
            }
            guard let mono = readMono(url: url, playhead: seconds) else { return }
            ProgramSlideAudioMeter.note(mono: mono.samples, sampleRate: mono.rate)
        }
    }

    private static func readMono(url: URL, playhead: TimeInterval) -> (samples: [Float], rate: Double)? {
        #if canImport(AVFoundation)
        if openURL != url {
            file = try? AVAudioFile(forReading: url)
            openURL = url
        }
        guard let file else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 1, file.length > 0 else { return nil }
        let frame = AVAudioFramePosition(max(0, playhead) * rate)
        guard frame < file.length else { return nil }
        let count = AVAudioFrameCount(min(2048, file.length - frame))
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return nil }
        file.framePosition = frame
        do {
            try file.read(into: buffer, frameCount: count)
        } catch {
            return nil
        }
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        let used = max(1, min(channelCount, 2))
        for channel in 0..<used {
            let samples = channels[channel]
            for index in 0..<frames {
                mono[index] += samples[index]
            }
        }
        if used > 1 {
            let scale = 1 / Float(used)
            for index in 0..<frames { mono[index] *= scale }
        }
        return (mono, rate)
        #else
        return nil
        #endif
    }
}

/// Snapshot used when the player tap is silent so RTMP still gets program audio.
enum ProgramAudioPuller {
    private static let lock = NSLock()
    private static var url: URL?
    private static var playhead: TimeInterval = 0
    private static var isPlaying = false
    private static var lastPCM: CFTimeInterval = 0

    static func publish(url: URL?, playhead: TimeInterval, isPlaying: Bool) {
        lock.lock()
        self.url = url
        self.playhead = playhead
        self.isPlaying = isPlaying
        lock.unlock()
    }

    static func markLivePCM() {
        lock.lock()
        lastPCM = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Clears starvation fallback after slide / file swaps so file PCM does not overlap live tap.
    static func noteSlideSourceChanged() {
        lock.lock()
        lastPCM = CFAbsoluteTimeGetCurrent()
        lock.unlock()
        ProgramFileAudioReader.invalidateCache()
    }

    static func pullIfStarving() -> [Float] {
        lock.lock()
        let url = self.url
        let playhead = self.playhead
        let playing = isPlaying
        let stale = CFAbsoluteTimeGetCurrent() - lastPCM > 0.42
        lock.unlock()
        guard playing, stale, let url else { return [] }
        return ProgramFileAudioReader.stereo48k(url: url, playhead: playhead, duration: 0.022)
    }
}

enum ProgramFileAudioReader {
    #if canImport(AVFoundation)
    private static let lock = NSLock()
    private static var cachedURL: URL?
    private static var reader: AVAssetReader?
    private static var output: AVAssetReaderTrackOutput?
    private static var expectedPlayhead: TimeInterval = 0
    #endif

    static func stereo48k(url: URL, playhead: TimeInterval, duration: TimeInterval) -> [Float] {
        #if canImport(AVFoundation)
        let chunkDuration = max(0.02, duration)
        lock.lock()
        let needsRebuild: Bool = {
            if cachedURL != url { return true }
            guard reader != nil, output != nil else { return true }
            if abs(playhead - expectedPlayhead) > 0.35 { return true }
            if reader?.status == .failed || reader?.status == .completed { return true }
            return false
        }()
        if needsRebuild {
            reader?.cancelReading()
            reader = nil
            output = nil
            cachedURL = url
            expectedPlayhead = max(0, playhead)
            let asset = AVURLAsset(url: url)
            guard let track = asset.tracks(withMediaType: .audio).first,
                  let newReader = try? AVAssetReader(asset: asset)
            else {
                lock.unlock()
                return []
            }
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ]
            let newOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            newOutput.alwaysCopiesSampleData = false
            guard newReader.canAdd(newOutput) else {
                lock.unlock()
                return []
            }
            newReader.add(newOutput)
            newReader.timeRange = CMTimeRange(
                start: CMTime(seconds: expectedPlayhead, preferredTimescale: 600),
                duration: CMTime(seconds: 120, preferredTimescale: 600)
            )
            guard newReader.startReading() else {
                lock.unlock()
                return []
            }
            reader = newReader
            output = newOutput
        }
        guard let output else {
            lock.unlock()
            return []
        }
        var stereo: [Float] = []
        stereo.reserveCapacity(ProgramStreamAudioClock.interleavedSamplesPerAccessUnit * 2)
        let targetSamples = Int(chunkDuration * 48_000) * 2
        while stereo.count < targetSamples, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes)
            bytes.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                stereo.append(contentsOf: floats)
            }
            CMSampleBufferInvalidate(sample)
        }
        if !stereo.isEmpty {
            expectedPlayhead += Double(stereo.count / 2) / 48_000
        }
        lock.unlock()
        return stereo
        #else
        return []
        #endif
    }

    static func invalidateCache() {
        #if canImport(AVFoundation)
        lock.lock()
        reader?.cancelReading()
        reader = nil
        output = nil
        cachedURL = nil
        expectedPlayhead = 0
        lock.unlock()
        #endif
    }
}

#if canImport(CoreAudio) || canImport(AVFoundation)
enum PCMBridgeSamples {
    static func mono(
        list: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        asbd: AudioStreamBasicDescription
    ) -> [Float] {
        guard frames > 0, !list.isEmpty else { return [] }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = max(1, Int(asbd.mChannelsPerFrame == 0 ? 1 : asbd.mChannelsPerFrame))
        var mono = [Float](repeating: 0, count: frames)
        if isFloat {
            if planar {
                var mixCount = 0
                for buffer in list {
                    guard let data = buffer.mData else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for index in 0..<frames {
                        mono[index] += samples[index]
                    }
                    mixCount += 1
                }
                if mixCount > 1 {
                    let inv = 1 / Float(mixCount)
                    for index in 0..<frames { mono[index] *= inv }
                }
            } else if let data = list.first?.mData {
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += samples[index * channels + channel]
                    }
                    mono[index] = sum / Float(channels)
                }
            }
            return mono
        }
        let bits = Int(asbd.mBitsPerChannel == 0 ? 16 : asbd.mBitsPerChannel)
        if bits == 16, let data = list.first?.mData {
            let samples = data.assumingMemoryBound(to: Int16.self)
            let stride = planar ? 1 : channels
            for index in 0..<frames {
                var sum: Float = 0
                for channel in 0..<(planar ? 1 : channels) {
                    sum += Float(samples[index * stride + channel]) / 32768
                }
                mono[index] = planar ? sum : sum / Float(channels)
            }
            if planar, list.count > 1 {
                for bufferIndex in 1..<list.count {
                    guard let extra = list[bufferIndex].mData else { continue }
                    let samples = extra.assumingMemoryBound(to: Int16.self)
                    for index in 0..<frames {
                        mono[index] = (mono[index] + Float(samples[index]) / 32768) * 0.5
                    }
                }
            }
            return mono
        }
        return []
    }
}
#endif

private final class TapFormatBox: @unchecked Sendable {
    private let lock = NSLock()
    private var asbd = AudioStreamBasicDescription()

    func set(_ format: UnsafePointer<AudioStreamBasicDescription>?) {
        guard let format else { return }
        lock.lock()
        asbd = format.pointee
        lock.unlock()
    }

    func get() -> AudioStreamBasicDescription {
        lock.lock()
        defer { lock.unlock() }
        return asbd
    }
}
#endif
