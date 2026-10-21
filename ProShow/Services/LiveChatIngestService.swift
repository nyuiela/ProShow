import Foundation

/// Normalizes Zoom / Meet / YouTube / Twitch webhook payloads into `LiveChatMessage`.
enum LiveChatIngestService {
    static func parseWebhook(platform: String, body: Data) -> LiveChatMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        switch platform.lowercased() {
        case "zoom":
            return parseZoom(object)
        case "meet", "google_meet", "googlemeet":
            return parseGoogleMeet(object)
        case "youtube":
            return parseYouTube(object)
        case "twitch":
            return parseTwitch(object)
        default:
            return parseGeneric(object, platform: platform)
        }
    }

    static func parseGeneric(_ object: [String: Any], platform: String) -> LiveChatMessage? {
        let author = (object["author"] as? String)
            ?? (object["user_name"] as? String)
            ?? (object["sender"] as? String)
            ?? "Guest"
        let text = (object["text"] as? String)
            ?? (object["message"] as? String)
            ?? (object["body"] as? String)
        guard let text, !text.isEmpty else { return nil }
        let id = (object["id"] as? String) ?? UUID().uuidString
        return LiveChatMessage(
            id: id,
            senderName: author,
            platformSource: platform,
            messageText: text
        )
    }

    private static func parseZoom(_ object: [String: Any]) -> LiveChatMessage? {
        let payload = object["payload"] as? [String: Any] ?? object
        let author = (payload["sender_name"] as? String) ?? (payload["user_name"] as? String) ?? "Zoom Guest"
        let text = (payload["message"] as? String) ?? (payload["content"] as? String)
        guard let text, !text.isEmpty else { return nil }
        return LiveChatMessage(
            id: (payload["id"] as? String) ?? UUID().uuidString,
            senderName: author,
            platformSource: "Zoom",
            messageText: text
        )
    }

    private static func parseGoogleMeet(_ object: [String: Any]) -> LiveChatMessage? {
        let author = (object["displayName"] as? String) ?? (object["sender"] as? String) ?? "Meet Guest"
        let text = (object["text"] as? String) ?? (object["message"] as? String)
        guard let text, !text.isEmpty else { return nil }
        return LiveChatMessage(
            senderName: author,
            platformSource: "Google Meet",
            messageText: text
        )
    }

    private static func parseYouTube(_ object: [String: Any]) -> LiveChatMessage? {
        let snippet = object["snippet"] as? [String: Any]
        let authorDetails = snippet?["authorDetails"] as? [String: Any]
        let name = (authorDetails?["displayName"] as? String) ?? (object["author"] as? String) ?? "YouTube"
        let text = (snippet?["displayMessage"] as? String) ?? (object["text"] as? String)
        guard let text, !text.isEmpty else { return nil }
        let avatar = (authorDetails?["profileImageUrl"] as? String) ?? (object["avatar"] as? String)
        return LiveChatMessage(
            id: (object["id"] as? String) ?? UUID().uuidString,
            senderName: name,
            senderAvatarUrl: avatar,
            platformSource: "YouTube",
            messageText: text
        )
    }

    private static func parseTwitch(_ object: [String: Any]) -> LiveChatMessage? {
        let author = (object["from_name"] as? String) ?? (object["user_name"] as? String) ?? "Twitch"
        let text = (object["message"] as? String) ?? (object["text"] as? String)
        guard let text, !text.isEmpty else { return nil }
        return LiveChatMessage(
            senderName: author,
            platformSource: "Twitch",
            messageText: text
        )
    }
}
