import Foundation

// On-Air Audio, phase 1: visibility only.
// Everything here reads state that already exists (layers, mixer channels, gate flags,
// capture owners, guest peaks, the program mix frame the monitor already receives).
// Nothing here changes what is summed, and nothing runs on a capture or encode thread.

enum OnAirAudioSourceType: String, Codable, Sendable {
    case mic, camera, desktop, slide, guest, soundboard, network

    var systemImage: String {
        switch self {
        case .mic: "mic.fill"
        case .camera: "video.fill"
        case .desktop: "display"
        case .slide: "play.rectangle.fill"
        case .guest: "person.wave.2.fill"
        case .soundboard: "square.grid.3x3.fill"
        case .network: "network"
        }
    }

    var label: String {
        switch self {
        case .mic: "Mic"
        case .camera: "Camera"
        case .desktop: "Screen"
        case .slide: "Slide"
        case .guest: "Room guest"
        case .soundboard: "Soundboard"
        case .network: "NDI/SRT"
        }
    }
}

enum OnAirAudioState: String, Codable, Sendable {
    case live
    case armed
    case held
    case muted
    case notRouted = "not_routed"
    case noSignal = "no_signal"
    case soloOff = "solo_off"

    var chip: String {
        switch self {
        case .live: "LIVE"
        case .armed: "ARMED"
        case .held: "HELD"
        case .muted: "MUTED"
        case .notRouted: "NOT ROUTED"
        case .noSignal: "NO SIGNAL"
        case .soloOff: "SOLO OFF"
        }
    }
}

enum OnAirAudioJump: Hashable, Sendable {
    case layer(Int)
    case slide
    case room
    case audioTab
}

/// One-click fix offered on a row that is not heard.
enum OnAirAudioFix: Hashable, Sendable {
    /// Turn on the live camera's own mic (the shot's audio was off).
    case useCameraMic(layer: Int, shotID: UUID)
    /// No mic found for this camera: add a mic shot on a free layer and take it live.
    case addMic

    var title: String {
        switch self {
        case .useCameraMic: "Use Camera Mic"
        case .addMic: "Add Mic"
        }
    }

    var key: String {
        switch self {
        case .useCameraMic: "use_camera_mic"
        case .addMic: "add_mic"
        }
    }
}

struct OnAirAudioSource: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var type: OnAirAudioSourceType
    /// Short origin tag: L2 = Live sources layer 2, S = live slide, Room, SB = soundboard.
    var origin: String
    var state: OnAirAudioState
    /// First failing check, one line. Nil while on air.
    var reason: String?
    var peakDb: Double
    var jump: OnAirAudioJump
    var simulated = false
    /// Where the sound actually comes from when it is not the row's own device (camera mic).
    var via: String?
    var fix: OnAirAudioFix?

    var isOnAir: Bool { state == .live }

    var jsonObject: [String: Any] {
        [
            "id": id,
            "name": name,
            "type": type.rawValue,
            "origin": origin,
            "state": state.rawValue,
            "on_air": isOnAir,
            "reason": reason ?? NSNull(),
            "peak_db": (peakDb * 10).rounded() / 10,
            "simulated": simulated,
            "via": via ?? NSNull(),
            "fix": fix?.key ?? NSNull(),
        ]
    }
}

enum OnAirAudioAlertKind: String, Codable, Sendable {
    case solo, clipping, silence, doubled, micMode
}

struct OnAirAudioAlert: Identifiable, Hashable, Sendable {
    var kind: OnAirAudioAlertKind
    var message: String
    var id: String { kind.rawValue }
}

/// Snapshot of the inputs the resolver needs. Built on the main actor from existing state.
struct OnAirAudioInputs: Sendable {
    struct SlideAudio: Sendable {
        var name: String
        /// Same chain as `ShowController.isProgramMediaMuted`, first failing condition.
        var blockReason: String?
        var peakDb: Double
    }

    struct Guest: Sendable {
        var identity: String
        var name: String
        var guestID: UUID
        var hasMic: Bool
        var peakDb: Double?
        var simulated = false
    }

