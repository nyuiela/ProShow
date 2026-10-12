import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct ProjectSettingsView: View {
    @Bindable var controller: ShowController
    @State private var draft: ProjectSettings
    @State private var preset: ProjectOutputPreset
    @State private var themeImportPresented = false
    @State private var themePackMessage: String?

    init(controller: ShowController) {
        self.controller = controller
        _draft = State(initialValue: controller.projectSettings)
        _preset = State(initialValue: ProjectOutputPreset.matching(controller.projectSettings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Project settings")
                    .font(DeskType.display)
                    .tracking(-0.4)
                Text("Canvas, aspect, and encoder settings apply only to this project.")
                    .font(DeskType.body)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }

            DeskSectionTitle(title: "Output")

            LabeledContent("Preset") {
                Picker("Preset", selection: $preset) {
                    ForEach(ProjectOutputPreset.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }

            HStack(spacing: DeskSpace.md) {
                LabeledContent("Width") {
                    TextField("Width", value: $draft.resolution.width, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("Canvas width")
                }
                LabeledContent("Height") {
                    TextField("Height", value: $draft.resolution.height, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .accessibilityLabel("Canvas height")
                }
            }

            LabeledContent("Frame rate") {
                Picker("Frame Rate", selection: $draft.frameRate) {
                    ForEach(TargetFrameRate.allCases, id: \.self) { rate in
                        Text(rate.title).tag(rate)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }

            LabeledContent("Aspect") {
                Text(draft.resolution.aspectRatioLabel)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }

            Toggle("Scale elements when the resolution changes", isOn: $draft.scaleContentOnResolutionChange)

            DeskSectionTitle(title: "Theme defaults")
            Text("Used for new slides and auto-themed cues when no variant is assigned.")
                .font(DeskType.body)
                .foregroundStyle(ProShowTheme.secondaryLabel)

            ForEach([ContentProfile.lyricMultiLine, .talkPoint, .lowerThird, .scripture], id: \.self) { profile in
                LabeledContent(profile.defaultLabel) {
                    Picker(profile.defaultLabel, selection: themeDefaultBinding(for: profile)) {
                        Text("None").tag(UUID?.none)
                        ForEach(controller.themeMenuVariants, id: \.id) { variant in
                            Text(variant.name).tag(Optional(variant.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
            }

            DeskSectionTitle(title: "Stage layout")
            Text("Stage confidence layouts live in the theme pack. Tokens preview with live program data in the Stage editor.")
                .font(DeskType.body)
                .foregroundStyle(ProShowTheme.secondaryLabel)

            LabeledContent("Active layout") {
                Picker("Stage layout", selection: stageLayoutBinding) {
                    ForEach(controller.stageMenuVariants, id: \.id) { variant in
                        Text(variant.name).tag(variant.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            DeskSectionTitle(title: "Theme pack")
            HStack(spacing: DeskSpace.sm) {
                Button("Import pack…") { themeImportPresented = true }
                Button("Export active pack…") { exportActiveThemePack() }
            }
            if let themePackMessage {
                Text(themePackMessage)
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }

            HStack {
                Spacer()
                Button("Cancel") { controller.isProjectSettingsOpen = false }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { applyDraft() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(ProShowTheme.accent)
            }
        }
        .padding(DeskSpace.lg)
        .frame(width: 520)
        .onChange(of: preset) { _, next in
            draft.applyPreset(next)
        }
        .onChange(of: draft.resolution) { _, _ in
            preset = ProjectOutputPreset.matching(draft)
            draft.syncDerivedFields()
        }
        .onChange(of: draft.frameRate) { _, _ in
            preset = ProjectOutputPreset.matching(draft)
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $themeImportPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    try controller.importThemePack(from: url)
                    themePackMessage = "Imported \(url.lastPathComponent)"
                } catch {
                    themePackMessage = error.localizedDescription
                }
            case .failure(let error):
                themePackMessage = error.localizedDescription
            }
        }
        #endif
    }

    #if os(macOS)
    private func exportActiveThemePack() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(controller.activeThemePack().collectionName).protheme.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.exportActiveThemePack(to: url)
            themePackMessage = "Exported to \(url.lastPathComponent)"
        } catch {
            themePackMessage = error.localizedDescription
        }
    }
    #endif

    private func applyDraft() {
        var next = draft
        next.syncDerivedFields()
        controller.applyProjectSettings(next)
        controller.isProjectSettingsOpen = false
    }

    private func themeDefaultBinding(for profile: ContentProfile) -> Binding<UUID?> {
        Binding(
            get: { controller.themeProjectSettings.defaultVariantID(for: profile) },
            set: { controller.setThemeProfileDefault($0, for: profile) }
        )
    }

    private var stageLayoutBinding: Binding<UUID> {
        Binding(
            get: {
                controller.themeProjectSettings.activeStageVariantID
                    ?? ThemeVariantRegistry.defaultStageVariant()?.id
                    ?? ActionSeedID.layoutGrid
            },
            set: { controller.applyStageVariant($0) }
        )
    }
}

private extension ContentProfile {
    var defaultLabel: String {
        switch self {
        case .lyricMultiLine: "Lyrics"
        case .talkPoint: "Talk points"
        case .lowerThird: "Lower thirds"
        case .scripture: "Scripture"
        default: rawValue
        }
    }
}
