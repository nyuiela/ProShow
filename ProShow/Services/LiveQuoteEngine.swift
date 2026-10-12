import Foundation
import Observation

protocol LiveQuoteProviding: Sendable {
    func fetchQuotes(_ requests: [LiveQuoteRequest]) async -> [LiveQuote]
}

@MainActor
@Observable
final class LiveQuoteEngine {
    var quotes: [String: LiveQuote] = [:]
    var lastError: String?
    var minimumInterval: TimeInterval = 20

    @ObservationIgnored private var lastFetch: Date?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored var provider: LiveQuoteProviding
    @ObservationIgnored var onQuotesUpdated: (() -> Void)?

    init(provider: LiveQuoteProviding = MarketQuoteProvider()) {
        self.provider = provider
    }

    /// True while program output should stay blank (before the first fetch cycle finishes).
    var isAwaitingFirstQuotePayload: Bool {
        quotes.isEmpty && lastError == nil && (inFlight || lastFetch == nil)
    }

    func tick(needed: [LiveQuoteRequest], now: Date = Date(), force: Bool = false) {
        guard !needed.isEmpty else { return }
        if inFlight, !force, !needed.contains(where: isMissing) {
            return
        }
        guard !inFlight else { return }
        let needsInitialLoad = needed.contains { isMissing($0) }
        if !force, let lastFetch, !needsInitialLoad, now.timeIntervalSince(lastFetch) < minimumInterval { return }
        inFlight = true
        lastFetch = now
        let requests = needed
        Task { [provider] in
            let fetched = await provider.fetchQuotes(requests)
            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { inFlight = false }
                for quote in fetched {
                    quotes[quote.symbol.uppercased()] = quote
                    let normalized = LiveQuoteCatalog.normalizedSymbol(quote.symbol, kind: quote.kind).uppercased()
                    quotes[normalized] = quote
                    quotes[LiveQuoteCatalog.displaySymbol(quote).uppercased()] = quote
                }
                lastError = fetched.isEmpty && !requests.isEmpty ? "Quotes unavailable" : nil
                onQuotesUpdated?()
            }
        }
    }

    private func isMissing(_ request: LiveQuoteRequest) -> Bool {
        let candidates = [
            request.symbol.uppercased(),
            request.normalizedSymbol.uppercased(),
            LiveQuoteCatalog.normalizedSymbol(request.symbol, kind: request.kind).uppercased(),
        ]
        return !candidates.contains { quotes[$0] != nil }
    }
}

struct MarketQuoteProvider: LiveQuoteProviding {
    func fetchQuotes(_ requests: [LiveQuoteRequest]) async -> [LiveQuote] {
        var results: [LiveQuote] = []
        let stocks = requests.filter { $0.kind == .stock }
        let cryptos = requests.filter { $0.kind == .crypto }
        if !stocks.isEmpty {
            results.append(contentsOf: await fetchStocks(stocks))
        }
        if !cryptos.isEmpty {
            results.append(contentsOf: await fetchCryptos(cryptos))
        }
        return results
    }

    private func fetchStocks(_ requests: [LiveQuoteRequest]) async -> [LiveQuote] {
        await withTaskGroup(of: LiveQuote?.self) { group in
            for request in requests {
                group.addTask {
                    await self.fetchYahoo(symbol: request.normalizedSymbol)
                }
            }
            var quotes: [LiveQuote] = []
            for await quote in group {
                if let quote { quotes.append(quote) }
            }
            return quotes
        }
    }

    private func fetchYahoo(symbol: String) async -> LiveQuote? {
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)?interval=1d&range=1d") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("ProShow/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chart = root["chart"] as? [String: Any],
              let result = (chart["result"] as? [[String: Any]])?.first,
              let meta = result["meta"] as? [String: Any]
        else { return nil }
        let price = double(meta["regularMarketPrice"]) ?? 0
        let previous = double(meta["chartPreviousClose"]) ?? price
        let change = previous == 0 ? 0 : ((price - previous) / previous) * 100
        return LiveQuote(
            symbol: (meta["symbol"] as? String) ?? symbol,
            name: (meta["shortName"] as? String) ?? symbol,
            price: price,
            changePercent: change,
            currency: (meta["currency"] as? String) ?? "USD",
            kind: .stock,
            updatedAt: Date()
        )
    }

    private func fetchCryptos(_ requests: [LiveQuoteRequest]) async -> [LiveQuote] {
        let ids = requests.map(\.normalizedSymbol).joined(separator: ",")
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=\(ids)&vs_currencies=usd&include_24hr_change=true") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
        else { return [] }
        return requests.compactMap { item in
            let id = item.normalizedSymbol
            guard let payload = root[id], let price = double(payload["usd"]) else { return nil }
            return LiveQuote(
                symbol: id,
                name: id.replacingOccurrences(of: "-", with: " ").capitalized,
                price: price,
                changePercent: double(payload["usd_24h_change"]) ?? 0,
                currency: "USD",
                kind: .crypto,
                updatedAt: Date()
            )
        }
    }

    private func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let text as String: return Double(text)
        default: return nil
        }
    }
}
