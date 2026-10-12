import Foundation

/// Hold times for script structure (newlines, `[PAUSE]`, `[LONGPAUSE]`) — separate from WPM word clock.
struct ScriptPacing: Equatable, Codable, Sendable {
    /// Extra hold after a hard line break (seconds per newline, capped at 2).
    var lineBreakPause: TimeInterval = 0.10
    /// Hold for a bare `[PAUSE]` tag (not the same as a newline).
    var tagPause: TimeInterval = 0.45
    /// Hold for `[LONGPAUSE]` / `[LONG PAUSE]` when no `:Ns` duration is given.
    var longTagPause: TimeInterval = 5.0
    /// When true, punctuation dwell is `max(N, X)` so the clock covers the flourish.
    var motionEnabled: Bool = true
    /// Author hold **N** per punctuation mark (after anim, wait `N − X`).
    var punctuationHolds: PunctuationHoldSettings = .default

    /// Timed `[PAUSE:Ns]` at or above this becomes a long pause (inline + banner).
    static let longPauseThreshold: TimeInterval = 2.0

    static let `default` = ScriptPacing()

    init(
        lineBreakPause: TimeInterval = 0.10,
        tagPause: TimeInterval = 0.45,
        longTagPause: TimeInterval = 5.0,
        motionEnabled: Bool = true,
        punctuationHolds: PunctuationHoldSettings = .default
    ) {
        self.lineBreakPause = min(1.5, max(0, lineBreakPause))
        self.tagPause = min(3.0, max(0.05, tagPause))
        self.longTagPause = min(60, max(2.0, longTagPause))
        self.motionEnabled = motionEnabled
        self.punctuationHolds = punctuationHolds
    }

    func hold(forLineBreaks count: Int) -> TimeInterval {
        guard count > 0 else { return 0 }
        return lineBreakPause * Double(min(count, 2))
    }

    /// Effective punctuation dwell for a token (includes animation gate when motion is on).
    func punctuationDwell(for token: String) -> TimeInterval {
        let emphasis = PunctuationEmphasis.trailing(in: token)
        guard emphasis != .none else { return 0 }
        return PunctuationEmphasis.dwellSeconds(
            holdN: punctuationHolds.hold(for: emphasis),
            emphasis: emphasis,
            motionEnabled: motionEnabled
        )
    }
}

/// Configurable hold **N** after each punctuation mark (seconds).
struct PunctuationHoldSettings: Equatable, Codable, Sendable {
    var comma: TimeInterval
    var semicolon: TimeInterval
    var colon: TimeInterval
    var period: TimeInterval
    var question: TimeInterval
    var exclamation: TimeInterval
    var ellipsis: TimeInterval
    var emDash: TimeInterval

    /// Defaults sit at / slightly above animation **X** so there is a breath after the flourish.
    static let `default` = PunctuationHoldSettings(
        comma: 0.85,
        semicolon: 0.85,
        colon: 0.90,
        period: 1.00,
        question: 1.00,
        exclamation: 1.00,
        ellipsis: 1.20,
        emDash: 0.95
    )

    init(
        comma: TimeInterval = 0.85,
        semicolon: TimeInterval = 0.85,
        colon: TimeInterval = 0.90,
        period: TimeInterval = 1.00,
        question: TimeInterval = 1.00,
        exclamation: TimeInterval = 1.00,
        ellipsis: TimeInterval = 1.20,
        emDash: TimeInterval = 0.95
    ) {
        self.comma = Self.clamp(comma)
        self.semicolon = Self.clamp(semicolon)
        self.colon = Self.clamp(colon)
        self.period = Self.clamp(period)
        self.question = Self.clamp(question)
        self.exclamation = Self.clamp(exclamation)
        self.ellipsis = Self.clamp(ellipsis)
        self.emDash = Self.clamp(emDash)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        self.init(
            comma: try c.decodeIfPresent(TimeInterval.self, forKey: .comma) ?? d.comma,
            semicolon: try c.decodeIfPresent(TimeInterval.self, forKey: .semicolon) ?? d.semicolon,
            colon: try c.decodeIfPresent(TimeInterval.self, forKey: .colon) ?? d.colon,
            period: try c.decodeIfPresent(TimeInterval.self, forKey: .period) ?? d.period,
            question: try c.decodeIfPresent(TimeInterval.self, forKey: .question) ?? d.question,
            exclamation: try c.decodeIfPresent(TimeInterval.self, forKey: .exclamation) ?? d.exclamation,
            ellipsis: try c.decodeIfPresent(TimeInterval.self, forKey: .ellipsis) ?? d.ellipsis,
            emDash: try c.decodeIfPresent(TimeInterval.self, forKey: .emDash) ?? d.emDash
        )
    }

    func hold(for emphasis: PunctuationEmphasis) -> TimeInterval {
        switch emphasis {
        case .none: return 0
        case .comma: return comma
        case .semicolon: return semicolon
        case .colon: return colon
        case .period: return period
        case .question: return question
        case .exclamation: return exclamation
        case .ellipsis: return ellipsis
        case .emDash: return emDash
        }
    }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        min(3.0, max(0, value))
    }

    private enum CodingKeys: String, CodingKey {
        case comma, semicolon, colon, period, question, exclamation, ellipsis, emDash
    }
}
