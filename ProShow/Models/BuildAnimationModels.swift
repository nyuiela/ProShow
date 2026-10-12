import Foundation
import CoreGraphics

enum BuildPhase: String, CaseIterable, Identifiable, Codable, Sendable {
    case buildIn
    case action
    case buildOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .buildIn: "Build In"
        case .action: "Action"
        case .buildOut: "Build Out"
        }
    }
}

enum AnimationEffectStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case fade
    case moveFromLeft, moveFromRight, moveFromTop, moveFromBottom
    case scaleZoom
    case wipeLeft, wipeRight
    case dissolve
    case pulse
    case floatBounce
    case spin
    case shake
    case infiniteMarqueeHorizontal
    case continuousRotate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fade: "Fade"
        case .moveFromLeft: "Move From Left"
        case .moveFromRight: "Move From Right"
        case .moveFromTop: "Move From Top"
        case .moveFromBottom: "Move From Bottom"
        case .scaleZoom: "Scale"
        case .wipeLeft: "Wipe Left"
        case .wipeRight: "Wipe Right"
        case .dissolve: "Dissolve"
        case .pulse: "Pulse"
        case .floatBounce: "Float"
        case .spin: "Spin"
        case .shake: "Shake"
        case .infiniteMarqueeHorizontal: "Marquee"
        case .continuousRotate: "Continuous Spin"
        }
    }

    var isContinuous: Bool {
        switch self {
        case .infiniteMarqueeHorizontal, .continuousRotate: true
        default: false
        }
    }

    static func defaults(for phase: BuildPhase) -> [AnimationEffectStyle] {
        switch phase {
        case .buildIn: [.moveFromLeft, .moveFromRight, .moveFromTop, .moveFromBottom, .fade, .dissolve, .scaleZoom, .wipeLeft, .wipeRight]
        case .action: [.infiniteMarqueeHorizontal, .continuousRotate, .pulse, .floatBounce, .spin, .shake]
        case .buildOut: [.fade, .dissolve, .scaleZoom, .moveFromLeft, .moveFromRight, .moveFromTop, .moveFromBottom, .wipeLeft, .wipeRight]
        }
    }

    static func defaultEffect(for phase: BuildPhase) -> AnimationEffectStyle {
        switch phase {
        case .buildIn: .moveFromLeft
        case .action: .infiniteMarqueeHorizontal
        case .buildOut: .fade
        }
    }
}

/// When a countdown should start or reset relative to this element's builds.
enum CountdownValueSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case timer
    case programMedia

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timer: "Timer"
        case .programMedia: "Program Media"
        }
    }
}

enum CountdownBuildLink: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case onSlideEnter
    case onClick
    case onBuildIn
    case onAction
    case onBuildOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Manual"
        case .onSlideEnter: "On Slide Enter"
        case .onClick: "On Click"
        case .onBuildIn: "On Build In"
        case .onAction: "On Action"
        case .onBuildOut: "On Build Out"
        }
    }
}

enum BuildTriggerMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case onSlideEnter
    case beforeSlideLeave
    case onClick
    case withPrevious
    case afterPrevious
    case onChange

    var id: String { rawValue }

    var title: String {
        title(for: nil)
    }

    func title(for phase: BuildPhase?) -> String {
        switch self {
        case .onSlideEnter:
            return phase == .buildOut ? "Before Slide Leave" : "On Slide Enter"
        case .beforeSlideLeave:
            return "Before Slide Leave"
        case .onClick:
            return "On Click"
        case .withPrevious:
            return "With Previous"
        case .afterPrevious:
            return "After Previous"
        case .onChange:
            return "On Change"
        }
    }

    static func cases(for phase: BuildPhase) -> [BuildTriggerMode] {
        switch phase {
        case .buildOut:
            return [.beforeSlideLeave, .onClick, .withPrevious, .afterPrevious, .onChange]
        case .buildIn, .action:
            return [.onSlideEnter, .onClick, .withPrevious, .afterPrevious, .onChange]
        }
    }

    func resolved(for phase: BuildPhase) -> BuildTriggerMode {
        if phase == .buildOut, self == .onSlideEnter {
            return .beforeSlideLeave
        }
        return self
    }
}

enum EasingCurveStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case springBounce

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In/Out"
        case .springBounce: "Spring"
        }
    }
}

