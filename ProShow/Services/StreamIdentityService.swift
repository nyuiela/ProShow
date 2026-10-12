import Foundation

struct StreamIdentity: Equatable, Sendable {
    var displayName: String
    var channelOrPageId: String
    var profileImageUrl: String?
}

/// Reads channel / page / handle after OAuth. Tokens stay in Keychain.
enum StreamIdentityService {
    static func fetch(
        platform: StreamPlatform,
        token: String,
        transport: any LiveAPITransport = URLSessionLiveTransport()
    ) async throws -> StreamIdentity {
        switch platform {
        case .youtube:
            let object = try await getJSON(
                URL(string: "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true")!,
                token: token,
                transport: transport
            )
            guard let identity = parseYouTube(object) else { throw PlatformLiveError.missingIngest }
            return identity
        case .twitter:
            let object = try await getJSON(
                URL(string: "https://api.x.com/2/users/me?user.fields=profile_image_url,name,username")!,
                token: token,
                transport: transport
            )
            guard let identity = parseX(object) else { throw PlatformLiveError.missingIngest }
            return identity
        case .linkedin:
            let profile = try await getJSON(
                URL(string: "https://api.linkedin.com/v2/userinfo")!,
                token: token,
                transport: transport
            )
            var identity = parseLinkedInUserInfo(profile)
            if let orgs = try? await getJSON(
                URL(string: "https://api.linkedin.com/v2/organizationAcls?q=roleAssignee&role=ADMINISTRATOR&projection=(elements*(organization~(id,localizedName)))")!,
                token: token,
                transport: transport
            ), let org = parseLinkedInOrganization(orgs) {
                identity.channelOrPageId = org.channelOrPageId
                if !org.displayName.isEmpty {
                    identity.displayName = org.displayName
                }
            }
            guard !identity.displayName.isEmpty || !identity.channelOrPageId.isEmpty else {
                throw PlatformLiveError.missingIngest
            }
            return identity
        case .facebook:
            let me = try await getJSON(
                URL(string: "https://graph.facebook.com/v19.0/me?fields=id,name,picture.type(large)")!,
                token: token,
                transport: transport
            )
            let pages = try? await getJSON(
                URL(string: "https://graph.facebook.com/v19.0/me/accounts?fields=id,name")!,
                token: token,
                transport: transport
            )
            guard let identity = parseFacebook(me: me, pages: pages) else { throw PlatformLiveError.missingIngest }
            return identity
        case .customRtmp, .srt:
            throw PlatformLiveError.unsupportedPlatform
        }
    }

    static func parseYouTube(_ object: [String: Any]) -> StreamIdentity? {
        guard let item = (object["items"] as? [[String: Any]])?.first else { return nil }
        let snippet = item["snippet"] as? [String: Any] ?? [:]
        let thumbs = snippet["thumbnails"] as? [String: Any]
        let image = (thumbs?["default"] as? [String: Any])?["url"] as? String
            ?? (thumbs?["medium"] as? [String: Any])?["url"] as? String
        let title = (snippet["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = (item["id"] as? String) ?? ""
        guard !title.isEmpty || !id.isEmpty else { return nil }
        return StreamIdentity(
            displayName: title.isEmpty ? id : title,
            channelOrPageId: id,
            profileImageUrl: image
        )
    }

    static func parseX(_ object: [String: Any]) -> StreamIdentity? {
        let data = object["data"] as? [String: Any] ?? object
        let username = (data["username"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = (data["id"] as? String) ?? username
        let display = name.isEmpty ? (username.isEmpty ? id : "@\(username)") : name
        guard !display.isEmpty else { return nil }
        return StreamIdentity(
            displayName: display,
            channelOrPageId: id,
            profileImageUrl: data["profile_image_url"] as? String
        )
    }

    static func parseLinkedInUserInfo(_ object: [String: Any]) -> StreamIdentity {
        let name = (object["name"] as? String)
            ?? [object["given_name"] as? String, object["family_name"] as? String]
                .compactMap { $0 }
                .joined(separator: " ")
        return StreamIdentity(
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            channelOrPageId: (object["sub"] as? String) ?? "",
            profileImageUrl: object["picture"] as? String
        )
    }

    static func parseLinkedInOrganization(_ object: [String: Any]) -> StreamIdentity? {
        guard let elements = object["elements"] as? [[String: Any]] else { return nil }
        for element in elements {
            if let org = element["organization~"] as? [String: Any] {
                let id = (org["id"] as? String) ?? ""
                let name = (org["localizedName"] as? String) ?? ""
                if !id.isEmpty || !name.isEmpty {
                    return StreamIdentity(displayName: name, channelOrPageId: id, profileImageUrl: nil)
                }
            }
        }
        return nil
    }

    static func parseFacebook(me: [String: Any], pages: [String: Any]?) -> StreamIdentity? {
        if let first = (pages?["data"] as? [[String: Any]])?.first {
            let name = (first["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let id = (first["id"] as? String) ?? ""
            if !name.isEmpty || !id.isEmpty {
                return StreamIdentity(displayName: name.isEmpty ? id : name, channelOrPageId: id, profileImageUrl: pictureURL(in: me))
            }
        }
        let name = (me["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let id = (me["id"] as? String) ?? ""
        guard !name.isEmpty || !id.isEmpty else { return nil }
        return StreamIdentity(displayName: name.isEmpty ? id : name, channelOrPageId: id, profileImageUrl: pictureURL(in: me))
    }

    private static func pictureURL(in object: [String: Any]) -> String? {
        ((object["picture"] as? [String: Any])?["data"] as? [String: Any])?["url"] as? String
            ?? object["picture"] as? String
    }

    private static func getJSON(
        _ url: URL,
        token: String,
        transport: any LiveAPITransport
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if url.host?.contains("linkedin.com") == true {
            request.setValue("202401", forHTTPHeaderField: "LinkedIn-Version")
            request.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        }
        let (data, response) = try await transport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PlatformLiveError.httpStatus(http.statusCode)
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

extension StreamAccount {
    mutating func apply(_ identity: StreamIdentity) {
        if !identity.displayName.isEmpty {
            accountName = identity.displayName
        }
        if !identity.channelOrPageId.isEmpty {
            channelOrPageId = identity.channelOrPageId
        }
        if let image = identity.profileImageUrl, !image.isEmpty {
            profileImageUrl = image
        }
    }
}
