import Foundation
import AppKit

/// One wrapped display line of spoken-word indices (brief pauses omitted; long pauses included).
struct KineticLine: Equatable, Identifiable, Sendable {
    var id: Int { startWordIndex }
    /// Global indices into the engine word array.
    var wordIndices: [Int]
    /// True when this row starts after a script newline (not soft wrap).
    var beginsAfterHardBreak: Bool = false
    var startWordIndex: Int { wordIndices.first ?? 0 }
}

/// Shared metrics so wrap math matches on-screen `HStack` spacing / font weights.
enum KineticLineMetrics {
    /// Must stay in sync with `KineticPrompterView` word gaps.
    static func wordGap(fontSize: CGFloat) -> CGFloat {
        max(6, fontSize * 0.28)
    }

    /// NSFont matching `ExpressiveWordView` weights (heavy is wider than regular).
    static func measuringFont(for style: VocalStyle, size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = {
            if style.prefersHeavyWeight { return .heavy }
            if style.prefersLightWeight { return .light }
            if style == .bounce || style == .melody { return .semibold }
            return .regular
        }()

        let base: NSFont = {
            if style.prefersMonospaced {
                return .monospacedSystemFont(ofSize: size, weight: weight)
            }
            if style.prefersRounded {
                return .systemFont(ofSize: size, weight: weight)
            }
            return .systemFont(ofSize: size, weight: weight)
        }()

        guard style.prefersItalic else { return base }
        let italic = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: italic, size: size) ?? base
    }
}

/// Breaks tokens into stable lines using style-aware widths (size never changes mid-playback).
enum KineticLineBreaker {
    static func lines(
        words: [SpokenWord],
        maxWidth: CGFloat,
        fontSize: CGFloat,
        fontName: String = ".AppleSystemUIFont"
    ) -> [KineticLine] {
        guard maxWidth > 8, !words.isEmpty else { return [] }

        _ = fontName
        let gap = KineticLineMetrics.wordGap(fontSize: fontSize)
        // Leave a little air so active scale punch / italic bias doesn’t kiss the margin.
        let usableWidth = max(8, maxWidth - max(4, fontSize * 0.12))

        var result: [KineticLine] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        /// Next flushed row begins after a script newline.
        var nextBeginsAfterHardBreak = false

        func flushCurrent(hardBreakFollows: Bool) {
            guard !current.isEmpty else { return }
            result.append(
                KineticLine(
                    wordIndices: current,
                    beginsAfterHardBreak: nextBeginsAfterHardBreak
                )
            )
            current = []
            currentWidth = 0
            nextBeginsAfterHardBreak = hardBreakFollows
        }

        for (index, word) in words.enumerated() {
            // Brief [PAUSE] stays invisible; long pauses render as an inline chip.
            if word.isPauseOnly, !word.isLongPause { continue }
            let font = KineticLineMetrics.measuringFont(for: word.vocalStyle, size: fontSize)
            let measureText = word.isLongPause ? word.longPauseLabel : word.text
            var tokenWidth = (measureText as NSString).size(withAttributes: [.font: font]).width
            // Long joins can exceed the stage — they keep one unit but wrap onto their own line.
            if word.isJoinedPhrase {
                tokenWidth = min(tokenWidth, usableWidth)
            }
            let nextWidth = current.isEmpty ? tokenWidth : currentWidth + gap + tokenWidth

            if !current.isEmpty, nextWidth > usableWidth {
                flushCurrent(hardBreakFollows: false)
                // After soft wrap, still allow an oversized join to claim the full row width.
                let aloneWidth = word.isJoinedPhrase ? min(
                    (measureText as NSString).size(withAttributes: [.font: font]).width,
                    usableWidth
                ) : tokenWidth
                current = [index]
                currentWidth = aloneWidth
            } else {
                current.append(index)
                currentWidth = nextWidth
            }

            // Script newline → hard wrap (even if the line still has width left).
            if word.forcesLineBreakAfter, !current.isEmpty {
                flushCurrent(hardBreakFollows: true)
            }
        }
        flushCurrent(hardBreakFollows: false)
        return result
    }

    /// Line containing `wordIndex`, if any.
    static func lineIndex(containing wordIndex: Int, in lines: [KineticLine]) -> Int? {
        lines.firstIndex { $0.wordIndices.contains(wordIndex) }
    }
}

/// Sliding window of lines so the reading line stays between line 2 and line (count − 1).
struct KineticLineWindow: Equatable, Sendable {
    var startLine: Int
    /// How many lines are shown at once (minimum 3 when content allows).
    var visibleCount: Int

    static let minimumVisible = 3

    func clamped(totalLines: Int) -> KineticLineWindow {
        guard totalLines > 0 else {
            return KineticLineWindow(startLine: 0, visibleCount: 0)
        }
        let count = min(max(1, visibleCount), totalLines)
        let maxStart = max(0, totalLines - count)
        return KineticLineWindow(
            startLine: min(max(0, startLine), maxStart),
            visibleCount: count
        )
    }

    /// Keep `activeLine` on a middle row: has a previous line when possible, and a next line when possible.
    static func reconciled(
        previous: KineticLineWindow,
        activeLine: Int,
        totalLines: Int,
        preferredVisibleCount: Int
    ) -> KineticLineWindow {
        guard totalLines > 0 else {
            return KineticLineWindow(startLine: 0, visibleCount: 0)
        }

        var window = KineticLineWindow(
            startLine: previous.startLine,
            visibleCount: preferredVisibleCount
        ).clamped(totalLines: totalLines)

        let active = min(max(0, activeLine), totalLines - 1)

        // Not enough lines for a true middle band — show everything.
        if totalLines <= window.visibleCount {
            return KineticLineWindow(startLine: 0, visibleCount: totalLines)
        }

        // Tiny stages (1–2 visible lines): just keep the active line on-screen.
        if window.visibleCount < minimumVisible {
            let start = min(max(0, active - (window.visibleCount - 1) / 2), totalLines - window.visibleCount)
            return KineticLineWindow(startLine: start, visibleCount: window.visibleCount)
        }

        // Target slot for the reading line inside the window (0-based):
        // prefer index 1 ... visibleCount-2  → 1-based lines 2 ... (x-1)
        let minSlot = 1
        let maxSlot = max(minSlot, window.visibleCount - 2)

        var slot = active - window.startLine
        if active > 0, slot < minSlot {
            window.startLine = max(0, active - minSlot)
            slot = active - window.startLine
        }
        if active < totalLines - 1, slot > maxSlot {
            window.startLine = min(totalLines - window.visibleCount, active - maxSlot)
        }

        // First word / last word edge cases: still show whatever context exists.
        if active == 0 {
            window.startLine = 0
        } else if active == totalLines - 1 {
            window.startLine = max(0, totalLines - window.visibleCount)
        }

        return window.clamped(totalLines: totalLines)
    }
}
