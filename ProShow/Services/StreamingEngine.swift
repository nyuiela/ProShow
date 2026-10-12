import CoreMedia
import Foundation
import Observation
#if canImport(CoreVideo)
import CoreVideo
#endif

/// Capture / RTMP session controller. Encodes via the system pipeline contract;
/// destinations are a single primary feed (direct or cloud relay), not four native encodes.
@MainActor
@Observable
final class StreamingEngine {
    var config = RtmpStreamConfig.default
    var transport: StreamTransport?
    private(set) var state: StreamSessionState = .idle
    private(set) var lastError: String?
    private(set) var startedAt: Date?
    private(set) var encoderSettings: ProgramEncoderSettings?
    private(set) var streamEncoderConfig: StreamEncoderConfig
    /// Ingest cap for the current session. The saved preset stays unchanged.
    private var sessionEncoderConfig: StreamEncoderConfig?
    let hardwareEncoder = HardwareVideoEncoder()
    let telemetry = StreamTelemetryMonitor()
    let streamEngineV2 = StreamEngineV2Session()

    init() {
        let loaded = EncoderPresetStore.load()
        streamEncoderConfig = loaded
        var stream = RtmpStreamConfig.default
        loaded.apply(to: &stream)
        config = stream
        encoderSettings = loaded.programEncoderSettings()
    }

    var isLive: Bool { state == .live }
    var usesCleanFeed = false
    private(set) var lastAllocation: EncoderAllocation?
    private(set) var lastEncodeSource: StreamEncodeSource?
    private(set) var routingPlan: EncodeLanePlan?
    private var routingIngests: [ResolvedIngest] = []
    #if canImport(CoreVideo)
    private var phoneLane: PhoneEncodeLane?
    #endif
    /// Set when the Phone lane fails and Stream is still up.
    private(set) var phoneLaneError: String?

    func applyProjectSettings(_ settings: ProjectSettings) {
        lastAllocation = EncoderBitrateProfile.allocation(for: settings)
        let delivery = CaptureBudget.deliveryResolution(settings.resolution)
        var config = streamEncoderConfig
        config.width = delivery.width
        config.height = delivery.height
        config.frameRate = settings.frameRate.encoderFPS
        if config.width != streamEncoderConfig.width || config.height != streamEncoderConfig.height {
            config.presetName = StreamEncoderPreset.custom.rawValue
        }
        if !config.customBitrateOverrideEnabled {
            let kbps = EncoderBitrateProfile.bitrateKbps(
                width: delivery.width,
                height: delivery.height,
                frameRate: settings.frameRate
            )
            config.targetBitrateBps = kbps * 1000
            config.maxBitrateCeilingBps = Int(Double(config.targetBitrateBps) * 1.2)
        }
        applyStreamEncoderConfig(config)
    }

    func applyStreamEncoderConfig(_ encoderConfig: StreamEncoderConfig) {
        streamEncoderConfig = encoderConfig
        encoderConfig.apply(to: &config)
        encoderSettings = encoderConfig.programEncoderSettings()
        telemetry.bind(config: encoderConfig)
        EncoderPresetStore.save(encoderConfig)
    }

    func setRelayDestinations(_ destinations: [RelayDestination]) {
        config.useCloudRelay = true
        config.relayDestinations = destinations
    }

    /// One VideoToolbox encode. A second destination fans out through the relay, not a second encoder.
    /// When multi-destination routing is on, Stream destinations still share that encode. Phone opens a side lane.
    func configureOutputs(_ ingests: [ResolvedIngest], accounts: [StreamAccount] = []) {
        routingIngests = ingests
        routingPlan = nil
        phoneLaneError = nil
        guard ProShowFeatureFlags.multiDestinationRoutingV1, !accounts.isEmpty else {
            applySharedFanout(ingests)
            return
        }
        let members = ingests.map { ingest in
            let account = accounts.first { $0.id == ingest.accountID }
            let kbps = account?.targetBitrateKbps ?? streamEncoderConfig.targetBitrateKbps
            return LaneMember(
                id: ingest.accountID,
                screen: account?.screenKind ?? .stream,
                scaleMode: account?.scaleMode ?? .fit,
                bitrateBps: max(400_000, kbps * 1000),
                ceilingBps: max(400_000, Int(Double(kbps * 1000) * 1.2))
            )
        }
        let plan = EncodeLaneGrouper.group(members: members, streamPreset: streamEncoderConfig)
        routingPlan = plan
        let streamIDs = Set(plan.lanes.first { $0.role == .stream }?.members.map(\.id) ?? [])
        let streamIngests = ingests.filter { streamIDs.contains($0.accountID) }
        if streamIngests.isEmpty {
            config.useCloudRelay = false
            config.relayDestinations = []
            config.destinationURL = ""
            config.streamKey = ""
        } else {
            applySharedFanout(streamIngests)
        }
    }

