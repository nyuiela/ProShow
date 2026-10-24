import SwiftUI
#if os(macOS)
import UniformTypeIdentifiers
#endif

struct RundownWorkspaceView: View {
    @Bindable var controller: ShowController
    private var selectedBlockIndex: Int {
        get { controller.rundownFocusedBlockIndex }
        nonmutating set { controller.rundownFocusedBlockIndex = newValue }
    }
    @State private var selectedTalentID: UUID?
    @State private var importError: String?
    @State private var blockEditorIndex: Int?
    @State private var blockEditorDraft = RundownBlock(itemNumber: "101", title: "New item", segmentType: .keynote, plannedDurationSeconds: 300)
    @State private var showBlockEditor = false
    @State private var talentDraft = TalentProfile(fullName: "")
    @State private var showTalentEditor = false
    @State private var editingTalentIsNew = true
    @State private var confirmDeleteBlock = false

    private var clock: RundownClockEngine { controller.rundownClock }
    private var program: ProgramDocumentModel {
        clock.program ?? controller.programDocument
    }
    private var blocks: [RundownBlock] { program.rundownBlocks }

    private var focusedIndex: Int? {
        guard blocks.indices.contains(selectedBlockIndex) else { return blocks.isEmpty ? nil : 0 }
        return selectedBlockIndex
    }

    private var focusedRundownBlock: RundownBlock? {
        focusedIndex.flatMap { blocks[safe: $0] }
    }

    private var focusedProgramPreview: ProgramOutlineRowPreview? {
        guard let block = focusedRundownBlock else { return nil }
        return controller.programPreview(for: block)
    }

