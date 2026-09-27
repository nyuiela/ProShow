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

    /// 0…1 level used by program meters on the same clock as the playhead.
    var outputLevel: Double {
        guard isPlaying, duration > 0, !isMuted else { return 0 }
        return min(1, max(0, 0.28 + 0.22 * sin(playhead * .pi / 4)))
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        applyOutputGain()
    }

    func applyMixGain(_ linear: Double) {
        mixGain = max(0, min(1, linear))
        applyOutputGain()
    }

    private func applyOutputGain() {
        #if canImport(AVFoundation)
        player.isMuted = isMuted
        player.volume = isMuted ? 0 : Float(mixGain)
        if isPlaying, !isMuted, mixGain > 0.0001, player.timeControlStatus == .paused {
            player.play()
        }
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
            stopFramePull(requestNext: true)
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
            let time = CMTime(seconds: next, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            if isPlaying { player.play() } else { player.pause() }
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
            let seconds = CMTimeGetSeconds(player.currentTime())
            if seconds.isFinite, seconds >= 0 {
                playhead = duration > 0 ? min(seconds, duration) : seconds
                publishDisplayPlayheadIfNeeded()
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
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                self.playhead = self.duration > 0 ? min(seconds, self.duration) : seconds
                self.publishDisplayPlayheadIfNeeded()
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

    private func attachFrameOutput(to item: AVPlayerItem) {
        detachFrameOutput()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        let publisher = OffThreadVideoPublisher(videoOutput: output)
        let bridge = ProgramVideoOutputBridge { [weak publisher] in
            publisher?.processDisplayLinkTick()
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
        ProShowQueues.onVideoDisplayLink { [weak publisher] in
            publisher?.processDisplayLinkTick()
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
    var onFrame: (() -> Void)?
    #if os(macOS)
    private var cvLink: CVDisplayLink?
    private var fallbackTimer: DispatchSourceTimer?
    #endif
    #if os(iOS) || os(tvOS)
    private var link: CADisplayLink?
    #endif

    init(onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        startPulling()
        enqueueFrame()
    }

    func startPulling() {
        #if os(macOS)
        if cvLink != nil || fallbackTimer != nil { return }
        var link: CVDisplayLink?
        if CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link {
            cvLink = link
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                ProShowQueues.videoDisplayLinkQueue.sync {
                    self?.onFrame?()
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
        #if os(macOS)
        if let cvLink {
            CVDisplayLinkStop(cvLink)
        }
        cvLink = nil
        fallbackTimer?.cancel()
        fallbackTimer = nil
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
            self?.onFrame?()
        }
        timer.resume()
        fallbackTimer = timer
    }
    #endif

    private func enqueueFrame(displayTime: CVTimeStamp? = nil) {
        _ = displayTime
        ProShowQueues.videoDisplayLinkQueue.async { [weak self] in
            self?.onFrame?()
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
                ProgramPlayerAudioTap.enqueue(bufferListInOut, frames: frames)
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
    private static func enqueue(_ list: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        guard frames > 0 else { return }
        let asbd = format.get()
        let mono = PCMBridgeSamples.mono(
            list: UnsafeMutableAudioBufferListPointer(list),
            frames: Int(frames),
            asbd: asbd
        )
        guard !mono.isEmpty else { return }
        let rate = asbd.mSampleRate > 1 ? asbd.mSampleRate : 48_000
        ProgramPCMBridge.enqueueMono(mono, sampleRate: rate)
        ProgramAudioPuller.markLivePCM()
    }
    #endif
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

    static func pullIfStarving() -> [Float] {
        lock.lock()
        let url = self.url
        let playhead = self.playhead
        let playing = isPlaying
        let stale = CFAbsoluteTimeGetCurrent() - lastPCM > 0.28
        lock.unlock()
        guard playing, stale, let url else { return [] }
        return ProgramFileAudioReader.stereo48k(url: url, playhead: playhead, duration: 0.022)
    }
}

enum ProgramFileAudioReader {
    static func stereo48k(url: URL, playhead: TimeInterval, duration: TimeInterval) -> [Float] {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .audio).first
        guard let track else { return [] }
        guard let reader = try? AVAssetReader(asset: asset) else { return [] }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        let start = max(0, playhead)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.02, duration), preferredTimescale: 600)
        )
        guard reader.startReading() else { return [] }
        var stereo: [Float] = []
        stereo.reserveCapacity(2048)
        while let sample = output.copyNextSampleBuffer() {
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
        return stereo
        #else
        return []
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
