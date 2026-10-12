import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Metal)
import Metal
#endif

/// Bounded slide thumbnail / texture caches; invalidated on slide revision changes.
final class SlideCacheManager: @unchecked Sendable {
    static let shared = SlideCacheManager()

    private let imageCache = NSCache<NSString, AnyObject>()
    #if canImport(Metal)
    private let textureCache = NSCache<NSString, AnyObject>()
    #endif

    private init() {
        imageCache.countLimit = 100
        imageCache.totalCostLimit = 50 * 1024 * 1024
        #if canImport(Metal)
        textureCache.countLimit = 30
        textureCache.totalCostLimit = 100 * 1024 * 1024
        #endif
    }

    func invalidate(slideId: UUID) {
        let key = slideId.uuidString as NSString
        imageCache.removeObject(forKey: key)
        #if canImport(Metal)
        textureCache.removeObject(forKey: key)
        #endif
    }

    func clearAllCaches() {
        imageCache.removeAllObjects()
        #if canImport(Metal)
        textureCache.removeAllObjects()
        #endif
    }

    #if canImport(AppKit)
    func cachedImage(slideId: UUID) -> NSImage? {
        imageCache.object(forKey: slideId.uuidString as NSString) as? NSImage
    }

    func storeImage(_ image: NSImage, slideId: UUID, cost: Int) {
        imageCache.setObject(image, forKey: slideId.uuidString as NSString, cost: max(1, cost))
    }
    #endif

    #if canImport(Metal)
    func cachedTexture(slideId: UUID) -> MTLTexture? {
        textureCache.object(forKey: slideId.uuidString as NSString) as? MTLTexture
    }

    func storeTexture(_ texture: MTLTexture, slideId: UUID, cost: Int) {
        textureCache.setObject(texture, forKey: slideId.uuidString as NSString, cost: max(1, cost))
    }
    #endif
}
