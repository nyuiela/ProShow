import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(macOS)
import AppKit
#endif

extension OutputCue {
    static func make(slide: Slide, presentationId: UUID, index: Int) -> OutputCue {
        let canvas = slide.audienceCanvas()
        let mediaOnly = slide.isProgramMediaCue
        return OutputCue(
            id: slide.id,
            presentationId: presentationId,
            slideIndex: index,
            layers: CueLayers(
                slideText: SlideElement.from(slide: slide),
                slideCanvas: canvas.isEmpty ? nil : canvas,
                canvasWidth: CanvasConfig.width,
                canvasHeight: CanvasConfig.height,
                slideBackgroundEnabled: mediaOnly ? false : slide.paintsOpaqueBackground,
                slideBackgroundHex: slide.backgroundHex
            )
        )
    }
}

struct StagePayload: Equatable, Sendable {
    var current: String
    var next: String
    var notes: String
    var outputEnabled: Bool

    static func make(
        liveSummary: String?,
        nextSummary: String?,
        notes: String?,
        programOutputEnabled: Bool
    ) -> StagePayload {
        StagePayload(
            current: liveSummary ?? "—",
            next: nextSummary ?? "—",
            notes: (notes?.isEmpty == false) ? (notes ?? "—") : "—",
            outputEnabled: programOutputEnabled
        )
    }

    @MainActor
    static func make(controller: ShowController) -> StagePayload {
        let layout = controller.stageDisplayLayout
        let rundownCurrent = controller.rundownClock.isShowRunning ? controller.rundownStageSegmentTitle : nil
        let current = rundownCurrent ?? stageSummary(controller.liveSlide, layout: layout, controller: controller)
        let rundownNext = controller.rundownStageNextCue ?? stageSummary(controller.nextSlide, layout: layout, controller: controller)
        var payload = make(
            liveSummary: current,
            nextSummary: rundownNext,
            notes: controller.selectedSlide?.notes,
            programOutputEnabled: controller.programOutputEnabled
        )
        if layout.showAlertBanner, !controller.stageAlertBanner.isEmpty {
            payload.notes = controller.stageAlertBanner
        }
        return payload
    }

    @MainActor
    private static func stageSummary(
        _ slide: Slide?,
        layout: StageDisplayLayout,
        controller: ShowController
    ) -> String? {
        guard let slide else { return nil }
        if layout.showChords {
            let source = slide.lines.isEmpty ? [slide.previewSummary] : slide.lines
            return StageDisplayEngine.stageLines(
                from: source,
                semitones: layout.chordSemitones,
                showChords: true
            ).joined(separator: "\n")
        }
        let prepared = controller.prepareSlideForProgramCue(slide)
        let themed = prepared.audienceCanvas()
            .filter { $0.isTextLike && $0.visibleOnStage }
            .map(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !themed.isEmpty {
            return themed.joined(separator: "\n")
        }
        return prepared.previewSummary
    }
}

enum MediaLoadResult: Equatable, Sendable {
    case image(path: String)
    case video(path: String, duration: String)
    case audio(path: String, duration: String)
    case missing(path: String)
    case unsupported(path: String)
}

enum MediaPath {
    nonisolated(unsafe) static var currentProjectRoot: URL?

