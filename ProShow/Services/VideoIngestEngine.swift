import Foundation
import Observation
import os
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
import CoreMedia
#endif
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
#if os(macOS)
import AppKit
#endif

struct VideoIngestFrame: Hashable, Sendable {
    var sourceID: UUID
    var label: String
    var kind: VideoInputKind
    var width: Int
    var height: Int
    var timestamp: TimeInterval
    var backend: String
    var sample: RGBA8
}

struct ScreenCapturePreset: Hashable, Sendable {
    var width: Int
    var height: Int
    var fps: Int
    var capturesAudio: Bool
}

/// Per-display screen share frame rate, kept on this Mac by display endpoint. Video only.
enum ScreenShareSmoothness: String, CaseIterable, Sendable {
    case smooth
    case light

    var fps: Int { self == .smooth ? 30 : 15 }
    var title: String { self == .smooth ? "Smooth (30 fps)" : "Light (15 fps)" }

    static func defaultsKey(_ endpoint: String) -> String { "screenShareSmoothness." + endpoint }

    static func current(endpoint: String?) -> ScreenShareSmoothness {
        let endpoint = (endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty,
              let raw = UserDefaults.standard.string(forKey: defaultsKey(endpoint)),
              let value = ScreenShareSmoothness(rawValue: raw)
        else { return .smooth }
        return value
    }
}

protocol VideoDeviceCataloging: Sendable {
    func cameras() -> [StudioVideoSource]
    func screens() -> [StudioVideoSource]
}

/// Keep `AVCaptureDevice.DiscoverySession` alive. Creating one and letting it
/// deallocate unloads CMIO plugins ("the System is exiting" / GetPropertyData `unk?`).
enum PersistentCaptureDiscovery {
    #if canImport(AVFoundation)
    private static let lock = NSLock()
    private static var sessions: [String: AVCaptureDevice.DiscoverySession] = [:]

    static func devices(types: [AVCaptureDevice.DeviceType], mediaType: AVMediaType) -> [AVCaptureDevice] {
        let key = mediaType.rawValue + "|" + types.map(\.rawValue).sorted().joined(separator: ",")
        lock.lock()
        defer { lock.unlock() }
        if let cached = sessions[key] {
            return cached.devices
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: mediaType,
            position: .unspecified
        )
        sessions[key] = session
        return session.devices
    }
    #endif
}

struct SystemVideoDeviceCatalog: VideoDeviceCataloging {
    /// `.external` loads CMIO DAL plugins (NDI, virtual cams) into the process. Keep that opt-in.
    func cameras() -> [StudioVideoSource] {
        cameras(includeExternal: false)
    }

    func cameras(includeExternal: Bool) -> [StudioVideoSource] {
        #if canImport(AVFoundation)
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if includeExternal {
            if #available(macOS 14.0, iOS 17.0, *) {
                types.append(.external)
            }
        }
        var seen = Set<String>()
        return PersistentCaptureDiscovery.devices(types: types, mediaType: .video).enumerated().compactMap { index, device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            guard !Self.isUnsafeCaptureDevice(name: device.localizedName, uniqueID: device.uniqueID) else {
                return nil
            }
            let continuity = isContinuity(device)
            let endpoint = "avf://\(device.uniqueID)"
            return StudioVideoSource(
                id: seedID(forCameraAt: index, continuity: continuity, endpoint: endpoint),
                label: device.localizedName,
                kind: continuity ? .continuity : .camera,
                endpoint: endpoint
            )
        }
        #else
        return []
        #endif
    }

    static func isUnsafeCaptureDevice(name: String, uniqueID: String) -> Bool {
        let haystack = "\(name) \(uniqueID)".lowercased()
        return haystack.contains("ndi")
            || haystack.contains("newtek")
            || haystack.contains("obs virtual")
            || haystack.contains("proshow virtual")
    }

    func screens() -> [StudioVideoSource] {
        #if os(macOS)
        return NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = ScreenShareCatalog.cgDisplayID(of: screen) else { return nil }
            let endpoint = ScreenShareEndpoint.display(id)
            return StudioVideoSource(
                id: index == 0 ? StudioSeedID.screen : HardwareSourceIdentity.uuid(for: endpoint),
                label: "Entire Display — \(screen.localizedName)",
                kind: .screenShare,
                endpoint: endpoint
            )
        }
        #else
        return [
            StudioVideoSource(
                id: StudioSeedID.screen,
                label: "Device Screen",
                kind: .screenShare,
                endpoint: "sck://display/0"
            )
        ]
        #endif
    }

    static func screenCapturePreset(width: Int, height: Int, fps: Int) -> ScreenCapturePreset {
        ScreenCapturePreset(
            width: max(1, width),
            height: max(1, height),
            fps: max(1, min(fps, 30)),
            capturesAudio: false
        )
    }

    #if canImport(AVFoundation)
    static func isContinuity(_ device: AVCaptureDevice) -> Bool {
        if #available(macOS 14.0, iOS 17.0, *) {
            if device.deviceType == .continuityCamera { return true }
        }
        let name = device.localizedName
        return name.localizedCaseInsensitiveContains("iphone")
            || name.localizedCaseInsensitiveContains("ipad")
            || name.localizedCaseInsensitiveContains("continuity")
    }

    private func isContinuity(_ device: AVCaptureDevice) -> Bool {
        Self.isContinuity(device)
    }
    #endif

    private func seedID(forCameraAt index: Int, continuity: Bool, endpoint: String) -> UUID {
        if continuity { return StudioSeedID.cameraB }
        return index == 0 ? StudioSeedID.camera : HardwareSourceIdentity.uuid(for: endpoint)
    }
}

struct SystemAudioDeviceCatalog {
    func microphones() -> [StudioAudioDevice] {
        #if canImport(AVFoundation)
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, iOS 17.0, *) {
            types.append(.microphone)
        }
        var seen = Set<String>()
        return PersistentCaptureDiscovery.devices(types: types, mediaType: .audio).compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return StudioAudioDevice(
                id: device.uniqueID,
                name: device.localizedName,
                endpoint: "avf://\(device.uniqueID)"
            )
        }
        #else
        return []
        #endif
    }
}

@MainActor
final class LiveInputLane {
    var sourceID: UUID
    var endpoint: String
    var kind: StudioVideoKind
    var backend: String
    var deviceName = ""
    var isLive = false
    var audioCaptureEnabled = false
    var lastFrame: VideoIngestFrame?
    #if canImport(CoreVideo)
    var lastPixelBuffer: CVPixelBuffer?
    #endif
    #if canImport(AVFoundation)
    var session: AVCaptureSession?
    let cameraRelay = CameraSampleRelay()
    #endif
    #if canImport(ScreenCaptureKit)
    var stream: SCStream?
    let screenRelay = ScreenSampleRelay()
    var screenCaptureGeneration: UInt = 0
    var screenCaptureStopped = false
    var screenCaptureAcceptStops = false
    var screenCaptureArmedAt: Date?
    var lastScreenFrameAt: Date?
    var screenFramesPublished: UInt64 = 0
    var screenIdleFrames: UInt64 = 0
    var screenCaptureFPS = 0
    var hasLiveScreenStream: Bool {
        stream != nil && !screenCaptureStopped
    }
    #endif

    init(sourceID: UUID, endpoint: String, kind: StudioVideoKind, backend: String) {
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.kind = kind
        self.backend = backend
    }
}

#if canImport(AVFoundation)
/// Logs capture runtime failures and drops the observer when the session stops.
enum CaptureSessionWatch {
    private static let log = Logger(subsystem: "com.proshow", category: "capture")
    private static let lock = NSLock()
    private static var tokens: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func watch(_ session: AVCaptureSession) {
        #if canImport(AVFoundation)
        let token = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { note in
            let running = (note.object as? AVCaptureSession)?.isRunning ?? false
            let error = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            log.error("AVCaptureSessionRuntimeError running=\(running, privacy: .public) \(error, privacy: .public)")
        }
        let id = ObjectIdentifier(session)
        lock.lock()
        if let old = tokens.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(old)
        }
        tokens[id] = token
        lock.unlock()
        #endif
    }

    static func stop(_ session: AVCaptureSession?) {
        guard let session else { return }
        let id = ObjectIdentifier(session)
        lock.lock()
        let token = tokens.removeValue(forKey: id)
        lock.unlock()
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    static func note(_ message: String) {
        log.info("\(message, privacy: .public)")
    }

    static func logFailure(_ message: String) {
        log.error("\(message, privacy: .public)")
    }
}
#endif

/// Owns the program camera session and screen-share stream. NDI uses a launch-safe C-SDK loader; RTSP/WebRTC stay gated.
@MainActor
@Observable
final class VideoIngestEngine {
    var hardwareEnabled = false
    @ObservationIgnored private var ndiReceivers: [String: NDIReceiver] = [:]
    @ObservationIgnored
    var lastFrame: VideoIngestFrame?
    #if canImport(CoreVideo)
    @ObservationIgnored
    var lastPixelBuffer: CVPixelBuffer?
    #endif
    var lastPIPFrame: VideoIngestFrame?
    var lastResult: VideoInputRuntime.Result?
    @ObservationIgnored
    var frameRevision: UInt64 = 0
    var catalog: VideoDeviceCataloging = SystemVideoDeviceCatalog()
    var outputWidth = 1920
    var outputHeight = 1080
    var outputFPS = 30
    var captureAboveOutput = false

    private struct LiveStreamScreenCaptureContract: Equatable {
        var width: Int
        var height: Int
        var fps: Int
    }

    @ObservationIgnored private var liveStreamScreenCaptureContract: LiveStreamScreenCaptureContract?

    #if canImport(AVFoundation)
    private(set) var captureSession: AVCaptureSession?
    /// One camera session and one mic session for the process. New session objects leak a CMIO audio queue. Stopping and starting these same objects does not.
    /// One app-lifetime session per physical camera (keyed by device uniqueID). A single shared
    /// session meant every camera slot reused the first camera, so only one camera could be assigned.
    private static var retainedCameraSessions: [String: AVCaptureSession] = [:]

