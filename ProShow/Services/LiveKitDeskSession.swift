import Foundation
import Observation
#if canImport(CoreVideo)
import CoreVideo
#endif

/// Desk-side LiveKit room. Guests show up as Assign Source rows. Frames land in `LivePixelHub`.
@MainActor
@Observable
final class LiveKitDeskBridge {
    var status = LiveKitDeskConfig.guestsOffStatus
    private(set) var hasStartedConnection = false
    var guests: [LiveKitGuestFeed] = []
    var roomSlug = ""
    var revision = 0
    var onGuests: (([LiveKitGuestFeed]) -> Void)?
    var onRoomActive: ((Bool) -> Void)?

    #if canImport(LiveKit)
    @ObservationIgnored private var session: LiveKitDeskSession?
    #endif

    func connect(roomSlug: String) {
        hasStartedConnection = true
        self.roomSlug = roomSlug
        guard let credentials = LiveKitDeskConfig.load() else {
            status = LiveKitDeskConfig.guestsOffStatus
            guests = []
            revision += 1
            onRoomActive?(false)
            onGuests?([])
            return
        }
        #if canImport(LiveKit)
        status = "Connecting"
        let next = LiveKitDeskSession(credentials: credentials, roomSlug: roomSlug)
        session = next
        next.onGuests = { [weak self] feeds in
            guard let self else { return }
            self.guests = feeds
            self.revision += 1
            self.onGuests?(feeds)
        }
        next.onStatus = { [weak self] text in
            self?.status = text
            let active = text.localizedCaseInsensitiveContains("in room")
            self?.onRoomActive?(active)
        }
        Task { await next.start() }
        #else
        status = "LiveKit SDK is not linked."
        #endif
    }

    func pushProgramFrame(_ buffer: CVPixelBuffer) {
        #if canImport(LiveKit)
        session?.pushProgramFrame(buffer)
        #endif
    }

    func publishProgram(_ identities: [String]) {
        #if canImport(LiveKit)
        session?.publishProgram(identities)
        #endif
    }

    func removeGuest(identity: String) {
        #if canImport(LiveKit)
        session?.removeGuest(identity: identity)
        #endif
    }

    func setGuestMicrophoneMuted(identity: String, muted: Bool) {
        #if canImport(LiveKit)
        session?.setGuestMicrophoneMuted(identity: identity, muted: muted)
        #endif
    }

    func setGuestVideoSuppressed(identity: String, suppressed: Bool) {
        #if canImport(LiveKit)
        session?.setGuestVideoSuppressed(identity: identity, suppressed: suppressed)
        #endif
    }

    func discoveredItems() -> [DiscoveredSourceItem] {
        LiveKitGuestCatalog.items(room: roomSlug, guests: guests)
    }
}

#if canImport(LiveKit)
import Accelerate
import AVFoundation
import LiveKit

@MainActor
final class LiveKitDeskSession: NSObject, RoomDelegate {
    let credentials: LiveKitDeskCredentials
    let roomSlug: String
    var onGuests: (([LiveKitGuestFeed]) -> Void)?
    var onStatus: ((String) -> Void)?

    private var room: Room?
    private var sinks: [String: GuestVideoSink] = [:]
    private var audioSinks: [String: GuestAudioSink] = [:]
    private var guestAudio: [String: RemoteAudioTrack] = [:]
    private var mutedGuests: Set<String> = []
    private var hiddenVideoGuests: Set<String> = []
    private var programIdentities: [String] = []
    private var tallySeq = 0
    private var admitInFlight: Set<String> = []
    private let programPump = ProgramFramePump()
    private var programTrack: LocalVideoTrack?

    init(credentials: LiveKitDeskCredentials, roomSlug: String) {
        self.credentials = credentials
        self.roomSlug = roomSlug
    }

