import Foundation
import Observation

/// Press logic for the Talk button. UI only: it calls the same start and stop
/// talkback functions the old checkbox did, and nothing else.
/// Tap toggles. Press and hold talks while held. A tap or hold while on turns it off.
@MainActor
@Observable
final class TalkButtonModel {
    static let shared = TalkButtonModel()
    static let holdThreshold: TimeInterval = 0.35

    private(set) var isPressed = false
    @ObservationIgnored private var pressStart: Date?
    @ObservationIgnored private var wasActiveAtPress = false

    func press(isActive: Bool, at now: Date = Date(), start: () -> Void) {
        guard pressStart == nil else { return }
        pressStart = now
        isPressed = true
        wasActiveAtPress = isActive
        if !isActive { start() }
    }

    func release(at now: Date = Date(), stop: () -> Void) {
        guard let pressStart else { return }
        self.pressStart = nil
        isPressed = false
        let held = now.timeIntervalSince(pressStart) >= Self.holdThreshold
        if wasActiveAtPress || held { stop() }
    }

    /// Accessibility and keyboard activation: plain toggle.
    func toggle(isActive: Bool, start: () -> Void, stop: () -> Void) {
        if isActive { stop() } else { start() }
    }
}
