import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

// On-Air Audio, phases 2 and 3: per-row controls, Listen, Isolate, follow-slide, return feeds
// and talkback. Every control writes the state that already owns it (live shot audio, mixer
// channel, guest mute). Nothing here runs on a capture, encode or render thread.

/// Result of a control call, for the UI and the Control API.
enum OnAirControlResult: Equatable {
    case ok
    case needsConfirm
    case notFound
    case unsupported(String)

    var key: String {
        switch self {
        case .ok: "ok"
        case .needsConfirm: "needs_confirm"
        case .notFound: "not_found"
        case .unsupported: "unsupported"
        }
    }
}

extension BackstageReturnFeedMode {
    var wireKey: String {
        switch self {
        case .programMixMinus: "mix"
        case .programFull: "full"
        case .intercomOnly: "intercom"
        }
    }

    init?(wireKey: String) {
        switch wireKey.lowercased() {
        case "mix", "mix-minus", "mixminus": self = .programMixMinus
        case "full": self = .programFull
        case "intercom", "intercom_only": self = .intercomOnly
        default: return nil
        }
    }
}

@MainActor
@Observable
final class OnAirAudioControls {
    static let shared = OnAirAudioControls()

    /// Per-guest return feed. Missing = the room default (`backstage.returnFeedMode`).
    var returnModes: [String: BackstageReturnFeedMode] = [:]
    private(set) var talkActive = false
    var routingSheetOpen = false
    /// nil = every guest.
    var talkTarget: String?
    var talkDeviceID: String? {
        didSet { UserDefaults.standard.set(talkDeviceID, forKey: Self.talkDeviceKey) }
    }
    @ObservationIgnored private var listenStartedMonitor = false
    @ObservationIgnored private var talkKeyMonitor: Any?
    @ObservationIgnored private var talkKeyDown = false

    static let talkDeviceKey = "proshow.talkback.deviceID"

    init() {
        talkDeviceID = UserDefaults.standard.string(forKey: Self.talkDeviceKey)
    }

    var talkPacketsSent: UInt32 { TalkbackEngine.shared.sentPackets }

    // MARK: Talk key (hold T)

    func installTalkKey(_ controller: ShowController) {
        #if os(macOS)
        guard talkKeyMonitor == nil else { return }
        talkKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak controller] event in
            guard let self, let controller else { return event }
            guard event.charactersIgnoringModifiers?.lowercased() == "t",
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  !Self.isEditingText()
            else { return event }
            guard controller.liveKitDesk.hasStartedConnection else { return event }
            if event.type == .keyDown {
                if !event.isARepeat, !self.talkKeyDown {
                    self.talkKeyDown = true
                    controller.startTalkback()
                }
            } else {
                self.talkKeyDown = false
                controller.stopTalkback()
            }
            return nil
        }
        #endif
    }

    #if os(macOS)
    private static func isEditingText() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable }
        return responder is NSTextField
    }
    #endif

    fileprivate func setTalkActive(_ on: Bool) { talkActive = on }

    fileprivate func noteListen(_ listening: Bool) {
        AudioMonitoringEngine.shared.isListening = listening
        let bridge = ProgramAudioMonitorBridge.shared
        if listening {
            if !bridge.isRunning {
                bridge.setActive(true)
                listenStartedMonitor = true
            } else {
                bridge.refreshOutputRouting()
            }
        } else {
            if listenStartedMonitor {
                bridge.setActive(false)
                listenStartedMonitor = false
            } else {
                bridge.refreshOutputRouting()
            }
        }
    }
}

extension ShowController {
    /// False while a follow-slide shot's slide is not live. Called from the gate policy each tick.
    func followSlideAllows(_ shot: LayerShot) -> Bool {
        guard shot.audioFollow == .followSlide, let bound = shot.audioFollowSlideID else { return true }
        return liveSlideID == bound
    }

    var followHeldShotIDs: Set<UUID> {
        var held: Set<UUID> = []
        for layer in masterLayers {
            guard let id = layer.liveShotID, let shot = layer.shots.first(where: { $0.id == id }) else { continue }
            if !followSlideAllows(shot) { held.insert(shot.id) }
        }
        return held
    }

