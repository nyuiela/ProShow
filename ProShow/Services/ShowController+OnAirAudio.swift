import Foundation
import AVFoundation
import Observation

struct ProgramMeterReading: Hashable, Sendable {
    var momentaryLUFS: Double = -70
    var shortTermLUFS: Double = -70
    var peakDb: Double = -120
    var clipping = false
    /// False when no program mix frame arrived recently (nothing consumes the mix yet).
    var measured = false
}

/// Main-actor view model for the On-Air Audio group and `GET /v1/audio/onair`.
/// Refreshes at 5 Hz from existing state; never touches the mix.
@MainActor
@Observable
final class OnAirAudioMonitor {
    static let shared = OnAirAudioMonitor()

    private(set) var sources: [OnAirAudioSource] = []
    private(set) var alerts: [OnAirAudioAlert] = []
    private(set) var program = ProgramMeterReading()
    /// QA only: rows that stand in for a room guest when no real guest is in the room.
    var simulatedGuests: [OnAirAudioInputs.Guest] = []

    @ObservationIgnored private var meter = ProgramLoudnessMeter()
    @ObservationIgnored private var silentSince: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var controller: ShowController?

    func attach(_ controller: ShowController) {
        self.controller = controller
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    /// The program mix frame the monitor engine already receives (main actor, ~47 per second).
    func noteProgramMix(_ interleavedStereo: [Float]) {
        meter.ingest(interleavedStereo: interleavedStereo)
    }

    func refresh() {
        guard let controller else { return }
        let now = Date()
        var input = controller.onAirAudioInputs()
        input.silentSeconds = silentSince.mapValues { now.timeIntervalSince($0) }
        let rows = OnAirAudioResolver.resolve(input)
        var nextSilent: [String: Date] = [:]
        for row in rows where row.state == .live || row.state == .noSignal {
            guard row.type == .mic || row.type == .desktop || row.type == .slide || row.via != nil else { continue }
            if row.peakDb < OnAirAudioResolver.signalFloorDb {
                nextSilent[row.id] = silentSince[row.id] ?? now
            }
        }
        silentSince = nextSilent
        let fresh = meter.isFresh(now: now)
        let reading = ProgramMeterReading(
            momentaryLUFS: fresh ? meter.momentaryLUFS : -70,
            shortTermLUFS: fresh ? meter.shortTermLUFS : -70,
            peakDb: fresh ? meter.peakDb : max(controller.audioMatrix.master.peakLeft, controller.audioMatrix.master.peakRight),
            clipping: fresh && meter.clippedRecently(now: now),
            measured: fresh
        )
        let isLive = controller.streaming.isLive || controller.isoRecorder.isRecording
        let capture = CaptureAudioSources.delivering().mapValues(\.keys)
        let nextAlerts = OnAirAudioResolver.alerts(
            sources: rows,
            channels: input.channels,
            capture: capture,
            programSilentSeconds: isLive ? meter.silentSeconds(now: now) : 0,
            isLive: isLive,
            clippedRecently: reading.clipping
        )
        var withMicMode = nextAlerts
        if rows.contains(where: { ($0.type == .mic || $0.via != nil) && $0.isOnAir }), MicrophoneModeStatus.isVoiceIsolation {
            withMicMode.append(OnAirAudioAlert(kind: .micMode, message: MicrophoneModeStatus.voiceIsolationWarning))
        }
        if rows != sources { sources = rows }
        if withMicMode != alerts { alerts = withMicMode }
        if reading != program { program = reading }
    }

    func jsonObject(controller: ShowController) -> [String: Any] {
        attach(controller)
        refresh()
        let onAir = sources.filter(\.isOnAir)
        return [
            "ok": true,
            "program": [
                "momentary_lufs": (program.momentaryLUFS * 10).rounded() / 10,
                "short_term_lufs": (program.shortTermLUFS * 10).rounded() / 10,
                "peak_db": (program.peakDb * 10).rounded() / 10,
                "clipping": program.clipping,
                "measured": program.measured,
            ] as [String: Any],
            "on_air_count": onAir.count,
            "on_air": onAir.map(\.jsonObject),
            "not_heard": sources.filter { !$0.isOnAir }.map(\.jsonObject),
            "alerts": alerts.map { ["kind": $0.kind.rawValue, "message": $0.message] },
            "solo": controller.audioMatrix.channels.filter(\.solo).map(\.name),
            "returns": controller.onAirReturnsSummary,
        ]
    }
}

extension ShowController {
    func onAirAudioInputs() -> OnAirAudioInputs {
        var input = OnAirAudioInputs()
        input.layers = masterLayers
        input.channels = audioMatrix.channels
        input.programMuted = audioMatrix.programMuted || audioMatrix.master.muted || audioIO.programMuted
        input.captureOpen = Set(
            [AudioChannelRole.microphone, .desktop, .guest, .slide, .soundboard]
                .filter { ProgramStreamAudioGates.isHardwareCaptureOpen($0) }
        )
        input.micOwner = CaptureAudioSources.delivering()[.microphone]?.owner
        input.desktopHeldByMic = ProgramStreamAudioGates.isDesktopHeldForMicrophone()
        input.slide = onAirSlideAudio()
        input.soundboardPlaying = !soundboard.playing.isEmpty
        for layer in masterLayers {
            guard let liveID = layer.liveShotID,
                  let shot = layer.shots.first(where: { $0.id == liveID }),
                  shot.source.sourceType == .systemCamera
            else { continue }
            if let mic = cameraMic(endpoint: shot.source.connectionString) {
                if !shot.isAudioMuted { input.cameraMics[shot.id] = mic.name }
            } else {
                input.camerasWithoutMic.insert(shot.id)
            }
        }
        let peaks = GuestAudioLevels.snapshot()
        input.guests = liveKitDesk.guests.map { feed in
            let id = LiveKitGuestEndpoint.stableID(feed.identity)
            return OnAirAudioInputs.Guest(
                identity: feed.identity,
                name: feed.name,
                guestID: id,
                hasMic: feed.hasMic,
                peakDb: peaks[id].map { max($0.left, $0.right) }
            )
        }
        for guest in OnAirAudioMonitor.shared.simulatedGuests {
            input.guests.append(guest)
            if !input.channels.contains(where: { $0.linkedGuestID == guest.guestID }) {
                var strip = AudioMatrixChannel(name: guest.name, role: .guest, peak: guest.peakDb ?? -120)
                strip.linkedGuestID = guest.guestID
                input.channels.append(strip)
            }
        }
        return input
    }

