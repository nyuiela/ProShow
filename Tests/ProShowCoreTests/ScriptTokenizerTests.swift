#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

struct ScriptTokenizerTests {
    @Test func stripsEmotionTagsAndAppliesShout() {
        let words = ScriptTokenizer.tokenize("Hello [SHOUT] world quiet", baseWPM: 150)
        #expect(words.map(\.text) == ["Hello", "world", "quiet"])
        #expect(words[0].vocalStyle == .normal)
        #expect(words[1].vocalStyle == .shout)
        #expect(words[2].vocalStyle == .shout)
    }

    @Test func pauseTagInsertsSilentUnit() {
        let pacing = ScriptPacing(lineBreakPause: 0.1, tagPause: 0.45)
        let words = ScriptTokenizer.tokenize("One [PAUSE] Two", baseWPM: 150, pacing: pacing)
        #expect(words.count == 3)
        #expect(words[1].isPauseOnly)
        #expect(words[1].punctuationPause == 0.45)
    }

    @Test func lineBreakHoldUsesPacingNotTagPause() {
        let pacing = ScriptPacing(lineBreakPause: 0.2, tagPause: 1.5)
        let words = ScriptTokenizer.tokenize("One\nTwo", baseWPM: 150, pacing: pacing)
        #expect(words[0].lineBreaksAfter == 1)
        #expect(words[0].lineBreakHold == 0.2)
        #expect(words[0].punctuationPause == 0)
        #expect(abs(words[0].totalDuration - (words[0].baseDuration + 0.2)) < 0.001)
    }

