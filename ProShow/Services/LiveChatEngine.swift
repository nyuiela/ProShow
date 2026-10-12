import Foundation
import Observation

enum WidgetKind: String, Hashable, Codable, Sendable {
    case liveChat, streamAlert, lowerThird
}

struct StudioWidget: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var kind: WidgetKind
    var title: String
    var enabled: Bool
}

/// Widget catalog replacing church-only Bible/CCLI navigation.
@MainActor
@Observable
final class WidgetEngine {
    var widgets: [StudioWidget] = [
        StudioWidget(id: UUID(uuidString: "E11E0000-0000-4000-8000-000000000001")!, kind: .liveChat, title: "Live Chat", enabled: true),
        StudioWidget(id: UUID(uuidString: "E11E0000-0000-4000-8000-000000000002")!, kind: .streamAlert, title: "Stream Alerts", enabled: true),
        StudioWidget(id: UUID(uuidString: "E11E0000-0000-4000-8000-000000000003")!, kind: .lowerThird, title: "Lower Third", enabled: true),
    ]

    func enabled(_ kind: WidgetKind) -> Bool {
        widgets.first(where: { $0.kind == kind })?.enabled ?? false
    }
}

/// YouTube / Twitch / Facebook / X comment ingest and Layer-8 overlay cards.
@MainActor
@Observable
final class LiveChatEngine {
    var inbox: [ChatMessage] = []
    var overlay: ChatOverlayCard?
    var connectedPlatforms: Set<ChatPlatform> = []
    let widgets = WidgetEngine()

    /// Platform OAuth clients ship separately; webhook ingest via Control API is always available.
    static var platformClientAvailable: Bool {
        ProcessInfo.processInfo.environment["PROSHOW_CHAT_OAUTH"] == "1"
    }

    func connect(_ platform: ChatPlatform) {
        if Self.platformClientAvailable {
            connectedPlatforms.insert(platform)
        }
    }

    func ingestWebhook(platform: String, body: Data) -> LiveChatMessage? {
        guard let message = LiveChatIngestService.parseWebhook(platform: platform, body: body) else {
            return nil
        }
        ingest(message.asStudioChatMessage() ?? ChatMessage(platform: .backstage, author: message.senderName, text: message.messageText))
        return message
    }

    func ingest(_ message: ChatMessage) {
        inbox.insert(message, at: 0)
        if inbox.count > 200 {
            inbox = Array(inbox.prefix(200))
        }
    }

    @discardableResult
    func pushOverlay(id: UUID) -> ChatOverlayCard? {
        guard let message = inbox.first(where: { $0.id == id }) else { return nil }
        overlay = ChatOverlayCard(message: message, visible: true)
        return overlay
    }

    @discardableResult
    func pushOverlay(_ message: ChatMessage) -> ChatOverlayCard {
        ingest(message)
        let card = ChatOverlayCard(message: message, visible: true)
        overlay = card
        return card
    }

    func dismissOverlay() {
        overlay?.visible = false
        overlay = nil
    }
}
