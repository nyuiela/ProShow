import SwiftUI
#if os(macOS)
import AppKit
import CoreVideo
import QuartzCore
#endif

#if os(macOS)
/// Display-link driven horizontal/vertical ticker using paired CoreText layers.
/// Loop scroll for pre-built multi-color attributed strings (live quote Display templates).
struct MarqueeAttributedTickerView: View {
    var object: CanvasObject
    var attributed: NSAttributedString
    var scale: CGFloat
    var cycleExtent: CGFloat
    var spacingGap: CGFloat
    var speedPixelsPerSecond: CGFloat
    var isVertical: Bool
    var scrollForward: Bool
    var anchorToTrailing: Bool
    var anchorToBottom: Bool
    var verticalAlign: TextVerticalAlign

    var body: some View {
        MarqueeAttributedTickerRepresentable(
            object: object,
            attributed: attributed,
            scale: scale,
            cycleExtent: cycleExtent,
            spacingGap: spacingGap,
            speedPixelsPerSecond: speedPixelsPerSecond,
            isVertical: isVertical,
            scrollForward: scrollForward,
            anchorToTrailing: anchorToTrailing,
            anchorToBottom: anchorToBottom,
            verticalAlign: verticalAlign
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityLabel(attributed.string)
    }
}

struct MarqueeTickerView: View {
    var style: SlideTextAttributes
    var cycleExtent: CGFloat
    var spacingGap: CGFloat
    var speedPixelsPerSecond: CGFloat
    var isVertical: Bool
    var scrollForward: Bool
    var anchorToTrailing: Bool
    var anchorToBottom: Bool
    var verticalAlign: TextVerticalAlign

    var body: some View {
        MarqueeTickerRepresentable(
            style: style,
            cycleExtent: cycleExtent,
            spacingGap: spacingGap,
            speedPixelsPerSecond: speedPixelsPerSecond,
            isVertical: isVertical,
            scrollForward: scrollForward,
            anchorToTrailing: anchorToTrailing,
            anchorToBottom: anchorToBottom,
            verticalAlign: verticalAlign
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityLabel(style.text)
    }
}

private struct MarqueeAttributedTickerRepresentable: NSViewRepresentable {
    var object: CanvasObject
    var attributed: NSAttributedString
    var scale: CGFloat
    var cycleExtent: CGFloat
    var spacingGap: CGFloat
    var speedPixelsPerSecond: CGFloat
    var isVertical: Bool
    var scrollForward: Bool
    var anchorToTrailing: Bool
    var anchorToBottom: Bool
    var verticalAlign: TextVerticalAlign

    func makeNSView(context: Context) -> MarqueeTickerContainerView {
        let view = MarqueeTickerContainerView()
        view.translatesAutoresizingMaskIntoConstraints = true
        pushBanner(to: view, preservePhase: false)
        return view
    }

    func updateNSView(_ nsView: MarqueeTickerContainerView, context: Context) {
        pushBanner(to: nsView, preservePhase: true)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeTickerContainerView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        let height = proposal.height ?? nsView.bounds.height
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ nsView: MarqueeTickerContainerView, coordinator: ()) {
        nsView.stopDisplayLink()
    }

    private var inkStyle: SlideTextAttributes {
        SlideTextAttributes.from(object: object, text: " ", scale: scale)
    }

    private var measuredExtent: CGFloat {
        max(1, cycleExtent)
    }

    private func pushBanner(to view: MarqueeTickerContainerView, preservePhase: Bool) {
        let style = inkStyle
        let extent = isVertical
            ? TextAttributeConverter.measureVerticalInkExtent(for: attributed, decorationPadding: style.decorationPadding)
            : TextAttributeConverter.measureHorizontalCycleExtent(for: attributed, decorationPadding: style.decorationPadding)
        view.updateLiveMarketText(
            newAttrString: attributed,
            newMeasuredWidth: max(1, extent),
            inkStyle: style
        )
        view.apply(
            style: style,
            cycleExtent: max(1, extent),
            spacingGap: spacingGap,
            speed: speedPixelsPerSecond,
            isVertical: isVertical,
            scrollForward: scrollForward,
            anchorToTrailing: anchorToTrailing,
            anchorToBottom: anchorToBottom,
            verticalAlign: verticalAlign,
            containerSize: view.bounds.size,
            preserveScrollPhase: preservePhase,
            usesExternalLiveContent: true
        )
    }
}

private struct MarqueeTickerRepresentable: NSViewRepresentable {
    var style: SlideTextAttributes
    var cycleExtent: CGFloat
    var spacingGap: CGFloat
    var speedPixelsPerSecond: CGFloat
    var isVertical: Bool
    var scrollForward: Bool
    var anchorToTrailing: Bool
    var anchorToBottom: Bool
    var verticalAlign: TextVerticalAlign

