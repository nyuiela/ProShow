import SwiftUI

/// 36 pt control strip. Assignment lives in a popover, not a table under the grid.
struct MultiViewerToolbarView: View {
    @Bindable var controller: ShowController
    @Binding var isConfigOpen: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .accessibilityHidden(true)
            Picker("Layout", selection: gridBinding) {
                ForEach(MultiViewerGrid.allCases) { grid in
                    Text(grid.title).tag(grid)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .accessibilityLabel("MultiViewer layout")

            Divider()
                .frame(height: 16)
                .overlay(ProShowTheme.hairline)

            Button("Fill from sources") {
                controller.resetMultiViewerFromSources()
            }
            .buttonStyle(DeskPressButtonStyle())
            .controlSize(.small)
            .accessibilityLabel("Fill MultiViewer from live sources")

            if controller.isBroadcasting {
                Text(ProShowCopy.Status.live)
                    .font(DeskType.micro.weight(.bold))
                    .foregroundStyle(ProShowTheme.lyricWhite)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(ProShowTheme.liveRed, in: Capsule(style: .continuous))
                    .accessibilityLabel("Live on program")
            }

            Spacer(minLength: 8)

            Text(controller.multiViewerFormatLabel)
                .font(DeskType.mono)
                .foregroundStyle(ProShowTheme.secondaryLabel)

            Button {
                isConfigOpen.toggle()
            } label: {
                Label("Assign", systemImage: "slider.horizontal.3")
                    .font(DeskType.micro)
            }
            .buttonStyle(DeskPressButtonStyle())
            .controlSize(.small)
            .accessibilityLabel("Configure tiles")
            .accessibilityValue(isConfigOpen ? "Open" : "Closed")
            .popover(isPresented: $isConfigOpen, arrowEdge: .top) {
                MultiViewerInspector(controller: controller)
                    .frame(width: 520, height: 280)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(ProShowTheme.titlebar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ProShowTheme.hairline)
                .frame(height: 1)
        }
    }

    private var gridBinding: Binding<MultiViewerGrid> {
        Binding(
            get: { controller.multiViewerLayout.grid },
            set: { controller.setMultiViewerGrid($0) }
        )
    }
}
