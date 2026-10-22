import Foundation
import CoreGraphics
import ImageIO

/// Decoded still images keyed by path, size and file date. Decoding a 4K PNG costs tens of ms,
/// so the program composite and previews must never decode per frame.
final class DecodedImageCache: @unchecked Sendable {
    static let shared = DecodedImageCache()
    /// Preview long side: enough for a Retina monitor window, a quarter of the bytes of 4K.
    static let previewLongSide = 1920

    private final class Box { let image: CGImage; let stamp: Date?; init(_ i: CGImage, _ s: Date?) { image = i; stamp = s } }
    private let cache = NSCache<NSString, Box>()

    init() {
        cache.totalCostLimit = 768 * 1024 * 1024
        cache.countLimit = 400
    }

    /// The program composite asks for every design image on every frame. A file stat per call
    /// was a measurable share of the composite, so a cached image is re-checked at most once a second.
    private let checkLock = NSLock()
    private var checkedAt: [NSString: TimeInterval] = [:]
    private static let recheckInterval: TimeInterval = 1

    /// Drops one decoded image, for preloads that were skipped.
    func remove(atPath path: String, maxLongSide: Int?) {
        let key = "\(path)#\(maxLongSide ?? 0)" as NSString
        cache.removeObject(forKey: key)
        checkLock.lock()
        checkedAt[key] = nil
        checkLock.unlock()
    }

    func contains(atPath path: String, maxLongSide: Int?) -> Bool {
        cache.object(forKey: "\(path)#\(maxLongSide ?? 0)" as NSString) != nil
    }

    func image(atPath path: String, maxLongSide: Int?) -> CGImage? {
        let key = "\(path)#\(maxLongSide ?? 0)" as NSString
        let now = ProcessInfo.processInfo.systemUptime
        checkLock.lock()
        let lastCheck = checkedAt[key]
        checkLock.unlock()
        if let lastCheck, now - lastCheck < Self.recheckInterval, let box = cache.object(forKey: key) {
            return box.image
        }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        checkLock.lock()
        if checkedAt.count > 2000 { checkedAt.removeAll() }
        checkedAt[key] = now
        checkLock.unlock()
        if let box = cache.object(forKey: key), box.stamp == stamp { return box.image }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let image: CGImage?
        if let maxLongSide {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxLongSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        guard let image else { return nil }
        cache.setObject(Box(image, stamp), forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}
