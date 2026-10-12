import SwiftUI

/// Pre-show health sheet. Uses desk tokens only — no second design system.
struct PreFlightHealthView: View {
    @Bindable var controller: ShowController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(ProShowTheme.hairline)
            findings
            Divider().overlay(ProShowTheme.hairline)
            footer
        }
        .frame(width: 520, height: 420)
        .background(ProShowTheme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pre-flight health check")
    }

    private var report: PreFlightReport? { controller.lastPreFlight }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: (report?.canProceed ?? false) ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle((report?.canProceed ?? false) ? Color.green : ProShowTheme.liveRed)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pre-Flight")
                    .font(DeskType.title)
                    .foregroundStyle(ProShowTheme.primaryLabel)
                Text(headerDetail)
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            Spacer()
            Button("Rescan") {
                _ = controller.runPreFlight(intent: controller.preFlightIntent)
            }
            .buttonStyle(DeskPressButtonStyle())
            .keyboardShortcut("r", modifiers: [.command])
            .accessibilityLabel("Rescan show dependencies")
        }
        .padding(16)
    }

    private var headerDetail: String {
        guard let report else { return "Scan before Go Live." }
        if report.canProceed {
            return report.warnCount == 0
                ? String(localized: "All Checks Passed")
                : ProShowCopy.warnings(report.warnCount)
        }
        return ProShowCopy.issues(report.failCount)
    }

    private var findings: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(report?.findings ?? []) { finding in
                    findingRow(finding)
                }
            }
            .padding(16)
        }
    }

    private func findingRow(_ finding: PreFlightFinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: finding.severity))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint(for: finding.severity))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title)
                    .font(DeskType.bodyEmph)
                    .foregroundStyle(ProShowTheme.primaryLabel)
                Text(finding.detail)
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = finding.relinkHint, !hint.isEmpty {
                    Text(hint)
                        .font(DeskType.mono)
                        .foregroundStyle(ProShowTheme.secondaryLabel.opacity(0.8))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ProShowTheme.well)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(finding.severity.rawValue) \(finding.title). \(finding.detail)")
    }

    private var footer: some View {
        HStack {
            Button("Close") {
                controller.isPreFlightPresented = false
            }
            .buttonStyle(DeskPressButtonStyle())
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close pre-flight")
            Spacer()
            Button(primaryTitle) {
                controller.confirmPreFlight()
            }
            .buttonStyle(DeskPressButtonStyle())
            .disabled(!(report?.canProceed ?? false))
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(primaryTitle)
            .opacity(report?.canProceed == true ? 1 : 0.45)
        }
        .padding(16)
    }

    private var primaryTitle: String {
        switch controller.preFlightIntent {
        case .startStream: "Start Capture"
        case .goLive: "Go Live"
        case .inspect: "Done"
        }
    }

    private func icon(for severity: PreFlightSeverity) -> String {
        switch severity {
        case .pass: "checkmark.circle.fill"
        case .warn: "exclamationmark.circle.fill"
        case .fail: "xmark.octagon.fill"
        }
    }

    private func tint(for severity: PreFlightSeverity) -> Color {
        switch severity {
        case .pass: Color.green
        case .warn: Color.yellow
        case .fail: ProShowTheme.liveRed
        }
    }
}
