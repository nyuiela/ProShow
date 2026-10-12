import Foundation
import Observation

/// Action Inspector state: props, messages, macros, timers, audio beds, and media transport.
@MainActor
@Observable
final class ActionInspectorEngine {
    var selectedTab: ActionInspectorTab = .props
    var previewFeed: PreviewFeed = .audience
    /// Independent Preview / Live for the Phone 9:16 monitor.
    var phonePreviewFeed: PreviewFeed = .stream
    var props: [ProShowProp] = []
    var messages: [ProShowMessage] = []
    var macros: [ProShowMacro] = []
    var timers: [InspectorTimer] = []
    var audioTracks: [InspectorAudioTrack] = []
    var collections: [String] = ActionInspectorCatalog.defaultPropCollections
    var selectedCollection: String = "Default Collection"
    var selectedPropID: UUID?
    var selectedMessageID: UUID?
    var selectedTimerID: UUID?
    var selectedAudioTrackID: UUID?
    var selectedMacroID: UUID?
    var transport = MediaTransportState.idle
    var lastExecutedMacroID: UUID?

    private weak var playback: MediaPlaybackEngine?
    private var transportAnchor: Date?
    private var transportAnchorPlayhead: TimeInterval = 0
    private var lastTick: Date?
    private var propDeadlines: [UUID: Date] = [:]

    func attachPlayback(_ engine: MediaPlaybackEngine) {
        playback = engine
    }

    func syncTransportFromPlayback() {
        guard let playback else { return }
        transport = playback.snapshot()
    }

    func install(_ catalog: ActionInspectorCatalog?) {
        let source = catalog ?? .empty
        props = source.props
        messages = source.messages
        macros = source.macros
        timers = source.timers
        audioTracks = source.audioTracks
        collections = Self.resolvedPropCollections(from: source)
        selectedCollection = source.selectedPropCollection
        if !collections.contains(selectedCollection) {
            selectedCollection = collections.first ?? "Default Collection"
        }
        reconcilePropCollections()
    }

    func snapshot() -> ActionInspectorCatalog {
        ActionInspectorCatalog(
            props: props,
            messages: messages,
            macros: macros,
            timers: timers,
            audioTracks: audioTracks,
            propCollections: collections,
            selectedPropCollection: selectedCollection
        )
    }

    static func resolvedPropCollections(from catalog: ActionInspectorCatalog) -> [String] {
        var names = catalog.propCollections.isEmpty
            ? ActionInspectorCatalog.defaultPropCollections
            : catalog.propCollections
        for prop in catalog.props where !prop.collectionName.isEmpty {
            if !names.contains(prop.collectionName) {
                names.append(prop.collectionName)
            }
        }
        return names.isEmpty ? ActionInspectorCatalog.defaultPropCollections : names
    }

    func reconcilePropCollections() {
        for prop in props where !prop.collectionName.isEmpty {
            ensureCollectionExists(prop.collectionName)
        }
        if collections.isEmpty {
            collections = ActionInspectorCatalog.defaultPropCollections
        }
        if !collections.contains(selectedCollection) {
            selectedCollection = collections.first ?? "Default Collection"
        }
    }

    func ensureCollectionExists(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !collections.contains(trimmed) {
            collections.append(trimmed)
        }
    }

    var visibleProps: [ProShowProp] {
        props.filter { $0.collectionName == selectedCollection }
    }

    func addProp(name: String = "New Prop") -> ProShowProp {
        ensureCollectionExists(selectedCollection)
        let prop = ProShowProp(name: name, collectionName: selectedCollection)
        props.append(prop)
        selectedPropID = prop.id
        return prop
    }

    func upsertProp(from document: EditorDocument) {
        if let index = props.firstIndex(where: { $0.id == document.id }) {
            props[index].name = document.name
            props[index].elements = document.objects
            props[index].autoClearMode = .parse(document.autoClear)
            props[index].transition = document.transition
            props[index].collectionName = document.collectionName
            props[index].transitionDuration = document.transitionDuration
            return
        }
        props.append(
            ProShowProp(
                id: document.id,
                name: document.name,
                elements: document.objects,
                transitionDuration: document.transitionDuration,
                autoClearMode: .parse(document.autoClear),
                collectionName: document.collectionName,
                transition: document.transition
            )
        )
        if selectedPropID == nil {
            selectedPropID = document.id
        }
    }

