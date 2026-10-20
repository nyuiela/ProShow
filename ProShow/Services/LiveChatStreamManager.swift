import Foundation
import Observation

/// Aggregates Zoom / Meet / platform chat + backstage guest chat into one operator inbox.
@MainActor
@Observable
final class LiveChatStreamManager {
    var enabledSources: Set<ChatPlatform> = [.zoom, .googleMeet, .backstage]
    var inbox: [LiveChatMessage] = []
    var activeOverlay: LiveChatMessage?
    var autoClearSeconds: Int = 10
    var lastIngestError: String?

    private weak var chatEngine: LiveChatEngine?
    private var seenKeys: Set<String> = []
    /// Session-only blocks, keyed by platform:authorID.
    private(set) var blockedAuthors: Set<String> = []
    private var seenOrder: [String] = []
    static let seenLimit = 2000
    private var autoClearTask: Task<Void, Never>?

    init(chatEngine: LiveChatEngine) {
        self.chatEngine = chatEngine
    }

    func setSourceEnabled(_ platform: ChatPlatform, enabled: Bool) {
        if enabled {
            enabledSources.insert(platform)
        } else {
            enabledSources.remove(platform)
        }
    }

    /// Returns false when the source is off or the message is a duplicate.
    @discardableResult
    func ingest(_ message: LiveChatMessage) -> Bool {
        let platform = ChatPlatform.from(displayName: message.platformSource)
        guard enabledSources.contains(platform) else { return false }
        if let author = message.authorID, blockedAuthors.contains("\(platform.rawValue):\(author)") { return false }
        if let key = message.dedupeKey {
            guard !seenKeys.contains(key) else { return false }
            remember(key)
        }
        inbox.insert(message, at: 0)
        if inbox.count > 200 {
            inbox = Array(inbox.prefix(200))
        }
        if let studio = message.asStudioChatMessage() {
            chatEngine?.ingest(studio)
        }
        return true
    }

    /// Oldest first batch from a connector. Returns how many were added.
    @discardableResult
    func ingestBatch(_ messages: [LiveChatMessage]) -> Int {
        var added = 0
        for message in messages where ingest(message) { added += 1 }
        return added
    }

    /// Operator hide. The message never comes back on replay. True when it was on screen.
    @discardableResult
    func hide(id: String) -> Bool {
        guard let message = inbox.first(where: { $0.id == id }) else { return false }
        if let key = message.dedupeKey, !seenKeys.contains(key) { remember(key) }
        return removeWhere { $0.id == id }
    }

    /// Operator block for this session: hides the author's messages now and later.
    @discardableResult
    func blockAuthor(of id: String) -> Bool {
        guard let message = inbox.first(where: { $0.id == id }) else { return false }
        let platform = ChatPlatform.from(displayName: message.platformSource)
        guard let author = message.authorID else { return hide(id: id) }
        blockedAuthors.insert("\(platform.rawValue):\(author)")
        return removeAuthors(platform: platform, authorIDs: [author])
    }

    /// Upstream delete. Returns true when the removed message was on screen.
    @discardableResult
    func removeExternal(platform: ChatPlatform, ids: [String]) -> Bool {
        let keys = Set(ids.map { "\(platform.rawValue):\($0)" })
        for key in keys where !seenKeys.contains(key) { remember(key) }
        return removeWhere { $0.dedupeKey.map(keys.contains) ?? false }
    }

    /// Upstream ban. Returns true when a removed message was on screen.
    @discardableResult
    func removeAuthors(platform: ChatPlatform, authorIDs: [String]) -> Bool {
        let ids = Set(authorIDs)
        return removeWhere {
            ChatPlatform.from(displayName: $0.platformSource) == platform && ($0.authorID.map(ids.contains) ?? false)
        }
    }

    private func removeWhere(_ match: (LiveChatMessage) -> Bool) -> Bool {
        let onScreen = activeOverlay.map(match) ?? false
        inbox.removeAll(where: match)
        return onScreen
    }

    private func remember(_ key: String) {
        seenKeys.insert(key)
        seenOrder.append(key)
        if seenOrder.count > Self.seenLimit {
            let drop = seenOrder.count - Self.seenLimit
            for old in seenOrder.prefix(drop) { seenKeys.remove(old) }
            seenOrder.removeFirst(drop)
        }
    }

    @discardableResult
    func triggerChatOverlay(_ message: LiveChatMessage, on compositor: CompositorEngine) -> ChatOverlayCard? {
        var featured = message
        featured.isFeaturedOnScreen = true
        activeOverlay = featured
        if let index = inbox.firstIndex(where: { $0.id == message.id }) {
            inbox[index] = featured
        } else {
            ingest(featured)
        }
        guard let studio = featured.asStudioChatMessage() else { return nil }
        let card = chatEngine?.pushOverlay(studio)
        if let card {
            compositor.setChatOverlay(card)
            scheduleAutoClear(compositor: compositor)
        }
        return card
    }

    func triggerChatOverlay(id: String, compositor: CompositorEngine) -> ChatOverlayCard? {
        guard let message = inbox.first(where: { $0.id == id }) else { return nil }
        return triggerChatOverlay(message, on: compositor)
    }

    func dismissOverlay(compositor: CompositorEngine) {
        autoClearTask?.cancel()
        activeOverlay = nil
        chatEngine?.dismissOverlay()
        compositor.setChatOverlay(nil)
        for index in inbox.indices where inbox[index].isFeaturedOnScreen {
            inbox[index].isFeaturedOnScreen = false
        }
    }

    func toggleStar(id: String) {
        guard let index = inbox.firstIndex(where: { $0.id == id }) else { return }
        inbox[index].isStarred.toggle()
    }

    private func scheduleAutoClear(compositor: CompositorEngine) {
        autoClearTask?.cancel()
        let seconds = max(0, autoClearSeconds)
        guard seconds > 0 else { return }
        autoClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.dismissOverlay(compositor: compositor)
            }
        }
    }
}
