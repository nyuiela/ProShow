import SwiftUI

/// Keeps the primary workspaces mounted and swaps them with opacity so Metal and
/// video hosts are not torn down on every Show / Edit / Map switch.
struct AppWorkspaceRouter: View {
    @Bindable var controller: ShowController

    var body: some View {
        ZStack {
            studioDesk
                .opacity(showsStudio ? 1 : 0)
                .allowsHitTesting(showsStudio)
                .accessibilityHidden(!showsStudio)

            if keepsEditorMounted {
                CanvasEditorView(controller: controller)
                    .opacity(showsEditor ? 1 : 0)
                    .allowsHitTesting(showsEditor)
                    .accessibilityHidden(!showsEditor)
            }

            if controller.hasMountedMapWorkspace || showsMap {
                MapWorkspaceView(controller: controller)
                    .opacity(showsMap ? 1 : 0)
                    .allowsHitTesting(showsMap)
                    .accessibilityHidden(!showsMap)
            }

            if controller.hasMountedRundownWorkspace || showsRundown {
                RundownWorkspaceView(controller: controller)
                    .opacity(showsRundown ? 1 : 0)
                    .allowsHitTesting(showsRundown)
                    .accessibilityHidden(!showsRundown)
            }
        }
        .onChange(of: showsStudio, initial: true) { _, visible in
            syncProgramMonitorPause(studioVisible: visible)
        }
        .onChange(of: controller.streaming.isLive) { _, _ in
            syncProgramMonitorPause(studioVisible: showsStudio)
        }
        .onChange(of: controller.isoRecorder.isRecording) { _, _ in
            syncProgramMonitorPause(studioVisible: showsStudio)
        }
    }

    /// Preview throttling only — RTMP / ISO must keep ticking while the operator edits.
    private func syncProgramMonitorPause(studioVisible: Bool) {
        if controller.streaming.isLive || controller.isoRecorder.isRecording {
            controller.isProgramMonitorPaused = false
        } else {
            controller.isProgramMonitorPaused = !studioVisible
        }
    }

    private var showsMap: Bool {
        controller.operatorMode == .map && !showsEditor
    }

    private var showsRundown: Bool {
        controller.operatorMode == .rundown && !showsEditor
    }

    private var showsEditor: Bool { controller.isCanvasEditorPresented }

    private var showsStudio: Bool { !showsMap && !showsRundown && !showsEditor }

    private var keepsEditorMounted: Bool {
        showsEditor || (controller.editors.kind == .presentation && controller.operatorMode == .edit)
    }

    @ViewBuilder
    private var studioDesk: some View {
        #if os(macOS)
        ProShowStudioDeskView(controller: controller)
            .ignoresSafeArea(edges: .top)
        #else
        VStack(spacing: 0) {
            SlideWorkspaceView(controller: controller)
            StudioMediaDrawerStack(controller: controller)
                .frame(minHeight: DeskLayout.mediaDrawer)
        }
        #endif
    }
}