    func start() async {
        let token = LiveKitAccessToken.jwt(
            apiKey: credentials.apiKey,
            apiSecret: credentials.apiSecret,
            identity: "proshow-desk",
            name: "ProShow Desk",
            room: roomSlug,
            canPublish: true,
            canSubscribe: true,
            canPublishData: true,
            attributes: ["ps.role": "desk", "ps.session": "idle"]
        )
        let room = Room(delegate: self)
        self.room = room
        AudioManager.shared.isVoiceProcessingBypassed = true
        do {
            try await room.connect(
                url: credentials.url,
                token: token,
                roomOptions: RoomOptions(adaptiveStream: false, dynacast: false)
            )
            onStatus?("In room")
            await publishProgramReturn(on: room)
            for participant in room.remoteParticipants.values {
                await considerAdmit(participant)
                attachExisting(participant)
            }
            publishGuestList()
        } catch {
            onStatus?("Could not join the room.")
        }
    }

    func pushProgramFrame(_ buffer: CVPixelBuffer) {
        programPump.push(buffer)
    }

    private func publishProgramReturn(on room: Room) async {
        let track = await LocalVideoTrack.createBufferTrack(
            name: "program",
            source: .camera,
            options: BufferCaptureOptions(dimensions: .h720_169, fps: 24)
        )
        guard let capturer = track.capturer as? BufferCapturer else { return }
        programPump.bind(capturer)
        programPump.captureSeed()
        let sized = Date().addingTimeInterval(1.5)
        while capturer.dimensions == nil, Date() < sized {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        programTrack = track
        AudioManager.shared.isVoiceProcessingBypassed = true
        let mix = ProgramMixInjector.shared
        AudioManager.shared.capturePostProcessingDelegate = mix
        ProgramPCMBridge.programMixListener = { samples in
            mix.pushInterleavedStereo(samples)
        }
        let audio = await LocalAudioTrack.createTrack(
            name: "program-audio",
            options: AudioCaptureOptions.noProcessing
        )
        do {
            _ = try await room.localParticipant.publish(
                videoTrack: track,
                options: VideoPublishOptions(
                    encoding: VideoEncoding(maxBitrate: 2_500_000, maxFps: 24),
                    simulcast: false,
                    degradationPreference: .maintainFramerateAndResolution
                )
            )
            _ = try await room.localParticipant.publish(
                audioTrack: audio,
                options: AudioPublishOptions(
                    encoding: .presetMusicHighQualityStereo,
                    dtx: false,
                    red: false
                )
            )
            let mixer = AudioManager.shared.mixer
            mixer.micVolume = 0
            mixer.appVolume = 0
            mixer.outputVolume = 1
            programPump.resume()
            try? await room.localParticipant.set(attributes: [
                "ps.role": "desk",
                "ps.programTrack": "1",
                "ps.session": "idle",
            ])
        } catch {
            onStatus?("In room. Program return failed.")
        }
    }

    func removeGuest(identity: String) {
        Task {
            await LiveKitRoomAdmin.remove(credentials: credentials, room: roomSlug, identity: identity)
        }
    }

    func setGuestMicrophoneMuted(identity: String, muted: Bool) {
        if muted {
            mutedGuests.insert(identity)
        } else {
            mutedGuests.remove(identity)
        }
        guestAudio[identity]?.volume = muted ? 0 : 1
        audioSinks[identity]?.suppressed = muted
        if muted {
            GuestProgramMixBus.remove(id: LiveKitGuestEndpoint.stableID(identity))
        }
    }

    func setGuestVideoSuppressed(identity: String, suppressed: Bool) {
        if suppressed {
            hiddenVideoGuests.insert(identity)
        } else {
            hiddenVideoGuests.remove(identity)
        }
        sinks[identity + ":camera"]?.suppressed = suppressed
        sinks[identity + ":screen"]?.suppressed = suppressed
    }

    func publishProgram(_ identities: [String]) {
        guard identities != programIdentities else { return }
        programIdentities = identities
        tallySeq += 1
        let seq = tallySeq
        let joined = identities.joined(separator: ",")
        let session = identities.isEmpty ? "idle" : "live"
        let packet: [String: Any] = ["program": identities, "seq": seq]
        guard let room, let data = try? JSONSerialization.data(withJSONObject: packet) else { return }
        Task {
            try? await room.localParticipant.set(attributes: [
                "ps.program": joined,
                "ps.session": session,
                "ps.role": "desk",
                "ps.programTrack": "1",
            ])
            try? await room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(topic: "ps.tally", reliable: true)
            )
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            await considerAdmit(participant)
            publishGuestList()
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            let identity = participant.identity?.stringValue ?? ""
            sinks[identity + ":camera"] = nil
            sinks[identity + ":screen"] = nil
            audioSinks[identity] = nil
            guestAudio[identity] = nil
            publishGuestList()
        }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didSubscribeTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor in
            attach(publication: publication, participant: participant)
            publishGuestList()
        }
    }

    nonisolated func room(
        _ room: Room,
        participant: RemoteParticipant,
        didUnsubscribeTrack publication: RemoteTrackPublication
    ) {
        Task { @MainActor in
            detach(publication: publication, participant: participant)
            publishGuestList()
        }
    }

    private func considerAdmit(_ participant: RemoteParticipant) async {
        let identity = participant.identity?.stringValue ?? ""
        guard !identity.isEmpty else { return }
        let role = participant.attributes["ps.role"] ?? "guest"
        guard role != "desk" else { return }
        guard participant.permissions.canPublish == false else { return }
        guard admitInFlight.insert(identity).inserted else { return }
        defer { admitInFlight.remove(identity) }
        await LiveKitRoomAdmin.admit(credentials: credentials, room: roomSlug, identity: identity)
    }

    private func attachExisting(_ participant: RemoteParticipant) {
        for publication in participant.trackPublications.values {
            guard let remote = publication as? RemoteTrackPublication else { continue }
            attach(publication: remote, participant: participant)
        }
    }

    private func attach(publication: RemoteTrackPublication, participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        guard !identity.isEmpty, participant.attributes["ps.role"] != "desk" else { return }
        switch publication.source {
        case .camera:
            guard let video = publication.track as? VideoTrack else { return }
            let key = identity + ":camera"
            let sink = GuestVideoSink(
                endpoint: LiveKitGuestEndpoint.camera(room: roomSlug, identity: identity),
                sourceID: LiveKitGuestEndpoint.stableID(identity).uuidString
            )
            sink.suppressed = hiddenVideoGuests.contains(identity)
            sinks[key] = sink
            video.add(videoRenderer: sink)
        case .screenShareVideo:
            guard let video = publication.track as? VideoTrack else { return }
            let key = identity + ":screen"
            let sink = GuestVideoSink(
                endpoint: LiveKitGuestEndpoint.screen(room: roomSlug, identity: identity),
                sourceID: LiveKitGuestEndpoint.stableID(identity + ":screen").uuidString
            )
            sink.suppressed = hiddenVideoGuests.contains(identity)
            sinks[key] = sink
            video.add(videoRenderer: sink)
        case .microphone:
            guard let audio = publication.track as? RemoteAudioTrack else { return }
            let sink = GuestAudioSink(guestID: LiveKitGuestEndpoint.stableID(identity))
            sink.suppressed = mutedGuests.contains(identity)
            audioSinks[identity] = sink
            guestAudio[identity] = audio
            audio.volume = mutedGuests.contains(identity) ? 0 : 1
            audio.add(audioRenderer: sink)
        default:
            break
        }
    }

    private func detach(publication: RemoteTrackPublication, participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? ""
        switch publication.source {
        case .camera:
            if let sink = sinks.removeValue(forKey: identity + ":camera"),
               let video = publication.track as? VideoTrack {
                video.remove(videoRenderer: sink)
            }
        case .screenShareVideo:
            if let sink = sinks.removeValue(forKey: identity + ":screen"),
               let video = publication.track as? VideoTrack {
                video.remove(videoRenderer: sink)
            }
        case .microphone:
            guestAudio[identity] = nil
            if let sink = audioSinks.removeValue(forKey: identity),
               let audio = publication.track as? RemoteAudioTrack {
                audio.remove(audioRenderer: sink)
                GuestProgramMixBus.remove(id: sink.guestID)
            }
        default:
            break
        }
    }

    private func publishGuestList() {
        guard let room else { return }
        let feeds: [LiveKitGuestFeed] = room.remoteParticipants.values.compactMap { participant in
            let identity = participant.identity?.stringValue ?? ""
            guard !identity.isEmpty, participant.attributes["ps.role"] != "desk" else { return nil }
            let sources = participant.trackPublications.values.map(\.source)
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return LiveKitGuestFeed(
                identity: identity,
                name: (name?.isEmpty == false ? name! : identity),
                hasCamera: sources.contains(.camera) || true,
                hasScreen: sources.contains(.screenShareVideo),
                hasMic: sources.contains(.microphone)
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onGuests?(feeds)
        if feeds.isEmpty {
            onStatus?("In room. Waiting for guests.")
        } else {
            onStatus?("\(feeds.count) in room")
        }
    }
}

final class ProgramFramePump: @unchecked Sendable {
    private let lock = NSLock()
    private var capturer: BufferCapturer?

    func bind(_ capturer: BufferCapturer) {
        lock.lock()
        self.capturer = capturer
        armed = false
        lock.unlock()
    }

    /// One frame so publish can read the picture size. Further frames wait until `resume()`.
    func captureSeed() {
        lock.lock()
        let capturer = capturer
        lock.unlock()
        guard let capturer, let seed = Self.opaque720() else { return }
        capturer.capture(seed)
    }

    func resume() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func push(_ buffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard armed else {
            lock.unlock()
            return
        }
        if now - lastPush < (1.0 / 24.0) || captureBusy {
            lock.unlock()
            return
        }
        lastPush = now
        captureBusy = true
        let capturer = capturer
        lock.unlock()
        guard let capturer else {
            lock.lock()
            captureBusy = false
            lock.unlock()
            return
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 16, height > 16 else {
            lock.lock()
            captureBusy = false
            lock.unlock()
            return
        }
        guard let fitted = Self.fit720(buffer) else {
            lock.lock()
            captureBusy = false
            lock.unlock()
            return
        }
        Self.captureQueue.async { [weak self] in
            capturer.capture(fitted)
            self?.lock.lock()
            self?.captureBusy = false
            self?.lock.unlock()
        }
    }

    private var armed = false
    private var captureBusy = false

    private static let captureQueue = DispatchQueue(label: "proshow.livekit.program", qos: .userInitiated)

    private static func opaque720() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            1280,
            720,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * 720)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// One 1280×720 picture so the encoder never changes size. A size change shows up as a blink on the guest page.
    private static func fit720(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(source)
        let sh = CVPixelBufferGetHeight(source)
        guard sw > 0, sh > 0, CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        if sw == 1280, sh == 720 { return copy(source) }
        let scale = min(1280.0 / Double(sw), 720.0 / Double(sh))
        let dw = max(2, Int((Double(sw) * scale).rounded(.down)) & ~1)
        let dh = max(2, Int((Double(sh) * scale).rounded(.down)) & ~1)
        let fillsFrame = dw == 1280 && dh == 720
        guard let scaled = make(width: dw, height: dh, format: kCVPixelFormatType_32BGRA) else { return nil }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        guard CVPixelBufferLockBaseAddress(scaled, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            return nil
        }
        var src = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(source),
            height: vImagePixelCount(sh),
            width: vImagePixelCount(sw),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var mid = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(scaled),
            height: vImagePixelCount(dh),
            width: vImagePixelCount(dw),
            rowBytes: CVPixelBufferGetBytesPerRow(scaled)
        )
        let error = vImageScale_ARGB8888(&src, &mid, nil, vImage_Flags(kvImageHighQualityResampling))
        CVPixelBufferUnlockBaseAddress(scaled, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
        guard error == kvImageNoError else { return nil }
        if fillsFrame { return scaled }
        guard let dest = make(width: 1280, height: 720, format: kCVPixelFormatType_32BGRA) else { return nil }
        guard CVPixelBufferLockBaseAddress(scaled, .readOnly) == kCVReturnSuccess else { return nil }
        guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess,
              let midBase = CVPixelBufferGetBaseAddress(scaled),
              let dstBase = CVPixelBufferGetBaseAddress(dest) else {
            CVPixelBufferUnlockBaseAddress(scaled, .readOnly)
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(scaled, .readOnly)
        }
        memset(dstBase, 0, CVPixelBufferGetBytesPerRow(dest) * 720)
        let originX = (1280 - dw) / 2
        let originY = (720 - dh) / 2
        let midStride = CVPixelBufferGetBytesPerRow(scaled)
        let dstStride = CVPixelBufferGetBytesPerRow(dest)
        for row in 0..<dh {
            dstBase.advanced(by: (originY + row) * dstStride + originX * 4).copyMemory(
                from: midBase.advanced(by: row * midStride),
                byteCount: dw * 4
            )
        }
        return dest
    }

    private var lastPush: CFAbsoluteTime = 0

    /// WebRTC keeps the buffer, so this is a pooled 720 copy, not the program frame.
    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        guard let dest = make(width: width, height: height, format: format) else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planes = CVPixelBufferGetPlaneCount(source)
        if planes == 0 {
            guard let src = CVPixelBufferGetBaseAddress(source),
                  let dst = CVPixelBufferGetBaseAddress(dest) else { return nil }
            let srcRow = CVPixelBufferGetBytesPerRow(source)
            let dstRow = CVPixelBufferGetBytesPerRow(dest)
            let row = min(srcRow, dstRow)
            for y in 0..<height {
                memcpy(dst.advanced(by: y * dstRow), src.advanced(by: y * srcRow), row)
            }
        } else {
            for plane in 0..<planes {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else { continue }
                let srcRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstRow = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let row = min(srcRow, dstRow)
                for y in 0..<planeHeight {
                    memcpy(dst.advanced(by: y * dstRow), src.advanced(by: y * srcRow), row)
                }
            }
        }
        return dest
    }

    private static func make(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        guard format == kCVPixelFormatType_32BGRA else { return nil }
        return ProgramFramePool.take(width: width, height: height)
    }
}

