import CoreMedia
import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(AudioToolbox)
import AudioToolbox
#endif

/// AAC-LC @ 48 kHz: 1024 PCM frames per access unit (~21.333 ms). RTMP pumps must match this rate.
enum ProgramStreamAudioClock {
    static let sampleRate = 48_000
    static let framesPerAccessUnit = 1024
    static let interleavedSamplesPerAccessUnit = framesPerAccessUnit * 2
    static let accessUnitIntervalNanoseconds = 1024 * 1_000_000_000 / sampleRate

    static func timestampMs(forAccessUnitIndex index: UInt64) -> UInt32 {
        UInt32((index * UInt64(framesPerAccessUnit) * 1_000) / UInt64(sampleRate))
    }

    static var pumpTimerInterval: DispatchTimeInterval {
        .nanoseconds(accessUnitIntervalNanoseconds)
    }
}

struct RTMPDestination: Equatable, Sendable {
    var host: String
    var port: UInt16
    var app: String
    var stream: String
    var secure: Bool
    var tcURL: String
}

enum EncodedAudioPacket: Sendable, Equatable {
    case sequenceHeader
    case accessUnit(timestampMs: UInt32, aac: Data = Data())
}

struct ProgramAudioAccessUnit: Sendable {
    var aac: Data
    var presentationTime: CMTime
    var timestampMs: UInt32
}

enum RTMPClient {
    static func parseURL(_ raw: String) -> RTMPDestination? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "rtmp" || scheme == "rtmps" else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "/").map(String.init)
        let app = parts.first ?? "live"
        let stream = parts.dropFirst().joined(separator: "/")
        let port = UInt16(url.port ?? (scheme == "rtmps" ? 443 : 1935))
        let tc = "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/\(app)"
        return RTMPDestination(
            host: host,
            port: port,
            app: app,
            stream: stream,
            secure: scheme == "rtmps",
            tcURL: tc
        )
    }

    static func resolve(_ config: RtmpStreamConfig) -> RTMPDestination? {
        resolve(url: config.destinationURL, streamKey: config.streamKey)
    }

    static func resolve(url: String, streamKey: String) -> RTMPDestination? {
        guard var dest = parseURL(url) else { return nil }
        let key = streamKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if dest.stream.isEmpty, !key.isEmpty {
            dest.stream = key
        }
        return dest.stream.isEmpty ? nil : dest
    }

    static func fanoutConfigs(from config: RtmpStreamConfig) -> [RtmpStreamConfig] {
        if !config.relayDestinations.isEmpty {
            return config.relayDestinations.compactMap { destination in
                var copy = config
                copy.useCloudRelay = false
                copy.relayDestinations = []
                copy.destinationURL = destination.url
                copy.streamKey = destination.streamKey.isEmpty ? config.streamKey : destination.streamKey
                return resolve(copy) == nil ? nil : copy
            }
        }
        return resolve(config) == nil ? [] : [config]
    }

    static func handshakeC0C1(timestamp: UInt32 = 1) -> Data {
        var data = Data([0x03])
        var time = timestamp.bigEndian
        data.append(Data(bytes: &time, count: 4))
        data.append(Data(count: 4))
        data.append(contentsOf: (0..<1528).map { UInt8($0 & 0xFF) })
        return data
    }

    static func flvHeader() -> Data {
        Data([0x46, 0x4C, 0x56, 0x01, 0x05, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x00])
    }

    static func amf0String(_ value: String) -> Data {
        let utf = Data(value.utf8)
        var data = Data([0x02])
        data.append(UInt16(utf.count).bigEndianData)
        data.append(utf)
        return data
    }

    static func amf0Number(_ value: Double) -> Data {
        var data = Data([0x00])
        var be = value.bitPattern.bigEndian
        data.append(Data(bytes: &be, count: 8))
        return data
    }

    static func amf0Null() -> Data { Data([0x05]) }

    static func amf0Boolean(_ value: Bool) -> Data {
        Data([0x01, value ? 1 : 0])
    }

    static func amf0Object(_ fields: [(String, Data)]) -> Data {
        var data = Data([0x03])
        for (key, value) in fields {
            let utf = Data(key.utf8)
            data.append(UInt16(utf.count).bigEndianData)
            data.append(utf)
            data.append(value)
        }
        data.append(contentsOf: [0x00, 0x00, 0x09])
        return data
    }

    static func commandConnect(app: String, tcURL: String) -> Data {
        var payload = Data()
        payload.append(amf0String("connect"))
        payload.append(amf0Number(1))
        payload.append(amf0Object([
            ("app", amf0String(app)),
            ("type", amf0String("nonprivate")),
            ("flashVer", amf0String("FMLE/3.0 (compatible; FMSc/1.0)")),
            ("swfUrl", amf0String(tcURL)),
            ("tcUrl", amf0String(tcURL)),
            ("fpad", amf0Boolean(false)),
            ("capabilities", amf0Number(239)),
            ("audioCodecs", amf0Number(3575)),
            ("videoCodecs", amf0Number(252)),
            ("videoFunction", amf0Number(1)),
            ("objectEncoding", amf0Number(0)),
        ]))
        return chunk(typeID: 20, streamID: 0, payload: payload)
    }

    static func commandReleaseStream(_ stream: String) -> Data {
        var payload = Data()
        payload.append(amf0String("releaseStream"))
        payload.append(amf0Number(2))
        payload.append(amf0Null())
        payload.append(amf0String(stream))
        return chunk(typeID: 20, streamID: 0, payload: payload)
    }

    static func commandFCPublish(_ stream: String) -> Data {
        var payload = Data()
        payload.append(amf0String("FCPublish"))
        payload.append(amf0Number(3))
        payload.append(amf0Null())
        payload.append(amf0String(stream))
        return chunk(typeID: 20, streamID: 0, payload: payload)
    }

    static func commandCreateStream() -> Data {
        var payload = Data()
        payload.append(amf0String("createStream"))
        payload.append(amf0Number(4))
        payload.append(amf0Null())
        return chunk(typeID: 20, streamID: 0, payload: payload)
    }

    static func commandPublish(_ stream: String) -> Data {
        var payload = Data()
        payload.append(amf0String("publish"))
        payload.append(amf0Number(0))
        payload.append(amf0Null())
        payload.append(amf0String(stream))
        payload.append(amf0String("live"))
        return chunk(typeID: 20, streamID: 1, payload: payload)
    }

    static func setChunkSize(_ size: UInt32 = 4096) -> Data {
        var payload = Data()
        var be = size.bigEndian
        payload.append(Data(bytes: &be, count: 4))
        return chunk(typeID: 1, streamID: 0, payload: payload, csid: 2)
    }

    static func amf0EcmaArray(_ fields: [(String, Data)]) -> Data {
        var data = Data([0x08])
        var count = UInt32(fields.count).bigEndian
        data.append(Data(bytes: &count, count: 4))
        for (key, value) in fields {
            let utf = Data(key.utf8)
            data.append(UInt16(utf.count).bigEndianData)
            data.append(utf)
            data.append(value)
        }
        data.append(contentsOf: [0x00, 0x00, 0x09])
        return data
    }

    static func metadataMessage(_ config: RtmpStreamConfig) -> Data {
        metadataMessage(
            width: config.width,
            height: config.height,
            framerate: config.framerate,
            videoBitrateKbps: config.bitrateKbps
        )
    }

    /// FLV `@setDataFrame` / `onMetaData` — explicit `framerate` so ffprobe reports avg_frame_rate (not 0/0).
    static func metadataMessage(width: Int, height: Int, framerate: Int, videoBitrateKbps: Int) -> Data {
        createOnMetaDataPayload(
            width: width,
            height: height,
            fps: framerate,
            videoBitrateKbps: videoBitrateKbps
        )
    }

    static func createOnMetaDataPayload(width: Int, height: Int, fps: Int, videoBitrateKbps: Int) -> Data {
        let fpsValue = Double(max(1, fps))
        var payload = Data()
        payload.append(amf0String("@setDataFrame"))
        payload.append(amf0String("onMetaData"))
        payload.append(amf0EcmaArray([
            ("duration", amf0Number(0)),
            ("width", amf0Number(Double(max(1, width)))),
            ("height", amf0Number(Double(max(1, height)))),
            ("framerate", amf0Number(fpsValue)),
            ("videocodecid", amf0Number(7)),
            ("audiocodecid", amf0Number(10)),
            ("videodatarate", amf0Number(Double(max(1, videoBitrateKbps)))),
            ("audiodatarate", amf0Number(128)),
            ("audiosamplerate", amf0Number(48_000)),
            ("audiosamplesize", amf0Number(16)),
            ("stereo", amf0Boolean(true)),
            ("encoder", amf0String("ProShow")),
        ]))
        return chunk(typeID: 18, streamID: 1, payload: payload, csid: 5, timestamp: 0, chunkSize: 4096)
    }

    /// AAC-LC 48 kHz stereo AudioSpecificConfig. Access units come from `AACSilenceEncoder`.
    static let aacSpecificConfig = Data([0x11, 0x90])
    static var silentAACFrame: Data { AACSilenceEncoder.frame() }

    static func audioMessage(_ packet: EncodedAudioPacket) -> Data {
        var body = Data([0xAF])
        let timestamp: UInt32
        switch packet {
        case .sequenceHeader:
            timestamp = 0
            body.append(0x00)
            body.append(aacSpecificConfig)
        case .accessUnit(let time, let aac):
            timestamp = time
            body.append(0x01)
            body.append(aac.isEmpty ? silentAACFrame : aac)
        }
        return chunk(typeID: 8, streamID: 1, payload: body, csid: 4, timestamp: timestamp, chunkSize: 4096)
    }

    static func videoMessage(_ packet: EncodedVideoPacket) -> Data {
        var body = Data()
        let timestamp: UInt32
        switch packet {
        case .sequenceHeader(let record):
            timestamp = 0
            body.append(contentsOf: [0x17, 0x00, 0x00, 0x00, 0x00])
            body.append(record)
        case .accessUnit(let time, let keyframe, let avcc):
            timestamp = time
            body.append(keyframe ? 0x17 : 0x27)
            body.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
            body.append(avcc)
        }
        return chunk(typeID: 9, streamID: 1, payload: body, csid: 6, timestamp: timestamp, chunkSize: 4096)
    }

    static func chunk(
        typeID: UInt8,
        streamID: UInt32,
        payload: Data,
        csid: UInt8 = 3,
        timestamp: UInt32 = 0,
        chunkSize: Int = 128
    ) -> Data {
        var header = Data([csid & 0x3F])
        let ts = timestamp & 0xFFFFFF
        header.append(UInt8((ts >> 16) & 0xFF))
        header.append(UInt8((ts >> 8) & 0xFF))
        header.append(UInt8(ts & 0xFF))
        let length = UInt32(payload.count)
        header.append(UInt8((length >> 16) & 0xFF))
        header.append(UInt8((length >> 8) & 0xFF))
        header.append(UInt8(length & 0xFF))
        header.append(typeID)
        var sid = streamID.littleEndian
        header.append(Data(bytes: &sid, count: 4))
        var packet = header
        let size = max(1, chunkSize)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + size, payload.count)
            packet.append(payload.subdata(in: offset..<end))
            offset = end
            if offset < payload.count {
                packet.append(0xC0 | (csid & 0x3F))
            }
        }
        return packet
    }

    static func userControl(event: UInt16, value: UInt32) -> Data {
        var payload = Data()
        var eventBE = event.bigEndian
        payload.append(Data(bytes: &eventBE, count: 2))
        var valueBE = value.bigEndian
        payload.append(Data(bytes: &valueBE, count: 4))
        return chunk(typeID: 4, streamID: 0, payload: payload, csid: 2)
    }

    static func pingRequest(timestamp: UInt32) -> Data {
        userControl(event: 6, value: timestamp)
    }

    static func pingResponse(timestamp: UInt32) -> Data {
        userControl(event: 7, value: timestamp)
    }
}