    /// Resolves an absolute path, `file://` URL, or a project-relative asset (`Assets/Videos/clip.mp4`).
    static func resolve(_ stored: String?, projectRoot: URL? = currentProjectRoot) -> URL? {
        guard var stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("file:") {
            stored = URL(string: stored)?.path ?? stored
        }
        if stored.hasPrefix("/") {
            let url = URL(fileURLWithPath: stored)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let roots = [projectRoot, currentProjectRoot].compactMap { $0 }
        for root in roots {
            let url = root.appendingPathComponent(stored)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

enum MediaLoader {
    static func inspect(url: URL) -> MediaLoadResult {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return .missing(path: path)
        }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif":
            return .image(path: path)
        case "mp4", "mov", "m4v":
            return .video(path: path, duration: durationString(for: url))
        case "mp3", "wav", "aac", "m4a", "aiff", "caf":
            return .audio(path: path, duration: durationString(for: url))
        default:
            return .unsupported(path: path)
        }
    }

    /// AVPlayerLayer crashes Fig when bound to audio-only or still files.
    static func hasVideoTrack(at url: URL) -> Bool {
        let key = url.standardizedFileURL.path
        videoTrackLock.lock()
        if let cached = videoTrackCache[key] {
            videoTrackLock.unlock()
            return cached
        }
        videoTrackLock.unlock()
        guard FileManager.default.fileExists(atPath: key) else { return false }
        let hasVideo: Bool
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks.contains { $0.mediaType == .video }
        hasVideo = tracks || AssignedMediaSource.pathLooksLikeVideo(key)
        #else
        hasVideo = AssignedMediaSource.pathLooksLikeVideo(key)
        #endif
        videoTrackLock.lock()
        videoTrackCache[key] = hasVideo
        videoTrackLock.unlock()
        return hasVideo
    }

    private static let videoTrackLock = NSLock()
    private static var videoTrackCache: [String: Bool] = [:]

    static func durationString(for url: URL) -> String {
        if let formatted = assetDuration(for: url) {
            return formatted
        }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize, size > 0
        else { return "0:00.00" }
        return "0:01.00"
    }

    static func assetDuration(for url: URL) -> String? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        let whole = Int(seconds)
        let frac = Int((seconds - Double(whole)) * 100)
        return String(format: "%d:%02d.%02d", whole / 60, whole % 60, frac)
        #else
        return nil
        #endif
    }

    static func action(from item: MediaBinItem, inspected: MediaLoadResult) -> MediaAction {
        let duration: String?
        if case let .video(_, value) = inspected { duration = value }
        else if case let .audio(_, value) = inspected { duration = value }
        else if case let .video(value) = item.kind { duration = value }
        else if case let .audio(value) = item.kind { duration = value }
        else { duration = nil }
        let path: String?
        switch inspected {
        case .image(let p), .video(let p, _), .audio(let p, _): path = p
        default: path = item.filePath
        }
        let image: Bool
        if case .image = inspected {
            image = true
        } else {
            image = item.kind == .image
        }
        let letter = PlaceholderLetter.allCases.map(\.rawValue).contains(item.title) ? item.title : nil
        return MediaAction(
            id: item.id,
            title: item.title,
            tintHex: item.tintHex,
            duration: duration,
            isImage: image,
            filePath: path,
            placeholderLetter: item.kind == .placeholder ? letter : nil
        )
    }
}

enum ScreenCatalog {
    static func defaultScreens() -> [OutputScreen] {
        [
            OutputScreen(id: "screen-1", name: "Screen 1", lookName: AudienceLookConfig.fullStack.name, role: .audience),
            OutputScreen(id: "screen-2", name: "Stage", lookName: "Stage", role: .stage),
        ]
    }

    static func availableScreens() -> [OutputScreen] {
        #if os(macOS)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return defaultScreens() }
        var mapped = screens.enumerated().map { index, screen in
            let role: OutputScreenRole = index == 1 ? .stage : .audience
            return OutputScreen(
                id: "screen-\(index + 1)",
                name: screen.localizedName.isEmpty ? "Screen \(index + 1)" : screen.localizedName,
                lookName: role == .stage ? "Stage" : AudienceLookConfig.fullStack.name,
                role: role
            )
        }
        if !mapped.contains(where: { $0.role == .stage }) {
            mapped.append(OutputScreen(id: "screen-stage", name: "Stage", lookName: "Stage", role: .stage))
        }
        return mapped
        #else
        return defaultScreens()
        #endif
    }

    static func look(named name: String) -> AudienceLookConfig {
        switch name {
        case AudienceLookConfig.alphaKey.name: return .alphaKey
        case AudienceLookConfig.slideAndMedia.name: return .slideAndMedia
        default: return .fullStack
        }
    }
}

/// Resolves Stage editor objects against the live program, not a flag list.
enum StageLiveBinder {
    static func document(from look: StageLookConfig, name: String = "Stage") -> EditorDocument {
        var objects: [CanvasObject] = []
        var z = 4
        if look.showCurrent {
            objects.append(token(.currentSlide, zIndex: z))
            z -= 1
        }
        if look.showNext {
            objects.append(token(.nextSlide, zIndex: z))
            z -= 1
        }
        if look.showClock {
            objects.append(token(.systemClock, zIndex: z))
            z -= 1
        }
        if look.showNotes {
            objects.append(token(.stageNotes, zIndex: z))
        }
        return EditorDocument(name: name, kind: .stage, objects: objects)
    }

