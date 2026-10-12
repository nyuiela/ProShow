import Foundation
import Observation

@MainActor
@Observable
final class TickerConfigStore {
    static let shared = TickerConfigStore()

    var colorConfig = TickerColorConfig()
    var websocketEndpoint: URL?
    var defaultSymbols: [String] = ["BTC/USD", "ETH/USD", "SOL/USD"]
    var publishInterval: TimeInterval = 0.10

    private init() {}

    func endpoint(from token: String) -> URL? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("market:ws:") else { return websocketEndpoint }
        let raw = String(trimmed.dropFirst("market:ws:".count))
        return URL(string: raw)
    }
}
