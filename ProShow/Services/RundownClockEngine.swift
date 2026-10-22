import Foundation
import Observation

/// What the prompter says about the live item's script, for the auto-advance guard.
enum RundownScriptState: Equatable, Sendable {
    /// No script, or the prompter is not following this item. The item runs on its duration.
    case none
    /// The prompter is still reading this item (running or paused part way).
    case reading
    /// The prompter reached the end of this item's script at this time.
    case finished(at: Date)
}

enum RundownAdvanceReason: String, Codable, Sendable {
    case manual
    case jump
    case clock
    case scriptEnd
    case scriptCap
}

struct RundownAdvanceRecord: Equatable, Sendable {
    var fromIndex: Int
    var toIndex: Int?
    var reason: RundownAdvanceReason
    /// When the cut was due (clock boundary, script end plus tail, or the cap). Nil for manual.
    var dueAt: Date?
    var firedAt: Date
}

/// Live rundown clock: block timing, schedule drift, stage cues, Hold, +30 s and auto-advance.
@MainActor
@Observable
final class RundownClockEngine {
    /// Wait this long after the prompter finishes before the auto cut.
    static let scriptTailSeconds: TimeInterval = 0.75
    /// Never hold an auto cut more than this past the planned end, even if the script is unread.
    static let scriptCapSeconds: TimeInterval = 12
    static let extendStepSeconds: TimeInterval = 30
    static let tickInterval: TimeInterval = 0.05

    private(set) var program: ProgramDocumentModel?
    private(set) var activeBlockIndex: Int?
    private(set) var activeBlockElapsedSeconds: TimeInterval = 0
    private(set) var activeBlockRemainingSeconds: TimeInterval = 0
    /// Seconds added to the live item with +30 s.
    private(set) var activeBlockExtensionSeconds: TimeInterval = 0
    private(set) var cumulativeDriftSeconds: TimeInterval = 0
    private(set) var currentStageMessage: String?
    private(set) var upcomingTalentCueText: String?
    private(set) var isShowRunning = false
    /// Hold freezes the item clock and auto-advance.
    private(set) var isHeld = false
    /// Auto mode reached the end of a stop item and is waiting for Next.
    private(set) var isStoppedAtItem = false
    /// Auto mode is past the planned end and waiting for the prompter to finish.
    private(set) var isWaitingOnScript = false
    private(set) var lastAdvance: RundownAdvanceRecord?

    var autoAdvanceEnabled = false {
        didSet {
            if !autoAdvanceEnabled {
                isWaitingOnScript = false
                isStoppedAtItem = false
                cancelPreciseCut()
            }
        }
    }

    var onStageCue: ((String, Bool) -> Void)?
    var onBlockStarted: ((RundownBlock) -> Void)?
    /// Reports the prompter state for the live item. Nil means no prompter: the duration rules.
    @ObservationIgnored var scriptStateProvider: ((RundownBlock) -> RundownScriptState)?
    /// Tests drive `tick(now:)` themselves.
    @ObservationIgnored var usesLiveTimer = true

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var preciseCut: DispatchWorkItem?
    @ObservationIgnored private var firedCueKeys: Set<String> = []
    @ObservationIgnored private var lastTickAt: Date?
    @ObservationIgnored private var previousRemaining: TimeInterval?

    func loadProgram(_ program: ProgramDocumentModel) {
        stopShow(resetBlocks: false)
        self.program = program
        activeBlockIndex = program.runState.activeBlockIndex
        cumulativeDriftSeconds = program.runState.cumulativeDriftSeconds
        isShowRunning = program.runState.isShowRunning
        if isShowRunning {
            if let idx = activeBlockIndex, let start = program.rundownBlocks[safe: idx]?.actualStartTime {
                activeBlockElapsedSeconds = max(0, Date().timeIntervalSince(start))
            }
            lastTickAt = Date()
            startTimer()
        }
    }

    func replaceProgram(_ program: ProgramDocumentModel) {
        self.program = program
    }