    static func resolvedText(
        for object: CanvasObject,
        payload: StagePayload,
        clock: String,
        timerText: String?,
        context: DynamicTextContext? = nil
    ) -> String {
        if object.kind == .systemClock, object.token.isEmpty || object.token == "h:mm:ss a" {
            return clock
        }
        let resolved = context ?? DynamicTextContext(
            now: Date(),
            timeZone: .current,
            fields: [:],
            quotes: [:],
            copyright: CopyrightInfo(),
            currentSlide: payload.current,
            nextSlide: payload.next,
            notes: payload.notes,
            timerText: timerText
        )
        return DynamicTextEngine.resolve(object, context: resolved)
    }

    static func clockString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: date)
    }

    private static func token(_ kind: CanvasObjectKind, zIndex: Int) -> CanvasObject {
        let bounds: CanvasBounds
        switch kind {
        case .currentSlide:
            bounds = CanvasBounds(x: 160, y: 160, width: 3520, height: 840)
        case .nextSlide:
            bounds = CanvasBounds(x: 160, y: 1080, width: 3520, height: 560)
        case .systemClock:
            bounds = CanvasBounds(x: 3120, y: 80, width: 640, height: 160)
        default:
            bounds = CanvasBounds(x: 160, y: 1720, width: 1600, height: 320)
        }
        var object = CanvasObject(
            name: kind.defaultName,
            kind: kind,
            bounds: bounds,
            zIndex: zIndex,
            text: kind.title
        )
        object.fill.type = .none
        object.stroke.style = .none
        object.fontSize = kind == .systemClock ? 56 : 72
        return object
    }
}

enum PresentationImport {
    struct Document: Codable {
        var name: String
        var groups: [Group]
    }

    struct Group: Codable {
        var name: String
        var colorHex: String?
        var slides: [SlideDoc]
    }

    struct SlideDoc: Codable {
        var title: String?
        var lines: [String]
        var notes: String?
        var isBlank: Bool?
    }

    static func parseJSON(_ data: Data) throws -> Show {
        let doc = try JSONDecoder().decode(Document.self, from: data)
        let groups = doc.groups.map { group in
            SlideGroup(
                name: group.name,
                colorHex: group.colorHex ?? "#5B8DEF",
                slides: group.slides.map { slide in
                    Slide(
                        title: slide.title ?? "",
                        lines: slide.lines,
                        notes: slide.notes ?? "",
                        isBlank: slide.isBlank ?? false
                    )
                }
            )
        }
        return Show(name: doc.name, groups: groups, notes: "Imported interchange JSON")
    }
}

enum VideoInputRuntime {
    enum Result: Equatable, Sendable {
        case started
        case denied(String)
        case unsupported(String)
    }

    static func activate(_ source: VideoInputSource) -> Result {
        switch source.kind {
        case .camera:
            return .started
        case .ndi:
            if NDIRuntime.shouldActivate {
                return .started
            }
            return .unsupported("NDI 6 runtime is not loaded. Install the NDI SDK and enable live I/O.")
        case .rtsp:
            return .unsupported("RTSP capture is configured as an input kind, not started in CI.")
        case .captureCard:
            return .unsupported("Capture card input is configured as an input kind, not started in CI.")
        case .screenShare:
            return .started
        case .continuity:
            return .started
        case .webrtc:
            return VideoInputRuntime.activateWebRTCIfSignaled(source)
        }
    }

    static func deactivate(_ source: VideoInputSource) -> Bool {
        source.kind == .camera || source.kind == .ndi || source.kind == .rtsp || source.kind == .captureCard
            || source.kind == .screenShare || source.kind == .continuity || source.kind == .webrtc
    }
}

protocol StreamTransport: AnyObject {
    var bytesWritten: Int { get }
    var isReady: Bool { get }
    func connect(config: RtmpStreamConfig) throws
    func waitUntilReady(timeoutMs: Int) async -> Bool
    func write(frameBytes: Int)
    func send(_ payload: Data)
    func send(_ payload: Data, kind: RTMPOutboundTag)
    func disconnect()
}