enum RTMPInboundEvent: Equatable, Sendable {
    case ping(UInt32)
    case setChunkSize(UInt32)
}

/// Enough of the RTMP chunk stream to answer ingest pings. X/pscp drops publishers that stay silent.
enum RTMPChunkReader {
    struct State {
        var buffer = Data()
        var chunkSize = 128
        var streams: [Int: Stream] = [:]
    }

    struct Stream {
        var timestamp: UInt32 = 0
        var length = 0
        var typeID: UInt8 = 0
        var messageStreamID: UInt32 = 0
        var payload = Data()
    }

    static func consume(_ data: Data, state: inout State) -> [RTMPInboundEvent] {
        if !data.isEmpty {
            state.buffer.append(data)
        }
        var events: [RTMPInboundEvent] = []
        var offset = 0
        while offset < state.buffer.count {
            let start = offset
            guard let header = readBasicHeader(state.buffer, offset: &offset) else {
                offset = start
                break
            }
            var stream = state.streams[header.csid] ?? Stream()
            if header.fmt < 3 {
                guard let message = readMessageHeader(
                    state.buffer,
                    offset: &offset,
                    fmt: header.fmt,
                    previous: stream
                ) else {
                    offset = start
                    break
                }
                stream.timestamp = message.timestamp
                stream.length = message.length
                stream.typeID = message.typeID
                stream.messageStreamID = message.messageStreamID
            }
            let remaining = max(0, stream.length - stream.payload.count)
            let take = min(max(1, state.chunkSize), remaining)
            guard offset + take <= state.buffer.count else {
                offset = start
                break
            }
            if take > 0 {
                stream.payload.append(state.buffer.subdata(in: offset..<(offset + take)))
                offset += take
            }
            if stream.payload.count >= stream.length {
                if let event = event(from: stream) {
                    events.append(event)
                    if case .setChunkSize(let size) = event {
                        state.chunkSize = max(1, Int(size))
                    }
                }
                stream.payload = Data()
            }
            state.streams[header.csid] = stream
        }
        if offset > 0 {
            state.buffer.removeSubrange(0..<offset)
        }
        return events
    }

    private static func readBasicHeader(_ data: Data, offset: inout Int) -> (fmt: UInt8, csid: Int)? {
        guard offset < data.count else { return nil }
        let first = data[offset]
        offset += 1
        let fmt = first >> 6
        var csid = Int(first & 0x3F)
        if csid == 0 {
            guard offset < data.count else { return nil }
            csid = Int(data[offset]) + 64
            offset += 1
        } else if csid == 1 {
            guard offset + 1 < data.count else { return nil }
            csid = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            csid += 64
            offset += 2
        }
        return (fmt, csid)
    }

    private static func readMessageHeader(
        _ data: Data,
        offset: inout Int,
        fmt: UInt8,
        previous: Stream
    ) -> (timestamp: UInt32, length: Int, typeID: UInt8, messageStreamID: UInt32)? {
        let needed = fmt == 0 ? 11 : fmt == 1 ? 7 : 3
        guard offset + needed <= data.count else { return nil }
        let timestamp = readUInt24(data, offset)
        var length = previous.length
        var typeID = previous.typeID
        var messageStreamID = previous.messageStreamID
        if fmt <= 1 {
            length = Int(readUInt24(data, offset + 3))
            typeID = data[offset + 6]
        }
        if fmt == 0 {
            messageStreamID = UInt32(data[offset + 7])
                | UInt32(data[offset + 8]) << 8
                | UInt32(data[offset + 9]) << 16
                | UInt32(data[offset + 10]) << 24
        }
        offset += needed
        var resolved = timestamp
        if timestamp == 0xFFFFFF {
            guard offset + 4 <= data.count else { return nil }
            resolved = UInt32(data[offset]) << 24
                | UInt32(data[offset + 1]) << 16
                | UInt32(data[offset + 2]) << 8
                | UInt32(data[offset + 3])
            offset += 4
        } else if fmt > 0 {
            resolved = previous.timestamp &+ timestamp
        }
        return (resolved, length, typeID, messageStreamID)
    }

    private static func readUInt24(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
    }

    private static func event(from stream: Stream) -> RTMPInboundEvent? {
        if stream.typeID == 1, stream.payload.count >= 4 {
            let size = UInt32(stream.payload[0]) << 24
                | UInt32(stream.payload[1]) << 16
                | UInt32(stream.payload[2]) << 8
                | UInt32(stream.payload[3])
            return .setChunkSize(size)
        }
        if stream.typeID == 4, stream.payload.count >= 6 {
            let event = UInt16(stream.payload[0]) << 8 | UInt16(stream.payload[1])
            guard event == 6 else { return nil }
            let timestamp = UInt32(stream.payload[2]) << 24
                | UInt32(stream.payload[3]) << 16
                | UInt32(stream.payload[4]) << 8
                | UInt32(stream.payload[5])
            return .ping(timestamp)
        }
        return nil
    }
}

