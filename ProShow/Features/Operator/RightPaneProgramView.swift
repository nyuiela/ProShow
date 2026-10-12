import SwiftUI

/// Right-pane program picture: SwiftUI program stack (live quotes, props, builds). Encode/recording uses `ProgramOutputBus` separately.
struct RightPaneProgramView: View {
    @Bindable var controller: ShowController

    var body: some View {
        programPicture
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ProShowTheme.stageBlack)
            .onAppear {
                controller.evaluateProgramClockState()
                ProgramAudioMonitorBridge.shared.setActive(true)
            }
            .onDisappear {
                ProgramAudioMonitorBridge.shared.setActive(false)
                controller.evaluateProgramClockState()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Program preview")
    }

    @ViewBuilder
    private var programPicture: some View {
        ProgramCanonicalMonitorView(
            controller: controller,
            outputEnabled: controller.programOutputEnabled,
            lookOverride: controller.compositor.look(forScreenID: controller.selectedScreenID),
            isRenderingPaused: controller.isProgramMonitorPaused
        )
        .allowsHitTesting(false)
    }
}
