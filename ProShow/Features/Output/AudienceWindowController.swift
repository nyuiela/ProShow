import SwiftUI

#if os(macOS)
import AppKit

/// One live window per `OutputScreen` (audience program or stage document).
@MainActor
class OutputWindowManager: ObservableObject {
    private var windows: [String: NSWindow] = [:]

    func openOutputs(controller: ShowController, role: OutputScreenRole? = nil) {
        controller.compositor.replaceOutputScreens(ScreenCatalog.availableScreens())
        let screens = controller.compositor.stack.outputScreens.filter { role == nil || $0.role == role }
        for (index, screen) in screens.enumerated() {
            open(screen: screen, controller: controller, displayIndex: index)
        }
    }

    func open(screen: OutputScreen, controller: ShowController, displayIndex: Int) {
        if let window = windows[screen.id], window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = OutputScreenRoot(controller: controller, screen: screen)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 120 + CGFloat(displayIndex) * 36, y: 80 + CGFloat(displayIndex) * 28, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        DeskWindowChrome.lock(window)
        window.title = screen.role == .stage ? "ProShow Stage — \(screen.name)" : "ProShow Audience — \(screen.name)"
        window.sharingType = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.center()
        let displays = NSScreen.screens
        if displays.indices.contains(displayIndex) {
            window.setFrame(displays[displayIndex].visibleFrame, display: true)
        } else if screen.role == .stage, displays.count > 1 {
            window.setFrame(displays[1].visibleFrame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        ProShowStreamCapturePrivacy.pinFeedbackWindowsOutOfCapture()
        if controller.streaming.isLive {
            controller.videoInputs.refreshDisplayScreenCaptureExclusions()
        }
        windows[screen.id] = window
    }

    func presentFullscreenOnSecondary() {
        guard let window = windows.values.first(where: { $0.isVisible }),
              let screen = NSScreen.screens.dropFirst().first
        else { return }
        window.setFrame(screen.frame, display: true)
        window.toggleFullScreen(nil)
    }

    func close() {
        windows.values.forEach { $0.close() }
        windows.removeAll()
    }

    var isOpen: Bool { windows.values.contains(where: { $0.isVisible }) }
}

@MainActor
final class AudienceWindowController: OutputWindowManager {
    func open(controller: ShowController) {
        openOutputs(controller: controller, role: .audience)
    }
}

@MainActor
final class StageWindowController: OutputWindowManager {
    func open(controller: ShowController) {
        openOutputs(controller: controller, role: .stage)
    }
}

@MainActor
final class StreamWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var controller: ShowController?

    func toggle(controller: ShowController) {
        if isOpen {
            close()
            return
        }
        open(controller: controller)
    }

    func open(controller: ShowController) {
        self.controller = controller
        controller.isStreamOutputOn = true
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: StreamProgramView(controller: controller, showsChrome: true)
        )
        let panel = NSWindow(
            contentRect: NSRect(x: 160, y: 100, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        DeskWindowChrome.lock(panel)
        panel.title = "ProShow Stream"
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior.insert(.fullScreenPrimary)
        panel.minSize = NSSize(width: 640, height: 360)
        panel.center()
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        ProShowStreamCapturePrivacy.pinFeedbackWindowsOutOfCapture()
        if controller.streaming.isLive {
            controller.videoInputs.refreshDisplayScreenCaptureExclusions()
        }
        window = panel
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        controller?.isStreamOutputOn = false
        window = nil
    }

    var isOpen: Bool { window?.isVisible == true }
}

private struct OutputScreenRoot: View {
    @Bindable var controller: ShowController
    let screen: OutputScreen

    var body: some View {
        let _ = controller.liveQuotePresentationStamp
        Group {
            if screen.role == .stage {
                LiveStageView(controller: controller)
            } else {
                ProgramCanonicalMonitorView(
                    controller: controller,
                    outputEnabled: controller.programOutputEnabled,
                    lookOverride: controller.compositor.look(forScreenID: screen.id),
                    themeVariantOverride: controller.themeVariantID(forOutputScreen: screen.id)
                )
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(ProShowTheme.stageBlack)
        .lockFlickerFreeBackground()
        .clipped()
        .overlay(alignment: .bottomLeading) {
            DeskSignalProbeView(controller: controller, style: .outputOverlay)
                .padding(16)
                .allowsHitTesting(false)
        }
    }
}

#endif
