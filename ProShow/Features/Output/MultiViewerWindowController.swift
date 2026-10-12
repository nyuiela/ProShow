import SwiftUI

#if os(macOS)
import AppKit

/// Places the SwiftUI MultiViewer window on the display assigned in Screens settings.
enum MultiViewerWindowController {
    static let windowTitle = "ProShow MultiViewer"

    static func assignedDisplay(from document: DeviceSettingsDocument) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = document.assignedMultiViewerDisplayIndex,
              screens.indices.contains(index)
        else { return nil }
        return screens[index]
    }

    static func preferredScreen(from document: DeviceSettingsDocument) -> NSScreen {
        if let assigned = assignedDisplay(from: document) {
            return assigned
        }
        if let key = NSApp.keyWindow?.screen {
            return key
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    static func placeOpenWindow(using document: DeviceSettingsDocument) {
        guard let window = NSApp.windows.first(where: { window in
            window.title == windowTitle || window.identifier?.rawValue == ProShowSceneID.multiviewer
        }) else { return }
        if let screen = assignedDisplay(from: document) {
            window.setFrame(screen.visibleFrame, display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
