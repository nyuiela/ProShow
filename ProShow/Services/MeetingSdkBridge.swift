import Foundation
import Observation

enum MeetingBridgeError: Error, LocalizedError {
    case missingCredentials(String)
    case providerUnavailable(MeetingProvider)

    var errorDescription: String? {
        switch self {
        case .missingCredentials(let detail): detail
        case .providerUnavailable(let provider): "\(provider.rawValue) integration is not configured."
        }
    }
}

/// Zoom REST + Google Calendar/Meet session creation (OAuth via existing `OAuthLoopbackServer`).
@MainActor
@Observable
final class MeetingSdkBridge {
    var activeSession: MeetingSessionConfig?
    var lastError: String?

    /// Creates a ProShow Direct backstage room (browser WebRTC). No external SDK required.
    func createProShowDirectSession(inviteURL: String) -> MeetingSessionConfig {
        let config = MeetingSessionConfig(
            meetingProvider: .proShowDirect,
            meetingId: "",
            joinUrl: inviteURL,
            passcode: "",
            isVirtualCameraActive: true,
            isVirtualAudioActive: true
        )
        activeSession = config
        lastError = nil
        return config
    }

    func createZoomMeeting(title: String) async throws -> MeetingSessionConfig {
        guard MeetingSdkBridge.zoomConfigured else {
            throw MeetingBridgeError.missingCredentials("Add Zoom OAuth client credentials in Settings → Integrations.")
        }
        let server = OAuthLoopbackServer(redirect: MeetingOAuthClient.zoomRedirect())
        try server.start()
        await server.waitUntilReady()
        defer { server.stop() }
        let state = StreamPKCE.makeVerifier()
        guard let url = MeetingOAuthClient.authorizeZoom(state: state, verifier: "") else {
            throw MeetingBridgeError.providerUnavailable(.zoom)
        }
        #if os(macOS)
        try MeetingOAuthClient.openBrowser(url)
        #endif
        let callback = try await server.waitForCallback()
        try StreamPKCE.validate(state: state, in: callback)
        let code = try StreamPKCE.authorizationCode(from: callback)
        let token = try await MeetingOAuthClient.exchangeZoomCode(code)
        let config = try await MeetingOAuthClient.createZoomMeeting(accessToken: token, title: title)
        activeSession = config
        lastError = nil
        return config
    }

    func createGoogleMeet(title: String) async throws -> MeetingSessionConfig {
        guard MeetingSdkBridge.googleConfigured else {
            throw MeetingBridgeError.missingCredentials("Connect Google Workspace in Settings → Integrations.")
        }
        let server = OAuthLoopbackServer(redirect: MeetingOAuthClient.googleRedirect())
        try server.start()
        await server.waitUntilReady()
        defer { server.stop() }
        let state = StreamPKCE.makeVerifier()
        guard let url = MeetingOAuthClient.authorizeGoogle(state: state) else {
            throw MeetingBridgeError.providerUnavailable(.googleMeet)
        }
        #if os(macOS)
        try MeetingOAuthClient.openBrowser(url)
        #endif
        let callback = try await server.waitForCallback()
        try StreamPKCE.validate(state: state, in: callback)
        let code = try StreamPKCE.authorizationCode(from: callback)
        let token = try await MeetingOAuthClient.exchangeGoogleCode(code)
        let config = try await MeetingOAuthClient.createGoogleMeet(accessToken: token, title: title)
        activeSession = config
        lastError = nil
        return config
    }

    static var zoomConfigured: Bool {
        MeetingOAuthClient.zoomClientID() != nil && MeetingOAuthClient.zoomClientSecret() != nil
    }

    static var googleConfigured: Bool {
        MeetingOAuthClient.googleClientID() != nil && MeetingOAuthClient.googleClientSecret() != nil
    }
}