    private static func isRetainedSession(_ session: AVCaptureSession?) -> Bool {
        guard let session else { return false }
        return session === retainedMicSession || retainedCameraSessions.values.contains { $0 === session }
    }
    private static var retainedMicSession: AVCaptureSession?
    #endif
    private var activeSourceID: UUID?
    private var activeBackend: String = "unavailable"
    private(set) var hardwareStartCount = 0
    private var lanes: [String: LiveInputLane] = [:]

    #if canImport(ScreenCaptureKit)
    private var screenStream: SCStream?
    private var screenStreamsPendingStop: [SCStream] = []
    private var screenCaptureChain: Task<Void, Never>?
    private var lastScreenRestartAt: [String: Date] = [:]
    private var spaceChangeObserver: NSObjectProtocol?
    #endif
    /// Written from the capture queue, drained on main: always accessed under `lanePublishLock`.
    @ObservationIgnored nonisolated(unsafe) private var lanePublishCoalesced = false
    /// One slot per lane: a 30 fps camera must not overwrite the screen's pending frame.
    @ObservationIgnored nonisolated(unsafe) private var pendingLanePublishes: [ObjectIdentifier: @MainActor () -> Void] = [:]
    @ObservationIgnored nonisolated(unsafe) private var lanePublishInterval: Double = 1.0 / 30.0
    @ObservationIgnored private nonisolated let lanePublishLock = NSLock()
    /// Invoked on `videoIngestQueue` — must not hop through MainActor (live stream latency).
    @ObservationIgnored nonisolated(unsafe) var onCaptureAudio: ((AudioChannelRole, [Float], Double, String) -> Void)?
    @ObservationIgnored nonisolated(unsafe) var onCaptureAudioPeak: ((AudioChannelRole, Double) -> Void)?

    func configureOutput(width: Int, height: Int, fps: Int, captureAboveOutput: Bool = false) {
        let picture = CaptureBudget.deliveryResolution(DisplayResolution(width: width, height: height))
        outputWidth = picture.width
        outputHeight = picture.height
        outputFPS = fps
        lanePublishLock.lock()
        lanePublishInterval = 1.0 / Double(min(max(fps, 10), 60))
        lanePublishLock.unlock()
        self.captureAboveOutput = captureAboveOutput
        reapplyCapturePresets()
    }

    #if canImport(AVFoundation)
    /// Preset follows the show. `.high` is not used, because many cameras treat it as 4K.
    /// An empty session reports `canSetSessionPreset` for 4K even when the camera cannot.
    /// The device check is what actually decides.
    static func capturePresets(
        outputWidth: Int,
        outputHeight: Int,
        allowAboveOutput: Bool
    ) -> [AVCaptureSession.Preset] {
        CaptureBudget.capturePresetSteps(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            allowAboveOutput: allowAboveOutput
        ).map { step in
            switch step {
            case .uhd4k: return .hd4K3840x2160
            case .hd1080: return .hd1920x1080
            case .hd720: return .hd1280x720
            case .medium: return .medium
            }
        }
    }

    static func applyCapturePreset(
        _ session: AVCaptureSession,
        device: AVCaptureDevice?,
        outputWidth: Int,
        outputHeight: Int,
        allowAboveOutput: Bool
    ) {
        for preset in capturePresets(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            allowAboveOutput: allowAboveOutput
        ) {
            if let device, device.supportsSessionPreset(preset) == false { continue }
            guard session.canSetSessionPreset(preset) else { continue }
            session.sessionPreset = preset
            return
        }
    }

    private func reapplyCapturePresets() {
        let width = outputWidth
        let height = outputHeight
        let above = captureAboveOutput
        let sessions = lanes.values.compactMap(\.session)
        for session in sessions {
            ProShowQueues.captureControlQueue.async {
                session.beginConfiguration()
                let device = session.inputs
                    .compactMap { $0 as? AVCaptureDeviceInput }
                    .map(\.device)
                    .first { $0.hasMediaType(.video) }
                Self.applyCapturePreset(
                    session,
                    device: device,
                    outputWidth: width,
                    outputHeight: height,
                    allowAboveOutput: above
                )
                session.commitConfiguration()
            }
        }
    }
    #endif

    /// While on air, capture the display at or below stream encode size so composite + encode keep up.
    func applyLiveStreamScreenCaptureContract(width: Int, height: Int, fps: Int, sources: [StudioVideoSource]) {
        let next = LiveStreamScreenCaptureContract(
            width: max(640, width),
            height: max(360, height),
            fps: max(1, min(60, fps))
        )
        guard liveStreamScreenCaptureContract != next else { return }
        liveStreamScreenCaptureContract = next
        refreshDisplayScreenCaptureExclusions(sources: sources)
    }

    func clearLiveStreamScreenCaptureContract() {
        guard liveStreamScreenCaptureContract != nil else { return }
        liveStreamScreenCaptureContract = nil
    }

    func discoverDevices(scanCameras: Bool = false) -> [StudioVideoSource] {
        var merged = discoverPresentHardware(scanCameras: scanCameras)
        let required: [StudioVideoSource] = [
            StudioVideoSource(id: StudioSeedID.camera, label: "Built-in Camera", kind: .camera),
            StudioVideoSource(id: StudioSeedID.cameraB, label: "Continuity Camera", kind: .continuity),
            StudioVideoSource(id: StudioSeedID.screen, label: "Display Capture", kind: .screenShare, endpoint: "sck://display/0"),
        ]
        for seed in required where !merged.contains(where: { $0.id == seed.id || $0.kind == seed.kind }) {
            merged.append(seed)
        }
        return merged
    }

    func discoverPresentHardware(scanCameras: Bool = true) -> [StudioVideoSource] {
        let cameras = scanCameras
            ? (catalog as? SystemVideoDeviceCatalog)?.cameras(includeExternal: true) ?? catalog.cameras()
            : []
        return cameras + catalog.screens()
    }

    @discardableResult
    func start(_ source: StudioVideoSource, pip: Bool = false) -> VideoInputRuntime.Result {
        if source.kind == .ndi, hardwareEnabled, NDIRuntime.isAvailable {
            NDIRuntime.hardwareEnabled = true
        }
        let result = VideoInputRuntime.activate(source.inputSource)
        lastResult = result
        guard result == .started else { return result }
        if !pip, let lane = liveLane(for: source), lane.kind == source.kind || sameCaptureFamily(lane.kind, source.kind) {
            #if canImport(ScreenCaptureKit)
            if source.kind == .screenShare, !lane.hasLiveScreenStream {
                restartScreenCapture(source, force: true)
                return result
            } else {
                adopt(lane, as: source)
                return result
            }
            #else
            adopt(lane, as: source)
            return result
            #endif
        }
        if !pip {
            activeSourceID = source.id
        }
        let backend = Self.backend(for: source.kind)
        publish(source: source, backend: backend, pip: pip)
        if hardwareEnabled, !pip, source.hasBindableHardwareEndpoint {
            startHardware(source)
        }
        return result
    }

    func isRunning(_ source: StudioVideoSource) -> Bool {
        lane(for: source)?.isLive == true
    }

    func isRunning(endpoint: String?, sourceID: String?) -> Bool {
        resolveLane(endpoint: endpoint, sourceID: sourceID)?.isLive == true
    }

    func pixelBuffer(endpoint: String?, sourceID: String?, kind: StudioVideoKind? = nil) -> CVPixelBuffer? {
        if let lane = resolveLane(endpoint: endpoint, sourceID: sourceID),
           kind == nil || sameCaptureFamily(lane.kind, kind!),
           let buffer = lane.lastPixelBuffer {
            return buffer
        }
        guard let kind else { return nil }
        return livePixelBuffer(kind: kind)
    }

    func livePixelBuffer(kind: StudioVideoKind) -> CVPixelBuffer? {
        lanes.values.first {
            $0.isLive && sameCaptureFamily($0.kind, kind) && $0.lastPixelBuffer != nil
        }?.lastPixelBuffer
    }

    func activeIsoChannelConfigs(
        defaultCodec: IsoRecordChannelConfig.IsoVideoCodec = .h264Hardware
    ) -> [IsoRecordChannelConfig] {
        lanes.values.compactMap { lane in
            guard lane.isLive else { return nil }
            let name = lane.deviceName.isEmpty ? lane.kind.rawValue : lane.deviceName
            return IsoRecordChannelConfig(
                sourceId: lane.sourceID.uuidString,
                channelName: name,
                codec: lane.kind == .screenShare ? .proRes422 : defaultCodec,
                width: outputWidth,
                height: outputHeight,
                fps: outputFPS
            )
        }
    }

    func livePixelBuffer(matching sourceID: UUID, kind: VideoInputKind) -> CVPixelBuffer? {
        let studioKind = StudioVideoKind(videoInput: kind)
        if let lane = lanes.values.first(where: {
            $0.isLive && $0.sourceID == sourceID && sameCaptureFamily($0.kind, studioKind)
        }), let buffer = lane.lastPixelBuffer {
            return buffer
        }
        if studioKind == .screenShare,
           let lane = lanes.values.first(where: { $0.isLive && $0.kind == .screenShare }),
           let buffer = lane.lastPixelBuffer {
            return buffer
        }
        if studioKind == .camera || studioKind == .continuity,
           let lane = lanes.values.first(where: {
               $0.isLive && ($0.kind == .camera || $0.kind == .continuity)
           }),
           let buffer = lane.lastPixelBuffer {
            return buffer
        }
        return nil
    }

    private func sameEndpointFamily(_ requested: String, _ laneEndpoint: String) -> Bool {
        func family(_ endpoint: String) -> String {
            if endpoint.hasPrefix("sck://") { return "screen" }
            if endpoint.hasPrefix("avf://") { return "camera" }
            if endpoint.hasPrefix("ndi://") { return "ndi" }
            return "other"
        }
        let left = family(requested)
        let right = family(laneEndpoint)
        if left == "other" || right == "other" { return true }
        return left == right
    }

