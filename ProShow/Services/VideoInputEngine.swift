import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

/// AVFoundation, Continuity Camera, ScreenCaptureKit, NDI, and WebRTC input contracts.
@MainActor
@Observable
final class VideoInputEngine {
    var sources: [StudioVideoSource] = []
    var activePrimaryID: UUID?
    var activePIPID: UUID?
    var lastResult: VideoInputRuntime.Result?
    let ingest = VideoIngestEngine()

    var hardwareEnabled: Bool {
        get { ingest.hardwareEnabled }
        set { ingest.hardwareEnabled = newValue }
    }

    var activeHardwareMicrophoneCapture: Bool { ingest.activeHardwareMicrophoneCapture }

    func startDedicatedMicrophone(endpoint: String, label: String) {
        ingest.startDedicatedMicrophone(endpoint: endpoint, label: label)
    }

    func refreshDisplayScreenCaptureExclusions() {
        ingest.refreshDisplayScreenCaptureExclusions(sources: sources)
    }

    func applyLiveStreamScreenCaptureContract(width: Int, height: Int, fps: Int) {
        ingest.applyLiveStreamScreenCaptureContract(
            width: width,
            height: height,
            fps: fps,
            sources: sources
        )
    }

    func clearLiveStreamScreenCaptureContract() {
        ingest.clearLiveStreamScreenCaptureContract()
    }

    func rearmLiveCapture(for input: VideoInputSource) {
        if let studio = source(id: input.id) {
            ingest.rearmLiveCapture(for: studio)
            return
        }
        ingest.rearmLiveCapture(
            for: StudioVideoSource(
                id: input.id,
                label: input.label,
                kind: StudioVideoKind(videoInput: input.kind),
                endpoint: input.endpoint
            )
        )
    }

    var lastFrame: VideoIngestFrame? { ingest.lastFrame }
    var frameRevision: UInt64 { ingest.frameRevision }
    private(set) var runningIDs: Set<UUID> = []
    private var sourceAliases: [UUID: UUID] = [:]

    #if canImport(CoreVideo)
    var lastPixelBuffer: CVPixelBuffer? { ingest.lastPixelBuffer }
    #endif

    #if canImport(AVFoundation)
    var captureSession: AVCaptureSession? { ingest.captureSession }
    #endif

    func isRunning(_ source: StudioVideoSource) -> Bool {
        ingest.isRunning(source)
    }

    func isRunning(endpoint: String?, sourceID: String?) -> Bool {
        if ingest.isRunning(endpoint: endpoint, sourceID: sourceID) { return true }
        if let sourceID, let id = UUID(uuidString: sourceID), runningIDs.contains(id) { return true }
        if let endpoint, let match = sources.first(where: { $0.endpoint == endpoint }), runningIDs.contains(match.id) {
            return true
        }
        return false
    }

    func hasLiveCamera(endpoint: String?, sourceID: String?, name: String?) -> Bool {
        if isRunning(endpoint: endpoint, sourceID: sourceID) { return true }
        guard let name, !name.isEmpty else { return false }
        return sources.contains { source in
            (source.kind == .camera || source.kind == .continuity)
                && CameraIdentity.isSameCamera(
                    endpointA: source.endpoint,
                    nameA: source.label,
                    endpointB: endpoint,
                    nameB: name
                )
                && isRunning(source)
        }
    }

    func pixelBuffer(matching endpoint: String?, sourceID: String?, kind: StudioVideoKind? = nil) -> CVPixelBuffer? {
        ingest.pixelBuffer(endpoint: endpoint, sourceID: sourceID, kind: kind)
    }

    func resolvedInputSource(for input: VideoInputSource) -> VideoInputSource {
        source(id: input.id)?.inputSource ?? input
    }

    func pixelBuffer(for input: VideoInputSource) -> CVPixelBuffer? {
        let live = resolvedInputSource(for: input)
        let kind = StudioVideoKind(videoInput: live.kind)
        return pixelBuffer(matching: live.endpoint, sourceID: live.id.uuidString, kind: kind)
    }

    func frame(matching endpoint: String?, sourceID: String?) -> VideoIngestFrame? {
        ingest.frame(endpoint: endpoint, sourceID: sourceID)
    }

    func frame(for input: VideoInputSource) -> VideoIngestFrame? {
        let live = resolvedInputSource(for: input)
        return frame(matching: live.endpoint, sourceID: live.id.uuidString)
            ?? ingest.frame(endpoint: nil, sourceID: live.id.uuidString)
    }

    func frameStamp(matching endpoint: String?, sourceID: String?) -> TimeInterval? {
        ingest.frame(endpoint: endpoint, sourceID: sourceID)?.timestamp
    }

    #if canImport(AVFoundation)
    func captureSession(matching endpoint: String?, sourceID: String?) -> AVCaptureSession? {
        ingest.captureSession(endpoint: endpoint, sourceID: sourceID)
    }
    #endif

    func install(_ sources: [StudioVideoSource]) {
        sourceAliases.removeAll()
        self.sources = []
        for source in sources {
            upsert(source)
        }
    }

    func source(id: UUID) -> StudioVideoSource? {
        if let found = sources.first(where: { $0.id == id }) { return found }
        if let alias = sourceAliases[id] {
            return sources.first(where: { $0.id == alias })
        }
        return nil
    }

