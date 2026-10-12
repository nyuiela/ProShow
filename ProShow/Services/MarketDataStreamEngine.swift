import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

#if os(macOS)
@MainActor
@Observable
final class MarketDataStreamEngine {
    static let shared = MarketDataStreamEngine()

    private(set) var items: [MarketTickerItem] = []
    /// Bumps when `items` changes; each marquee compiles its own attributed banner at local scale.
    private(set) var bannerRevision: UInt64 = 0

    var onTickerDataUpdated: (([MarketTickerItem]) -> Void)?

    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var publishTimer: Timer?
    @ObservationIgnored private var displayClients = 0
    @ObservationIgnored private var connectedURL: URL?
    @ObservationIgnored private var publishScheduled = false
    @ObservationIgnored private var lastPublishedItems: [MarketTickerItem] = []

    private static let ingestQueue = DispatchQueue(label: "com.proshow.market.data", qos: .utility)
    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var activeItems: [String: MarketTickerItem] = [:]
    nonisolated(unsafe) private static var previousPrices: [String: Double] = [:]
    nonisolated(unsafe) private static var pendingPublish = false

    private init() {}

    func beginDisplay(
        endpoint: URL?,
        symbols: [String]
    ) {
        displayClients += 1
        seedSymbols(symbols)
        if let endpoint, endpoint != connectedURL {
            connect(endpointUrl: endpoint)
        }
        startThrottledPublisher(interval: TickerConfigStore.shared.publishInterval)
        Self.pendingPublish = true
        schedulePublishSnapshot()
    }

    func endDisplay() {
        displayClients = max(0, displayClients - 1)
        guard displayClients == 0 else { return }
        disconnect()
    }

    func connect(endpointUrl: URL) {
        disconnectWebSocketOnly()
        connectedURL = endpointUrl
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: endpointUrl)
        webSocketTask = task
        task.resume()
        listenForMessages()
    }

    func disconnect() {
        disconnectWebSocketOnly()
        connectedURL = nil
        publishTimer?.invalidate()
        publishTimer = nil
    }

    nonisolated func ingestWebhookJSON(_ data: Data) {
        Self.ingestQueue.async {
            Self.mergePayload(data)
            Self.pendingPublish = true
        }
    }

    nonisolated func ingestWebhookText(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }
        ingestWebhookJSON(data)
    }

    func publishSnapshotForTesting(items: [MarketTickerItem]) {
        Self.stateLock.lock()
        Self.activeItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id.uppercased(), $0) })
        Self.stateLock.unlock()
        publishSnapshot()
    }

    /// Updates from `LiveQuoteEngine` polls (same formatter path as WebSocket ticks).
    func ingestLiveQuoteItems(_ items: [MarketTickerItem]) {
        guard !items.isEmpty else { return }
        Self.stateLock.lock()
        var changed = false
        for item in items {
            let key = item.id.uppercased()
            if Self.activeItems[key] != item {
                Self.activeItems[key] = item
                changed = true
            }
        }
        Self.stateLock.unlock()
        guard changed else { return }
        Self.pendingPublish = true
        schedulePublishSnapshot()
    }

    /// Avoid publishing `@Observable` state during an in-flight SwiftUI view update.
    private func schedulePublishSnapshot() {
        if publishScheduled { return }
        publishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishScheduled = false
            if Self.pendingPublish {
                Self.pendingPublish = false
            }
            self.publishSnapshot()
        }
    }

    private func disconnectWebSocketOnly() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func seedSymbols(_ symbols: [String]) {
        Self.ingestQueue.async {
            Self.stateLock.lock()
            for symbol in symbols {
                let key = symbol.uppercased()
                if Self.activeItems[key] != nil { continue }
                Self.activeItems[key] = MarketTickerItem(
                    id: key,
                    symbol: symbol,
                    price: 0,
                    changePercent24h: 0
                )
            }
            Self.stateLock.unlock()
            Self.pendingPublish = true
        }
    }

    private func listenForMessages() {
        webSocketTask?.receive { [weak self] result in
            if case .success(let message) = result {
                switch message {
                case .string(let text):
                    MarketDataStreamEngine.shared.ingestWebhookText(text)
                case .data(let data):
                    MarketDataStreamEngine.shared.ingestWebhookJSON(data)
                @unknown default:
                    break
                }
            }
            Task { @MainActor in
                self?.listenForMessages()
            }
        }
    }

    private func startThrottledPublisher(interval: TimeInterval) {
        publishTimer?.invalidate()
        publishTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard Self.pendingPublish else { return }
                Self.pendingPublish = false
                self?.schedulePublishSnapshot()
            }
        }
    }

    private func publishSnapshot() {
        Self.stateLock.lock()
        let snapshot = Array(Self.activeItems.values).sorted {
            $0.symbol.localizedCaseInsensitiveCompare($1.symbol) == .orderedAscending
        }
        Self.stateLock.unlock()

        guard snapshot != lastPublishedItems else { return }
        lastPublishedItems = snapshot

        items = snapshot
        bannerRevision &+= 1
        onTickerDataUpdated?(snapshot)
    }

    nonisolated private static func mergePayload(_ data: Data) {
        let decoded = decodeItems(from: data)
        guard !decoded.isEmpty else { return }
        stateLock.lock()
        for item in decoded {
            mergeLocked(item)
        }
        stateLock.unlock()
    }

    nonisolated private static func mergeLocked(_ item: MarketTickerItem) {
        var next = item
        let key = item.id.uppercased()
        if abs(next.changePercent24h) < 0.0001, let prev = previousPrices[key], prev > 0, next.price > 0 {
            next.changePercent24h = ((next.price - prev) / prev) * 100
        }
        if next.price > 0 {
            previousPrices[key] = next.price
        }
        activeItems[key] = next
    }

    nonisolated private static func decodeItems(from data: Data) -> [MarketTickerItem] {
        if let item = try? JSONDecoder().decode(MarketTickerItem.self, from: data) {
            return [item]
        }
        if let items = try? JSONDecoder().decode([MarketTickerItem].self, from: data) {
            return items
        }
        if let wire = try? JSONDecoder().decode(MarketTickerWirePacket.self, from: data) {
            return wire.asItems()
        }
        return []
    }
}

private struct MarketTickerWirePacket: Decodable {
    var id: String?
    var symbol: String?
    var s: String?
    var price: Double?
    var c: String?
    var changePercent24h: Double?
    var P: String?
    var data: [MarketTickerWirePacket]?

    func asItems() -> [MarketTickerItem] {
        if let data, !data.isEmpty {
            return data.flatMap { $0.asItems() }
        }
        let sym = symbol ?? s ?? id ?? "TICKER"
        let priceValue = price ?? c.flatMap(Double.init) ?? 0
        let change = changePercent24h ?? P.flatMap(Double.init) ?? 0
        let identity = (id ?? sym).uppercased()
        return [
            MarketTickerItem(
                id: identity,
                symbol: displaySymbol(sym),
                price: priceValue,
                changePercent24h: change
            ),
        ]
    }

    private func displaySymbol(_ raw: String) -> String {
        if raw.contains("/") { return raw }
        if raw.hasSuffix("USDT") {
            let base = String(raw.dropLast(4))
            return "\(base)/USD"
        }
        return raw
    }
}
#endif
