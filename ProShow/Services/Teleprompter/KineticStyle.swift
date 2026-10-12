import Foundation

/// Tunable Caption-with-Intention look — persisted on profiles and sticky session prefs.
struct KineticStyle: Equatable, Codable, Sendable {
    /// Word currently spilling out.
    var activeColor: PromptColor = .neonHighlight
    /// Already spoken words.
    var passedColor: PromptColor = .white
    var passedOpacity: Double = 1.0
    /// Words still ahead in the chunk.
    var upcomingColor: PromptColor = .white
    var upcomingOpacity: Double = 0.30
    /// `[SHOUT]` / `[LOUD]` size multiplier.
    var shoutScale: Double = 1.22
    /// `[WHISPER]` / `[SOFT]` size multiplier.
    var whisperScale: Double = 0.92
    /// Extra dim applied to whisper tokens (multiplies role opacity).
    var whisperOpacity: Double = 0.55
    /// Max words on screen before a page reset.
    var chunkCapacity: Int = 28
    /// When false, kinetic keeps color/weight but skips KeyframeAnimator motion.
    var motionEnabled: Bool = true
    /// Subtle scale punch on untagged active words (only when motion is on).
    var activePunchEnabled: Bool = true
    var activePunchScale: Double = 1.06
    /// Hold after a script newline (seconds per break). Independent of `[PAUSE]`.
    var lineBreakPause: Double = 0.10
    /// Hold for `[PAUSE]` tags.
    var tagPause: Double = 0.45
    /// Hold for bare `[LONGPAUSE]` / `[LONG PAUSE]` (override with `[LONGPAUSE:Ns]`).
    var longTagPause: Double = 5.0
    /// Show an inline “Long pause · Ns” chip in the prompt where the marker lives.
    var showsLongPauseInline: Bool = true
    /// Show a countdown banner on the panel while a long pause is holding.
    var showsLongPauseBanner: Bool = true
    /// Punctuation hold **N** per mark (engine waits `max(0, N − X)` after flourish **X**).
    var punctuationHolds: PunctuationHoldSettings = .default

    static let `default` = KineticStyle()

    var scriptPacing: ScriptPacing {
        ScriptPacing(
            lineBreakPause: lineBreakPause,
            tagPause: tagPause,
            longTagPause: longTagPause,
            motionEnabled: motionEnabled,
            punctuationHolds: punctuationHolds
        )
    }

    enum CodingKeys: String, CodingKey {
        case activeColor, passedColor, passedOpacity
        case upcomingColor, upcomingOpacity
        case shoutScale, whisperScale, whisperOpacity
        case chunkCapacity, motionEnabled, activePunchEnabled, activePunchScale
        case lineBreakPause, tagPause, longTagPause
        case showsLongPauseInline, showsLongPauseBanner
        case punctuationHolds
    }

