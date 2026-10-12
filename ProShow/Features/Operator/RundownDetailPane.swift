import SwiftUI

/// Featured script / cue pane (right column) — Shoflo-style director view.
struct RundownDetailPane: View {
    @Bindable var controller: ShowController
    @AppStorage(ProShowFeatureFlags.multiDestinationRoutingV1Key) private var multiDestinationRouting = false
    var block: RundownBlock?
    var blockIndex: Int?
    @Binding var selectedTalentID: UUID?
    var onEditBlock: (() -> Void)?
    var onEditTalent: ((TalentProfile) -> Void)?

    private var clock: RundownClockEngine { controller.rundownClock }
    private var program: ProgramDocumentModel {
        clock.program ?? controller.programDocument
    }

    private var focusedPageURL: String? {
        guard let block else { return nil }
        return ProgramOutlinePresentation.resolvedPageURL(
            for: block,
            in: program,
            showLookup: { controller.show(matching: $0) }
        )
    }

    private var showsNoPhone: Bool {
        guard multiDestinationRouting, let slide = focusedProgramSlide else { return false }
        let phoneArmed = controller.deviceSettings.document.accounts.contains {
            controller.streamMatrix.isActive($0.id) && $0.screenKind == .phone
        }
        guard phoneArmed else { return false }
        return PhoneSlideRouting.state(boards: slide.editorCanvases) != .present
    }

