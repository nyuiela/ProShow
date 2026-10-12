import SwiftUI

/// Right column: live preview, clear strip, transport, and action inspector.
struct OutputSidebarView: View {
    @Bindable var controller: ShowController

    var body: some View {
        RightInspectorView(controller: controller)
    }
}
