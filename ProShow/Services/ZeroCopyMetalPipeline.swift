import Foundation
import os
#if canImport(Metal)
import Metal
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(IOSurface)
import IOSurface
#endif

final class ZeroCopyMetalPipeline: @unchecked Sendable {
    #if canImport(Metal)
    private let device: MTLDevice?
    #if canImport(CoreVideo)
    private var textureCache: CVMetalTextureCache?
    #endif
    #endif

    init() {
        #if canImport(Metal)
        device = MTLCreateSystemDefaultDevice()
        #if canImport(CoreVideo)
        if let device {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        }
        #endif
        #endif
    }

    var isReady: Bool {
        #if canImport(Metal) && canImport(CoreVideo)
        textureCache != nil
        #else
        false
        #endif
    }

    #if canImport(Metal)
    func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        #if canImport(CoreVideo)
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
        #else
        return nil
        #endif
    }

#if canImport(IOSurface)
    func createTexture(from surface: IOSurface) -> MTLTexture? {
        guard let device, surface.width > 0, surface.height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: surface.width,
            height: surface.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
    }
#endif
#endif

    #if canImport(CoreVideo)
    static func makeCompatiblePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        ProgramFramePool.take(width: max(16, width), height: max(16, height))
    }
    #endif
}

/// BGRA buffers for one size. Released buffers return to the pool instead of a new allocation each frame.
/// Depth covers every place that can hold a different frame at once: the composite in progress,
/// the program store, the RTMP slot, the ticker's last frame, the hold-frame cache,
/// the last published frame, the encoder, and the preview hub.
enum ProgramFramePool {
    static let depth = 8

    private static let lock = NSLock()
    private static var pools: [String: CVPixelBufferPool] = [:]

    static func take(width: Int, height: Int) -> CVPixelBuffer? {
        let width = max(16, width)
        let height = max(16, height)
        let key = "\(width)x\(height)"
        lock.lock()
        let pool: CVPixelBufferPool?
        if let existing = pools[key] {
            pool = existing
        } else {
            pool = makePool(width: width, height: height)
            if let pool {
                if pools.count >= 4 { pools.removeAll() }
                pools[key] = pool
            }
        }
        lock.unlock()
        guard let pool else {
            noteFailure(width: width, height: height, status: kCVReturnAllocationFailed)
            return nil
        }
        var buffer: CVPixelBuffer?
        let created = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard created == kCVReturnSuccess, let buffer else {
            noteFailure(width: width, height: height, status: created)
            return nil
        }
        if stillHeld(buffer) {
            noteAlias()
            noteFailure(width: width, height: height, status: kCVReturnWouldExceedAllocationThreshold)
            return nil
        }
        return buffer
    }

    /// The pool must not hand back a buffer RTMP or the hold-frame cache still owns.
    /// Drawing into that buffer tears the frame those consumers are reading.
    private static func stillHeld(_ buffer: CVPixelBuffer) -> Bool {
        if LatestFrameSlot.shared.held() === buffer { return true }
        if StreamHoldFrameCache.current() === buffer { return true }
        if LastPublishedStreamFrame.current() === buffer { return true }
        return false
    }

    private static let failureLog = Logger(subsystem: "com.proshow", category: "pool")

    private static func noteFailure(width: Int, height: Int, status: CVReturn) {
        failureLog.error("Program frame pool failed \(width, privacy: .public)x\(height, privacy: .public) status=\(status, privacy: .public)")
        let url = URL(fileURLWithPath: "/tmp/proshow-pool-fail.log")
        let line = Data("pool_fail \(width)x\(height) status=\(status)\n".utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private static func noteAlias() {
        let url = URL(fileURLWithPath: "/tmp/proshow-pool-alias.log")
        let line = Data("pool_alias=1\n".utf8)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        let pixel: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: depth,
            kCVPixelBufferPoolAllocationThresholdKey: depth,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            pixel as CFDictionary,
            &pool
        ) == kCVReturnSuccess else { return nil }
        return pool
    }

    static func reset() {
        lock.lock()
        pools.removeAll()
        lock.unlock()
    }
}