    var isOnAirLive: Bool { streaming.isLive || isoRecorder.isRecording }

    // MARK: Row lookup

    func onAirRow(_ id: String) -> OnAirAudioSource? {
        let monitor = OnAirAudioMonitor.shared
        monitor.attach(self)
        monitor.refresh()
        return monitor.sources.first { $0.id == id }
    }

    /// The mixer strip a row's gain, Listen and Isolate act on.
    func onAirChannel(for row: OnAirAudioSource) -> AudioMatrixChannel? {
        if let identity = row.guestIdentity {
            let guestID = LiveKitGuestEndpoint.stableID(identity)
            return audioMatrix.channels.first { $0.linkedGuestID == guestID }
        }
        guard let role = row.role else { return nil }
        return audioMatrix.channel(role: role)
    }

    func onAirChannelExists(for row: OnAirAudioSource) -> Bool {
        guard row.type != .network, !(row.type == .camera && row.via == nil && row.state != .live) else { return false }
        return onAirChannel(for: row) != nil
    }

    func onAirIsIsolated(_ row: OnAirAudioSource) -> Bool {
        onAirChannel(for: row)?.solo == true
    }

    /// Fills each row's control state (mute, gain, Listen, follow) after resolve.
    func decorateOnAirRows(_ rows: [OnAirAudioSource]) -> [OnAirAudioSource] {
        rows.map { source in
            var row = source
            if let channel = onAirChannel(for: row) {
                row.gainDb = channel.gainDb
                row.listening = audioMatrix.listenChannelIDs.contains(channel.id)
                if row.type == .slide || row.type == .soundboard || row.type == .guest { row.muted = channel.muted }
            }
            if let layer = row.layerIndex, let shotID = row.shotID,
               masterLayers.indices.contains(layer),
               let shot = masterLayers[layer].shots.first(where: { $0.id == shotID }) {
                row.muted = shot.isAudioMuted
                row.follow = shot.audioFollow ?? .alwaysOn
            }
            if row.type == .slide {
                row.follow = compositor.mediaAudioAlwaysOn ? .alwaysOn : .followSlide
            }
            return row
        }
    }

    // MARK: Controls

    @discardableResult
    func setOnAirMute(_ id: String, muted: Bool) -> OnAirControlResult {
        guard let row = onAirRow(id) else { return .notFound }
        if let identity = row.guestIdentity {
            muteLiveKitGuest(identity: identity, muted: muted)
        } else if let layer = row.layerIndex, let shotID = row.shotID {
            guard masterLayers.indices.contains(layer),
                  let shotIndex = masterLayers[layer].shots.firstIndex(where: { $0.id == shotID })
            else { return .notFound }
            if masterLayers[layer].liveShotID == shotID {
                if isLiveShotAudioMuted(layerIndex: layer) != muted { toggleLiveShotAudio(layerIndex: layer) }
            } else {
                var layers = masterLayers
                layers[layer].shots[shotIndex].audioMuted = muted ? true : nil
                masterLayers = layers
            }
        } else if let channel = onAirChannel(for: row) {
            audioMatrix.setMute(id: channel.id, muted: muted)
            ProgramStreamAudioGates.sync(from: audioMatrix)
        } else {
            return .unsupported("no channel")
        }
        OnAirAudioMonitor.shared.refresh()
        return .ok
    }

    @discardableResult
    func setOnAirGain(_ id: String, db: Double) -> OnAirControlResult {
        guard let row = onAirRow(id) else { return .notFound }
        guard let channel = onAirChannel(for: row) else { return .unsupported("no channel") }
        audioMatrix.setGain(id: channel.id, db: db)
        ProgramStreamAudioGates.sync(from: audioMatrix)
        OnAirAudioMonitor.shared.refresh()
        return .ok
    }