    func makeNSView(context: Context) -> MarqueeTickerContainerView {
        let view = MarqueeTickerContainerView()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.apply(
            style: style,
            cycleExtent: cycleExtent,
            spacingGap: spacingGap,
            speed: speedPixelsPerSecond,
            isVertical: isVertical,
            scrollForward: scrollForward,
            anchorToTrailing: anchorToTrailing,
            anchorToBottom: anchorToBottom,
            verticalAlign: verticalAlign,
            containerSize: .zero
        )
        return view
    }

    func updateNSView(_ nsView: MarqueeTickerContainerView, context: Context) {
        nsView.apply(
            style: style,
            cycleExtent: cycleExtent,
            spacingGap: spacingGap,
            speed: speedPixelsPerSecond,
            isVertical: isVertical,
            scrollForward: scrollForward,
            anchorToTrailing: anchorToTrailing,
            anchorToBottom: anchorToBottom,
            verticalAlign: verticalAlign,
            containerSize: nsView.bounds.size
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeTickerContainerView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        let height = proposal.height ?? nsView.bounds.height
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ nsView: MarqueeTickerContainerView, coordinator: ()) {
        nsView.stopDisplayLink()
    }
}

final class MarqueeTickerContainerView: NSView {
    private let backgroundLayerA = CALayer()
    private let backgroundLayerB = CALayer()
    private let textLayerA = CATextLayer()
    private let textLayerB = CATextLayer()
    private var displayLink: CVDisplayLink?

    private var styleSignature: String = ""
    private var cycleExtent: CGFloat = 1
    private var spacingGap: CGFloat = 0
    private var speed: CGFloat = 80
    private var isVertical = false
    private var scrollForward = true
    private var anchorToTrailing = false
    private var anchorToBottom = false
    private var containerSize: CGSize = .zero
    private var textVerticalInset: CGFloat = 0
    private var textInkHeight: CGFloat = 12
    private var verticalAlign: TextVerticalAlign = .middle
    private var startTime: CFTimeInterval = 0
    private var attributedString: NSAttributedString = NSAttributedString(string: "")
    private var lastLayoutCopyHeight: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Editor canvas drags/selects the SwiftUI object wrapper — AppKit must not steal mouse events.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        clipsToBounds = true
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = true
        autoresizingMask = [.width, .height]

        for layer in [backgroundLayerA, backgroundLayerB] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
            layer.masksToBounds = false
        }
        configure(textLayerA)
        configure(textLayerB)

        layer?.addSublayer(backgroundLayerA)
        layer?.addSublayer(backgroundLayerB)
        layer?.addSublayer(textLayerA)
        layer?.addSublayer(textLayerB)
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        containerSize = newSize
        layoutCopyFrames()
    }

    override func layout() {
        super.layout()
        containerSize = bounds.size
        layoutCopyFrames()
        renderNextFrame(at: CACurrentMediaTime())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else if cycleExtent > 0 {
            startDisplayLinkIfNeeded()
        }
    }

