import Foundation
import CoreMedia
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(IOSurface)
import IOSurface
#endif

/// One GPU-resident program frame shared by every preview. No CPU pixel copies.
final class SharedTexturePublisher: @unchecked Sendable {
    static let shared = SharedTexturePublisher()

    private let lock = NSLock()
    private let pipeline = ZeroCopyMetalPipeline()
    private var generation: UInt64 = 0
    private var width: Int = 0
    private var height: Int = 0
#if canImport(IOSurface)
    private var surface: IOSurface?
#endif
#if canImport(CoreVideo)
    private var pixelBuffer: CVPixelBuffer?
#endif
    private var lastItemTime: CMTime = .invalid
    private var consumers: [ObjectIdentifier: () -> Void] = [:]

    private init() {}

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func hasNewFrame(since generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation != generation
    }

    var frameSize: CGSize {
        lock.lock()
        defer { lock.unlock() }
        return CGSize(width: width, height: height)
    }

#if canImport(IOSurface)
    func currentIOSurface() -> IOSurface? {
        lock.lock()
        defer { lock.unlock() }
        return surface
    }
#endif

#if canImport(CoreVideo)
    func currentPixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return pixelBuffer
    }

    /// Thread-safe read for mirror hosts on the display-link queue.
    func takeFrameForPresentation(lastSeenGeneration: UInt64, needsInitialBind: Bool) -> (generation: UInt64, pixelBuffer: CVPixelBuffer)? {
        lock.lock()
        defer { lock.unlock() }
        guard let pixelBuffer else { return nil }
        guard generation != lastSeenGeneration || needsInitialBind else { return nil }
        return (generation, pixelBuffer)
    }

    /// Bind the incoming buffer's IOSurface. Recycled surfaces still publish when item time advances.
    func publish(pixelBuffer incoming: CVPixelBuffer, itemTime: CMTime = .invalid) {
        let nextWidth = CVPixelBufferGetWidth(incoming)
        let nextHeight = CVPixelBufferGetHeight(incoming)
#if canImport(IOSurface)
        let nextSurface = CVPixelBufferGetIOSurface(incoming)?.takeUnretainedValue()
#endif
        lock.lock()
        let isSameBufferPointer = pixelBuffer != nil && incoming === pixelBuffer
        let isSamePresentationTime = itemTime.isValid
            && lastItemTime.isValid
            && CMTimeCompare(itemTime, lastItemTime) == 0
        if isSameBufferPointer && isSamePresentationTime {
            lock.unlock()
            return
        }
#if canImport(IOSurface)
        surface = nextSurface
#endif
        pixelBuffer = incoming
        if itemTime.isValid {
            lastItemTime = itemTime
        }
        width = nextWidth
        height = nextHeight
        generation &+= 1
        let handlers = Array(consumers.values)
        lock.unlock()
        notify(handlers)
    }

    /// Same bind path as `publish`, callable from `com.proshow.video.displaylink`.
    func publishFromBackgroundQueue(pixelBuffer incoming: CVPixelBuffer, itemTime: CMTime = .invalid) {
        publish(pixelBuffer: incoming, itemTime: itemTime)
    }
#endif

#if canImport(Metal) && canImport(CoreVideo)
    func publishFromBackgroundQueue(texture: MTLTexture, pixelBuffer incoming: CVPixelBuffer, timestamp: CMTime) {
        _ = texture
        publish(pixelBuffer: incoming, itemTime: timestamp)
    }
#endif

#if canImport(Metal)
    func currentMetalTexture() -> MTLTexture? {
#if canImport(IOSurface)
        if let surface = currentIOSurface(), let texture = pipeline.createTexture(from: surface) {
            return texture
        }
#endif
#if canImport(CoreVideo)
        if let pixelBuffer = currentPixelBuffer() {
            return pipeline.createTexture(from: pixelBuffer)
        }
#endif
        return nil
    }
#endif

    func addConsumer(_ id: ObjectIdentifier, handler: @escaping () -> Void) {
        lock.lock()
        consumers[id] = handler
        lock.unlock()
    }

    func removeConsumer(_ id: ObjectIdentifier) {
        lock.lock()
        consumers.removeValue(forKey: id)
        lock.unlock()
    }

    func resetForTests() {
        lock.lock()
        generation = 0
        width = 0
        height = 0
        lastItemTime = .invalid
#if canImport(IOSurface)
        surface = nil
#endif
#if canImport(CoreVideo)
        pixelBuffer = nil
#endif
        consumers.removeAll()
        lock.unlock()
    }

    private func notify(_ handlers: [() -> Void]) {
        for handler in handlers {
            handler()
        }
    }
}