    @Test func punctuationAddsConfiguredDelays() {
        let holds = PunctuationHoldSettings(
            comma: 0.3,
            semicolon: 0.3,
            colon: 0.3,
            period: 0.6,
            question: 0.6,
            exclamation: 0.6,
            ellipsis: 1.0,
            emDash: 0.6
        )
        let motionOff = ScriptPacing(motionEnabled: false, punctuationHolds: holds)
        #expect(ScriptTokenizer.punctuationPause(for: "hello,", pacing: motionOff) == 0.3)
        #expect(ScriptTokenizer.punctuationPause(for: "Stop!", pacing: motionOff) == 0.6)
        #expect(ScriptTokenizer.punctuationPause(for: "Wait...", pacing: motionOff) == 1.0)
        #expect(ScriptTokenizer.punctuationPause(for: "plain", pacing: motionOff) == 0)

        let motionOn = ScriptPacing(motionEnabled: true, punctuationHolds: holds)
        let commaX = PunctuationEmphasis.comma.animationDuration
        #expect(ScriptTokenizer.punctuationPause(for: "hello,", pacing: motionOn) == max(0.3, commaX))
        #expect(
            abs(
                ScriptTokenizer.punctuationPause(for: "Wait...", pacing: motionOn)
                    - max(1.0, PunctuationEmphasis.ellipsis.animationDuration)
            ) < 0.001
        )
    }

    @Test func punctuationDwellWaitsRemainingAfterAnimation() {
        // N=1.2, X≈0.80 for comma → dwell 1.2; leftover wait after anim = 0.4
        let holds = PunctuationHoldSettings(comma: 1.2)
        let pacing = ScriptPacing(motionEnabled: true, punctuationHolds: holds)
        let dwell = ScriptTokenizer.punctuationPause(for: "wait,", pacing: pacing)
        let x = PunctuationEmphasis.comma.animationDuration
        #expect(abs(dwell - 1.2) < 0.001)
        #expect(abs((dwell - x) - 0.4) < 0.001)
    }

    @Test func whisperTagDimsFollowingWords() {
        let words = ScriptTokenizer.tokenize("[WHISPER] soft [NORMAL] loud", baseWPM: 120)
        #expect(words[0].vocalStyle == .whisper)
        #expect(words[1].vocalStyle == .normal)
    }

    @Test func resolvesExtendedVocalStyles() {
        let script = """
        [BOUNCE] joy [STRETCH] drawl [FAST] quick \
        [TREMBLE] fear [HEAVY] grave [SLANT] mock \
        [GASP] breath [STUTTER] uh [MELODY] sing [ROBOT] flat
        """
        let words = ScriptTokenizer.tokenize(script, baseWPM: 150)
        let styles = words.map(\.vocalStyle)
        #expect(styles.contains(.bounce))
        #expect(styles.contains(.stretch))
        #expect(styles.contains(.fast))
        #expect(styles.contains(.tremble))
        #expect(styles.contains(.heavy))
        #expect(styles.contains(.slant))
        #expect(styles.contains(.gasp))
        #expect(styles.contains(.stutter))
        #expect(styles.contains(.melody))
        #expect(styles.contains(.robotic))
    }

    @Test func stretchAndFastAdjustHoldDuration() {
        let stretch = ScriptTokenizer.tokenize("[STRETCH] loooong", baseWPM: 150)[0]
        let fast = ScriptTokenizer.tokenize("[FAST] quick", baseWPM: 150)[0]
        let normal = ScriptTokenizer.tokenize("plain", baseWPM: 150)[0]
        #expect(stretch.totalDuration > normal.totalDuration)
        #expect(fast.totalDuration < normal.totalDuration)
    }

    @Test func unknownTagsAreIgnored() {
        let words = ScriptTokenizer.tokenize("Hi [NOTASTYLE] there", baseWPM: 150)
        #expect(words.map(\.text) == ["Hi", "there"])
        #expect(words.allSatisfy { $0.vocalStyle == .normal })
    }

    @Test func scrollDisplayStripsMarkupAndKeepsWords() {
        let plain = ScriptDisplayText.plain(
            from: "Hello [BOUNCE] world [SHOUT] bang [PAUSE] soft"
        )
        #expect(plain == "Hello world bang soft")
        #expect(!plain.contains("["))
        #expect(!plain.contains("BOUNCE"))
    }

    @Test func htmlStyleClosingTagsAreStrippedFromDisplay() {
        let words = ScriptTokenizer.tokenize(
            "[HEAVY]live right now[/HEAVY][NORMAL], powering",
            baseWPM: 150
        )
        let texts = words.map(\.text)
        #expect(texts.contains("live"))
        #expect(texts.contains("right"))
        #expect(texts.contains("now") || texts.contains("now,"))
        #expect(texts.contains("powering"))
        #expect(words.allSatisfy { !$0.text.contains("[") && !$0.text.contains("]") })
        #expect(words.first(where: { $0.text.hasPrefix("live") })?.vocalStyle == .heavy)
        #expect(words.first(where: { $0.text == "powering" })?.vocalStyle == .normal)

        let plain = ScriptDisplayText.plain(
            from: "We are [HEAVY]live right now[/HEAVY][NORMAL], powering daily. "
                + "[FAST]instantly routes[/FAST][NORMAL] the payment. "
                + "Visit [SHOUT][JOIN]morapay.io[/JOIN][NORMAL]"
        )
        #expect(!plain.contains("["))
        #expect(!plain.contains("HEAVY"))
        #expect(plain.contains("live right now"))
        #expect(plain.contains("morapay.io"))
    }

    @Test func preservesHardLineBreaksFromScript() {
        let script = "Line one\nLine two\n\nParagraph"
        let words = ScriptTokenizer.tokenize(script, baseWPM: 150)
        #expect(words.map(\.text) == ["Line", "one", "Line", "two", "Paragraph"])
        #expect(words[1].lineBreaksAfter == 1)
        #expect(words[3].lineBreaksAfter >= 2)

        let plain = ScriptDisplayText.plain(from: script)
        #expect(plain.contains("one\nLine"))
        #expect(plain.contains("two\n\nParagraph") || plain.contains("two\nParagraph"))
    }

    @Test func longPauseTagUsesLongHold() {
        let pacing = ScriptPacing(lineBreakPause: 0.1, tagPause: 0.45, longTagPause: 5)
        let words = ScriptTokenizer.tokenize("One [LONGPAUSE] Two", baseWPM: 150, pacing: pacing)
        #expect(words.count == 3)
        #expect(words[1].isLongPause)
        #expect(words[1].punctuationPause == 5)
        #expect(abs(words[1].totalDuration - 5) < 0.001)
    }

    @Test func longPauseAliasWithSpace() {
        let words = ScriptTokenizer.tokenize("A [LONG PAUSE] B", baseWPM: 150)
        #expect(words[1].isLongPause)
    }

    @Test func timedPauseBecomesLongAtThreshold() {
        let words = ScriptTokenizer.tokenize("A [PAUSE:8s] B", baseWPM: 150)
        #expect(words[1].isLongPause)
        #expect(words[1].punctuationPause == 8)
    }

    @Test func shortTimedPauseStaysBrief() {
        let words = ScriptTokenizer.tokenize("A [PAUSE:1s] B", baseWPM: 150)
        #expect(words[1].isBriefPause)
        #expect(words[1].punctuationPause == 1)
        #expect(!words[1].isLongPause)
    }

    @Test func explicitLongPauseDurationOverridesDefault() {
        let pacing = ScriptPacing(longTagPause: 5)
        let words = ScriptTokenizer.tokenize("A [LONGPAUSE:12] B", baseWPM: 150, pacing: pacing)
        #expect(words[1].isLongPause)
        #expect(words[1].punctuationPause == 12)
    }

    @Test func joinMarkupBundlesPhraseAsOneWord() {
        let words = ScriptTokenizer.tokenize(
            "Try [JOIN]Build on Stellar[/JOIN] today",
            baseWPM: 150
        )
        #expect(words.map(\.text) == ["Try", "Build on Stellar", "today"])
        #expect(words[1].baseDuration > words[0].baseDuration)
    }

    @Test func phraseAndBundleAliasesWork() {
        let a = ScriptTokenizer.tokenize("[PHRASE]core protocol teams[/PHRASE]", baseWPM: 150)
        let b = ScriptTokenizer.tokenize("[BUNDLE]core protocol teams[/BUNDLE]", baseWPM: 150)
        #expect(a.map(\.text) == ["core protocol teams"])
        #expect(b.map(\.text) == ["core protocol teams"])
    }

    @Test func underscoreGluesPhrase() {
        let words = ScriptTokenizer.tokenize("Visit Build_on_Stellar now", baseWPM: 150)
        #expect(words.map(\.text) == ["Visit", "Build on Stellar", "now"])
    }

    @Test func joinKeepsTrailingPunctuationOnPhrase() {
        let words = ScriptTokenizer.tokenize("[JOIN]four thousand dollars[/JOIN]. Next", baseWPM: 150)
        #expect(words[0].text == "four thousand dollars.")
        #expect(words[0].punctuationEmphasis == .period)
        #expect(words[1].text == "Next")
    }

    @Test func longJoinGetsMoreDurationThanShortJoin() {
        let short = ScriptTokenizer.tokenize("[JOIN]hi there[/JOIN]", baseWPM: 150)
        let long = ScriptTokenizer.tokenize("[JOIN]Build on Stellar[/JOIN]", baseWPM: 150)
        #expect(short[0].isJoinedPhrase)
        #expect(long[0].isJoinedPhrase)
        #expect(long[0].baseDuration > short[0].baseDuration)

        let single = ScriptTokenizer.tokenize("Stellar", baseWPM: 150)
        // Long 3-word join must outlast a comparable single spoken token.
        #expect(long[0].baseDuration > single[0].baseDuration * 1.5)
    }

    @Test func durationWeightMarksLongBundlesHeavier() {
        let shortW = ScriptTokenizer.durationWeight(forDisplay: "hi there")
        let longW = ScriptTokenizer.durationWeight(forDisplay: "Build on Stellar")
        let longerW = ScriptTokenizer.durationWeight(forDisplay: "four thousand dollars")
        #expect(longW > shortW)
        #expect(longerW > longW)
    }
}


    @Test func punctuationEmphasisDetectsComma() {
        let word = SpokenWord(text: "Hello,", baseDuration: 0.2)
        #expect(word.punctuationEmphasis == .comma)
        #expect(word.displayStem == "Hello")
    }

    @Test func punctuationEmphasisDetectsEllipsisAndBang() {
        #expect(SpokenWord(text: "Wait...", baseDuration: 0.2).punctuationEmphasis == .ellipsis)
        #expect(SpokenWord(text: "Go!", baseDuration: 0.2).punctuationEmphasis == .exclamation)
        #expect(SpokenWord(text: "Really?", baseDuration: 0.2).punctuationEmphasis == .question)
    }