    var activeBlock: RundownBlock? {
        guard let program, let idx = activeBlockIndex, program.rundownBlocks.indices.contains(idx) else { return nil }
        return program.rundownBlocks[idx]
    }

    /// Planned length of the live item including +30 s extensions.
    var activeBlockPlannedSeconds: TimeInterval {
        (activeBlock?.plannedDurationSeconds ?? 0) + activeBlockExtensionSeconds
    }

    func startShow(at index: Int = 0, now: Date = Date()) {
        guard var program, !program.rundownBlocks.isEmpty else { return }
        let clamped = min(max(0, index), program.rundownBlocks.count - 1)
        program.runState.isShowRunning = true
        if program.runState.showStartedAt == nil {
            program.runState.showStartedAt = now
        }
        program.runState.activeBlockIndex = clamped
        program.rundownBlocks[clamped].actualStartTime = now
        program.rundownBlocks[clamped].isCompleted = false
        self.program = program
        activeBlockIndex = clamped
        isShowRunning = true
        resetItemState(now: now)
        startTimer()
        if let block = activeBlock {
            onBlockStarted?(block)
        }
    }

    func stopShow(resetBlocks: Bool = true) {
        timer?.invalidate()
        timer = nil
        cancelPreciseCut()
        isShowRunning = false
        if resetBlocks, var program {
            program.runState = ProgramRunEngineState()
            for index in program.rundownBlocks.indices {
                program.rundownBlocks[index].actualStartTime = nil
                program.rundownBlocks[index].actualEndTime = nil
                program.rundownBlocks[index].isCompleted = false
            }
            self.program = program
        }
        activeBlockIndex = program?.runState.activeBlockIndex
        activeBlockElapsedSeconds = 0
        activeBlockRemainingSeconds = 0
        activeBlockExtensionSeconds = 0
        currentStageMessage = nil
        upcomingTalentCueText = nil
        isHeld = false
        isStoppedAtItem = false
        isWaitingOnScript = false
        firedCueKeys.removeAll()
        previousRemaining = nil
        lastTickAt = nil
    }

    /// Next (Skip). Moves on now, held or not.
    func advanceToNextBlock(now: Date = Date()) {
        advance(reason: .manual, dueAt: nil, now: now)
    }

    func jumpToBlock(index: Int, now: Date = Date()) {
        guard var program, program.rundownBlocks.indices.contains(index) else { return }
        let from = activeBlockIndex
        if let currentIdx = activeBlockIndex, program.rundownBlocks.indices.contains(currentIdx) {
            program.rundownBlocks[currentIdx].actualEndTime = now
            program.rundownBlocks[currentIdx].isCompleted = true
        }
        program.rundownBlocks[index].actualStartTime = now
        program.rundownBlocks[index].isCompleted = false
        program.runState.activeBlockIndex = index
        program.runState.isShowRunning = true
        activeBlockIndex = index
        isShowRunning = true
        self.program = program
        lastAdvance = RundownAdvanceRecord(fromIndex: from ?? index, toIndex: index, reason: .jump, dueAt: nil, firedAt: now)
        resetItemState(now: now)
        startTimer()
        onBlockStarted?(program.rundownBlocks[index])
    }

    /// Hold freezes the item clock and auto-advance. Press again to resume.
    func toggleHold(now: Date = Date()) {
        setHeld(!isHeld, now: now)
    }

    func setHeld(_ held: Bool, now: Date = Date()) {
        guard isShowRunning, held != isHeld else { return }
        // Bank the time up to this moment before freezing or resuming.
        tick(now: now)
        isHeld = held
        if held {
            cancelPreciseCut()
            isWaitingOnScript = false
        }
        lastTickAt = now
    }

    /// +30 s on the live item.
    func extendActiveBlock(by seconds: TimeInterval = RundownClockEngine.extendStepSeconds, now: Date = Date()) {
        guard isShowRunning, activeBlock != nil else { return }
        tick(now: now)
        activeBlockExtensionSeconds += seconds
        isStoppedAtItem = false
        isWaitingOnScript = false
        cancelPreciseCut()
        activeBlockRemainingSeconds = activeBlockPlannedSeconds - activeBlockElapsedSeconds
        // A later cue may cross again after the extension, but each still fires once per item.
        previousRemaining = activeBlockRemainingSeconds
    }

