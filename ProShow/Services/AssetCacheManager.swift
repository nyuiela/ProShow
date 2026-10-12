import Foundation
#if canImport(AppKit)
import AppKit
#endif

final class AssetCacheManager: @unchecked Sendable {
    static let shared = AssetCacheManager()

    private let cache = NSCache<NSString, AnyObject>()
    private let lock = NSLock()
    private(set) var storedCount = 0
    #if os(macOS)
    private var pressureSource: DispatchSourceMemoryPressure?
    #endif

    init(totalCostLimit: Int = 128 * 1024 * 1024, countLimit: Int = 500) {
        cache.totalCostLimit = totalCostLimit
        cache.countLimit = countLimit
        cache.evictsObjectsWithDiscardedContent = true
        observeMemoryPressure()
    }

    func object(forKey key: String) -> AnyObject? {
        cache.object(forKey: key as NSString)
    }

    func setObject(_ object: AnyObject, forKey key: String, cost: Int) {
        cache.setObject(object, forKey: key as NSString, cost: max(1, cost))
        lock.lock()
        storedCount += 1
        lock.unlock()
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        storedCount = 0
        lock.unlock()
    }

    func remove(matchingPrefix prefix: String) {
        guard !prefix.isEmpty else { return }
        // NSCache is opaque; prefix eviction is tracked in UnifiedCacheRegistry for generic keys.
        _ = prefix
    }

    func handleMemoryPressure() {
        removeAll()
    }

    private func observeMemoryPressure() {
        #if os(macOS)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: ProShowQueues.diskIOQueue)
        source.setEventHandler { [weak self] in
            self?.handleMemoryPressure()
        }
        source.resume()
        pressureSource = source
        #endif
    }

    deinit {
        #if os(macOS)
        pressureSource?.cancel()
        pressureSource = nil
        #endif
    }
}
