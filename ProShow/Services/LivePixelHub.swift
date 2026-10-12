import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif

/// Latest live pixels per camera/display lane. NSView hosts subscribe here so
/// SwiftUI does not re-evaluate `View.body` on every capture frame.
final class LivePixelHub: @unchecked Sendable {
    static let shared = LivePixelHub()

    private let lock = NSLock()
    #if canImport(CoreVideo)
    private var buffers: [String: CVPixelBuffer] = [:]
    private var bufferRevisions: [String: UInt64] = [:]
    #endif
    private var consumers: [UUID: Consumer] = [:]

    private struct Consumer {
        var endpoint: String?
        var sourceID: String?
        var deliverOnCaptureQueue: Bool
        var handler: (CVPixelBuffer) -> Void
    }

    private var endpointSubscriberCounts: [String: Int] = [:]

    private init() {}

    #if canImport(CoreVideo)
    func publish(
        endpoint: String?,
        sourceID: String?,
        buffer: CVPixelBuffer,
        frameRevision: UInt64 = 0
    ) {
        lock.lock()
        if let endpoint, !endpoint.isEmpty {
            buffers[endpoint] = buffer
            bufferRevisions[endpoint] = frameRevision
        }
        if let sourceID, !sourceID.isEmpty {
            buffers[sourceID] = buffer
            bufferRevisions[sourceID] = frameRevision
        }
        let delivery = consumers.values.compactMap { consumer -> ((CVPixelBuffer) -> Void, Bool)? in
            guard matches(consumer, endpoint: endpoint, sourceID: sourceID) else { return nil }
            return (consumer.handler, consumer.deliverOnCaptureQueue)
        }
        lock.unlock()
        for (handler, onCaptureQueue) in delivery {
            if onCaptureQueue {
                handler(buffer)
            } else if Thread.isMainThread {
                handler(buffer)
            } else {
                let endpoint = endpoint
                let sourceID = sourceID
                DispatchQueue.main.async { [weak self] in
                    guard let latest = self?.current(endpoint: endpoint, sourceID: sourceID) else { return }
                    handler(latest)
                }
            }
        }
    }

    func current(endpoint: String?, sourceID: String?) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        if let endpoint, let buffer = buffers[endpoint] { return buffer }
        if let sourceID, let buffer = buffers[sourceID] { return buffer }
        return nil
    }
    #endif

    func add(
        endpoint: String?,
        sourceID: String?,
        deliverOnCaptureQueue: Bool = false,
        handler: @escaping (CVPixelBuffer) -> Void
    ) -> UUID {
        let id = UUID()
        lock.lock()
        consumers[id] = Consumer(
            endpoint: endpoint,
            sourceID: sourceID,
            deliverOnCaptureQueue: deliverOnCaptureQueue,
            handler: handler
        )
        incrementSubscriberCounts(endpoint: endpoint, sourceID: sourceID, lockHeld: true)
        lock.unlock()
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        if let consumer = consumers.removeValue(forKey: id) {
            decrementSubscriberCounts(endpoint: consumer.endpoint, sourceID: consumer.sourceID, lockHeld: true)
        }
        lock.unlock()
    }

    /// Drops program.encode and any buffers stamped below `validRevision`.
    func clearStaleProgramFrames(validRevision: UInt64) {
        lock.lock()
        #if canImport(CoreVideo)
        for key in Array(buffers.keys) {
            if key == ProgramOutputComposer.previewEndpoint { continue }
            let stamped = bufferRevisions[key] ?? 0
            if stamped > 0, stamped < validRevision {
                buffers.removeValue(forKey: key)
                bufferRevisions.removeValue(forKey: key)
            }
        }
        #endif
        lock.unlock()
    }

    /// Drop cached frames for lanes with no subscribers (keeps program.encode when watched).
    func purgeUnusedBuffers() {
        lock.lock()
        #if canImport(CoreVideo)
        let keys = Array(buffers.keys)
        for key in keys {
            let count = endpointSubscriberCounts[key, default: 0]
            if count == 0, key != ProgramOutputComposer.previewEndpoint {
                buffers.removeValue(forKey: key)
            }
        }
        #endif
        lock.unlock()
    }

    private func incrementSubscriberCounts(endpoint: String?, sourceID: String?, lockHeld: Bool) {
        if !lockHeld { lock.lock() }
        if let endpoint, !endpoint.isEmpty {
            endpointSubscriberCounts[endpoint, default: 0] += 1
        }
        if let sourceID, !sourceID.isEmpty {
            endpointSubscriberCounts[sourceID, default: 0] += 1
        }
        if !lockHeld { lock.unlock() }
    }

    private func decrementSubscriberCounts(endpoint: String?, sourceID: String?, lockHeld: Bool) {
        if !lockHeld { lock.lock() }
        if let endpoint, !endpoint.isEmpty {
            endpointSubscriberCounts[endpoint, default: 1] -= 1
            if endpointSubscriberCounts[endpoint, default: 0] <= 0 {
                endpointSubscriberCounts.removeValue(forKey: endpoint)
            }
        }
        if let sourceID, !sourceID.isEmpty {
            endpointSubscriberCounts[sourceID, default: 1] -= 1
            if endpointSubscriberCounts[sourceID, default: 0] <= 0 {
                endpointSubscriberCounts.removeValue(forKey: sourceID)
            }
        }
        if !lockHeld { lock.unlock() }
    }

    func resetForTests() {
        lock.lock()
        #if canImport(CoreVideo)
        buffers.removeAll()
        bufferRevisions.removeAll()
        #endif
        consumers.removeAll()
        endpointSubscriberCounts.removeAll()
        lock.unlock()
    }

    private func matches(_ consumer: Consumer, endpoint: String?, sourceID: String?) -> Bool {
        if let endpoint, let wanted = consumer.endpoint, !wanted.isEmpty, wanted == endpoint {
            return true
        }
        if let sourceID, let wanted = consumer.sourceID, !wanted.isEmpty, wanted == sourceID {
            return true
        }
        return false
    }
}
