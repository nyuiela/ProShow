import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Chat author pictures. Fetched off the main thread, cached in memory, https only.
actor ChatAvatarCache {
    static let shared = ChatAvatarCache()
    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private var failed: Set<URL> = []

    init() {
        cache.countLimit = 300
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if failed.contains(url) { return nil }
        if let running = inflight[url] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> NSImage? in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 512 * 1024 else { return nil }
            return NSImage(data: data)
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        } else {
            failed.insert(url)
        }
        return image
    }
}

/// Fixed-size circle. Shows initials until (or unless) the picture loads.
struct ChatAvatarView: View {
    let url: String?
    let name: String
    var size: CGFloat = 22

    @State private var image: NSImage?

    var body: some View {
        Circle()
            .fill(ShowSidebarPalette.subtitle.opacity(0.22))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .task(id: url) {
                image = nil
                guard let raw = url, let parsed = URL(string: raw), parsed.scheme == "https" else { return }
                image = await ChatAvatarCache.shared.image(for: parsed)
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}
