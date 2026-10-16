import Foundation
import Observation

/// WebRTC / Rendezvous green room: invite links, ISO guest feeds, intercom, mix-minus return.
@MainActor
@Observable
final class ProShowBackstageEngine {
    var room: BackstageRoomConfig
    var guests: [RemoteGuestNode] = []
    var intercomActive = false
    var returnFeedMode: BackstageReturnFeedMode = .programMixMinus
    var lastError: String?

    init(room: BackstageRoomConfig? = nil) {
        if let room {
            self.room = room
        } else if let saved = UserDefaults.standard.string(forKey: Self.slugDefaultsKey),
                  saved.hasPrefix("pso-"), saved.count <= 16 {
            self.room = BackstageRoomConfig(roomSlug: saved)
        } else {
            let slug = Self.makeRoomSlug()
            UserDefaults.standard.set(slug, forKey: Self.slugDefaultsKey)
            self.room = BackstageRoomConfig(roomSlug: slug)
        }
    }

    var inviteURLString: String {
        room.inviteURL?.absoluteString ?? "\(room.inviteBaseURL)\(room.roomSlug)"
    }

    var activeGuestCount: Int {
        guests.filter { $0.profile.connectionStatus != .disconnected }.count
    }

    func rotateRoom() {
        room.roomSlug = Self.makeRoomSlug()
        UserDefaults.standard.set(room.roomSlug, forKey: Self.slugDefaultsKey)
        if let projectKey { UserDefaults.standard.removeObject(forKey: Self.projectRoomKey(projectKey)) }
    }

    // MARK: Per-project room name (custom invite slug, e.g. "stellar14")

    /// Project whose room-name override is active (set when a project opens).
    private(set) var projectKey: String?
    /// The custom room name for the open project, or nil when using the generated pso-#### room.
    var customRoomName: String? {
        guard let projectKey else { return nil }
        return UserDefaults.standard.string(forKey: Self.projectRoomKey(projectKey))
    }