extension StreamTransport {
    func send(_ payload: Data, kind: RTMPOutboundTag) {
        send(payload)
    }
}

final class MockStreamTransport: StreamTransport, @unchecked Sendable {
    private(set) var bytesWritten = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var isReady = false
    var shouldFailConnect = false

    func connect(config: RtmpStreamConfig) throws {
        if shouldFailConnect { throw NSError(domain: "ProShow.Stream", code: 1) }
        connectCount += 1
        isReady = true
    }

    func waitUntilReady(timeoutMs: Int) async -> Bool {
        isReady
    }

    func write(frameBytes: Int) {
        bytesWritten += max(0, frameBytes)
    }

    func send(_ payload: Data) {
        bytesWritten += payload.count
    }

    func disconnect() {
        disconnectCount += 1
        isReady = false
    }

    func forceDrop() {
        isReady = false
    }
}

struct EncoderAllocation: Equatable, Sendable {
    var width: Int
    var height: Int
    var framerate: Int
    var bitrateKbps: Int
    var gopFrames: Int
    var keyframeIntervalSec: Int
    var frameInterval: TimeInterval
}

enum EncoderBitrateProfile {
    static func allocation(for settings: ProjectSettings) -> EncoderAllocation {
        let fps = settings.frameRate
        return EncoderAllocation(
            width: settings.resolution.width,
            height: settings.resolution.height,
            framerate: fps.encoderFPS,
            bitrateKbps: bitrateKbps(width: settings.resolution.width, height: settings.resolution.height, frameRate: fps),
            gopFrames: fps.gopFrames,
            keyframeIntervalSec: 2,
            frameInterval: fps.frameInterval
        )
    }

    static func bitrateKbps(width: Int, height: Int, frameRate: TargetFrameRate) -> Int {
        let pixels = width * height
        let highMotion = frameRate == .fps60 || frameRate == .fps5994
        if width >= 3800 || pixels >= 3840 * 2000 {
            return highMotion ? 18_000 : 11_500
        }
        if width == 1080 && height == 1920 {
            return highMotion ? 7_000 : 5_000
        }
        if width == 1920 && height == 1080 {
            return highMotion ? 7_500 : 5_500
        }
        if highMotion { return 4_500 }
        return 3_500
    }
}

struct ProgramEncoderSettings: Equatable, Sendable {
    var codec: String
    var width: Int
    var height: Int
    var framerate: Int
    var bitrateKbps: Int
    var keyframeIntervalSec: Int
    var keyframeIntervalFrames: Int
    var audioCodec: String
    var audioBitrateKbps: Int
    var frameInterval: TimeInterval

    static let program1080p30 = ProgramEncoderSettings(
        codec: "H264",
        width: 1920,
        height: 1080,
        framerate: 30,
        bitrateKbps: 5500,
        keyframeIntervalSec: 2,
        keyframeIntervalFrames: 60,
        audioCodec: "AAC",
        audioBitrateKbps: 128,
        frameInterval: 1.0 / 30.0
    )

    static func from(_ config: RtmpStreamConfig) -> ProgramEncoderSettings {
        ProgramEncoderSettings(
            codec: config.codec,
            width: config.width,
            height: config.height,
            framerate: config.framerate,
            bitrateKbps: config.bitrateKbps,
            keyframeIntervalSec: config.keyframeIntervalSec,
            keyframeIntervalFrames: max(config.framerate, 1) * 2,
            audioCodec: config.audioCodec,
            audioBitrateKbps: config.audioBitrateKbps,
            frameInterval: 1.0 / Double(max(config.framerate, 1))
        )
    }

    static func from(_ settings: ProjectSettings) -> ProgramEncoderSettings {
        let allocation = EncoderBitrateProfile.allocation(for: settings)
        return ProgramEncoderSettings(
            codec: "H264",
            width: allocation.width,
            height: allocation.height,
            framerate: allocation.framerate,
            bitrateKbps: allocation.bitrateKbps,
            keyframeIntervalSec: allocation.keyframeIntervalSec,
            keyframeIntervalFrames: allocation.gopFrames,
            audioCodec: "AAC",
            audioBitrateKbps: 128,
            frameInterval: allocation.frameInterval
        )
    }
}