    /// Cameras, displays, and live NDI that are attached right now — not seed or shot history.
    var attachedSources: [StudioVideoSource] {
        uniqueDevices(sources.filter { !$0.isHardwarePlaceholder })
    }

    func register(_ source: StudioVideoSource) {
        upsert(source)
    }

    func refreshDevices() {
        reconcile(with: ingest.discoverPresentHardware(scanCameras: true), includeNDI: hardwareEnabled)
    }

    func reconcile(with present: [StudioVideoSource], includeNDI: Bool = false) {
        var live = uniqueDevices(present.filter { !$0.isHardwarePlaceholder })
        if includeNDI, hardwareEnabled, NDIRuntime.isAvailable {
            NDIRuntime.hardwareEnabled = true
            for found in NDIRuntime.findSources() {
                let endpoint = found.url.isEmpty ? "ndi://\(found.name)" : found.url
                live.append(
                    StudioVideoSource(
                        id: HardwareSourceIdentity.uuid(for: endpoint),
                        label: found.name,
                        kind: .ndi,
                        endpoint: endpoint
                    )
                )
            }
        }
        for source in live {
            upsert(source)
        }
        sources.removeAll { source in
            shouldDrop(source, present: live)
        }
        let remaining = Set(sources.map(\.id))
        sourceAliases = sourceAliases.filter { remaining.contains($0.value) }
    }

    @discardableResult
    private func upsert(_ source: StudioVideoSource) -> UUID {
        if let index = sources.firstIndex(where: { StudioDeviceIdentity.isSame($0, source) }) {
            rememberAlias(source.id, stored: sources[index].id)
            merge(source, into: index)
            return sources[index].id
        }
        if let index = sources.firstIndex(where: { StudioDeviceIdentity.canAbsorbPlaceholder($0, live: source) }) {
            rememberAlias(source.id, stored: sources[index].id)
            merge(source, into: index)
            return sources[index].id
        }
        sources.append(source)
        return source.id
    }

    private func rememberAlias(_ incoming: UUID, stored: UUID) {
        guard incoming != stored else { return }
        sourceAliases[incoming] = stored
    }

    private func merge(_ incoming: StudioVideoSource, into index: Int) {
        sources[index].label = incoming.label
        sources[index].kind = incoming.kind
        if let endpoint = incoming.endpoint, !endpoint.isEmpty {
            sources[index].endpoint = endpoint
        }
        sources[index].enabled = incoming.enabled
    }

    private func shouldDrop(_ source: StudioVideoSource, present: [StudioVideoSource]) -> Bool {
        if isRunning(source) { return false }
        if source.isHardwarePlaceholder {
            return present.contains { $0.kind == source.kind }
        }
        switch source.kind {
        case .camera, .continuity, .captureCard:
            return !present.contains { StudioDeviceIdentity.isSame($0, source) }
        case .screenShare:
            if source.endpoint?.hasPrefix("sck://window/") == true { return false }
            return !present.contains { StudioDeviceIdentity.isSame($0, source) }
        case .ndi:
            return !present.contains { StudioDeviceIdentity.isSame($0, source) }
        case .webrtc, .rtsp:
            return false
        }
    }

    private func uniqueDevices(_ incoming: [StudioVideoSource]) -> [StudioVideoSource] {
        var unique: [StudioVideoSource] = []
        for source in incoming {
            if !unique.contains(where: { StudioDeviceIdentity.isSame($0, source) }) {
                unique.append(source)
            }
        }
        return unique
    }

    @discardableResult
    func activatePrimary(_ id: UUID) -> VideoInputRuntime.Result {
        guard let source = source(id: id) else {
            lastResult = .denied("Unknown video source.")
            return lastResult!
        }
        let result = ingest.start(source, pip: false)
        lastResult = result
        if result == .started {
            activePrimaryID = id
            runningIDs.insert(id)
        }
        return result
    }

    @discardableResult
    func activatePIP(_ id: UUID) -> VideoInputRuntime.Result {
        guard let source = source(id: id) else {
            lastResult = .denied("Unknown video source.")
            return lastResult!
        }
        let result = ingest.start(source, pip: true)
        lastResult = result
        if result == .started {
            activePIPID = id
        }
        return result
    }

    func clearPIP() {
        activePIPID = nil
        ingest.clearPIPFrame()
    }

    func stop() {
        ingest.stop()
        activePrimaryID = nil
        activePIPID = nil
        runningIDs.removeAll()
        lastResult = ingest.lastResult
    }

    func enumeratePhysicalDevices() -> [StudioVideoSource] {
        ingest.discoverDevices()
    }

    func screenShareFeed(displayName: String = "Main Display") -> StudioVideoSource {
        StudioVideoSource(label: displayName, kind: .screenShare, endpoint: "sck://display/0")
    }

    func ndiFeed(name: String, endpoint: String) -> StudioVideoSource {
        StudioVideoSource(label: name, kind: .ndi, endpoint: endpoint)
    }

    func webrtcGuest(name: String, endpoint: String) -> StudioVideoSource {
        StudioVideoSource(label: name, kind: .webrtc, endpoint: endpoint)
    }
}
