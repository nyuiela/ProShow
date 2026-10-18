import Foundation
import Observation

enum AudioListenMode: String, Codable, Sendable, CaseIterable {
    /// Pre-fader: the source as captured (trim only), even if muted or isolated out.
    case pfl
    /// After-fader: exactly what the stream gets from this source.
    case afl
}

/// Multi-bus mixer: mic, desktop, guest, slide, and soundboard with ducking, EQ, and a limited master.
@MainActor
@Observable
final class AudioMatrixEngine {
    var channels: [AudioMatrixChannel] = []
    var master = MixerMasterState()
    var duckThresholdDb: Double = -24
    var duckAmountDb: Double = -12
    var duckingEnabled: Bool = true
    var duckingActive: Bool = false
    var programMuted: Bool = false
    /// Listen (PFL/AFL): operator monitor only. Never persisted, never changes the stream bus.
    var listenChannelIDs: Set<UUID> = []
    var listenMode: AudioListenMode = .pfl
    private var channelLimiter: Set<UUID> = []
    private var noiseGate: Set<UUID> = []

    func install(_ channels: [AudioMatrixChannel]) {
        self.channels = channels
    }

    func channel(id: UUID) -> AudioMatrixChannel? {
        channels.first(where: { $0.id == id })
    }

    func channel(role: AudioChannelRole) -> AudioMatrixChannel? {
        channels.first(where: { $0.role == role })
    }

    func setGain(id: UUID, db: Double) {
        mutate(id) { $0.gainDb = min(12, max(-60, db)) }
    }

    func setMasterGain(db: Double) {
        master.gainDb = min(12, max(-60, db))
    }

    func setHighPassEnabled(id: UUID, enabled: Bool) {
        mutate(id) { channel in
            var eq = channel.resolvedEQ
            if let index = eq.bands.firstIndex(where: { $0.filter == .highPass }) {
                eq.bands[index].enabled = enabled
                channel.parametricEQ = eq
            }
        }
    }

    func clearPeakHolds() {
        for index in channels.indices {
            channels[index].peakHoldDb = channels[index].peak
        }
        master.peakHoldDb = max(master.peakLeft, master.peakRight)
    }

    func setTrim(id: UUID, db: Double) {
        mutate(id) { $0.trimDb = min(12, max(-12, db)) }
    }

    func setMute(id: UUID, muted: Bool) {
        mutate(id) { $0.muted = muted }
        if muted, let channel = channel(id: id) {
            ProgramAACEncoder.flush(role: channel.role)
        }
    }

    func toggleMute(id: UUID) {
        guard let channel = channel(id: id) else { return }
        setMute(id: id, muted: !channel.muted)
    }

    func setSolo(id: UUID, solo: Bool) {
        mutate(id) { $0.solo = solo }
    }

    func toggleSolo(id: UUID) {
        mutate(id) { $0.solo.toggle() }
    }

    func toggleChannelLimiter(id: UUID) {
        if channelLimiter.contains(id) {
            channelLimiter.remove(id)
        } else {
            channelLimiter.insert(id)
        }
    }

    func isChannelLimited(_ id: UUID) -> Bool {
        channelLimiter.contains(id)
    }

    func toggleNoiseGate(id: UUID) {
        if noiseGate.contains(id) {
            noiseGate.remove(id)
        } else {
            noiseGate.insert(id)
        }
    }

    func isNoiseGateOn(_ id: UUID) -> Bool {
        noiseGate.contains(id)
    }

    func setHeadphoneMix(id: UUID, included: Bool) {
        mutate(id) { $0.bus = included ? .both : .stream }
    }

    func setDuckTarget(id: UUID, enabled: Bool) {
        mutate(id) { $0.duckTarget = enabled }
    }

    func toggleDuckTarget(id: UUID) {
        mutate(id) { $0.duckTarget = !($0.duckTarget ?? ($0.role != .microphone)) }
    }

    func setEQ(id: UUID, eq: ParametricEQ) {
        mutate(id) {
            $0.parametricEQ = eq
            if let low = eq.bands.first(where: { $0.filter == .lowShelf }) {
                $0.eq.lowDb = low.gainDb
            }
            if let high = eq.bands.first(where: { $0.filter == .highShelf }) {
                $0.eq.highDb = high.gainDb
            }
            let peaks = eq.bands.filter { $0.filter == .parametric }.map(\.gainDb)
            $0.eq.midDb = peaks.reduce(0, +)
        }
    }

