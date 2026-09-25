import SwiftUI

/// ProPresenter-class operator desk: toolbar + library | workspace/media | output.
struct OperatorView: View {
    @Bindable var controller: ShowController
    var onOpenAudienceWindow: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            TopToolbarView(
                controller: controller,
                onOpenAudience: { onOpenAudienceWindow?() }
            )

            #if os(macOS)
            macDesk
            #else
            iOSDesk
            #endif
        }
        .background(ProShowTheme.canvas)
        .preferredColorScheme(.dark)
    }

    #if os(macOS)
    private var macDesk: some View {
        HSplitView {
            LibrarySidebarView(controller: controller)
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)

            VSplitView {
                SlideWorkspaceView(controller: controller)
                    .frame(minHeight: 280)

                MediaBinView()
                    .frame(minHeight: 140, idealHeight: 180, maxHeight: 260)
            }
            .frame(minWidth: 420)

            OutputSidebarView(controller: controller)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
        }
    }
    #endif

    private var iOSDesk: some View {
        VStack(spacing: 0) {
            SlideWorkspaceView(controller: controller)
            PaneHairline()
            OutputSidebarView(controller: controller)
                .frame(height: 280)
        }
    }
}