    // MARK: - Clock

    private func advance(reason: RundownAdvanceReason, dueAt: Date?, now: Date) {
        guard var program, let currentIdx = activeBlockIndex else { return }
        cancelPreciseCut()
        program.rundownBlocks[currentIdx].actualEndTime = now
        program.rundownBlocks[currentIdx].isCompleted = true

        let nextIdx: Int? = reason == .manual
            ? (currentIdx + 1 < program.rundownBlocks.count ? currentIdx + 1 : nil)
            : RundownAutoAdvanceRules.nextAutoIndex(after: currentIdx, in: program.rundownBlocks)
        lastAdvance = RundownAdvanceRecord(fromIndex: currentIdx, toIndex: nextIdx, reason: reason, dueAt: dueAt, firedAt: now)
        if let nextIdx {
            program.rundownBlocks[nextIdx].actualStartTime = now
            program.rundownBlocks[nextIdx].isCompleted = false
            program.runState.activeBlockIndex = nextIdx
            activeBlockIndex = nextIdx
            self.program = program
            resetItemState(now: now)
            onBlockStarted?(program.rundownBlocks[nextIdx])
        } else {
            program.runState.isShowRunning = false
            program.runState.activeBlockIndex = nil
            self.program = program
            stopShow(resetBlocks: false)
        }
    }

    private func resetItemState(now: Date) {
        activeBlockElapsedSeconds = 0
        activeBlockExtensionSeconds = 0
        activeBlockRemainingSeconds = activeBlock?.plannedDurationSeconds ?? 0
        previousRemaining = nil
        lastTickAt = now
        isHeld = false
        isStoppedAtItem = false
        isWaitingOnScript = false
        currentStageMessage = nil
        firedCueKeys.removeAll()
    }