    private var focusedProgramSlide: Slide? {
        guard let block else { return nil }
        return controller.programSlide(for: block)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailHeader
            cueStrip
            scriptScroll
            operatorOutline
            talentRail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProShowTheme.canvas)
    }

    @ViewBuilder
    private var detailHeader: some View {
        if let block, let blockIndex {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(block.itemNumber)
                        .font(DeskType.mono)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                    Text(block.title)
                        .font(DeskType.display)
                        .tracking(-0.2)
                        .foregroundStyle(ProShowTheme.primaryLabel)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    metaItem(icon: "clock", text: plannedStartLabel(index: blockIndex))
                    metaItem(icon: "hourglass", text: RundownFormat.duration(block.plannedDurationSeconds))
                    if let onEditBlock {
                        Button(action: onEditBlock) {
                            Image(systemName: "pencil")
                                .font(DeskControlSize.regular.iconFont)
                                .foregroundStyle(ProShowTheme.toolbarIcon)
                                .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(DeskPressButtonStyle())
                        .help("Edit item")
                        .accessibilityLabel("Edit item")
                    }
                }
                if let link = RundownLinkSummary.describe(block: block, controller: controller) {
                    Label(link, systemImage: "link")
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                }
                if clock.activeBlockIndex == blockIndex, clock.isShowRunning {
                    rundownProgressBar
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        } else {
            Text("Select a rundown item")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var rundownProgressBar: some View {
        let total = max(block?.plannedDurationSeconds ?? 1, 1)
        let remaining = max(0, clock.activeBlockRemainingSeconds)
        let progress = min(1, max(0, 1 - remaining / total))
        let progressPercent = Int(progress * 100)
        let timing = RundownTiming.color(remaining: remaining, total: total)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(timing)
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Segment progress")
        .accessibilityValue("\(progressPercent) percent elapsed")
    }

    @ViewBuilder
    private var cueStrip: some View {
        if let block {
            HStack(spacing: 16) {
                if !block.audioCue.isEmpty {
                    Label(block.audioCue, systemImage: "mic.fill")
                }
                if !block.videoCue.isEmpty {
                    Label(block.videoCue, systemImage: "video.fill")
                }
                if let message = clock.currentStageMessage {
                    Label(message, systemImage: "megaphone")
                }
                Spacer()
                if clock.activeBlockIndex == blockIndex, clock.isShowRunning {
                    let remaining = max(0, clock.activeBlockRemainingSeconds)
                    let total = max(block.plannedDurationSeconds, 1)
                    Text(RundownFormat.duration(remaining))
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RundownTiming.color(remaining: remaining, total: total))
                        .accessibilityLabel("Time remaining")
                }
            }
            .font(DeskType.micro)
            .foregroundStyle(ProShowTheme.secondaryLabel)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    private var scriptScroll: some View {
        ScrollView {
            if let block, !block.scriptBody.isEmpty {
                Text("Script")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RundownChrome.mutedLabel)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
                RundownScriptText(script: block.scriptBody)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            } else if focusedPageURL == nil {
                Text("No script for this item. Add copy in the program file or link a slide deck.")
                    .font(DeskType.body)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var operatorOutline: some View {
        if let block, block.hasOperatorOutline {
            VStack(alignment: .leading, spacing: 10) {
                if let slide = focusedProgramSlide {
                    outlineGroup("Program slide") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(".program")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(RundownChrome.mutedLabel)
                                .frame(width: 64, alignment: .leading)
                            Text(slide.title.isEmpty ? "Linked slide" : slide.title)
                                .font(DeskType.micro)
                                .foregroundStyle(ProShowTheme.lyricWhite)
                                .lineLimit(2)
                            if showsNoPhone {
                                Text("No Phone")
                                    .font(DeskType.micro)
                                    .foregroundStyle(ProShowTheme.secondaryLabel)
                                    .accessibilityLabel("No Phone")
                            }
                        }
                        .accessibilityLabel("Program slide, \(slide.title)")
                    }
                }
                if !block.screenDirections.isEmpty {
                    outlineGroup("On screen") {
                        ForEach(block.screenDirections) { direction in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(direction.kindTitle)
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RundownChrome.mutedLabel)
                                    .frame(width: 64, alignment: .leading)
                                Text(direction.displayLabel)
                                    .font(DeskType.micro)
                                    .foregroundStyle(ProShowTheme.lyricWhite)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(direction.kindTitle), \(direction.displayLabel)")
                        }
                    }
                }
                if !block.linkCues.isEmpty {
                    outlineGroup("Links") {
                        ForEach(block.linkCues) { link in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(link.label)
                                    .font(DeskType.micro.weight(.semibold))
                                    .foregroundStyle(ProShowTheme.lyricWhite)
                                Text(link.url)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(RundownChrome.secondaryInk)
                                    .textSelection(.enabled)
                                Text(link.operatorFlags)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(RundownChrome.mutedLabel)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(link.label), \(link.operatorFlags)")
                        }
                    }
                }
                if !block.referenceNotes.isEmpty {
                    outlineGroup("Operator notes") {
                        Text(block.referenceNotes)
                            .font(DeskType.micro)
                            .foregroundStyle(RundownChrome.noteInk)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Operator notes")
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RundownChrome.noteBand)
        }
    }

    private func outlineGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(RundownChrome.mutedLabel)
                .textCase(.uppercase)
            content()
        }
    }

    private var talentRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(program.talentDatabase) { talent in
                    talentChip(talent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func talentChip(_ talent: TalentProfile) -> some View {
        let selected = selectedTalentID == talent.id
        return Button {
            selectedTalentID = talent.id
            TalentManager.fireLowerThird(talent: talent, controller: controller)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(selected ? ProShowTheme.accent : RundownChrome.mutedLabel)
                VStack(alignment: .leading, spacing: 1) {
                    Text(talent.fullName)
                        .font(DeskType.micro.weight(.semibold))
                        .foregroundStyle(ProShowTheme.lyricWhite)
                    Text(TalentManager.displayLine(for: talent))
                        .font(DeskType.micro)
                        .foregroundStyle(RundownChrome.mutedLabel)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selected ? ProShowTheme.accent.opacity(0.15) : Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel("Fire lower third for \(talent.fullName)")
        .contextMenu {
            Button("Edit speaker…") { onEditTalent?(talent) }
            Button("Remove from show", role: .destructive) {
                controller.deleteTalentProfile(id: talent.id)
            }
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
        .font(DeskType.mono)
        .foregroundStyle(ProShowTheme.secondaryLabel)
    }

    private func plannedStartLabel(index: Int) -> String {
        let program = clock.program ?? controller.programDocument
        let offset = program.rundownBlocks.prefix(index).reduce(0.0) { $0 + $1.plannedDurationSeconds }
        let date = program.hardStartTime.addingTimeInterval(offset)
        return RundownFormat.timeOfDay(date)
    }

}

/// Parses `[CUE]` tokens in script copy with high-visibility styling.
struct RundownScriptText: View {
    let script: String

    var body: some View {
        Text(attributed)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(ProShowTheme.lyricWhite)
            .lineSpacing(6)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let pattern = #"\[[^\]]+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return AttributedString(script)
        }
        let ns = script as NSString
        var cursor = 0
        for match in regex.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                let plain = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(AttributedString(plain))
            }
            let cue = ns.substring(with: match.range)
            var cueAttr = AttributedString(cue)
            cueAttr.font = .system(size: 17, weight: .bold)
            cueAttr.foregroundColor = Color(red: 1, green: 0.92, blue: 0.35)
            result.append(cueAttr)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            result.append(AttributedString(ns.substring(from: cursor)))
        }
        return result
    }
}

enum RundownTiming {
    /// Green while the live item has room, amber inside a minute, red inside the last 30 seconds.
    static func color(remaining: TimeInterval, total: TimeInterval) -> Color {
        if remaining <= 30 || (total > 0 && remaining / total <= 0.15) {
            return ProShowTheme.liveRed
        }
        if remaining <= 60 {
            return ProShowTheme.meterWarn
        }
        return ProShowTheme.meterSafe
    }
}

#if os(macOS)
/// Compact `.program` slide (canvas + browser) or legacy page raster for the rundown footer.
struct RundownProgramSlidePreview: View {
    @Bindable var controller: ShowController
    var slide: Slide?
    var canvasObjects: [CanvasObject] = []
    var pageURL: String?
    var showsCaption: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCameraCanvas: Bool {
        canvasObjects.contains { $0.kind == .videoInput || $0.assignedSource?.sourceType == .systemCamera }
    }

    private var caption: String {
        if let slide, !slide.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return slide.title
        }
        if let pageURL {
            return ProgramPageViewport.displayHost(for: pageURL)
        }
        return "Program slide"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsCaption {
                HStack(spacing: 4) {
                    Text("PROGRAM")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(RundownChrome.mutedLabel)
                        .tracking(0.5)
                    Text(caption)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                        .lineLimit(1)
                }
            }
            ZStack {
                if slide?.paintsOpaqueBackground == true {
                    Color(hex: slide?.backgroundHex ?? "#000000") ?? ProShowTheme.stageBlack
                } else if showsCameraCanvas || pageURL != nil {
                    Color.black
                } else if !canvasObjects.isEmpty {
                    DeskTransparencyGrid(cell: 4)
                } else {
                    Color.black
                }
                if let slide, !canvasObjects.isEmpty {
                    ProgramSlideThumbnailPreview(
                        controller: controller,
                        slide: slide,
                        objects: canvasObjects
                    )
                } else if let pageURL {
                    RundownProgramPagePreview(pageURL: pageURL)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                    .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
            )
        }
        .onAppear {
            warmPageRasterIfNeeded()
            warmCameraPreviewIfNeeded()
        }
        .onChange(of: pageURL) { _, _ in warmPageRasterIfNeeded() }
        .onChange(of: slide?.id) { _, _ in warmCameraPreviewIfNeeded() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Program slide preview")
        .accessibilityValue(caption)
    }

    private func warmPageRasterIfNeeded() {
        guard let pageURL else { return }
        ProgramPageRaster.shared.prefetch([pageURL])
    }

    private func warmCameraPreviewIfNeeded() {
        guard let slide, showsCameraCanvas else { return }
        controller.prepareSlidePreviewCapture(for: slide)
    }
}

private struct RundownProgramPagePreview: View {
    let pageURL: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion)) { _ in
            let raster = ProgramPageRaster.shared
            LivePixelPreview(
                pixelBuffer: raster.displayBuffer(for: pageURL),
                stamp: raster.presentationStamp,
                style: MediaFrameEngine.pageFitStyle,
                isPaused: reduceMotion
            )
        }
    }
}
#endif

enum RundownChrome {
    static let listBackground = ProShowTheme.panel
    static let detailBackground = ProShowTheme.canvas
    static let activeRow = ProShowTheme.accent.opacity(0.18)
    static let gridLine = ProShowTheme.hairline
    static let mutedLabel = ProShowTheme.secondaryLabel
    static let secondaryInk = ProShowTheme.primaryLabel
    static let noteInk = ProShowTheme.primaryLabel
    static let noteBand = ProShowTheme.well
}

enum RundownFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "0:%02d", s)
    }

    static func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: date).lowercased()
    }

    static func itemRunTime(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d:%02d", Int(seconds) / 3600, (Int(seconds) % 3600) / 60, Int(seconds) % 60)
    }
}

extension RundownBlock {
    var hasOperatorOutline: Bool {
        !screenDirections.isEmpty || !linkCues.isEmpty || !referenceNotes.isEmpty
    }
}

extension ScreenDirection {
    var kindTitle: String {
        switch kind {
        case .camera: "Camera"
        case .slide: "Slide"
        case .url: "URL"
        case .layout: "Layout"
        case .note: "Note"
        case .unknown: rawKind?.isEmpty == false ? rawKind! : "Other"
        }
    }

    var displayLabel: String {
        if let url, !url.isEmpty, !label.isEmpty, label != url {
            return "\(label)  \(url)"
        }
        if let url, !url.isEmpty { return url }
        return label
    }
}

extension LinkCue {
    var operatorFlags: String {
        let read = speakOnAir ? "Read" : "Skip"
        let take = autoTake ? "Auto" : "Manual"
        return "\(read) · \(take)"
    }
}
