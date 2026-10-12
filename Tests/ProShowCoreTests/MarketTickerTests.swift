import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)
@Suite
struct MarketTickerTests {
    @Test
    func deltaDirection_thresholds() {
        let up = MarketTickerItem(id: "BTC", symbol: "BTC/USD", price: 100, changePercent24h: 2.5)
        let down = MarketTickerItem(id: "ETH", symbol: "ETH/USD", price: 50, changePercent24h: -1.2)
        let flat = MarketTickerItem(id: "SOL", symbol: "SOL/USD", price: 20, changePercent24h: 0)
        #expect(up.direction == .positive)
        #expect(down.direction == .negative)
        #expect(flat.direction == .neutral)
    }

    @Test
    func formatter_appliesGreenAndRedDeltaColors() {
        let config = TickerColorConfig()
        let font = NSFont.systemFont(ofSize: 24, weight: .bold)
        let items = [
            MarketTickerItem(id: "BTC", symbol: "BTC/USD", price: 64_230.5, changePercent24h: 3.42),
            MarketTickerItem(id: "ETH", symbol: "ETH/USD", price: 3_210.2, changePercent24h: -1.18),
        ]
        let banner = CryptoTickerFormatter.makeTickerAttributedString(
            items: items,
            font: font,
            colorConfig: config
        )
        let green = config.upColor
        let red = config.downColor
        var sawGreen = false
        var sawRed = false
        banner.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: banner.length)) { value, _, _ in
            guard let color = value as? NSColor else { return }
            if color.hexStringForTests == green.hexStringForTests { sawGreen = true }
            if color.hexStringForTests == red.hexStringForTests { sawRed = true }
        }
        #expect(sawGreen)
        #expect(sawRed)
        #expect(banner.string.contains("▲ +"))
        #expect(banner.string.contains("▼"))
    }

    @Test
    func tickerEngine_preservesPhaseWhenWidthChanges() {
        let speed: CGFloat = 120
        let start: CFTimeInterval = 1_000
        let now: CFTimeInterval = 1_005
        let oldUnit: CGFloat = 240
        let phase = TickerEngine.phaseRemainder(startTime: start, now: now, speed: speed, unitDistance: oldUnit)
        let adjusted = TickerEngine.startTimePreservingPhase(phase: phase, now: now, speed: speed)
        let phaseAfter = TickerEngine.phaseRemainder(startTime: adjusted, now: now, speed: speed, unitDistance: 360)
        #expect(abs(phase - phaseAfter) < 0.001)
    }

    @Test
    func marketTokenParser_detectsMarketTokens() {
        #expect(MarketTickerTokenParser.isMarketToken("market"))
        #expect(MarketTickerTokenParser.isMarketToken("market:live"))
        #expect(MarketTickerTokenParser.isMarketToken("market:BTC/USD,ETH/USD"))
        #expect(!MarketTickerTokenParser.isMarketToken("quote:BTC"))
    }

    @Test
    @MainActor
    func streamEngine_compilesColoredBannerSnapshot() {
        let engine = MarketDataStreamEngine.shared
        engine.publishSnapshotForTesting(
            items: [
                MarketTickerItem(id: "BTC", symbol: "BTC/USD", price: 100, changePercent24h: 2.2),
                MarketTickerItem(id: "ETH", symbol: "ETH/USD", price: 50, changePercent24h: -0.8),
            ]
        )
        #expect(engine.bannerRevision > 0)
        #expect(!engine.items.isEmpty)
        let banner = CryptoTickerFormatter.makeTickerAttributedString(
            items: engine.items,
            font: .systemFont(ofSize: 24, weight: .bold),
            colorConfig: TickerColorConfig()
        )
        #expect(banner.length > 0)
        #expect(CryptoTickerFormatter.measureHorizontalCycleExtent(for: banner) > 10)
    }
}

private extension NSColor {
    var hexStringForTests: String {
        guard let rgb = usingColorSpace(.deviceRGB) else { return "" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
#endif
