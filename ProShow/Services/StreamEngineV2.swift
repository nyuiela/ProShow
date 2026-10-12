import CoreMedia
import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(os)
import os
#endif

/// Debug switch. Default off. Legacy clocks, AAC bus, and queue wipe stay in place until this is on.
enum ProShowFeatureFlags {
    static let streamEngineV2Key = "proshow.debug.streamEngineV2"
    static let multiDestinationRoutingV1Key = "proshow.multiDestinationRoutingV1"

    /// Live output always uses the master clock, ticker, and mixer.
    static var streamEngineV2Enabled: Bool { true }

    /// Off until Settings → Streaming → Multiple screens. On, destinations can pick Stream or Phone.
    static var multiDestinationRoutingV1: Bool {
        get { UserDefaults.standard.bool(forKey: multiDestinationRoutingV1Key) }
        set { UserDefaults.standard.set(newValue, forKey: multiDestinationRoutingV1Key) }
    }
}

/// One origin for video frame index and audio sample count. FLV uses milliseconds.
final class MasterClock: @unchecked Sendable {
    let t0: CMTime
    private let lock = NSLock()
    private var videoFrameIndex: Int64 = 0
    private var audioSampleCount: Int64 = 0

    init(t0: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        self.t0 = t0
    }

    func videoPTS(frameIndex: Int64, fpsNum: Int32, fpsDen: Int32) -> CMTime {
        let den = max(1, Int64(fpsDen))
        let num = max(1, Int32(fpsNum))
        return CMTime(value: frameIndex * den, timescale: num)
    }

    func audioPTS(sampleCount: Int64) -> CMTime {
        CMTime(value: max(0, sampleCount), timescale: 48_000)
    }

    func flvMilliseconds(_ time: CMTime) -> UInt32 {
        guard time.isValid else { return 0 }
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= 0 else { return 0 }
        return UInt32(min(seconds * 1000, Double(UInt32.max)))
    }

    func claimVideoFrame() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let index = videoFrameIndex
        videoFrameIndex += 1
        return index
    }

    func claimAudioBlock(frames: Int64 = 1024) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        let start = audioSampleCount
        audioSampleCount += frames
        return start
    }
}

#if canImport(CoreVideo)
/// Latest composite only. The ticker never waits on the composer.
final class LatestFrameSlot: @unchecked Sendable {
    static let shared = LatestFrameSlot()

    private let lock = NSLock()
    private var buffer: CVPixelBuffer?

    func store(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        buffer = pixelBuffer
        lock.unlock()
    }

    func take() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func held() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }
}
#endif

struct StreamV2Packet: Equatable {
    enum Kind: Equatable {
        case audio
        case video(keyframe: Bool)
    }

    var kind: Kind
    var pts: CMTime
    var payload: Data
}

/// Small DTS window so audio and video leave in order.
final class PacketInterleaver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.proshow.stream.interleave")
    private var pending: [StreamV2Packet] = []
    private let window: TimeInterval
    var emit: ((StreamV2Packet) -> Void)?

    init(window: TimeInterval = 0.15) {
        self.window = window
    }

    func push(_ packet: StreamV2Packet) {
        queue.async { [self] in
            pending.append(packet)
            pending.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
            flushUnlocked(force: false)
        }
    }

    func flush() {
        queue.async { [self] in
            flushUnlocked(force: true)
        }
    }

    private func flushUnlocked(force: Bool) {
        guard let newest = pending.last else { return }
        let newestSeconds = CMTimeGetSeconds(newest.pts)
        while let first = pending.first {
            let age = newestSeconds - CMTimeGetSeconds(first.pts)
            if !force, age < window { break }
            pending.removeFirst()
            emit?(first)
        }
    }
}

