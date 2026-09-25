import SwiftUI

/// Top global toolbar: mode tools (left) + Live / Audience / Stage (right).
struct TopToolbarView: View {
    @Bindable var controller: ShowController
    var onOpenAudience: () -> Void

    private let tools: [(String, String)] = [
        ("magnifyingglass", "Search"),
        ("textformat", "Text"),
        ("paintpalette", "Theme"),
        ("play.rectangle", "Show"),
        ("pencil", "Edit"),
        ("arrow.triangle.2.circlepath", "Reflow"),
        ("book", "Bible"),
        ("ellipsis", "More"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tools, id: \.1) { icon, title in
                ToolbarGlyphButton(systemImage: icon, title: title)
            }

            Spacer(minLength: 12)

            ToolbarGlyphButton(systemImage: "sparkles.tv", title: "ProContent")
            ToolbarGlyphButton(systemImage: "photo.on.rectangle.angled", title: "Media")
            ToolbarGlyphButton(systemImage: "icloud", title: "Default")

            Button {
                controller.goLive()
            } label: {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(ProShowTheme.liveRed.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)

            StatusLamp(title: "Audience", isOn: !controller.isAudienceCleared && controller.liveSlideID != nil)
            StatusLamp(title: "Stage", isOn: true)

            Button(action: onOpenAudience) {
                Image(systemName: "rectangle.on.rectangle")
                    .foregroundStyle(ProShowTheme.toolbarIcon)
            }
            .buttonStyle(.plain)
            .help("Open Audience Window")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(ProShowTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ProShowTheme.hairline).frame(height: DeskPaneDivider.width)
        }
    }
}

private struct ToolbarGlyphButton: View {
    let systemImage: String
    let title: String

    var body: some View {
        Button {} label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(.system(size: 9))
            }
            .foregroundStyle(ProShowTheme.toolbarIcon)
            .frame(minWidth: 44)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct StatusLamp: View {
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? ProShowTheme.statusOn : ProShowTheme.statusOff)
                .frame(width: 8, height: 8)
                .shadow(color: isOn ? ProShowTheme.statusOn.opacity(0.7) : .clear, radius: 3)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
        .padding(.horizontal, 6)
    }
}
