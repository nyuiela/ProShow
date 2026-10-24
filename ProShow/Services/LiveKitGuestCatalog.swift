import Foundation
import Observation

struct LiveKitGuestFeed: Identifiable, Equatable, Sendable {
    var identity: String
    var name: String
    var hasCamera: Bool
    var hasScreen: Bool
    var hasMic: Bool

    var id: String { identity }
}

enum LiveKitGuestEndpoint {
    static func camera(room: String, identity: String) -> String {
        "livekit://\(room)/\(identity)/camera"
    }

    static func screen(room: String, identity: String) -> String {
        "livekit://\(room)/\(identity)/screen"
    }

    static func identity(from endpoint: String?) -> String? {
        guard let endpoint, endpoint.hasPrefix("livekit://") else { return nil }
        let parts = endpoint.dropFirst("livekit://".count).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[1]
    }

    static func stableID(_ identity: String) -> UUID {
        if let parsed = UUID(uuidString: identity) { return parsed }
        return HardwareSourceIdentity.uuid(for: "livekit-guest:\(identity)")
    }
}

enum LiveKitGuestCatalog {
    static func items(room: String, guests: [LiveKitGuestFeed]) -> [DiscoveredSourceItem] {
        guests.flatMap { guest -> [DiscoveredSourceItem] in
            let display = guest.name.isEmpty ? guest.identity : guest.name
            var rows = [
                DiscoveredSourceItem(
                    id: "livekit-\(guest.identity)-camera",
                    name: "\(display) Cam",
                    category: .network,
                    groupName: "Live Guests",
                    sourceType: .rendezvousGuest,
                    connectionString: LiveKitGuestEndpoint.camera(room: room, identity: guest.identity),
                    isConnected: true
                ),
            ]
            if guest.hasScreen {
                rows.append(
                    DiscoveredSourceItem(
                        id: "livekit-\(guest.identity)-screen",
                        name: "\(display) Screen",
                        category: .network,
                        groupName: "Live Guests",
                        sourceType: .rendezvousGuest,
                        connectionString: LiveKitGuestEndpoint.screen(room: room, identity: guest.identity),
                        isConnected: true
                    )
                )
            }
            return rows
        }
    }
}

#if canImport(AppKit)
import AppKit
#endif

/// Guest profile from showroom participant metadata/attributes (`name`, `ps.title`, `ps.avatar`, metadata JSON).
struct GuestProfile: Equatable {
    var name: String
    var title: String
    /// Data URL (uploaded photo) or DiceBear URL.
    var avatarSource: String
    /// True while a camera track is published and unmuted.
    var cameraLive: Bool
}

/// Desk-wide guest profiles keyed by LiveKit identity. Drives the camera-off nameplate card.
@MainActor
@Observable
final class GuestProfileStore {
    static let shared = GuestProfileStore()
    private(set) var profiles: [String: GuestProfile] = [:]
    #if canImport(AppKit)
    @ObservationIgnored private var imageCache: [String: NSImage] = [:]
    private(set) var imageRevision = 0
    #endif

    func profile(identity: String) -> GuestProfile? { profiles[identity] }

    func replaceAll(_ next: [String: GuestProfile]) {
        guard next != profiles else { return }
        profiles = next
        #if canImport(AppKit)
        for profile in next.values { loadAvatar(profile.avatarSource) }
        #endif
    }

    /// Parses showroom metadata (`{"v":1,"name","title","avatar"}`) with attribute fallbacks.
    static func make(name: String, metadata: String?, attributes: [String: String], cameraLive: Bool) -> GuestProfile {
        var title = attributes["ps.title"] ?? ""
        var avatar = attributes["ps.avatar"] ?? ""
        var display = name
        if let metadata, let data = metadata.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let t = json["title"] as? String, !t.isEmpty { title = t }
            if let a = json["avatar"] as? String, !a.isEmpty { avatar = a }
            if display.isEmpty, let n = json["name"] as? String { display = n }
        }
        if avatar.isEmpty {
            let seed = display.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "guest"
            avatar = "https://api.dicebear.com/9.x/personas/png?seed=\(seed)"
        }
        return GuestProfile(name: display, title: String(title.prefix(48)), avatarSource: avatar, cameraLive: cameraLive)
    }

    #if canImport(AppKit)
    func avatarImage(for source: String) -> NSImage? {
        _ = imageRevision
        return imageCache[source]
    }

    private func loadAvatar(_ source: String) {
        guard imageCache[source] == nil, !source.isEmpty else { return }
        if source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ",") {
            let b64 = String(source[source.index(after: comma)...])
            if let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
                imageCache[source] = image
                imageRevision &+= 1
            }
            return
        }
        // Only DiceBear over HTTPS; ask for PNG (SVG decoding in NSImage is unreliable).
        guard source.hasPrefix("https://api.dicebear.com/") else { return }
        let png = source.replacingOccurrences(of: "/svg?", with: "/png?")
        guard let url = URL(string: png) else { return }
        imageCache[source] = NSImage(size: .zero) // in flight; prevents duplicate fetches
        Task.detached(priority: .utility) {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            await MainActor.run {
                GuestProfileStore.shared.imageCache[source] = image
                GuestProfileStore.shared.imageRevision &+= 1
            }
        }
    }
    #endif
}
