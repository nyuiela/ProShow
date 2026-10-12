import CryptoKit
import Foundation

/// LiveKit room JWT (HS256). The API secret never leaves the desk.
enum LiveKitAccessToken {
    static func jwt(
        apiKey: String,
        apiSecret: String,
        identity: String,
        name: String,
        room: String,
        roomAdmin: Bool = false,
        canPublish: Bool = true,
        canSubscribe: Bool = true,
        canPublishData: Bool = true,
        canUpdateOwnMetadata: Bool = false,
        attributes: [String: String] = [:],
        ttl: TimeInterval = 6 * 60 * 60,
        now: Date = Date()
    ) -> String {
        let header = base64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let issued = Int(now.timeIntervalSince1970)
        var video: [String: Any] = [
            "canPublish": canPublish,
            "canPublishData": canPublishData,
            "canSubscribe": canSubscribe,
            "room": room,
            "roomJoin": true,
        ]
        if roomAdmin {
            video["roomAdmin"] = true
        }
        if canUpdateOwnMetadata {
            video["canUpdateOwnMetadata"] = true
        }
        var payload: [String: Any] = [
            "exp": issued + Int(ttl),
            "iss": apiKey,
            "name": name,
            "nbf": issued,
            "sub": identity,
            "video": video,
        ]
        if !attributes.isEmpty {
            payload["attributes"] = attributes
        }
        let bodyData = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        let body = base64url(bodyData)
        let signingInput = Data("\(header).\(body)".utf8)
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: signingInput, using: key)
        return "\(header).\(body).\(base64url(Data(digest)))"
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func payloadJSON(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var raw = String(parts[1])
        raw = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let pad = (4 - raw.count % 4) % 4
        raw += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
