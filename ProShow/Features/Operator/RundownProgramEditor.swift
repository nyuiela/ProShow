import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Block editor (Assign Source modal language)

struct RundownBlockEditorSheet: View {
    @Bindable var controller: ShowController
    let blockIndex: Int?
    @Binding var draft: RundownBlock
    var onSave: (RundownBlock) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var section: OutlineEditorSection = .basics
    @State private var durationMinutes: Int = 5
    @State private var durationSeconds: Int = 0

    static let modalWidth: CGFloat = AddShotModalView.modalWidth
    static let modalHeight: CGFloat = AddShotModalView.modalHeight
    static let modalMaxWidth: CGFloat = AddShotModalView.modalMaxWidth
    static let modalMaxHeight: CGFloat = AddShotModalView.modalMaxHeight

    private var program: ProgramDocumentModel {
        controller.rundownClock.program ?? controller.programDocument
    }

    private var isNew: Bool { blockIndex == nil }

    private var modalTitle: String {
        isNew ? "Outline item" : "Edit outline item"
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                contentPane
                dock
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StartHome.page)
        }
        // Fill the sheet (not a fixed 620 pt box centred in it) so the sidebar reaches the bottom edge.
        .frame(minWidth: Self.modalWidth, idealWidth: Self.modalWidth, maxWidth: Self.modalMaxWidth,
               minHeight: Self.modalHeight, idealHeight: Self.modalHeight, maxHeight: Self.modalMaxHeight)
        .background(StartHome.page)
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.sheet, style: .continuous))
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear {
            let total = Int(draft.plannedDurationSeconds)
            durationMinutes = total / 60
            durationSeconds = total % 60
        }
        .sheet(isPresented: rundownAssignSourcePresented) {
            AddShotModalView(controller: controller)
                .frame(
                    maxWidth: AddShotModalView.modalMaxWidth,
                    maxHeight: AddShotModalView.modalMaxHeight
                )
                .frame(minWidth: AddShotModalView.modalWidth, idealWidth: AddShotModalView.modalWidth, maxWidth: AddShotModalView.modalMaxWidth,
               minHeight: AddShotModalView.modalHeight, idealHeight: AddShotModalView.modalHeight, maxHeight: AddShotModalView.modalMaxHeight)
        }
    }

    private var rundownAssignSourcePresented: Binding<Bool> {
        Binding(
            get: {
                controller.isAddShotOpen && controller.addShotPurpose == .assignRundownProgramSlide
            },
            set: { isPresented in
                if !isPresented {
                    controller.closeAddShot()
                }
            }
        )
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(StartHome.ink)
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                Text(modalTitle)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(OutlineEditorSection.allCases) { item in
                        navButton(item.title, systemImage: item.iconName, selected: section == item) {
                            section = item
                        }
                    }
                }
            }
            .focusEffectDisabled()
            .frame(maxHeight: .infinity, alignment: .top)

            Spacer(minLength: 0)

            navButton("Cancel", systemImage: "xmark") { dismiss() }
                .padding(.bottom, 20)
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(StartHome.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outline sections")
    }

    private func navButton(
        _ title: String,
        systemImage: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(selected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .padding(.horizontal, 8)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.headerTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text(section.subtitle(for: draft, durationMinutes: durationMinutes, durationSeconds: durationSeconds))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer(minLength: 12)
            if section == .basics {
                HStack(spacing: 8) {
                    outlineChip("\(durationMinutes)m \(durationSeconds)s", selected: true) {}
                        .allowsHitTesting(false)
                    outlineChip(draft.segmentType.rawValue, selected: false) {}
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch section {
                case .basics:
                    basicsSection
                case .programSlide:
                    programSlideSection
                case .speakers:
                    speakersSection
                case .script:
                    scriptSection
                case .runtime:
                    runtimeSection
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusEffectDisabled()
    }

    private var basicsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                fieldBlock("Item #") {
                    outlineTextField("101", text: $draft.itemNumber)
                        .frame(width: 88)
                }
                fieldBlock("Title") {
                    outlineTextField("Segment title", text: $draft.title)
                }
            }
            fieldBlock("Segment type") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 10)], spacing: 10) {
                    ForEach(SegmentType.allCases, id: \.self) { type in
                        Button {
                            draft.segmentType = type
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: type.systemImage)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(type.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(draft.segmentType == type ? StartHome.ink : Color.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                draft.segmentType == type ? StartHome.lemon : Color.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(DeskPressButtonStyle())
                        .accessibilityAddTraits(draft.segmentType == type ? .isSelected : [])
                    }
                }
            }
            fieldBlock("Theme variant") {
                Picker("Theme variant", selection: blockThemeVariantBinding) {
                    Text("Profile default").tag(UUID?.none)
                    ForEach(controller.themeMenuVariants, id: \.id) { variant in
                        Text(variant.name).tag(Optional(variant.id))
                    }
                }
                .labelsHidden()
            }
            fieldBlock("Theme application") {
                Picker("Theme application", selection: blockThemeApplicationBinding) {
                    Text("Auto").tag(Optional<ThemeApplicationMode>.none)
                    ForEach(ThemeApplicationMode.allCases, id: \.self) { mode in
                        Text(themeApplicationLabel(mode)).tag(Optional(mode))
                    }
                }
                .labelsHidden()
            }
            fieldBlock("Planned duration") {
                HStack(spacing: 24) {
                    HStack(spacing: 8) {
                        Text("\(durationMinutes) min")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 56, alignment: .leading)
                        Stepper("Minutes", value: $durationMinutes, in: 0...180)
                            .labelsHidden()
                    }
                    HStack(spacing: 8) {
                        Text("\(durationSeconds) sec")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 56, alignment: .leading)
                        Stepper("Seconds", value: $durationSeconds, in: 0...59)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private var programSlideSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(programSlideMarkColor)
                    .frame(width: 72, height: 52)
                    .overlay {
                        Image(systemName: programSlideMarkIcon)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(StartHome.ink.opacity(0.85))
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(RundownBlockSlideSource.summary(for: draft, controller: controller))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Link a library slide, or assign a web page, camera, or media source. Leave blank for script-only.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("Assign source…") { openProgramSlideAssignSource() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StartHome.ink)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(StartHome.lemon, in: Capsule(style: .continuous))
                    .buttonStyle(DeskPressButtonStyle())
                Button("Leave blank") {
                    RundownBlockSlideSource.apply(.blank, to: &draft)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                .buttonStyle(DeskPressButtonStyle())
            }
        }
    }

    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if program.talentDatabase.isEmpty {
                Text("No speakers in this program yet. Add talent from the rundown toolbar, then assign them here.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.55))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(program.talentDatabase.enumerated()), id: \.element.id) { index, talent in
                        Button {
                            toggleTalent(talent.id)
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(StartHome.rowTint(index))
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Text(talentInitials(talent))
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(StartHome.ink)
                                    }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(talent.fullName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                    if !talent.titleOrRole.isEmpty {
                                        Text(talent.titleOrRole)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.white.opacity(0.5))
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: draft.assignedTalentIds.contains(talent.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(draft.assignedTalentIds.contains(talent.id) ? StartHome.lemon : Color.white.opacity(0.35))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(DeskPressButtonStyle())
                        .accessibilityLabel(talent.fullName)
                        .accessibilityValue(draft.assignedTalentIds.contains(talent.id) ? "Assigned" : "Not assigned")
                    }
                }
            }
        }
    }

    private var scriptSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            fieldBlock("Script") {
                outlineTextEditor(text: $draft.scriptBody, minHeight: 160, label: "Script")
            }
            HStack(spacing: 14) {
                fieldBlock("Audio cue") {
                    outlineTextField("Lav 1 — Host", text: $draft.audioCue)
                }
                fieldBlock("Video cue") {
                    outlineTextField("Cam 2 — wide", text: $draft.videoCue)
                }
            }
            fieldBlock("Operator notes") {
                outlineTextEditor(text: $draft.referenceNotes, minHeight: 88, label: "Operator notes")
            }
        }
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            toggleRow(
                title: "Auto lower-third on start",
                subtitle: "Fire the assigned speaker lower-third when this item goes live.",
                isOn: $draft.autoFireLowerThirdOnStart
            )
        }
    }

    // MARK: Dock

    private var dock: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(StartHome.tangerine)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(draft.itemNumber.isEmpty ? "#" : draft.itemNumber)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(StartHome.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 4)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(draft.title.isEmpty ? "Untitled segment" : draft.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(dockSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button("Cancel") { dismiss() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                .buttonStyle(DeskPressButtonStyle())
                .keyboardShortcut(.cancelAction)

            Button(isNew ? "Add item" : "Save") { commitSave() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StartHome.ink)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(canSave ? StartHome.lemon : Color.white.opacity(0.35), in: Capsule(style: .continuous))
                .buttonStyle(DeskPressButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(StartHome.dock)
    }

    private var dockSubtitle: String {
        let duration = "\(durationMinutes)m \(String(format: "%02d", durationSeconds))s"
        let source = RundownLinkSummary.describe(block: draft, controller: controller) ?? "No program slide"
        return "\(duration) · \(source)"
    }

    private var canSave: Bool {
        !draft.itemNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Field chrome

    private func fieldBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            content()
        }
    }

    private func outlineTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func outlineTextEditor(text: Binding<String>, minHeight: CGFloat, label: String) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: minHeight)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(label)
    }

    private func outlineChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? StartHome.ink : Color.white.opacity(0.8))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(selected ? Color.white : Color.white.opacity(0.08), in: Capsule(style: .continuous))
                .lineLimit(1)
        }
        .buttonStyle(DeskPressButtonStyle())
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn.wrappedValue ? StartHome.lemon : Color.white.opacity(0.35))
            }
            .padding(14)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    // MARK: Program slide mark

    private var programSlideMarkIcon: String {
        switch RundownBlockSlideSource.resolve(draft) {
        case .blank: "rectangle.dashed"
        case .webPage: "globe"
        case .camera: "video.fill"
        case .mediaBin, .mediaFile: "film"
        case .playlistItem, .presentationSlide: "link"
        }
    }

    private var programSlideMarkColor: Color {
        switch RundownBlockSlideSource.resolve(draft) {
        case .blank: Color.white.opacity(0.12)
        case .webPage: StartHome.aqua
        case .camera: StartHome.blush
        case .mediaBin, .mediaFile: StartHome.tangerine
        case .playlistItem, .presentationSlide: StartHome.lemon
        }
    }

    // MARK: Actions

    private func openProgramSlideAssignSource() {
        controller.openAddShotForRundownProgramSlide { item in
            if item.sourceType != .placeholderSlot,
               let letter = RundownBlockSlideSource.placeholderLetter(in: draft) {
                controller.assignDiscoveredSource(item, toPlaceholder: letter)
                return
            }
            RundownBlockSlideSource.apply(discovered: item, webURL: nil, to: &draft)
            if let committed = controller.commitOutlineSlideSource(for: draft) {
                draft = committed
            }
        }
    }

    private func toggleTalent(_ id: UUID) {
        if draft.assignedTalentIds.contains(id) {
            draft.assignedTalentIds.removeAll { $0 == id }
        } else {
            draft.assignedTalentIds.append(id)
        }
    }

    private func talentInitials(_ talent: TalentProfile) -> String {
        let parts = talent.fullName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }.joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var blockThemeVariantBinding: Binding<UUID?> {
        Binding(
            get: { ThemeRundownBridge.themeVariantID(for: draft) },
            set: { ThemeRundownBridge.setThemeVariantID($0, on: &draft) }
        )
    }

    private var blockThemeApplicationBinding: Binding<ThemeApplicationMode?> {
        Binding(
            get: { ThemeRundownBridge.themeApplication(for: draft) },
            set: { ThemeRundownBridge.setThemeApplication($0, on: &draft) }
        )
    }

    private func themeApplicationLabel(_ mode: ThemeApplicationMode) -> String {
        switch mode {
        case .auto: "Auto"
        case .native: "Native canvas"
        case .replace: "Replace"
        case .decorOnly: "Decor only"
        }
    }

    private func commitSave() {
        draft.plannedDurationSeconds = TimeInterval(durationMinutes * 60 + durationSeconds)
        onSave(draft)
        dismiss()
    }
}