    var body: some View {
        VStack(spacing: 0) {
            runtimeChromeRow
            featuredTopBar
            screenBody
            transportFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProShowTheme.canvas)
        .lockFlickerFreeBackground()
        .onAppear {
            PromptFloatController.shared.attachRundown(controller)
            #if os(macOS)
            RundownFloatController.shared.attachRundown(controller)
            #endif
            controller.syncProgramSlidesFromOutline()
            controller.prefetchProgramSlidePageFrames()
            if clock.isShowRunning, let active = clock.activeBlockIndex, blocks.indices.contains(active) {
                selectedBlockIndex = active
            }
            loadPrompt()
        }
        .onChange(of: focusedIndex) { _, _ in
            loadPrompt()
            if let block = focusedRundownBlock {
                warmProgramSlidePreview(for: block)
            }
        }
        .onChange(of: blocks.map(\.scriptBody).joined(separator: "\u{1e}")) { _, _ in loadPrompt() }
        .alert("Program File", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .confirmationDialog("Delete this rundown item?", isPresented: $confirmDeleteBlock, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelectedBlock() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showBlockEditor) {
            RundownBlockEditorSheet(
                controller: controller,
                blockIndex: blockEditorIndex,
                draft: $blockEditorDraft,
                onSave: { saveBlockEditor($0) }
            )
            .frame(minWidth: RundownBlockEditorSheet.modalWidth, idealWidth: RundownBlockEditorSheet.modalWidth, maxWidth: RundownBlockEditorSheet.modalMaxWidth,
                   minHeight: RundownBlockEditorSheet.modalHeight, idealHeight: RundownBlockEditorSheet.modalHeight, maxHeight: RundownBlockEditorSheet.modalMaxHeight)
        }
        .sheet(isPresented: $showTalentEditor) {
            RundownTalentEditorSheet(
                draft: $talentDraft,
                isNew: editingTalentIsNew,
                onSave: { controller.upsertTalentProfile($0) }
            )
        }
    }

    // MARK: - Top bar

    private var runtimeChromeRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                WorkspaceTitleGroup(controller: controller)
                    .fixedSize(horizontal: true, vertical: false)
            }
            RundownPromptSidebarToggle(controller: controller)
            #if os(macOS)
            RundownOutlineFloatToggle()
            #endif
        }
        .padding(.horizontal, DeskSpace.xs)
        .padding(.vertical, 6)
        .frame(height: 38)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var featuredTopBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(program.showTitle)
                    .font(DeskType.title)
                    .tracking(-0.2)
                    .foregroundStyle(ProShowTheme.primaryLabel)
                Text(sessionSubtitle)
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            .frame(minWidth: 180, alignment: .leading)

            HStack(spacing: 2) {
                rundownIcon("plus", label: "Add item") { openAddBlock() }
                rundownIcon("pencil", label: "Edit item", enabled: focusedIndex != nil) { openEditBlock() }
                rundownIcon("trash", label: "Delete item", enabled: focusedIndex != nil && !clock.isShowRunning) {
                    confirmDeleteBlock = true
                }
                rundownIcon("person.badge.plus", label: "Add speaker") { openAddTalent() }
                rundownIcon("eye", label: "Follow active item") {
                    if let active = clock.activeBlockIndex { selectedBlockIndex = active }
                }
                #if os(macOS)
                rundownIcon("folder", label: "Open program file") { openProgramFile() }
                rundownIcon("square.and.arrow.down", label: "Save program file") { saveProgramFile() }
                #endif
                rundownIcon("bolt", label: "Fire next cue", enabled: clock.isShowRunning) {
                    controller.advanceRundownBlock()
                }
            }

            Spacer(minLength: 12)

            driftSummary

            TimelineView(.periodic(from: TimelineAnchor.start, by: 0.5)) { context in
                HStack(spacing: 20) {
                    clockColumn(
                        title: "Item run time",
                        value: itemRunTimeDisplay,
                        prominent: clock.isShowRunning,
                        valueColor: itemRunTimeColor
                    )
                    clockColumn(
                        title: "Time of day",
                        value: RundownFormat.timeOfDay(context.date),
                        prominent: false
                    )
                }
            }
        }
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 10)
    }

    private var screenBody: some View {
        HSplitView {
            VStack(spacing: 0) {
                featuredList
            }
            .frame(minWidth: 400, idealWidth: 480, maxWidth: 560)
            VStack(spacing: 0) {
                RundownDetailPane(
                    controller: controller,
                    block: focusedIndex.flatMap { blocks[safe: $0] },
                    blockIndex: focusedIndex,
                    selectedTalentID: $selectedTalentID,
                    onEditBlock: { openEditBlock() },
                    onEditTalent: { talent in
                        editingTalentIsNew = false
                        talentDraft = talent
                        showTalentEditor = true
                    }
                )
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if controller.showsPromptSidebar {
                RundownTeleprompterView(
                    script: focusedIndex.flatMap { blocks[safe: $0]?.scriptBody } ?? "",
                    settings: .shared,
                    session: .shared,
                    surface: .embedded
                )
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 480, maxHeight: .infinity)
                .accessibilityLabel("Prompt")
            }
        }
    }

    private func loadPrompt() {
        let body = focusedIndex.flatMap { blocks[safe: $0]?.scriptBody } ?? ""
        TeleprompterSession.shared.loadIfNeeded(script: body, settings: .shared)
    }

    private var sessionSubtitle: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: program.scheduledDate)
    }

    private var itemRunTimeDisplay: String {
        if clock.isShowRunning {
            return RundownFormat.itemRunTime(clock.activeBlockElapsedSeconds)
        }
        return "00:00:00"
    }

    /// Red only once the live item has run past its planned length.
    private var itemRunTimeColor: Color? {
        guard clock.isShowRunning,
              let index = clock.activeBlockIndex,
              blocks.indices.contains(index),
              clock.activeBlockElapsedSeconds > blocks[index].plannedDurationSeconds
        else { return nil }
        return ProShowTheme.liveRed
    }

    private var driftSummary: some View {
        let drift = clock.cumulativeDriftSeconds
        let color = driftColor(drift)
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(driftLabel(drift))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func clockColumn(title: String, value: String, prominent: Bool, valueColor: Color? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(RundownChrome.mutedLabel)
                .tracking(0.6)
            Text(value)
                .font(.system(size: prominent ? 22 : 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(valueColor ?? (prominent ? ProShowTheme.lyricWhite : RundownChrome.secondaryInk))
        }
        .accessibilityElement(children: .combine)
    }

    private func openAddBlock() {
        blockEditorIndex = nil
        let nextNum = nextItemNumber()
        blockEditorDraft = RundownBlock(
            itemNumber: nextNum,
            title: "New segment",
            segmentType: .keynote,
            plannedDurationSeconds: 300
        )
        showBlockEditor = true
    }

    private func openEditBlock() {
        guard let idx = focusedIndex, let block = blocks[safe: idx] else { return }
        blockEditorIndex = idx
        blockEditorDraft = block
        showBlockEditor = true
    }

    private func saveBlockEditor(_ block: RundownBlock) {
        if let idx = blockEditorIndex {
            controller.updateRundownBlock(at: idx, with: block)
        } else {
            controller.addRundownBlock(block)
            let count = controller.programDocumentSnapshot().rundownBlocks.count
            selectedBlockIndex = max(0, count - 1)
        }
    }

    private func deleteSelectedBlock() {
        guard let idx = focusedIndex else { return }
        controller.deleteRundownBlock(at: idx)
        selectedBlockIndex = min(idx, max(0, blocks.count - 2))
    }

    private func openAddTalent() {
        editingTalentIsNew = true
        talentDraft = TalentProfile(fullName: "")
        showTalentEditor = true
    }

    private func nextItemNumber() -> String {
        let last = blocks.last?.itemNumber ?? "100"
        if let n = Int(last.filter(\.isNumber)) {
            return String(n + 1)
        }
        return "\(blocks.count + 101)"
    }

    #if os(macOS)
    private func saveProgramFile() {
        do {
            if controller.programDocumentURL == nil {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.proShowProgram]
                panel.nameFieldStringValue = "\(program.showTitle).program"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try controller.saveProgramDocument(to: url)
            } else {
                try controller.saveProgramDocument()
            }
        } catch {
            importError = error.localizedDescription
        }
    }
    #endif

    private func rundownIcon(
        _ symbol: String,
        label: String,
        enabled: Bool = true,
        active: Bool = false,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DeskControlSize.regular.iconFont)
                .foregroundStyle(active ? ProShowTheme.accent : ProShowTheme.toolbarIcon)
                .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(label)
        .accessibilityLabel(label)
        .modifier(RundownKeyShortcut(shortcut: shortcut))
    }

    // MARK: - List

    private var featuredList: some View {
        VStack(spacing: 0) {
            listHeader
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        featuredRow(block, index: index)
                    }
                }
            }
        }
        .background(ProShowTheme.canvas)
    }

    private var listHeader: some View {
        HStack(spacing: 0) {
            headerCell("#", width: 44)
            headerCell("Description", flex: true)
            headerCell("Start", width: 64, alignment: .trailing)
            headerCell("Duration", width: 72, alignment: .trailing)
            headerCell("", width: 28)
        }
        .font(DeskType.micro)
        .foregroundStyle(ProShowTheme.secondaryLabel)
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 8)
    }

    private func featuredRow(_ block: RundownBlock, index: Int) -> some View {
        let isActive = clock.activeBlockIndex == index && clock.isShowRunning
        let isSelected = selectedBlockIndex == index
        let ink = isActive ? Color.white : ProShowTheme.lyricWhite
        let quiet = isActive ? Color.white.opacity(0.85) : RundownChrome.secondaryInk
        return HStack(spacing: 0) {
            Text(block.itemNumber)
                .font(DeskType.mono)
                .foregroundStyle(quiet)
                .frame(width: 44, alignment: .leading)
            Text(block.title)
                .font(isActive ? DeskType.bodyEmph : DeskType.body)
                .foregroundStyle(ink)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(plannedStartLabel(index: index))
                .font(DeskType.mono)
                .foregroundStyle(isActive ? Color.white.opacity(0.9) : RundownChrome.mutedLabel)
                .frame(width: 64, alignment: .trailing)
            Group {
                if isActive {
                    RundownLiveCountdown(clock: clock, font: DeskType.mono, color: Color.white)
                } else {
                    Text(RundownFormat.duration(block.plannedDurationSeconds))
                        .font(DeskType.mono)
                        .foregroundStyle(quiet)
                }
            }
            .frame(width: 72, alignment: .trailing)
            Group {
                if block.linkedPresentationSlideID != nil {
                    Image(systemName: "link")
                        .help("Linked presentation slide")
                } else if block.programSlideID != nil {
                    Image(systemName: "rectangle.on.rectangle.angled")
                        .help("`.program` slide")
                } else {
                    Image(systemName: block.segmentType.systemImage)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(quiet)
            .frame(width: 28)
        }
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(block: block, isActive: isActive, isSelected: isSelected))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectedBlockIndex = index
            selectedTalentID = block.assignedTalentIds.first
            warmProgramSlidePreview(for: block)
            controller.takeRundownBlockLive(at: index)
        }
        .onTapGesture(count: 1) {
            selectedBlockIndex = index
            selectedTalentID = block.assignedTalentIds.first
            warmProgramSlidePreview(for: block)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.itemNumber), \(block.title)")
        .accessibilityHint("Double-click to take this minute live")
        .accessibilityAddTraits(isSelected || isActive ? .isSelected : [])
    }

    private func rowBackground(block: RundownBlock, isActive: Bool, isSelected: Bool) -> Color {
        if isActive { return RundownChrome.activeRow }
        let tint = Color(hex: block.segmentType.rowTintHex) ?? RundownChrome.listBackground
        return isSelected ? tint.opacity(0.95) : tint
    }

    private func plannedStartLabel(index: Int) -> String {
        let offset = blocks.prefix(index).reduce(0.0) { $0 + $1.plannedDurationSeconds }
        let date = program.hardStartTime.addingTimeInterval(offset)
        return RundownFormat.timeOfDay(date)
    }

    private func warmProgramSlidePreview(for block: RundownBlock) {
        guard let preview = controller.programPreview(for: block) else { return }
        controller.prepareSlidePreviewCapture(for: preview.slide)
    }

    // MARK: - Footer

    private var transportFooter: some View {
        HStack(spacing: 2) {
            if clock.isShowRunning {
                rundownIcon("stop.fill", label: "Stop show") {
                    if let active = clock.activeBlockIndex, blocks.indices.contains(active) {
                        selectedBlockIndex = active
                    }
                    clock.stopShow()
                    controller.refreshRundownTick()
                }
                rundownIcon(clock.isHeld ? "play.circle" : "pause.circle", label: clock.isHeld ? "Resume" : "Hold", active: clock.isHeld) {
                    controller.toggleRundownHold()
                }
                rundownIcon("goforward.30", label: "Add 30 seconds") {
                    controller.extendRundownBlock()
                }
                rundownIcon("forward.end.fill", label: "Next block") {
                    controller.advanceRundownBlock()
                }
                // Space: resume a Hold, otherwise Next.
                Button("") { controller.rundownSpaceAction() }
                    .keyboardShortcut(.space, modifiers: [])
                    .buttonStyle(.plain)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            rundownIcon(
                controller.rundownAutoAdvance ? "a.circle.fill" : "a.circle",
                label: controller.rundownAutoAdvance ? "Auto on" : "Auto off",
                active: controller.rundownAutoAdvance
            ) {
                controller.toggleRundownAutoAdvance()
            }

            Spacer()

            if clock.isShowRunning {
                Text("Tracking live rundown")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            } else {
                Text("Double-click an outline row to go live")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }

            rundownFooterPreviews
        }
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var rundownFooterPreviews: some View {
        HStack(alignment: .bottom, spacing: 10) {
            #if os(macOS)
            if let block = focusedRundownBlock, let preview = focusedProgramPreview {
                RundownProgramSlidePreview(
                    controller: controller,
                    slide: preview.slide,
                    canvasObjects: preview.canvas,
                    pageURL: preview.pageURL
                )
                .frame(width: 120)
                .id("\(block.id)-\(preview.slide.id)-\(preview.canvas.count)-\(preview.pageURL ?? "")")
            }
            #endif
            VStack(alignment: .leading, spacing: 4) {
                Text("STAGE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .tracking(0.5)
                StageDisplayView(controller: controller)
                    .frame(width: 120, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                            .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Stage display preview")
        }
    }

    private func headerCell(_ title: String, width: CGFloat? = nil, flex: Bool = false, alignment: Alignment = .leading) -> some View {
        Group {
            if flex {
                Text(title).frame(maxWidth: .infinity, alignment: alignment)
            } else if let width {
                Text(title).frame(width: width, alignment: alignment)
            } else {
                Text(title)
            }
        }
    }

    private func driftLabel(_ seconds: TimeInterval) -> String {
        if abs(seconds) < 5 { return "ON TIME" }
        return seconds > 0 ? "+\(RundownFormat.duration(seconds))" : "−\(RundownFormat.duration(abs(seconds)))"
    }

    private func driftColor(_ seconds: TimeInterval) -> Color {
        if abs(seconds) < 60 { return ProShowTheme.meterSafe }
        if abs(seconds) < 180 { return ProShowTheme.statusOn }
        return ProShowTheme.liveRed
    }

    #if os(macOS)
    private func openProgramFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.proShowProgram]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.loadProgramDocument(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }
    #endif
}

/// The live item's countdown. Its own view, so only this text redraws as the clock ticks.
struct RundownLiveCountdown: View {
    let clock: RundownClockEngine
    var font: Font
    var color: Color

    var body: some View {
        let text = clock.liveCountdownText
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(clock.activeBlockRemainingSeconds < 0 || clock.isHeld ? ProShowTheme.liveRed : color)
            .accessibilityLabel(clock.isHeld ? "Held, \(text)" : "Remaining \(text)")
    }
}

private struct RundownKeyShortcut: ViewModifier {
    var shortcut: KeyEquivalent?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut, modifiers: [])
        } else {
            content
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

#if os(macOS)
extension UTType {
    static let proShowProgram = UTType(exportedAs: "com.kaleel.proshow.program", conformingTo: .package)
}
#endif
