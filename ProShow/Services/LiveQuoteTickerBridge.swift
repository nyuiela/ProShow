import Foundation
#if os(macOS)
import AppKit
#endif

enum MarketTickerRouting {
    private static let defaultWatchSymbols = ["BTC/USD", "ETH/USD", "SOL/USD"]

    /// Scrolling colored ticker (requires Loop). Respects Live Quote **Display** templates; colored strip only for `{quote:…}` lists and market tickers.
    static func usesColoredStrip(_ object: CanvasObject) -> Bool {
        guard object.textLayout.isLooping else { return false }
        if object.kind == .liveQuote {
            return DynamicTextEngine.isQuoteDirectiveTemplate(liveQuoteDisplayTemplate(for: object))
        }
        if object.textLayout.resolvedMarketTickerStrip { return true }
        if MarketTickerTokenParser.isMarketToken(object.token) { return true }
        return false
    }

    /// In-place green/red ticker row(s) — only for multi-`{quote:…}` or market strips, not custom Display templates.
    static func usesStaticColoredLiveQuote(_ object: CanvasObject) -> Bool {
        guard !object.textLayout.isLooping else { return false }
        if object.kind == .liveQuote {
            return DynamicTextEngine.isQuoteDirectiveTemplate(liveQuoteDisplayTemplate(for: object))
        }
        if object.textLayout.resolvedMarketTickerStrip { return true }
        if MarketTickerTokenParser.isMarketToken(object.token) { return true }
        return false
    }

    /// Body used for Live Quote rendering (`object.text` / Display field).
    static func liveQuoteDisplayTemplate(for object: CanvasObject) -> String {
        let trimmed = object.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? LiveQuoteCatalog.defaultTemplate : object.text
    }

    /// Poll/stream market rows for colored live presentation (loop or static).
    static func usesLiveMarketDataFeed(_ object: CanvasObject) -> Bool {
        usesColoredStrip(object) || usesStaticColoredLiveQuote(object)
    }

    static func watchSymbols(for object: CanvasObject, canvasObjects: [CanvasObject]) -> [String] {
        if object.kind == .liveQuote {
            let requests = DynamicTextEngine.quoteRequests(in: canvasObjects)
            if !requests.isEmpty {
                return requests.map(\.symbol)
            }
            return [DynamicTextEngine.quoteSpec(for: object).symbol]
        }
        if MarketTickerTokenParser.isMarketToken(object.token) {
            return MarketTickerTokenParser.watchSymbols(from: object, fallback: defaultWatchSymbols)
        }
        let fromText = object.text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !fromText.isEmpty { return fromText }
        return defaultWatchSymbols
    }
}

#if os(macOS)
enum LiveQuoteTickerBridge {
    @MainActor
    static func sync(quotes: [String: LiveQuote], canvasObjects: [CanvasObject]) {
        guard canvasObjects.contains(where: MarketTickerRouting.usesLiveMarketDataFeed) else { return }
        let requests = DynamicTextEngine.quoteRequests(in: canvasObjects)
        let items = marketItems(from: requests, quotes: quotes)
        guard !items.isEmpty else { return }
        MarketDataStreamEngine.shared.ingestLiveQuoteItems(items)
    }

    static func marketItems(from requests: [LiveQuoteRequest], quotes: [String: LiveQuote]) -> [MarketTickerItem] {
        var seen = Set<String>()
        var items: [MarketTickerItem] = []
        for request in requests {
            let normalized = request.normalizedSymbol.uppercased()
            guard seen.insert(normalized).inserted else { continue }
            if let quote = resolveQuote(request: request, quotes: quotes) {
                items.append(
                    MarketTickerItem(
                        id: normalized,
                        symbol: LiveQuoteCatalog.displaySymbol(quote),
                        price: quote.price,
                        changePercent24h: quote.changePercent
                    )
                )
            } else {
                items.append(
                    MarketTickerItem(
                        id: normalized,
                        symbol: request.symbol.uppercased(),
                        price: 0,
                        changePercent24h: 0
                    )
                )
            }
        }
        return items.sorted { $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending }
    }

    private static func resolveQuote(request: LiveQuoteRequest, quotes: [String: LiveQuote]) -> LiveQuote? {
        let candidates = [
            request.normalizedSymbol.uppercased(),
            request.symbol.uppercased(),
            request.symbol,
        ]
        for key in candidates {
            if let quote = quotes[key] { return quote }
        }
        for quote in quotes.values where quote.symbol.uppercased() == request.normalizedSymbol.uppercased() {
            return quote
        }
        return nil
    }
}

extension MarketTickerRouting {
    /// Stream items when available; otherwise placeholder rows matching reduce-motion preview.
    static func resolvedTickerItems(
        object: CanvasObject,
        canvasObjects: [CanvasObject],
        streamItems: [MarketTickerItem],
        liveQuotes: [String: LiveQuote]
    ) -> [MarketTickerItem] {
        let scope = canvasObjects.isEmpty ? [object] : canvasObjects
        let requests = DynamicTextEngine.quoteRequests(in: scope)
        if !requests.isEmpty {
            let fromQuotes = LiveQuoteTickerBridge.marketItems(from: requests, quotes: liveQuotes)
            let hasLivePrices = fromQuotes.contains { $0.price > 0.000_001 }
            if hasLivePrices || streamItems.isEmpty || !liveQuotes.isEmpty {
                return fromQuotes
            }
        }
        if !streamItems.isEmpty { return streamItems }
        if !requests.isEmpty {
            return LiveQuoteTickerBridge.marketItems(from: requests, quotes: liveQuotes)
        }
        return watchSymbols(for: object, canvasObjects: canvasObjects).map { symbol in
            MarketTickerItem(id: symbol, symbol: symbol, price: 0, changePercent24h: 0)
        }
    }
}
#endif
