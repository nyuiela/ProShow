#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

/// Program auto-advance: clock, script guard, hold and +30 s, stop items, crossing cues, prompter continuity.
@MainActor
@Suite
struct AutoAdvanceTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func block(_ title: String, _ seconds: TimeInterval, script: String = "") -> RundownBlock {
        var b = RundownBlock(itemNumber: "", title: title, segmentType: .keynote, plannedDurationSeconds: seconds)
        b.scriptBody = script
        return b
    }

    private func program(_ blocks: [RundownBlock], cues: [StageCueTrigger]? = nil) -> ProgramDocumentModel {
        var doc = ProgramDocumentModel()
        doc.rundownBlocks = blocks
        doc.hardStartTime = t0
        if let cues { doc.defaultStageCueTriggers = cues }
        return doc
    }

    private func engine(_ blocks: [RundownBlock], auto: Bool = true, cues: [StageCueTrigger]? = nil) -> RundownClockEngine {
        let e = RundownClockEngine()
        e.usesLiveTimer = false
        e.loadProgram(program(blocks, cues: cues))
        e.autoAdvanceEnabled = auto
        return e
    }

    /// Ticks at 10 Hz from `from` to `to` seconds after t0.
    private func run(_ e: RundownClockEngine, from: Double, to: Double, step: Double = 0.1) {
        let count = Int(((to - from) / step).rounded())
        for i in 0...max(0, count) {
            e.tick(now: t0.addingTimeInterval(from + Double(i) * step))
        }
    }

    private var talk: [RundownBlock] {
        [block("Intro", 10), block("Problem", 5), block("Demo", 5), block("Wrap", 5)]
    }

    // MARK: Clock

    @Test func autoAdvancesAtTheBoundary() {
        let e = engine(talk)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 9.9)
        #expect(e.activeBlockIndex == 0)
        run(e, from: 10.0, to: 10.1)
        #expect(e.activeBlockIndex == 1)
        #expect(e.lastAdvance?.reason == .clock)
        #expect(e.activeBlockElapsedSeconds < 0.15)
    }

    @Test func manualModeDoesNotAdvance() {
        let e = engine(talk, auto: false)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 20)
        #expect(e.activeBlockIndex == 0)
        #expect(e.activeBlockRemainingSeconds < -9)
        #expect(e.liveCountdownText.hasPrefix("+"))
    }

    @Test func runsSixItemsBackToBack() {
        let blocks = (1...7).map { block("Part \($0)", 3) }
        let e = engine(blocks)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 18.2)
        #expect(e.activeBlockIndex == 6)
    }

    // MARK: Script guard

    @Test func waitsForScriptThenTail() {
        let e = engine(talk)
        var state: RundownScriptState = .reading
        e.scriptStateProvider = { _ in state }
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 12)
        #expect(e.activeBlockIndex == 0)
        #expect(e.isWaitingOnScript)
        // Script finishes 2 s over; the cut lands 0.75 s later.
        state = .finished(at: t0.addingTimeInterval(12))
        run(e, from: 12.1, to: 12.6)
        #expect(e.activeBlockIndex == 0)
        run(e, from: 12.7, to: 12.9)
        #expect(e.activeBlockIndex == 1)
        #expect(e.lastAdvance?.reason == .scriptEnd)
    }

    @Test func scriptFinishedEarlyCutsOnTheClock() {
        let e = engine(talk)
        e.scriptStateProvider = { _ in .finished(at: Date(timeIntervalSinceReferenceDate: 800_000_005)) }
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 10.2)
        #expect(e.activeBlockIndex == 1)
        #expect(e.lastAdvance?.reason == .clock)
    }

    @Test func scriptGuardIsCappedAtTwelveSeconds() {
        let e = engine(talk)
        e.scriptStateProvider = { _ in .reading }
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 21.8)
        #expect(e.activeBlockIndex == 0)
        run(e, from: 21.9, to: 22.2)
        #expect(e.activeBlockIndex == 1)
        #expect(e.lastAdvance?.reason == .scriptCap)
    }

    @Test func noScriptUsesDurationOnly() {
        let e = engine(talk)
        e.scriptStateProvider = { _ in .none }
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 10.2)
        #expect(e.activeBlockIndex == 1)
    }

    // MARK: Hold and extend

    @Test func holdFreezesClockAndAutoAdvance() {
        let e = engine(talk)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 5)
        e.setHeld(true, now: t0.addingTimeInterval(5))
        run(e, from: 5.1, to: 40)
        #expect(e.activeBlockIndex == 0)
        #expect(abs(e.activeBlockRemainingSeconds - 5) < 0.11)
        #expect(e.liveCountdownText.hasPrefix("HOLD"))
        e.toggleHold(now: t0.addingTimeInterval(40))
        run(e, from: 40.1, to: 44.9)
        #expect(e.activeBlockIndex == 0)
        run(e, from: 45.0, to: 45.1)
        #expect(e.activeBlockIndex == 1)
    }

    @Test func extendAddsThirtySeconds() {
        let e = engine(talk)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 8)
        e.extendActiveBlock(now: t0.addingTimeInterval(8))
        #expect(e.activeBlockPlannedSeconds == 40)
        run(e, from: 8.1, to: 39.9)
        #expect(e.activeBlockIndex == 0)
        run(e, from: 40.0, to: 40.1)
        #expect(e.activeBlockIndex == 1)
        #expect(e.activeBlockExtensionSeconds == 0)
    }

    @Test func manualNextIsASkip() {
        let e = engine(talk)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 2)
        e.advanceToNextBlock(now: t0.addingTimeInterval(2))
        #expect(e.activeBlockIndex == 1)
        #expect(e.lastAdvance?.reason == .manual)
    }

    // MARK: Stop items

    @Test func derivedStopItems() {
        let blocks = [
            block("Starting soon", 300), block("Hook", 10), block("STANDBY: BRB (only if needed)", 60),
            block("Close", 10), block("Outro", 30), block("End", 5),
        ]
        #expect(RundownAutoAdvanceRules.isStopItem(at: 0, in: blocks))
        #expect(!RundownAutoAdvanceRules.isStopItem(at: 1, in: blocks))
        #expect(RundownAutoAdvanceRules.isStopItem(at: 2, in: blocks))
        #expect(!RundownAutoAdvanceRules.isStopItem(at: 3, in: blocks))
        #expect(RundownAutoAdvanceRules.isStopItem(at: 4, in: blocks))
        #expect(RundownAutoAdvanceRules.isStopItem(at: 5, in: blocks))
        // Auto skips a derived standby item.
        #expect(RundownAutoAdvanceRules.nextAutoIndex(after: 1, in: blocks) == 3)
        // "Starting soon" only stops as the first item.
        let mid = [block("Hook", 10), block("Starting soon", 10), block("End", 5)]
        #expect(!RundownAutoAdvanceRules.isStopItem(at: 1, in: mid))
    }

    @Test func explicitStopHereWins() {
        var blocks = [block("Hook", 10), block("Outro", 10), block("Tail", 5)]
        blocks[0].stopHere = true
        blocks[1].stopHere = false
        #expect(RundownAutoAdvanceRules.isStopItem(at: 0, in: blocks))
        #expect(!RundownAutoAdvanceRules.isStopItem(at: 1, in: blocks))
    }

    @Test func stopItemHoldsAndCountsOver() {
        let blocks = [block("Starting soon", 5), block("Hook", 5)]
        let e = engine(blocks)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 9.2)
        #expect(e.activeBlockIndex == 0)
        #expect(e.isStoppedAtItem)
        #expect(e.liveCountdownText == "+0:04")
        e.advanceToNextBlock(now: t0.addingTimeInterval(9))
        #expect(e.activeBlockIndex == 1)
        #expect(!e.isStoppedAtItem)
    }

    @Test func autoSkipsStandbyToTheNextTalkItem() {
        let blocks = [block("Hook", 3), block("STANDBY: BRB", 60), block("Body", 3), block("Last", 3)]
        let e = engine(blocks)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 3.2)
        #expect(e.activeBlockIndex == 2)
    }

    // MARK: Cues

    private func cueEngine(_ cues: [StageCueTrigger], seconds: TimeInterval = 90) -> (RundownClockEngine, () -> [String]) {
        let e = engine([block("Talk", seconds), block("Next", 10)], auto: false, cues: cues)
        var fired: [String] = []
        e.onStageCue = { message, _ in fired.append(message) }
        return (e, { fired })
    }

    @Test func defaultCuesFireOnceAtSixtyThirtyZero() {
        let (e, fired) = cueEngine(ProgramDocumentModel().defaultStageCueTriggers)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 29.9)
        #expect(fired().isEmpty)
        run(e, from: 30, to: 30.2)
        #expect(fired() == ["1 MINUTE REMAINING"])
        run(e, from: 30.2, to: 120)
        #expect(fired() == ["1 MINUTE REMAINING", "WRAP UP", "TIME EXPIRED"])
    }

    @Test func negativeLegacyOffsetsMeanBeforeTheEnd() {
        let (e, fired) = cueEngine([StageCueTrigger(triggerOffsetSeconds: -60, stageMessage: "ONE"), StageCueTrigger(triggerOffsetSeconds: -30, stageMessage: "HALF")])
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 29.9)
        #expect(fired().isEmpty)
        run(e, from: 30, to: 60.1)
        #expect(fired() == ["ONE", "HALF"])
    }

    @Test func stallStillFiresEveryCrossedCueOnce() {
        let (e, fired) = cueEngine(ProgramDocumentModel().defaultStageCueTriggers)
        e.startShow(at: 0, now: t0)
        e.tick(now: t0)
        // A 70 s stall jumps from 90 to 20 remaining: both 60 and 30 are crossed in one step.
        e.tick(now: t0.addingTimeInterval(70))
        #expect(fired() == ["1 MINUTE REMAINING", "WRAP UP"])
        e.tick(now: t0.addingTimeInterval(95))
        #expect(fired() == ["1 MINUTE REMAINING", "WRAP UP", "TIME EXPIRED"])
        e.tick(now: t0.addingTimeInterval(200))
        #expect(fired().count == 3)
    }

    @Test func holdAndExtendDoNotRepeatCues() {
        let (e, fired) = cueEngine([StageCueTrigger(triggerOffsetSeconds: 30, stageMessage: "WRAP UP")], seconds: 40)
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 15)
        #expect(fired() == ["WRAP UP"])
        e.setHeld(true, now: t0.addingTimeInterval(15))
        run(e, from: 15.1, to: 30)
        e.setHeld(false, now: t0.addingTimeInterval(30))
        e.extendActiveBlock(now: t0.addingTimeInterval(30))
        // Remaining goes back above 30, then crosses it again: still once per item.
        run(e, from: 30.1, to: 60)
        #expect(fired() == ["WRAP UP"])
    }

    @Test func cueAtFullLengthFiresOnStart() {
        let (e, fired) = cueEngine([StageCueTrigger(triggerOffsetSeconds: 60, stageMessage: "MIN")], seconds: 60)
        e.startShow(at: 0, now: t0)
        e.tick(now: t0)
        #expect(fired() == ["MIN"])
    }

    @Test func cuesResetPerItem() {
        let e = engine([block("A", 5), block("B", 5)], auto: true, cues: [StageCueTrigger(triggerOffsetSeconds: 2, stageMessage: "GO")])
        var fired = 0
        e.onStageCue = { _, _ in fired += 1 }
        e.startShow(at: 0, now: t0)
        run(e, from: 0, to: 9.5)
        #expect(fired == 2)
    }

    @Test func compilerGuardKeepsShortCuesAndNormalizesSign() {
        let inherited = [StageCueTrigger(triggerOffsetSeconds: -60, stageMessage: "LONG"), StageCueTrigger(triggerOffsetSeconds: -10, stageMessage: "SHORT")]
        let cues = OutlineScriptCompiler.explicitShortCues(inheriting: inherited)
        #expect(cues.map(\.stageMessage) == ["SHORT"])
        #expect(cues.first?.triggerOffsetSeconds == 10)
    }

    // MARK: Countdown text

    @Test func countdownText() {
        #expect(RundownClockEngine.countdownText(remaining: 12.2, held: false) == "0:13")
        #expect(RundownClockEngine.countdownText(remaining: 0, held: false) == "0:00")
        #expect(RundownClockEngine.countdownText(remaining: -5.4, held: false) == "+0:05")
        #expect(RundownClockEngine.countdownText(remaining: 75, held: true) == "HOLD 1:15")
    }

    // MARK: Pacing

    @Test func fittedWPMFitsAndClamps() {
        let words = Array(repeating: "word", count: 95).joined(separator: " ")
        let pacing = ScriptPacing()
        let fit = ProgramPromptPacing.fittedWPM(script: words, plannedSeconds: 30, pacing: pacing)
        #expect(fit != nil)
        if let fit {
            #expect((120...240).contains(fit))
            #expect(abs(ProgramPromptPacing.total(words, wpm: fit, pacing: pacing) - 30) < 2.5)
        }
        #expect(ProgramPromptPacing.fittedWPM(script: words, plannedSeconds: 3, pacing: pacing) == 240)
        #expect(ProgramPromptPacing.fittedWPM(script: words, plannedSeconds: 600, pacing: pacing) == 120)
        #expect(ProgramPromptPacing.fittedWPM(script: "", plannedSeconds: 30, pacing: pacing) == nil)
        var b = block("Talk", 30, script: words)
        #expect(ProgramPromptPacing.wpm(for: b, plannedSeconds: 30, baseWPM: 160, pacing: pacing) == fit)
        b.promptPacing = .prompterSpeed
        #expect(ProgramPromptPacing.wpm(for: b, plannedSeconds: 30, baseWPM: 160, pacing: pacing) == nil)
    }

    @Test func blockFlagsRoundTrip() throws {
        var b = block("Talk", 30)
        b.stopHere = true
        b.promptPacing = .prompterSpeed
        let back = try JSONDecoder().decode(RundownBlock.self, from: JSONEncoder().encode(b))
        #expect(back.stopHere == true)
        #expect(back.promptPacing == .prompterSpeed)
        let plain = try JSONDecoder().decode(RundownBlock.self, from: JSONEncoder().encode(block("Talk", 30)))
        #expect(plain.stopHere == nil)
        #expect(plain.promptPacing == nil)
    }

    // MARK: Prompter continuity

    @Test func programAdvanceKeepsPrompterRolling() {
        let session = TeleprompterSession.shared
        let settings = TeleprompterSettingsStore.isolatedPreview()
        let saved = session.programWPMResolver
        session.programWPMResolver = nil
        defer {
            session.engine.reset()
            session.scroll.reset()
            session.programWPMResolver = saved
        }
        for kind in [PromptEngineKind.kinetic, .scroll] {
            settings.promptEngine = kind
            session.loadProgramItem(script: "one two three four", settings: settings, keepRolling: true)
            #expect(session.isRunning, "\(kind) starts rolling")
            session.loadProgramItem(script: "five six seven eight", settings: settings, keepRolling: true)
            #expect(session.isRunning, "\(kind) keeps rolling into the next item")
            #expect(session.script == "five six seven eight")
            #expect(session.engine.activeIndex == 0)
            session.engine.pause()
            session.scroll.pause()
            session.loadProgramItem(script: "nine ten", settings: settings, keepRolling: false)
            #expect(!session.isRunning, "\(kind) stays paused when not rolling and Auto off")
        }
    }

    @Test func scriptStateFollowsTheLoadedItem() {
        let session = TeleprompterSession.shared
        let settings = TeleprompterSettingsStore.isolatedPreview()
        settings.promptEngine = .kinetic
        defer { session.engine.reset() }
        let item = block("Talk", 10, script: "alpha beta gamma")
        session.loadProgramItem(script: item.scriptBody, settings: settings, keepRolling: false)
        #expect(ShowController.promptScriptState(for: item, session: session, settings: settings) == .none)
        session.engine.start()
        #expect(ShowController.promptScriptState(for: item, session: session, settings: settings) == .reading)
        let other = block("Other", 10, script: "different")
        #expect(ShowController.promptScriptState(for: other, session: session, settings: settings) == .none)
        #expect(ShowController.promptScriptState(for: block("Empty", 10), session: session, settings: settings) == .none)
    }

    // MARK: Remote

    @Test func remoteProgramRoutes() {
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/program/next", body: [:]) == .programNext)
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/program/prev", body: [:]) == .programPrevious)
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/program/previous", body: [:]) == .programPrevious)
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/program/hold", body: [:]) == .programHold)
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/program/extend", body: [:]) == .programExtend)
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/program/auto", body: ["enabled": "true"]) == .programAuto(true))
        #expect(RemoteControlBridge.parseREST(method: "GET", path: "/v1/program/status", body: [:]) == .programStatus)
        #expect(RemoteControlBridge.parseREST(method: "POST", path: "/v1/slide/next", body: [:]) == .nextSlide)
        #expect(RemoteControlBridge.parseOSC("/proshow/program/next") == .programNext)
        #expect(RemoteControlBridge.parseOSC("/proshow/program/hold") == .programHold)
        #expect(RemoteControlBridge.parseOSC("/proshow/program/auto", arguments: ["0"]) == .programAuto(false))
        #expect(RemoteControlBridge.parseMIDI(status: 0x90, data1: 62, data2: 100) == .programNext)
        #expect(RemoteControlBridge.parseMIDI(status: 0x90, data1: 63, data2: 100) == .programPrevious)
        #expect(RemoteControlBridge.parseMIDI(status: 0x90, data1: 64, data2: 100) == .programHold)
    }
}