final class ProgramMixInjector: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    static let shared = ProgramMixInjector()

    private let lock = NSLock()
    private var pending: [Float] = []
    private var captureRate: Double = 48_000
    private let capacity = 48_000 * 2

    func pushInterleavedStereo(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: samples)
        if pending.count > capacity {
            pending.removeFirst(pending.count - capacity)
        }
        lock.unlock()
    }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        _ = channels
        lock.lock()
        if sampleRateHz >= 8_000 {
            captureRate = Double(sampleRateHz)
        }
        lock.unlock()
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        let frames = audioBuffer.frames
        let channelCount = audioBuffer.channels
        guard frames > 0, channelCount > 0 else { return }
        lock.lock()
        let rate = captureRate
        let needed = max(1, Int((Double(frames) * 48_000 / rate).rounded(.up)))
        let available = pending.count / 2
        let take = min(needed + 1, available)
        let chunk = Array(pending.prefix(take * 2))
        let consume = min(needed, available)
        if consume > 0 {
            pending.removeFirst(consume * 2)
        }
        lock.unlock()

        let step = 48_000 / rate
        for channel in 0..<channelCount {
            let destination = audioBuffer.rawBuffer(forChannel: channel)
            var position = 0.0
            for frame in 0..<frames {
                let index = Int(position)
                let fraction = Float(position - Double(index))
                if index + 1 < take {
                    let left = chunk[index * 2] + (chunk[(index + 1) * 2] - chunk[index * 2]) * fraction
                    let right = chunk[index * 2 + 1] + (chunk[(index + 1) * 2 + 1] - chunk[index * 2 + 1]) * fraction
                    destination[frame] = channelCount == 1 ? (left + right) * 0.5 : (channel == 0 ? left : right)
                } else {
                    destination[frame] = 0
                }
                position += step
            }
        }
    }

    func audioProcessingRelease() {}
}

