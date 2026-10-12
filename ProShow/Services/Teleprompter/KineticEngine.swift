import Foundation
import Observation

/// Word-by-word spillout clock for Caption-with-Intention.
@Observable
@MainActor
final class KineticEngine {
    private(set) var words: [SpokenWord] = []
    private(set) var activeIndex: Int = 0
    private(set) var isRunning = false
    private(set) var lines: [KineticLine] = []
    private(set) var lineWindow = KineticLineWindow(startLine: 0, visibleCount: 5)
    /// True while voice tracking is delaying the WPM floor advance.
    private(set) var voiceHoldActive = false

    /// Settings UI still exposes “words per page” — map to ~visible lines.
    private(set) var chunkCapacity: Int = 28

    /// Layout bookkeeping must not be Observation-tracked: `didSet` / computed bridges
    /// under `@Observable` re-entered `preferredVisibleLines` and blew the stack on launch.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var layoutWidth: CGFloat = 0
    @ObservationIgnored private var layoutHeight: CGFloat = 0
    @ObservationIgnored private var layoutFontSize: CGFloat = 42
    @ObservationIgnored private var layoutFontName: String = ".AppleSystemUIFont"
    /// User/settings cap; actual window may be smaller to fit the stage height.
    @ObservationIgnored private var settingsVisibleLines: Int = 5
    @ObservationIgnored private var fittedVisibleLines: Int = 5
    /// When the current word’s WPM hold started (for hybrid voice hold).
    @ObservationIgnored private var wordHoldStartedAt: Date?
    /// Max words voice may snap ahead in one match.
    @ObservationIgnored private let voiceSnapCap = 12

    var visibleLines: ArraySlice<KineticLine> {
        guard !lines.isEmpty, lineWindow.visibleCount > 0 else { return [] }
        let end = min(lines.count, lineWindow.startLine + lineWindow.visibleCount)
        return lines[lineWindow.startLine..<end]
    }

    /// Line of the nearest displayable word at/after `activeIndex` (includes long-pause chips).
    var activeLineIndex: Int? {
        guard !words.isEmpty else { return nil }
        var probe = min(activeIndex, max(0, words.count - 1))
        while probe < words.count, words[probe].isPauseOnly, !words[probe].isLongPause {
            probe += 1
        }
        if probe >= words.count {
            probe = activeIndex
            while probe >= 0, probe < words.count, words[probe].isPauseOnly, !words[probe].isLongPause {
                probe -= 1
            }
        }
        guard probe >= 0, probe < words.count else { return nil }
        return KineticLineBreaker.lineIndex(containing: probe, in: lines)
    }

    /// Active long-pause hold for countdown UI (`remaining`, `total`).
    var activeLongPause: (remaining: TimeInterval, total: TimeInterval)? {
        guard isRunning,
              activeIndex < words.count,
              words[activeIndex].isLongPause,
              let started = wordHoldStartedAt else { return nil }
        let total = words[activeIndex].totalDuration
        let elapsed = Date().timeIntervalSince(started)
        return (max(0, total - elapsed), total)
    }

    var progress: Double {
        guard !words.isEmpty else { return 0 }
        return Double(min(activeIndex, words.count)) / Double(words.count)
    }

    var isFinished: Bool {
        !words.isEmpty && activeIndex >= words.count
    }

    func load(script body: String, baseWPM: Int, pacing: ScriptPacing = .default) {
        pause()
        words = ScriptTokenizer.tokenize(body, baseWPM: baseWPM, pacing: pacing)
        activeIndex = 0
        rebuildLines()
        refitVisibleLines()
        lineWindow = KineticLineWindow(startLine: 0, visibleCount: fittedVisibleLines)
            .clamped(totalLines: lines.count)
    }

    /// Apply profile/settings chunk size and refit the visible line window.
    func setChunkCapacity(_ capacity: Int) {
        let clamped = min(60, max(8, capacity))
        chunkCapacity = clamped
        settingsVisibleLines = min(12, max(1, clamped / 5))
        refitVisibleLines()
        reconcileWindow()
    }

    /// Call when the prompt width / height / font changes so wrapping + visible lines fit the stage.
    func updateLayout(
        width: CGFloat,
        height: CGFloat,
        fontSize: CGFloat,
        fontName: String,
        lineBoxHeight: CGFloat
    ) {
        let widthChanged = abs(width - layoutWidth) > 0.5
        let heightChanged = abs(height - layoutHeight) > 0.5
        let sizeChanged = abs(fontSize - layoutFontSize) > 0.5
        let nameChanged = fontName != layoutFontName
        guard widthChanged || heightChanged || sizeChanged || nameChanged else { return }

        layoutWidth = max(0, width)
        layoutHeight = max(0, height)
        layoutFontSize = fontSize
        layoutFontName = fontName

        if widthChanged || sizeChanged || nameChanged {
            rebuildLines()
        }
        refitVisibleLines(lineBoxHeight: lineBoxHeight)
        reconcileWindow()
    }

