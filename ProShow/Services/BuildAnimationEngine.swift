import Foundation
import CoreGraphics
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

enum BuildAnimationEngine {
    static func filterSteps(_ steps: [ElementBuildStep], including phases: Set<BuildPhase>?) -> [ElementBuildStep] {
        guard let phases else { return steps }
        let filtered = steps.filter { phases.contains($0.phase) }
        guard phases == [.buildOut] else { return filtered }
        return filtered.map { step in
            var next = step
            next.trigger = .onSlideEnter
            next.delaySeconds = 0
            return next
        }
    }

    static func authoredBuildOutDuration(in objects: [CanvasObject]) -> Double {
        var longest = 0.0
        for object in objects {
            for step in object.buildSteps ?? [] where step.phase == .buildOut {
                longest = max(longest, max(0, step.durationSeconds) + max(0, step.delaySeconds))
            }
        }
        return longest
    }

    static func authoredBuildInDuration(in objects: [CanvasObject]) -> Double {
        var longest = 0.0
        for object in objects {
            for step in object.resolvedBuildSteps where step.phase == .buildIn {
                longest = max(longest, max(0, step.durationSeconds) + max(0, step.delaySeconds))
            }
        }
        return longest
    }

    /// RTMP/ISO: autoplay through pending click-builds so text and graphics match the on-air program.
    static func broadcastPlayback(from playback: BuildPlayback, canvasObjects: [CanvasObject]) -> BuildPlayback {
        if playback.isLeaving { return playback }
        let inSpan = authoredBuildInDuration(in: canvasObjects)
        guard playback.isArmed else {
            return BuildPlayback.preview(elapsed: max(86_400, inSpan + 1))
        }
        return BuildPlayback.preview(elapsed: max(playback.elapsed, inSpan + 1))
    }

    static func shouldTickLive(mode: AnimationEvaluationMode, clock: BuildClock, objectID: UUID) -> Bool {
        if mode.usesSettledRestState {
            return clock.changeTimes[objectID] != nil
        }
        return clock.startedAt != nil || clock.autoplayClicks || !clock.clickTimes.isEmpty || clock.changeTimes[objectID] != nil
    }

    static func interpolateEasing(_ tau: Double, style: EasingCurveStyle) -> Double {
        let t = min(1, max(0, tau))
        switch style {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .springBounce: return 1 + sin(t * .pi * 2.5) * (1 - t) * 0.3
        }
    }

    static func marqueeOffset(elapsed: Double, contentWidth: Double, gap: Double, speed: Double, left: Bool) -> Double {
        TickerEngine.marqueeOffset(
            elapsed: elapsed,
            contentWidth: contentWidth,
            gap: gap,
            speed: speed,
            scrollForward: left
        )
    }

