import SwiftUI

/// Project name, program output status, and unsaved indicator for the desk title bar.
struct ProjectTitleHeaderView: View {
    var projectName: String
    var isDirty: Bool
    var programStatusTitle: String = ""
    var programStatusColor: Color = ProShowTheme.secondaryLabel

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                if isDirty {
                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("Unsaved changes")
                        .help("Unsaved changes — press ⌘S to save")
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
                Text(projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProShowTheme.primaryLabel)
                    .lineLimit(1)
            }
            if !programStatusTitle.isEmpty {
                Text(programStatusTitle)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(programStatusColor)
                    .lineLimit(1)
                    .accessibilityLabel("Program output \(programStatusTitle)")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDirty)
        .animation(.easeInOut(duration: 0.15), value: programStatusTitle)
        .accessibilityElement(children: .combine)
    }
}
