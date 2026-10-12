import CoreMedia
import CoreVideo
import Foundation

/// Single-pass fan-out of one composited program frame to RTMP, record, hub, and virtual camera.
final class ProgramOutputBus: @unchecked Sendable {
    static let shared = ProgramOutputBus()

    struct FramePayload {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: TimeInterval
        var hostTime: CMTime = .invalid
        let mode: ProgramOutputMode
        let renderContract: ProgramRenderContract
        var frameRevision: UInt64 = 0
    }

    typealias SinkHandler = (FramePayload) -> Void

    private let lock = NSLock()
    private var subscribers: [String: SinkHandler] = [:]

    func subscribe(id: String, handler: @escaping SinkHandler) {
        lock.lock()
        subscribers[id] = handler
        lock.unlock()
    }

    func unsubscribe(id: String) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }

    /// Call from `programClockQueue` after `ProgramOutputComposer` produces a frame.
    func publish(payload: FramePayload) {
        lock.lock()
        let active = Array(subscribers.values)
        lock.unlock()
        for handler in active {
            handler(payload)
        }
    }
}