    private func sameCaptureFamily(_ lhs: StudioVideoKind, _ rhs: StudioVideoKind) -> Bool {
        switch (lhs, rhs) {
        case (.camera, .camera), (.continuity, .continuity), (.camera, .continuity), (.continuity, .camera):
            return true
        case (.screenShare, .screenShare):
            return true
        default:
            return lhs == rhs
        }
    }

    func frame(endpoint: String?, sourceID: String?) -> VideoIngestFrame? {
        resolveLane(endpoint: endpoint, sourceID: sourceID)?.lastFrame
    }

    #if canImport(AVFoundation)
    func captureSession(endpoint: String?, sourceID: String?) -> AVCaptureSession? {
        resolveLane(endpoint: endpoint, sourceID: sourceID)?.session
    }
    #endif

    func clearPIPFrame() {
        lastPIPFrame = nil
    }

    static func dedicatedAudioLaneKey(endpoint: String) -> String {
        "audio:\(endpoint)"
    }

    /// Stops AVFoundation / ScreenCaptureKit audio taps for a lane key or source id.
    func stopAudioCapture(sourceID: String) {
        stopAudioCapture(endpoint: nil, sourceID: sourceID)
    }

    /// Re-open capture after operator teardown (same shot / source taken live again).
    func refreshDisplayScreenCaptureExclusions(sources: [StudioVideoSource]) {
        #if canImport(ScreenCaptureKit)
        ProShowStreamCapturePrivacy.pinFeedbackWindowsOutOfCapture()
        for source in sources where source.kind == .screenShare {
            let endpoint = (source.endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard endpoint.hasPrefix("sck://display/") else { continue }
            guard let lane = liveLane(for: source) ?? lane(for: source), lane.isLive, lane.stream != nil else {
                continue
            }
            teardownLane(lane)
            _ = start(source)
        }
        #endif
    }

    func rearmLiveCapture(for source: StudioVideoSource) {
        if source.kind == .screenShare {
            ProgramStreamAudioGates.setHardwareCaptureOpen(.desktop, open: true)
        } else if source.kind == .camera || source.kind == .continuity {
            ProgramStreamAudioGates.setHardwareCaptureOpen(.microphone, open: true)
        }
        guard hardwareEnabled else { return }
        if let lane = liveLane(for: source) ?? lane(for: source), lane.isLive {
            if source.kind == .camera || source.kind == .continuity {
                #if canImport(AVFoundation)
                if let session = lane.session, sessionHasAudioOutput(session) {
                    // Picture only: a camera session's audio output never feeds the mic lane.
                    lane.audioCaptureEnabled = false
                    wireCameraCaptureAudio(lane: lane)
                    return
                }
                #endif
                guard shouldAddCameraMicrophone(except: lane) else {
                    lane.audioCaptureEnabled = false
                    wireCameraCaptureAudio(lane: lane)
                    return
                }
                lane.audioCaptureEnabled = true
                #if canImport(AVFoundation)
                if let session = lane.session {
                    restoreCameraAudioPipeline(source: source, lane: lane, session: session)
                    wireCameraCaptureAudio(lane: lane)
                    return
                }
                #endif
            }
            if source.kind == .screenShare, lane.stream != nil {
                #if canImport(ScreenCaptureKit)
                let sourceKey = lane.endpoint
                lane.screenRelay.onAudioPCM = { [weak self] samples, rate in
                    self?.onCaptureAudio?(.desktop, samples, rate, sourceKey)
                }
                #endif
                return
            }
        }
        _ = start(source)
    }

    func stopAudioCapture(endpoint: String?, sourceID: String?) {
        guard let lane = resolveLane(endpoint: endpoint, sourceID: sourceID) else { return }
        stopAudioCapture(on: lane)
    }

    /// Drop capture lanes whose audio/video is no longer referenced by the program stack.
    /// While live, leave a running camera session alone. Slide changes were calling
    /// `beginConfiguration` and removing the audio output, which killed the stream mix.
    func reconcileCapture(audioLaneKeys: Set<String>, videoLaneKeys: Set<String>, preserveLiveAudio: Bool = false) {
        let snapshot = Array(lanes)
        for (key, lane) in snapshot where lane.isLive {
            let needsVideo = laneIsRequired(lane, key: key, keeping: videoLaneKeys)
            let needsAudio = laneIsRequired(lane, key: key, keeping: audioLaneKeys)
            if preserveLiveAudio, lane.session != nil || lane.isLive {
                continue
            }
            if !needsAudio {
                if needsVideo {
                    softMuteAudioCapture(on: lane)
                } else {
                    stopAudioCapture(on: lane)
                }
            }
            if !needsVideo {
                teardownLane(lane)
            }
        }
    }

    /// Read-only screen capture counters (QA capture_diag).
    func screenCaptureDiagnostics() -> [[String: Any]] {
        #if canImport(ScreenCaptureKit)
        let now = Date()
        var seen = Set<ObjectIdentifier>()
        return lanes.values.compactMap { lane -> [String: Any]? in
            guard lane.kind == .screenShare, lane.isLive, seen.insert(ObjectIdentifier(lane)).inserted else { return nil }
            return [
                "endpoint": lane.endpoint,
                "generation": lane.screenCaptureGeneration,
                "frames": lane.screenFramesPublished,
                "idle": lane.screenIdleFrames,
                "since_frame_s": lane.lastScreenFrameAt.map { now.timeIntervalSince($0) } ?? -1,
                "stream": lane.stream != nil,
                "fps_cap": lane.screenCaptureFPS,
                "width": lane.lastFrame?.width ?? 0,
                "height": lane.lastFrame?.height ?? 0,
            ]
        }
        #else
        return []
        #endif
    }

    func liveCaptureLaneKeys() -> [String] {
        lanes.filter { $0.value.isLive }.map(\.key)
    }

    private func laneIsRequired(_ lane: LiveInputLane, key: String, keeping: Set<String>) -> Bool {
        if keeping.contains(key) || keeping.contains(lane.endpoint) || keeping.contains(lane.sourceID.uuidString) {
            return true
        }
        if let avf = CameraIdentity.avfUniqueID(from: lane.endpoint) {
            if keeping.contains("avf://\(avf)") { return true }
        }
        for token in keeping where sameEndpointFamily(token, lane.endpoint) && token == lane.endpoint {
            return true
        }
        return false
    }

    /// Operator mute — silence PCM without stopping camera / screen video capture.
    private func softMuteAudioCapture(on lane: LiveInputLane) {
        #if canImport(AVFoundation)
        if let session = lane.session {
            for shared in lanes.values where shared.session === session {
                shared.audioCaptureEnabled = false
            }
        } else {
            lane.audioCaptureEnabled = false
        }
        #else
        lane.audioCaptureEnabled = false
        #endif
        let relay = audioRelayOwner(for: lane).cameraRelay
        relay.onAudioPCM = nil
        relay.onAudioPeak = nil
        #if canImport(ScreenCaptureKit)
        lane.screenRelay.onAudioPCM = nil
        lane.screenRelay.onAudioPeak = nil
        #endif
    }

    private func stopAudioCapture(on lane: LiveInputLane) {
        softMuteAudioCapture(on: lane)
        #if canImport(AVFoundation)
        guard let session = lane.session else { return }
        CaptureSessionLifetime.configure {
            session.beginConfiguration()
            for output in session.outputs {
                guard let audioOutput = output as? AVCaptureAudioDataOutput else { continue }
                audioOutput.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(audioOutput)
            }
            session.commitConfiguration()
        }
        if session.outputs.isEmpty {
            for shared in lanes.values where shared.session === session {
                shared.session = nil
            }
            if captureSession === session {
                captureSession = nil
            }
            CaptureSessionWatch.stop(session)
            CaptureSessionLifetime.stop(session)
        }
        #endif
    }

    private func audioRelayOwner(for lane: LiveInputLane) -> LiveInputLane {
        #if canImport(AVFoundation)
        if let session = lane.session,
           let owner = lanes.values.first(where: { $0.session === session }) {
            return owner
        }
        #endif
        return lane
    }

    private func teardownLane(_ lane: LiveInputLane) {
        stopNDIReceiver(for: lane.endpoint)
        stopAudioCapture(on: lane)
        lane.isLive = false
        #if canImport(AVFoundation)
        lane.cameraRelay.onFrame = nil
        lane.cameraRelay.onAudioPCM = nil
        lane.cameraRelay.onAudioPeak = nil
        if let session = lane.session {
            if Self.isRetainedSession(session) {
                // Shared app-lifetime session: never restart it on a slide change.
                let stillUsed = lanes.values.contains { $0 !== lane && $0.isLive && $0.session === session }
                if !stillUsed {
                    CaptureSessionLifetime.pause(session, after: 20)
                }
            } else {
                CaptureSessionWatch.stop(session)
                CaptureSessionLifetime.stop(session)
            }
            lane.session = nil
        }
        #endif
        #if canImport(ScreenCaptureKit)
        lane.screenRelay.onFrame = nil
        lane.screenRelay.onStopped = nil
        lane.screenRelay.onAudioPCM = nil
        lane.screenRelay.onAudioPeak = nil
        retireScreenStream(lane.stream)
        lane.stream = nil
        lane.screenCaptureStopped = true
        #endif
        let keys = lanes.filter { $0.value.sourceID == lane.sourceID || $0.value === lane }.map(\.key)
        for key in keys {
            lanes.removeValue(forKey: key)
        }
        if activeSourceID == lane.sourceID {
            activeSourceID = lanes.values.first(where: \.isLive)?.sourceID
        }
        if lane.lastFrame != nil || lane.lastPixelBuffer != nil {
            lane.lastFrame = nil
            #if canImport(CoreVideo)
            lane.lastPixelBuffer = nil
            #endif
        }
    }

    func stop() {
        stopHardware()
        lanes.removeAll()
        activeSourceID = nil
        lastFrame = nil
        #if canImport(CoreVideo)
        lastPixelBuffer = nil
        #endif
        lastPIPFrame = nil
        lastResult = nil
        frameRevision = 0
    }

    func inject(_ frame: VideoIngestFrame, pip: Bool = false, pixelBuffer: CVPixelBuffer? = nil) {
        if pip {
            lastPIPFrame = frame
        } else {
            lastFrame = frame
            #if canImport(CoreVideo)
            if let pixelBuffer {
                lastPixelBuffer = pixelBuffer
                LivePixelHub.shared.publish(endpoint: nil, sourceID: frame.sourceID.uuidString, buffer: pixelBuffer)
            }
            #endif
        }
        frameRevision &+= 1
    }

    func screenCapturePreset() -> ScreenCapturePreset {
        let captureWidth: Int
        let captureHeight: Int
        let captureFPS: Int
        if let contract = liveStreamScreenCaptureContract {
            captureWidth = min(outputWidth, contract.width)
            captureHeight = min(outputHeight, contract.height)
            captureFPS = min(outputFPS, contract.fps)
        } else {
            captureWidth = outputWidth
            captureHeight = outputHeight
            captureFPS = outputFPS
        }
        let base = SystemVideoDeviceCatalog.screenCapturePreset(
            width: captureWidth,
            height: captureHeight,
            fps: captureFPS
        )
        guard hardwareEnabled else { return base }
        return ScreenCapturePreset(
            width: base.width,
            height: base.height,
            fps: base.fps,
            capturesAudio: true
        )
    }

    var activeHardwareMicrophoneCapture: Bool {
        lanes.values.contains { lane in
            lane.isLive && lane.audioCaptureEnabled && laneProvidesMicrophonePCM(lane)
        }
    }

    private func laneProvidesMicrophonePCM(_ lane: LiveInputLane) -> Bool {
        lane.kind == .camera
            || lane.kind == .continuity
            || lane.backend == "avfoundation-audio"
    }

    static func backend(for kind: StudioVideoKind) -> String {
        switch kind {
        case .camera, .continuity: return "avfoundation"
        case .screenShare: return "screenCaptureKit"
        case .ndi: return NDIRuntime.shouldActivate ? "ndi" : "unsupported"
        case .webrtc: return "webrtc-signaling"
        case .rtsp, .captureCard: return "unsupported"
        }
    }

    private func publish(source: StudioVideoSource, backend: String, pip: Bool) {
        activeBackend = backend
        let frame = VideoIngestFrame(
            sourceID: source.id,
            label: source.label,
            kind: source.inputSource.kind,
            width: outputWidth,
            height: outputHeight,
            timestamp: Date().timeIntervalSinceReferenceDate,
            backend: backend,
            sample: source.chromaEnabled
                ? RGBA8(r: 0, g: 1, b: 0, a: 1)
                : RGBA8(r: 0.12, g: 0.14, b: 0.18, a: 1)
        )
        inject(frame, pip: pip)
    }

    private func startHardware(_ source: StudioVideoSource) {
        if let live = liveLane(for: source) {
            adopt(live, as: source)
            return
        }
        let key = Self.laneKey(for: source)
        let lane = lanes[key] ?? LiveInputLane(
            sourceID: source.id,
            endpoint: key,
            kind: source.kind,
            backend: Self.backend(for: source.kind)
        )
        lane.sourceID = source.id
        lane.kind = source.kind
        lane.deviceName = source.label
        lane.isLive = true
        lanes[key] = lane
        hardwareStartCount += 1
        switch source.kind {
        case .camera, .continuity:
            startCamera(source, lane: lane)
        case .screenShare:
            startScreen(source, lane: lane)
        case .ndi:
            startNDI(source)
        default:
            break
        }
    }

    private func adopt(_ lane: LiveInputLane, as source: StudioVideoSource) {
        lane.sourceID = source.id
        if !source.label.isEmpty {
            lane.deviceName = source.label
        }
        if let endpoint = source.endpoint, !endpoint.isEmpty {
            lanes[endpoint] = lane
        }
        lanes[Self.laneKey(for: source)] = lane
        activeSourceID = source.id
        activeBackend = lane.backend
        lastFrame = lane.lastFrame ?? lastFrame
        #if canImport(CoreVideo)
        lastPixelBuffer = lane.lastPixelBuffer ?? lastPixelBuffer
        #endif
        #if canImport(AVFoundation)
        if let session = lane.session {
            captureSession = session
        }
        #endif
        #if canImport(ScreenCaptureKit)
        if let stream = lane.stream {
            screenStream = stream
        }
        #endif
    }

    private func lane(for source: StudioVideoSource) -> LiveInputLane? {
        lanes[Self.laneKey(for: source)]
    }

    private func liveLane(for source: StudioVideoSource) -> LiveInputLane? {
        if let lane = lane(for: source), lane.isLive { return lane }
        if let endpoint = source.endpoint, !endpoint.isEmpty,
           let lane = lanes[endpoint], lane.isLive {
            return lane
        }
        if let lane = lanes.values.first(where: { $0.isLive && $0.sourceID == source.id }) {
            return lane
        }
        guard source.kind == .camera || source.kind == .continuity else { return nil }
        if let token = CameraIdentity.avfUniqueID(from: source.endpoint),
           let lane = lanes.values.first(where: {
               $0.isLive && CameraIdentity.avfUniqueID(from: $0.endpoint) == token
           }) {
            return lane
        }
        let name = CameraIdentity.normalizedName(source.label)
        guard !name.isEmpty else { return nil }
        return lanes.values.first {
            $0.isLive
                && ($0.kind == .camera || $0.kind == .continuity)
                && CameraIdentity.normalizedName($0.deviceName) == name
        }
    }

    private func resolveLane(endpoint: String?, sourceID: String?) -> LiveInputLane? {
        if let endpoint, !endpoint.isEmpty {
            if let lane = lanes[endpoint] { return lane }
            if let uniqueID = CameraIdentity.avfUniqueID(from: endpoint),
               let lane = lanes["avf://\(uniqueID)"] {
                return lane
            }
        }
        if let sourceID {
            if let uuid = UUID(uuidString: sourceID),
               let lane = lanes.values.first(where: { $0.sourceID == uuid }) {
                if let endpoint, !endpoint.isEmpty, !sameEndpointFamily(endpoint, lane.endpoint) {
                    return nil
                }
                return lane
            }
            if sourceID.hasPrefix("avf-video-") {
                let unique = String(sourceID.dropFirst("avf-video-".count))
                if let lane = lanes["avf://\(unique)"] { return lane }
            }
            if sourceID.hasPrefix("sck-display-") {
                let token = String(sourceID.dropFirst("sck-display-".count))
                if let lane = lanes["sck://display/\(token)"] { return lane }
            }
            if sourceID.hasPrefix("sck-window-") {
                let token = String(sourceID.dropFirst("sck-window-".count))
                if let lane = lanes["sck://window/\(token)"] { return lane }
            }
        }
        return nil
    }

    static func laneKey(for source: StudioVideoSource) -> String {
        if let endpoint = source.endpoint, !endpoint.isEmpty { return endpoint }
        return source.id.uuidString
    }

    private func startNDI(_ source: StudioVideoSource) {
        guard let lane = lane(for: source) else { return }
        guard NDIRuntime.load() else {
            lastResult = .unsupported("NDI 6 runtime not found.")
            lane.isLive = false
            return
        }
        let endpoint = source.endpoint ?? ""
        let name: String
        let url: String
        if endpoint.hasPrefix("ndi://") {
            name = String(endpoint.dropFirst("ndi://".count))
            url = ""
        } else if endpoint.isEmpty {
            name = source.label
            url = ""
        } else {
            name = source.label.isEmpty ? endpoint : source.label
            url = endpoint
        }
        stopNDIReceiver(for: lane.endpoint)
        guard let receiver = NDISessionFactory.openReceiver(sourceName: name, sourceURL: url) else {
            lastResult = .unsupported("NDI source did not open.")
            lane.isLive = false
            return
        }
        ndiReceivers[lane.endpoint] = receiver
        receiver.onVideo = { [weak self] buffer in
            Task { @MainActor in
                self?.deliverNDIFrame(buffer, source: source, lane: lane)
            }
        }
        receiver.start()
    }

    private func deliverNDIFrame(_ buffer: CVPixelBuffer, source: StudioVideoSource, lane: LiveInputLane) {
        guard lane.isLive else { return }
        publishLaneFrame(
            source: source,
            lane: lane,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            sample: sampleBGRA(buffer),
            pixel: buffer,
            backend: "ndi",
            kind: .ndi
        )
    }

    private func sampleBGRA(_ buffer: CVPixelBuffer) -> RGBA8 {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return RGBA8(r: 0.12, g: 0.14, b: 0.18, a: 1)
        }
        let pixel = base.assumingMemoryBound(to: UInt8.self)
        return RGBA8(
            r: Double(pixel[2]) / 255,
            g: Double(pixel[1]) / 255,
            b: Double(pixel[0]) / 255,
            a: 1
        )
    }