    var layers: [MasterLayer] = []
    var channels: [AudioMatrixChannel] = []
    var programMuted = false
    var captureOpen: Set<AudioChannelRole> = [.microphone, .desktop, .guest, .slide, .soundboard]
    /// Capture source key that owns the mic role right now ("system-input" or a device endpoint).
    var micOwner: String?
    var desktopHeldByMic = false
    var slide: SlideAudio?
    var guests: [Guest] = []
    var soundboardPlaying = false
    /// Live camera shot id to the mic it brings (camera audio on, a mic found).
    var cameraMics: [UUID: String] = [:]
    /// Camera shot ids that are live but have no mic at all.
    var camerasWithoutMic: Set<UUID> = []
    /// Seconds a source has been under the signal floor while its path is open (keyed by source id).
    var silentSeconds: [String: TimeInterval] = [:]
}

enum OnAirAudioResolver {
    static let noSignalAfter: TimeInterval = 10
    static let signalFloorDb: Double = -70

    static func resolve(_ input: OnAirAudioInputs) -> [OnAirAudioSource] {
        var rows: [OnAirAudioSource] = []
        let liveMicKeys: [String] = input.layers.compactMap { layer in
            guard let shot = liveShot(layer), shot.source.sourceType == .systemMicrophone, !shot.isAudioMuted
            else { return nil }
            return micKey(shot)
        }
        for (index, layer) in input.layers.enumerated() {
            let tag = "L\(index + 1)"
            let live = liveShot(layer)
            for shot in layer.shots {
                let isLive = shot.id == live?.id
                guard let row = row(for: shot, live: isLive, layerIndex: index, tag: tag, input: input, liveMicKeys: liveMicKeys)
                else { continue }
                rows.append(row)
            }
        }
        if let slide = input.slide {
            let id = "slide"
            var row = OnAirAudioSource(
                id: id, name: slide.name, type: .slide, origin: "S",
                state: .live, reason: nil, peakDb: slide.peakDb, jump: .slide
            )
            if let block = slide.blockReason {
                row.state = .muted
                row.reason = "Slide audio off: \(block)"
            } else if let block = channelBlock(role: .slide, guestID: nil, input: input) {
                row.state = block.state
                row.reason = block.reason
            }
            rows.append(row)
        }
        if input.soundboardPlaying {
            var row = OnAirAudioSource(
                id: "soundboard", name: "Soundboard", type: .soundboard, origin: "SB",
                state: .live, reason: nil, peakDb: channel(.soundboard, input)?.peak ?? -120, jump: .audioTab
            )
            if let block = channelBlock(role: .soundboard, guestID: nil, input: input) {
                row.state = block.state
                row.reason = block.reason
            }
            rows.append(row)
        }
        for guest in input.guests {
            var row = OnAirAudioSource(
                id: "guest:\(guest.identity)", name: guest.name, type: .guest, origin: "Room",
                state: .live, reason: nil, peakDb: guest.peakDb ?? -120, jump: .room, simulated: guest.simulated
            )
            if !guest.hasMic {
                row.state = .notRouted
                row.reason = "No mic published from the room"
            } else if let block = channelBlock(role: .guest, guestID: guest.guestID, input: input) {
                row.state = block.state
                row.reason = block.reason
            }
            rows.append(row)
        }
        return rows
    }