private extension UInt16 {
    var bigEndianData: Data {
        var value = bigEndian
        return Data(bytes: &value, count: 2)
    }
}

/// One outbound RTMP/RTMPS client. Tests keep `MockStreamTransport`.
final class RTMPStreamTransport: StreamTransport, @unchecked Sendable {
    private(set) var bytesWritten = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    private(set) var destination: RTMPDestination?
    private(set) var isReady = false
    private var streamConfig = RtmpStreamConfig.default
    private var audioAccessUnitsSent: UInt64 = 0
    private var audioTimer: DispatchSourceTimer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var keepaliveTimestamp: UInt32 = 0
    private var receiveLoopRunning = false
    private var inbound = RTMPChunkReader.State()
    #if canImport(Network)
    private var connection: NWConnection?
    #endif
    private var mediaQueue: RTMPEndpointQueue?
    private let queue = DispatchQueue(label: "com.kaleel.proshow.rtmp")

    var networkDropCount: Int {
        queue.sync { mediaQueue?.droppedTagCount ?? 0 }
    }

    var networkAudioDropCount: Int {
        queue.sync { mediaQueue?.droppedAudioTagCount ?? 0 }
    }

    func connect(config: RtmpStreamConfig) throws {
        guard let dest = RTMPClient.resolve(config), !dest.stream.isEmpty else {
            throw NSError(
                domain: "ProShow.RTMP",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ingest URL or stream key is missing."]
            )
        }
        streamConfig = config
        destination = dest
        connectCount += 1
        isReady = false
        #if canImport(Network)
        let parameters: NWParameters = dest.secure ? .tls : .tcp
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(dest.host),
            port: NWEndpoint.Port(rawValue: dest.port) ?? 1935
        )
        let socket = NWConnection(to: endpoint, using: parameters)
        connection = socket
        let outbound = RTMPEndpointQueue(endpointId: "\(dest.host):\(dest.port)/\(dest.stream)") { [weak self] data, done in
            guard let self else {
                done()
                return
            }
            self.bytesWritten += data.count
            guard let connection = self.connection else {
                done()
                return
            }
            connection.send(content: data, completion: .contentProcessed { _ in
                done()
            })
        }
        mediaQueue = outbound
        socket.start(queue: queue)
        #endif
    }

    func waitUntilReady(timeoutMs: Int) async -> Bool {
        #if canImport(Network)
        guard let connection else { return false }
        let ready = await waitForState(.ready, timeoutMs: timeoutMs)
        guard ready else { return false }
        do {
            try await publish(on: connection)
            isReady = true
            watchConnection(connection)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    func write(frameBytes: Int) {
        send(Data(count: min(max(0, frameBytes), 188)))
    }

    func send(_ payload: Data) {
        send(payload, kind: .other)
    }

    func send(_ payload: Data, kind: RTMPOutboundTag) {
        guard !payload.isEmpty else { return }
        #if canImport(Network)
        if let mediaQueue {
            mediaQueue.enqueue(payload, kind: kind)
            return
        }
        bytesWritten += payload.count
        connection?.send(content: payload, completion: .contentProcessed { _ in })
        #else
        bytesWritten += payload.count
        #endif
    }

    func disconnect() {
        disconnectCount += 1
        isReady = false
        receiveLoopRunning = false
        audioTimer?.cancel()
        audioTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        mediaQueue?.cancel()
        mediaQueue = nil
        #if canImport(Network)
        connection?.cancel()
        connection = nil
        #endif
    }

    #if canImport(Network)
    private func waitForState(_ target: NWConnection.State, timeoutMs: Int) async -> Bool {
        if connection?.state == target { return true }
        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Bool) -> Void = { value in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: value)
            }
            if connection?.state == target {
                finish(true)
                return
            }
            connection?.stateUpdateHandler = { state in
                switch state {
                case target:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(max(timeoutMs, 40))) {
                finish(self.connection?.state == target)
            }
        }
    }

    private func publish(on connection: NWConnection) async throws {
        guard let dest = destination else {
            throw NSError(domain: "ProShow.RTMP", code: 3, userInfo: [NSLocalizedDescriptionKey: "RTMP destination missing."])
        }
        let hello = RTMPClient.handshakeC0C1()
        try await send(hello, on: connection)
        let serverHello = try await receive(3073, on: connection)
        let c2 = serverHello.count >= 1537 ? serverHello.subdata(in: 1..<1537) : Data(hello.suffix(1536))
        try await send(c2, on: connection)
        try await send(RTMPClient.commandConnect(app: dest.app, tcURL: dest.tcURL), on: connection)
        _ = try? await receiveContaining("_result", on: connection, timeoutMs: 2_000)
        try await send(RTMPClient.commandReleaseStream(dest.stream), on: connection)
        try await send(RTMPClient.commandFCPublish(dest.stream), on: connection)
        try await send(RTMPClient.commandCreateStream(), on: connection)
        _ = try? await receiveContaining("_result", on: connection, timeoutMs: 1_500)
        try await send(RTMPClient.commandPublish(dest.stream), on: connection)
        try await Task.sleep(nanoseconds: 120_000_000)
        try await send(RTMPClient.setChunkSize(), on: connection)
        try await send(RTMPClient.metadataMessage(streamConfig), on: connection)
        try await send(RTMPClient.audioMessage(.sequenceHeader), on: connection)
        for _ in 0..<4 {
            let pts = MediaClockAnchor.shared.nextAudioPresentationTime()
            let ts = MediaClockAnchor.shared.timestampMs(pts)
            try await send(RTMPClient.audioMessage(.accessUnit(timestampMs: ts)), on: connection)
        }
        audioAccessUnitsSent = 4
        inbound = RTMPChunkReader.State()
        startReceiveLoop(on: connection)
        startAudioPump()
        startPublishKeepalive()
        bytesWritten += hello.count + 1536
    }

    var suppressAudioPump = false

    private func startPublishKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimestamp = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(12), repeating: .seconds(12))
        timer.setEventHandler { [weak self] in
            guard let self, self.isReady else { return }
            self.keepaliveTimestamp &+= 12_000
            self.send(RTMPClient.pingRequest(timestamp: self.keepaliveTimestamp))
        }
        timer.resume()
        keepaliveTimer = timer
    }

    private func startAudioPump() {
        guard !suppressAudioPump else { return }
        audioTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + ProgramStreamAudioClock.pumpTimerInterval, repeating: ProgramStreamAudioClock.pumpTimerInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isReady else { return }
            ProgramEncoderAudioPump.noteTick()
            let due = MediaClockAnchor.shared.dueAudioBlockCount()
            guard due > 0 else { return }
            for _ in 0..<due {
                let unit = ProgramAACEncoder.nextTimedAccessUnit(recording: ProgramRecordingAudioBridge.activeProgramRecorder)
                self.sendAudioFrame(unit)
                ProgramAudioAccessTap.publish(unit)
            }
        }
        timer.resume()
        audioTimer = timer
    }

    func sendAudioFrame(_ unit: ProgramAudioAccessUnit) {
        send(
            RTMPClient.audioMessage(.accessUnit(timestampMs: unit.timestampMs, aac: unit.aac)),
            kind: .audio
        )
        audioAccessUnitsSent += 1
    }

    private func startReceiveLoop(on connection: NWConnection) {
        receiveLoopRunning = true
        drain(on: connection)
    }

    private func drain(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self, self.receiveLoopRunning else { return }
            if error != nil {
                // Ingest read errors are often transient; keep publishing until the socket is dead.
                if connection.state == .ready, self.isReady, self.receiveLoopRunning {
                    self.drain(on: connection)
                } else {
                    self.markDropped()
                }
                return
            }
            if let data, !data.isEmpty {
                for event in RTMPChunkReader.consume(data, state: &self.inbound) {
                    if case .ping(let timestamp) = event {
                        self.send(RTMPClient.pingResponse(timestamp: timestamp))
                    }
                }
            }
            if isComplete {
                // Some ingests (including X/pscp) close the read half while still accepting publish.
                self.receiveLoopRunning = false
                return
            }
            self.drain(on: connection)
        }
    }

    private func watchConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.markDropped()
            default:
                break
            }
        }
    }

    private func markDropped() {
        receiveLoopRunning = false
        isReady = false
        audioTimer?.cancel()
        audioTimer = nil
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    private func send(_ payload: Data, on connection: NWConnection) async throws {
        bytesWritten += payload.count
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receiveContaining(_ token: String, on connection: NWConnection, timeoutMs: Int) async throws -> Data {
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 200)) / 1000)
        var buffer = Data()
        while Date() < deadline {
            let chunk = try await receive(1, on: connection, timeoutNs: 400_000_000)
            buffer.append(chunk)
            if String(decoding: buffer, as: UTF8.self).contains(token) {
                return buffer
            }
            if buffer.count > 65_536 {
                return buffer
            }
        }
        return buffer
    }

    private func receive(_ count: Int, on connection: NWConnection, timeoutNs: UInt64 = 8_000_000_000) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receive(minimumIncompleteLength: count, maximumLength: max(count, 8192)) { data, _, _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: data ?? Data())
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw NSError(domain: "ProShow.RTMP", code: 4, userInfo: [NSLocalizedDescriptionKey: "RTMP handshake timed out."])
            }
            guard let data = try await group.next() else {
                throw NSError(domain: "ProShow.RTMP", code: 4, userInfo: [NSLocalizedDescriptionKey: "RTMP handshake timed out."])
            }
            group.cancelAll()
            return data
        }
    }
    #endif
}