/// Duration-bounded send queue. Drops non-keyframe video. Never wipes audio with video.
final class StreamSendQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private var pending: [StreamV2Packet] = []
    private let dropThreshold: TimeInterval
    private let maxDuration: TimeInterval
    private(set) var droppedPFrameCount = 0
    private(set) var droppedAudioCount = 0
    private(set) var keyframeRequestCount = 0
    var requestKeyframe: (() -> Void)?
    var transmit: ((StreamV2Packet, @escaping () -> Void) -> Void)?
    private var inFlight = 0
    private let maxInFlight = 4
    private var unacked: [StreamV2Packet] = []

    init(
        endpointId: String,
        dropThreshold: TimeInterval = 0.7,
        maxDuration: TimeInterval = 2.5
    ) {
        self.dropThreshold = dropThreshold
        self.maxDuration = maxDuration
        queue = DispatchQueue(label: "com.proshow.stream.send.\(endpointId)")
    }

    func enqueue(_ packet: StreamV2Packet) {
        queue.async { [self] in
            pending.append(packet)
            relieveCongestion()
            drain()
        }
    }

    func bufferedDuration() -> TimeInterval {
        queue.sync { duration(of: unacked + pending) }
    }

    func depths() -> (pending: Int, unacked: Int) {
        queue.sync { (pending.count, unacked.count) }
    }

    func sync() {
        queue.sync {}
    }

    private func duration(of packets: [StreamV2Packet]) -> TimeInterval {
        guard let first = packets.first, let last = packets.last else { return 0 }
        return max(0, CMTimeGetSeconds(last.pts) - CMTimeGetSeconds(first.pts))
    }

    private func relieveCongestion() {
        let span = duration(of: unacked + pending)
        guard span > dropThreshold else { return }
        let before = pending.count
        pending.removeAll { packet in
            if case .video(false) = packet.kind { return true }
            return false
        }
        let removed = before - pending.count
        if removed > 0 {
            droppedPFrameCount += removed
            keyframeRequestCount += 1
            requestKeyframe?()
        }
        guard duration(of: unacked + pending) > maxDuration else { return }
        if let last = (unacked + pending).last {
            let cutoff = CMTimeGetSeconds(last.pts) - maxDuration
            pending.removeAll { CMTimeGetSeconds($0.pts) < cutoff }
        }
    }

    private func drain() {
        while inFlight < maxInFlight, !pending.isEmpty {
            let packet = pending.removeFirst()
            unacked.append(packet)
            inFlight += 1
            transmit?(packet) { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    if !self.unacked.isEmpty { self.unacked.removeFirst() }
                    self.inFlight = max(0, self.inFlight - 1)
                    self.drain()
                }
            }
        }
    }
}

/// Fixed-size stereo ring. Starvation returns zeros for that lane only.
final class LaneRing: @unchecked Sendable {
    let capacity: Int
    private var samples: [Float]
    private var read = 0
    private var count = 0
    private(set) var underruns = 0
    var gain: Double = 1

    init(capacityFrames: Int = 48_000 / 5) {
        capacity = max(2048, capacityFrames * 2)
        samples = [Float](repeating: 0, count: capacity)
    }

    var fillMilliseconds: Double {
        Double(count / 2) / 48.0
    }

    func write(_ input: [Float]) {
        for sample in input {
            let index = (read + count) % capacity
            if count == capacity {
                read = (read + 1) % capacity
                count -= 1
            }
            samples[index] = sample
            count += 1
        }
    }

    /// Reads `frames` stereo pairs into `mix` (interleaved). Short lane contributes zeros.
    func readMix(into mix: inout [Float], frames: Int, gain: Double) {
        let need = frames * 2
        let have = min(count, need)
        if have < need { underruns += 1 }
        for index in 0..<have {
            mix[index] += samples[(read + index) % capacity] * Float(gain)
        }
        let consume = have
        read = (read + consume) % capacity
        count -= consume
    }
}

final class AudioMixer: @unchecked Sendable {
    static let framesPerBlock = 1024
    private let queue = DispatchQueue(label: "com.proshow.stream.audio.mixer")
    private var lanes: [AudioChannelRole: LaneRing] = [:]
    private var scratch = [Float](repeating: 0, count: framesPerBlock * 2)
    private(set) var silentBlockCount = 0
    private(set) var blockCount = 0
    var onBlock: (([Float], CMTime) -> Void)?

    func enqueue(_ samples: [Float], role: AudioChannelRole, gain: Double) {
        queue.async { [self] in
            self.absorb(samples, role: role, gain: gain)
        }
    }

    /// Call only from the mixer queue (including `mixOnce`'s fill callback).
    func absorb(_ samples: [Float], role: AudioChannelRole, gain: Double) {
        let lane = lanes[role] ?? LaneRing()
        lane.gain = gain
        lane.write(samples)
        lanes[role] = lane
    }