struct TeleprompterSettingsTests {
    @Test func factoryDefaultsMatchCueLogPacing() {
        let style = KineticStyle.default
        #expect(style.scriptPacing.lineBreakPause == 0.10)
        #expect(style.scriptPacing.tagPause == 0.45)
        #expect(style.scriptPacing.longTagPause == 5.0)
        #expect(style.chunkCapacity == 28)
        #expect(style.shoutScale == 1.22)
        #expect(style.upcomingOpacity == 0.30)
        #expect(style.activeColor.hexString.hasPrefix("#"))
    }

    @Test @MainActor func beamSplitterMirrorAliasTracksHorizontal() {
        let store = TeleprompterSettingsStore.isolatedPreview()
        store.isBeamSplitterMirrored = true
        #expect(store.mirrorHorizontal == true)
        store.mirrorHorizontal = false
        #expect(store.isBeamSplitterMirrored == false)
    }

    @Test func hexRoundTripForHighlight() {
        let color = PromptColor.neonHighlight
        let hex = color.hexString
        let parsed = PromptColor(hexString: hex)
        #expect(parsed != nil)
        #expect(abs((parsed?.red ?? 0) - color.red) < 0.01)
    }

    @Test func kineticStyleRoundTripsThroughJSON() {
        var style = KineticStyle.default
        style.upcomingOpacity = 0.18
        style.shoutScale = 1.4
        style.activeColor = PromptColor(red: 0.1, green: 1, blue: 0.4, opacity: 1)
        let data = try! JSONEncoder().encode(style)
        let decoded = try! JSONDecoder().decode(KineticStyle.self, from: data)
        #expect(decoded.upcomingOpacity == 0.18)
        #expect(decoded.shoutScale == 1.4)
        #expect(decoded.activeColor.green == 1)
    }

