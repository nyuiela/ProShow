import Foundation
import Observation

/// Live rundown clock: block timing, schedule drift, and stage cue evaluation (10 Hz).
@MainActor
@Observable
final class RundownClockEngine {
    private(set) var program: ProgramDocumentModel?
    private(set) var activeBlockIndex: Int?
    private(set) var activeBlockElapsedSeconds: TimeInterval = 0
    private(set) var activeBlockRemainingSeconds: TimeInterval = 0
    private(set) var cumulativeDriftSeconds: TimeInterval = 0
    private(set) var currentStageMessage: String?
    private(set) var upcomingTalentCueText: String?
    private(set) var isShowRunning = false

    var onStageCue: ((String, Bool) -> Void)?
    var onBlockStarted: ((RundownBlock) -> Void)?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var firedCueKeys: Set<String> = []

    func loadProgram(_ program: ProgramDocumentModel) {
        stopShow(resetBlocks: false)
        self.program = program
        activeBlockIndex = program.runState.activeBlockIndex
        cumulativeDriftSeconds = program.runState.cumulativeDriftSeconds
        isShowRunning = program.runState.isShowRunning
        if isShowRunning {
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

    func startShow(at index: Int = 0) {
        guard var program, !program.rundownBlocks.isEmpty else { return }
        let clamped = min(max(0, index), program.rundownBlocks.count - 1)
        let now = Date()
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
        firedCueKeys.removeAll()
        currentStageMessage = nil
        startTimer()
        if let block = activeBlock {
            onBlockStarted?(block)
        }
    }

    func stopShow(resetBlocks: Bool = true) {
        timer?.invalidate()
        timer = nil
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
        currentStageMessage = nil
        upcomingTalentCueText = nil
        firedCueKeys.removeAll()
    }

    func advanceToNextBlock() {
        guard var program, let currentIdx = activeBlockIndex else { return }
        let now = Date()
        program.rundownBlocks[currentIdx].actualEndTime = now
        program.rundownBlocks[currentIdx].isCompleted = true

        let nextIdx = currentIdx + 1
        if nextIdx < program.rundownBlocks.count {
            program.rundownBlocks[nextIdx].actualStartTime = now
            program.rundownBlocks[nextIdx].isCompleted = false
            program.runState.activeBlockIndex = nextIdx
            activeBlockIndex = nextIdx
            currentStageMessage = nil
            firedCueKeys.removeAll()
            self.program = program
            onBlockStarted?(program.rundownBlocks[nextIdx])
        } else {
            program.runState.isShowRunning = false
            program.runState.activeBlockIndex = nil
            self.program = program
            stopShow(resetBlocks: false)
        }
    }

    func jumpToBlock(index: Int) {
        guard var program, program.rundownBlocks.indices.contains(index) else { return }
        let now = Date()
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
        firedCueKeys.removeAll()
        currentStageMessage = nil
        self.program = program
        startTimer()
        onBlockStarted?(program.rundownBlocks[index])
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickClock() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tickClock() {
        guard var program, let idx = activeBlockIndex, program.rundownBlocks.indices.contains(idx) else { return }
        let block = program.rundownBlocks[idx]
        guard let startTime = block.actualStartTime else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        let remaining = block.plannedDurationSeconds - elapsed

        activeBlockElapsedSeconds = max(0, elapsed)
        activeBlockRemainingSeconds = remaining

        evaluateStageCues(for: block, remainingSeconds: remaining)

        let priorPlanned = program.rundownBlocks.prefix(idx).reduce(0.0) { $0 + $1.plannedDurationSeconds }
        let expectedElapsedTotal = priorPlanned + elapsed
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
    }

    private func evaluateStageCues(for block: RundownBlock, remainingSeconds: TimeInterval) {
        let triggers = block.customCueTriggers.isEmpty
            ? (program?.defaultStageCueTriggers ?? [])
            : block.customCueTriggers
        for cue in triggers {
            let targetRemaining = TimeInterval(cue.triggerOffsetSeconds)
            let key = "\(block.id.uuidString)-\(cue.id.uuidString)"
            if abs(remainingSeconds - targetRemaining) < 0.25, !firedCueKeys.contains(key) {
                firedCueKeys.insert(key)
                currentStageMessage = cue.stageMessage
                onStageCue?(cue.stageMessage, cue.flashScreen)
            }
        }
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