    /// Headphone-only: changes monitor-bus gains, never stream or room gains.
    @discardableResult
    func setOnAirListen(_ id: String, on: Bool, exclusive: Bool = true) -> OnAirControlResult {
        guard let row = onAirRow(id) else { return .notFound }
        guard let channel = onAirChannel(for: row) else { return .unsupported("no channel") }
        if on, exclusive { audioMatrix.clearListen() }
        audioMatrix.setListen(id: channel.id, on: on)
        applyListenState()
        return .ok
    }

    func clearOnAirListen() {
        audioMatrix.clearListen()
        applyListenState()
    }

    func setListenMode(_ mode: AudioListenMode) {
        audioMatrix.listenMode = mode
        applyListenState()
    }

    private func applyListenState() {
        ProgramStreamAudioGates.sync(from: audioMatrix)
        OnAirAudioControls.shared.noteListen(audioMatrix.isListening)
        OnAirAudioMonitor.shared.refresh()
    }

    /// Isolate (was "solo"): silences every other source on the stream. Needs confirm while live.
    @discardableResult
    func setOnAirIsolate(_ id: String, on: Bool, confirmed: Bool) -> OnAirControlResult {
        guard let row = onAirRow(id) else { return .notFound }
        guard let channel = onAirChannel(for: row) else { return .unsupported("no channel") }
        if on, isOnAirLive, !confirmed { return .needsConfirm }
        audioMatrix.setSolo(id: channel.id, solo: on)
        ProgramStreamAudioGates.sync(from: audioMatrix)
        OnAirAudioMonitor.shared.refresh()
        return .ok
    }

    @discardableResult
    func setOnAirFollow(_ id: String, mode: AudioFollowMode) -> OnAirControlResult {
        guard let row = onAirRow(id) else { return .notFound }
        if row.type == .slide {
            compositor.mediaAudioAlwaysOn = mode == .alwaysOn
            OnAirAudioMonitor.shared.refresh()
            return .ok
        }
        guard let layer = row.layerIndex, let shotID = row.shotID,
              masterLayers.indices.contains(layer),
              let shotIndex = masterLayers[layer].shots.firstIndex(where: { $0.id == shotID })
        else { return .unsupported("follow is for layer sources and slide audio") }
        var layers = masterLayers
        layers[layer].shots[shotIndex].audioFollow = mode == .alwaysOn ? nil : .followSlide
        layers[layer].shots[shotIndex].audioFollowSlideID = mode == .alwaysOn ? nil : liveSlideID
        masterLayers = layers
        AudioMatrixReconciler.enforceProgramAudioGates(controller: self)
        reconcileAudioCaptureGraph()
        OnAirAudioMonitor.shared.refresh()
        return .ok
    }

    /// Audio tab Isolate while live: one confirm. True = go ahead.
    func confirmIsolateIfLive(_ name: String) -> Bool {
        guard isOnAirLive else { return true }
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = "Isolate \(name)?"
        alert.informativeText = "Everything else goes silent on the stream."
        alert.addButton(withTitle: "Isolate")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
        #else
        return true
        #endif
    }

    // MARK: Shortcuts

    func toggleLayerAudioShortcut(_ layerIndex: Int) {
        guard masterLayers.indices.contains(layerIndex), masterLayers[layerIndex].liveShotID != nil else { return }
        toggleLiveShotAudio(layerIndex: layerIndex)
        OnAirAudioMonitor.shared.refresh()
    }

    func toggleMicChannelShortcut() {
        guard let mic = audioMatrix.channel(role: .microphone) else { return }
        audioMatrix.setMute(id: mic.id, muted: !mic.muted)
        ProgramStreamAudioGates.sync(from: audioMatrix)
        OnAirAudioMonitor.shared.refresh()
    }

    // MARK: Returns

    func returnMode(for identity: String) -> BackstageReturnFeedMode {
        OnAirAudioControls.shared.returnModes[identity] ?? backstage.returnFeedMode
    }