struct ElementBuildStep: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var elementId: UUID
    var phase: BuildPhase
    var effect: AnimationEffectStyle
    var trigger: BuildTriggerMode
    var sequenceOrder: Int
    var delaySeconds: Double
    var durationSeconds: Double
    var easing: EasingCurveStyle
    var marqueeSpeedPxPerSec: Double
    var marqueeGapPx: Double
    var marqueeDirectionLeft: Bool

    init(
        id: UUID = UUID(),
        elementId: UUID,
        phase: BuildPhase,
        effect: AnimationEffectStyle? = nil,
        trigger: BuildTriggerMode = .onSlideEnter,
        sequenceOrder: Int = 1,
        delaySeconds: Double = 0,
        durationSeconds: Double = 0.5,
        easing: EasingCurveStyle = .easeInOut,
        marqueeSpeedPxPerSec: Double = 100,
        marqueeGapPx: Double = 60,
        marqueeDirectionLeft: Bool = true
    ) {
        self.id = id
        self.elementId = elementId
        self.phase = phase
        self.effect = effect ?? .defaultEffect(for: phase)
        self.trigger = trigger
        self.sequenceOrder = sequenceOrder
        self.delaySeconds = delaySeconds
        self.durationSeconds = durationSeconds
        self.easing = easing
        self.marqueeSpeedPxPerSec = marqueeSpeedPxPerSec
        self.marqueeGapPx = marqueeGapPx
        self.marqueeDirectionLeft = marqueeDirectionLeft
    }
}

struct TransformedRenderState: Hashable, Sendable {
    var opacity: Double = 1
    var translation: CGPoint = .zero
    var scale: CGSize = CGSize(width: 1, height: 1)
    var rotationDegrees: Double = 0
    var scrollOffsetPx: Double = 0
    var marqueeGapPx: Double = 60
    var marqueeVertical: Bool = false
    var isVisible: Bool = true
    var usesMarquee: Bool = false

    static let rest = TransformedRenderState()
    static let hidden = TransformedRenderState(opacity: 0, isVisible: false)

    var isIdentity: Bool {
        isVisible
            && !usesMarquee
            && opacity >= 0.999
            && abs(scale.width - 1) < 0.001
            && abs(scale.height - 1) < 0.001
            && abs(rotationDegrees) < 0.001
            && abs(translation.x) < 0.05
            && abs(translation.y) < 0.05
            && abs(scrollOffsetPx) < 0.05
            && !marqueeVertical
    }
}

struct BuildPlayback: Hashable, Sendable {
    var elapsed: Double
    var unlockedClickOrder: Int
    var clickTimes: [Int: Double]
    var autoplayClicks: Bool
    var isArmed: Bool
    var changeTimes: [UUID: Double] = [:]
    var isLeaving: Bool = false

    static let rest = BuildPlayback(elapsed: 0, unlockedClickOrder: 0, clickTimes: [:], autoplayClicks: false, isArmed: false)

    static func live(elapsed: Double, unlockedClickOrder: Int, clickTimes: [Int: Double], changeTimes: [UUID: Double] = [:]) -> BuildPlayback {
        BuildPlayback(elapsed: elapsed, unlockedClickOrder: unlockedClickOrder, clickTimes: clickTimes, autoplayClicks: false, isArmed: true, changeTimes: changeTimes)
    }

    static func preview(elapsed: Double) -> BuildPlayback {
        BuildPlayback(elapsed: elapsed, unlockedClickOrder: .max, clickTimes: [:], autoplayClicks: true, isArmed: true)
    }
}

/// How a canvas should evaluate element builds: settled rest vs live elapsed time.
enum AnimationEvaluationMode: Equatable, Hashable, Sendable {
    /// Canvas editor: items stay at design bounds so handles and text stay interactive.
    case editorDesign
    /// Static slide / library thumbnails: post-Build In, pre-Build Out rest pose.
    case thumbnailPreview
    /// Live program playback at exact elapsed time `t`.
    case liveTimeline(elapsedTime: Double)

    /// Clock-driven live mode; elapsed is taken from `BuildPlayback`.
    static let liveClock = AnimationEvaluationMode.liveTimeline(elapsedTime: 0)

    var usesSettledRestState: Bool {
        switch self {
        case .editorDesign, .thumbnailPreview: true
        case .liveTimeline: false
        }
    }
}

enum ElementType: String, Equatable, Hashable, Sendable {
    case text
    case shape
    case media
    case placeholder

    init(kind: CanvasObjectKind) {
        if kind.isTextLike {
            self = .text
            return
        }
        switch kind {
        case .image, .videoInput, .webView, .browser, .prop, .qrCode:
            self = .media
        case .maskShape, .cutout:
            self = .placeholder
        default:
            self = .shape
        }
    }
}

struct BuildClock: Hashable, Sendable {
    var startedAt: Date?
    var unlockedClickOrder: Int
    var clickTimes: [Int: Double]
    var autoplayClicks: Bool
    var frame: Int
    var changeTimes: [UUID: Double] = [:]
    var isLeaving: Bool = false

    static let idle = BuildClock(startedAt: nil, unlockedClickOrder: 0, clickTimes: [:], autoplayClicks: false, frame: 0)

    func playback(now: Date) -> BuildPlayback {
        guard let startedAt else { return .rest }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        return BuildPlayback(
            elapsed: elapsed,
            unlockedClickOrder: unlockedClickOrder,
            clickTimes: clickTimes,
            autoplayClicks: autoplayClicks,
            isArmed: true,
            changeTimes: changeTimes,
            isLeaving: isLeaving
        )
    }
}
