#if os(macOS)
import AppKit
import SwiftUI

/// Show-mode desk: Library | Slide grid + media drawer | Inspector.
struct ProShowStudioDeskView: NSViewControllerRepresentable {
    var controller: ShowController

    @Bindable private var userSettings = UserSettingsStore.shared

    func makeNSViewController(context: Context) -> ProShow3ColumnDeskController {
        _ = context
        let libraryHost = DeskStudioHostController(rootView: LibrarySidebarView(controller: controller))

        let slidesHost = DeskStudioHostController(rootView: SlideWorkspaceView(controller: controller))
        let mediaHost = DeskStudioHostController(rootView: StudioMediaDrawerStack(controller: controller))
        let centerRows = ProShow2RowCenterController(mediaDrawerHeight: CGFloat(userSettings.mediaDrawerHeight)) { height in
            userSettings.mediaDrawerHeight = Double(height)
        }
        centerRows.attach(top: slidesHost, bottom: mediaHost)

        let inspectorHost = DeskStudioHostController(rootView: OutputSidebarView(controller: controller))
        let root = ProShow3ColumnDeskController(
            libraryWidth: CGFloat(userSettings.libraryWidth),
            inspectorWidth: CGFloat(userSettings.inspectorWidth),
            onPersistLibrary: { userSettings.libraryWidth = Double($0) },
            onPersistInspector: { userSettings.inspectorWidth = Double($0) }
        )
        root.attach(left: libraryHost, center: centerRows, right: inspectorHost)
        return root
    }

    func updateNSViewController(_ nsViewController: ProShow3ColumnDeskController, context: Context) {
        _ = nsViewController
        _ = context
    }
}

#endif
