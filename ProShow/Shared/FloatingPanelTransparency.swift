import AppKit
import SwiftUI

/// Floating desk panels (Studio, Rundown, Prompt) must composite over the desktop with no plate.
/// A clear `NSPanel.backgroundColor` alone is not enough: the hosting view and the window frame
/// view can still back themselves with an opaque layer, which shows as a black rectangle around
/// the rounded glass. This clears every layer in that chain.
enum FloatingPanelTransparency {
    @MainActor
    static func apply<Content: View>(to panel: NSPanel, hosting: NSHostingController<Content>) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        clear(hosting.view)
        if let content = panel.contentView { clear(content) }
        if let frameView = panel.contentView?.superview { clear(frameView) }
        panel.invalidateShadow()
    }

    @MainActor
    private static func clear(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
    }
}