    private func stopNDIReceiver(for endpoint: String) {
        ndiReceivers[endpoint]?.stop()
        ndiReceivers.removeValue(forKey: endpoint)
    }

    private func stopNDIReceivers() {
        for receiver in ndiReceivers.values {
            receiver.stop()
        }
        ndiReceivers.removeAll()
    }

    private func stopHardware() {
        stopNDIReceivers()
        for lane in lanes.values {
            lane.isLive = false
            #if canImport(AVFoundation)
            lane.cameraRelay.onFrame = nil
            lane.cameraRelay.onAudioPCM = nil
            lane.cameraRelay.onAudioPeak = nil
            if Self.isRetainedSession(lane.session) {
                CaptureSessionLifetime.pause(lane.session)
                lane.session = nil
            } else {
                CaptureSessionWatch.stop(lane.session)
                CaptureSessionLifetime.stop(lane.session)
                lane.session = nil
            }
            #endif
            #if canImport(ScreenCaptureKit)
            lane.screenRelay.onFrame = nil
            lane.screenRelay.onStopped = nil
            lane.screenRelay.onAudioPCM = nil
            lane.screenRelay.onAudioPeak = nil
            #endif
            #if canImport(ScreenCaptureKit)
            retireScreenStream(lane.stream)
            lane.stream = nil
            lane.screenCaptureStopped = true
            lane.screenCaptureAcceptStops = false
            #endif
        }
        #if canImport(AVFoundation)
        if Self.isRetainedSession(captureSession) {
            CaptureSessionLifetime.pause(captureSession)
            captureSession = nil
        } else {
            CaptureSessionWatch.stop(captureSession)
            CaptureSessionLifetime.stop(captureSession)
            captureSession = nil
        }
        #endif
        #if canImport(ScreenCaptureKit)
        retireScreenStream(screenStream)
        screenStream = nil
        for lane in lanes.values {
            retireScreenStream(lane.stream)
            lane.stream = nil
        }
        let pending = screenStreamsPendingStop
        screenStreamsPendingStop = []
        Task {
            for stream in pending {
                try? await stream.stopCapture()
            }
        }
        spaceChangeObserver.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        spaceChangeObserver = nil
        #endif
    }