final class GuestVideoSink: NSObject, VideoRenderer, @unchecked Sendable {
    let endpoint: String
    let sourceID: String
    var suppressed = false

    init(endpoint: String, sourceID: String) {
        self.endpoint = endpoint
        self.sourceID = sourceID
    }

    var isAdaptiveStreamEnabled: Bool { true }
    var adaptiveStreamSize: CGSize { CGSize(width: 1280, height: 720) }

    func render(frame: VideoFrame) {
        #if canImport(CoreVideo)
        let pixel: CVPixelBuffer?
        if let cv = frame.buffer as? CVPixelVideoBuffer {
            pixel = cv.pixelBuffer
        } else if let i420 = frame.buffer as? I420VideoBuffer {
            pixel = i420.toPixelBuffer()
        } else {
            pixel = nil
        }
        guard !suppressed, let pixel else { return }
        let owned = ProgramOutputComposer.snapshot(pixel)
        guard owned !== pixel else { return }
        LivePixelHub.shared.publish(endpoint: endpoint, sourceID: sourceID, buffer: owned)
        #endif
    }
}

final class GuestAudioSink: NSObject, AudioRenderer, @unchecked Sendable {
    let guestID: UUID
    var suppressed = false

    init(guestID: UUID) {
        self.guestID = guestID
    }