    private func streamVideoPolicies(from policies: [PlatformIngestPolicy]) -> [PlatformIngestPolicy] {
        guard ProShowFeatureFlags.multiDestinationRoutingV1, let plan = routingPlan, plan.encodesStream else {
            return policies
        }
        let streamIDs = Set(plan.lanes.first { $0.role == .stream }?.members.map(\.id) ?? [])
        let names = Set(routingIngests.filter { streamIDs.contains($0.accountID) }.compactMap {
            PlatformIngestPolicy.detect(platform: $0.platform, ingestURL: $0.publicURLString)?.name
        })
        let matched = policies.filter { names.contains($0.name) }
        return matched.isEmpty ? policies : matched
    }

    private func applySharedFanout(_ ingests: [ResolvedIngest]) {
        guard let primary = ingests.first else { return }
        config.destinationURL = primary.publicURLString
        config.streamKey = primary.streamKey
        if ingests.count >= 2 {
            setRelayDestinations(ingests.map {
                RelayDestination(id: $0.accountID, name: $0.name, url: $0.publicURLString, streamKey: $0.streamKey)
            })
        } else {
            config.useCloudRelay = false
            config.relayDestinations = []
        }
    }

    @discardableResult
    func start(ingestPolicies: [PlatformIngestPolicy] = []) -> Bool {
        if ProShowFeatureFlags.multiDestinationRoutingV1, let plan = routingPlan, !plan.encodesStream {
            return startPhoneOnly(plan, policies: ingestPolicies)
        }
        let videoPolicies = streamVideoPolicies(from: ingestPolicies)
        var session = streamEncoderConfig.clamped(to: videoPolicies)
        if ProShowFeatureFlags.multiDestinationRoutingV1, routingPlan != nil,
           let audioCap = ingestPolicies.compactMap(\.maxAudioBitrateBps).min(),
           session.audioBitrateBps > audioCap {
            session.audioBitrateBps = audioCap
        }
        sessionEncoderConfig = session == streamEncoderConfig ? nil : session
        session.apply(to: &config)
        encoderSettings = session.programEncoderSettings()
        lastError = nil
        startedAt = nil
        if transport == nil || (transport is RTMPStreamTransport && RTMPClient.fanoutConfigs(from: config).count > 1) {
            transport = RTMPClient.fanoutConfigs(from: config).count > 1
                ? MultiRTMPTransport()
                : RTMPStreamTransport()
        }
        if RTMPClient.fanoutConfigs(from: config).isEmpty {
            state = .failed
            lastError = config.destinationURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Destination URL required for direct RTMP."
                : "YouTube has not issued a stream key yet. Use Start Broadcasting so ProShow can create the live stream."
            return false
        }
        state = .starting
        if encoderSettings == nil {
            encoderSettings = ProgramEncoderSettings.from(config)
        }
        guard let transport else {
            state = .failed
            lastError = "No stream transport."
            return false
        }
        MediaClockAnchor.shared.reset()
        StreamAudioPipelineDiagnostics.resetSession()
        do {
            if let client = transport as? RTMPStreamTransport {
                client.suppressAudioPump = false
            }
            try transport.connect(config: config)
            _ = config.outboundURLs
        } catch {
            MediaClockAnchor.shared.clear()
            state = .failed
            lastError = error.localizedDescription
            return false
        }
        ProgramAACEncoder.prepare(audioBitrateBps: session.audioBitrateBps)
        telemetry.reset()
        telemetry.bind(config: session)
        if transport.isReady {
            markLive(transport)
            return true
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await transport.waitUntilReady(timeoutMs: 12_000)
            if ready {
                self.markLive(transport)
            } else {
                MediaClockAnchor.shared.clear()
                self.state = .failed
                self.startedAt = nil
                self.lastError = "Could not reach the ingest host. The desk is not on air."
            }
        }
        return true
    }

    func noteTransportHealth() {
        guard state == .live, let transport, !transport.isReady else { return }
        lastError = "Ingest dropped the connection. Stop and start broadcasting again."
        startedAt = nil
        state = .failed
    }

