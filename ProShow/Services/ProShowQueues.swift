import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

enum ProShowQueues {
    private static let encoderQueueKey = DispatchSpecificKey<UInt8>()
    private static let videoDisplayLinkKey = DispatchSpecificKey<UInt8>()

    static let programClockQueue = DispatchQueue(
        label: "com.proshow.program.clock",
        qos: .userInteractive
    )

    /// Full program composite — must not share a serial queue with CFR hold duplicates.
    static let programCompositeQueue = DispatchQueue(
        label: "com.proshow.program.composite",
        qos: .userInteractive
    )

    static let metalRenderQueue = DispatchQueue(
        label: "com.proshow.metal.render",
        qos: .userInteractive
    )

    /// Hardware-vsync frame pull. Never hops to `DispatchQueue.main`.
    static let videoDisplayLinkQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.proshow.video.displaylink",
            qos: .userInteractive
        )
        queue.setSpecific(key: videoDisplayLinkKey, value: 1)
        return queue
    }()

    static let videoIngestQueue = DispatchQueue(
        label: "com.proshow.video.ingest",
        qos: .userInitiated
    )

    private static let captureControlQueueKey = DispatchSpecificKey<UInt8>()

    /// Session start/stop must not run on the sample-buffer delegate queue.
    static let captureControlQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.proshow.capture.control",
            qos: .userInitiated
        )
        queue.setSpecific(key: captureControlQueueKey, value: 1)
        return queue
    }()

    static var isOnCaptureControlQueue: Bool {
        DispatchQueue.getSpecific(key: captureControlQueueKey) != nil
    }

    static var isOnVideoDisplayLinkQueue: Bool {
        DispatchQueue.getSpecific(key: videoDisplayLinkKey) != nil
    }

    static func onVideoDisplayLink(_ work: @escaping () -> Void) {
        if isOnVideoDisplayLinkQueue {
            work()
        } else {
            videoDisplayLinkQueue.async(execute: work)
        }
    }

    static let encoderQueue: DispatchQueue = {
        let queue = DispatchQueue(
            label: "com.proshow.video.encoder",
            qos: .userInitiated
        )
        queue.setSpecific(key: encoderQueueKey, value: 1)
        return queue
    }()

    static let diskIOQueue = DispatchQueue(
        label: "com.proshow.disk.io",
        qos: .utility
    )

    static var isOnEncoderQueue: Bool {
        DispatchQueue.getSpecific(key: encoderQueueKey) != nil
    }
}

#if canImport(AVFoundation)
/// Start and stop share `captureControlQueue` and keep the session alive until `stopRunning` returns.
enum CaptureSessionLifetime {
    private static let lock = NSLock()
    private static var generation: [ObjectIdentifier: Int] = [:]
    private static var held: [ObjectIdentifier: AVCaptureSession] = [:]

    static func start(_ session: AVCaptureSession) {
        let id = ObjectIdentifier(session)
        lock.lock()
        let token = (generation[id] ?? 0) + 1
        generation[id] = token
        held[id] = session
        lock.unlock()
        ProShowQueues.captureControlQueue.async {
            lock.lock()
            let current = generation[id] == token
            lock.unlock()
            guard current else { return }
            session.startRunning()
            lock.lock()
            let stillCurrent = generation[id] == token
            lock.unlock()
            if !stillCurrent {
                flushAndStop(session)
                release(id, token: token)
            }
        }
    }

    /// Stop the graph so the camera light goes off. The session object, its inputs, and its outputs stay.
    static func pause(_ session: AVCaptureSession?) {
        guard let session else { return }
        let id = ObjectIdentifier(session)
        lock.lock()
        let token = (generation[id] ?? 0) + 1
        generation[id] = token
        held[id] = session
        lock.unlock()
        ProShowQueues.captureControlQueue.async {
            lock.lock()
            let current = generation[id] == token
            lock.unlock()
            guard current else { return }
            if session.isRunning {
                session.stopRunning()
            }
            CaptureSessionWatch.note("capture paused running=\(session.isRunning)")
            release(id, token: token)
        }
    }

    static func stop(_ session: AVCaptureSession?) {
        guard let session else { return }
        let id = ObjectIdentifier(session)
        lock.lock()
        let token = (generation[id] ?? 0) + 1
        generation[id] = token
        held[id] = session
        lock.unlock()
        ProShowQueues.captureControlQueue.async {
            flushAndStop(session)
            release(id, token: token)
        }
    }

    private static func release(_ id: ObjectIdentifier, token: Int) {
        lock.lock()
        if generation[id] == token {
            held[id] = nil
            generation[id] = nil
        }
        lock.unlock()
    }

    private static func flushAndStop(_ session: AVCaptureSession) {
        for output in session.outputs {
            if let video = output as? AVCaptureVideoDataOutput {
                video.setSampleBufferDelegate(nil, queue: nil)
            }
            if let audio = output as? AVCaptureAudioDataOutput {
                audio.setSampleBufferDelegate(nil, queue: nil)
            }
        }
        if session.isRunning {
            session.stopRunning()
        }
        let outputs = session.outputs
        let inputs = session.inputs
        if outputs.isEmpty && inputs.isEmpty { return }
        session.beginConfiguration()
        for output in outputs {
            session.removeOutput(output)
        }
        for input in inputs {
            session.removeInput(input)
        }
        session.commitConfiguration()
    }
}
#endif

enum TripleBufferManager {
    static let maxBuffersInFlight = 3

    final class Gate: @unchecked Sendable {
        let inFlightSemaphore = DispatchSemaphore(value: TripleBufferManager.maxBuffersInFlight)
        private(set) var currentBufferIndex = 0
        private var acquiredCount = 0

        deinit {
            while acquiredCount > 0 {
                endFrame()
            }
        }

        @discardableResult
        func advanceBufferIndex() -> Int {
            currentBufferIndex = (currentBufferIndex + 1) % TripleBufferManager.maxBuffersInFlight
            return currentBufferIndex
        }

        func tryBeginFrame() -> Int? {
            beginFrame(maxWait: 0)
        }

        func beginFrame(maxWait: TimeInterval) -> Int? {
            let deadline: DispatchTime = maxWait > 0 ? .now() + maxWait : .now()
            if inFlightSemaphore.wait(timeout: deadline) == .timedOut {
                return nil
            }
            acquiredCount += 1
            return advanceBufferIndex()
        }

        func endFrame() {
            guard acquiredCount > 0 else { return }
            acquiredCount -= 1
            inFlightSemaphore.signal()
        }
    }
}