    func render(pcmBuffer: AVAudioPCMBuffer) {
        let mono = Self.mono(from: pcmBuffer)
        let stereo = Self.peaks(mono)
        GuestAudioLevels.note(guestID: guestID, left: stereo.left, right: stereo.right)
        guard !suppressed, !mono.isEmpty else { return }
        GuestProgramMixBus.push(id: guestID, mono: mono, sampleRate: pcmBuffer.format.sampleRate)
    }

    private static func mono(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        if let data = buffer.floatChannelData {
            if buffer.format.channelCount > 1, buffer.format.isInterleaved == false {
                let left = data[0]
                let right = data[1]
                var out = [Float](repeating: 0, count: count)
                for index in 0..<count {
                    out[index] = (left[index] + right[index]) * 0.5
                }
                return out
            }
            return Array(UnsafeBufferPointer(start: data[0], count: count))
        }
        if let data = buffer.int16ChannelData {
            let samples = data[0]
            var out = [Float](repeating: 0, count: count)
            let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
            for index in 0..<count {
                out[index] = Float(samples[index * stride]) / 32768
            }
            return out
        }
        return []
    }

    private static func peaks(_ mono: [Float]) -> (left: Double, right: Double) {
        var peak: Float = 0
        for sample in mono {
            peak = max(peak, abs(sample))
        }
        if peak <= 0.0001 { return (-120, -120) }
        let db = Double(20 * log10(peak))
        return (db, db)
    }
}