    func waitUntilLiveOrFailed(timeoutNanoseconds: UInt64 = 15_000_000_000) async -> Bool {
        let steps = max(1, Int(timeoutNanoseconds / 50_000_000))
        for _ in 0..<steps {
            if state == .live { return true }
            if state == .failed || state == .idle { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if state != .live {
            MediaClockAnchor.shared.clear()
            state = .failed
            startedAt = nil
            lastError = lastError ?? "Ingest timed out. The desk is not on air."
        }
        return state == .live
    }

    private func markLive(_ transport: StreamTransport) {
        prepareHardwareEncoder()
        #if canImport(AVFoundation)
        ProgramRecordingAudioPump.suspendLocalPump()
        #endif
        let telemetry = telemetry
        hardwareEncoder.onEncoded = { packet in
            let kind: RTMPOutboundTag
            switch packet {
            case .sequenceHeader:
                kind = .video(keyframe: true)
            case .accessUnit(_, let keyframe, _):
                kind = .video(keyframe: keyframe)
            }
            transport.send(RTMPClient.videoMessage(packet), kind: kind)
        }
        hardwareEncoder.onEncodedSample = { sample in
            #if canImport(AVFoundation)
            ProgramRecordingAudioBridge.activeProgramRecorder?.appendEncodedVideoSample(sample)
            #endif
        }
        hardwareEncoder.onAccessUnitBytes = { bytes in
            telemetry.recordVideoAccessUnit(byteCount: bytes)
        }
        startedAt = Date()
        state = .live
        #if canImport(CoreVideo)
        let fps = (sessionEncoderConfig ?? streamEncoderConfig).frameRate
        streamEngineV2.start(transport: transport, encoder: hardwareEncoder, fps: fps)
        attachPhoneLaneIfNeeded(pumpsAudio: false)
        #endif
    }

    private var phoneCanvasBoards: [EditorCanvasFrame] = []

    func notePhoneCanvas(_ boards: [EditorCanvasFrame]) {
        phoneCanvasBoards = boards
        pushPhoneCanvas()
    }

    func phoneEncodeBoard() -> EditorCanvasFrame? {
        guard ProShowFeatureFlags.multiDestinationRoutingV1, routingPlan?.phoneLane != nil else { return nil }
        return phoneCanvasBoards.first {
            !$0.isPrimary && CanvasResolution.screenFamily(width: $0.width, height: $0.height) == .phone
        }
    }

    private func pushPhoneCanvas() {
        #if canImport(CoreVideo)
        guard ProShowFeatureFlags.multiDestinationRoutingV1, let lane = routingPlan?.phoneLane else { return }
        phoneLane?.note(
            state: PhoneSlideRouting.state(boards: phoneCanvasBoards),
            boards: phoneCanvasBoards,
            scaleMode: lane.scaleMode
        )
        #endif
    }

    private func startPhoneOnly(_ plan: EncodeLanePlan, policies: [PlatformIngestPolicy]) -> Bool {
        #if canImport(CoreVideo)
        lastError = nil
        phoneLaneError = nil
        startedAt = nil
        MediaClockAnchor.shared.reset()
        StreamAudioPipelineDiagnostics.resetSession()
        let audioCap = policies.compactMap(\.maxAudioBitrateBps).min() ?? streamEncoderConfig.audioBitrateBps
        ProgramAACEncoder.prepare(audioBitrateBps: min(streamEncoderConfig.audioBitrateBps, audioCap))
        guard let lane = plan.phoneLane else {
            MediaClockAnchor.shared.clear()
            state = .failed
            lastError = "No Phone destination."
            return false
        }
        let phone = PhoneEncodeLane()
        guard phone.start(ingests: phoneIngests(in: plan), lane: lane, pumpsAudio: true) else {
            MediaClockAnchor.shared.clear()
            state = .failed
            let name = phoneIngests(in: plan).first?.name ?? "Phone"
            lastError = "\(name) lost."
            return false
        }
        phoneLane = phone
        transport = phone.transport
        pushPhoneCanvas()
        state = .starting
        if phone.transport.isReady {
            startedAt = Date()
            state = .live
            return true
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ready = await phone.transport.waitUntilReady(timeoutMs: 12_000)
            guard self.state == .starting else { return }
            if ready {
                self.startedAt = Date()
                self.state = .live
            } else {
                phone.stop()
                self.phoneLane = nil
                MediaClockAnchor.shared.clear()
                self.state = .failed
                self.startedAt = nil
                self.lastError = "Could not reach the ingest host. The desk is not on air."
            }
        }
        return true
        #else
        state = .failed
        lastError = "Phone encode is unavailable."
        return false
        #endif
    }

    private func phoneIngests(in plan: EncodeLanePlan) -> [ResolvedIngest] {
        let ids = Set(plan.phoneLane?.members.map(\.id) ?? [])
        return routingIngests.filter { ids.contains($0.accountID) }
    }

    @discardableResult
    private func attachPhoneLaneIfNeeded(pumpsAudio: Bool, plan: EncodeLanePlan? = nil) -> Bool {
        #if canImport(CoreVideo)
        let plan = plan ?? routingPlan
        guard let lane = plan?.phoneLane else { return false }
        let ids = Set(lane.members.map(\.id))
        let ingests = routingIngests.filter { ids.contains($0.accountID) }
        let phone = PhoneEncodeLane()
        guard phone.start(ingests: ingests, lane: lane, pumpsAudio: pumpsAudio) else {
            let name = ingests.first?.name ?? "Phone"
            phoneLaneError = "\(name) lost."
            return false
        }
        phoneLane = phone
        pushPhoneCanvas()
        return true
        #else
        return false
        #endif
    }

    func emitCachedCFRHoldFrame(now: Date = Date()) {
        guard state == .live, let buffer = StreamHoldFrameCache.current() else { return }
        telemetry.recordStreamCFRHoldFrame()
        markLastEncodeSource(.cfrHoldDuplicate)
        encodeProgramFrame(pixelBuffer: buffer, now: now, source: .cfrHoldDuplicate)
    }

    nonisolated static func broadcastTimecode(from startedAt: Date?, now: Date = Date()) -> String {
        guard let startedAt else { return "00:00:00" }
        let total = Int(max(0, now.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    func stop() {
        #if canImport(CoreVideo)
        phoneLane?.stop()
        phoneLane = nil
        #endif
        phoneLaneError = nil
        state = .stopping
        #if canImport(CoreVideo)
        StreamVideoCFRPacer.stop()
        #endif
        streamEngineV2.stop()
        hardwareEncoder.flushPendingEncodes()
        hardwareEncoder.onEncoded = nil
        hardwareEncoder.onAccessUnitBytes = nil
        telemetry.reset()
        transport?.disconnect()
        startedAt = nil
        #if canImport(AVFoundation)
        if let recorder = ProgramRecordingAudioBridge.activeProgramRecorder, recorder.isPassthrough {
            state = .idle
            ProgramRecordingAudioPump.start(recorder: recorder)
            return
        }
        #endif
        hardwareEncoder.onEncodedSample = nil
        hardwareEncoder.teardown()
        MediaClockAnchor.shared.clear()
        ProgramAACEncoder.reset()
        restoreUserEncoderConfig()
        state = .idle
    }

    /// Drops the hardware session after passthrough recording ends and the stream is already down.
    func releaseEncoderIfIdle() {
        guard state != .live else { return }
        #if canImport(CoreVideo)
        StreamVideoCFRPacer.stop()
        #endif
        hardwareEncoder.onEncoded = nil
        hardwareEncoder.onEncodedSample = nil
        hardwareEncoder.onAccessUnitBytes = nil
        hardwareEncoder.teardown()
        MediaClockAnchor.shared.clear()
        ProgramAACEncoder.reset()
    }

    func encodeProgramFrame(
        pixelBuffer: CVPixelBuffer?,
        now: Date = Date(),
        source: StreamEncodeSource = .programComposite
    ) {
        guard state == .live, let pixelBuffer else { return }
        lastEncodeSource = source
        if routingPlan?.encodesStream != false {
            if !hardwareEncoder.isPrepared {
                prepareHardwareEncoder()
            }
            hardwareEncoder.encode(pixelBuffer: pixelBuffer, presentationTime: now.timeIntervalSinceReferenceDate)
        }
        #if canImport(CoreVideo)
        phoneLane?.acceptStreamFrame(pixelBuffer)
        #endif
    }

    func markLastEncodeSource(_ source: StreamEncodeSource) {
        lastEncodeSource = source
    }

    /// Encoder is `@unchecked Sendable`; call from `programClockQueue` without hopping to MainActor.
    func submitEncodedFrame(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval, source: StreamEncodeSource) {
        lastEncodeSource = source
        if routingPlan?.encodesStream != false {
            if !hardwareEncoder.isPrepared {
                prepareHardwareEncoder()
            }
            hardwareEncoder.encode(pixelBuffer: pixelBuffer, presentationTime: time)
        }
        #if canImport(CoreVideo)
        phoneLane?.acceptStreamFrame(pixelBuffer)
        #endif
    }

    private func prepareHardwareEncoder() {
        hardwareEncoder.setupStream(config: sessionEncoderConfig ?? streamEncoderConfig)
    }

    private func restoreUserEncoderConfig() {
        sessionEncoderConfig = nil
        streamEncoderConfig.apply(to: &config)
        encoderSettings = streamEncoderConfig.programEncoderSettings()
        telemetry.bind(config: streamEncoderConfig)
    }

    var statusLine: String {
        switch state {
        case .idle:
            return ProShowCopy.Status.off
        case .starting:
            return ProShowCopy.Status.connecting
        case .live:
            let dest = config.useCloudRelay ? "Relay" : "RTMP"
            return ProShowCopy.meta([
                ProShowCopy.Status.live,
                "\(config.width)×\(config.height)",
                "\(config.framerate)",
                dest
            ])
        case .stopping:
            return ProShowCopy.Status.stopping
        case .failed:
            return ProShowCopy.error(for: lastError)
        }
    }
}
