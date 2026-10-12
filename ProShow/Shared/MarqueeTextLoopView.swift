import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Canvas/audience looping text using the seamless display-link ticker (Path: no SwiftUI `TimelineView` loop).
struct MarqueeTextLoopView: View {
    var object: CanvasObject
    var text: String
    var scale: CGFloat
    var reduceMotion: Bool
    var canvasObjects: [CanvasObject] = []
    var liveQuotes: [String: LiveQuote] = [:]
    var dynamicTextContext: DynamicTextContext?

    var body: some View {
        #if os(macOS)
        if MarketTickerRouting.usesColoredStrip(object) {
            LiveMarketMarqueeView(
                object: object,
                canvasObjects: canvasObjects,
                scale: scale,
                reduceMotion: reduceMotion,
                liveQuotes: liveQuotes
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: loopFrameAlignment)
        } else if let coloredTemplate {
            if reduceMotion {
                CanvasStaticAttributedTextView(object: object, attributed: coloredTemplate, layoutScale: scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: loopFrameAlignment)
                    .clipped()
            } else {
                LiveQuoteAttributedMarqueeScrollView(
                    object: object,
                    attributed: coloredTemplate,
                    scale: scale,
                    cycleExtent: coloredTemplateCycleExtent,
                    spacingGap: CGFloat(object.textLayout.resolvedLoopGap) * scale,
                    speedPixelsPerSecond: CGFloat(object.textLayout.resolvedLoopSpeed) * scale,
                    loopScroll: object.textLayout.resolvedLoopDirection.marqueeScroll,
                    frameAlignment: loopFrameAlignment
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: loopFrameAlignment)
            }
        } else if reduceMotion {
            restingCopy
        } else {
            let style = SlideTextAttributes.from(object: object, text: text, scale: scale)
            let loop = object.textLayout.resolvedLoopDirection.marqueeScroll
            MarqueeTickerView(
                style: style,
                cycleExtent: cycleExtent(for: style),
                spacingGap: CGFloat(object.textLayout.resolvedLoopGap) * scale,
                speedPixelsPerSecond: CGFloat(object.textLayout.resolvedLoopSpeed) * scale,
                isVertical: loop.isVertical,
                scrollForward: loop.scrollForward,
                anchorToTrailing: loop.anchorToTrailing,
                anchorToBottom: loop.anchorToBottom,
                verticalAlign: object.textLayout.verticalAlign
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: loopFrameAlignment)
        }
        #else
        restingCopy
        #endif
    }

    #if os(macOS)
    private var coloredTemplate: NSAttributedString? {
        guard object.kind == .liveQuote else { return nil }
        var context = dynamicTextContext ?? .empty
        if dynamicTextContext == nil, !liveQuotes.isEmpty {
            context.quotes = liveQuotes
            context.now = Date()
        }
        return LiveQuoteTemplateRenderer.makeAttributedString(
            object: object,
            scale: scale,
            context: context,
            colorConfig: TickerConfigStore.shared.colorConfig
        )
    }

    private var coloredTemplateCycleExtent: CGFloat {
        guard let coloredTemplate else { return 1 }
        let inkStyle = SlideTextAttributes.from(object: object, text: " ", scale: scale)
        let vertical = object.textLayout.resolvedLoopDirection.isVertical
        return vertical
            ? TextAttributeConverter.measureVerticalInkExtent(
                for: coloredTemplate,
                decorationPadding: inkStyle.decorationPadding
            )
            : TextAttributeConverter.measureHorizontalCycleExtent(
                for: coloredTemplate,
                decorationPadding: inkStyle.decorationPadding
            )
    }
    #endif

    private var restingCopy: some View {
        Group {
            #if os(macOS)
            if let coloredTemplate {
                CanvasStaticAttributedTextView(object: object, attributed: coloredTemplate, layoutScale: scale)
            } else {
            CanvasRasterizedTextView(object: object, text: text, layoutScale: scale)
            }
            #else
            Text(text)
                .font(CanvasSwiftUIFont.resolve(
                    family: object.typography.fontFamily,
                    size: max(1, object.typography.fontSize * scale),
                    weight: object.typography.fontWeight,
                    bold: object.typography.isBold,
                    italic: object.typography.isItalic
                ))
                .foregroundStyle(Color(hex: object.typography.color) ?? .white)
            #endif
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: loopFrameAlignment)
        .clipped()
        .accessibilityLabel(text)
    }

    private var canvasBaselineOffset: CGFloat {
        if object.typography.isSuperscript {
            return object.typography.fontSize * scale * 0.35
        }
        if object.typography.isSubscript {
            return -object.typography.fontSize * scale * 0.25
        }
        return 0
    }

    #if os(macOS)
    private func cycleExtent(for style: SlideTextAttributes) -> CGFloat {
        let vertical = object.textLayout.resolvedLoopDirection.isVertical
        return vertical
            ? TextAttributeConverter.measureVerticalCycleExtent(style: style)
            : TextAttributeConverter.measureHorizontalCycleExtent(style: style)
    }
    #endif

    private var loopFrameAlignment: Alignment {
        object.loopMarqueeFrameAlignment(direction: object.textLayout.resolvedLoopDirection)
    }
}

#if os(macOS)
/// Loop scroll for `{symbol}` / `{price}` templates — same CoreText path as static live quotes.
private struct LiveQuoteAttributedMarqueeScrollView: View {
    var object: CanvasObject
    var attributed: NSAttributedString
    var scale: CGFloat
    var cycleExtent: CGFloat
    var spacingGap: CGFloat
    var speedPixelsPerSecond: CGFloat
    var loopScroll: TextLoopMarqueeScroll
    var frameAlignment: Alignment

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion || !onScreen)) { timeline in
            let unit = TickerEngine.unitDistance(contentExtent: max(1, cycleExtent), gap: spacingGap)
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let offset = TickerEngine.primaryOffset(
                elapsed: elapsed,
                speed: speedPixelsPerSecond,
                unitDistance: unit,
                scrollForward: loopScroll.scrollForward
            )
            Group {
                if loopScroll.isVertical {
                    VStack(spacing: spacingGap) {
                        attributedCopy
                        attributedCopy
                    }
                    .offset(y: offset)
                } else {
                    HStack(spacing: spacingGap) {
                        attributedCopy
                        attributedCopy
                    }
                    .offset(x: offset)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .clipped()
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityLabel(attributed.string)
    }

    private var attributedCopy: some View {
        CanvasStaticAttributedTextView(object: object, attributed: attributed, layoutScale: scale)
            .fixedSize(horizontal: !loopScroll.isVertical, vertical: loopScroll.isVertical)
    }
}
#endif