    /// Ordered checks shared by every source that goes through a mixer channel.
    static func channelBlock(role: AudioChannelRole, guestID: UUID?, input: OnAirAudioInputs) -> (state: OnAirAudioState, reason: String)? {
        if input.programMuted { return (.muted, "Program audio is muted") }
        let strip: AudioMatrixChannel?
        if let guestID {
            strip = input.channels.first { $0.linkedGuestID == guestID }
        } else {
            strip = channel(role, input)
        }
        guard let strip else {
            // Guests without a strip still mix at unity; other roles need a strip.
            return guestID == nil ? (.notRouted, "No mixer channel") : nil
        }
        if strip.muted {
            return (.muted, guestID == nil ? "Muted on the \(strip.name) channel" : "Muted by the desk")
        }
        if !(strip.bus == .all || strip.bus == .both || strip.bus == .stream) {
            return (.notRouted, "\(strip.name) channel is not sent to the stream")
        }
        let soloed = input.channels.filter(\.solo)
        if !soloed.isEmpty, !strip.solo {
            return (.soloOff, "Silenced by solo on \(soloed.map(\.name).joined(separator: ", "))")
        }
        if !input.captureOpen.contains(role) {
            return (.notRouted, "\(strip.name) gate is closed")
        }
        return nil
    }

    static func alerts(
        sources: [OnAirAudioSource],
        channels: [AudioMatrixChannel],
        capture: [AudioChannelRole: [String]],
        programSilentSeconds: TimeInterval,
        isLive: Bool,
        clippedRecently: Bool
    ) -> [OnAirAudioAlert] {
        var out: [OnAirAudioAlert] = []
        let soloed = channels.filter(\.solo).map(\.name)
        if !soloed.isEmpty {
            out.append(OnAirAudioAlert(kind: .solo, message: "Solo on \(soloed.joined(separator: ", ")). Other audio is silent."))
        }
        if clippedRecently {
            out.append(OnAirAudioAlert(kind: .clipping, message: "Program is clipping. Lower the loudest source."))
        }
        if isLive, programSilentSeconds >= 5 {
            out.append(OnAirAudioAlert(kind: .silence, message: "Program silent for \(Int(programSilentSeconds)) s."))
        }
        var doubled: [String] = []
        for (role, keys) in capture where Set(keys).count > 1 {
            doubled.append(role == .microphone ? "two mics" : "two screen sources")
        }
        let liveMics = sources.filter { $0.type == .mic && ($0.state == .live || $0.state == .armed) }
        if liveMics.count > 1, !doubled.contains("two mics") {
            doubled.append("two mics")
        }
        if !doubled.isEmpty {
            out.append(OnAirAudioAlert(kind: .doubled, message: "Doubled source: \(doubled.joined(separator: ", ")) live. Only one is heard."))
        }
        return out
    }

    // MARK: Rows

    private static func row(
        for shot: LayerShot,
        live: Bool,
        layerIndex: Int,
        tag: String,
        input: OnAirAudioInputs,
        liveMicKeys: [String]
    ) -> OnAirAudioSource? {
        let type: OnAirAudioSourceType
        switch shot.source.sourceType {
        case .systemMicrophone: type = .mic
        case .systemDisplay, .systemWindow, .systemAudioCapture: type = .desktop
        case .systemCamera, .rendezvousGuest: type = .camera
        case .ndiSource, .srtStream: type = .network
        default: return nil
        }
        var row = OnAirAudioSource(
            id: "shot:\(shot.id.uuidString)", name: shot.name, type: type, origin: tag,
            state: .live, reason: nil, peakDb: -120, jump: .layer(layerIndex)
        )
        guard live else {
            // Only sources whose job is audio get a "not taken" row; idle cameras and screens are noise.
            guard type == .mic || shot.source.sourceType == .systemAudioCapture else { return nil }
            row.state = .notRouted
            row.reason = "Not live: shot added, not taken"
            return row
        }
        switch type {
        case .camera:
            if shot.source.sourceType == .rendezvousGuest {
                row.state = .notRouted
                row.reason = "Picture only. Room audio is on the guest row"
                return row
            }
            return cameraRow(row, shot: shot, layerIndex: layerIndex, input: input, liveMicKeys: liveMicKeys)
        case .network:
            row.state = .notRouted
            row.reason = "No audio path for NDI/SRT yet"
            return row
        default:
            break
        }
        let role: AudioChannelRole = type == .mic ? .microphone : .desktop
        row.peakDb = channel(role, input)?.peak ?? -120
        if shot.isAudioMuted {
            row.state = .muted
            row.reason = "Muted on this layer"
            return row
        }
        if let block = channelBlock(role: role, guestID: nil, input: input) {
            row.state = block.state
            row.reason = block.reason
            return row
        }
        if type == .mic, liveMicKeys.count > 1 {
            let key = micKey(shot)
            let owner = input.micOwner ?? liveMicKeys.first
            if let owner, owner != key {
                row.state = .armed
                row.reason = "Second mic: \(ownerName(owner, input)) owns the mic"
                row.peakDb = -120
                return row
            }
        }
        if type == .desktop, input.desktopHeldByMic {
            row.state = .held
            row.reason = "Held: the mic owns the mix"
            return row
        }
        if (input.silentSeconds[row.id] ?? 0) >= noSignalAfter {
            row.state = .noSignal
            row.reason = "No signal for \(Int(noSignalAfter)) s"
        }
        return row
    }

