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

    func ingest(_ message: LiveChatMessage) {
        let platform = ChatPlatform.from(displayName: message.platformSource)
        guard enabledSources.contains(platform) else { return }
        inbox.insert(message, at: 0)
        if inbox.count > 200 {
            inbox = Array(inbox.prefix(200))
        }
        if let studio = message.asStudioChatMessage() {
            chatEngine?.ingest(studio)
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