private enum OutlineEditorSection: String, CaseIterable, Identifiable {
    case basics
    case programSlide
    case speakers
    case script
    case runtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basics: "Basics"
        case .programSlide: "Program slide"
        case .speakers: "Speakers"
        case .script: "Script & cues"
        case .runtime: "Runtime"
        }
    }

    var iconName: String {
        switch self {
        case .basics: "number"
        case .programSlide: "rectangle.on.rectangle.angled"
        case .speakers: "person.2.fill"
        case .script: "text.alignleft"
        case .runtime: "play.circle"
        }
    }

    var headerTitle: String {
        switch self {
        case .basics: "Segment basics"
        case .programSlide: "Program slide"
        case .speakers: "Speakers"
        case .script: "Script & cues"
        case .runtime: "Runtime options"
        }
    }

    func subtitle(for block: RundownBlock, durationMinutes: Int, durationSeconds: Int) -> String {
        switch self {
        case .basics:
            "Item number, title, segment type, and planned duration"
        case .programSlide:
            "What goes to air for this outline row"
        case .speakers:
            "Talent tied to this segment"
        case .script:
            "Script body, audio/video cues, and operator notes"
        case .runtime:
            "Automation when the item starts · \(durationMinutes)m \(durationSeconds)s planned"
        }
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
