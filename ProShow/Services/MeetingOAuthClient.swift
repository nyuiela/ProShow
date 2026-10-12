import Foundation
#if os(macOS)
import AppKit
#endif

enum MeetingOAuthClient {
    static func zoomClientID() -> String? {
        ProcessInfo.processInfo.environment["PROSHOW_ZOOM_CLIENT_ID"]
    }

    static func zoomClientSecret() -> String? {
        ProcessInfo.processInfo.environment["PROSHOW_ZOOM_CLIENT_SECRET"]
    }

    static func googleClientID() -> String? {
        ProcessInfo.processInfo.environment["PROSHOW_GOOGLE_CLIENT_ID"]
    }

    static func googleClientSecret() -> String? {
        ProcessInfo.processInfo.environment["PROSHOW_GOOGLE_CLIENT_SECRET"]
    }

    static func zoomRedirect() -> URL {
        URL(string: ProcessInfo.processInfo.environment["PROSHOW_ZOOM_REDIRECT"] ?? "http://127.0.0.1:8765/zoom/callback")!
    }

    static func googleRedirect() -> URL {
        URL(string: ProcessInfo.processInfo.environment["PROSHOW_GOOGLE_REDIRECT"] ?? "http://127.0.0.1:8765/google/callback")!
    }

    static func authorizeZoom(state: String, verifier: String) -> URL? {
        guard let clientID = zoomClientID() else { return nil }
        var components = URLComponents(string: "https://zoom.us/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: zoomRedirect().absoluteString),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url
    }

    static func authorizeGoogle(state: String) -> URL? {
        guard let clientID = googleClientID() else { return nil }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: googleRedirect().absoluteString),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/calendar.events"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url
    }

    static func exchangeGoogleCode(_ code: String) async throws -> String {
        guard let clientID = googleClientID(), let secret = googleClientSecret() else {
            throw MeetingBridgeError.missingCredentials("Google client credentials missing.")
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(googleRedirect().absoluteString)&client_id=\(clientID)&client_secret=\(secret)"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else {
            throw MeetingBridgeError.providerUnavailable(.googleMeet)
        }
        return token
    }

    static func exchangeZoomCode(_ code: String) async throws -> String {
        guard let clientID = zoomClientID(), let secret = zoomClientSecret() else {
            throw MeetingBridgeError.missingCredentials("Zoom client credentials missing.")
        }
        var request = URLRequest(url: URL(string: "https://zoom.us/oauth/token")!)
        request.httpMethod = "POST"
        let body = "grant_type=authorization_code&code=\(code)&redirect_uri=\(zoomRedirect().absoluteString)"
        request.httpBody = body.data(using: .utf8)
        let auth = Data("\(clientID):\(secret)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = json?["access_token"] as? String else {
            throw MeetingBridgeError.providerUnavailable(.zoom)
        }
        return token
    }

    static func createZoomMeeting(accessToken: String, title: String) async throws -> MeetingSessionConfig {
        var request = URLRequest(url: URL(string: "https://api.zoom.us/v2/users/me/meetings")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "topic": title,
            "type": 1,
            "settings": ["join_before_host": true],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let join = json?["join_url"] as? String else {
            throw MeetingBridgeError.providerUnavailable(.zoom)
        }
        return MeetingSessionConfig(
            meetingProvider: .zoom,
            meetingId: String(describing: json?["id"] ?? ""),
            joinUrl: join,
            passcode: json?["password"] as? String ?? "",
            isVirtualCameraActive: true,
            isVirtualAudioActive: true
        )
    }

    static func createGoogleMeet(accessToken: String, title: String) async throws -> MeetingSessionConfig {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "summary": title,
            "start": ["dateTime": ISO8601DateFormatter().string(from: Date())],
            "end": ["dateTime": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))],
            "conferenceData": [
                "createRequest": [
                    "requestId": UUID().uuidString,
                    "conferenceSolutionKey": ["type": "hangoutsMeet"],
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hangout = (json?["hangoutLink"] as? String)
            ?? ((json?["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]])?.first?["uri"] as? String
        guard let join = hangout else {
            throw MeetingBridgeError.providerUnavailable(.googleMeet)
        }
        return MeetingSessionConfig(
            meetingProvider: .googleMeet,
            meetingId: json?["id"] as? String ?? "",
            joinUrl: join,
            passcode: "",
            isVirtualCameraActive: true,
            isVirtualAudioActive: true
        )
    }

    #if os(macOS)
    static func openBrowser(_ url: URL) throws {
        if !NSWorkspace.shared.open(url) {
            throw StreamOAuthError.invalidCallback
        }
    }
    #endif
}