    /// Slide/media audio row: shown when program media can make sound, or slide audio is metering.
    private func onAirSlideAudio() -> OnAirAudioInputs.SlideAudio? {
        let meterDb = ProgramSlideAudioMeter.peakDb()
        let media = compositor.stack.media
        let hasAudibleMedia = media.map { !$0.isImage && !$0.clearsLayer } ?? false
        guard hasAudibleMedia || meterDb > OnAirAudioResolver.signalFloorDb else { return nil }
        let slideName = liveIndex.map { "Slide \($0 + 1) audio" } ?? "Slide audio"
        let name = media.map { $0.title.isEmpty ? slideName : $0.title } ?? slideName
        return OnAirAudioInputs.SlideAudio(name: name, blockReason: programMediaAudioBlockReason, peakDb: meterDb)
    }

    var onAirReturnsSummary: [String: Any] {
        [
            "room_connected": liveKitDesk.hasStartedConnection,
            "room_return": liveKitGuestReturnActive,
            "mode": backstage.returnFeedMode.rawValue,
            "intercom": backstage.intercomActive,
            "guests": liveKitDesk.guests.count,
        ]
    }

    /// One line for the group footer. Honest about today's wiring: the room always hears
    /// the program without guests (guests hear each other directly). Full and Intercom are
    /// selectable but do not change the return yet (plan phase 3).
    var onAirReturnsLine: String {
        guard liveKitDesk.hasStartedConnection else { return "Room off" }
        let count = liveKitDesk.guests.count
        let guests = "\(count) guest\(count == 1 ? "" : "s")"
        guard liveKitGuestReturnActive else { return "Room: return off. \(guests)." }
        var line = "Room hears program without guests. \(guests)."
        if backstage.returnFeedMode != .programMixMinus || backstage.intercomActive {
            line += " Full and Intercom are not wired yet."
        }
        return line
    }

