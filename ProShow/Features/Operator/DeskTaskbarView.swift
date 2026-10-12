import SwiftUI

#if os(macOS)
import AppKit

/// Title-bar control. Three groups: live, floating windows, prompt.
struct DeskTaskbar: View {
    @Bindable var controller: ShowController
    @Environment(\.deskWindowActions) private var windows
    @Bindable private var prompt = PromptFloatController.shared
    @State private var metrics = TitlebarMetrics(leadingInset: 78, height: 28, climb: 0)

    var body: some View {
        HStack(spacing: 8) {
            capsule {
                button(
                    title: controller.streaming.isLive ? "Stop" : "Live",
                    symbol: "antenna.radiowaves.left.and.right",
                    help: controller.streaming.isLive ? "Stop the live broadcast" : "Go live",
                    isOn: controller.streaming.isLive,
                    tint: controller.streaming.isLive ? ProShowTheme.liveRed : ProShowTheme.toolbarIcon
                ) {
                    if controller.streaming.isLive {
                        controller.stopBroadcast()
                    } else {
                        controller.requestGoLive()
                    }
                }
                button(
                    title: controller.isAudienceCleared ? "Restore" : "Clear",
                    symbol: controller.isAudienceCleared ? "eye" : "eye.slash",
                    help: controller.isAudienceCleared ? "Restore the audience output" : "Clear the audience output",
                    isOn: controller.isAudienceCleared,
                    tint: controller.isAudienceCleared ? ProShowTheme.liveRed : ProShowTheme.toolbarIcon
                ) {
                    if controller.isAudienceCleared {
                        controller.restoreAudience()
                    } else {
                        controller.clearAudience()
                    }
                }
            }

            capsule {
                button(title: "Audience", symbol: "person.2.fill", help: "Show the audience window", isOn: false) {
                    windows.openAudience()
                }
                button(title: "Stage", symbol: "rectangle.split.2x1.fill", help: "Show the stage window", isOn: false) {
                    windows.openStage()
                }
                button(
                    title: "Stream",
                    symbol: "dot.radiowaves.left.and.right",
                    help: "Show the stream window",
                    isOn: controller.isStreamOutputOn
                ) {
                    windows.openStream()
                }
                button(
                    title: "Studio",
                    symbol: "square.grid.2x2.fill",
                    help: "Show the studio window",
                    isOn: controller.isMultiViewerOn
                ) {
                    windows.openMultiViewer()
                }
                button(
                    title: "Full Screen",
                    symbol: "arrow.up.left.and.arrow.down.right",
                    help: "Show the studio window full screen",
                    isOn: false
                ) {
                    NotificationCenter.default.post(name: .proShowStudioToggleFullScreen, object: nil)
                }
            }

            capsule {
                button(
                    title: "Prompt",
                    symbol: "text.quote",
                    help: prompt.isOpen ? "Hide the prompt" : "Show the prompt",
                    isOn: prompt.isOpen
                ) {
                    prompt.toggle()
                }
            }
        }
        .padding(.trailing, 12)
        .frame(height: metrics.height, alignment: .center)
        .offset(y: -metrics.climb)
        .background {
            TitlebarMetricsReader { metrics = $0 }
        }
    }

    private func capsule<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            content()
        }
        .padding(.horizontal, 4)
        .deskChromeGlass(in: Capsule(style: .continuous), interactive: true)
    }

    private func button(
        title: String,
        symbol: String,
        help: String,
        isOn: Bool,
        tint: Color = ProShowTheme.toolbarIcon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isOn {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 26, height: 26)
                }
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isOn ? tint : ProShowTheme.toolbarIcon)
            }
            .frame(width: 32, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
#endif