/// One VideoToolbox encode, one RTMP client per destination.
final class MultiRTMPTransport: StreamTransport, @unchecked Sendable {
    private var clients: [RTMPStreamTransport] = []
    var aggregateNetworkDropCount: Int {
        clients.reduce(0) { $0 + $1.networkDropCount }
    }

    var aggregateNetworkAudioDropCount: Int {
        clients.reduce(0) { $0 + $1.networkAudioDropCount }
    }
    private(set) var bytesWritten = 0
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0
    /// Phone lane sets this so the Stream pump stays the only AAC encode.
    var suppressSharedAudioPump = false
    private let gate = NSLock()
    private var videoSequenceHeader: Data?
    private var primedVideoConfig: Set<ObjectIdentifier> = []
    var isReady: Bool {
        !clients.isEmpty && clients.contains(where: \.isReady)
    }

    private var audioTimer: DispatchSourceTimer?

    func rememberVideoSequenceHeader(_ message: Data) {
        gate.lock()
        videoSequenceHeader = message
        primedVideoConfig.removeAll()
        gate.unlock()
    }

    /// A destination that connected after the first keyframe still needs SPS/PPS, then an IDR.
    func clientNeedsVideoConfig() -> Bool {
        gate.lock()
        defer { gate.unlock() }
        guard videoSequenceHeader != nil else { return false }
        return clients.contains { $0.isReady && !primedVideoConfig.contains(ObjectIdentifier($0)) }
    }

    func connect(config: RtmpStreamConfig) throws {
        gate.lock()
        videoSequenceHeader = nil
        primedVideoConfig.removeAll()
        gate.unlock()
        let configs = RTMPClient.fanoutConfigs(from: config)
        guard !configs.isEmpty else {
            throw NSError(
                domain: "ProShow.RTMP",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ingest URL or stream key is missing."]
            )
        }
        clients = []
        for item in configs {
            let client = RTMPStreamTransport()
            client.suppressAudioPump = true
            try client.connect(config: item)
            clients.append(client)
        }
        connectCount += 1
    }

    func waitUntilReady(timeoutMs: Int) async -> Bool {
        var ready = 0
        for client in clients {
            if await client.waitUntilReady(timeoutMs: timeoutMs) {
                ready += 1
            }
        }
        if ready > 0, !suppressSharedAudioPump {
            startSharedAudioPump()
        }
        return isReady
    }

    private func startSharedAudioPump() {
        audioTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.kaleel.proshow.rtmp.fanout-audio"))
        timer.schedule(deadline: .now() + ProgramStreamAudioClock.pumpTimerInterval, repeating: ProgramStreamAudioClock.pumpTimerInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.isReady else { return }
            ProgramEncoderAudioPump.noteTick()
            let due = MediaClockAnchor.shared.dueAudioBlockCount()
            guard due > 0 else { return }
            for _ in 0..<due {
                let unit = ProgramAACEncoder.nextTimedAccessUnit(recording: ProgramRecordingAudioBridge.activeProgramRecorder)
                ProgramAudioAccessTap.publish(unit)
                for client in self.clients where client.isReady {
                    client.sendAudioFrame(unit)
                }
            }
        }
        timer.resume()
        audioTimer = timer
    }

    func write(frameBytes: Int) {
        send(Data(count: min(max(0, frameBytes), 188)))
    }

    func send(_ payload: Data) {
        send(payload, kind: .other)
    }

    func send(_ payload: Data, kind: RTMPOutboundTag) {
        guard !payload.isEmpty else { return }
        let keyframe: Bool
        if case .video(let isKeyframe) = kind {
            keyframe = isKeyframe
        } else {
            keyframe = false
        }
        gate.lock()
        let header = videoSequenceHeader
        let ready = clients.filter(\.isReady)
        var prime: [RTMPStreamTransport] = []
        if let header, payload != header {
            for client in ready where !primedVideoConfig.contains(ObjectIdentifier(client)) {
                prime.append(client)
            }
        }
        if keyframe, payload != header {
            for client in ready {
                primedVideoConfig.insert(ObjectIdentifier(client))
            }
        }
        gate.unlock()
        if let header {
            for client in prime {
                client.send(header, kind: .video(keyframe: true))
            }
        }
        for client in ready {
            client.send(payload, kind: kind)
        }
        bytesWritten += payload.count
    }

    func disconnect() {
        disconnectCount += 1
        audioTimer?.cancel()
        audioTimer = nil
        for client in clients {
            client.disconnect()
        }
        clients = []
    }
}

/// Sums each LiveKit guest microphone into the program mix used by the room return,
/// RTMP destinations, and the recording. Per-guest faders are applied here.
enum GuestProgramMixBus {
    private static let lock = NSLock()
    private static var mono: [UUID: [Float]] = [:]
    private static var streamGain: [UUID: Float] = [:]
    private static var monitorGain: [UUID: Float] = [:]

    static func setGain(id: UUID, stream: Double, monitor: Double) {
        lock.lock()
        streamGain[id] = Float(stream)
        monitorGain[id] = Float(monitor)
        lock.unlock()
    }

    static func remove(id: UUID) {
        lock.lock()
        mono[id] = nil
        streamGain[id] = nil
        monitorGain[id] = nil
        lock.unlock()
    }

    static func push(id: UUID, mono samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        let converted = resample(samples, from: sampleRate)
        lock.lock()
        var ring = mono[id] ?? []
        ring.append(contentsOf: converted)
        let cap = 48_000 / 4
        if ring.count > cap {
            ring.removeFirst(ring.count - cap)
        }
        mono[id] = ring
        lock.unlock()
    }

    static func mix(interleavedCount: Int) -> (stream: [Float], monitor: [Float], active: Bool) {
        let frames = interleavedCount / 2
        guard frames > 0 else { return ([], [], false) }
        lock.lock()
        defer { lock.unlock() }
        var stream = [Float](repeating: 0, count: frames * 2)
        var monitor = [Float](repeating: 0, count: frames * 2)
        var active = false
        for (id, var ring) in mono {
            let streamLevel = streamGain[id] ?? 1
            let monitorLevel = monitorGain[id] ?? 1
            let take = min(frames, ring.count)
            if take > 0 { active = true }
            for index in 0..<take {
                let sample = ring[index]
                stream[index * 2] += sample * streamLevel
                stream[index * 2 + 1] += sample * streamLevel
                monitor[index * 2] += sample * monitorLevel
                monitor[index * 2 + 1] += sample * monitorLevel
            }
            if take > 0 {
                ring.removeFirst(take)
            }
            mono[id] = ring
        }
        return (stream, monitor, active)
    }

    private static func resample(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard abs(sampleRate - 48_000) >= 1, sampleRate > 1 else { return samples }
        let step = sampleRate / 48_000
        var out: [Float] = []
        out.reserveCapacity(Int(Double(samples.count) / step))
        var position = 0.0
        while Int(position) < samples.count {
            out.append(samples[Int(position)])
            position += step
        }
        return out
    }
}