    /// identity nil sets the room default and clears per-guest overrides.
    func setReturnMode(identity: String?, mode: BackstageReturnFeedMode) {
        let controls = OnAirAudioControls.shared
        if let identity {
            controls.returnModes[identity] = mode == backstage.returnFeedMode ? nil : mode
        } else {
            backstage.returnFeedMode = mode
            backstage.intercomActive = mode == .intercomOnly
            controls.returnModes.removeAll()
        }
        publishReturnsState()
    }

    /// Per-guest modes and desk mutes for the join page. Dedupes, so it is cheap to call often.
    func publishReturnsState() {
        guard liveKitDesk.hasStartedConnection else { return }
        var modes: [String: String] = [:]
        var muted: [String] = []
        for feed in liveKitDesk.guests {
            modes[feed.identity] = returnMode(for: feed.identity).wireKey
            let guestID = LiveKitGuestEndpoint.stableID(feed.identity)
            if audioMatrix.channels.first(where: { $0.linkedGuestID == guestID })?.muted == true {
                muted.append(feed.identity)
            }
        }
        liveKitDesk.publishReturns(modes: modes, defaultMode: backstage.returnFeedMode.wireKey, muted: muted)
    }

    var onAirReturnCounts: (mix: Int, full: Int, intercom: Int) {
        var counts = (mix: 0, full: 0, intercom: 0)
        for feed in liveKitDesk.guests {
            switch returnMode(for: feed.identity) {
            case .programMixMinus: counts.mix += 1
            case .programFull: counts.full += 1
            case .intercomOnly: counts.intercom += 1
            }
        }
        return counts
    }

    // MARK: Talkback

    /// Push to talk. Separate mic session, data packets to the room only. Never on program.
    @discardableResult
    func startTalkback(target: String? = nil, toneHz: Double? = nil) -> OnAirControlResult {
        guard liveKitDesk.hasStartedConnection, let send = liveKitDesk.intercomSender() else {
            return .unsupported("room off")
        }
        let controls = OnAirAudioControls.shared
        if let target { controls.talkTarget = target.isEmpty ? nil : target }
        let targets = controls.talkTarget.map { [$0] } ?? []
        TalkbackEngine.shared.start(deviceID: controls.talkDeviceID, toneHz: toneHz) { packet in
            send(packet, targets)
        }
        guard TalkbackEngine.shared.isRunning else { return .unsupported("mic unavailable") }
        controls.setTalkActive(true)
        liveKitDesk.publishTalk(on: true, targets: targets)
        return .ok
    }

    func stopTalkback() {
        let controls = OnAirAudioControls.shared
        guard controls.talkActive || TalkbackEngine.shared.isRunning else { return }
        TalkbackEngine.shared.stop()
        controls.setTalkActive(false)
        liveKitDesk.publishTalk(on: false, targets: controls.talkTarget.map { [$0] } ?? [])
    }

    // MARK: Routing matrix

    static let routingBuses = ["program", "phone", "return_mix", "return_full", "intercom", "monitor"]

    /// Which bus each row reaches right now. "direct" = guests hear that guest over the room, not the return.
    func onAirRouting() -> [[String: Any]] {
        let monitor = OnAirAudioMonitor.shared
        monitor.attach(self)
        monitor.refresh()
        let phone = streaming.isLive && streaming.routingPlan?.phoneLane != nil
        var out: [[String: Any]] = []
        for row in monitor.sources {
            let heard = row.isOnAir
            var monitorOn = heard
            if let channel = onAirChannel(for: row) {
                monitorOn = (heard || row.listening) && audioMatrix.outputLevel(for: channel, bus: .monitor) > 0
            }
            let isGuest = row.type == .guest
            out.append([
                "id": row.id,
                "name": row.name,
                "type": row.type.rawValue,
                "program": heard ? "on" : "off",
                "phone": heard && phone ? "on" : "off",
                "return_mix": heard ? (isGuest ? "direct" : "on") : "off",
                "return_full": heard ? (isGuest ? "direct" : "on") : "off",
                "intercom": "off",
                "monitor": monitorOn ? "on" : "off",
            ])
        }
        out.append([
            "id": "talkback", "name": "Talkback", "type": "talkback",
            "program": "off", "phone": "off", "return_mix": "off", "return_full": "off",
            "intercom": OnAirAudioControls.shared.talkActive ? "on" : "ready", "monitor": "off",
        ])
        return out
    }
}