    var soloedAudioChannelNames: [String] {
        audioMatrix.channels.filter(\.solo).map(\.name)
    }

    func clearAllAudioSolos() {
        for channel in audioMatrix.channels where channel.solo {
            audioMatrix.setSolo(id: channel.id, solo: false)
        }
        ProgramStreamAudioGates.sync(from: audioMatrix)
    }

    /// The row's one-click fix. Adds or turns on a mic; never removes a shot.
    func applyOnAirFix(_ fix: OnAirAudioFix) {
        switch fix {
        case .useCameraMic(let layer, let shotID):
            guard masterLayers.indices.contains(layer), masterLayers[layer].liveShotID == shotID else { return }
            if isLiveShotAudioMuted(layerIndex: layer) { toggleLiveShotAudio(layerIndex: layer) }
        case .addMic:
            addDefaultMicShot()
        }
    }

    /// A mic shot on the first free layer (system default input), taken live.
    @discardableResult
    func addDefaultMicShot(endpoint: String = "") -> LayerShot? {
        guard let index = masterLayers.firstIndex(where: { $0.liveShotID == nil && $0.shots.isEmpty })
            ?? masterLayers.firstIndex(where: { $0.liveShotID == nil })
        else { return nil }
        let item = DiscoveredSourceItem(
            name: "Microphone", category: .all, groupName: "Audio",
            sourceType: .systemMicrophone, connectionString: endpoint
        )
        let shot = LayerShot(name: "Microphone", source: item)
        var layers = masterLayers
        layers[index].shots.append(shot)
        masterLayers = layers
        takeShotLive(shot, layerIndex: index)
        return shot
    }

    func jumpToOnAirSource(_ source: OnAirAudioSource) {
        switch source.jump {
        case .layer(let index):
            inspector.selectedTab = .layers
            UserDefaults.standard.set(true, forKey: "proshow.inspector.masterExpanded")
            selectMasterLayer(at: index)
        case .slide:
            if let liveSlideID { selectedSlideID = liveSlideID }
        case .room:
            inspector.selectedTab = .backstage
        case .audioTab:
            inspector.selectedTab = .audio
        }
    }
}


/// macOS Mic Mode (Control Center) for this app. Voice Isolation strips steady sound such as music,
/// a held note or room tone and only lets speech through, so a mic that "works" can sound empty on air.
enum MicrophoneModeStatus {
    static let voiceIsolationWarning = "Mic Mode is Voice Isolation. Music and room sound are removed. Choose Standard."

    static var active: String { name(AVCaptureDevice.activeMicrophoneMode) }
    static var preferred: String { name(AVCaptureDevice.preferredMicrophoneMode) }
    static var isVoiceIsolation: Bool { AVCaptureDevice.activeMicrophoneMode == .voiceIsolation }

    /// Opens the system Mic Mode picker. The user picks Standard there; apps cannot set it.
    static func showPicker() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }

    static func name(_ mode: AVCaptureDevice.MicrophoneMode) -> String {
        switch mode {
        case .standard: return "standard"
        case .wideSpectrum: return "wide_spectrum"
        case .voiceIsolation: return "voice_isolation"
        @unknown default: return "unknown"
        }
    }
}