/// Stream mix gains for capture threads (updated on the program clock, read on ingest).
enum ProgramStreamAudioGates {
    private static let lock = NSLock()
    private static var streamGain: [AudioChannelRole: Double] = [:]
    private static var monitorGain: [AudioChannelRole: Double] = [:]
    private static var strips: [AudioChannelRole: ChannelStripSettings] = [:]
    private static var runtimes: [AudioChannelRole: ChannelStripRuntime] = [:]
    private static var programMuted = false
    private static var masterLinear: Double = 1
    private static var hardwareCaptureOpen: Set<AudioChannelRole> = [
        .microphone, .desktop, .guest, .slide, .soundboard,
    ]
    /// While the assigned mic is still delivering, screen-share device audio stays out of the mix.
    private static var lastMicrophonePCM = Date.distantPast
    private static var lastDesktopPCM = Date.distantPast
    private static var lastSlidePCM = Date.distantPast
    private static var systemInputTapOpen = false
    private static var desktopHeldForMicrophone = false
    private static let microphoneOwnsMixWindow: TimeInterval = 0.35
    /// Hardware capture is often well below 0 dBFS; lift before AAC so the stream isn't whisper-quiet.
    private static let captureBoostDb: [AudioChannelRole: Double] = [
        .microphone: 18,
        .desktop: 12,
        .guest: 9,
    ]

    @MainActor
    static func sync(from matrix: AudioMatrixEngine) {
        lock.lock()
        programMuted = matrix.programMuted || matrix.master.muted
        if programMuted {
            streamGain.removeAll()
            monitorGain.removeAll()
            strips.removeAll()
            masterLinear = 0
        } else {
            streamGain.removeAll()
            monitorGain.removeAll()
            strips.removeAll()
            for channel in matrix.channels {
                streamGain[channel.role] = matrix.outputLevel(for: channel, bus: .stream)
                monitorGain[channel.role] = matrix.outputLevel(for: channel, bus: .monitor)
                strips[channel.role] = ChannelStripSettings.make(
                    channel: channel,
                    gate: matrix.isNoiseGateOn(channel.id),
                    comp: matrix.isChannelLimited(channel.id)
                )
                if channel.role == .guest, let guestID = channel.linkedGuestID {
                    GuestProgramMixBus.setGain(
                        id: guestID,
                        stream: matrix.outputLevel(for: channel, bus: .stream),
                        monitor: matrix.outputLevel(for: channel, bus: .monitor)
                    )
                }
            }
            masterLinear = AudioDSP.applyLimiter(
                AudioDSP.linear(fromDb: matrix.master.gainDb),
                enabled: matrix.master.limiterEnabled,
                ceilingDb: matrix.master.ceilingDb
            )
        }
        lock.unlock()
    }

    static func masterMixLinear() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return masterLinear
    }

    static func destinationGains(_ role: AudioChannelRole) -> (stream: Double, monitor: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (streamGain[role] ?? 0, monitorGain[role] ?? 0)
    }

    static func gainSnapshot() -> (stream: [AudioChannelRole: Double], monitor: [AudioChannelRole: Double], master: Double) {
        lock.lock()
        defer { lock.unlock() }
        return (streamGain, monitorGain, masterLinear)
    }
    static func streamGainLinear(_ role: AudioChannelRole) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let gain = streamGain[role] ?? 0
        return gain * masterLinear
    }

    static func setHardwareCaptureOpen(_ role: AudioChannelRole, open: Bool) {
        lock.lock()
        if open {
            hardwareCaptureOpen.insert(role)
        } else {
            hardwareCaptureOpen.remove(role)
        }
        lock.unlock()
    }

    static func isHardwareCaptureOpen(_ role: AudioChannelRole) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hardwareCaptureOpen.contains(role)
    }

    static func flushCaptureRole(_ role: AudioChannelRole) {
        setHardwareCaptureOpen(role, open: false)
        ProgramAACEncoder.flush(role: role)
        ProgramPCMBridge.clearMonitorRing()
    }

    static func setSystemInputTapOpen(_ open: Bool) {
        lock.lock()
        systemInputTapOpen = open
        lock.unlock()
    }

    /// True when slide, desktop, or the system-input tap is already the program voice.
    /// A camera added for picture must not open a second microphone on top of that.
    static func programVoiceBlocksExtraMicrophone() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if systemInputTapOpen { return true }
        let now = Date()
        if now.timeIntervalSince(lastDesktopPCM) < 0.75 { return true }
        if now.timeIntervalSince(lastSlidePCM) < 0.75 { return true }
        return false
    }

    static func enqueueCapture(role: AudioChannelRole, mono: [Float], sampleRate: Double, source: String?) {
        guard !mono.isEmpty else { return }
        if let source, role == .microphone || role == .desktop {
            lock.lock()
            let open = hardwareCaptureOpen.contains(role)
            lock.unlock()
            if open, !CaptureAudioSources.admit(role: role, source: source, frames: mono.count) {
                StreamAudioPipelineDiagnostics.recordGateReject()
                return
            }
        }
        enqueueCapture(role: role, mono: mono, sampleRate: sampleRate)
    }

    static func enqueueCapture(role: AudioChannelRole, mono: [Float], sampleRate: Double) {
        guard !mono.isEmpty else { return }
        lock.lock()
        guard hardwareCaptureOpen.contains(role) else {
            lock.unlock()
            StreamAudioPipelineDiagnostics.recordGateReject()
            return
        }
        let muted = programMuted
        let known = streamGain[role] != nil || monitorGain[role] != nil
        let stream = known ? (streamGain[role] ?? 0) : 1
        let monitor = known ? (monitorGain[role] ?? 0) : 1
        let settings = strips[role] ?? ChannelStripSettings()
        var runtime = runtimes[role] ?? ChannelStripRuntime()
        let boost = AudioDSP.linear(fromDb: captureBoostDb[role] ?? 0)
        let micStillOwnsMix = role == .desktop
            && Date().timeIntervalSince(lastMicrophonePCM) < microphoneOwnsMixWindow
        if role == .microphone, muted || (stream <= 0.0001 && monitor <= 0.0001) {
            lastMicrophonePCM = .distantPast
            desktopHeldForMicrophone = false
        }
        if micStillOwnsMix {
            let flushDesktop = !desktopHeldForMicrophone
            desktopHeldForMicrophone = true
            lock.unlock()
            if flushDesktop {
                ProgramAACEncoder.flush(role: .desktop)
            }
            StreamAudioPipelineDiagnostics.recordGateReject()
            return
        }
        if role == .desktop {
            desktopHeldForMicrophone = false
            if !muted, stream > 0.0001 || monitor > 0.0001 {
                lastDesktopPCM = Date()
            }
        }
        if role == .slide, !muted, stream > 0.0001 || monitor > 0.0001 {
            lastSlidePCM = Date()
        }
        if role == .microphone, !muted, stream > 0.0001 || monitor > 0.0001 {
            lastMicrophonePCM = Date()
        }
        lock.unlock()
        guard !muted, stream > 0.0001 || monitor > 0.0001 else { return }
        let processed = runtime.process(mono, settings: settings, sampleRate: sampleRate)
        lock.lock()
        runtimes[role] = runtime
        lock.unlock()
        let scaled = processed.map { sample in
            Float(max(-1, min(1, Double(sample) * boost)))
        }
        ProgramPCMBridge.enqueueMono(scaled, sampleRate: sampleRate, role: role)
    }

    /// One mixed access unit for operator headphones (no AAC).
    static func pullPreviewAudioFrame(sampleRate: Double = 48_000, channelCount: Int = 2) {
        guard channelCount >= 2, abs(sampleRate - 48_000) < 1 else { return }
        // The stream or recording encoder already drains the mix and feeds the room.
        // A second consumer split every source between two pullers (thin, gappy audio).
        guard !ProgramEncoderAudioPump.isActive else { return }
        ProgramAACEncoder.pumpPreviewMonitorMix()
    }
}

/// ~21 ms PCM mix pump while the right pane monitors off-air (matches live AAC cadence).
enum PreviewProgramAudioPump {
    private static let lock = NSLock()
    private static var timer: DispatchSourceTimer?
    private static var monitorWantsPump = false
    private static var guestReturnWantsPump = false
    private static var encodingSuppressed = false

    static func setMonitorWantsPump(_ wants: Bool) {
        lock.lock()
        monitorWantsPump = wants
        lock.unlock()
        reconcile()
    }

    static func setGuestReturnWantsPump(_ wants: Bool) {
        lock.lock()
        guestReturnWantsPump = wants
        lock.unlock()
        reconcile()
    }

    static func setEncodingSuppressed(_ suppressed: Bool) {
        lock.lock()
        encodingSuppressed = suppressed
        lock.unlock()
        reconcile()
    }