    func setBus(id: UUID, bus: AudioOutputBus) {
        mutate(id) { $0.bus = bus }
    }

    func setPeak(id: UUID, db: Double) {
        mutate(id) { channel in
            channel.peak = db
            channel.peakHoldDb = AudioDSP.holdPeak(current: db, hold: channel.peakHoldDb ?? -120)
        }
    }

    func setStereoPeak(id: UUID, left: Double, right: Double) {
        mutate(id) { channel in
            channel.peakLeft = left
            channel.peakRight = right
            channel.peak = max(left, right)
            channel.peakHoldDb = AudioDSP.holdPeak(current: channel.peak, hold: channel.peakHoldDb ?? -120)
        }
    }

    func applyMix(_ mix: [AudioMixLevel]) {
        for level in mix {
            setGain(id: level.channelID, db: level.gainDb)
        }
    }

    /// Program mute is a master gate only. It must not rewrite per-channel mutes:
    /// those persist with the project while this flag does not, so a reload left
    /// Slide and Soundboard muted with no visible way back.
    func muteProgram(_ muted: Bool) {
        programMuted = muted
        master.muted = muted
        if muted {
            for channel in channels where channel.role != .microphone {
                ProgramAACEncoder.flush(role: channel.role)
            }
        }
    }

    func processFrame() {
        let anySolo = channels.contains(where: \.solo)
        // Only a mic that actually reaches program may duck the others. A muted, closed or
        // soloed-out mic still meters room sound, and used to duck slides and guests on air.
        let micGateOpen = ProgramStreamAudioGates.isHardwareCaptureOpen(.microphone)
        let micPeak = channels
            .filter { $0.role == .microphone && !$0.muted && micGateOpen && (!anySolo || $0.solo) }
            .map(\.peak).max() ?? -120
        duckingActive = duckingEnabled && !programMuted && micPeak > duckThresholdDb
        let audible = channels.compactMap { channel -> Double? in
            if programMuted || master.muted || channel.muted { return nil }
            if anySolo && !channel.solo { return nil }
            // Program meter follows the hard capture gate: a closed mic or desktop never reaches program.
            if channel.role == .microphone || channel.role == .desktop,
               !ProgramStreamAudioGates.isHardwareCaptureOpen(channel.role) { return nil }
            return channel.peak
        }
        let slideChannel = channels.first { $0.role == .slide }
        // Same rule as `outputLevel`: a solo elsewhere silences slide audio, so the meter must drop too.
        let slideSoloedOut = anySolo && !(slideChannel?.solo ?? false)
        let slideBlocked = programMuted || master.muted || (slideChannel?.muted ?? false) || slideSoloedOut
        let slideDb = slideBlocked ? -120.0 : ProgramSlideAudioMeter.peakDb()
        let mixDb = max(audible.max() ?? -120, slideDb)
        master.peakLeft = mixDb
        master.peakRight = mixDb
        master.peakHoldDb = AudioDSP.holdPeak(current: mixDb, hold: master.peakHoldDb)
    }

    func ensureStandardBuses() {
        guard channels.isEmpty else { return }
        install(DefaultSeedData.studioManifest().audioChannels)
    }

    var isListening: Bool { !listenChannelIDs.isEmpty }

    func setListen(id: UUID, on: Bool) {
        if on { listenChannelIDs.insert(id) } else { listenChannelIDs.remove(id) }
    }

    func clearListen() {
        listenChannelIDs.removeAll()
    }

    func outputLevel(for channel: AudioMatrixChannel, bus: AudioOutputBus) -> Double {
        if bus == .monitor, isListening {
            // Monitor bus only: the listened channels, everything else silent.
            guard listenChannelIDs.contains(channel.id), !programMuted, !master.muted else { return 0 }
            switch listenMode {
            case .pfl: return AudioDSP.linear(fromDb: channel.resolvedTrimDb)
            case .afl: return outputLevel(for: channel, bus: .stream)
            }
        }
        if programMuted || master.muted { return 0 }
        guard routes(channel, to: bus) else { return 0 }
        if channel.muted { return 0 }
        let anySolo = channels.contains(where: \.solo)
        if anySolo && !channel.solo { return 0 }
        var gain = channel.resolvedTrimDb + channel.gainDb
        if duckingActive && channel.isDuckTarget && channel.role != .microphone {
            gain += duckAmountDb
        }
        let linear = AudioDSP.linear(fromDb: gain)
        return linear
    }

