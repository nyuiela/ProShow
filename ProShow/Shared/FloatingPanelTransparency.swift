import AppKit
import SwiftUI

/// Floating desk panels (Studio, Rundown, Prompt) must composite over the desktop with no plate.
///
/// Root cause of the black plate: clearing `NSPanel.backgroundColor` once at creation is not enough.
/// The hosting view, the content view, and the window frame view (NSThemeFrame) each get a backing
/// layer lazily on first display, after our one-time clear ran, and AppKit backs them opaque.
/// The frame view can also insert its own backdrop subviews (visual effect / glass titlebar
/// backdrop) on macOS 26+. Everything outside the rounded SwiftUI glass then shows as black.
///
/// Fix: clear the whole chain at creation, again after the panel is first ordered in, and on
/// every resize / screen / key change, and hide any frame-view backdrop that is not ours.
enum FloatingPanelTransparency {
    @MainActor private static var observed = Set<ObjectIdentifier>()

    @MainActor
    static func apply<Content: View>(to panel: NSPanel, hosting: NSHostingController<Content>) {
        if #available(macOS 14.0, *) {
            hosting.sceneBridgingOptions = []
        }
        clearChain(panel)
        let id = ObjectIdentifier(panel)
        guard !observed.contains(id) else { return }
        observed.insert(id)
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didExposeNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak panel] _ in
                MainActor.assumeIsolated {
                    if let panel { clearChain(panel) }
                }
            }
        }
        // Layers are created lazily on first display; clear again once the panel is on screen.
        DispatchQueue.main.async { [weak panel] in
            if let panel { clearChain(panel) }
        }
    }

    @MainActor
    static func clearChain(_ panel: NSWindow) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        guard let content = panel.contentView else { return }
        clear(content)
        for sub in content.subviews { clear(sub) }
        if let frameView = content.superview {
            clear(frameView)
            for sub in frameView.subviews where sub !== content {
                let name = NSStringFromClass(type(of: sub))
                if sub is NSVisualEffectView || name.contains("Glass") || name.contains("Backdrop") || name.contains("Background") {
                    sub.isHidden = true
                } else {
                    clear(sub)
                }
            }
        }
        panel.invalidateShadow()
    }

    @MainActor
    private static func clear(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.isOpaque = false
    }
}