    /// Live market banner swap — preserves scroll phase when width/string changes.
    func updateLiveMarketText(
        newAttrString: NSAttributedString,
        newMeasuredWidth: CGFloat,
        inkStyle: SlideTextAttributes
    ) {
        let now = CACurrentMediaTime()
        let oldUnit = TickerEngine.unitDistance(contentExtent: cycleExtent, gap: spacingGap)
        let phase = TickerEngine.phaseRemainder(
            startTime: startTime,
            now: now,
            speed: speed,
            unitDistance: oldUnit
        )
        startTime = TickerEngine.startTimePreservingPhase(phase: phase, now: now, speed: speed)
        cycleExtent = max(1, newMeasuredWidth)
        attributedString = newAttrString

        let inkHeight = TextAttributeConverter.measureVerticalInkExtent(
            for: newAttrString,
            decorationPadding: inkStyle.decorationPadding
        )
        textInkHeight = max(1, inkHeight)
        let boxHeight = max(textInkHeight, containerSize.height > 0 ? containerSize.height : bounds.height)
        textVerticalInset = Self.verticalInset(containerHeight: boxHeight, inkHeight: textInkHeight, align: verticalAlign)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        assignAttributedString(newAttrString)
        layoutCopyFrames()
        CATransaction.commit()
        renderNextFrame(at: now)
    }

    func apply(
        style: SlideTextAttributes,
        cycleExtent: CGFloat,
        spacingGap: CGFloat,
        speed: CGFloat,
        isVertical: Bool,
        scrollForward: Bool,
        anchorToTrailing: Bool,
        anchorToBottom: Bool,
        verticalAlign: TextVerticalAlign,
        containerSize: CGSize,
        preserveScrollPhase: Bool = false,
        usesExternalLiveContent: Bool = false
    ) {
        let signature = styleSignature(for: style, cycleExtent: cycleExtent, spacingGap: spacingGap, speed: speed)
        if signature != styleSignature {
            styleSignature = signature
            if !preserveScrollPhase {
                startTime = CACurrentMediaTime()
            }
        }

        self.cycleExtent = max(1, cycleExtent)
        self.spacingGap = max(0, spacingGap)
        self.speed = max(0, speed)
        self.isVertical = isVertical
        self.scrollForward = scrollForward
        self.anchorToTrailing = anchorToTrailing
        self.anchorToBottom = anchorToBottom
        self.verticalAlign = verticalAlign
        if containerSize.width > 0, containerSize.height > 0 {
            self.containerSize = containerSize
        } else if bounds.width > 0, bounds.height > 0 {
            self.containerSize = bounds.size
        }
        let inkHeight: CGFloat
        if usesExternalLiveContent, attributedString.length > 0 {
            inkHeight = TextAttributeConverter.measureVerticalInkExtent(
                for: attributedString,
                decorationPadding: style.decorationPadding
            )
        } else {
            inkHeight = ceil(style.font.ascender - style.font.descender + style.font.leading)
        }
        textInkHeight = max(1, inkHeight)
        let boxHeight = max(textInkHeight, self.containerSize.height > 0 ? self.containerSize.height : bounds.height)
        textVerticalInset = Self.verticalInset(containerHeight: boxHeight, inkHeight: inkHeight, align: verticalAlign)

        let scale = window?.backingScaleFactor ?? 2
        if !usesExternalLiveContent {
            attributedString = TextAttributeConverter.makeAttributedString(from: style)
            assignAttributedString(attributedString)
        }

        let bgColor = style.backgroundColor?.cgColor
        for layer in [backgroundLayerA, backgroundLayerB] {
            layer.contentsScale = scale
            layer.backgroundColor = bgColor
            layer.isHidden = bgColor == nil
        }

        layoutCopyFrames()
        startDisplayLinkIfNeeded()
        renderNextFrame(at: CACurrentMediaTime())
    }

    func stopDisplayLink() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
    }

    private func styleSignature(
        for style: SlideTextAttributes,
        cycleExtent: CGFloat,
        spacingGap: CGFloat,
        speed: CGFloat
    ) -> String {
        [
            style.text,
            style.font.fontName,
            "\(style.font.pointSize)",
            style.textColor.description,
            style.strokeColor?.description ?? "",
            "\(style.strokeWidth)",
            style.shadowColor?.description ?? "",
            "\(style.shadowRadius)",
            "\(style.shadowOffset.width)",
            "\(style.shadowOffset.height)",
            "\(style.kerning)",
            "\(style.underline)",
            "\(style.strikethrough)",
            style.backgroundColor?.description ?? "",
            "\(cycleExtent)",
            "\(spacingGap)",
            "\(speed)",
        ].joined(separator: "|")
    }