    private func refitVisibleLines(lineBoxHeight: CGFloat? = nil) {
        let box = lineBoxHeight ?? max(1, layoutFontSize * 1.35)
        let fitFromHeight: Int = {
            guard layoutHeight > 8, box > 1 else { return settingsVisibleLines }
            // Leave padding so a centered stack doesn’t clip against panel chrome.
            let usable = max(box, layoutHeight - 12)
            return max(1, Int(floor(usable / box)))
        }()
        fittedVisibleLines = max(1, min(settingsVisibleLines, fitFromHeight))
    }

    func start() {
        guard !words.isEmpty else { return }
        if isFinished {
            reset()
        }
        isRunning = true
        voiceHoldActive = false
        scheduleAdvance()
    }

    func pause() {
        isRunning = false
        voiceHoldActive = false
        wordHoldStartedAt = nil
        runTask?.cancel()
        runTask = nil
    }

    func toggle() {
        if isRunning { pause() } else { start() }
    }

    func reset() {
        pause()
        activeIndex = 0
        refitVisibleLines()
        lineWindow = KineticLineWindow(startLine: 0, visibleCount: fittedVisibleLines)
            .clamped(totalLines: lines.count)
    }

    func seek(to index: Int) {
        guard !words.isEmpty else { return }
        activeIndex = min(max(0, index), words.count)
        voiceHoldActive = false
        reconcileWindow()
        if isRunning {
            scheduleAdvance()
        }
    }

    /// Speech matched script word `index` (word just spoken or still being spoken).
    /// Hybrid: snap ahead when talent is faster; hold WPM advance when behind.
    func applyVoiceMatch(at index: Int) {
        guard !words.isEmpty else { return }
        let spoken = min(max(0, index), words.count - 1)
        let next = nextSpeakableIndex(after: spoken) ?? (spoken + 1)

        // Talent ahead of the clock — snap forward (capped).
        if next > activeIndex {
            let capped = min(next, activeIndex + voiceSnapCap)
            seek(to: capped)
            return
        }

        // Still on / just behind the active word — hold if most of the WPM slot elapsed.
        guard isRunning, spoken <= activeIndex else { return }
        let hold = words[safe: activeIndex]?.totalDuration ?? 0.4
        let started = wordHoldStartedAt ?? Date()
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= hold * 0.6 else { return }

        voiceHoldActive = true
        runTask?.cancel()
        let grace = max(0.35, hold - elapsed + 0.25)
        let holdingIndex = activeIndex
        runTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, self.isRunning else { return }
            guard self.activeIndex == holdingIndex else { return }
            self.voiceHoldActive = false
            self.activeIndex += 1
            self.reconcileWindow()
            if self.activeIndex >= self.words.count {
                self.isRunning = false
                return
            }
            self.scheduleAdvance()
        }
    }

    /// Clear voice hold and resume the WPM floor if still running.
    func clearVoicePacing() {
        voiceHoldActive = false
        if isRunning {
            scheduleAdvance()
        } else {
            runTask?.cancel()
            runTask = nil
            wordHoldStartedAt = nil
        }
    }

    private func scheduleAdvance() {
        runTask?.cancel()
        voiceHoldActive = false
        guard isRunning else { return }
        guard activeIndex < words.count else {
            isRunning = false
            return
        }

        let hold = words[activeIndex].totalDuration
        wordHoldStartedAt = Date()
        runTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, self.isRunning else { return }
            self.activeIndex += 1
            self.reconcileWindow()
            if self.activeIndex >= self.words.count {
                self.isRunning = false
                return
            }
            self.scheduleAdvance()
        }
    }

    private func nextSpeakableIndex(after index: Int) -> Int? {
        var probe = index + 1
        while probe < words.count {
            if !words[probe].isPauseOnly { return probe }
            probe += 1
        }
        return words.count
    }

    private func rebuildLines() {
        guard layoutWidth > 8 else {
            lines = []
            return
        }
        lines = KineticLineBreaker.lines(
            words: words,
            maxWidth: layoutWidth,
            fontSize: layoutFontSize,
            fontName: layoutFontName
        )
    }

    private func reconcileWindow() {
        guard let activeLine = activeLineIndex else {
            lineWindow = lineWindow.clamped(totalLines: lines.count)
            return
        }
        lineWindow = KineticLineWindow.reconciled(
            previous: lineWindow,
            activeLine: activeLine,
            totalLines: lines.count,
            preferredVisibleCount: fittedVisibleLines
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
