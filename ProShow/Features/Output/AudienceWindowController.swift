import SwiftUI

#if os(macOS)
import AppKit

/// Hosts a dedicated audience window on macOS (second display / full-screen ready).
@MainActor
final class AudienceWindowController: ObservableObject {
    private var window: NSWindow?

    func open(controller: ShowController) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = AudienceWindowRoot(controller: controller)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 80, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "ProShow Audience"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct AudienceWindowRoot: View {
    @Bindable var controller: ShowController

    var body: some View {
        AudienceView(slide: controller.liveSlide, showsChrome: false)
            .frame(minWidth: 640, minHeight: 360)
            .background(ProShowTheme.stageBlack)
    }
}
#endif
