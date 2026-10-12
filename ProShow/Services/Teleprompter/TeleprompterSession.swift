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

    func loadIfNeeded(script: String, settings: TeleprompterSettingsStore) {
        let signature = Self.signature(script: script, settings: settings)
        self.script = script
        engine.setChunkCapacity(settings.style.chunkCapacity)
        guard signature != loadedSignature else { return }
        let wasRunning = engine.isRunning
        loadedSignature = signature
        engine.load(script: script, baseWPM: settings.baseWPM, pacing: settings.style.scriptPacing)
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

    private static func signature(script: String, settings: TeleprompterSettingsStore) -> String {
        let style = settings.style
        return [
            script,
            String(settings.baseWPM),
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