    /// Lowercase letters, digits and dashes, 3–40 chars, starting with a letter or digit.
    /// Subset of the showroom token route's room regex `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`.
    static func normalizedRoomName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.range(of: "^[a-z0-9][a-z0-9-]{2,39}$", options: .regularExpression) != nil else { return nil }
        return name
    }

    /// Applies the open project's override (if any); otherwise keeps the generated room.
    func applyProject(key: String) {
        projectKey = key
        if let name = customRoomName, let valid = Self.normalizedRoomName(name) {
            room.roomSlug = valid
        } else if !room.roomSlug.hasPrefix("pso-") {
            room.roomSlug = Self.generatedSlug()
        }
    }

    /// Sets (or clears, with nil/empty) the open project's room name. Returns false when invalid.
    @discardableResult
    func setCustomRoomName(_ raw: String?) -> Bool {
        guard let projectKey else { return false }
        let key = Self.projectRoomKey(projectKey)
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            UserDefaults.standard.removeObject(forKey: key)
            room.roomSlug = Self.generatedSlug()
            return true
        }
        guard let name = Self.normalizedRoomName(raw) else { return false }
        UserDefaults.standard.set(name, forKey: key)
        room.roomSlug = name
        return true
    }

    private static func projectRoomKey(_ project: String) -> String { "proshow.backstage.roomName.\(project)" }

    private static func generatedSlug() -> String {
        if let saved = UserDefaults.standard.string(forKey: slugDefaultsKey), saved.hasPrefix("pso-"), saved.count <= 16 {
            return saved
        }
        let slug = makeRoomSlug()
        UserDefaults.standard.set(slug, forKey: slugDefaultsKey)
        return slug
    }

    @discardableResult
    func connectSignaledGuest(
        id: UUID,
        displayName: String,
        roleOrTitle: String? = nil,
        cameraEndpoint: String
    ) -> RemoteGuestNode {
        if let index = guests.firstIndex(where: { $0.id == id || $0.profile.id == id }) {
            guests[index].id = id
            guests[index].profile.id = id
            if guests[index].profile.connectionStatus != .liveOnAir {
                guests[index].profile.connectionStatus = .inGreenRoom
            }
            guests[index].cameraEndpoint = cameraEndpoint
            guests[index].profile.displayName = displayName
            guests[index].profile.roleOrTitle = roleOrTitle
            return guests[index]
        }
        let profile = RemoteGuestProfile(
            id: id,
            displayName: displayName,
            roleOrTitle: roleOrTitle,
            connectionStatus: .inGreenRoom,
            videoLabel: "720p30 WebRTC"
        )
        let node = RemoteGuestNode(id: id, profile: profile, cameraEndpoint: cameraEndpoint, joinedAt: Date())
        guests.append(node)
        lastError = nil
        return node
    }

    @discardableResult
    func admitGuest(displayName: String, roleOrTitle: String? = nil) -> RemoteGuestNode? {
        guard activeGuestCount < room.maxGuests else {
            lastError = "Guest limit (\(room.maxGuests)) reached."
            return nil
        }
        let endpoint = "webrtc://guest/\(UUID().uuidString.lowercased())"
        let profile = RemoteGuestProfile(
            displayName: displayName,
            roleOrTitle: roleOrTitle,
            connectionStatus: .inGreenRoom,
            videoLabel: "720p30 WebRTC"
        )
        let node = RemoteGuestNode(
            profile: profile,
            cameraEndpoint: endpoint,
            joinedAt: Date()
        )
        guests.append(node)
        lastError = nil
        return node
    }

    func setGuestOnAir(id: UUID, onAir: Bool) {
        guard let index = guestIndex(id) else { return }
        guests[index].profile.connectionStatus = onAir ? .liveOnAir : .inGreenRoom
    }

    func setGuestMuted(id: UUID, muted: Bool) {
        guard let index = guestIndex(id) else { return }
        guests[index].profile.isAudioMuted = muted
    }

    func setGuestVideoDisabled(id: UUID, disabled: Bool) {
        guard let index = guestIndex(id) else { return }
        guests[index].profile.isVideoDisabled = disabled
    }

    private func guestIndex(_ id: UUID) -> Int? {
        guests.firstIndex(where: { $0.id == id || $0.profile.id == id })
    }

    func attachScreenShare(guestID: UUID, label: String) {
        guard let index = guests.firstIndex(where: { $0.id == guestID }) else { return }
        guests[index].profile.hasActiveScreenShare = true
        guests[index].screenShareEndpoint = "webrtc://screen/\(guestID.uuidString.lowercased())"
        guests[index].profile.videoLabel = label
    }

    func disconnectGuest(id: UUID) {
        guard let index = guests.firstIndex(where: { $0.id == id }) else { return }
        guests[index].profile.connectionStatus = .disconnected
    }

    func removeGuest(id: UUID) {
        guests.removeAll { $0.id == id }
    }

    /// Registers guest camera/screen as assignable video inputs for canvas + node graph.
    func videoSourcesForGraph() -> [(label: String, endpoint: String, guestID: UUID, kind: BackstageMediaKind)] {
        guests.flatMap { guest -> [(String, String, UUID, BackstageMediaKind)] in
            guard guest.profile.connectionStatus != .disconnected else { return [] }
            var rows: [(String, String, UUID, BackstageMediaKind)] = [
                ("\(guest.profile.displayName) Cam", guest.cameraEndpoint, guest.id, .camera),
            ]
            if guest.profile.hasActiveScreenShare, let screen = guest.screenShareEndpoint {
                rows.append(("\(guest.profile.displayName) Screen", screen, guest.id, .screenShare))
            }
            return rows
        }
    }

    private static let slugDefaultsKey = "proshow.backstage.roomSlug"

    private static func makeRoomSlug() -> String {
        "pso-\(Int.random(in: 1000...9999))"
    }
}

enum BackstageReturnFeedMode: String, Codable, Sendable, CaseIterable {
    case programMixMinus = "Program (Mix-Minus)"
    case programFull = "Full Program"
    case intercomOnly = "Intercom Only"

    /// Compact labels for the narrow action-inspector column.
    var pickerShortLabel: String {
        switch self {
        case .programMixMinus: "Mix−"
        case .programFull: "Full"
        case .intercomOnly: "Intercom"
        }
    }
}
