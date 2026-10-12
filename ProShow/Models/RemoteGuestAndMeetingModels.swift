import Foundation

public enum GuestConnectionStatus: String, Codable, Sendable, CaseIterable {
    case inviting = "Inviting"
    case inGreenRoom = "Backstage (Green Room)"
    case liveOnAir = "Live On Air"
    case disconnected = "Disconnected"

    /// Glance label. Raw values stay stable for saved rooms.
    public var displayTitle: String {
        switch self {
        case .inviting: ProShowCopy.Status.connecting
        case .inGreenRoom: ProShowCopy.Status.ready
        case .liveOnAir: ProShowCopy.Status.live
        case .disconnected: ProShowCopy.Status.offline
        }
    }

    public var accessibilityTitle: String {
        switch self {
        case .inviting: "Connecting to the room"
        case .inGreenRoom: "Ready in backstage"
        case .liveOnAir: "Live on program"
        case .disconnected: "Offline"
        }
    }
}

public enum MeetingProvider: String, Codable, Sendable, CaseIterable {
    case proShowDirect = "ProShow Direct"
    case zoom = "Zoom"
    case googleMeet = "Google Meet"
}

public enum BackstageMediaKind: String, Codable, Sendable {
    case camera
    case screenShare
    case microphone
}

public struct RemoteGuestProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var displayName: String
    public var roleOrTitle: String?
    public var connectionStatus: GuestConnectionStatus
    public var isAudioMuted: Bool
    public var isVideoDisabled: Bool
    public var hasActiveScreenShare: Bool
    public var streamLatencyMs: Int
    public var videoLabel: String
    public var audioLevelDb: Double

    public init(
        id: UUID = UUID(),
        displayName: String,
        roleOrTitle: String? = nil,
        connectionStatus: GuestConnectionStatus = .inviting,
        isAudioMuted: Bool = false,
        isVideoDisabled: Bool = false,
        hasActiveScreenShare: Bool = false,
        streamLatencyMs: Int = 0,
        videoLabel: String = "—",
        audioLevelDb: Double = -60
    ) {
        self.id = id
        self.displayName = displayName
        self.roleOrTitle = roleOrTitle
        self.connectionStatus = connectionStatus
        self.isAudioMuted = isAudioMuted
        self.isVideoDisabled = isVideoDisabled
        self.hasActiveScreenShare = hasActiveScreenShare
        self.streamLatencyMs = streamLatencyMs
        self.videoLabel = videoLabel
        self.audioLevelDb = audioLevelDb
    }
}

/// ISO A/V endpoints for one browser or SDK participant (maps to `VideoInputSource` / matrix rows).
public struct RemoteGuestNode: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var profile: RemoteGuestProfile
    public var cameraEndpoint: String
    public var screenShareEndpoint: String?
    public var videoInputID: UUID?
    public var screenShareInputID: UUID?
    public var joinedAt: Date?

    public init(
        id: UUID = UUID(),
        profile: RemoteGuestProfile,
        cameraEndpoint: String,
        screenShareEndpoint: String? = nil,
        videoInputID: UUID? = nil,
        screenShareInputID: UUID? = nil,
        joinedAt: Date? = nil
    ) {
        self.id = id
        self.profile = profile
        self.cameraEndpoint = cameraEndpoint
        self.screenShareEndpoint = screenShareEndpoint
        self.videoInputID = videoInputID
        self.screenShareInputID = screenShareInputID
        self.joinedAt = joinedAt
    }
}

public struct LiveChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var senderName: String
    public var senderAvatarUrl: String?
    public var platformSource: String
    public var messageText: String
    public var timestamp: Date
    public var isStarred: Bool
    public var isFeaturedOnScreen: Bool

    public init(
        id: String = UUID().uuidString,
        senderName: String,
        senderAvatarUrl: String? = nil,
        platformSource: String,
        messageText: String,
        timestamp: Date = Date(),
        isStarred: Bool = false,
        isFeaturedOnScreen: Bool = false
    ) {
        self.id = id
        self.senderName = senderName
        self.senderAvatarUrl = senderAvatarUrl
        self.platformSource = platformSource
        self.messageText = messageText
        self.timestamp = timestamp
        self.isStarred = isStarred
        self.isFeaturedOnScreen = isFeaturedOnScreen
    }

    func asStudioChatMessage() -> ChatMessage? {
        let platform = ChatPlatform.from(displayName: platformSource)
        return ChatMessage(platform: platform, author: senderName, text: messageText)
    }
}

public struct MeetingSessionConfig: Codable, Equatable, Sendable {
    public var meetingProvider: MeetingProvider
    public var meetingId: String
    public var joinUrl: String
    public var passcode: String
    public var isVirtualCameraActive: Bool
    public var isVirtualAudioActive: Bool

    public init(
        meetingProvider: MeetingProvider = .proShowDirect,
        meetingId: String = "",
        joinUrl: String = "",
        passcode: String = "",
        isVirtualCameraActive: Bool = true,
        isVirtualAudioActive: Bool = true
    ) {
        self.meetingProvider = meetingProvider
        self.meetingId = meetingId
        self.joinUrl = joinUrl
        self.passcode = passcode
        self.isVirtualCameraActive = isVirtualCameraActive
        self.isVirtualAudioActive = isVirtualAudioActive
    }
}

public struct BackstageRoomConfig: Codable, Equatable, Sendable {
    public var roomSlug: String
    public var inviteBaseURL: String
    public var maxGuests: Int
    public var mixMinusEnabled: Bool
    public var intercomEnabled: Bool

    public static var defaultInviteBaseURL: String {
        if let custom = ProcessInfo.processInfo.environment["PROSHOW_CALL_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom.hasSuffix("/") ? custom : "\(custom)/"
        }
        return "https://room.xfoundrylab.com/j/"
    }

    public init(
        roomSlug: String,
        inviteBaseURL: String = BackstageRoomConfig.defaultInviteBaseURL,
        maxGuests: Int = 8,
        mixMinusEnabled: Bool = true,
        intercomEnabled: Bool = true
    ) {
        self.roomSlug = roomSlug
        self.inviteBaseURL = inviteBaseURL
        self.maxGuests = maxGuests
        self.mixMinusEnabled = mixMinusEnabled
        self.intercomEnabled = intercomEnabled
    }

    public var inviteURL: URL? {
        URL(string: inviteBaseURL + roomSlug)
    }
}

extension ChatPlatform {
    static func from(displayName: String) -> ChatPlatform {
        let lower = displayName.lowercased()
        if lower.contains("zoom") { return .zoom }
        if lower.contains("meet") { return .googleMeet }
        if lower.contains("backstage") { return .backstage }
        if lower.contains("youtube") { return .youtube }
        if lower.contains("facebook") { return .facebook }
        if lower == "x" || lower.contains("twitter") { return .x }
        if lower.contains("twitch") { return .twitch }
        return .backstage
    }

    var displayTitle: String {
        switch self {
        case .youtube: "YouTube"
        case .twitch: "Twitch"
        case .facebook: "Facebook"
        case .x: "X"
        case .zoom: "Zoom"
        case .googleMeet: "Google Meet"
        case .backstage: "Backstage"
        }
    }
}
