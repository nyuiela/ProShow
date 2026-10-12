import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// Real-time crypto/market strip driven by `MarketDataStreamEngine` + seamless `CATextLayer` updates.
struct LiveMarketMarqueeView: View {
    var object: CanvasObject
    var canvasObjects: [CanvasObject]
    var scale: CGFloat
    var reduceMotion: Bool

    @Bindable private var stream = MarketDataStreamEngine.shared
    var liveQuotes: [String: LiveQuote] = [:]

    private var config: TickerConfigStore { TickerConfigStore.shared }

    private var frameAlignment: Alignment {
        object.loopMarqueeFrameAlignment(direction: object.textLayout.resolvedLoopDirection)
    }

    var body: some View {
        Group {
            if reduceMotion {
                restingCopy
            } else {
                LiveMarketMarqueeRepresentable(
                    object: object,
                    canvasObjects: canvasObjects,
                    scale: scale,
                    liveQuotes: liveQuotes,
                    items: stream.items,
                    bannerRevision: stream.bannerRevision,
                    colorConfig: config.colorConfig
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            }
        }
        .onAppear(perform: startStream)
        .onDisappear { stream.endDisplay() }
        .onChange(of: liveQuoteFingerprint) { _, _ in
            syncQuotes()
        }
    }

    private var liveQuoteFingerprint: String {
        liveQuotes
            .map { key, quote in
                "\(key)|\(quote.price)|\(quote.changePercent)|\(quote.updatedAt.timeIntervalSinceReferenceDate)"
            }
            .sorted()
            .joined(separator: ";")
    }

    private var restingCopy: some View {
        tickerBannerText(items: displayItems)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .clipped()
    }

    private func tickerBannerText(items: [MarketTickerItem]) -> some View {
        let inkStyle = SlideTextAttributes.from(object: object, text: " ", scale: scale)
        let banner = CryptoTickerFormatter.makeTickerAttributedString(
            items: items,
            object: object,
            scale: scale,
            colorConfig: config.colorConfig
        )
        return Text(AttributedString(banner))
            .baselineOffset(canvasBaselineOffset)
            .lineLimit(1)
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

    private var displayItems: [MarketTickerItem] {
        MarketTickerRouting.resolvedTickerItems(
            object: object,
            canvasObjects: canvasObjects,
            streamItems: stream.items,
            liveQuotes: liveQuotes
        )
    }

    private func startStream() {
        let symbols = MarketTickerRouting.watchSymbols(for: object, canvasObjects: canvasObjects)
        let endpoint = config.endpoint(from: object.token)
        stream.beginDisplay(endpoint: endpoint, symbols: symbols)
        syncQuotes()
    }

    private func syncQuotes() {
        let objects = canvasObjects.isEmpty ? [object] : canvasObjects
        LiveQuoteTickerBridge.sync(quotes: liveQuotes, canvasObjects: objects)
    }
}

private struct LiveMarketMarqueeRepresentable: NSViewRepresentable {
    var object: CanvasObject
    var canvasObjects: [CanvasObject]
    var scale: CGFloat
    var liveQuotes: [String: LiveQuote]
    var items: [MarketTickerItem]
    var bannerRevision: UInt64
    var colorConfig: TickerColorConfig

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MarqueeTickerContainerView {
        let view = MarqueeTickerContainerView()
        context.coordinator.container = view
        pushBanner(to: view, context: context, preservePhase: false)
        return view
    }

    func updateNSView(_ nsView: MarqueeTickerContainerView, context: Context) {
        context.coordinator.container = nsView
        let signature = renderSignature
        guard context.coordinator.lastRenderSignature != signature else {
            applyScrollConfiguration(to: nsView, cycleExtent: context.coordinator.lastCycleExtent, preservePhase: true)
            return
        }
        context.coordinator.lastRenderSignature = signature
        pushBanner(to: nsView, context: context, preservePhase: true)
    }

    static func dismantleNSView(_ nsView: MarqueeTickerContainerView, coordinator: Coordinator) {
        coordinator.container = nil
        nsView.stopDisplayLink()
    }

    private var inkStyle: SlideTextAttributes {
        SlideTextAttributes.from(object: object, text: " ", scale: scale)
    }

    private var bannerItems: [MarketTickerItem] {
        MarketTickerRouting.resolvedTickerItems(
            object: object,
            canvasObjects: canvasObjects,
            streamItems: items,
            liveQuotes: liveQuotes
        )
    }

    private var renderSignature: String {
        let quoteSig = liveQuotes
            .map { "\($0.key)|\($0.value.price)|\($0.value.changePercent)" }
            .sorted()
            .joined(separator: ";")
        let itemSig = bannerItems.map { "\($0.id)|\($0.price)|\($0.changePercent24h)" }.joined(separator: ";")
        let style = inkStyle
        return [
            itemSig,
            quoteSig,
            "\(bannerRevision)",
            "\(scale)",
            object.typography.fontFamily,
            "\(object.typography.fontSize)",
            "\(object.typography.fontWeight.rawValue)",
            "\(object.typography.isBold)",
            "\(object.typography.isItalic)",
            object.typography.color,
            "\(object.textOutline.enabled)",
            object.textOutline.color,
            "\(object.textOutline.width)",
            "\(object.textShadow.enabled)",
            object.textShadow.color,
            "\(object.textShadow.blur)",
            "\(object.textShadow.offset)",
            "\(object.textShadow.angle)",
            "\(object.textLayout.characterSpacing)",
            "\(object.textLayout.lineHeight)",
            "\(object.textLayout.wordSpacing)",
            object.textLayout.verticalAlign.rawValue,
            object.textLayout.horizontalAlign.rawValue,
            "\(object.textLayout.resolvedLoopGap)",
            "\(object.textLayout.resolvedLoopSpeed)",
            object.textLayout.resolvedLoopDirection.rawValue,
            style.strokeColor?.description ?? "",
            "\(style.strokeWidth)",
            style.shadowColor?.description ?? "",
            "\(style.shadowRadius)",
        ].joined(separator: "|")
    }

    private func compiledBanner() -> (NSAttributedString, CGFloat) {
        let banner = CryptoTickerFormatter.makeTickerAttributedString(
            items: bannerItems,
            object: object,
            scale: scale,
            colorConfig: colorConfig
        )
        let loop = object.textLayout.resolvedLoopDirection.marqueeScroll
        let extent = loop.isVertical
            ? TextAttributeConverter.measureVerticalInkExtent(
                for: banner,
                decorationPadding: inkStyle.decorationPadding
            )
            : CryptoTickerFormatter.measureHorizontalCycleExtent(
                for: banner,
                decorationPadding: inkStyle.decorationPadding
            )
        return (banner, extent)
    }

    private func pushBanner(to view: MarqueeTickerContainerView, context: Context, preservePhase: Bool) {
        let (banner, extent) = compiledBanner()
        context.coordinator.lastCycleExtent = extent
        applyScrollConfiguration(to: view, cycleExtent: extent, preservePhase: preservePhase)
        view.updateLiveMarketText(
            newAttrString: banner,
            newMeasuredWidth: max(1, extent),
            inkStyle: inkStyle
        )
    }

    private func applyScrollConfiguration(to view: MarqueeTickerContainerView, cycleExtent: CGFloat, preservePhase: Bool) {
        let loop = object.textLayout.resolvedLoopDirection.marqueeScroll
        view.apply(
            style: inkStyle,
            cycleExtent: max(1, cycleExtent),
            spacingGap: CGFloat(object.textLayout.resolvedLoopGap) * scale,
            speed: CGFloat(object.textLayout.resolvedLoopSpeed) * scale,
            isVertical: loop.isVertical,
            scrollForward: loop.scrollForward,
            anchorToTrailing: loop.anchorToTrailing,
            anchorToBottom: loop.anchorToBottom,
            verticalAlign: object.textLayout.verticalAlign,
            containerSize: view.bounds.size,
            preserveScrollPhase: preservePhase,
            usesExternalLiveContent: true
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeTickerContainerView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        let height = proposal.height ?? nsView.bounds.height
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Coordinator {
        weak var container: MarqueeTickerContainerView?
        var lastRenderSignature: String = ""
        var lastCycleExtent: CGFloat = 1
    }
}

/// Live market prices in place (colored deltas) without enabling Loop scroll.
struct StaticColoredLiveQuoteView: View {
    var object: CanvasObject
    var canvasObjects: [CanvasObject]
    var scale: CGFloat
    var liveQuotes: [String: LiveQuote] = [:]

    #if os(macOS)
    @Bindable private var stream = MarketDataStreamEngine.shared
    private var config: TickerConfigStore { TickerConfigStore.shared }
    #endif

    private var frameAlignment: Alignment {
        object.canvasTextFrameAlignment
    }

    var body: some View {
        #if os(macOS)
        banner
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: frameAlignment)
            .clipped()
            .onAppear(perform: startStream)
            .onDisappear { stream.endDisplay() }
            .onChange(of: liveQuoteFingerprint) { _, _ in syncQuotes() }
        #else
        EmptyView()
        #endif
    }

    #if os(macOS)
    private var banner: some View {
        let items = MarketTickerRouting.resolvedTickerItems(
            object: object,
            canvasObjects: canvasObjects,
            streamItems: stream.items,
            liveQuotes: liveQuotes
        )
        let inkStyle = SlideTextAttributes.from(object: object, text: " ", scale: scale)
        let attributed = CryptoTickerFormatter.makeTickerAttributedString(
            items: items,
            object: object,
            scale: scale,
            colorConfig: config.colorConfig
        )
        return Text(AttributedString(attributed))
            .baselineOffset(canvasBaselineOffset)
            .lineLimit(object.textLayout.linesOnly == true ? 1 : nil)
    }

    private var canvasBaselineOffset: CGFloat {
        if object.typography.isSuperscript { return object.typography.fontSize * scale * 0.35 }
        if object.typography.isSubscript { return -object.typography.fontSize * scale * 0.25 }
        return 0
    }

    private var liveQuoteFingerprint: String {
        liveQuotes
            .map { key, quote in
                "\(key)|\(quote.price)|\(quote.changePercent)|\(quote.updatedAt.timeIntervalSinceReferenceDate)"
            }
            .sorted()
            .joined(separator: ";")
    }

    private func startStream() {
        let symbols = MarketTickerRouting.watchSymbols(for: object, canvasObjects: canvasObjects)
        let endpoint = config.endpoint(from: object.token)
        stream.beginDisplay(endpoint: endpoint, symbols: symbols)
        syncQuotes()
    }

    private func syncQuotes() {
        let objects = canvasObjects.isEmpty ? [object] : canvasObjects
        LiveQuoteTickerBridge.sync(quotes: liveQuotes, canvasObjects: objects)
    }
    #endif
}
#endif
