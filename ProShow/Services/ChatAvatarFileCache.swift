import CryptoKit
import Foundation
import ImageIO

/// Chat avatars for image layers bound to `chat.avatar`. Downloads off the main thread and off
/// the render path; the renderer only ever sees a local file that is already on disk.
/// HTTPS only, 2 MB cap, must decode as an image. A miss or failure leaves the layer's own image.
@MainActor
final class ChatAvatarFileCache {
    static let shared = ChatAvatarFileCache()

    typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)
    nonisolated static let maxBytes = 2_000_000

    private let directory: URL
    private let fetch: Fetch
    private var ready: [String: String] = [:]
    private var failed: Set<String> = []
    private var waiting: [String: [(String?) -> Void]] = [:]

    init(directory: URL? = nil, fetch: Fetch? = nil) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.directory = directory ?? base.appendingPathComponent("ProShow/ChatAvatars", isDirectory: true)
        self.fetch = fetch ?? { url in
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            return try await URLSession.shared.data(for: request)
        }
    }

    /// Larger variant where the platform's URL scheme allows it (X `_normal`, YouTube `=s64`).
    nonisolated static func preferredURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var path = components.percentEncodedPath
        if host.hasSuffix("twimg.com") {
            for suffix in ["_normal.", "_bigger.", "_mini."] where path.contains(suffix) {
                path = path.replacingOccurrences(of: suffix, with: "_400x400.")
            }
        }
        if host.hasSuffix("ggpht.com") || host.hasSuffix("googleusercontent.com"),
           let range = path.range(of: #"=s\d+"#, options: .regularExpression) {
            path.replaceSubrange(range, with: "=s240")
        }
        components.percentEncodedPath = path
        return components.url
    }

    /// Local file for an avatar URL, or nil when it has not been fetched (or cannot be).
    func localPath(for raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let path = ready[key] { return path }
        guard let url = Self.preferredURL(key) else { return nil }
        let file = fileURL(for: url)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        ready[key] = file.path
        return file.path
    }

    /// Fetches once per URL. `done` runs on the main actor with the local path, or nil.
    func prefetch(_ raw: String, done: @escaping (String?) -> Void = { _ in }) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path = localPath(for: key) { done(path); return }
        guard !key.isEmpty, !failed.contains(key), let url = Self.preferredURL(key) else { done(nil); return }
        if waiting[key] != nil { waiting[key]?.append(done); return }
        waiting[key] = [done]
        let file = fileURL(for: url)
        let directory = directory
        let fetch = fetch
        // The larger size first; the URL as sent when that size does not exist.
        let original = URL(string: key).flatMap { $0 == url ? nil : $0 }
        Task.detached(priority: .utility) {
            var path = await Self.download(url, to: file, directory: directory, fetch: fetch)
            if path == nil, let original {
                path = await Self.download(original, to: file, directory: directory, fetch: fetch)
            }
            let result = path
            await MainActor.run { self.finish(key, path: result) }
        }
    }

    private func finish(_ key: String, path: String?) {
        if let path { ready[key] = path } else { failed.insert(key) }
        let callbacks = waiting.removeValue(forKey: key) ?? []
        for callback in callbacks { callback(path) }
    }

    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(String(digest.prefix(32))).appendingPathExtension("img")
    }

    nonisolated private static func download(_ url: URL, to file: URL, directory: URL, fetch: Fetch) async -> String? {
        guard let (data, response) = try? await fetch(url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard !data.isEmpty, data.count <= maxBytes, isImage(data) else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file.path
        } catch {
            return nil
        }
    }

    nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0 && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