    /// Drops snapshot clones created when the editor used to mint a new prop on every mutation.
    func collapseDuplicateNamedProps() {
        var chosen: [String: Int] = [:]
        for (index, prop) in props.enumerated() {
            if let kept = chosen[prop.name] {
                let current = props[kept]
                let richer = prop.elements.count > current.elements.count
                    || (prop.elements.count == current.elements.count && index > kept)
                if richer {
                    chosen[prop.name] = index
                }
            } else {
                chosen[prop.name] = index
            }
        }
        guard chosen.count < props.count else { return }
        let keep = Set(chosen.values)
        let previousName = selectedPropID.flatMap { id in props.first(where: { $0.id == id })?.name }
        props = props.enumerated().compactMap { keep.contains($0.offset) ? $0.element : nil }
        if let id = selectedPropID, props.contains(where: { $0.id == id }) {
            return
        }
        if let previousName, let match = props.first(where: { $0.name == previousName }) {
            selectedPropID = match.id
        } else {
            selectedPropID = props.first?.id
        }
    }

    @discardableResult
    func renameProp(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = props.firstIndex(where: { $0.id == id }) else { return false }
        props[index].name = trimmed
        selectedPropID = id
        return true
    }

    @discardableResult
    func duplicateProp(id: UUID) -> ProShowProp? {
        guard let prop = props.first(where: { $0.id == id }) else { return nil }
        var copy = prop
        copy.id = UUID()
        copy.name = prop.name.hasSuffix(" Copy") ? prop.name : "\(prop.name) Copy"
        copy.isActive = false
        props.append(copy)
        selectedPropID = copy.id
        return copy
    }

    @discardableResult
    func deleteProp(id: UUID) -> Bool {
        guard props.contains(where: { $0.id == id }) else { return false }
        props.removeAll { $0.id == id }
        if selectedPropID == id { selectedPropID = nil }
        propDeadlines[id] = nil
        return true
    }

    func setPropAutoClear(id: UUID, mode: ProShowProp.AutoClearMode) {
        guard let index = props.firstIndex(where: { $0.id == id }) else { return }
        props[index].autoClearMode = mode
        selectedPropID = id
    }

    func setPropTransition(id: UUID, transition: String) {
        guard let index = props.firstIndex(where: { $0.id == id }) else { return }
        props[index].transition = transition
        selectedPropID = id
    }

    func setPropCollection(id: UUID, collection: String) {
        ensureCollectionExists(collection)
        guard let index = props.firstIndex(where: { $0.id == id }) else { return }
        props[index].collectionName = collection
        selectedPropID = id
    }

    func setPropElements(id: UUID, elements: [CanvasObject]) {
        guard let index = props.firstIndex(where: { $0.id == id }) else { return }
        props[index].elements = elements
    }

    func addMessage(title: String = "New Message", template: String = "{Name}") -> ProShowMessage {
        let message = ProShowMessage(title: title, templateText: template)
        messages.append(message)
        return message
    }

    func addMacro(name: String = "New Macro", actions: [MacroAction] = []) -> ProShowMacro {
        let macro = ProShowMacro(name: name, actions: actions)
        macros.append(macro)
        return macro
    }

    func addTimer(name: String = "Timer", kind: InspectorTimerKind = .countdown, seconds: Int = 300) -> InspectorTimer {
        let timer = InspectorTimer(name: name, kind: kind, durationSeconds: seconds)
        timers.append(timer)
        return timer
    }

    @discardableResult
    func toggleProp(id: UUID, now: Date = Date()) -> Bool {
        guard let index = props.firstIndex(where: { $0.id == id }) else { return false }
        selectedPropID = id
        var next = props
        next[index].isActive.toggle()
        if next[index].isActive {
            if case .afterDelay(let seconds) = next[index].autoClearMode {
                propDeadlines[id] = now.addingTimeInterval(seconds)
            }
        } else {
            propDeadlines[id] = nil
        }
        props = next
        return true
    }

    func selectProp(id: UUID) {
        selectedPropID = id
    }

    func deactivateAllProps() {
        var next = props
        for index in next.indices {
            next[index].isActive = false
        }
        props = next
        selectedPropID = nil
        propDeadlines.removeAll()
    }

