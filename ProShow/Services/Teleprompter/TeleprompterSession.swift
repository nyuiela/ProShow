import Foundation
import Observation

/// Shared CueLog playhead for the in-app prompt and the floating window.
@MainActor
@Observable
final class TeleprompterSession {
    static let shared = TeleprompterSession()

    let engine = KineticEngine()
    let scroll = ScrollEngine()

    private(set) var script: String = ""
    private var loadedSignature = ""
    private var scrubOriginWordIndex: Int?
    private var scrubOriginOffset: Double?
    private var resumeAfterScrub = false

    private init() {}

    var isRunning: Bool {
        engine.isRunning || scroll.isRunning
    }

    /// Play at the top, Continue after a pause mid-script, Pause while rolling.
    var transport: PromptTransport {
        if isRunning { return .pause }
        if engine.isFinished { return .play }
        if engine.activeIndex > 0 || scroll.offset > 2 { return .continue }
        return .play
    }

    /// Words per minute the program picks for a script (fit to the item's duration). Nil: settings.
    @ObservationIgnored var programWPMResolver: ((String) -> Int?)?

    func effectiveWPM(for script: String, settings: TeleprompterSettingsStore) -> Int {
        programWPMResolver?(script) ?? settings.baseWPM
    }

    /// True when the prompter is rolling, or rolled to the end of the current script.
    var rolledThrough: Bool {
        isRunning || engine.finishedAt != nil || scroll.finishedAt != nil
    }

    /// Program advance: the next item's script from the top, still rolling when asked.
    /// Loads even when the text matches the last item, because it is a new read.
    func loadProgramItem(script: String, settings: TeleprompterSettingsStore, keepRolling: Bool) {
        self.script = script
        engine.setChunkCapacity(settings.style.chunkCapacity)
        loadedSignature = Self.signature(script: script, wpm: effectiveWPM(for: script, settings: settings), settings: settings)
        engine.load(script: script, baseWPM: effectiveWPM(for: script, settings: settings), pacing: settings.style.scriptPacing)
        engine.setChunkCapacity(settings.style.chunkCapacity)
        scroll.reset()
        guard keepRolling, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch settings.promptEngine {
        case .kinetic:
            engine.start()
        case .scroll:
            scroll.speedPointsPerSecond = settings.scrollSpeed
            scroll.start()
        }
    }

    func loadIfNeeded(script: String, settings: TeleprompterSettingsStore) {
        let wpm = effectiveWPM(for: script, settings: settings)
        let signature = Self.signature(script: script, wpm: wpm, settings: settings)
        self.script = script
        engine.setChunkCapacity(settings.style.chunkCapacity)
        guard signature != loadedSignature else { return }
        let wasRunning = engine.isRunning
        loadedSignature = signature
        engine.load(script: script, baseWPM: wpm, pacing: settings.style.scriptPacing)
        engine.setChunkCapacity(settings.style.chunkCapacity)
        scroll.reset()
        if wasRunning, settings.promptEngine == .kinetic {
            engine.start()
        }
    }

    func primaryAction(settings: TeleprompterSettingsStore) {
        switch settings.promptEngine {
        case .kinetic:
            scroll.pause()
            engine.toggle()
        case .scroll:
            engine.pause()
            scroll.speedPointsPerSecond = settings.scrollSpeed
            scroll.toggle()
        }
    }

    func restart(settings: TeleprompterSettingsStore) {
        engine.reset()
        scroll.reset()
        primaryAction(settings: settings)
    }

    /// CueLog stage drag. A movement under 6pt is a tap and toggles play.
    func handleScrubChanged(translationY: CGFloat, settings: TeleprompterSettingsStore) {
        let delta = -Double(translationY)
        switch settings.promptEngine {
        case .kinetic:
            if scrubOriginWordIndex == nil {
                scrubOriginWordIndex = engine.activeIndex
                resumeAfterScrub = engine.isRunning
                if engine.isRunning { engine.pause() }
            }
            let pointsPerWord = max(10.0, settings.fontSize * 0.65)
            let wordDelta = Int((delta / pointsPerWord).rounded())
            engine.seek(to: (scrubOriginWordIndex ?? 0) + wordDelta)
        case .scroll:
            if scrubOriginOffset == nil {
                scrubOriginOffset = scroll.offset
                resumeAfterScrub = scroll.isRunning
                if scroll.isRunning { scroll.pause() }
            }
            scroll.seek(to: (scrubOriginOffset ?? 0) + delta)
        }
    }

    func handleScrubEnded(translationY: CGFloat, predictedTranslationY: CGFloat, settings: TeleprompterSettingsStore) {
        let shouldResume = resumeAfterScrub
        let originOffset = scrubOriginOffset
        scrubOriginWordIndex = nil
        scrubOriginOffset = nil
        resumeAfterScrub = false

        if settings.promptEngine == .scroll, originOffset != nil {
            let residual = -Double(predictedTranslationY - translationY)
            if abs(residual) > 8 {
                scroll.nudge(by: residual * 0.35)
            }
        }
        guard shouldResume else { return }
        primaryAction(settings: settings)
    }

    func handleStageTap(distance: CGFloat, settings: TeleprompterSettingsStore) -> Bool {
        guard distance < 6 else { return false }
        scrubOriginWordIndex = nil
        scrubOriginOffset = nil
        resumeAfterScrub = false
        primaryAction(settings: settings)
        return true
    }

    private static func signature(script: String, wpm: Int, settings: TeleprompterSettingsStore) -> String {
        let style = settings.style
        return [
            script,
            String(wpm),
            String(style.lineBreakPause),
            String(style.tagPause),
            String(style.longTagPause),
            String(style.motionEnabled),
            String(style.punctuationHolds.comma),
            String(style.punctuationHolds.period),
            String(style.punctuationHolds.question),
            String(style.punctuationHolds.exclamation),
            String(style.punctuationHolds.ellipsis),
        ].joined(separator: "|")
    }
}

enum PromptTransport: Equatable {
    case play, pause, `continue`

    var title: String {
        switch self {
        case .play: "Play"
        case .pause: "Pause"
        case .continue: "Continue"
        }
    }

    var systemImage: String {
        switch self {
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .continue: "play.fill"
        }
    }
}

enum PromptSurface: Equatable {
    case embedded
    case extended
    case compact
}