/// QA: writes what the monitor bus carries (Listen, headphones) to a wav. Fed on the encode queue.
enum MonitorBusCapture {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var armed = false
    nonisolated(unsafe) private static var samples: [Float] = []
    nonisolated(unsafe) private static var limit = 0

    static func start(seconds: Double) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        limit = Int(seconds * 48_000) * 2
        armed = true
        lock.unlock()
    }

    static func feed(_ interleavedStereo: [Float]) {
        guard armed else { return }
        lock.lock()
        if armed {
            samples.append(contentsOf: interleavedStereo)
            if samples.count >= limit { armed = false }
        }
        lock.unlock()
    }

    static var isArmed: Bool { armed }

    /// Writes 16-bit 48 kHz stereo wav.
    static func write(to url: URL) -> Int {
        lock.lock()
        let data = samples
        armed = false
        lock.unlock()
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; wav.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(data.count * 2)
        wav.append("RIFF".data(using: .ascii)!); u32(36 + bytes)
        wav.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        wav.append("data".data(using: .ascii)!); u32(bytes)
        var pcm = [Int16](repeating: 0, count: data.count)
        for index in data.indices { pcm[index] = Int16(max(-1, min(1, data[index])) * 32_767) }
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        try? wav.write(to: url)
        return data.count / 2
    }
}

// MARK: Control API

extension ShowController {
    private static func flag(_ value: String?) -> Bool? {
        guard let value else { return nil }
        return value == "1" || value.lowercased() == "true" || value.lowercased() == "on"
    }

    func onAirControlsJSON() -> [String: Any] {
        let monitor = OnAirAudioMonitor.shared
        monitor.attach(self)
        monitor.refresh()
        return [
            "ok": true,
            "sources": monitor.sources.map(\.jsonObject),
            "listen": [
                "active": audioMatrix.isListening,
                "mode": audioMatrix.listenMode.rawValue,
                "channels": audioMatrix.channels.filter { audioMatrix.listenChannelIDs.contains($0.id) }.map(\.name),
                "device": AudioMonitoringEngine.shared.listenDeviceUID ?? NSNull(),
                "output": AudioMonitoringEngine.shared.activeOutputDeviceUID ?? "default",
                "monitor_running": ProgramAudioMonitorBridge.shared.isRunning,
            ] as [String: Any],
            "isolate": audioMatrix.channels.filter(\.solo).map(\.name),
            "live": isOnAirLive,
            "returns": onAirReturnsSummary,
        ]
    }

