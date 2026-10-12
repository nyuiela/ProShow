import CoreVideo
import Foundation

/// Last program frame the stream published. Updated on the composite queue so a MainActor hop cannot pin every frame.
enum LastPublishedStreamFrame {
    private static let lock = NSLock()
    private static var buffer: CVPixelBuffer?

    static func remember(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        buffer = pixelBuffer
        lock.unlock()
    }

    static func current() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
    static func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }
}

/// Thread-safe last encoded program frame for CFR gap-fill when composite falls behind.
enum StreamHoldFrameCache {
    private static let lock = NSLock()
    private static var buffer: CVPixelBuffer?

    static func remember(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        buffer = pixelBuffer
        lock.unlock()
    }

    static func current() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    static func clear() {
        lock.lock()
        buffer = nil
        lock.unlock()
    }
}

#if canImport(CoreVideo)
enum StreamVideoCFRPacer {
    private static let queue = DispatchQueue(label: "com.proshow.stream.cfr-pacer", qos: .userInteractive)
    private static var timer: DispatchSourceTimer?
    private static var lastEncodedCount: UInt64 = 0
    private static var lastEncodeActivity = CFAbsoluteTimeGetCurrent()
    private static var frameCounter: (@Sendable () -> UInt64)?
    private static var emitHold: (@Sendable () -> Void)?

    static func start(
        frameRate: Int,
        encodedFrameCount: @escaping @Sendable () -> UInt64,
        emitHoldIfNeeded: @escaping @Sendable () -> Void
    ) {
        stop()
        let fps = max(1, frameRate)
        let interval = 1.0 / Double(fps)
        frameCounter = encodedFrameCount
        emitHold = emitHoldIfNeeded
        lastEncodedCount = encodedFrameCount()
        lastEncodeActivity = CFAbsoluteTimeGetCurrent()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler {
            tick(framePeriod: interval)
        }
        source.resume()
        timer = source
    }

    static func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            frameCounter = nil
            emitHold = nil
            lastEncodedCount = 0
        }
        StreamHoldFrameCache.clear()
    }

    private static func tick(framePeriod: TimeInterval) {
        guard let frameCounter, let emitHold else { return }
        let count = frameCounter()
        let now = CFAbsoluteTimeGetCurrent()
        if count > lastEncodedCount {
            lastEncodedCount = count
            lastEncodeActivity = now
            return
        }
        guard now - lastEncodeActivity >= framePeriod * 0.88 else { return }
        guard StreamHoldFrameCache.current() != nil else { return }
        emitHold()
        lastEncodeActivity = now
    }
}
#endif