    /// Collapse bursty SCK/AVF callbacks into one MainActor publish per run loop (keeps UI/stream smooth while dragging windows).
    /// Called from capture queues. The pending closure (which strongly retains its CVPixelBuffer) is swapped under
    /// a lock and taken out on main before it runs, so the capture thread can't release it mid-call. Before this,
    /// the closure var was raced across threads and the 100 ms throttle made a use-after-free likely (EXC_BAD_ACCESS
    /// in CVPixelBufferGetIOSurface).
    nonisolated private func scheduleLanePublish(key: ObjectIdentifier, _ publish: @escaping @MainActor () -> Void) {
        lanePublishLock.lock()
        pendingLanePublishes[key] = publish
        let alreadyScheduled = lanePublishCoalesced
        lanePublishCoalesced = true
        let interval = lanePublishInterval
        lanePublishLock.unlock()
        guard !alreadyScheduled else { return }
        // Coalesce to the show frame interval, keeping the newest frame of every lane.
        // Frame fields are @ObservationIgnored, so this does not drive SwiftUI per frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self else { return }
            self.lanePublishLock.lock()
            let next = Array(self.pendingLanePublishes.values)
            self.pendingLanePublishes.removeAll(keepingCapacity: true)
            self.lanePublishCoalesced = false
            self.lanePublishLock.unlock()
            MainActor.assumeIsolated { next.forEach { $0() } }
        }
    }

    /// Placeholder matrix watchdog — updated from the ingest queue (no MainActor hop).
    var placeholderFrameNotifier: (@Sendable (String, Bool) -> Void)?

    private func notifyPlaceholderSignal(sourceKey: String) {
        placeholderFrameNotifier?(sourceKey, true)
    }

    private func publishLaneFrame(
        source: StudioVideoSource,
        lane: LiveInputLane,
        width: Int,
        height: Int,
        sample: RGBA8,
        pixel: CVPixelBuffer,
        backend: String,
        kind: VideoInputKind
    ) {
        let frame = VideoIngestFrame(
            sourceID: source.id,
            label: source.label,
            kind: kind,
            width: width,
            height: height,
            timestamp: Date().timeIntervalSinceReferenceDate,
            backend: backend,
            sample: sample
        )
        LowLatencyIngestPipeline.shared.markCapture(at: frame.timestamp)
        IsoRecorderEngine.shared.appendRawPixelBuffer(sourceId: source.id.uuidString, pixelBuffer: pixel)
        let sourceKey = source.id.uuidString
        InputFailoverEngine.shared.noteFrame(sourceKey: sourceKey)
        notifyPlaceholderSignal(sourceKey: sourceKey)
        LivePixelHub.shared.publish(endpoint: lane.endpoint, sourceID: sourceKey, buffer: pixel)
        lane.lastFrame = frame
        lane.lastPixelBuffer = pixel
        #if canImport(ScreenCaptureKit)
        if backend == "screenCaptureKit" {
            lane.lastScreenFrameAt = Date()
            lane.screenCaptureStopped = false
            lane.screenFramesPublished &+= 1
        }
        #endif
        if activeSourceID == source.id || activeSourceID == nil {
            lastPixelBuffer = pixel
            lastFrame = frame
        }
        frameRevision &+= 1
    }

    private func startCamera(_ source: StudioVideoSource, lane: LiveInputLane) {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            lastResult = .denied("Camera permission denied.")
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.startCamera(source, lane: lane)
                    } else {
                        self.lastResult = .denied("Camera permission denied.")
                    }
                }
            }
            return
        default:
            break
        }
        if let existing = lane.session {
            captureSession = existing
            if lane.audioCaptureEnabled {
                restoreCameraAudioPipeline(source: source, lane: lane, session: existing)
            }
            wireCameraCaptureAudio(lane: lane)
            return
        }
        let device = resolveCamera(source)
        if let owner = existingCameraLane(for: device, source: source), owner !== lane {
            lane.session = owner.session
            lane.audioCaptureEnabled = owner.audioCaptureEnabled
            captureSession = owner.session
            wireCameraCaptureAudio(lane: owner)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in
                    self?.startCamera(source, lane: lane)
                }
            }
            return
        default:
            break
        }
        let cameraKey = device?.uniqueID ?? "default"
        if let session = Self.retainedCameraSessions[cameraKey], !session.inputs.isEmpty {
            lane.session = session
            captureSession = session
            bindCameraRelay(source: source, lane: lane, session: session)
            wireCameraCaptureAudio(lane: lane)
            if !session.isRunning {
                CaptureSessionLifetime.start(session)
            }
            return
        }
        let session = Self.retainedCameraSessions[cameraKey] ?? AVCaptureSession()
        if Self.retainedCameraSessions[cameraKey] == nil {
            Self.retainedCameraSessions[cameraKey] = session
            CaptureSessionWatch.watch(session)
        }
        CaptureSessionLifetime.configure {
            session.beginConfiguration()
            var addedCamera = false
            if let device, let input = try? AVCaptureDeviceInput(device: device) {
                for preset in Self.capturePresets(
                    outputWidth: outputWidth,
                    outputHeight: outputHeight,
                    allowAboveOutput: captureAboveOutput
                ) {
                    guard device.supportsSessionPreset(preset), session.canSetSessionPreset(preset) else { continue }
                    session.sessionPreset = preset
                    guard session.canAddInput(input) else { continue }
                    session.addInput(input)
                    addedCamera = true
                    CaptureSessionWatch.note("Camera input added preset=\(preset.rawValue)")
                    break
                }
            }
            if let device, addedCamera == false {
                CaptureSessionWatch.logFailure("Camera input was not added for \(device.localizedName). No supported preset fit the show size.")
            }
            if shouldAddCameraMicrophone(except: lane),
               let audioDevice = companionAudioDevice(for: device),
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                lane.audioCaptureEnabled = true
            } else {
                lane.audioCaptureEnabled = false
            }
            let output = AVCaptureVideoDataOutput()
            LowLatencyIngestPipeline.shared.configure(output)
            let relay = lane.cameraRelay
            let publishKey = ObjectIdentifier(lane)
            relay.onFrame = { [weak self, weak lane] width, height, sample, pixel in
                self?.scheduleLanePublish(key: publishKey) {
                    guard let lane else { return }
                    self?.publishLaneFrame(
                        source: source,
                        lane: lane,
                        width: width,
                        height: height,
                        sample: sample,
                        pixel: pixel,
                        backend: "avfoundation",
                        kind: source.inputSource.kind
                    )
                }
            }
            output.setSampleBufferDelegate(relay, queue: relay.queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            if lane.audioCaptureEnabled {
                let audioOutput = AVCaptureAudioDataOutput()
                audioOutput.setSampleBufferDelegate(relay, queue: relay.queue)
                if session.canAddOutput(audioOutput) {
                    session.addOutput(audioOutput)
                } else {
                    lane.audioCaptureEnabled = false
                }
            }
            session.commitConfiguration()
        }
        wireCameraCaptureAudio(lane: lane)
        lane.session = session
        captureSession = session
        if device != nil {
            CaptureSessionLifetime.start(session)
        }
        #endif
    }

    #if canImport(AVFoundation)
    /// Reattach the sample callback on the process-wide camera session. Does not call `startRunning`.
    private func bindCameraRelay(source: StudioVideoSource, lane: LiveInputLane, session: AVCaptureSession) {
        let relay = lane.cameraRelay
        let publishKey = ObjectIdentifier(lane)
        relay.onFrame = { [weak self, weak lane] width, height, sample, pixel in
            self?.scheduleLanePublish(key: publishKey) {
                guard let lane else { return }
                self?.publishLaneFrame(
                    source: source,
                    lane: lane,
                    width: width,
                    height: height,
                    sample: sample,
                    pixel: pixel,
                    backend: "avfoundation",
                    kind: source.inputSource.kind
                )
            }
        }
        for output in session.outputs {
            if let video = output as? AVCaptureVideoDataOutput {
                video.setSampleBufferDelegate(relay, queue: relay.queue)
            }
            if let audio = output as? AVCaptureAudioDataOutput {
                audio.setSampleBufferDelegate(relay, queue: relay.queue)
                // Only a dedicated mic lane carries mic PCM; a reused camera session stays picture only.
                lane.audioCaptureEnabled = lane.backend == "avfoundation-audio"
            }
        }
    }
    #endif

    /// A Space change or a stopped ScreenCaptureKit stream used to leave the last frame
    /// marked live. Later window and display shares adopted that frame and never opened
    /// a new stream, so the operator only got a snapshot until the app was quit.
    func reviveStalledScreenCaptures() {
        #if canImport(ScreenCaptureKit)
        let now = Date()
        for lane in lanes.values where lane.kind == .screenShare && lane.isLive {
            let stalled: Bool
            if lane.screenCaptureStopped {
                stalled = true
            } else if let last = lane.lastScreenFrameAt {
                stalled = now.timeIntervalSince(last) > 2.5
            } else if lane.stream == nil, let armed = lane.screenCaptureArmedAt {
                stalled = now.timeIntervalSince(armed) > 4
            } else {
                stalled = false
            }
            guard stalled else { continue }
            restartScreenCapture(screenSource(for: lane), force: false)
        }
        #endif
    }

    #if canImport(ScreenCaptureKit)
    private func screenSource(for lane: LiveInputLane) -> StudioVideoSource {
        StudioVideoSource(
            id: lane.sourceID,
            label: lane.deviceName.isEmpty ? "Screen" : lane.deviceName,
            kind: lane.kind,
            endpoint: lane.endpoint
        )
    }

    private func ensureSpaceChangeObserver() {
        guard spaceChangeObserver == nil else { return }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restartScreenCapturesAfterSpaceChange()
            }
        }
    }

    /// Stores the display's Smooth / Light choice and restarts its live capture so the new interval applies.
    func setScreenShareSmoothness(_ value: ScreenShareSmoothness, endpoint: String) {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, ScreenShareSmoothness.current(endpoint: endpoint) != value else { return }
        UserDefaults.standard.set(value.rawValue, forKey: ScreenShareSmoothness.defaultsKey(endpoint))
        var seen = Set<ObjectIdentifier>()
        for lane in lanes.values where lane.kind == .screenShare && lane.isLive && lane.endpoint == endpoint {
            guard seen.insert(ObjectIdentifier(lane)).inserted else { continue }
            restartScreenCapture(screenSource(for: lane), force: true)
        }
    }

    private func restartScreenCapturesAfterSpaceChange() {
        let live = lanes.values.filter { $0.kind == .screenShare && $0.isLive }
        for lane in live {
            lane.screenCaptureStopped = true
            lane.screenCaptureAcceptStops = false
        }
        for lane in live {
            restartScreenCapture(screenSource(for: lane), force: true)
        }
    }

    private func restartScreenCapture(_ source: StudioVideoSource, force: Bool) {
        guard source.kind == .screenShare else { return }
        let key = Self.laneKey(for: source)
        if !force, let last = lastScreenRestartAt[key], Date().timeIntervalSince(last) < 2 {
            return
        }
        lastScreenRestartAt[key] = Date()
        guard let lane = liveLane(for: source) ?? lane(for: source), lane.isLive else {
            _ = start(source)
            return
        }
        lane.screenCaptureStopped = true
        lane.screenCaptureAcceptStops = false
        startScreen(source, lane: lane)
    }

    private func retireScreenStream(_ stream: SCStream?) {
        guard let stream else { return }
        if screenStream === stream {
            screenStream = nil
        }
        if !screenStreamsPendingStop.contains(where: { $0 === stream }) {
            screenStreamsPendingStop.append(stream)
        }
    }

    /// Stop streams that have already died so a new `SCStream` is not started beside a zombie.
    /// A zombie left running makes the next capture deliver one frame and then stall.
    private func retireStaleScreenStreams(except lane: LiveInputLane) {
        let now = Date()
        for other in lanes.values where other !== lane {
            guard let stream = other.stream else { continue }
            let stale: Bool
            if other.screenCaptureStopped {
                stale = true
            } else if let last = other.lastScreenFrameAt {
                stale = now.timeIntervalSince(last) > 2.5
            } else {
                stale = true
            }
            guard stale else { continue }
            retireScreenStream(stream)
            other.stream = nil
            other.screenCaptureStopped = true
            other.screenCaptureAcceptStops = false
        }
    }

    private func noteScreenCaptureStopped(source: StudioVideoSource, lane: LiveInputLane, generation: UInt) {
        guard lane.screenCaptureGeneration == generation, lane.screenCaptureAcceptStops, lane.isLive else { return }
        lane.screenCaptureAcceptStops = false
        lane.screenCaptureStopped = true
        restartScreenCapture(source, force: false)
    }
    #endif

    private func startScreen(_ source: StudioVideoSource, lane: LiveInputLane) {
        #if canImport(ScreenCaptureKit)
        ensureSpaceChangeObserver()
        let endpoint = (source.endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.hasPrefix("sck://window/") {
            ProShowStreamCapturePrivacy.applyOperatorDeskConcealment(active: true)
        }
        let generation = lane.screenCaptureGeneration &+ 1
        lane.screenCaptureGeneration = generation
        lane.screenCaptureStopped = false
        lane.screenCaptureAcceptStops = false
        lane.screenCaptureArmedAt = Date()
        lane.lastScreenFrameAt = Date()
        retireScreenStream(lane.stream)
        lane.stream = nil
        var preset = screenCapturePreset()
        // Smooth / Light per display: only the frame interval changes.
        preset.fps = min(preset.fps, ScreenShareSmoothness.current(endpoint: source.endpoint).fps)
        lane.screenCaptureFPS = preset.fps
        let index = Self.displayIndex(from: source.endpoint)
        let relay = lane.screenRelay
        let publishKey = ObjectIdentifier(lane)
        relay.onFrame = { [weak self, weak lane] width, height, sample, pixel in
            self?.scheduleLanePublish(key: publishKey) {
                guard let lane else { return }
                guard lane.screenCaptureGeneration == generation, !lane.screenCaptureStopped else { return }
                self?.publishLaneFrame(
                    source: source,
                    lane: lane,
                    width: width,
                    height: height,
                    sample: sample,
                    pixel: pixel,
                    backend: "screenCaptureKit",
                    kind: .screenShare
                )
            }
        }
        let idleKey = ObjectIdentifier(relay)
        relay.onIdle = { [weak self, weak lane] in
            self?.scheduleLanePublish(key: idleKey) {
                guard let lane, lane.screenCaptureGeneration == generation, !lane.screenCaptureStopped else { return }
                // ScreenCaptureKit sends idle frames while the screen is unchanged: the stream is healthy.
                lane.lastScreenFrameAt = Date()
                lane.screenIdleFrames &+= 1
                let sourceKey = source.id.uuidString
                InputFailoverEngine.shared.noteFrame(sourceKey: sourceKey)
                self?.notifyPlaceholderSignal(sourceKey: sourceKey)
            }
        }
        relay.onStopped = { [weak self, weak lane] stopped in
            Task { @MainActor in
                guard let lane, lane.stream === stopped else { return }
                self?.noteScreenCaptureStopped(source: source, lane: lane, generation: generation)
            }
        }
        relay.onAudioPeak = { [weak self] peak in
            self?.onCaptureAudioPeak?(.desktop, peak)
        }
        let sourceKey = lane.endpoint
        relay.onAudioPCM = { [weak self] samples, rate in
            self?.onCaptureAudio?(.desktop, samples, rate, sourceKey)
        }
        let previous = screenCaptureChain
        screenCaptureChain = Task { @MainActor in
            _ = await previous?.value
            guard lane.screenCaptureGeneration == generation, lane.isLive else { return }
            self.retireScreenStream(lane.stream)
            lane.stream = nil
            self.retireStaleScreenStreams(except: lane)
            if let screenStream = self.screenStream, !self.lanes.values.contains(where: { $0.stream === screenStream }) {
                self.retireScreenStream(screenStream)
            }
            let pending = self.screenStreamsPendingStop
            self.screenStreamsPendingStop = []
            for stream in pending {
                try? await stream.stopCapture()
            }
            guard lane.screenCaptureGeneration == generation, lane.isLive else { return }
            let endpoint = (source.endpoint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hidesDesk = !endpoint.hasPrefix("sck://window/")
            if hidesDesk {
                ProShowStreamCapturePrivacy.beginOperatorWindowFilterSnapshot()
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if hidesDesk {
                    ProShowStreamCapturePrivacy.endOperatorWindowFilterSnapshot()
                }
                guard lane.screenCaptureGeneration == generation, lane.isLive else { return }
                guard let filter = ScreenCaptureRouting.filter(endpoint: source.endpoint, content: content)
                    ?? ScreenCaptureRouting.filter(endpoint: "sck://display/\(index)", content: content)
                else {
                    self.lastResult = .denied("Screen Recording permission is required.")
                    lane.screenCaptureStopped = true
                    return
                }
                let configuration = SCStreamConfiguration()
                configuration.width = preset.width
                configuration.height = preset.height
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(preset.fps))
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = true
                configuration.queueDepth = 2
                if #available(macOS 13.0, *) {
                    configuration.capturesAudio = preset.capturesAudio
                    // Device audio must not recapture ProShow's own monitor of the assigned mic.
                    configuration.excludesCurrentProcessAudio = true
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: relay)
                try stream.addStreamOutput(relay, type: .screen, sampleHandlerQueue: relay.queue)
                if #available(macOS 13.0, *) {
                    try stream.addStreamOutput(relay, type: SCStreamOutputType.audio, sampleHandlerQueue: relay.queue)
                }
                if hidesDesk {
                    ProShowStreamCapturePrivacy.applyOperatorDeskConcealment(active: true)
                }
                try await stream.startCapture()
                guard lane.screenCaptureGeneration == generation, lane.isLive else {
                    self.retireScreenStream(stream)
                    let orphan = self.screenStreamsPendingStop
                    self.screenStreamsPendingStop = []
                    for item in orphan {
                        try? await item.stopCapture()
                    }
                    return
                }
                lane.stream = stream
                lane.lastScreenFrameAt = Date()
                lane.screenCaptureStopped = false
                lane.screenCaptureAcceptStops = true
                self.screenStream = stream
            } catch {
                if hidesDesk {
                    ProShowStreamCapturePrivacy.endOperatorWindowFilterSnapshot()
                }
                lane.screenCaptureStopped = true
                self.lastResult = .denied("Screen Recording permission is required.")
            }
        }
        #endif
    }

    #if canImport(AVFoundation)
    private func existingCameraLane(for device: AVCaptureDevice?, source: StudioVideoSource) -> LiveInputLane? {
        if let device {
            if let owner = lanes.values.first(where: { lane in
                guard let session = lane.session else { return false }
                return session.inputs.contains { input in
                    guard let existing = (input as? AVCaptureDeviceInput)?.device else { return false }
                    // Match by uniqueID only: name matching made two cameras share one session.
                    return existing.uniqueID == device.uniqueID
                }
            }) {
                return owner
            }
        }
        return liveLane(for: source)
    }

    private func resolveCamera(_ source: StudioVideoSource) -> AVCaptureDevice? {
        guard let endpoint = source.endpoint, endpoint.hasPrefix("avf://") else { return nil }
        let uniqueID = String(endpoint.dropFirst("avf://".count))
        guard !uniqueID.isEmpty,
              let match = AVCaptureDevice(uniqueID: uniqueID),
              !SystemVideoDeviceCatalog.isUnsafeCaptureDevice(name: match.localizedName, uniqueID: match.uniqueID)
        else {
            return nil
        }
        return match
    }

    /// Opens an audio-only AVFoundation capture for USB / Bluetooth / Continuity / built-in mics.
    func startDedicatedMicrophone(endpoint: String, label: String = "Microphone") {
        #if canImport(AVFoundation)
        guard hardwareEnabled else { return }
        let key = Self.dedicatedAudioLaneKey(endpoint: endpoint)
        if let lane = lanes[key], lane.session != nil {
            lane.audioCaptureEnabled = true
            ProgramStreamAudioGates.setHardwareCaptureOpen(.microphone, open: true)
            wireCameraCaptureAudio(lane: lane)
            #if canImport(AVFoundation)
            if let session = lane.session, !sessionHasAudioOutput(session) {
                restoreDedicatedMicOutputs(lane: lane, session: session, endpoint: endpoint)
            }
            #endif
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            lastResult = .denied("Microphone permission denied.")
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard granted else {
                        self?.lastResult = .denied("Microphone permission denied.")
                        return
                    }
                    self?.startDedicatedMicrophone(endpoint: endpoint, label: label)
                }
            }
            return
        default:
            break
        }
        let device = resolveAudioCaptureDevice(endpoint: endpoint)
        guard let device else {
            lastResult = .denied("Microphone not available.")
            return
        }
        let lane = lanes[key] ?? LiveInputLane(
            sourceID: HardwareSourceIdentity.uuid(for: endpoint),
            endpoint: key,
            kind: .camera,
            backend: "avfoundation-audio"
        )
        lane.sourceID = HardwareSourceIdentity.uuid(for: endpoint)
        lane.deviceName = label.isEmpty ? device.localizedName : label
        lane.isLive = true
        lane.audioCaptureEnabled = true
        lanes[key] = lane
        hardwareStartCount += 1

        // One mic session for the process. Point it at this device and this lane every time:
        // reusing it as-is kept the previous device (switching to the phone mic still heard the
        // Mac mic) and, after a stop removed its output, delivered nothing at all.
        let session = Self.retainedMicSession ?? AVCaptureSession()
        if Self.retainedMicSession == nil {
            Self.retainedMicSession = session
        }
        detachMicLanes(sharing: session, keeping: key)
        configureMicSession(session, device: device, lane: lane)
        wireCameraCaptureAudio(lane: lane)
        lane.session = session
        captureSession = session
        if !session.isRunning {
            CaptureSessionLifetime.start(session)
        }
        #endif
    }

    #if canImport(AVFoundation)
    /// Mic handover: the lane that owned the shared mic session stops feeding the mic role.
    private func detachMicLanes(sharing session: AVCaptureSession, keeping key: String) {
        for (otherKey, other) in lanes where otherKey != key && other.session === session {
            CaptureAudioSources.release(role: .microphone)
            other.cameraRelay.onAudioPCM = nil
            other.cameraRelay.onAudioPeak = nil
            other.audioCaptureEnabled = false
            other.session = nil
            other.isLive = false
            lanes.removeValue(forKey: otherKey)
        }
    }

    /// Exactly one input (this device) and one audio output (this lane's relay).
    private func configureMicSession(_ session: AVCaptureSession, device: AVCaptureDevice, lane: LiveInputLane) {
        let relay = lane.cameraRelay
        var outputOK = true
        CaptureSessionLifetime.configure {
            session.beginConfiguration()
            for input in session.inputs {
                guard let deviceInput = input as? AVCaptureDeviceInput else { continue }
                if deviceInput.device.uniqueID != device.uniqueID {
                    session.removeInput(deviceInput)
                }
            }
            let hasInput = session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID }
            if !hasInput, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            let outputs = session.outputs.compactMap { $0 as? AVCaptureAudioDataOutput }
            for extra in outputs.dropFirst() {
                extra.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(extra)
            }
            if let audio = outputs.first {
                audio.setSampleBufferDelegate(relay, queue: relay.queue)
            } else {
                let audioOutput = AVCaptureAudioDataOutput()
                audioOutput.setSampleBufferDelegate(relay, queue: relay.queue)
                if session.canAddOutput(audioOutput) {
                    session.addOutput(audioOutput)
                } else {
                    outputOK = false
                }
            }
            session.commitConfiguration()
        }
        if !outputOK { lane.audioCaptureEnabled = false }
    }

    /// Mic that belongs to a camera: the built-in camera uses the built-in mic, a Continuity
    /// camera uses the phone's mic. Falls back to the system default input. Cached for 5 s
    /// because the program tick asks on every frame.
    func companionMicrophone(cameraEndpoint: String) -> CameraMicCompanion? {
        let now = Date()
        if let hit = Self.companionCache[cameraEndpoint], now.timeIntervalSince(hit.at) < 5 {
            return hit.value
        }
        var value: CameraMicCompanion?
        if AVCaptureDevice.authorizationStatus(for: .audio) != .denied,
           AVCaptureDevice.authorizationStatus(for: .audio) != .restricted {
            let uniqueID = cameraEndpoint.hasPrefix("avf://") ? String(cameraEndpoint.dropFirst("avf://".count)) : ""
            let camera = uniqueID.isEmpty ? nil : AVCaptureDevice(uniqueID: uniqueID)
            var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
            if #available(macOS 14.0, iOS 17.0, *) {
                types.append(.microphone)
            }
            let audioDevices = PersistentCaptureDiscovery.devices(types: types, mediaType: .audio)
            let paired = camera.flatMap { cam in
                audioDevices.first { CaptureDevicePairing.pairsCamera(videoName: cam.localizedName, audioName: $0.localizedName) }
            }
            if let mic = paired ?? AVCaptureDevice.default(for: .audio) ?? audioDevices.first {
                value = CameraMicCompanion(endpoint: "avf://\(mic.uniqueID)", name: mic.localizedName, paired: paired != nil)
            }
        }
        Self.companionCache[cameraEndpoint] = (now, value)
        return value
    }

    private static var companionCache: [String: (at: Date, value: CameraMicCompanion?)] = [:]
    #endif

    private func resolveAudioCaptureDevice(endpoint: String) -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, iOS 17.0, *) {
            types.append(.microphone)
        }
        let audioDevices = PersistentCaptureDiscovery.devices(types: types, mediaType: .audio)
        if endpoint.hasPrefix("avf://") {
            let uniqueID = String(endpoint.dropFirst("avf://".count))
            if let match = AVCaptureDevice(uniqueID: uniqueID) {
                return match
            }
            if let match = audioDevices.first(where: { $0.uniqueID == uniqueID }) {
                return match
            }
        }
        return AVCaptureDevice.default(for: .audio) ?? audioDevices.first
    }

    /// A camera is picture only (ProgramAudioGatePolicy). The mic reaches program only through an
    /// explicit mic shot (dedicated mic lane or the system input tap). A camera that also opened its
    /// companion mic put a second, slightly delayed copy of the same voice into the mic lane, and
    /// with one capture session per camera (95eb06d) the iPhone's Continuity mic could join as well.
    private func shouldAddCameraMicrophone(except lane: LiveInputLane) -> Bool {
        _ = lane
        return false
    }

    private func companionAudioDevice(for videoDevice: AVCaptureDevice?) -> AVCaptureDevice? {
        var types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone]
        if #available(macOS 14.0, iOS 17.0, *) {
            types.append(.microphone)
        }
        let audioDevices = PersistentCaptureDiscovery.devices(types: types, mediaType: .audio)
        return CaptureDevicePairing.companionAudio(for: videoDevice, among: audioDevices)
    }

    private func wireCameraCaptureAudio(lane: LiveInputLane) {
        let owner = audioRelayOwner(for: lane)
        guard lane.audioCaptureEnabled else {
            owner.cameraRelay.onAudioPCM = nil
            owner.cameraRelay.onAudioPeak = nil
            return
        }
        let sourceKey = owner.endpoint
        owner.cameraRelay.onAudioPCM = { [weak self] samples, rate in
            self?.onCaptureAudio?(.microphone, samples, rate, sourceKey)
        }
        owner.cameraRelay.onAudioPeak = { [weak self] db in
            self?.onCaptureAudioPeak?(.microphone, db)
        }
    }

    private func sessionHasAudioOutput(_ session: AVCaptureSession) -> Bool {
        session.outputs.contains { $0 is AVCaptureAudioDataOutput }
    }

    private func restoreCameraAudioPipeline(
        source: StudioVideoSource,
        lane: LiveInputLane,
        session: AVCaptureSession
    ) {
        guard !sessionHasAudioOutput(session) else { return }
        let device = resolveCamera(source)
        CaptureSessionLifetime.configure {
            session.beginConfiguration()
            if let audioDevice = companionAudioDevice(for: device) {
                let hasAudioInput = session.inputs.contains { input in
                    guard let deviceInput = input as? AVCaptureDeviceInput else { return false }
                    return deviceInput.device.hasMediaType(.audio)
                }
                if !hasAudioInput, let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
                   session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                }
            }
            let relay = lane.cameraRelay
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(relay, queue: relay.queue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
                lane.audioCaptureEnabled = true
            }
            session.commitConfiguration()
        }
    }

    private func restoreDedicatedMicOutputs(lane: LiveInputLane, session: AVCaptureSession, endpoint: String) {
        guard let device = resolveAudioCaptureDevice(endpoint: endpoint) else { return }
        CaptureSessionLifetime.configure {
            session.beginConfiguration()
            let hasInput = session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == device.uniqueID }
            if !hasInput, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
            let relay = lane.cameraRelay
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(relay, queue: relay.queue)
            if session.canAddOutput(audioOutput) {
                session.addOutput(audioOutput)
            }
            session.commitConfiguration()
        }
        if !session.isRunning {
            CaptureSessionLifetime.start(session)
        }
    }

    #endif

    private static func displayIndex(from endpoint: String?) -> Int {
        guard let endpoint, endpoint.hasPrefix("sck://display/") else { return 0 }
        return Int(endpoint.replacingOccurrences(of: "sck://display/", with: "")) ?? 0
    }
}