    /// `fill` runs on the mixer queue before the block is summed.
    func mixOnce(clock: MasterClock, fill: @escaping () -> Void) {
        queue.async { [self] in
            fill()
            for index in scratch.indices { scratch[index] = 0 }
            for lane in lanes.values {
                lane.readMix(into: &scratch, frames: Self.framesPerBlock, gain: lane.gain)
            }
            if scratch.allSatisfy({ $0 == 0 }) { silentBlockCount += 1 }
            blockCount += 1
            let start = clock.claimAudioBlock(frames: Int64(Self.framesPerBlock))
            let pts = clock.audioPTS(sampleCount: start)
            onBlock?(scratch, pts)
        }
    }

    func laneFillMilliseconds() -> [AudioChannelRole: Double] {
        queue.sync {
            lanes.mapValues(\.fillMilliseconds)
        }
    }
}

#if canImport(CoreVideo)
final class OutputTicker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.proshow.stream.video.ticker")
    private var timer: DispatchSourceTimer?
    private var last: CVPixelBuffer?
    private var frameIndex: Int64 = 0
    private(set) var tickCount = 0
    private(set) var repeatCount = 0
    var onFrame: ((CVPixelBuffer, CMTime, Bool) -> Void)?
    private var forceNextKeyframe = false

    func requestKeyframe() {
        queue.async { [self] in
            forceNextKeyframe = true
        }
    }

    func start(clock: MasterClock, fps: Int, slot: LatestFrameSlot) {
        stop()
        let rate = max(1, fps)
        let interval = 1.0 / Double(rate)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .microseconds(500))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = CMTimeGetSeconds(MediaClockAnchor.shared.currentPresentationTime())
            let hostIndex = Int64(max(0, elapsed) * Double(rate))
            if self.frameIndex > hostIndex { return }
            let fresh = slot.take()
            let buffer = fresh ?? self.last
            guard let buffer else { return }
            if fresh == nil { self.repeatCount += 1 }
            self.last = buffer
            self.tickCount += 1
            var index = self.frameIndex
            if hostIndex - index > 1 {
                index = hostIndex
            }
            self.frameIndex = index + 1
            let force = self.forceNextKeyframe || index % Int64(rate * 2) == 0
            self.forceNextKeyframe = false
            let pts = clock.videoPTS(frameIndex: index, fpsNum: Int32(rate), fpsDen: 1)
            self.onFrame?(buffer, pts, force)
        }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
        last = nil
    }
}
#endif

enum StreamEngineV2Telemetry {
    #if canImport(os)
    private static let log = Logger(subsystem: "com.kaleel.proshow", category: "StreamEngineV2")
    #endif
    private static let lock = NSLock()
    private static var lastVideoTicks = 0
    private static var lastRepeats = 0
    private static var lastAudioBlocks = 0
    private static var lastDropP = 0
    private static var line = "v2 idle"

    static var latestLine: String {
        lock.lock()
        defer { lock.unlock() }
        return line
    }

    static func publish(
        videoTicks: Int,
        repeats: Int,
        audioBlocks: Int,
        silentBlocks: Int,
        dropP: Int,
        dropA: Int,
        keyframeRequests: Int,
        queueMilliseconds: Int
    ) {
        let vDelta = videoTicks - lastVideoTicks
        let rDelta = repeats - lastRepeats
        let aDelta = audioBlocks - lastAudioBlocks
        let pDelta = dropP - lastDropP
        lastVideoTicks = videoTicks
        lastRepeats = repeats
        lastAudioBlocks = audioBlocks
        lastDropP = dropP
        let sil = audioBlocks > 0 ? Double(silentBlocks) / Double(audioBlocks) : 0
        let text = "v_tick \(vDelta) v_rep \(rDelta) a_blk \(aDelta) sil \(String(format: "%.2f", sil)) drop_p \(pDelta) drop_a \(dropA) kf_req \(keyframeRequests) snd_ms \(queueMilliseconds)"
        lock.lock()
        line = text
        lock.unlock()
        #if canImport(os)
        log.info("\(text, privacy: .public)")
        #endif
    }

    static func reset() {
        lock.lock()
        lastVideoTicks = 0
        lastRepeats = 0
        lastAudioBlocks = 0
        lastDropP = 0
        line = "v2 idle"
        lock.unlock()
    }
}

enum StreamDepthLog {
    private static let path = "/tmp/proshow-stream-depth.log"