    private static func reconcile() {
        lock.lock()
        let shouldRun = (monitorWantsPump || guestReturnWantsPump) && !encodingSuppressed
        lock.unlock()
        if shouldRun {
            startIfNeeded()
        } else {
            stop()
        }
    }

    private static func startIfNeeded() {
        lock.lock()
        if timer != nil {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: ProShowQueues.diskIOQueue)
        source.schedule(deadline: .now() + ProgramStreamAudioClock.pumpTimerInterval, repeating: ProgramStreamAudioClock.pumpTimerInterval)
        source.setEventHandler {
            ProgramStreamAudioGates.pullPreviewAudioFrame()
        }
        source.resume()
        timer = source
        lock.unlock()
        for _ in 0..<4 {
            ProgramStreamAudioGates.pullPreviewAudioFrame()
        }
    }

    private static func stop() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }
}

enum ProgramPCMBridge {
    private static let lock = NSLock()
    private static var monitorRing: [Float] = []
    /// ~120 ms interleaved stereo @ 48 kHz — low latency for headphones.
    private static let monitorCapacity = 11_520

    static func enqueueMono(_ samples: [Float], sampleRate: Double, role: AudioChannelRole = .slide) {
        guard !samples.isEmpty else { return }
        let stereo: [Float]
        if abs(sampleRate - 48_000) < 1 {
            stereo = samples.flatMap { [$0, $0] }
        } else {
            let outCount = max(1, Int((Double(samples.count) * 48_000 / sampleRate).rounded()))
            var out: [Float] = []
            out.reserveCapacity(outCount * 2)
            let scale = sampleRate / 48_000
            let last = samples.count - 1
            for index in 0..<outCount {
                let position = Double(index) * scale
                let base = min(Int(position), last)
                let next = min(base + 1, last)
                let fraction = Float(position - Double(base))
                let sample = samples[base] + (samples[next] - samples[base]) * fraction
                out.append(sample)
                out.append(sample)
            }
            stereo = out
        }
        ProgramAACEncoder.enqueueInterleavedStereo(stereo, role: role)
    }

    /// Interleaved stereo 48 kHz samples for virtual-audio loopback (not mixer fader levels).
    static func consumeInterleavedStereo(frameCount: Int) -> [Float] {
        let needed = max(0, frameCount) * 2
        guard needed > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if monitorRing.isEmpty {
            return [Float](repeating: 0, count: needed)
        }
        var out: [Float] = []
        out.reserveCapacity(needed)
        while out.count < needed, !monitorRing.isEmpty {
            out.append(monitorRing.removeFirst())
        }
        if out.count < needed {
            out.append(contentsOf: repeatElement(0, count: needed - out.count))
        }
        return out
    }

    private static func appendMonitor(_ stereo: [Float]) {
        guard !stereo.isEmpty else { return }
        lock.lock()
        monitorRing.append(contentsOf: stereo)
        if monitorRing.count > monitorCapacity {
            monitorRing.removeFirst(monitorRing.count - monitorCapacity)
        }
        lock.unlock()
    }

    /// Headphone program bus. Does not feed the guest return.
    static func appendProgramMixMonitor(_ interleavedStereo: [Float]) {
        appendMonitor(interleavedStereo)
    }

    /// Room return (program minus guests). RTMP and recording keep the full mix.
    static func publishStreamMix(_ interleavedStereo: [Float]) {
        programMixListener?(interleavedStereo)
    }

    /// Extra consumer for the guest return. Does not drain the headphone ring.
    static var programMixListener: (([Float]) -> Void)?

    static func clearMonitorRing() {
        lock.lock()
        monitorRing.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

/// Latest program AAC frames for the RTMP audio pump.
enum ProgramAudioBus {
    private struct Entry {
        var frame: Data
        var presentationTime: CMTime
        var timestampMs: UInt32
    }

    private static let lock = NSLock()
    private static var frames: [Entry] = []

    static func push(_ frame: Data, presentationTime: CMTime, timestampMs: UInt32) {
        guard !frame.isEmpty else { return }
        lock.lock()
        frames.append(Entry(frame: frame, presentationTime: presentationTime, timestampMs: timestampMs))
        if frames.count > 64 {
            frames.removeFirst(frames.count - 48)
        }
        lock.unlock()
    }

    static func pop() -> Data? {
        popEntry()?.frame
    }

    static func popEntry() -> (frame: Data, presentationTime: CMTime, timestampMs: UInt32)? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        let entry = frames.removeFirst()
        return (entry.frame, entry.presentationTime, entry.timestampMs)
    }

    static func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    static func queuedAccessUnitCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }
}

/// Encodes interleaved stereo float PCM (48 kHz) to AAC-LC.
enum ProgramAACEncoder {
    private static let lock = NSLock()
    private static var configuredAudioBitrateBps: UInt32 = 128_000
    private static var lanes: [AudioChannelRole: [Float]] = [:]
    private static let accessUnitSamples = ProgramStreamAudioClock.interleavedSamplesPerAccessUnit
    /// Per-role PCM lane caps (interleaved stereo floats @ 48 kHz). Trim only under sustained overload.
    private static func laneLimits(for role: AudioChannelRole) -> (max: Int, trimTo: Int) {
        switch role {
        case .microphone, .desktop:
            return (384_000, 352_000) // ~4 s / ~3.7 s
        case .slide, .guest, .soundboard:
            return (192_000, 176_000) // ~2 s / ~1.8 s
        }
    }
    private static let encodeQueue = DispatchQueue(label: "com.kaleel.proshow.aac")
    private static let streamRoles: [AudioChannelRole] = [.microphone, .desktop, .guest, .slide, .soundboard]
    #if canImport(AudioToolbox)
    private static var converter: AudioConverterRef?
    #endif

    static func prepare(audioBitrateBps: Int = 128_000) {
        configuredAudioBitrateBps = UInt32(max(32_000, audioBitrateBps))
        encodeQueue.sync { _ = ensureConverter() }
    }

    static func enqueueInterleavedStereo(_ samples: [Float], role: AudioChannelRole = .slide) {
        guard !samples.isEmpty else { return }
        lock.lock()
        var lane = lanes[role] ?? []
        lane.append(contentsOf: samples)
        let limits = laneLimits(for: role)
        if lane.count > limits.max {
            lane.removeFirst(lane.count - limits.trimTo)
        }
        lanes[role] = lane
        lock.unlock()
    }

    /// Pulls up to one stereo block from a lane. Missing samples are zeros. Does not starve other lanes.
    static func drainLane(_ role: AudioChannelRole, stereoFrames: Int) -> [Float] {
        let need = max(0, stereoFrames) * 2
        guard need > 0 else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var lane = lanes[role] ?? []
        var out = [Float](repeating: 0, count: need)
        let take = min(lane.count, need)
        if take > 0 {
            for index in 0..<take {
                out[index] = lane[index]
            }
            lane.removeFirst(take)
            lanes[role] = lane
        }
        return out
    }

    static func encodeStereoBlock(_ samples: [Float]) -> Data? {
        encodeQueue.sync { encode(samples) }
    }

    static func nextAccessUnit(recording: ProgramVideoFileRecorder? = nil) -> Data {
        nextTimedAccessUnit(recording: recording).aac
    }

    static func nextTimedAccessUnit(recording: ProgramVideoFileRecorder? = nil) -> ProgramAudioAccessUnit {
        encodeQueue.sync {
            fillFromFileIfNeeded()
            advanceMixedProgramAudio(recording: recording)
        }
        if let entry = ProgramAudioBus.popEntry() {
            StreamAudioPipelineDiagnostics.recordRealAU()
            return ProgramAudioAccessUnit(
                aac: entry.frame,
                presentationTime: entry.presentationTime,
                timestampMs: entry.timestampMs
            )
        }
        StreamAudioPipelineDiagnostics.recordSyntheticSilenceAU()
        let pts = MediaClockAnchor.shared.nextAudioPresentationTime()
        return ProgramAudioAccessUnit(
            aac: AACSilenceEncoder.frame(),
            presentationTime: pts,
            timestampMs: MediaClockAnchor.shared.timestampMs(pts)
        )
    }

    /// Same mixed PCM as `nextAccessUnit`, without AAC encode (operator preview headphones).
    static func pumpPreviewMonitorMix() {
        encodeQueue.sync {
            fillFromFileIfNeeded()
            deliverMixedProgramAudio(shouldEncode: false, recording: nil)
        }
    }