    init(
        activeColor: PromptColor = .neonHighlight,
        passedColor: PromptColor = .white,
        passedOpacity: Double = 1.0,
        upcomingColor: PromptColor = .white,
        upcomingOpacity: Double = 0.30,
        shoutScale: Double = 1.22,
        whisperScale: Double = 0.92,
        whisperOpacity: Double = 0.55,
        chunkCapacity: Int = 28,
        motionEnabled: Bool = true,
        activePunchEnabled: Bool = true,
        activePunchScale: Double = 1.06,
        lineBreakPause: Double = 0.10,
        tagPause: Double = 0.45,
        longTagPause: Double = 5.0,
        showsLongPauseInline: Bool = true,
        showsLongPauseBanner: Bool = true,
        punctuationHolds: PunctuationHoldSettings = .default
    ) {
        self.activeColor = activeColor
        self.passedColor = passedColor
        self.passedOpacity = min(1, max(0.15, passedOpacity))
        self.upcomingColor = upcomingColor
        self.upcomingOpacity = min(1, max(0.05, upcomingOpacity))
        self.shoutScale = min(1.6, max(1.0, shoutScale))
        self.whisperScale = min(1.0, max(0.7, whisperScale))
        self.whisperOpacity = min(1, max(0.15, whisperOpacity))
        self.chunkCapacity = min(60, max(8, chunkCapacity))
        self.motionEnabled = motionEnabled
        self.activePunchEnabled = activePunchEnabled
        self.activePunchScale = min(1.25, max(1.0, activePunchScale))
        self.lineBreakPause = min(1.5, max(0, lineBreakPause))
        self.tagPause = min(3.0, max(0.05, tagPause))
        self.longTagPause = min(60, max(2.0, longTagPause))
        self.showsLongPauseInline = showsLongPauseInline
        self.showsLongPauseBanner = showsLongPauseBanner
        self.punctuationHolds = punctuationHolds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            activeColor: try c.decodeIfPresent(PromptColor.self, forKey: .activeColor) ?? .neonHighlight,
            passedColor: try c.decodeIfPresent(PromptColor.self, forKey: .passedColor) ?? .white,
            passedOpacity: try c.decodeIfPresent(Double.self, forKey: .passedOpacity) ?? 1,
            upcomingColor: try c.decodeIfPresent(PromptColor.self, forKey: .upcomingColor) ?? .white,
            upcomingOpacity: try c.decodeIfPresent(Double.self, forKey: .upcomingOpacity) ?? 0.30,
            shoutScale: try c.decodeIfPresent(Double.self, forKey: .shoutScale) ?? 1.22,
            whisperScale: try c.decodeIfPresent(Double.self, forKey: .whisperScale) ?? 0.92,
            whisperOpacity: try c.decodeIfPresent(Double.self, forKey: .whisperOpacity) ?? 0.55,
            chunkCapacity: try c.decodeIfPresent(Int.self, forKey: .chunkCapacity) ?? 28,
            motionEnabled: try c.decodeIfPresent(Bool.self, forKey: .motionEnabled) ?? true,
            activePunchEnabled: try c.decodeIfPresent(Bool.self, forKey: .activePunchEnabled) ?? true,
            activePunchScale: try c.decodeIfPresent(Double.self, forKey: .activePunchScale) ?? 1.06,
            lineBreakPause: try c.decodeIfPresent(Double.self, forKey: .lineBreakPause) ?? 0.10,
            tagPause: try c.decodeIfPresent(Double.self, forKey: .tagPause) ?? 0.45,
            longTagPause: try c.decodeIfPresent(Double.self, forKey: .longTagPause) ?? 5.0,
            showsLongPauseInline: try c.decodeIfPresent(Bool.self, forKey: .showsLongPauseInline) ?? true,
            showsLongPauseBanner: try c.decodeIfPresent(Bool.self, forKey: .showsLongPauseBanner) ?? true,
            punctuationHolds: try c.decodeIfPresent(PunctuationHoldSettings.self, forKey: .punctuationHolds) ?? .default
        )
    }

    /// Presets to help talent find a fit quickly.
    static let presets: [(title: String, style: KineticStyle)] = [
        ("Neon", .default),
        ("Soft", KineticStyle(
            activeColor: PromptColor(red: 1, green: 0.85, blue: 0.55, opacity: 1),
            passedOpacity: 0.85,
            upcomingOpacity: 0.22,
            shoutScale: 1.12,
            whisperScale: 0.88,
            whisperOpacity: 0.4,
            activePunchScale: 1.03
        )),
        ("High contrast", KineticStyle(
            activeColor: PromptColor(red: 0.2, green: 1, blue: 0.55, opacity: 1),
            passedColor: .white,
            passedOpacity: 1,
            upcomingColor: .white,
            upcomingOpacity: 0.18,
            shoutScale: 1.3,
            whisperScale: 0.85,
            chunkCapacity: 22,
            activePunchScale: 1.1
        )),
        ("Warm", KineticStyle(
            activeColor: PromptColor(red: 1, green: 0.55, blue: 0.25, opacity: 1),
            passedColor: PromptColor(red: 1, green: 0.92, blue: 0.82, opacity: 1),
            passedOpacity: 0.95,
            upcomingColor: PromptColor(red: 1, green: 0.9, blue: 0.75, opacity: 1),
            upcomingOpacity: 0.28,
            shoutScale: 1.18
        ))
    ]
}
