#if os(macOS)
import AppKit
import SwiftUI

/// Keeps ProShow output windows (and optionally the operator desk) out of ScreenCaptureKit display capture.
enum ProShowStreamCapturePrivacy {
    private static var savedOperatorSharingTypes: [ObjectIdentifier: NSWindow.SharingType] = [:]
    private static var concealmentUpdateObserver: NSObjectProtocol?
    /// True while a full-display share should keep ProShow windows out of the capture.
    static var deskConcealmentActive = false
    /// While a display filter is being built, the desk must stay listed so ScreenCaptureKit can exclude it.
    /// `sharingType` alone does not remove the key window from a same-process full-display capture.
    private static var suspendConcealmentForFilterSnapshot = false

    static var isSuspendingConcealment: Bool { suspendConcealmentForFilterSnapshot }

    static let streamWindowIdentifier = "proshow-stream"
    static let multiViewerWindowIdentifier = "proshow-multiviewer"

    /// Audience, stage, stream, and multiviewer never belong in a screen-share of the desktop.
    static func pinFeedbackWindowsOutOfCapture() {
        for window in NSApp.windows where shouldPinOutOfCapture(window) {
            window.sharingType = .none
        }
    }

    static func feedbackWindowNumbers() -> Set<UInt32> {
        applicationWindowNumbers()
    }

    /// Every on-screen ProShow window, including the operator desk. Display capture punches these out.
    static func applicationWindowNumbers() -> Set<UInt32> {
        Set(NSApp.windows.compactMap { window in
            let number = window.windowNumber
            guard number > 0 else { return nil }
            return UInt32(number)
        })
    }

    /// List ProShow windows for one `SCShareableContent` snapshot, then the filter excludes them.
    static func beginOperatorWindowFilterSnapshot() {
        suspendConcealmentForFilterSnapshot = true
        for window in NSApp.windows where window.windowNumber > 0 && window.sharingType == .none {
            window.sharingType = .readOnly
        }
    }

    static func endOperatorWindowFilterSnapshot() {
        suspendConcealmentForFilterSnapshot = false
        if deskConcealmentActive {
            _ = applyOperatorDeskConcealment(active: true)
        }
    }

    static func shouldPinOutOfCapture(_ window: NSWindow) -> Bool {
        if ScreenCaptureRouting.isFeedbackWindow(title: window.title) { return true }
        let id = window.identifier?.rawValue ?? ""
        if id == streamWindowIdentifier || id == multiViewerWindowIdentifier { return true }
        return false
    }

    /// While a display is being shared, hide every ProShow window. Output windows stay hidden afterward.
    /// Returns true when a window had to be punched out again (AppKit restores sharing after a Space change).
    @discardableResult
    static func applyOperatorDeskConcealment(active: Bool) -> Bool {
        if suspendConcealmentForFilterSnapshot { return false }
        pinFeedbackWindowsOutOfCapture()
        if !active {
            deskConcealmentActive = false
            removeConcealmentUpdates()
            for window in NSApp.windows where !shouldPinOutOfCapture(window) {
                let key = ObjectIdentifier(window)
                if let restored = savedOperatorSharingTypes.removeValue(forKey: key) {
                    window.sharingType = restored
                }
            }
            savedOperatorSharingTypes.removeAll()
            return false
        }
        deskConcealmentActive = true
        var changed = false
        for window in NSApp.windows where !shouldPinOutOfCapture(window) {
            if concealOperatorWindow(window) {
                changed = true
            }
        }
        installConcealmentUpdates()
        return changed
    }

    /// Space changes and SwiftUI layout put `sharingType` back to `.readOnly`. Hide the window again
    /// before the next capture frame instead of waiting for the next privacy tick.
    private static func installConcealmentUpdates() {
        guard concealmentUpdateObserver == nil else { return }
        concealmentUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { note in
            guard !suspendConcealmentForFilterSnapshot else { return }
            guard let window = note.object as? NSWindow else { return }
            if shouldPinOutOfCapture(window) {
                if window.sharingType != .none {
                    window.sharingType = .none
                }
                return
            }
            _ = concealOperatorWindow(window)
        }
    }

    private static func removeConcealmentUpdates() {
        if let concealmentUpdateObserver {
            NotificationCenter.default.removeObserver(concealmentUpdateObserver)
        }
        concealmentUpdateObserver = nil
    }

    /// Saves the previous sharing type once, then keeps the window out of ScreenCaptureKit.
    private static func concealOperatorWindow(_ window: NSWindow) -> Bool {
        if suspendConcealmentForFilterSnapshot { return false }
        let key = ObjectIdentifier(window)
        let changed = window.sharingType != .none
        if savedOperatorSharingTypes[key] == nil {
            savedOperatorSharingTypes[key] = changed ? window.sharingType : .readOnly
        }
        if changed {
            window.sharingType = .none
        }
        return changed
    }
}

/// Ensures SwiftUI-hosted output windows pick up `sharingType = .none` once attached to a window.
struct ProShowCapturePrivacyInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(from: nsView)
    }

    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            ProShowStreamCapturePrivacy.pinFeedbackWindowsOutOfCapture()
            if let window = view.window {
                window.sharingType = .none
            }
        }
    }
}
#endif
