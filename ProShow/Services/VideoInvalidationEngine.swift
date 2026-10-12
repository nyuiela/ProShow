import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(Metal)
import Metal
#endif

/// Purges stale program frames when `FrameRevisionClock` advances.
final class VideoInvalidationEngine: @unchecked Sendable {
    static let shared = VideoInvalidationEngine()

    private let lock = NSLock()
    #if canImport(CoreVideo)
    private var cachedPixelBuffers: [String: (buffer: CVPixelBuffer, revision: UInt64)] = [:]
    #endif
    #if canImport(Metal)
    private var cachedTextures: [String: (texture: MTLTexture, revision: UInt64)] = [:]
    #endif

    private init() {}

    func invalidateAllBuffers(upToRevision targetRevision: UInt64) {
        var texturePurged = 0
        var bufferPurged = 0
        lock.lock()
        #if canImport(Metal)
        let staleTextureKeys = cachedTextures.filter { $0.value.revision < targetRevision }.map(\.key)
        texturePurged = staleTextureKeys.count
        for key in staleTextureKeys {
            cachedTextures.removeValue(forKey: key)
        }
        #endif
        #if canImport(CoreVideo)
        let staleBufferKeys = cachedPixelBuffers.filter { $0.value.revision < targetRevision }.map(\.key)
        bufferPurged = staleBufferKeys.count
        for key in staleBufferKeys {
            cachedPixelBuffers.removeValue(forKey: key)
        }
        #endif
        lock.unlock()

        LivePixelHub.shared.clearStaleProgramFrames(validRevision: targetRevision)
        NotificationCenter.default.post(
            name: .proShowVideoFrameInvalidated,
            object: nil,
            userInfo: ["revision": targetRevision]
        )

        #if DEBUG
        if texturePurged > 0 || bufferPurged > 0 {
            print(
                "VideoInvalidation: revision \(targetRevision) flushed \(texturePurged) textures, \(bufferPurged) buffers"
            )
        }
        #endif
    }

    #if canImport(CoreVideo)
    func storeBuffer(_ buffer: CVPixelBuffer, forKey key: String, revision: UInt64) {
        lock.lock()
        cachedPixelBuffers[key] = (buffer, revision)
        lock.unlock()
    }

    func buffer(forKey key: String, requiredRevision: UInt64) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cachedPixelBuffers[key], entry.revision >= requiredRevision else {
            return nil
        }
        return entry.buffer
    }
    #endif

    func resetForTests() {
        lock.lock()
        #if canImport(CoreVideo)
        cachedPixelBuffers.removeAll()
        #endif
        #if canImport(Metal)
        cachedTextures.removeAll()
        #endif
        lock.unlock()
    }
}