    /// Highest PCM lane fill ratio (0…1) across stream roles — backpressure before AAC encode.
    static func captureLanePressureRatio() -> Double {
        lock.lock()
        defer { lock.unlock() }
        var peak = 0.0
        for role in streamRoles {
            guard let lane = lanes[role], !lane.isEmpty else { continue }
            let limits = laneLimits(for: role)
            peak = max(peak, Double(lane.count) / Double(max(1, limits.max)))
        }
        return peak
    }

    /// Interleaved stereo sample counts per stream role (for live diagnostics).
    static func laneDepthSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        return laneDepthSummaryUnlocked()
    }

    static func flush(role: AudioChannelRole) {
        encodeQueue.sync {
            lock.lock()
            lanes[role] = []
            lock.unlock()
        }
        ProgramAudioJitter.reset(role: role)
    }

    static func flushAll() {
        encodeQueue.sync {
            lock.lock()
            lanes.removeAll()
            lock.unlock()
        }
    }

    static func reset() {
        encodeQueue.sync {
            lock.lock()
            lanes.removeAll()
            lock.unlock()
            #if canImport(AudioToolbox)
            if let converter {
                AudioConverterDispose(converter)
                self.converter = nil
            }
            #endif
        }
        ProgramAudioBus.reset()
    }

    private static func fillFromFileIfNeeded() {
        lock.lock()
        let slideDepth = lanes[.slide]?.count ?? 0
        lock.unlock()
        // Only fall back to disk when the live tap lane is empty — avoids tap/file overlap gaps.
        guard slideDepth == 0 else { return }
        let pulled = ProgramAudioPuller.pullIfStarving()
        if !pulled.isEmpty {
            enqueueInterleavedStereo(pulled, role: .slide)
        }
    }

    private static func advanceMixedProgramAudio(recording: ProgramVideoFileRecorder?) {
        deliverMixedProgramAudio(shouldEncode: true, recording: recording)
    }

    private static func deliverMixedProgramAudio(shouldEncode: Bool, recording: ProgramVideoFileRecorder?) {
        let frame = dequeueMixedFrame()
        let stream = frame?.stream ?? [Float](repeating: 0, count: accessUnitSamples)
        let monitor = frame?.monitor ?? stream
        ProgramPCMBridge.appendProgramMixMonitor(monitor)
        ProgramPCMBridge.publishStreamMix(frame?.room ?? stream)
        Task { @MainActor in
            AudioMonitoringEngine.shared.noteProgramMixFrame(monitor)
        }
        let passthrough = recording?.isPassthrough == true
        if let recording, !passthrough {
            recording.appendAudioPCM(stream)
        }
        guard shouldEncode, let encoded = encode(stream) else {
            if shouldEncode { StreamAudioPipelineDiagnostics.recordEncodeFailure() }
            return
        }
        let pts = MediaClockAnchor.shared.nextAudioPresentationTime()
        let timestampMs = MediaClockAnchor.shared.timestampMs(pts)
        if passthrough {
            recording?.appendEncodedAudio(encoded, presentationTime: pts)
        }
        ProgramAudioBus.push(encoded, presentationTime: pts, timestampMs: timestampMs)
    }

    /// Drop stale PCM so a slow slide (low video bitrate, deep capture buffer) cannot play sound late.
    /// Live capture (mic, desktop) arrives in bursts of up to ~100 ms (AVAudioEngine taps, Continuity
    /// mics, ScreenCaptureKit). The old 120 ms ceiling cut 40 ms out of almost every burst and the lane
    /// then ran dry before the next one, so speech was chopped about ten times a second (robotic).
    private static func trimLanesToLiveHorizonLocked() {
        for role in streamRoles {
            let horizon = ProgramAudioJitter.horizon(for: role)
            guard var lane = lanes[role], lane.count > horizon.ceiling else { continue }
            let dropped = lane.count - horizon.keep
            lane.removeFirst(dropped)
            lanes[role] = lane
            ProgramAudioJitter.noteTrim(role: role, droppedSamples: dropped)
        }
    }

    private static var roomScratch: [Float] = []

    private static func dequeueMixedFrame() -> (stream: [Float], monitor: [Float], room: [Float])? {
        let gains = ProgramStreamAudioGates.gainSnapshot()
        lock.lock()
        trimLanesToLiveHorizonLocked()
        let take = accessUnitSamples
        var stream = [Float](repeating: 0, count: take)
        var monitor = [Float](repeating: 0, count: take)
        var contributed = false
        for role in streamRoles where role != .guest {
            guard var lane = lanes[role], !lane.isEmpty else {
                ProgramAudioJitter.noteEmpty(role: role)
                continue
            }
            // Wait for a small prefill after the lane ran dry so a bursty source plays smoothly
            // instead of alternating sound and zeros.
            guard ProgramAudioJitter.admit(role: role, depth: lane.count, take: take) else { continue }
            contributed = true
            let consume = min(lane.count, take)
            if consume < take {
                ProgramAudioJitter.noteUnderrun(role: role)
            }
            let known = gains.stream[role] != nil || gains.monitor[role] != nil
            let streamGain = known ? (gains.stream[role] ?? 0) : 1
            let monitorGain = known ? (gains.monitor[role] ?? 0) : 1
            for index in 0..<consume {
                let sample = Double(lane[index])
                stream[index] += Float(sample * streamGain)
                monitor[index] += Float(sample * monitorGain)
            }
            lane.removeFirst(consume)
            lanes[role] = lane
        }
        // Room return is mix-minus: everything except guests. Guests already hear each
        // other directly in LiveKit, so this stops them hearing themselves back.
        if roomScratch.count != take { roomScratch = [Float](repeating: 0, count: take) }
        for index in 0..<take { roomScratch[index] = stream[index] }
        let guest = GuestProgramMixBus.mix(interleavedCount: take)
        if guest.active {
            contributed = true
            for index in 0..<take {
                stream[index] += guest.stream[index]
                monitor[index] += guest.monitor[index]
            }
        }
        guard contributed else {
            lock.unlock()
            return nil
        }
        let master = gains.master
        let streamOut = stream.map { sample in
            Float(max(-1, min(1, Double(sample) * master)))
        }
        let monitorOut = monitor.map { sample in
            Float(max(-1, min(1, Double(sample) * master)))
        }
        let roomGain = Float(master)
        for index in 0..<take {
            roomScratch[index] = max(-1, min(1, roomScratch[index] * roomGain))
        }
        let room = roomScratch
        let depthLine = laneDepthSummaryUnlocked()
        lock.unlock()
        StreamAudioPipelineDiagnostics.updateLaneDepths(depthLine)
        return (streamOut, monitorOut, room)
    }

    private static func laneDepthSummaryUnlocked() -> String {
        let stereoFrames = ProgramStreamAudioClock.framesPerAccessUnit
        let parts = streamRoles.compactMap { role -> String? in
            guard let lane = lanes[role], !lane.isEmpty else { return nil }
            let frames = lane.count / 2
            return "\(role.shortDiagnosticLabel) \(frames)/\(stereoFrames)"
        }
        return parts.isEmpty ? "lanes empty" : parts.joined(separator: " ")
    }

    private static func encode(_ samples: [Float]) -> Data? {
        #if canImport(AudioToolbox)
        guard let converter = ensureConverter() else { return nil }
        let context = AACFillContext()
        context.samples = samples
        var packets: UInt32 = 1
        var packet = AudioStreamPacketDescription()
        var outSize: UInt32 = 2048
        var bytes = [UInt8](repeating: 0, count: Int(outSize))
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            var buffer = AudioBufferList.single(
                channels: 2,
                size: outSize,
                data: raw.baseAddress
            )
            return AudioConverterFillComplexBuffer(
                converter,
                AACFillContext.callback,
                Unmanaged.passUnretained(context).toOpaque(),
                &packets,
                &buffer,
                &packet
            )
        }
        guard status == noErr, packets > 0, packet.mDataByteSize > 0 else {
            if status != noErr {
                disposeConverter()
            }
            return nil
        }
        return Data(bytes.prefix(Int(packet.mDataByteSize)))
        #else
        return nil
        #endif
    }

    private static func disposeConverter() {
        #if canImport(AudioToolbox)
        if let converter {
            AudioConverterDispose(converter)
            self.converter = nil
        }
        #endif
    }

    @discardableResult
    private static func ensureConverter() -> AudioConverterRef? {
        #if canImport(AudioToolbox)
        if let converter { return converter }
        var input = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var created: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &created) == noErr, let created else { return nil }
        var bitrate = configuredAudioBitrateBps
        AudioConverterSetProperty(
            created,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )
        converter = created
        return created
        #else
        return nil
        #endif
    }
}