    func streamMixLevel() -> Double {
        processFrame()
        return streamMixLevelRaw()
    }

    func monitorMixLevel() -> Double {
        processFrame()
        return monitorMixLevelRaw()
    }

    func stageMixLevel() -> Double {
        processFrame()
        return channels.reduce(0) { $0 + outputLevel(for: $1, bus: .stage) }
    }

    /// Sum of monitor bus channels, optionally excluding guest mic rows (mix-minus).
    func monitorMixLinear(excludingChannelIDs: Set<UUID> = []) -> Double {
        processFrame()
        if programMuted || master.muted { return 0 }
        let sum = channels.reduce(0) { partial, channel in
            if excludingChannelIDs.contains(channel.id) { return partial }
            return partial + outputLevel(for: channel, bus: .monitor)
        }
        return AudioDSP.applyLimiter(
            sum * AudioDSP.linear(fromDb: master.gainDb),
            enabled: master.limiterEnabled,
            ceilingDb: master.ceilingDb
        )
    }

    func mixMinusLinear(excludingGuestID: UUID?) -> Double {
        guard let excludingGuestID else { return monitorMixLinear() }
        let excluded = Set(
            channels.filter { $0.linkedGuestID == excludingGuestID }.map(\.id)
        )
        return monitorMixLinear(excludingChannelIDs: excluded)
    }

    @discardableResult
    func ensureGuestChannel(guestID: UUID, displayName: String) -> UUID {
        if let existing = channels.first(where: { $0.linkedGuestID == guestID }) {
            return existing.id
        }
        var channel = AudioMatrixChannel(
            id: UUID(),
            name: displayName,
            role: .guest,
            gainDb: 0,
            muted: false,
            solo: false,
            eq: AudioEQ(),
            bus: .both,
            peak: -120
        )
        channel.linkedGuestID = guestID
        channels.append(channel)
        return channel.id
    }

    /// Drops guest strips that are not in the current room, including leftovers from earlier sessions.
    func pruneGuestChannels(keeping guestIDs: Set<UUID>) {
        channels.removeAll { channel in
            guard channel.role == .guest else { return false }
            guard let linked = channel.linkedGuestID else { return true }
            return !guestIDs.contains(linked)
        }
    }

    func setGuestChannelMuted(guestID: UUID, muted: Bool) {
        guard let index = channels.firstIndex(where: { $0.linkedGuestID == guestID }) else { return }
        channels[index].muted = muted
    }

    func metersJSON() -> String {
        processFrame()
        let rows = channels.map { channel in
            #"{"id":"\#(channel.id.uuidString)","name":"\#(channel.name)","peak":\#(channel.peak),"gainDb":\#(channel.gainDb),"muted":\#(channel.muted)}"#
        }.joined(separator: ",")
        return #"{"ok":true,"ducking":\#(duckingActive),"limiter":\#(master.limiterEnabled),"programMuted":\#(programMuted),"master":{"peakLeft":\#(master.peakLeft),"peakRight":\#(master.peakRight),"peakHoldDb":\#(master.peakHoldDb),"muted":\#(master.muted),"gainDb":\#(master.gainDb)},"channels":[\#(rows)]}"#
    }

    nonisolated static func linearGain(db: Double) -> Double {
        AudioDSP.linear(fromDb: db)
    }

    private func streamMixLevelRaw() -> Double {
        if programMuted || master.muted { return 0 }
        let sum = channels.reduce(0) { $0 + outputLevel(for: $1, bus: .stream) }
        return AudioDSP.applyLimiter(sum * AudioDSP.linear(fromDb: master.gainDb), enabled: master.limiterEnabled, ceilingDb: master.ceilingDb)
    }

    private func monitorMixLevelRaw() -> Double {
        if programMuted || master.muted { return 0 }
        let sum = channels.reduce(0) { $0 + outputLevel(for: $1, bus: .monitor) }
        return AudioDSP.applyLimiter(sum * AudioDSP.linear(fromDb: master.gainDb), enabled: master.limiterEnabled, ceilingDb: master.ceilingDb)
    }

    private func routes(_ channel: AudioMatrixChannel, to bus: AudioOutputBus) -> Bool {
        switch channel.bus {
        case .all: true
        case .both: bus == .stream || bus == .monitor
        default: channel.bus == bus
        }
    }

    private func mutate(_ id: UUID, _ body: (inout AudioMatrixChannel) -> Void) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        body(&channels[index])
    }
}
