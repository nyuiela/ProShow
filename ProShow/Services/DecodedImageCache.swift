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

    func image(atPath path: String, maxLongSide: Int?) -> CGImage? {
        let key = "\(path)#\(maxLongSide ?? 0)" as NSString
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
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
