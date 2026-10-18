import Foundation

enum RTMPOutboundTag: Sendable, Equatable {
    case other
    case audio
    case video(keyframe: Bool)
}

/// Per-destination send queue. Congestion drops non-keyframe video only.
/// Audio and keyframes stay. A full socket does not stall other endpoints.
final class RTMPEndpointQueue: @unchecked Sendable {
    let endpointId: String

    private let queue: DispatchQueue
    private let maxPending: Int
    private let maxInFlight = 8
    private let transmit: @Sendable (Data, @escaping @Sendable () -> Void) -> Void

    private struct Tag {
        var data: Data
        var kind: RTMPOutboundTag
    }

    private var pending: [Tag] = []
    private var inFlight = 0
    private var droppingUntilKeyframe = false
    private var cancelled = false
    private(set) var droppedTagCount = 0
    private(set) var droppedAudioTagCount = 0
    private(set) var acceptedTagCount = 0

    init(
        endpointId: String,
        maxPending: Int = 120,
        transmit: @escaping @Sendable (Data, @escaping @Sendable () -> Void) -> Void
    ) {
        self.endpointId = endpointId
        self.maxPending = max(2, maxPending)
        self.transmit = transmit
        queue = DispatchQueue(label: "com.proshow.rtmp.queue.\(endpointId)", qos: .userInitiated)
    }

    func enqueue(_ data: Data, kind: RTMPOutboundTag) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            enqueueOnQueue(data, kind: kind)
        }
    }

    func cancel() {
        queue.sync {
            cancelled = true
            pending.removeAll(keepingCapacity: false)
            droppingUntilKeyframe = false
        }
    }

    func sync() {
        queue.sync {}
    }

    private func enqueueOnQueue(_ data: Data, kind: RTMPOutboundTag) {
        guard !cancelled else { return }
        if pending.count >= maxPending {
            let before = pending.count
            pending.removeAll { tag in
                if case .video(false) = tag.kind { return true }
                return false
            }
            droppedTagCount += before - pending.count
            droppingUntilKeyframe = true
            while pending.count >= maxPending {
                guard let index = pending.firstIndex(where: { tag in
                    if case .video = tag.kind { return true }
                    return false
                }) else { break }
                pending.remove(at: index)
                droppedTagCount += 1
            }
        }
        if droppingUntilKeyframe {
            if isKeyframe(kind) {
                droppingUntilKeyframe = false
            } else if dropsWhileRecovering(kind) {
                noteDroppedTag(kind)
                return
            }
        }
        pending.append(Tag(data: data, kind: kind))
        acceptedTagCount += 1
        trimAudio()
        drain()
    }

    /// Audio backlog that triggers shedding P-frames (about 0.5 s of AAC).
    static let audioBacklogShedVideo = 24
    /// Hard cap for a dead socket (about 5 s of AAC). The old cap of 30 (0.64 s) cut a 0.6 s
    /// hole in the audio after every keyframe on a slow uplink.
    static let audioBacklogCap = 240
    private(set) var shedVideoForAudioCount = 0

    /// Congestion sheds non-keyframe video first so audio stays continuous.
    /// A stuck socket must not keep an unbounded run of AAC tags.
    private func trimAudio() {
        let cap = Self.audioBacklogCap
        var audioIndexes = pending.indices.filter { index in
            if case .audio = pending[index].kind { return true }
            return false
        }
        if audioIndexes.count > Self.audioBacklogShedVideo {
            let before = pending.count
            pending.removeAll { tag in
                if case .video(false) = tag.kind { return true }
                return false
            }
            let removed = before - pending.count
            if removed > 0 {
                droppedTagCount += removed
                shedVideoForAudioCount += removed
                droppingUntilKeyframe = true
                audioIndexes = pending.indices.filter { index in
                    if case .audio = pending[index].kind { return true }
                    return false
                }
            }
        }
        while audioIndexes.count > cap {
            let index = audioIndexes.removeFirst()
            pending.remove(at: index)
            noteDroppedTag(.audio)
            audioIndexes = audioIndexes.map { $0 > index ? $0 - 1 : $0 }
        }
    }

    private func isKeyframe(_ kind: RTMPOutboundTag) -> Bool {
        if case .video(true) = kind { return true }
        return false
    }

    private func noteDroppedTags(_ tags: [Tag]) {
        guard !tags.isEmpty else { return }
        droppedTagCount += tags.count
        droppedAudioTagCount += tags.reduce(0) { partial, tag in
            if case .audio = tag.kind { return partial + 1 }
            return partial
        }
    }

    private func noteDroppedTag(_ kind: RTMPOutboundTag) {
        droppedTagCount += 1
        if case .audio = kind {
            droppedAudioTagCount += 1
        }
    }

    private func dropsWhileRecovering(_ kind: RTMPOutboundTag) -> Bool {
        switch kind {
        case .video(false):
            return true
        case .audio, .other, .video(true):
            // Keep AAC flowing during video catch-up — dropping audio causes audible cutouts.
            return false
        }
    }

    private func drain() {
        guard !cancelled else { return }
        while inFlight < maxInFlight, !pending.isEmpty {
            let tag = pending.removeFirst()
            inFlight += 1
            transmit(tag.data) { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    self.drain()
                }
            }
        }
    }
}
