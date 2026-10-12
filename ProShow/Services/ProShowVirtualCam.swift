import Foundation
import Observation

enum StudioPerformance {
    static let targetFPS = 60
    static let targetWidth = 3840
    static let targetHeight = 2160
    static let maxVirtualCamLatencyMs = 30.0
}

/// In-process virtual camera sink. Publishing waits for a CoreMediaIO system extension.
@MainActor
@Observable
final class VirtualCameraSink {
    var deviceName = "ProShow Virtual Camera"
    var lastLatencyMs: Double = 0
    var framesPublished = 0
    var width = StudioPerformance.targetWidth
    var height = StudioPerformance.targetHeight
    var fps = StudioPerformance.targetFPS
    var wantsPublish = false
    var extensionAvailable = false

    var isPublished: Bool { wantsPublish && extensionAvailable }
    var needsExtension: Bool { wantsPublish && !extensionAvailable }
    var blockedReason: String? {
        needsExtension ? "Camera extension missing." : nil
    }

    func start(width: Int = StudioPerformance.targetWidth, height: Int = StudioPerformance.targetHeight, fps: Int = StudioPerformance.targetFPS) {
        self.width = width
        self.height = height
        self.fps = fps
        wantsPublish = true
    }

    func stop() {
        wantsPublish = false
    }

    func installExtensionForTests() {
        extensionAvailable = true
    }

    @discardableResult
    func publishFrame(compositedAt: TimeInterval, deliveredAt: TimeInterval) -> Double {
        lastLatencyMs = max(0, (deliveredAt - compositedAt) * 1000)
        if isPublished {
            framesPublished += 1
        }
        return lastLatencyMs
    }
}