    /// A camera's picture never carries sound. Its own mic (built-in, Continuity) feeds the
    /// single mic lane when the shot's audio is on and no mic shot is live.
    private static func cameraRow(
        _ base: OnAirAudioSource,
        shot: LayerShot,
        layerIndex: Int,
        input: OnAirAudioInputs,
        liveMicKeys: [String]
    ) -> OnAirAudioSource {
        var row = base
        if !liveMicKeys.isEmpty {
            row.state = .armed
            let owner = ownerName(input.micOwner ?? liveMicKeys[0], input)
            row.reason = owner == "Another mic" ? "Picture only. A mic shot owns the mic" : "Picture only. The \(owner) shot owns the mic"
            return row
        }
        guard let micName = input.cameraMics[shot.id] else {
            row.state = .notRouted
            if shot.isAudioMuted, !input.camerasWithoutMic.contains(shot.id) {
                row.state = .muted
                row.reason = "Camera mic is off on this layer"
                row.fix = .useCameraMic(layer: layerIndex, shotID: shot.id)
            } else {
                row.reason = "Picture only. No mic found for this camera"
                row.fix = .addMic
            }
            return row
        }
        row.via = micName
        let owner = cameraMicOwner(input)
        if let owner, owner != shot.id {
            row.state = .armed
            row.reason = "Picture only. Another camera's mic is on air"
            return row
        }
        row.peakDb = channel(.microphone, input)?.peak ?? -120
        if let block = channelBlock(role: .microphone, guestID: nil, input: input) {
            row.state = block.state
            row.reason = block.reason
            return row
        }
        if (input.silentSeconds[row.id] ?? 0) >= noSignalAfter {
            row.state = .noSignal
            row.reason = "No signal for \(Int(noSignalAfter)) s from \(micName)"
        }
        return row
    }

    /// First live camera (layer order) whose mic is on: the one camera that owns the mic lane.
    static func cameraMicOwner(_ input: OnAirAudioInputs) -> UUID? {
        for layer in input.layers {
            if let shot = liveShot(layer), shot.source.sourceType == .systemCamera, input.cameraMics[shot.id] != nil {
                return shot.id
            }
        }
        return nil
    }

    private static func liveShot(_ layer: MasterLayer) -> LayerShot? {
        guard let id = layer.liveShotID else { return nil }
        return layer.shots.first { $0.id == id }
    }

    static func micKey(_ shot: LayerShot) -> String {
        let endpoint = shot.source.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return endpoint.isEmpty ? "system-input" : endpoint
    }

    private static func ownerName(_ rawKey: String, _ input: OnAirAudioInputs) -> String {
        // Capture keys for a device mic are "audio:<endpoint>"; shots are keyed by endpoint.
        let key = rawKey.hasPrefix("audio:") ? String(rawKey.dropFirst("audio:".count)) : rawKey
        for layer in input.layers {
            if let shot = liveShot(layer), shot.source.sourceType == .systemMicrophone, micKey(shot) == key {
                return shot.name
            }
        }
        return key == "system-input" ? "System input" : "Another mic"
    }