    private func startTimer() {
        guard usesLiveTimer else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// One clock step. The live timer calls this at 20 Hz; tests call it with their own times.
    func tick(now: Date = Date()) {
        guard isShowRunning, var program, let idx = activeBlockIndex, program.rundownBlocks.indices.contains(idx) else { return }
        let block = program.rundownBlocks[idx]
        guard block.actualStartTime != nil else { return }
        let delta = lastTickAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        lastTickAt = now
        if !isHeld {
            activeBlockElapsedSeconds += delta
        }
        let remaining = activeBlockPlannedSeconds - activeBlockElapsedSeconds
        activeBlockRemainingSeconds = remaining

        evaluateStageCues(for: block, previous: previousRemaining, current: remaining)
        previousRemaining = remaining

        let priorPlanned = program.rundownBlocks.prefix(idx).reduce(0.0) { $0 + $1.plannedDurationSeconds }
        let expectedElapsedTotal = priorPlanned + activeBlockElapsedSeconds
        let wallClockElapsedTotal = now.timeIntervalSince(program.hardStartTime)
        cumulativeDriftSeconds = wallClockElapsedTotal - expectedElapsedTotal
        program.runState.cumulativeDriftSeconds = cumulativeDriftSeconds
        self.program = program

        if remaining <= 60, idx + 1 < program.rundownBlocks.count {
            let nextBlock = program.rundownBlocks[idx + 1]
            if let firstTalentId = nextBlock.assignedTalentIds.first,
               let talent = program.talentDatabase.first(where: { $0.id == firstTalentId }) {
                upcomingTalentCueText = "NEXT (\(max(0, Int(remaining)))s): \(talent.fullName) · \(talent.titleOrRole)"
            } else {
                upcomingTalentCueText = "NEXT (\(max(0, Int(remaining)))s): \(nextBlock.title)"
            }
        } else {
            upcomingTalentCueText = nil
        }

        evaluateAutoAdvance(block: block, index: idx, remaining: remaining, now: now)
    }

    /// Cue offsets are seconds before the end, whatever their sign (older files stored -60).
    /// A cue fires when the countdown crosses it: previous > t >= current. Once per item, so holds,
    /// +30 s and stalls never repeat or skip it.
    private func evaluateStageCues(for block: RundownBlock, previous: TimeInterval?, current: TimeInterval) {
        let triggers = block.customCueTriggers.isEmpty
            ? (program?.defaultStageCueTriggers ?? [])
            : block.customCueTriggers
        // The first tick of an item starts at its planned length, so a cue at exactly that time fires.
        let previous = previous ?? (current + 0.000_1)
        guard previous > current else { return }
        let crossed = triggers
            .filter { cue in
                let t = TimeInterval(abs(cue.triggerOffsetSeconds))
                return previous > t && t >= current
            }
            .sorted { abs($0.triggerOffsetSeconds) > abs($1.triggerOffsetSeconds) }
        for cue in crossed {
            let key = "\(block.id.uuidString)-\(cue.id.uuidString)"
            guard !firedCueKeys.contains(key) else { continue }
            firedCueKeys.insert(key)
            currentStageMessage = cue.stageMessage
            onStageCue?(cue.stageMessage, cue.flashScreen)
        }
    }

    private func evaluateAutoAdvance(block: RundownBlock, index: Int, remaining: TimeInterval, now: Date) {
        guard autoAdvanceEnabled, !isHeld, isShowRunning else {
            isWaitingOnScript = false
            return
        }
        guard let program else { return }
        let stopItem = RundownAutoAdvanceRules.isStopItem(at: index, in: program.rundownBlocks)
        if stopItem {
            isStoppedAtItem = remaining <= 0
            isWaitingOnScript = false
            return
        }
        // Item time past the planned end (holds excluded). Negative: still before the end.
        let over = -remaining
        // How far past the end the cut is due, in item time.
        let dueOver: TimeInterval
        let reason: RundownAdvanceReason
        switch scriptStateProvider?(block) ?? .none {
        case .none:
            dueOver = 0
            reason = .clock
        case .finished(let at):
            let finishedOver = over - max(0, now.timeIntervalSince(at))
            if finishedOver <= 0 {
                dueOver = 0
                reason = .clock
            } else {
                let tailed = finishedOver + Self.scriptTailSeconds
                dueOver = min(tailed, Self.scriptCapSeconds)
                reason = tailed > Self.scriptCapSeconds ? .scriptCap : .scriptEnd
            }
        case .reading:
            dueOver = Self.scriptCapSeconds
            reason = .scriptCap
        }
        let wait = dueOver - over
        isWaitingOnScript = over >= 0 && dueOver > 0 && wait > 0
        let dueAt = now.addingTimeInterval(wait)
        if wait <= 0 {
            advance(reason: reason, dueAt: dueAt, now: now)
        } else if wait <= Self.tickInterval * 2 {
            schedulePreciseCut(at: dueAt)
        }
    }

    /// Lands the cut on the due time instead of the next 50 ms tick.
    private func schedulePreciseCut(at dueAt: Date) {
        guard usesLiveTimer, preciseCut == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.preciseCut = nil
                self.tick(now: max(Date(), dueAt))
            }
        }
        preciseCut = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, dueAt.timeIntervalSinceNow), execute: item)
    }

    private func cancelPreciseCut() {
        preciseCut?.cancel()
        preciseCut = nil
    }

    func projectedDrift(forBlockAt index: Int, assumingOnScheduleAfter activeIdx: Int) -> TimeInterval? {
        guard let program, program.rundownBlocks.indices.contains(index) else { return nil }
        if index == activeIdx { return cumulativeDriftSeconds }
        if index < activeIdx {
            guard let block = program.rundownBlocks[safe: index],
                  let start = block.actualStartTime,
                  let end = block.actualEndTime
            else { return nil }
            let actual = end.timeIntervalSince(start)
            return actual - block.plannedDurationSeconds
        }
        return nil
    }
}