    func applyAutoClearOnNextSlide() {
        var next = props
        var changed = false
        for index in next.indices where next[index].isActive {
            if case .onNextSlide = next[index].autoClearMode {
                next[index].isActive = false
                propDeadlines[next[index].id] = nil
                changed = true
            }
        }
        if changed {
            props = next
        }
    }

    var activePropNames: [String] {
        props.filter(\.isActive).map(\.name)
    }

    @discardableResult
    func showMessage(id: UUID) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return nil }
        selectedMessageID = id
        var next = messages
        for cursor in next.indices {
            next[cursor].isActive = cursor == index
        }
        messages = next
        return next[index].resolvedText()
    }

    func hideMessage(id: UUID? = nil) {
        var next = messages
        if let id, let index = next.firstIndex(where: { $0.id == id }) {
            next[index].isActive = false
            if selectedMessageID == id { selectedMessageID = nil }
        } else {
            for index in next.indices {
                next[index].isActive = false
            }
            selectedMessageID = nil
        }
        messages = next
    }

    func setMessageValue(id: UUID, key: String, value: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        var next = messages
        next[index].dynamicValues[key] = value
        messages = next
    }

    func selectMessage(id: UUID) {
        selectedMessageID = id
    }

    @discardableResult
    func startTimer(id: UUID) -> Bool {
        markTimerClock()
        return mutateTimer(id) { timer in
            armTimerIfNeeded(&timer)
            timer.isRunning = true
        }
    }

    @discardableResult
    func restartTimer(id: UUID) -> Bool {
        markTimerClock()
        return mutateTimer(id) { timer in
            resetTimerValue(&timer)
            timer.isRunning = true
        }
    }

    @discardableResult
    func stopTimer(id: UUID) -> Bool {
        mutateTimer(id) { $0.isRunning = false }
    }

    @discardableResult
    func resetTimer(id: UUID) -> Bool {
        markTimerClock()
        return mutateTimer(id) { timer in
            timer.isRunning = false
            resetTimerValue(&timer)
        }
    }

    private func resetTimerValue(_ timer: inout InspectorTimer) {
        timer.elapsedSeconds = 0
        timer.isOverrun = false
        switch timer.kind {
        case .countdown:
            timer.remainingSeconds = timer.durationSeconds
        case .countdownToTime:
            timer.remainingSeconds = Self.secondsUntil(hour: timer.targetHour, minute: timer.targetMinute, from: Date())
        case .elapsed:
            timer.remainingSeconds = 0
        }
    }

    private func armTimerIfNeeded(_ timer: inout InspectorTimer) {
        switch timer.kind {
        case .countdown where timer.remainingSeconds <= 0:
            resetTimerValue(&timer)
        case .countdownToTime:
            timer.remainingSeconds = Self.secondsUntil(hour: timer.targetHour, minute: timer.targetMinute, from: Date())
            timer.isOverrun = false
        default:
            break
        }
    }

    private func markTimerClock(now: Date = Date()) {
        lastTick = now
    }

    func timer(id: UUID?) -> InspectorTimer? {
        if let id, let match = timers.first(where: { $0.id == id }) {
            return match
        }
        return timers.first
    }

    @discardableResult
    func followProgramMedia(id: UUID, remaining: Int, duration: Int) -> Bool {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return false }
        let nextRemaining = max(0, remaining)
        let nextDuration = max(nextRemaining, duration)
        var timer = timers[index]
        guard timer.remainingSeconds != nextRemaining || timer.durationSeconds != nextDuration else { return false }
        timer.remainingSeconds = nextRemaining
        timer.durationSeconds = nextDuration
        timer.isOverrun = timer.kind != .elapsed && nextRemaining <= timer.overrunThresholdSeconds
        var next = timers
        next[index] = timer
        timers = next
        return true
    }

    @discardableResult
    func setTimerName(id: UUID, name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return mutateTimer(id) { $0.name = trimmed }
    }

    @discardableResult
    func setTimerKind(id: UUID, kind: InspectorTimerKind) -> Bool {
        mutateTimer(id) { timer in
            timer.kind = kind
            switch kind {
            case .countdown:
                timer.remainingSeconds = timer.durationSeconds
            case .countdownToTime:
                timer.remainingSeconds = Self.secondsUntil(hour: timer.targetHour, minute: timer.targetMinute, from: Date())
            case .elapsed:
                timer.elapsedSeconds = 0
                timer.remainingSeconds = 0
            }
            timer.isOverrun = timer.kind != .elapsed && timer.remainingSeconds <= timer.overrunThresholdSeconds
        }
    }

    @discardableResult
    func setTimerDuration(id: UUID, seconds: Int) -> Bool {
        mutateTimer(id) { timer in
            timer.durationSeconds = max(0, seconds)
            if timer.kind == .countdown {
                timer.remainingSeconds = timer.durationSeconds
                timer.isOverrun = timer.remainingSeconds <= timer.overrunThresholdSeconds
            }
        }
    }

    @discardableResult
    func setTimerTarget(id: UUID, hour: Int, minute: Int) -> Bool {
        mutateTimer(id) { timer in
            timer.targetHour = min(23, max(0, hour))
            timer.targetMinute = min(59, max(0, minute))
            if timer.kind == .countdownToTime {
                timer.remainingSeconds = Self.secondsUntil(hour: timer.targetHour, minute: timer.targetMinute, from: Date())
                timer.isOverrun = timer.remainingSeconds <= timer.overrunThresholdSeconds
            }
        }
    }

    func playAudioTrack(id: UUID) -> InspectorAudioTrack? {
        selectedAudioTrackID = id
        var next = audioTracks
        for index in next.indices {
            next[index].isPlaying = next[index].id == id
        }
        audioTracks = next
        return next.first(where: { $0.id == id })
    }

    func stopAudioTracks() {
        var next = audioTracks
        for index in next.indices {
            next[index].isPlaying = false
        }
        audioTracks = next
        selectedAudioTrackID = nil
    }

    func setTrackVolume(id: UUID, volume: Double) {
        guard let index = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        var next = audioTracks
        next[index].volume = volume
        audioTracks = next
    }

    func setTrackDestination(id: UUID, destination: AudioOutputBus) {
        guard let index = audioTracks.firstIndex(where: { $0.id == id }) else { return }
        var next = audioTracks
        next[index].destination = destination
        audioTracks = next
    }

    func stopAllTimers() {
        var next = timers
        for index in next.indices {
            next[index].isRunning = false
        }
        timers = next
        selectedTimerID = nil
    }

    func clearInspectorSelections() {
        deactivateAllProps()
        hideMessage()
        stopAudioTracks()
        stopAllTimers()
        selectedMacroID = nil
        lastExecutedMacroID = nil
    }

    func bindMedia(_ media: MediaAction?) {
        if let playback {
            playback.load(media, restart: false)
            transport = playback.snapshot()
            return
        }
        guard let media else {
            transport = .idle
            transportAnchor = nil
            return
        }
        let duration = MediaDurationParser.seconds(from: media.duration)
        transport = MediaTransportState(
            title: media.title,
            duration: duration > 0 ? duration : 60,
            playhead: 0,
            isPlaying: !media.isImage,
            isLooping: transport.isLooping,
            markers: duration > 0 ? [0, duration / 2] : [0]
        )
        transportAnchor = Date()
        transportAnchorPlayhead = 0
    }

    func playTransport() {
        if let playback {
            playback.play()
            transport = playback.snapshot()
            return
        }
        transport.isPlaying = true
        transportAnchor = Date()
        transportAnchorPlayhead = transport.playhead
    }

    func pauseTransport() {
        if let playback {
            playback.pause()
            transport = playback.snapshot()
            return
        }
        transport.isPlaying = false
        transportAnchor = nil
    }

    func toggleTransport() {
        if let playback {
            playback.toggle()
            transport = playback.snapshot()
            return
        }
        if transport.isPlaying { pauseTransport() } else { playTransport() }
    }

    func skipTransport(seconds: TimeInterval) {
        if let playback {
            playback.skip(seconds: seconds)
            transport = playback.snapshot()
            return
        }
        seekTransport(to: transport.playhead + seconds)
    }

    func seekTransport(to seconds: TimeInterval) {
        if let playback {
            playback.seek(to: seconds)
            transport = playback.snapshot()
            return
        }
        let duration = max(transport.duration, 0)
        let next = duration == 0 ? 0 : min(max(0, seconds), duration)
        transport.playhead = next
        transportAnchorPlayhead = next
        transportAnchor = transport.isPlaying ? Date() : nil
        if next >= duration, duration > 0, !transport.isLooping {
            transport.isPlaying = false
        }
    }

    func toggleLoop() {
        if let playback {
            playback.toggleLoop()
            transport = playback.snapshot()
            return
        }
        transport.isLooping.toggle()
    }

    func jumpToNextMarker() {
        if let playback {
            playback.jumpToNextMarker()
            transport = playback.snapshot()
            return
        }
        let upcoming = transport.markers.filter { $0 > transport.playhead + 0.05 }.sorted()
        if let next = upcoming.first {
            seekTransport(to: next)
        } else if let first = transport.markers.sorted().first {
            seekTransport(to: first)
        }
    }

    func tick(now: Date = Date(), advanceTransport: Bool = true) {
        if let playback {
            playback.tick(now: now)
            transport = playback.snapshot()
        } else if advanceTransport {
            tickTransport(now: now)
        }
        tickTimers(now: now)
        tickPropDelays(now: now)
    }

    private func tickTransport(now: Date) {
        guard transport.isPlaying else { return }
        let anchor = transportAnchor ?? now
        var playhead = transportAnchorPlayhead + now.timeIntervalSince(anchor)
        if transport.duration > 0, playhead >= transport.duration {
            if transport.isLooping {
                playhead = playhead.truncatingRemainder(dividingBy: transport.duration)
                transportAnchor = now
                transportAnchorPlayhead = playhead
            } else {
                playhead = transport.duration
                transport.isPlaying = false
                transportAnchor = nil
            }
        }
        transport.playhead = playhead
    }

    private func tickTimers(now: Date) {
        if lastTick == nil {
            lastTick = now
            refreshAbsoluteTimers(now: now)
            return
        }
        let last = lastTick ?? now
        let rawStep = Int(now.timeIntervalSince(last).rounded(.towardZero))
        let step = rawStep > 3 ? 1 : max(0, rawStep)
        if step > 0 {
            lastTick = last.addingTimeInterval(TimeInterval(step))
        }
        var next = timers
        var changed = false
        if step > 0 {
            for index in next.indices where next[index].isRunning {
                switch next[index].kind {
                case .elapsed:
                    next[index].elapsedSeconds += step
                    changed = true
                case .countdown:
                    next[index].remainingSeconds = max(0, next[index].remainingSeconds - step)
                    if next[index].remainingSeconds == 0 {
                        next[index].isRunning = false
                    }
                    next[index].isOverrun = next[index].remainingSeconds <= next[index].overrunThresholdSeconds
                    changed = true
                case .countdownToTime:
                    break
                }
            }
        }
        for index in next.indices where next[index].isRunning && next[index].kind == .countdownToTime {
            let remaining = Self.secondsUntil(
                hour: next[index].targetHour,
                minute: next[index].targetMinute,
                from: now
            )
            if next[index].remainingSeconds != remaining {
                next[index].remainingSeconds = remaining
                next[index].isOverrun = remaining <= next[index].overrunThresholdSeconds
                changed = true
            }
        }
        if changed {
            timers = next
        }
    }

    private func refreshAbsoluteTimers(now: Date) {
        var next = timers
        var changed = false
        for index in next.indices where next[index].isRunning && next[index].kind == .countdownToTime {
            let remaining = Self.secondsUntil(
                hour: next[index].targetHour,
                minute: next[index].targetMinute,
                from: now
            )
            if next[index].remainingSeconds != remaining {
                next[index].remainingSeconds = remaining
                next[index].isOverrun = remaining <= next[index].overrunThresholdSeconds
                changed = true
            }
        }
        if changed {
            timers = next
        }
    }

    private func tickPropDelays(now: Date) {
        let expired = propDeadlines.filter { now >= $0.value }.map(\.key)
        guard !expired.isEmpty else { return }
        var next = props
        for id in expired {
            if let index = next.firstIndex(where: { $0.id == id }) {
                next[index].isActive = false
            }
            propDeadlines[id] = nil
        }
        props = next
    }

    @discardableResult
    private func mutateTimer(_ id: UUID, _ body: (inout InspectorTimer) -> Void) -> Bool {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return false }
        selectedTimerID = id
        var next = timers
        body(&next[index])
        timers = next
        return true
    }

    static func secondsUntil(hour: Int, minute: Int, from now: Date) -> Int {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        guard var target = Calendar.current.date(from: components) else { return 0 }
        if target <= now {
            target = Calendar.current.date(byAdding: .day, value: 1, to: target) ?? target
        }
        return max(0, Int(target.timeIntervalSince(now)))
    }
}