    private static func channel(_ role: AudioChannelRole, _ input: OnAirAudioInputs) -> AudioMatrixChannel? {
        input.channels.first { $0.role == role && $0.linkedGuestID == nil }
    }
}

/// BS.1770 K-weighted loudness (momentary 400 ms, short-term 3 s) and sample peak on the
/// mixed program. Fed from the program mix frame the monitor already gets on the main actor.
struct ProgramLoudnessMeter: Sendable {
    private struct Biquad: Sendable {
        var b0, b1, b2, a1, a2: Double
        var z1 = 0.0, z2 = 0.0
        mutating func run(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var shelf = [Self.makeShelf(), Self.makeShelf()]
    private var highPass = [Self.makeHighPass(), Self.makeHighPass()]
    /// Mean square per block (sum over both channels), newest last.
    private var blocks: [(energy: Double, frames: Int)] = []
    private var bufferedFrames = 0
    private(set) var peakDb: Double = -120
    private(set) var lastClipAt: Date = .distantPast
    private(set) var lastFrameAt: Date = .distantPast
    private(set) var lastSoundAt: Date = .distantPast
    let sampleRate: Double = 48_000

    static let clipLinear: Float = 0.999

    var momentaryLUFS: Double { loudness(seconds: 0.4) }
    var shortTermLUFS: Double { loudness(seconds: 3) }

    func clippedRecently(now: Date = Date(), window: TimeInterval = 2) -> Bool {
        now.timeIntervalSince(lastClipAt) < window
    }

    func isFresh(now: Date = Date()) -> Bool {
        now.timeIntervalSince(lastFrameAt) < 0.5
    }

    func silentSeconds(now: Date = Date()) -> TimeInterval {
        guard isFresh(now: now) else { return 0 }
        if lastSoundAt == .distantPast { return 0 }
        return now.timeIntervalSince(lastSoundAt)
    }

    mutating func ingest(interleavedStereo samples: [Float], now: Date = Date()) {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        var energy = 0.0
        var peak: Float = 0
        var clipped = false
        for index in 0..<frames {
            let left = samples[index * 2]
            let right = samples[index * 2 + 1]
            let magnitude = max(abs(left), abs(right))
            if magnitude > peak { peak = magnitude }
            if magnitude >= Self.clipLinear { clipped = true }
            let kl = highPass[0].run(shelf[0].run(Double(left)))
            let kr = highPass[1].run(shelf[1].run(Double(right)))
            energy += kl * kl + kr * kr
        }
        blocks.append((energy / Double(frames), frames))
        bufferedFrames += frames
        let keep = Int(sampleRate * 3)
        while bufferedFrames - (blocks.first?.frames ?? 0) >= keep, blocks.count > 1 {
            bufferedFrames -= blocks.removeFirst().frames
        }
        let blockPeakDb = peak > 0 ? 20 * log10(Double(peak)) : -120
        // Peak hold with a slow fall (about 20 dB/s at 47 blocks/s).
        peakDb = max(blockPeakDb, peakDb - 0.45)
        if clipped { lastClipAt = now }
        lastFrameAt = now
        if blockPeakDb > -60 || lastSoundAt == .distantPast { lastSoundAt = now }
    }

    private func loudness(seconds: Double) -> Double {
        let want = Int(sampleRate * seconds)
        var frames = 0
        var weighted = 0.0
        for block in blocks.reversed() {
            weighted += block.energy * Double(block.frames)
            frames += block.frames
            if frames >= want { break }
        }
        guard frames > 0, weighted > 0 else { return -70 }
        let meanSquare = weighted / Double(frames)
        return max(-70, -0.691 + 10 * log10(meanSquare))
    }

    // BS.1770-4 pre-filter and RLB filter at 48 kHz.
    private static func makeShelf() -> Biquad {
        Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
               a1: -1.69065929318241, a2: 0.73248077421585)
    }

    private static func makeHighPass() -> Biquad {
        Biquad(b0: 1.0, b1: -2.0, b2: 1.0, a1: -1.99004745483398, a2: 0.99007225036621)
    }
}
