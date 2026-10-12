import Foundation

extension ShowController {
    func emitPropLifecycle(id: UUID, phase: PropLifecyclePhase, at date: Date = Date()) {
        guard let prop = inspector.props.first(where: { $0.id == id }) else { return }
        let objects = resolvedCanvasObjects(prop.elements)
        if PropLifecycleEngine.shouldForceQuoteRefresh(prop: prop, phase: phase) {
            refreshLiveQuotes(now: date, force: true)
        }
        onPropLifecycle?(id, phase, objects)
    }

    func emitSlideLifecycle(_ phase: SlideLifecyclePhase, at date: Date = Date()) {
        switch phase {
        case .enter:
            refreshLiveQuotes(now: date, force: true)
        case .leave:
            break
        }
    }

    /// Collects canvas objects that may contain live-quote tokens and updates the quote engine.
    func refreshLiveQuotes(now: Date = Date(), force: Bool = false) {
        if !force, now.timeIntervalSince(lastLiveQuoteRefreshAt) < liveQuoteRefreshMinInterval {
            return
        }
        lastLiveQuoteRefreshAt = now
        let needed = DynamicTextEngine.quoteRequests(in: quoteCanvasObjects())
        liveQuotes.tick(needed: needed, now: now, force: force)
        syncMarketTickerFromLiveQuotes()
    }

    /// Keeps WebSocket + throttled ticker rows alive for RTMP when props are not on the Audience surface.
    func ensureProgramMarketTickerFeeds(now: Date = Date()) {
        #if os(macOS)
        guard streaming.isLive || isoRecorder.isRecording || wantsEncodedPreview else { return }
        if now.timeIntervalSince(lastMarketTickerFeedAt) < 2 {
            return
        }
        lastMarketTickerFeedAt = now
        let objects = quoteCanvasObjects()
        guard objects.contains(where: MarketTickerRouting.usesLiveMarketDataFeed) else { return }
        for object in objects where MarketTickerRouting.usesLiveMarketDataFeed(object) {
            let endpoint = TickerConfigStore.shared.endpoint(from: object.token)
            let key = endpoint?.absoluteString ?? "live-quotes"
            if armedMarketTickerFeedKeys.contains(key) { continue }
            armedMarketTickerFeedKeys.insert(key)
            let symbols = MarketTickerRouting.watchSymbols(for: object, canvasObjects: objects)
            MarketDataStreamEngine.shared.beginDisplay(endpoint: endpoint, symbols: symbols)
        }
        syncMarketTickerFromLiveQuotes()
        #endif
    }
}
