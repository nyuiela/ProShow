import Foundation

/// Slide cues cannot unload or replace a locked Action Stack slot.
struct LayerLockController: Hashable, Codable, Sendable {
    var lockedLayerNumbers: Set<Int> = []

    func isLocked(_ layer: RenderLayer) -> Bool {
        lockedLayerNumbers.contains(layer.rawValue)
    }

    mutating func setLocked(_ layer: RenderLayer, locked: Bool) {
        if locked {
            lockedLayerNumbers.insert(layer.rawValue)
        } else {
            lockedLayerNumbers.remove(layer.rawValue)
        }
    }

    mutating func toggle(_ layer: RenderLayer) {
        setLocked(layer, locked: !isLocked(layer))
    }
}
