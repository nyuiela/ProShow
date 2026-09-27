#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreGraphics
import Foundation
import Testing

@Suite
struct BuildAnimationTests {
    @Test
    func restState_isIdentity() {
        #expect(TransformedRenderState.rest.isIdentity)
        #expect(!TransformedRenderState.hidden.isIdentity)
    }

    @Test
    func testBuildInInterpolation() {
        let id = UUID()
        let step = ElementBuildStep(
            elementId: id,
            phase: .buildIn,
            effect: .fade,
            trigger: .onSlideEnter,
            durationSeconds: 0.5,
            easing: .linear
        )
        let bounds = CGRect(x: 100, y: 80, width: 400, height: 90)
        let start = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            elapsedTime: 0,
            elementBounds: bounds,
            textWidth: nil
        )
        let mid = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            elapsedTime: 0.25,
            elementBounds: bounds,
            textWidth: nil
        )
        let end = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            elapsedTime: 0.5,
            elementBounds: bounds,
            textWidth: nil
        )
        #expect(start.opacity == 0)
        #expect(abs(mid.opacity - 0.5) < 0.0001)
        #expect(abs(end.opacity - 1) < 0.0001)
        #expect(end.isVisible)
    }

    @Test
    func testInfiniteMarqueeOffsetMath() {
        let width = 200.0
        let gap = 40.0
        let speed = 120.0
        let cycle = width + gap
        #expect(BuildAnimationEngine.marqueeOffset(elapsed: 0, contentWidth: width, gap: gap, speed: speed, left: true) == 0)
        #expect(abs(BuildAnimationEngine.marqueeOffset(elapsed: 1, contentWidth: width, gap: gap, speed: speed, left: true) + 120) < 0.0001)
        #expect(abs(BuildAnimationEngine.marqueeOffset(elapsed: 2, contentWidth: width, gap: gap, speed: speed, left: true)) < 0.0001)
        #expect(abs(BuildAnimationEngine.marqueeOffset(elapsed: 2 + (1 / speed), contentWidth: width, gap: gap, speed: speed, left: true) + 1) < 0.001)

        let justBefore = BuildAnimationEngine.marqueeOffset(elapsed: (cycle - 1) / speed, contentWidth: width, gap: gap, speed: speed, left: true)
        let justAfter = BuildAnimationEngine.marqueeOffset(elapsed: (cycle + 1) / speed, contentWidth: width, gap: gap, speed: speed, left: true)
        #expect(abs(justBefore + (cycle - 1)) < 0.001)
        #expect(abs(justAfter + 1) < 0.001)

        let id = UUID()
        let step = ElementBuildStep(
            elementId: id,
            phase: .action,
            effect: .infiniteMarqueeHorizontal,
            trigger: .onSlideEnter,
            marqueeSpeedPxPerSec: speed,
            marqueeGapPx: gap,
            marqueeDirectionLeft: true
        )
        let state = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            elapsedTime: 1,
            elementBounds: CGRect(x: 0, y: 0, width: 320, height: 80),
            textWidth: width
        )
        #expect(state.usesMarquee)
        #expect(abs(state.scrollOffsetPx + 120) < 0.0001)
    }

    @Test
    func textLoop_repeatsHorizontallyAndVertically() {
        var ticker = CanvasObject(
            name: "Prices",
            kind: .liveQuote,
            bounds: CanvasBounds(x: 0, y: 0, width: 400, height: 64),
            text: "AAPL 192.10   MSFT 428.55   NVDA 118.40"
        )
        ticker.textLayout.scrolling = true
        ticker.textLayout.loopDirection = .left
        ticker.textLayout.loopSpeedPxPerSec = 100
        ticker.textLayout.loopGapPx = 40

        let t0 = Date(timeIntervalSinceReferenceDate: 10)
        let t1 = Date(timeIntervalSinceReferenceDate: 11)
        let start = BuildAnimationEngine.textLoopState(object: ticker, text: ticker.text, now: t0, reduceMotion: false)
        let next = BuildAnimationEngine.textLoopState(object: ticker, text: ticker.text, now: t1, reduceMotion: false)
        #expect(start.usesMarquee)
        #expect(!start.marqueeVertical)
        #expect(abs(next.scrollOffsetPx - start.scrollOffsetPx + 100) < 0.05)

        ticker.textLayout.loopDirection = .up
        ticker.text = "AAPL 192.10\nMSFT 428.55\nNVDA 118.40\nTSLA 248.12"
        let vertical = BuildAnimationEngine.textLoopState(object: ticker, text: ticker.text, now: t1, reduceMotion: false)
        #expect(vertical.usesMarquee)
        #expect(vertical.marqueeVertical)

        let still = BuildAnimationEngine.textLoopState(object: ticker, text: ticker.text, now: t1, reduceMotion: true)
        #expect(still.usesMarquee)
        #expect(abs(still.scrollOffsetPx) < 0.001)
    }

    @Test
    func textLoop_measuredWidthIsNotClampedToBox() {
        var ticker = CanvasObject(
            name: "Prices",
            kind: .text,
            bounds: CanvasBounds(x: 0, y: 0, width: 80, height: 40),
            text: "AAPL 192.10   MSFT 428.55   NVDA 118.40   TSLA 248.12"
        )
        ticker.textLayout.scrolling = true
        let width = BuildAnimationEngine.measuredTextWidth(for: ticker, text: ticker.text)
        #expect(width > ticker.bounds.width)
    }

    @Test @MainActor
    func editor_enablesTextLoopFromInspector() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let text = engine.addObject(.text)
        engine.mutateSelectedObjects { $0.text = "AAPL 192.10\nMSFT 428.55\nNVDA 118.40" }
        engine.setSelectedTextLooping(true)
        let object = engine.selectedDocument?.objects.first(where: { $0.id == text.id })
        #expect(object?.textLayout.isLooping == true)
        #expect(object?.textLayout.resolvedLoopDirection == .up)
        #expect(object?.textLayout.autoFitMode == TextAutoFitMode.none)
        engine.setSelectedTextLooping(false)
        #expect(engine.selectedDocument?.objects.first(where: { $0.id == text.id })?.textLayout.isLooping == false)
    }

    @Test @MainActor
    func testSequentialStepAdvancement() {
        var title = CanvasObject(
            name: "Main Title Header",
            kind: .text,
            bounds: .centered(width: 1200, height: 140),
            text: "Welcome"
        )
        title.build = ElementBuildAnimation(inEffect: .none, outEffect: .none)
        title.buildSteps = [
            ElementBuildStep(
                elementId: title.id,
                phase: .buildIn,
                effect: .moveFromLeft,
                trigger: .onClick,
                sequenceOrder: 1,
                durationSeconds: 0.4
            ),
            ElementBuildStep(
                elementId: title.id,
                phase: .action,
                effect: .pulse,
                trigger: .onClick,
                sequenceOrder: 2,
                durationSeconds: 0.4
            ),
        ]
        let first = Slide(title: "Title", canvas: [title])
        let second = Slide(title: "Verse")
        let show = Show(name: "Build Sequence", groups: [SlideGroup(name: "Set", slides: [first, second])])
        let controller = ShowController(show: show, playlist: Playlist(name: "Test"), persistOnInit: false)
        controller.goLive(slideID: first.id)

        #expect(controller.liveSlideID == first.id)
        #expect(controller.activeSlideBuildStepIndex == 0)

        controller.advance()
        #expect(controller.liveSlideID == first.id)
        #expect(controller.activeSlideBuildStepIndex == 1)
        #expect(controller.liveBuildClickTimes[1] != nil)

        controller.advance()
        #expect(controller.liveSlideID == first.id)
        #expect(controller.activeSlideBuildStepIndex == 2)

        controller.advance()
        #expect(controller.liveSlideID == second.id)
        #expect(controller.activeSlideBuildStepIndex == 0)
    }

    @Test
    func liveOnClick_doesNotStartUnlockedStepsAtZero() {
        let title = UUID()
        let body = UUID()
        let steps = [
            ElementBuildStep(elementId: title, phase: .buildIn, effect: .fade, trigger: .onClick, sequenceOrder: 1, durationSeconds: 0.4),
            ElementBuildStep(elementId: body, phase: .buildIn, effect: .fade, trigger: .afterPrevious, sequenceOrder: 2, durationSeconds: 0.4),
        ]
        let waiting = BuildPlayback.live(elapsed: 1.2, unlockedClickOrder: 0, clickTimes: [:])
        let waitingStarts = BuildAnimationEngine.startTimes(for: steps, playback: waiting)
        #expect(waitingStarts[steps[0].id] == nil)
        #expect(waitingStarts[steps[1].id] == nil)

        let clicked = BuildPlayback.live(elapsed: 1.2, unlockedClickOrder: 1, clickTimes: [1: 1.0])
        let liveStarts = BuildAnimationEngine.startTimes(for: steps, playback: clicked)
        #expect(abs((liveStarts[steps[0].id] ?? -1) - 1.0) < 0.0001)
        #expect(abs((liveStarts[steps[1].id] ?? -1) - 1.4) < 0.0001)

        let preview = BuildPlayback.preview(elapsed: 0.2)
        let previewStarts = BuildAnimationEngine.startTimes(for: steps, playback: preview)
        #expect(abs((previewStarts[steps[0].id] ?? -1)) < 0.0001)
        #expect(abs((previewStarts[steps[1].id] ?? -1) - 0.4) < 0.0001)
    }

    @Test
    func afterPrevious_staggersOnSlideEnter() {
        let a = UUID()
        let b = UUID()
        let steps = [
            ElementBuildStep(elementId: a, phase: .buildIn, effect: .fade, trigger: .onSlideEnter, sequenceOrder: 1, durationSeconds: 0.5),
            ElementBuildStep(elementId: b, phase: .buildIn, effect: .fade, trigger: .afterPrevious, sequenceOrder: 2, durationSeconds: 0.5),
        ]
        let starts = BuildAnimationEngine.startTimes(for: steps, playback: .live(elapsed: 0.1, unlockedClickOrder: 0, clickTimes: [:]))
        #expect(starts[steps[0].id] == 0)
        #expect(starts[steps[1].id] == 0.5)
        let early = BuildAnimationEngine.evaluateState(
            elementId: b,
            buildSteps: steps,
            playback: .live(elapsed: 0.1, unlockedClickOrder: 0, clickTimes: [:]),
            elementBounds: CGRect(x: 0, y: 0, width: 200, height: 80),
            textWidth: nil
        )
        #expect(!early.isVisible)
        let later = BuildAnimationEngine.evaluateState(
            elementId: b,
            buildSteps: steps,
            playback: .live(elapsed: 0.75, unlockedClickOrder: 0, clickTimes: [:]),
            elementBounds: CGRect(x: 0, y: 0, width: 200, height: 80),
            textWidth: nil
        )
        #expect(later.isVisible)
        #expect(later.opacity > 0.4)
    }

    @Test
    func emptySteps_returnSettledRest() {
        let state = BuildAnimationEngine.evaluateState(
            elementId: UUID(),
            buildSteps: [],
            mode: .liveTimeline(elapsedTime: 0),
            elementBounds: CGRect(x: 0, y: 0, width: 200, height: 80)
        )
        #expect(state.isIdentity)
        #expect(state.isVisible)
        #expect(state.opacity == 1)
    }

    @Test
    func editorAndThumbnailModes_ignoreLiveElapsed() {
        let id = UUID()
        let step = ElementBuildStep(
            elementId: id,
            phase: .buildIn,
            effect: .fade,
            trigger: .onSlideEnter,
            durationSeconds: 0.5,
            easing: .linear
        )
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 90)
        let live = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            mode: .liveTimeline(elapsedTime: 0),
            elementBounds: bounds
        )
        let editor = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            mode: .editorDesign,
            elementBounds: bounds,
            playback: .live(elapsed: 0, unlockedClickOrder: .max, clickTimes: [:])
        )
        let thumb = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            mode: .thumbnailPreview,
            elementBounds: bounds,
            playback: .live(elapsed: 0, unlockedClickOrder: .max, clickTimes: [:])
        )
        #expect(live.opacity == 0)
        #expect(!live.isIdentity)
        #expect(editor.isIdentity)
        #expect(thumb.isIdentity)
    }

    @Test
    func onChange_staysVisibleUntilFiredThenAnimates() {
        let id = UUID()
        let step = ElementBuildStep(
            elementId: id,
            phase: .buildIn,
            effect: .fade,
            trigger: .onChange,
            durationSeconds: 0.4,
            easing: .linear
        )
        let bounds = CGRect(x: 20, y: 20, width: 300, height: 80)
        let idle = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            playback: .live(elapsed: 2, unlockedClickOrder: 0, clickTimes: [:]),
            elementBounds: bounds,
            textWidth: nil
        )
        #expect(idle.isVisible)
        #expect(idle.opacity == 1)

        let mid = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            playback: .live(elapsed: 1.2, unlockedClickOrder: 0, clickTimes: [:], changeTimes: [id: 1.0]),
            elementBounds: bounds,
            textWidth: nil
        )
        #expect(abs(mid.opacity - 0.5) < 0.0001)

        let done = BuildAnimationEngine.evaluateState(
            elementId: id,
            buildSteps: [step],
            playback: .live(elapsed: 1.4, unlockedClickOrder: 0, clickTimes: [:], changeTimes: [id: 1.0]),
            elementBounds: bounds,
            textWidth: nil
        )
        #expect(abs(done.opacity - 1) < 0.0001)
        #expect(done.isVisible)
    }

    @Test
    func defaultBuildFactory_usesFadeOnSlideEnter() {
        let textID = UUID()
        let shapeID = UUID()
        let mediaID = UUID()
        let text = DefaultBuildFactory.createDefaultBuildSteps(for: textID, elementType: .text)
        let shape = DefaultBuildFactory.createDefaultBuildSteps(for: shapeID, kind: .rectangle)
        let media = DefaultBuildFactory.createDefaultBuildSteps(for: mediaID, elementType: .media)
        #expect(text.count == 1)
        #expect(text[0].phase == .buildIn)
        #expect(text[0].effect == .fade)
        #expect(text[0].trigger == .onSlideEnter)
        #expect(text[0].durationSeconds == 0.3)
        #expect(text[0].easing == .easeOut)
        #expect(shape[0].durationSeconds == 0.2)
        #expect(shape[0].easing == .linear)
        #expect(media[0].durationSeconds == 0.4)
        #expect(media[0].easing == .easeInOut)
    }

    @Test
    func buildOut_triggerIsBeforeSlideLeaveUntilLeaving() {
        #expect(BuildTriggerMode.onSlideEnter.title(for: .buildOut) == "Before Slide Leave")
        #expect(BuildTriggerMode.beforeSlideLeave.title(for: .buildOut) == "Before Slide Leave")
        #expect(BuildTriggerMode.onSlideEnter.title(for: .buildIn) == "On Slide Enter")
        #expect(BuildTriggerMode.onSlideEnter.resolved(for: .buildOut) == .beforeSlideLeave)

        let id = UUID()
        let authoredEnter = ElementBuildStep(
            elementId: id,
            phase: .buildOut,
            effect: .fade,
            trigger: .onSlideEnter,
            sequenceOrder: 1,
            durationSeconds: 0.4
        )
        let explicitLeave = ElementBuildStep(
            elementId: id,
            phase: .buildOut,
            effect: .fade,
            trigger: .beforeSlideLeave,
            sequenceOrder: 1,
            durationSeconds: 0.4
        )
        let idle = BuildPlayback.live(elapsed: 1.2, unlockedClickOrder: 0, clickTimes: [:])
        #expect(BuildAnimationEngine.startTimes(for: [authoredEnter], playback: idle)[authoredEnter.id] == nil)
        #expect(BuildAnimationEngine.startTimes(for: [explicitLeave], playback: idle)[explicitLeave.id] == nil)

        var leaving = BuildPlayback.live(elapsed: 0.1, unlockedClickOrder: 0, clickTimes: [:])
        leaving.isLeaving = true
        #expect(BuildAnimationEngine.startTimes(for: [authoredEnter], playback: leaving)[authoredEnter.id] == 0)
        #expect(BuildAnimationEngine.startTimes(for: [explicitLeave], playback: leaving)[explicitLeave.id] == 0)

        let preview = BuildPlayback.preview(elapsed: 0.2)
        #expect(BuildAnimationEngine.startTimes(for: [explicitLeave], playback: preview)[explicitLeave.id] == 0)
    }

    @Test @MainActor
    func goLive_playsBuildOutBeforeSwitchingSlides() {
        var title = CanvasObject(
            name: "Outgoing Title",
            kind: .text,
            bounds: .centered(width: 1200, height: 140),
            text: "See you"
        )
        title.build = ElementBuildAnimation(inEffect: .none, outEffect: .none)
        title.buildSteps = [
            ElementBuildStep(
                elementId: title.id,
                phase: .buildOut,
                effect: .fade,
                trigger: .beforeSlideLeave,
                sequenceOrder: 1,
                durationSeconds: 0.4
            )
        ]
        let first = Slide(title: "Leave", canvas: [title])
        let second = Slide(title: "Arrive")
        let show = Show(name: "Leave Then Switch", groups: [SlideGroup(name: "Set", slides: [first, second])])
        let controller = ShowController(show: show, playlist: Playlist(name: "Test"), persistOnInit: false)
        controller.goLive(slideID: first.id)
        #expect(controller.liveSlideID == first.id)
        #expect(controller.liveBuildClock().isLeaving == false)

        controller.goLive(slideID: second.id)
        #expect(controller.liveSlideID == first.id)
        #expect(controller.slideLeaveTargetID == second.id)
        #expect(controller.liveBuildClock().isLeaving)

        let started = controller.slideLeaveStartedAt ?? Date()
        controller.tickProgram(now: started.addingTimeInterval(0.1))
        #expect(controller.liveSlideID == first.id)

        controller.tickProgram(now: started.addingTimeInterval(0.45))
        #expect(controller.liveSlideID == second.id)
        #expect(controller.liveBuildClock().isLeaving == false)
    }

    @Test
    func liveTimeline_ticksOnSlideEnterWithoutClicks() {
        let clock = BuildClock(
            startedAt: Date(),
            unlockedClickOrder: 0,
            clickTimes: [:],
            autoplayClicks: false,
            frame: 0
        )
        #expect(BuildAnimationEngine.shouldTickLive(mode: .liveClock, clock: clock, objectID: UUID()))
        #expect(
            BuildAnimationEngine.shouldTickLive(
                mode: .editorDesign,
                clock: clock,
                objectID: UUID()
            ) == false
        )
    }
}