/// Encodes one 1024-sample AAC-LC silence frame so YouTube sees a valid audio track.
enum AACSilenceEncoder {
    private static let lock = NSLock()
    private static var cached: Data?

    static func frame() -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let encoded = encode() ?? Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C])
        cached = encoded
        return encoded
    }

    private static func encode() -> Data? {
        #if canImport(AudioToolbox)
        var input = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        defer { AudioConverterDispose(converter) }
        var bitrate: UInt32 = 128_000
        AudioConverterSetProperty(
            converter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &bitrate
        )
        let context = AACFillContext()
        var packets: UInt32 = 1
        var packet = AudioStreamPacketDescription()
        var outSize: UInt32 = 2048
        var bytes = [UInt8](repeating: 0, count: Int(outSize))
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            var buffer = AudioBufferList.single(
                channels: 2,
                size: outSize,
                data: raw.baseAddress
            )
            return AudioConverterFillComplexBuffer(
                converter,
                AACFillContext.callback,
                Unmanaged.passUnretained(context).toOpaque(),
                &packets,
                &buffer,
                &packet
            )
        }
        guard status == noErr, packets > 0, packet.mDataByteSize > 0 else { return nil }
        return Data(bytes.prefix(Int(packet.mDataByteSize)))
        #else
        return nil
        #endif
    }
}

extension RTMPStreamTransport {
    /// Explicit container frame rate for ingest / ffprobe (`avg_frame_rate` must match `r_frame_rate`).
    static func createOnMetaDataPayload(width: Int, height: Int, fps: Int, bitrateKbps: Int) -> Data {
        RTMPClient.createOnMetaDataPayload(
            width: width,
            height: height,
            fps: fps,
            videoBitrateKbps: bitrateKbps
        )
    }
}

#if canImport(AudioToolbox)
private final class AACFillContext {
    var samples = [Float](repeating: 0, count: 2048)
    var consumed = false

    static let callback: AudioConverterComplexInputDataProc = { _, packetCount, ioData, _, refcon in
        guard let refcon else { return -1 }
        let context = Unmanaged<AACFillContext>.fromOpaque(refcon).takeUnretainedValue()
        if context.consumed {
            packetCount.pointee = 0
            return noErr
        }
        context.consumed = true
        packetCount.pointee = 1024
        return context.samples.withUnsafeMutableBytes { raw in
            ioData.pointee = AudioBufferList.single(
                channels: 2,
                size: 1024 * 8,
                data: raw.baseAddress
            )
            return noErr
        }
    }
}

private extension AudioBufferList {
    static func single(channels: UInt32, size: UInt32, data: UnsafeMutableRawPointer?) -> AudioBufferList {
        AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: size, mData: data)
        )
    }
}
#endif

private extension AudioChannelRole {
    var shortDiagnosticLabel: String {
        switch self {
        case .microphone: "mic"
        case .desktop: "desk"
        case .guest: "guest"
        case .slide: "slide"
        case .soundboard: "pad"
        }
    }
}

/// Tracks whether a stream or recording encoder timer is draining the program mix.
enum ProgramEncoderAudioPump {
    private static let lock = NSLock()
    private static var lastTick: CFAbsoluteTime = 0

    static func noteTick() {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        lastTick = now
        lock.unlock()
    }

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return CFAbsoluteTimeGetCurrent() - lastTick < 0.15
    }
}


/// Jitter policy and counters for the program mix lanes. One lane per role, drained 1024 frames
/// per AAC access unit. Counters are cumulative and read by GET /v1/audio/pipeline.
enum ProgramAudioJitter {
    private static let lock = NSLock()
    private static var primed: Set<AudioChannelRole> = []
    private static var trims: [AudioChannelRole: Int] = [:]
    private static var trimmedSamples: [AudioChannelRole: Int] = [:]
    private static var underruns: [AudioChannelRole: Int] = [:]
    private static var waits: [AudioChannelRole: Int] = [:]

    /// `defaults write com.kaleel.proshow ProShowLegacyAudioHorizon -bool YES` restores the old
    /// 120/80 ms trim with no prefill (A/B checks only).
    static var legacy: Bool { UserDefaults.standard.bool(forKey: "ProShowLegacyAudioHorizon") }

    /// Interleaved stereo sample counts at 48 kHz.
    static func horizon(for role: AudioChannelRole) -> (ceiling: Int, keep: Int) {
        let ms: (Int, Int)
        if legacy {
            ms = (120, 80)
        } else {
            switch role {
            case .microphone, .desktop:
                ms = (320, 180)
            case .guest, .slide, .soundboard:
                ms = (200, 120)
            }
        }
        return (48_000 * 2 * ms.0 / 1000, 48_000 * 2 * ms.1 / 1000)
    }

    /// Prefill before a dry lane plays again (interleaved samples).
    static func prefill(for role: AudioChannelRole, take: Int) -> Int {
        if legacy { return 1 }
        switch role {
        case .microphone, .desktop:
            return max(take * 2, 48_000 * 2 * 45 / 1000)
        case .guest, .slide, .soundboard:
            return 1
        }
    }

    static func admit(role: AudioChannelRole, depth: Int, take: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if primed.contains(role) { return true }
        if depth >= prefill(for: role, take: take) {
            primed.insert(role)
            return true
        }
        waits[role, default: 0] += 1
        return false
    }

    static func noteEmpty(role: AudioChannelRole) {
        lock.lock()
        if primed.remove(role) != nil {
            underruns[role, default: 0] += 1
        }
        lock.unlock()
    }

    static func noteUnderrun(role: AudioChannelRole) {
        lock.lock()
        underruns[role, default: 0] += 1
        primed.remove(role)
        lock.unlock()
    }

    static func noteTrim(role: AudioChannelRole, droppedSamples: Int) {
        lock.lock()
        trims[role, default: 0] += 1
        trimmedSamples[role, default: 0] += droppedSamples
        lock.unlock()
    }

    static func reset(role: AudioChannelRole) {
        lock.lock()
        primed.remove(role)
        lock.unlock()
    }

    static func snapshot() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var roles: [String: Any] = [:]
        for role in [AudioChannelRole.microphone, .desktop, .guest, .slide, .soundboard] {
            roles[role.shortDiagnosticLabel] = [
                "trims": trims[role] ?? 0,
                "trimmedMs": (trimmedSamples[role] ?? 0) * 1000 / (48_000 * 2),
                "underruns": underruns[role] ?? 0,
                "prefillWaits": waits[role] ?? 0,
            ]
        }
        return ["legacyHorizon": legacy, "lanes": roles]
    }
}

/// Which capture sources are feeding each hardware role. Two sources on one role (camera mic plus
/// a mic shot, two screen shares with audio) used to be interleaved into one lane: the same voice
/// twice, a few ms apart, chopped by the trim. Only the first live source owns the role.
enum CaptureAudioSources {
    private static let lock = NSLock()
    private struct Entry { var frames: Int = 0; var since: CFAbsoluteTime; var last: CFAbsoluteTime; var rejected: Int = 0 }
    private static var entries: [AudioChannelRole: [String: Entry]] = [:]
    private static var owner: [AudioChannelRole: String] = [:]
    private static let stale: CFAbsoluteTime = 0.3

    /// True when `source` may feed `role`. A second source is refused while the owner is live.
    static func admit(role: AudioChannelRole, source: String, frames: Int) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        var map = entries[role] ?? [:]
        var entry = map[source] ?? Entry(since: now, last: now)
        if now - entry.last > 2 { entry = Entry(since: now, last: now) }
        entry.last = now
        var allowed = true
        if let current = owner[role], current != source,
           let held = map[current], now - held.last < stale {
            allowed = false
            entry.rejected += frames
        } else {
            owner[role] = source
            entry.frames += frames
        }
        map[source] = entry
        entries[role] = map
        return allowed
    }

    static func snapshot() -> [String: Any] {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        defer { lock.unlock() }
        var out: [String: Any] = [:]
        for (role, map) in entries {
            var sources: [[String: Any]] = []
            for (name, entry) in map where now - entry.last < 2 {
                let span = max(0.001, entry.last - entry.since)
                sources.append([
                    "source": name,
                    "owner": owner[role] == name,
                    "framesPerSecond": Int(Double(entry.frames) / span),
                    "rejectedFramesPerSecond": Int(Double(entry.rejected) / span),
                ])
            }
            out[role.shortDiagnosticLabel] = sources
        }
        return out
    }
}