#if canImport(AVFoundation)
/// Copies a camera frame into an IOSurface BGRA pool with VideoToolbox, then returns so the capture buffer can be released.
enum CameraFrameCopy {
    private static let lock = NSLock()
    private static var pool: CVPixelBufferPool?
    private static var poolWidth = 0
    private static var poolHeight = 0
    private static var poolFormat: OSType = 0
    #if canImport(VideoToolbox)
    private static var transfer: VTPixelTransferSession?
    #endif

    static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        guard width > 0, height > 0, let dest = take(width: width, height: height, format: format) else { return nil }
        #if canImport(VideoToolbox)
        // Session create/use/invalidate are serialized: `reset()` could invalidate it mid-transfer.
        lock.lock()
        defer { lock.unlock() }
        guard let session = transferSession(),
              VTPixelTransferSessionTransferImage(session, from: source, to: dest) == noErr
        else { return nil }
        return dest
        #else
        return nil
        #endif
    }

    static func reset() {
        lock.lock()
        pool = nil
        poolWidth = 0
        poolHeight = 0
        poolFormat = 0
        #if canImport(VideoToolbox)
        if let transfer {
            VTPixelTransferSessionInvalidate(transfer)
        }
        transfer = nil
        #endif
        lock.unlock()
    }

    #if canImport(VideoToolbox)
    private static func transferSession() -> VTPixelTransferSession? {
        if let transfer { return transfer }
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
              let session
        else { return nil }
        transfer = session
        return session
    }
    #endif

    private static func take(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        lock.lock()
        if pool == nil || poolWidth != width || poolHeight != height || poolFormat != format {
            pool = makePool(width: width, height: height, format: format)
            poolWidth = width
            poolHeight = height
            poolFormat = format
        }
        let active = pool
        lock.unlock()
        guard let active else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, active, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private static func makePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let pixel: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(format),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3,
            kCVPixelBufferPoolAllocationThresholdKey: 3,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, pixel as CFDictionary, &pool) == kCVReturnSuccess else {
            return nil
        }
        return pool
    }
}

