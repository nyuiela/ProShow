import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// TTL + revision keyed memory cache; coordinates slide/asset cache purge on mutation.
final class UnifiedCacheRegistry: @unchecked Sendable {
    static let shared = UnifiedCacheRegistry()

    private struct CacheMeta {
        var createdAt: Date
        var revision: UInt64
        var ttlSeconds: TimeInterval
    }

    private let lock = NSLock()
    private let memoryCache = NSCache<NSString, AnyObject>()
    private var cacheMetadata: [String: CacheMeta] = [:]
    private var minimumRevision: UInt64 = 0

    private init() {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 100 * 1024 * 1024
    }

    func registerGlobalRevision(_ revision: UInt64) {
        lock.lock()
        minimumRevision = max(minimumRevision, revision)
        lock.unlock()
    }

    func set(_ key: String, value: AnyObject, ttl: TimeInterval = 300, revision: UInt64) {
        lock.lock()
        memoryCache.setObject(value, forKey: key as NSString)
        cacheMetadata[key] = CacheMeta(createdAt: Date(), revision: revision, ttlSeconds: ttl)
        lock.unlock()
    }

    func get<T: AnyObject>(_ key: String, currentRevision: UInt64) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let meta = cacheMetadata[key] else { return nil }
        let expired = Date().timeIntervalSince(meta.createdAt) > meta.ttlSeconds
        let stale = meta.revision < minimumRevision || meta.revision < currentRevision
        if expired || stale {
            memoryCache.removeObject(forKey: key as NSString)
            cacheMetadata.removeValue(forKey: key)
            return nil
        }
        return memoryCache.object(forKey: key as NSString) as? T
    }

    func invalidate(entityId: UUID) {
        let prefix = entityId.uuidString
        lock.lock()
        let keys = cacheMetadata.keys.filter { $0.hasPrefix(prefix) }
        for key in keys {
            memoryCache.removeObject(forKey: key as NSString)
            cacheMetadata.removeValue(forKey: key)
        }
        lock.unlock()
        SlideCacheManager.shared.invalidate(slideId: entityId)
        AssetCacheManager.shared.remove(matchingPrefix: prefix)
    }

    func purgeTombstone(entityId: UUID) {
        invalidate(entityId: entityId)
    }

    func flushAll() {
        lock.lock()
        memoryCache.removeAllObjects()
        cacheMetadata.removeAll()
        minimumRevision = 0
        lock.unlock()
        SlideCacheManager.shared.clearAllCaches()
        AssetCacheManager.shared.removeAll()
    }
}
