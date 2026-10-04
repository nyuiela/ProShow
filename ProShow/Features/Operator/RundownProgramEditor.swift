import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Block editor

struct RundownBlockEditorSheet: View {
    @Bindable var controller: ShowController
    let blockIndex: Int?
    @Binding var draft: RundownBlock
    var onSave: (RundownBlock) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var durationMinutes: Int = 5
    @State private var durationSeconds: Int = 0

    private var program: ProgramDocumentModel {
        controller.rundownClock.program ?? controller.programDocument
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(blockIndex == nil ? "Add rundown item" : "Edit rundown item")
                    .font(DeskType.meta.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    draft.plannedDurationSeconds = TimeInterval(durationMinutes * 60 + durationSeconds)
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(DeskPressButtonStyle())
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DeskSpace.md) {
                    gridField("Item #") {
                        TextField("101", text: $draft.itemNumber)
                            .textFieldStyle(.roundedBorder)
                    }
                    gridField("Title") {
                        TextField("Segment title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }
                    gridField("Type") {
                        Picker("Segment", selection: $draft.segmentType) {
                            ForEach(SegmentType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .labelsHidden()
                    }
                    HStack(spacing: 12) {
                        gridField("Duration (min)") {
                            Stepper("\(durationMinutes)", value: $durationMinutes, in: 0...180)
                        }
                        gridField("Seconds") {
                            Stepper("\(durationSeconds)", value: $durationSeconds, in: 0...59)
                        }
                    }
                    Toggle("Auto lower-third on start", isOn: $draft.autoFireLowerThirdOnStart)
                    talentPicker
                    programSlideSourceSection
                    gridField("Audio cue") {
                        TextField("Lav 1 — Host", text: $draft.audioCue)
                            .textFieldStyle(.roundedBorder)
                    }
                    gridField("Video cue") {
                        TextField("Cam 2 — wide", text: $draft.videoCue)
                            .textFieldStyle(.roundedBorder)
                    }
                    gridField("Script") {
                        TextEditor(text: $draft.scriptBody)
                            .font(.system(size: 13))
                            .frame(minHeight: 140)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(ProShowTheme.hairline))
                    }
                    gridField("Operator notes") {
                        TextEditor(text: $draft.referenceNotes)
                            .font(.system(size: 13))
                            .frame(minHeight: 72)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(ProShowTheme.hairline))
                            .accessibilityLabel("Operator notes")
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 700)
        .onAppear {
            let total = Int(draft.plannedDurationSeconds)
            durationMinutes = total / 60
            durationSeconds = total % 60
        }
    }

    private var programSlideSourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Program slide")
                .font(DeskType.micro.weight(.semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Text(RundownBlockSlideSource.summary(for: draft, controller: controller))
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.primaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Text("Link a library slide, or create a web, camera, or media slide in `.program`. Leave blank for script-only.")
                .font(DeskType.micro)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Assign source…") { openProgramSlideAssignSource() }
                    .buttonStyle(DeskPressButtonStyle())
                Button("Leave blank") {
                    RundownBlockSlideSource.apply(.blank, to: &draft)
                }
                .buttonStyle(.plain)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            }
        }
    }

    private func gridField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DeskType.micro.weight(.semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            content()
        }
    }

    private var talentPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speakers")
                .font(DeskType.micro.weight(.semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            if program.talentDatabase.isEmpty {
                Text("No speakers yet — add one from the rundown toolbar.")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            } else {
                ForEach(program.talentDatabase) { talent in
                    Toggle(talent.fullName, isOn: talentBinding(talent.id))
                        .font(DeskType.meta)
                }
            }
        }
    }

    private func openProgramSlideAssignSource() {
        controller.openAddShotForRundownProgramSlide { item in
            RundownBlockSlideSource.apply(discovered: item, webURL: nil, to: &draft)
        }
    }

    private func talentBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.assignedTalentIds.contains(id) },
            set: { on in
                if on {
                    if !draft.assignedTalentIds.contains(id) { draft.assignedTalentIds.append(id) }
                } else {
                    draft.assignedTalentIds.removeAll { $0 == id }
                }
            }
        )
    }

}

// MARK: - Talent editor

struct RundownTalentEditorSheet: View {
    @Binding var draft: TalentProfile
    var isNew: Bool
    var onSave: (TalentProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "Add speaker" : "Edit speaker")
                    .font(DeskType.meta.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(DeskPressButtonStyle())
            }
            .padding()
            Divider()
            Form {
                TextField("Full name", text: $draft.fullName)
                TextField("Title / role", text: $draft.titleOrRole)
                TextField("Organization", text: $draft.organization)
                TextField("Microphone", text: Binding(
                    get: { draft.microphoneChannelName ?? "" },
                    set: { draft.microphoneChannelName = $0.isEmpty ? nil : $0 }
                ))
                TextField("Stage notes", text: Binding(
                    get: { draft.speakerNotes ?? "" },
                    set: { draft.speakerNotes = $0.isEmpty ? nil : $0 }
                ), axis: .vertical)
                .lineLimit(3...6)
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(width: 400, height: 380)
    }
}

// MARK: - Link summary

enum RundownLinkSummary {
    @MainActor
    static func describe(block: RundownBlock, controller: ShowController) -> String? {
        let summary = RundownBlockSlideSource.summary(for: block, controller: controller)
        switch RundownBlockSlideSource.resolve(block) {
        case .blank:
            return nil
        default:
            return summary
        }
    }
}