    @Test func websiteFormatsIncludeBarePathsAndBothSchemes() {
        #expect(PromptWebsiteURL.canonical("stellar.org/foundation") == "https://stellar.org/foundation")
        #expect(PromptWebsiteURL.canonical("http://stellar.org/foundation") == "http://stellar.org/foundation")
        #expect(PromptWebsiteURL.canonical("https://stellar.org/foundation") == "https://stellar.org/foundation")
        #expect(PromptWebsiteURL.canonical("HTTPS://www.stellar.org/foundation/") == "https://www.stellar.org/foundation/")
        #expect(PromptWebsiteURL.canonical("www.stellar.org/foundation") == "https://www.stellar.org/foundation")
        #expect(PromptWebsiteURL.canonical("stellar.org/foundation/grants?ref=1#apply") == "https://stellar.org/foundation/grants?ref=1#apply")
        #expect(PromptWebsiteURL.canonical("(stellar.org/foundation).") == "https://stellar.org/foundation")
        #expect(PromptWebsiteURL.canonical("//stellar.org/foundation") == "https://stellar.org/foundation")
        #expect(PromptWebsiteURL.canonical("stellar.org:443/foundation") == "https://stellar.org:443/foundation")
        #expect(PromptWebsiteURL.canonical("notes.pdf") == nil)
        #expect(PromptWebsiteURL.canonical("Hello") == nil)

        let words = ScriptTokenizer.tokenize("Visit stellar.org/foundation and https://stellar.org/a_b today.", baseWPM: 150)
        #expect(words.map(\.text).contains("stellar.org/foundation"))
        #expect(words.map(\.text).contains("https://stellar.org/a_b"))
    }
}