    /// /v1/audio/{source,listen,isolate,follow,returns,talkback,monitor}. Nil = not ours.
    func handleOnAirControlAPI(method: String, parts: [String], body: Data?) -> (Int, String)? {
        guard parts.count >= 3, parts[0] == "v1", parts[1] == "audio" else { return nil }
        let args = ControlHTTP.jsonObject(body)
        func reply(_ result: OnAirControlResult, _ extra: [String: Any] = [:]) -> (Int, String) {
            var out: [String: Any] = ["ok": result == .ok, "result": result.key]
            if case .unsupported(let why) = result { out["error"] = why }
            for (key, value) in extra { out[key] = value }
            let code = result == .notFound ? 404 : (result == .needsConfirm ? 409 : (result == .ok ? 200 : 400))
            return (code, ControlJSON.encode(out))
        }
        switch (method, Array(parts.dropFirst(2))) {
        case ("GET", ["controls"]), ("GET", ["source"]):
            return (200, ControlJSON.encode(onAirControlsJSON()))
        case ("POST", ["source"]):
            guard let id = args["id"] else { return (400, #"{"ok":false,"error":"missing_id"}"#) }
            var result = OnAirControlResult.ok
            if let muted = Self.flag(args["mute"] ?? args["muted"]) { result = setOnAirMute(id, muted: muted) }
            if result == .ok, let db = args["gain_db"].flatMap(Double.init) { result = setOnAirGain(id, db: db) }
            if result == .ok, let listen = Self.flag(args["listen"]) { result = setOnAirListen(id, on: listen) }
            if result == .ok, let follow = args["follow"] {
                guard let mode = AudioFollowMode(rawValue: follow == "slide" ? "followSlide" : (follow == "always" ? "alwaysOn" : follow))
                else { return (400, #"{"ok":false,"error":"follow must be slide or always"}"#) }
                result = setOnAirFollow(id, mode: mode)
            }
            if result == .ok, let isolate = Self.flag(args["isolate"]) {
                result = setOnAirIsolate(id, on: isolate, confirmed: Self.flag(args["confirm"]) ?? false)
            }
            return reply(result, ["source": onAirRow(id)?.jsonObject ?? NSNull()])
        case ("POST", ["listen"]):
            if Self.flag(args["clear"]) == true { clearOnAirListen() }
            if let mode = args["mode"].flatMap(AudioListenMode.init(rawValue:)) { setListenMode(mode) }
            if let device = args["device"] {
                AudioMonitoringEngine.shared.listenDeviceUID = (device.isEmpty || device == "default") ? nil : device
                if audioMatrix.isListening { ProgramAudioMonitorBridge.shared.refreshOutputRouting() }
            }
            return (200, ControlJSON.encode(onAirControlsJSON()))
        case ("POST", ["isolate", "clear"]):
            clearAllAudioSolos()
            OnAirAudioMonitor.shared.refresh()
            return (200, ControlJSON.encode(onAirControlsJSON()))
        case ("GET", ["routing"]), ("GET", ["follow"]):
            return (200, ControlJSON.encode(["ok": true, "buses": Self.routingBuses, "rows": onAirRouting()]))
        case ("GET", ["returns"]):
            return (200, ControlJSON.encode(["ok": true, "returns": onAirReturnsSummary]))
        case ("POST", ["returns"]):
            guard let mode = args["mode"].flatMap(BackstageReturnFeedMode.init(wireKey:)) else {
                return (400, #"{"ok":false,"error":"mode must be mix, full or intercom"}"#)
            }
            let identity = args["identity"].flatMap { $0.isEmpty ? nil : $0 }
            setReturnMode(identity: identity, mode: mode)
            return (200, ControlJSON.encode(["ok": true, "returns": onAirReturnsSummary]))
        case ("POST", ["talkback"]):
            if let device = args["device"] {
                OnAirAudioControls.shared.talkDeviceID = (device.isEmpty || device == "default") ? nil : device
            }
            if let target = args["target"] {
                OnAirAudioControls.shared.talkTarget = (target.isEmpty || target == "all") ? nil : target
            }
            var result = OnAirControlResult.ok
            if let on = Self.flag(args["on"]) {
                if on {
                    result = startTalkback(toneHz: args["test_tone"].flatMap(Double.init))
                } else {
                    stopTalkback()
                }
            }
            return reply(result, ["returns": onAirReturnsSummary])
        case ("GET", ["talkback"]):
            return (200, ControlJSON.encode([
                "ok": true,
                "mics": TalkbackEngine.microphones().map { ["id": $0.id, "name": $0.name] },
                "returns": onAirReturnsSummary,
            ]))
        case ("POST", ["monitor", "capture"]):
            if let path = args["write"] {
                guard path.hasPrefix("/tmp/") else { return (400, #"{"ok":false,"error":"write under /tmp only"}"#) }
                let frames = MonitorBusCapture.write(to: URL(fileURLWithPath: path))
                return (200, ControlJSON.encode(["ok": true, "frames": frames, "path": path]))
            }
            let seconds = min(30, max(0.5, args["secs"].flatMap(Double.init) ?? 4))
            MonitorBusCapture.start(seconds: seconds)
            return (200, ControlJSON.encode(["ok": true, "armed": true, "secs": seconds]))
        default:
            return nil
        }
    }
}