enum LiveKitRoomAdmin {
    static func admit(credentials: LiveKitDeskCredentials, room: String, identity: String) async {
        let token = LiveKitAccessToken.jwt(
            apiKey: credentials.apiKey,
            apiSecret: credentials.apiSecret,
            identity: "proshow-desk-admin",
            name: "ProShow Desk",
            room: room,
            roomAdmin: true,
            attributes: ["ps.role": "desk"]
        )
        guard let url = URL(string: "\(credentials.httpOrigin)/twirp/livekit.RoomService/UpdateParticipant") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "room": room,
            "identity": identity,
            "permission": [
                "canSubscribe": true,
                "canPublish": true,
                "canPublishData": true,
            ],
            "attributes": [
                "ps.state": "admitted",
                "ps.role": "guest",
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    static func remove(credentials: LiveKitDeskCredentials, room: String, identity: String) async {
        let token = LiveKitAccessToken.jwt(
            apiKey: credentials.apiKey,
            apiSecret: credentials.apiSecret,
            identity: "proshow-desk-admin",
            name: "ProShow Desk",
            room: room,
            roomAdmin: true,
            attributes: ["ps.role": "desk"]
        )
        guard let url = URL(string: "\(credentials.httpOrigin)/twirp/livekit.RoomService/RemoveParticipant") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["room": room, "identity": identity]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
#endif