final class CameraSampleRelay: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = ProShowQueues.videoIngestQueue
    var onFrame: ((Int, Int, RGBA8, CVPixelBuffer) -> Void)?
    var onAudioPCM: (([Float], Double) -> Void)?
    var onAudioPeak: ((Double) -> Void)?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output is AVCaptureAudioDataOutput {
            guard onAudioPCM != nil else { return }
            guard let decoded = VideoSampleDecoder.monoPCM(from: sampleBuffer) else {
                StreamAudioPipelineDiagnostics.recordMonoPCMDrop(role: .microphone)
                return
            }
            onAudioPeak?(VideoSampleDecoder.peakDb(fromMono: decoded.samples))
            onAudioPCM?(decoded.samples, decoded.sampleRate)
            return
        }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let owned = CameraFrameCopy.copy(pixel) else { return }
        let width = CVPixelBufferGetWidth(owned)
        let height = CVPixelBufferGetHeight(owned)
        onFrame?(width, height, VideoSampleDecoder.sample(from: owned), owned)
    }
}
#endif

#if canImport(ScreenCaptureKit)
final class ScreenSampleRelay: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = ProShowQueues.videoIngestQueue
    var onFrame: ((Int, Int, RGBA8, CVPixelBuffer) -> Void)?
    var onAudioPeak: ((Double) -> Void)?
    var onAudioPCM: (([Float], Double) -> Void)?
    var onStopped: ((SCStream) -> Void)?
    var onIdle: (() -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStopped?(stream)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .screen {
            if ScreenCaptureRouting.isCompleteFrame(sampleBuffer),
               let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) {
                onFrame?(CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), VideoSampleDecoder.sample(from: pixel), pixel)
            } else if ScreenCaptureRouting.isIdleFrame(sampleBuffer) {
                onIdle?()
            }
        }
        if type == .audio {
            onAudioPeak?(VideoSampleDecoder.audioPeak(from: sampleBuffer))
            guard onAudioPCM != nil else { return }
            if let decoded = VideoSampleDecoder.monoPCM(from: sampleBuffer) {
                onAudioPCM?(decoded.samples, decoded.sampleRate)
            } else {
                StreamAudioPipelineDiagnostics.recordMonoPCMDrop(role: .desktop)
            }
        }
    }
}
#endif