    static func reset() {
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    static func append(_ line: String) {
        let text = line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

/// Owns the V2 ticker and mixer while a broadcast is live.
final class StreamEngineV2Session: @unchecked Sendable {
    private let clock = MasterClock()
    private let mixer = AudioMixer()
    private let interleaver = PacketInterleaver()
    private let sendQueue = StreamSendQueue(endpointId: "primary")
    #if canImport(CoreVideo)
    private let ticker = OutputTicker()
    #endif
    private var audioTimer: DispatchSourceTimer?
    private var depthTimer: DispatchSourceTimer?
    private weak var transport: StreamTransport?
    private weak var encoder: HardwareVideoEncoder?
    private var started = false

    func start(transport: StreamTransport, encoder: HardwareVideoEncoder, fps: Int) {
        guard ProShowFeatureFlags.streamEngineV2Enabled, !started else { return }
        started = true
        self.transport = transport
        self.encoder = encoder
        encoder.strictPresentationTimestamps = true
        StreamEngineV2Telemetry.reset()
        StreamDepthLog.reset()
        sendQueue.requestKeyframe = { [weak self] in
            #if canImport(CoreVideo)
            self?.ticker.requestKeyframe()
            #endif
        }
        sendQueue.transmit = { [weak self] packet, done in
            self?.write(packet)
            done()
        }
        interleaver.emit = { [weak self] packet in
            self?.sendQueue.enqueue(packet)
        }
        mixer.onBlock = { samples, _ in
            ProgramPCMBridge.appendProgramMixMonitor(samples)
        }
        #if canImport(CoreVideo)
        ticker.onFrame = { [weak encoder] buffer, pts, force in
            encoder?.encodeOnMasterClock(pixelBuffer: buffer, presentationTime: pts, forceKeyframe: force)
        }
        let original = encoder.onEncoded
        encoder.onEncoded = { [weak self] packet in
            guard let self else {
                original?(packet)
                return
            }
            let pts: CMTime
            let key: Bool
            let payload: Data
            switch packet {
            case .sequenceHeader(let data):
                original?(packet)
                return
            case .accessUnit(let ms, let keyframe, let avcc):
                pts = CMTime(value: Int64(ms), timescale: 1000)
                key = keyframe
                payload = RTMPClient.videoMessage(packet)
                _ = avcc
            }
            self.interleaver.push(StreamV2Packet(kind: .video(keyframe: key), pts: pts, payload: payload))
        }
        ticker.start(clock: clock, fps: fps, slot: LatestFrameSlot.shared)
        #endif
        startDepthLog()
    }

    private func startDepthLog() {
        depthTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.proshow.stream.depth"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.started else { return }
            let send = self.sendQueue.depths()
            let enc = self.encoder?.queuedFrameDepth ?? (session: 0, encoder: 0)
            let outcome = self.encoder?.encodeOutcome ?? (failures: 0, status: 0)
            let line = "send_pending=\(send.pending) send_unacked=\(send.unacked) enc_session=\(enc.session) enc_held=\(enc.encoder) vt_status=\(outcome.status) vt_fail=\(outcome.failures)"
            StreamDepthLog.append(line)
        }
        depthTimer = timer
        timer.resume()
    }

    func stop() {
        started = false
        audioTimer?.cancel()
        audioTimer = nil
        depthTimer?.cancel()
        depthTimer = nil
        #if canImport(CoreVideo)
        ticker.stop()
        #endif
        interleaver.flush()
        encoder?.strictPresentationTimestamps = false
        encoder?.onEncoded = nil
    }

    func noteTelemetry() {
        #if canImport(CoreVideo)
        StreamEngineV2Telemetry.publish(
            videoTicks: ticker.tickCount,
            repeats: ticker.repeatCount,
            audioBlocks: mixer.blockCount,
            silentBlocks: mixer.silentBlockCount,
            dropP: sendQueue.droppedPFrameCount,
            dropA: sendQueue.droppedAudioCount,
            keyframeRequests: sendQueue.keyframeRequestCount,
            queueMilliseconds: Int(sendQueue.bufferedDuration() * 1000)
        )
        #endif
    }

    private func write(_ packet: StreamV2Packet) {
        guard let transport else { return }
        switch packet.kind {
        case .audio:
            let seconds = CMTimeGetSeconds(packet.pts)
            let stamp = UInt32(min(max(0, seconds * 1000), Double(UInt32.max)))
            transport.send(
                RTMPClient.audioMessage(.accessUnit(timestampMs: stamp, aac: packet.payload)),
                kind: .audio
            )
        case .video(let keyframe):
            transport.send(packet.payload, kind: .video(keyframe: keyframe))
        }
    }
}
