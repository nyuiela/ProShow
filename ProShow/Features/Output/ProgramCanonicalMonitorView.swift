import SwiftUI

/// Program monitor that matches RTMP / ISO when encode is active; otherwise SwiftUI stack tied to frame revision.
struct ProgramCanonicalMonitorView: View {
    @Bindable var controller: ShowController
    var outputEnabled: Bool
    var lookOverride: AudienceLookConfig? = nil
    var themeVariantOverride: UUID? = nil
    var isRenderingPaused: Bool = false

    var body: some View {
        let _ = controller.programFrameRevisionStamp
        let _ = controller.liveQuotePresentationStamp
        Group {
            if controller.usesCanonicalProgramMonitor {
                LivePixelPreview(
                    endpoint: ProgramOutputComposer.previewEndpoint,
                    sourceID: nil,
                    isPaused: isRenderingPaused || !outputEnabled
                )
            } else {
                ProgramSurfaceView(
                    controller: controller,
                    outputEnabled: outputEnabled,
                    lookOverride: lookOverride,
                    themeVariantOverride: themeVariantOverride,
                    isRenderingPaused: isRenderingPaused
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProShowTheme.stageBlack)
    }
}
