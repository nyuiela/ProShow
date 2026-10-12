import Foundation
import Observation

struct SoundboardPlayback: Hashable, Sendable {
    var padID: UUID
    var startedAt: Date
    var looping: Bool
}

/// Instant audio pads with precomputed waveforms and non-blocking play state.
@MainActor
@Observable
final class SoundboardStore {
    var pads: [SoundboardPad] = []
    var playing: [UUID: SoundboardPlayback] = [:]
    var lastTriggeredID: UUID?

    func install(_ pads: [SoundboardPad]) {
        self.pads = pads
    }

    func pad(id: UUID) -> SoundboardPad? {
        pads.first(where: { $0.id == id })
    }

    func add(_ pad: SoundboardPad) {
        pads.append(pad)
    }

    @discardableResult
    func play(_ id: UUID) -> Bool {
        guard let pad = pad(id: id) else { return false }
        playing[id] = SoundboardPlayback(padID: id, startedAt: Date(), looping: pad.loopMode == .loop)
        lastTriggeredID = id
        return true
    }

    func stop(_ id: UUID) {
        playing[id] = nil
    }

    func stopAll() {
        playing.removeAll()
    }

    func waveform(for id: UUID) -> [Double] {
        pad(id: id)?.waveform ?? []
    }
}
