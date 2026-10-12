import Foundation
import Observation

enum BackstageSignalKind: String, Codable, Sendable {
    case join
    case offer
    case answer
    case ice
    case leave
    case mediaFrame
}

struct BackstageSignalMessage: Codable, Sendable, Equatable {
    var kind: BackstageSignalKind
    var roomSlug: String
    var guestID: String?
    var sdp: String?
    var candidate: String?
    var sdpMid: String?
    var sdpMLineIndex: Int?
    var displayName: String?
    var title: String?
    /// Base64 JPEG/PNG fallback when WebRTC binary is unavailable.
    var mediaPayload: String?
    var mediaMime: String?
    var timestamp: TimeInterval?

    static func decode(from data: Data) -> BackstageSignalMessage? {
        try? JSONDecoder().decode(BackstageSignalMessage.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

/// Room-scoped SDP / ICE relay for browser guests (`call.proshow.app` ↔ localhost control API).
@MainActor
@Observable
final class BackstageSignalingEngine {
    weak var ingest: BackstageWebRTCIngestEngine?

    private(set) var connectedGuests: Set<String> = []
    var lastSignalError: String?

    func handleREST(_ body: Data?, roomSlug: String) -> (Int, String) {
        guard let body, let message = BackstageSignalMessage.decode(from: body) else {
            return (400, #"{"ok":false,"error":"invalid_signal"}"#)
        }
        guard message.roomSlug == roomSlug else {
            return (403, #"{"ok":false,"error":"room_mismatch"}"#)
        }
        return (200, handle(message))
    }

    func handleWebSocketText(_ text: String, roomSlug: String) -> String? {
        guard let data = text.data(using: .utf8),
              var message = BackstageSignalMessage.decode(from: data)
        else {
            lastSignalError = "invalid_signal"
            return #"{"ok":false,"error":"invalid_signal"}"#
        }
        message.roomSlug = roomSlug
        return handle(message)
    }

    @discardableResult
    func handle(_ message: BackstageSignalMessage) -> String {
        switch message.kind {
        case .join:
            if let guestID = message.guestID {
                connectedGuests.insert(guestID)
                ingest?.registerGuest(
                    id: guestID,
                    displayName: message.displayName ?? "Guest",
                    roleOrTitle: message.title,
                    endpoint: "webrtc://guest/\(guestID)"
                )
            }
            return ControlJSON.encode(["ok": true, "action": "join", "guests": connectedGuests.count])
        case .offer, .answer, .ice:
            ingest?.applySignal(message)
            return ControlJSON.encode(["ok": true, "action": message.kind.rawValue])
        case .mediaFrame:
            ingest?.applyMediaFrame(message)
            return ControlJSON.encode(["ok": true, "action": "media_frame"])
        case .leave:
            if let guestID = message.guestID {
                connectedGuests.remove(guestID)
                ingest?.disconnectGuest(id: guestID)
            }
            return ControlJSON.encode(["ok": true, "action": "leave"])
        }
    }
}