#if canImport(AVFoundation)
/// The mic a camera shot uses for its audio (see `companionMicrophone(cameraEndpoint:)`).
struct CameraMicCompanion: Hashable, Sendable {
    var endpoint: String
    var name: String
    /// False when no mic matched the camera and the system default input is used.
    var paired: Bool
}

enum CaptureDevicePairing {
    static func pairsCamera(videoName: String, audioName: String) -> Bool {
        let video = normalized(videoName)
        let audio = normalized(audioName)
        if video == audio { return true }
        if video.replacingOccurrences(of: " camera", with: " microphone") == audio { return true }
        if audio.replacingOccurrences(of: " microphone", with: " camera") == video { return true }
        let videoStem = video.replacingOccurrences(of: " camera", with: "")
        if audio.contains("microphone") && (audio.contains(videoStem) || videoStem.contains(audioStem(from: audio))) {
            return true
        }
        if (video.contains("iphone") || video.contains("ipad"))
            && (audio.contains("iphone") || audio.contains("ipad")) {
            return sharedHardwareFamily(video, audio)
        }
        if video.contains("continuity") || audio.contains("continuity") {
            return sharedHardwareFamily(video, audio)
        }
        if audio.contains("bluetooth") || video.contains("bluetooth") {
            return sharedHardwareFamily(video, audio)
        }
        if video.contains("external") || audio.contains("usb") || audio.contains("external") {
            return videoStem.count > 3 && audio.contains(String(videoStem.prefix(min(8, videoStem.count))))
        }
        return false
    }

    static func companionAudio(for videoDevice: AVCaptureDevice?, among audioDevices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let videoDevice {
            let cameraName = videoDevice.localizedName
            if let match = audioDevices.first(where: { pairsCamera(videoName: cameraName, audioName: $0.localizedName) }) {
                return match
            }
        }
        return AVCaptureDevice.default(for: .audio) ?? audioDevices.first
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func audioStem(from audioName: String) -> String {
        audioName
            .replacingOccurrences(of: " microphone", with: "")
            .replacingOccurrences(of: " mic", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sharedHardwareFamily(_ video: String, _ audio: String) -> Bool {
        let tokens = ["iphone", "ipad", "continuity", "airpods", "beats", "bluetooth", "macbook"]
        return tokens.contains { video.contains($0) && audio.contains($0) }
    }
}
#endif

enum VideoSampleDecoder {
    static func sample(from pixel: CVPixelBuffer) -> RGBA8 {
        guard CVPixelBufferGetBytesPerRow(pixel) >= 4, CVPixelBufferGetDataSize(pixel) >= 4 else {
            return RGBA8(r: 0, g: 0, b: 0, a: 1)
        }
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else {
            return RGBA8(r: 0, g: 0, b: 0, a: 1)
        }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        return RGBA8(
            r: Double(bytes[2]) / 255,
            g: Double(bytes[1]) / 255,
            b: Double(bytes[0]) / 255,
            a: 1
        )
    }

    static func monoPCM(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        #if canImport(AVFoundation)
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        guard basic.pointee.mSampleRate > 0,
              basic.pointee.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: basic),
              format.sampleRate > 0,
              format.channelCount > 0
        else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        buffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        ) == noErr else { return nil }
        guard let channels = buffer.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard frames > 0, channelCount > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channelCount {
            for index in 0..<frames {
                mono[index] += channels[channel][index]
            }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for index in 0..<frames { mono[index] *= scale }
        }
        return (mono, Double(basic.pointee.mSampleRate))
        #else
        return nil
        #endif
    }

    static func peakDb(fromMono samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        if peak <= 0.0001 { return -120 }
        return Double(20 * log10(peak))
    }

    static func audioPeak(from sampleBuffer: CMSampleBuffer) -> Double {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return -120 }
        var length = 0
        var data: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &data) == noErr,
              let data, length > 0
        else { return -120 }
        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return -120 }
        return data.withMemoryRebound(to: Float.self, capacity: count) { samples in
            var peak: Float = 0
            for index in 0..<count {
                peak = max(peak, abs(samples[index]))
            }
            if peak <= 0.0001 { return -120 }
            return Double(20 * log10(peak))
        }
    }
}