    private func configure(_ layer: CATextLayer) {
        layer.actions = [
            "position": NSNull(),
            "bounds": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
        ]
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.masksToBounds = false
        layer.font = nil
        layer.foregroundColor = nil
    }

    private func assignAttributedString(_ string: NSAttributedString) {
        let scale = window?.backingScaleFactor ?? 2
        for layer in [textLayerA, textLayerB] {
            layer.contentsScale = scale
            layer.font = nil
            layer.foregroundColor = nil
            layer.string = string
            layer.alignmentMode = .left
        }
    }

    private func layoutCopyFrames() {
        let boxWidth = max(bounds.width, containerSize.width)
        let boxHeight = max(bounds.height, containerSize.height)
        let width = max(1, boxWidth)
        let height = max(1, boxHeight)
        let copyWidth = isVertical ? width : max(cycleExtent, 1)
        let copyHeight = isVertical ? max(cycleExtent, textInkHeight) : max(height, textInkHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let anchor = scrollAnchorPoint
        for pair in copyLayers {
            pair.background.anchorPoint = anchor
            pair.text.anchorPoint = anchor
            pair.background.bounds = CGRect(x: 0, y: 0, width: copyWidth, height: copyHeight)
            pair.text.bounds = pair.background.bounds
        }

        CATransaction.commit()

        if abs(copyHeight - lastLayoutCopyHeight) > 0.5 {
            lastLayoutCopyHeight = copyHeight
            for layer in [textLayerA, textLayerB] {
                layer.setNeedsDisplay()
            }
        }
    }

    private var copyLayers: [(background: CALayer, text: CATextLayer)] {
        [(backgroundLayerA, textLayerA), (backgroundLayerB, textLayerB)]
    }

    private static func verticalInset(containerHeight: CGFloat, inkHeight: CGFloat, align: TextVerticalAlign) -> CGFloat {
        let extra = max(0, containerHeight - inkHeight)
        switch align {
        case .top: return 0
        case .middle: return extra / 2
        case .bottom, .baseline: return extra
        }
    }

    private var scrollAnchorPoint: CGPoint {
        if isVertical {
            return CGPoint(x: 0.5, y: anchorToBottom ? 1 : 0)
        }
        return CGPoint(x: anchorToTrailing ? 1 : 0, y: 0)
    }

    private func startDisplayLinkIfNeeded() {
        guard window != nil, displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
        displayLink = link
        CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
            self?.renderNextFrame(at: CACurrentMediaTime())
            return kCVReturnSuccess
        }
        CVDisplayLinkStart(link)
    }

    private func renderNextFrame(at timestamp: CFTimeInterval) {
        guard cycleExtent > 0 else { return }

        let unit = TickerEngine.unitDistance(contentExtent: cycleExtent, gap: spacingGap)
        let elapsed = timestamp - startTime
        let primary = TickerEngine.primaryOffset(
            elapsed: elapsed,
            speed: speed,
            unitDistance: unit,
            scrollForward: scrollForward
        )
        let pair = TickerEngine.pairedOffsets(primary: primary, unitDistance: unit)

        let apply = { [weak self] in
            guard let self, self.window != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.applyScrollPositions(pair: pair)
            CATransaction.commit()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func applyScrollPositions(pair: (CGFloat, CGFloat)) {
        let width = bounds.width
        let height = bounds.height

        if isVertical {
            let baseY = anchorToBottom ? height : 0
            let positions = (baseY + pair.0, baseY + pair.1)
            textLayerA.position = CGPoint(x: bounds.midX, y: positions.0)
            textLayerB.position = CGPoint(x: bounds.midX, y: positions.1)
            backgroundLayerA.position = textLayerA.position
            backgroundLayerB.position = textLayerB.position
        } else {
            let baseX = anchorToTrailing ? width : 0
            let positions = (baseX + pair.0, baseX + pair.1)
            let y = textVerticalInset
            textLayerA.position = CGPoint(x: positions.0, y: y)
            textLayerB.position = CGPoint(x: positions.1, y: y)
            backgroundLayerA.position = textLayerA.position
            backgroundLayerB.position = textLayerB.position
        }
    }

    deinit {
        stopDisplayLink()
    }
}
#endif