/// Prompter words per minute that fit an item's script into its planned duration.
enum ProgramPromptPacing {
    /// Nil keeps the prompter's own speed (no script, no duration, or the item asks for it).
    static func wpm(for block: RundownBlock, plannedSeconds: TimeInterval, baseWPM: Int, pacing: ScriptPacing) -> Int? {
        guard (block.promptPacing ?? .defaultMode) == .fitDuration else { return nil }
        return fittedWPM(script: block.scriptBody, plannedSeconds: plannedSeconds, pacing: pacing)
    }

    /// Script time is word time (scales with 1/wpm) plus fixed holds for pauses and punctuation.
    /// Two tokenizations separate them; then solve for the planned duration and clamp to 120...240.
    static func fittedWPM(script: String, plannedSeconds: TimeInterval, pacing: ScriptPacing) -> Int? {
        guard plannedSeconds > 0, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let range = PromptPacingMode.wpmRange
        let slow = total(script, wpm: range.lowerBound, pacing: pacing)
        let fast = total(script, wpm: range.upperBound, pacing: pacing)
        let ratio = Double(range.upperBound) / Double(range.lowerBound)
        // slow = K/lo + P, fast = K/hi + P
        let wordTimeAtFast = (slow - fast) / (ratio - 1)
        let holds = fast - wordTimeAtFast
        guard wordTimeAtFast > 0 else { return nil }
        let available = plannedSeconds - holds
        guard available > 0 else { return range.upperBound }
        let wpm = Double(range.upperBound) * wordTimeAtFast / available
        return min(range.upperBound, max(range.lowerBound, Int(wpm.rounded())))
    }

    static func total(_ script: String, wpm: Int, pacing: ScriptPacing) -> TimeInterval {
        ScriptTokenizer.tokenize(script, baseWPM: wpm, pacing: pacing).reduce(0) { $0 + $1.totalDuration }
    }
}

/// Which items auto-advance stops at, and which ones it skips over.
enum RundownAutoAdvanceRules {
    /// Explicit `stopHere` wins. Otherwise auto stops at:
    /// the first item when it is a waiting slate (Starting soon, Pre-show, Countdown, Waiting room),
    /// STANDBY or BRB items, an Outro, and the last item.
    static func isStopItem(at index: Int, in blocks: [RundownBlock]) -> Bool {
        guard blocks.indices.contains(index) else { return false }
        let block = blocks[index]
        if let explicit = block.stopHere { return explicit }
        return derivedStop(at: index, in: blocks)
    }

    static func derivedStop(at index: Int, in blocks: [RundownBlock]) -> Bool {
        guard blocks.indices.contains(index) else { return false }
        let block = blocks[index]
        if index == blocks.count - 1 { return true }
        if index == 0, isWaitingSlate(block) { return true }
        if isStandby(block) { return true }
        if isOutro(block) { return true }
        return false
    }

    /// Auto never cuts into an only-if-needed standby item (STANDBY or BRB without an explicit
    /// `stopHere`); it goes to the next item instead. Manual Next still takes it. Nil when nothing is left.
    static func nextAutoIndex(after index: Int, in blocks: [RundownBlock]) -> Int? {
        var probe = index + 1
        while blocks.indices.contains(probe) {
            if !isStandby(blocks[probe]) || blocks[probe].stopHere != nil { return probe }
            probe += 1
        }
        return nil
    }

    static func isWaitingSlate(_ block: RundownBlock) -> Bool {
        let title = normalized(block.title)
        return ["starting soon", "pre show", "preshow", "countdown", "waiting room", "stream starting"]
            .contains { title.contains($0) }
    }

    static func isStandby(_ block: RundownBlock) -> Bool {
        let words = Set(normalized(block.title).split(separator: " ").map(String.init))
        return words.contains("standby") || words.contains("brb") || normalized(block.title).contains("be right back")
    }

    static func isOutro(_ block: RundownBlock) -> Bool {
        let title = normalized(block.title)
        return title.hasPrefix("outro") || title.contains(" outro") || title.hasPrefix("end slate")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
