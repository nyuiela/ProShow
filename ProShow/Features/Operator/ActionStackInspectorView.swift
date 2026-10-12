import SwiftUI

/// Operator composition panel — semantic on-air stack (see `UserCompositionPanelView`).
struct ActionStackInspectorView: View {
    @Bindable var controller: ShowController

    var body: some View {
        UserCompositionPanelView(controller: controller)
    }
}
