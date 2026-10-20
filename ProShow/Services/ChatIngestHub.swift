import Foundation
import Observation

/// Main actor facade for chat connectors. Holds UI state only; the connectors
/// do their work on their own actors. See docs/PROSHOW_LIVE_CHAT_PLAN.md.
@MainActor
@Observable
final class ChatIngestHub {
    var youtubeState: ChatConnectorState = .idle
    var youtubeTitle: String?
    var youtubeQuotaUnits = 0
    var youtubeMessageCount = 0
    var youtubeConnects = 0
    var youtubeLastHoldSeconds: Double?
    var youtubeDayUnits = 0
    /// True when Go Live started the connector (stopping the broadcast stops it).
    private(set) var youtubeAutoStarted = false

    @ObservationIgnored weak var stream: LiveChatStreamManager?
    @ObservationIgnored var tokenProvider: YouTubeChatConnector.TokenProvider?
    @ObservationIgnored var makeConnector: ((@escaping YouTubeChatConnector.TokenProvider, @escaping @Sendable (YouTubeChatUpdate) async -> Void) -> YouTubeChatConnector)?
    /// Clears the on-screen card when its message is removed upstream.
    @ObservationIgnored var clearOverlay: (() -> Void)?
    @ObservationIgnored private var youtube: YouTubeChatConnector?
    @ObservationIgnored private var generation = 0

    init(stream: LiveChatStreamManager?) {
        self.stream = stream
    }

    var isEnabled: Bool { LiveChatIngestFlags.liveChatIngestV1 }

    @discardableResult
    func connectYouTube(_ target: YouTubeChatTarget, auto: Bool = false) -> Bool {
        guard isEnabled else { return false }
        guard let tokenProvider else {
            youtubeState = .failed("Connect a YouTube account")
            return false
        }
        stopYouTube()
        generation += 1
        let gen = generation
        youtubeAutoStarted = auto
        youtubeTitle = nil
        youtubeMessageCount = 0
        youtubeConnects = 0
        youtubeLastHoldSeconds = nil
        stream?.setSourceEnabled(.youtube, enabled: true)
        let onUpdate: @Sendable (YouTubeChatUpdate) async -> Void = { [weak self] update in
            await MainActor.run { self?.apply(update, generation: gen) }
        }
        let connector = makeConnector?(tokenProvider, onUpdate)
            ?? YouTubeChatConnector(token: tokenProvider, onUpdate: onUpdate)
        youtube = connector
        youtubeState = .resolving
        Task { await connector.start(target) }
        return true
    }

    func stopYouTube() {
        generation += 1
        if let youtube {
            Task { await youtube.stop() }
        }
        youtube = nil
        youtubeAutoStarted = false
        youtubeState = .idle
    }

    func stopAutoStarted() {
        if youtubeAutoStarted { stopYouTube() }
    }

    private func apply(_ update: YouTubeChatUpdate, generation gen: Int) {
        guard gen == generation else { return }
        if let state = update.state { youtubeState = state }
        if let title = update.title { youtubeTitle = title }
        if let units = update.quotaUnits { youtubeQuotaUnits = units }
        if let connects = update.connects { youtubeConnects = connects }
        if let hold = update.holdSeconds { youtubeLastHoldSeconds = hold }
        if let day = update.dayUnits { youtubeDayUnits = day }
        if let page = update.page {
            let added = stream?.ingestBatch(page.messages) ?? 0
            youtubeMessageCount += added
            var overlayRemoved = false
            if !page.removedMessageIDs.isEmpty {
                overlayRemoved = stream?.removeExternal(platform: .youtube, ids: page.removedMessageIDs) ?? false
            }
            if !page.bannedAuthorIDs.isEmpty {
                overlayRemoved = (stream?.removeAuthors(platform: .youtube, authorIDs: page.bannedAuthorIDs) ?? false) || overlayRemoved
            }
            if overlayRemoved { clearOverlay?() }
        }
    }

    func statusJSON() -> [String: Any] {
        [
            "ok": true,
            "enabled": isEnabled,
            "state": youtubeState.label,
            "active": youtubeState.isActive,
            "title": youtubeTitle ?? "",
            "messages": youtubeMessageCount,
            "quota_units": youtubeQuotaUnits,
            "quota_units_today": youtubeDayUnits,
            "quota_budget": YouTubeQuotaLedger.dailyBudget,
            "stream_connects": youtubeConnects,
            "last_hold_s": youtubeLastHoldSeconds.map { (($0 * 10).rounded()) / 10 } ?? 0,
            "auto": youtubeAutoStarted,
        ]
    }
}
