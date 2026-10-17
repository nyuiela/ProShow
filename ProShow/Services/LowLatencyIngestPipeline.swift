import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Sub-frame capture → glass path: IOSurface / Metal textures, no main-thread SwiftUI tick.
final class LowLatencyIngestPipeline: @unchecked Sendable {
    static let shared = LowLatencyIngestPipeline()

    let zeroCopy = ZeroCopyMetalPipeline()
    private let lock = NSLock()
    private var lastCaptureMonotonic: TimeInterval?
    private(set) var lastMeasuredLatencyMs: Double = 0

    var targetMaxLatencyMs: Double = 16.0

    #if canImport(AVFoundation)
    func configure(_ output: AVCaptureVideoDataOutput) {
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
    }
    #endif

    func markCapture(at monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock()
        lastCaptureMonotonic = monotonic
        lock.unlock()
    }

    @discardableResult
    func markPresent(at monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let captured = lastCaptureMonotonic else { return lastMeasuredLatencyMs }
        let ms = max(0, (monotonic - captured) * 1000)
        lastMeasuredLatencyMs = ms
        return ms
    }

    #if canImport(QuartzCore) && canImport(CoreVideo)
    /// IOSurface pass-through for live preview hosts (DeskChrome `PixelBufferHostView`).
    func presentIOSurface(_ pixelBuffer: CVPixelBuffer, on layer: CALayer) {
        #if os(macOS)
        layer.drawsAsynchronously = true
        #endif
        if let metal = layer as? CAMetalLayer {
            metal.presentsWithTransaction = false
        }
        // Non-IOSurface-backed buffers return nil: skip the frame. Retain the surface while it is assigned.
        if let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() as IOSurface? {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
        }
        _ = markPresent()
    }
    #endif

    #if canImport(Metal) && canImport(CoreVideo)
    func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        zeroCopy.createTexture(from: pixelBuffer)
    }
    #endif
}
