import Foundation

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