    static func measuredTextHeight(for object: CanvasObject, text: String? = nil) -> Double {
        let body = text ?? object.displayText
        #if canImport(AppKit)
        let width = max(1, object.bounds.width)
        let attributes = textMeasureAttributes(for: object, text: body)
        let box = (body as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return box.height
        #else
        let lines = max(1, body.split(separator: "\n", omittingEmptySubsequences: false).count)
        return max(object.bounds.height, Double(lines) * object.typography.fontSize * max(1, object.textLayout.lineHeight))
        #endif
    }

    static func measuredTextWidth(for object: CanvasObject, text: String) -> Double {
        #if canImport(AppKit)
        let style = SlideTextAttributes.from(object: object, text: text, scale: 1)
        return Double(TextAttributeConverter.measureHorizontalCycleExtent(style: style))
        #else
        return max(object.bounds.width, Double(text.count) * object.typography.fontSize * 0.55)
        #endif
    }

    private static func textMeasureAttributes(for object: CanvasObject, text: String) -> [NSAttributedString.Key: Any] {
        #if canImport(AppKit)
        let attributed = TextAttributeConverter.makeAttributedString(
            object: object,
            text: text,
            scale: 1
        )
        return attributed.length > 0
            ? attributed.attributes(at: 0, effectiveRange: nil)
            : [:]
        #else
        return [:]
        #endif
    }

    static func textLoopState(
        object: CanvasObject,
        text: String,
        now: Date,
        reduceMotion: Bool
    ) -> TransformedRenderState {
        guard object.textLayout.isLooping else { return .rest }
        let direction = object.textLayout.resolvedLoopDirection
        let gap = object.textLayout.resolvedLoopGap
        #if canImport(AppKit)
        let style = SlideTextAttributes.from(object: object, text: text, scale: 1)
        let content = direction.isVertical
            ? Double(TextAttributeConverter.measureVerticalCycleExtent(style: style))
            : Double(TextAttributeConverter.measureHorizontalCycleExtent(style: style))
        #else
        let content = direction.isVertical
            ? measuredTextHeight(for: object, text: text)
            : measuredTextWidth(for: object, text: text)
        #endif
        var state = TransformedRenderState.rest
        state.usesMarquee = true
        state.marqueeVertical = direction.isVertical
        state.marqueeGapPx = gap
        if reduceMotion {
            return state
        }
        state.scrollOffsetPx = marqueeOffset(
            elapsed: now.timeIntervalSinceReferenceDate,
            contentWidth: content,
            gap: gap,
            speed: object.textLayout.resolvedLoopSpeed,
            left: direction == .left || direction == .up
        )
        return state
    }

    static func startTimes(for steps: [ElementBuildStep], playback: BuildPlayback) -> [UUID: Double] {
        let ordered = steps.sorted { lhs, rhs in
            if lhs.sequenceOrder != rhs.sequenceOrder { return lhs.sequenceOrder < rhs.sequenceOrder }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var starts: [UUID: Double] = [:]
        var previousStart: Double?
        var previousEnd: Double?
        var waitingOnPredecessor = false
        for step in ordered {
            let duration = step.effect.isContinuous ? 0 : max(0, step.durationSeconds)
            let start: Double?
            switch step.trigger.resolved(for: step.phase) {
            case .onSlideEnter:
                start = step.delaySeconds
            case .beforeSlideLeave:
                if playback.isLeaving {
                    start = step.delaySeconds
                } else if playback.autoplayClicks {
                    start = (previousEnd ?? 0) + step.delaySeconds
                } else {
                    start = nil
                }
            case .onClick:
                if playback.autoplayClicks {
                    start = (previousEnd ?? 0) + step.delaySeconds
                } else if let clicked = playback.clickTimes[step.sequenceOrder] {
                    start = clicked + step.delaySeconds
                } else {
                    start = nil
                }
            case .withPrevious:
                start = waitingOnPredecessor ? nil : (previousStart ?? 0) + step.delaySeconds
            case .afterPrevious:
                start = waitingOnPredecessor ? nil : (previousEnd ?? 0) + step.delaySeconds
            case .onChange:
                if let changed = playback.changeTimes[step.elementId] {
                    start = changed + step.delaySeconds
                } else {
                    start = nil
                }
            }
            if let start {
                starts[step.id] = start
                previousStart = start
                previousEnd = start + duration
                waitingOnPredecessor = false
            } else {
                waitingOnPredecessor = true
            }
        }
        return starts
    }

    static func evaluateState(
        elementId: UUID,
        buildSteps: [ElementBuildStep],
        elapsedTime: Double,
        elementBounds: CGRect,
        textWidth: Double?,
        reduceMotion: Bool = false
    ) -> TransformedRenderState {
        evaluateState(
            elementId: elementId,
            buildSteps: buildSteps,
            mode: .liveTimeline(elapsedTime: elapsedTime),
            elementBounds: elementBounds,
            textWidth: textWidth,
            reduceMotion: reduceMotion
        )
    }

    static func evaluateState(
        elementId: UUID,
        buildSteps: [ElementBuildStep],
        playback: BuildPlayback,
        elementBounds: CGRect,
        textWidth: Double?,
        reduceMotion: Bool = false
    ) -> TransformedRenderState {
        evaluateState(
            elementId: elementId,
            buildSteps: buildSteps,
            mode: .liveTimeline(elapsedTime: playback.elapsed),
            elementBounds: elementBounds,
            textWidth: textWidth,
            reduceMotion: reduceMotion,
            playback: playback
        )
    }

    static func evaluateState(
        elementId: UUID,
        buildSteps: [ElementBuildStep],
        mode: AnimationEvaluationMode,
        elementBounds: CGRect,
        textWidth: Double? = nil,
        reduceMotion: Bool = false,
        playback: BuildPlayback? = nil
    ) -> TransformedRenderState {
        let elementSteps = buildSteps
            .filter { $0.elementId == elementId }
            .sorted { $0.sequenceOrder < $1.sequenceOrder }
        if elementSteps.isEmpty {
            return .rest
        }
        switch mode {
        case .editorDesign, .thumbnailPreview:
            return .rest
        case .liveTimeline(let elapsedTime):
            let play = playback ?? .live(elapsed: elapsedTime, unlockedClickOrder: .max, clickTimes: [:])
            return evaluateLiveTimeline(
                elementSteps: elementSteps,
                allSteps: buildSteps,
                playback: play,
                elementBounds: elementBounds,
                textWidth: textWidth,
                reduceMotion: reduceMotion
            )
        }
    }

    private static func evaluateLiveTimeline(
        elementSteps: [ElementBuildStep],
        allSteps: [ElementBuildStep],
        playback: BuildPlayback,
        elementBounds: CGRect,
        textWidth: Double?,
        reduceMotion: Bool
    ) -> TransformedRenderState {
        guard playback.isArmed else { return .rest }
        let starts = startTimes(for: allSteps, playback: playback)
        if reduceMotion {
            return evaluateReduced(elementSteps: elementSteps, starts: starts, playback: playback)
        }
        var state = TransformedRenderState.rest
        for step in elementSteps {
            guard let start = starts[step.id] else {
                if step.trigger != .onChange, step.phase == .buildIn { state = .hidden }
                continue
            }
            apply(step: step, start: start, playback: playback, bounds: elementBounds, textWidth: textWidth, into: &state)
        }
        return state
    }

    static func synthesize(from build: ElementBuildAnimation, objectID: UUID) -> [ElementBuildStep] {
        var steps: [ElementBuildStep] = []
        var order = 1
        if build.inEffect != .none {
            steps.append(
                ElementBuildStep(
                    elementId: objectID,
                    phase: .buildIn,
                    effect: mapEffect(build.inEffect, direction: build.inDirection, phase: .buildIn),
                    trigger: mapTrigger(build.trigger),
                    sequenceOrder: order,
                    delaySeconds: 0,
                    durationSeconds: build.inDurationSec,
                    easing: mapEasing(build.inEasing)
                )
            )
            order += 1
        }
        if build.outEffect != .none {
            steps.append(
                ElementBuildStep(
                    elementId: objectID,
                    phase: .buildOut,
                    effect: mapEffect(build.outEffect, direction: build.inDirection, phase: .buildOut),
                    trigger: build.outDelaySec > 0 ? .afterPrevious : mapTrigger(build.trigger),
                    sequenceOrder: order,
                    delaySeconds: build.outDelaySec,
                    durationSeconds: build.outDurationSec,
                    easing: mapEasing(build.inEasing)
                )
            )
        }
        return steps
    }

    static func pendingOnClickSteps(in objects: [CanvasObject]) -> [ElementBuildStep] {
        objects
            .flatMap(\.resolvedBuildSteps)
            .filter { $0.trigger == .onClick }
            .sorted { $0.sequenceOrder < $1.sequenceOrder }
    }

    static func measuredTextWidth(for object: CanvasObject) -> Double {
        #if canImport(AppKit)
        let font = CanvasTypeface.nsFont(
            family: object.typography.fontFamily,
            size: object.typography.fontSize,
            weight: object.typography.fontWeight,
            bold: object.typography.isBold,
            italic: object.typography.isItalic
        )
        return ceil((object.displayText as NSString).size(withAttributes: [.font: font]).width)
        #else
        return max(object.bounds.width, Double(object.displayText.count) * object.typography.fontSize * 0.55)
        #endif
    }

    private static func apply(
        step: ElementBuildStep,
        start: Double,
        playback: BuildPlayback,
        bounds: CGRect,
        textWidth: Double?,
        into state: inout TransformedRenderState
    ) {
        let elapsed = playback.elapsed
        if step.effect.isContinuous {
            guard elapsed >= start else { return }
            let local = elapsed - start
            if step.effect == .infiniteMarqueeHorizontal {
                let width = textWidth ?? bounds.width
                state.scrollOffsetPx = marqueeOffset(
                    elapsed: local,
                    contentWidth: width,
                    gap: step.marqueeGapPx,
                    speed: step.marqueeSpeedPxPerSec,
                    left: step.marqueeDirectionLeft
                )
                state.marqueeGapPx = step.marqueeGapPx
                state.usesMarquee = true
                state.isVisible = true
                state.opacity = 1
            } else {
                let period = max(0.25, step.durationSeconds)
                state.rotationDegrees = (local / period) * 360
                state.isVisible = true
            }
            return
        }

        if elapsed < start {
            if step.phase == .buildIn {
                state = .hidden
            }
            return
        }

        let raw = min(1, (elapsed - start) / max(0.001, step.durationSeconds))
        let progress = interpolateEasing(raw, style: step.easing)
        state.isVisible = true
        applyEffect(step.effect, phase: step.phase, progress: progress, bounds: bounds, into: &state)
        if step.phase == .buildOut, raw >= 1 {
            state.opacity = 0
            state.isVisible = false
        }
    }

    private static func applyEffect(
        _ effect: AnimationEffectStyle,
        phase: BuildPhase,
        progress: Double,
        bounds: CGRect,
        into state: inout TransformedRenderState
    ) {
        let inbound = phase != .buildOut
        let travel = inbound ? (1 - progress) : progress
        switch effect {
        case .fade, .dissolve:
            state.opacity = inbound ? progress : (1 - progress)
        case .moveFromLeft, .wipeLeft:
            state.translation.x = -max(bounds.width, 240) * travel
            state.opacity = inbound ? min(1, progress * 1.4) : (1 - progress)
        case .moveFromRight, .wipeRight:
            state.translation.x = max(bounds.width, 240) * travel
            state.opacity = inbound ? min(1, progress * 1.4) : (1 - progress)
        case .moveFromTop:
            state.translation.y = -max(bounds.height, 160) * travel
            state.opacity = inbound ? min(1, progress * 1.4) : (1 - progress)
        case .moveFromBottom:
            state.translation.y = max(bounds.height, 160) * travel
            state.opacity = inbound ? min(1, progress * 1.4) : (1 - progress)
        case .scaleZoom:
            let scaled = inbound ? max(0.2, progress) : max(0.2, 1 - progress)
            state.scale = CGSize(width: scaled, height: scaled)
            state.opacity = inbound ? min(1, progress * 2) : (1 - progress)
        case .pulse:
            let pulse = 1 + sin(progress * .pi * 2) * 0.15
            state.scale = CGSize(width: pulse, height: pulse)
        case .floatBounce:
            state.translation.y = sin(progress * .pi * 2) * 16
        case .spin:
            state.rotationDegrees = progress * 360
        case .shake:
            state.translation.x = sin(progress * .pi * 16) * 10 * (1 - progress)
        case .infiniteMarqueeHorizontal, .continuousRotate:
            break
        }
    }

    private static func evaluateReduced(
        elementSteps: [ElementBuildStep],
        starts: [UUID: Double],
        playback: BuildPlayback
    ) -> TransformedRenderState {
        if elementSteps.contains(where: { $0.phase == .buildIn && starts[$0.id] == nil }) {
            return .hidden
        }
        if let out = elementSteps.last(where: { $0.phase == .buildOut }), let start = starts[out.id] {
            if playback.elapsed >= start + out.durationSeconds {
                return .hidden
            }
        }
        return .rest
    }

    private static func mapEffect(_ effect: BuildEffect, direction: BuildDirection, phase: BuildPhase) -> AnimationEffectStyle {
        switch effect {
        case .none, .dissolve: return .dissolve
        case .push, .fly:
            switch direction {
            case .left: return .moveFromLeft
            case .right: return .moveFromRight
            case .top: return .moveFromTop
            case .bottom: return .moveFromBottom
            }
        case .wipe: return direction == .right ? .wipeRight : .wipeLeft
        case .zoom: return .scaleZoom
        case .flip: return phase == .action ? .spin : .fade
        }
    }

    private static func mapTrigger(_ trigger: BuildTrigger) -> BuildTriggerMode {
        switch trigger {
        case .withSlide: .onSlideEnter
        case .onClick: .onClick
        case .afterPrevious: .afterPrevious
        case .onChange: .onChange
        }
    }

    private static func mapEasing(_ easing: BuildEasing) -> EasingCurveStyle {
        switch easing {
        case .linear: .linear
        case .easeIn: .easeIn
        case .easeOut: .easeOut
        case .easeInOut: .easeInOut
        case .bounce: .springBounce
        }
    }
}

#if canImport(SwiftUI)
private struct BuildClockKey: EnvironmentKey {
    static let defaultValue = BuildClock.idle
}

private struct AnimationEvaluationModeKey: EnvironmentKey {
    static let defaultValue = AnimationEvaluationMode.liveClock
}

private struct BuildPhaseFilterKey: EnvironmentKey {
    static let defaultValue: Set<BuildPhase>? = nil
}

extension EnvironmentValues {
    var buildClock: BuildClock {
        get { self[BuildClockKey.self] }
        set { self[BuildClockKey.self] = newValue }
    }

    var animationEvaluationMode: AnimationEvaluationMode {
        get { self[AnimationEvaluationModeKey.self] }
        set { self[AnimationEvaluationModeKey.self] = newValue }
    }

    var buildPhaseFilter: Set<BuildPhase>? {
        get { self[BuildPhaseFilterKey.self] }
        set { self[BuildPhaseFilterKey.self] = newValue }
    }
}

struct BuildAnimated<Content: View>: View {
    let object: CanvasObject
    let slideSteps: [ElementBuildStep]
    let scale: CGFloat
    @ViewBuilder var content: (TransformedRenderState) -> Content
    @Environment(\.buildClock) private var clock
    @Environment(\.animationEvaluationMode) private var evaluationMode
    @Environment(\.buildPhaseFilter) private var phaseFilter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    var body: some View {
        Group {
            if shouldTickLive && onScreen {
                TimelineView(.periodic(from: .now, by: reduceMotion ? 1.0 / 15.0 : 1.0 / 30.0)) { timeline in
                    built(at: timeline.date)
                }
            } else {
                built(at: Date())
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private func built(at date: Date) -> some View {
        let state = currentState(at: date)
        return applyBuild(state, to: content(state))
    }

    private var shouldTickLive: Bool {
        BuildAnimationEngine.shouldTickLive(
            mode: evaluationMode,
            clock: clock,
            objectID: object.id
        )
    }

    @ViewBuilder
    private func applyBuild<V: View>(_ state: TransformedRenderState, to view: V) -> some View {
        if object.hostsLayerBackedMedia {
            view
                .offset(x: state.translation.x * scale, y: state.translation.y * scale)
                .hiddenKeepingAlive(!state.isVisible || state.opacity < 0.02)
        } else if state.isIdentity {
            view
        } else {
            view
                .opacity(state.opacity)
                .scaleEffect(x: max(0.2, state.scale.width), y: max(0.2, state.scale.height), anchor: .center)
                .rotationEffect(.degrees(state.rotationDegrees))
                .offset(x: state.translation.x * scale, y: state.translation.y * scale)
                .allowsHitTesting(state.isVisible)
                .accessibilityHidden(!state.isVisible)
        }
    }

    func currentState(at date: Date) -> TransformedRenderState {
        let playback = clock.playback(now: date)
        let mode: AnimationEvaluationMode = evaluationMode.usesSettledRestState
            ? evaluationMode
            : .liveTimeline(elapsedTime: playback.elapsed)
        let rawSteps = slideSteps.isEmpty ? object.resolvedBuildSteps : slideSteps
        let phases: Set<BuildPhase>? = clock.isLeaving ? [.buildOut] : phaseFilter
        return BuildAnimationEngine.evaluateState(
            elementId: object.id,
            buildSteps: BuildAnimationEngine.filterSteps(rawSteps, including: phases),
            mode: mode,
            elementBounds: CGRect(
                x: object.transform.x,
                y: object.transform.y,
                width: object.transform.width,
                height: object.transform.height
            ),
            textWidth: object.isTextLike ? BuildAnimationEngine.measuredTextWidth(for: object) : nil,
            reduceMotion: reduceMotion,
            playback: playback
        )
    }
}
#endif
