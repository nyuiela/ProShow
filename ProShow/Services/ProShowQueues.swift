import Foundation

enum ProShowQueues {
    private static let encoderQueueKey = DispatchSpecificKey<UInt8>()
    private static let videoDisplayLinkKey = DispatchSpecificKey<UInt8>()

    static let programClockQueue = DispatchQueue(
        label: "com.proshow.program.clock",
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
            qos: .utility
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
            if inFlightSemaphore.wait(timeout: .now()) == .timedOut {
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
