import SwiftUI
import UniformTypeIdentifiers

extension WorkspaceDragPayload: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .plainText) { payload in
            WorkspaceDragPasteboard.active = payload
            return Data(payload.token.utf8)
        } importing: { data in
            let token = String(decoding: data, as: UTF8.self)
            return WorkspaceDragPayload.parse(token)
                ?? WorkspaceDragPayload(kind: .slide, id: token, name: token)
        }
        CodableRepresentation(contentType: .json)
    }
}

/// Center column: presentation context + slide grid / mode workspace.
struct SlideWorkspaceView: View {
    @Bindable var controller: ShowController
    @State private var mountedModes: Set<OperatorMode> = [.show]

    var body: some View {
        VStack(spacing: 0) {
            header
            if controller.isTextInspectorOpen {
                textInspector
            }
            workspace
        }
        .background(ProShowTheme.canvas)
        .overlay { DeskDropCatcher(controller: controller, role: .slides) }
        .onChange(of: controller.operatorMode, initial: true) { _, mode in
            switch mode {
            case .edit, .map:
                mountedModes.insert(.show)
            default:
                mountedModes.insert(mode)
            }
        }
    }

    private var header: some View {
        HStack(spacing: DeskSpace.xs) {
            Text(controller.selectedPlaylistItemTitle)
                .font(DeskType.title)
                .tracking(-0.2)
                .foregroundStyle(ProShowTheme.primaryLabel)
                .lineLimit(1)
            presentationTypeMenu
            Spacer(minLength: DeskSpace.sm)
            PaneLayoutToggle(
                gridOn: controller.slideLayoutMode == .grid,
                listOn: controller.slideLayoutMode == .list,
                onGrid: { controller.slideLayoutMode = .grid },
                onList: { controller.slideLayoutMode = .list }
            )
        }
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 10)
    }

    private var textInspector: some View {
        HStack(spacing: 12) {
            Text("Text")
                .font(.caption.weight(.bold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Label("San Serif", systemImage: "textformat")
                .font(.caption)
            Text("64 pt")
                .font(.caption.monospacedDigit())
            Text("Center")
                .font(.caption)
            Spacer()
            Text(controller.selectedTheme)
                .font(.caption)
                .foregroundStyle(ProShowTheme.secondaryLabel)
        }
        .foregroundStyle(ProShowTheme.toolbarIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var workspace: some View {
        ZStack {
            showWorkspace
                .opacity(showsShowWorkspace ? 1 : 0)
                .allowsHitTesting(showsShowWorkspace)
                .accessibilityHidden(!showsShowWorkspace)
            if mountedModes.contains(.bible) {
                bibleWorkspace
                    .opacity(controller.operatorMode == .bible ? 1 : 0)
                    .allowsHitTesting(controller.operatorMode == .bible)
                    .accessibilityHidden(controller.operatorMode != .bible)
            }
        }
    }

    private var showsShowWorkspace: Bool {
        switch controller.operatorMode {
        case .show, .edit, .map:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var showWorkspace: some View {
        switch controller.slideLayoutMode {
        case .grid:
            slideGrid
        case .list:
            slideList
        case .outline:
            slideOutline
        }
    }

    private var slideTileWidth: CGFloat {
        128 + CGFloat(controller.slideThumbZoom) * 180
    }

    /// `.program` stays in outline order. Other playlists can be reordered.
    private var allowsSlideReorder: Bool {
        controller.show.id != ProgramOutlinePresentation.showID
    }

    /// Same leading inset as the presentation title. The gap never grows to center a short row.
    private var slideGridGap: CGFloat { DeskSpace.sm }

    private func slideGridColumnCount(containerWidth: CGFloat) -> Int {
        let available = max(0, containerWidth - DeskSpace.sm * 2)
        let tile = slideTileWidth
        let gap = slideGridGap
        guard available >= tile else { return 1 }
        var count = 1
        while CGFloat(count + 1) * tile + CGFloat(count) * gap <= available {
            count += 1
        }
        return count
    }

    private var slideGrid: some View {
        GeometryReader { geo in
            let width = slideTileWidth
            let count = slideGridColumnCount(containerWidth: geo.size.width)
            let columns = Array(
                repeating: GridItem(.fixed(width), spacing: slideGridGap, alignment: .top),
                count: count
            )
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: slideGridGap) {
                    ForEach(controller.indexedCues) { cue in
                        // Selection and live state are read inside the cell, so a take only updates the
                        // cells, not the grid container (which re-laid out all 37 tiles on every take).
                        SlideGridCell(controller: controller, cue: cue)
                        .frame(width: width, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .contextMenu { SlideContextMenu(controller: controller, slideID: cue.slide.id) }
                        .onTapGesture(count: 2) { controller.goLive(slideID: cue.slide.id) }
                        .onTapGesture(count: 1) { controller.select(cue.slide.id) }
                        .cueDragAndDrop(controller: controller, slideID: cue.slide.id, enabled: allowsSlideReorder)
                    }
                }
                .padding(.horizontal, DeskSpace.sm)
                .padding(.vertical, DeskSpace.sm)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .paneDrop(controller: controller, enabled: allowsSlideReorder)
    }

    private var presentationTypeMenu: some View {
        Menu {
            ForEach(EditorCatalog.themeVariants, id: \.self) { name in
                Button {
                    controller.setPresentationContentType(name)
                } label: {
                    if controller.presentationContentType == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            DeskChip(text: controller.presentationContentType)
        }
        .menuStyle(.borderlessButton)
        .disabled(controller.show.id == ProgramOutlinePresentation.showID)
        .help("Slide theme")
        .accessibilityLabel("Slide theme")
        .accessibilityValue(controller.presentationContentType)
    }

    private var slideList: some View {
        List {
            ForEach(controller.indexedCues) { cue in
                HStack(spacing: 10) {
                    SlideThumbnailCard(
                        index: cue.number,
                        slide: cue.slide,
                        groupName: cue.group.name,
                        groupColor: cue.group.colorHex,
                        isSelected: cue.slide.id == controller.selectedSlideID,
                        isLive: controller.liveStack.isSlideActive(slideID: cue.slide.id),
                        mediaProjectRoot: controller.mediaProjectRoot,
                        controller: controller
                    )
                    .equatable()
                    .frame(width: 110 + CGFloat(controller.slideThumbZoom) * 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cue.group.name)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(ProShowTheme.groupColor(cue.group.colorHex))
                        Text(cue.slide.previewSummary)
                            .font(.subheadline)
                    }
                }
                .listRowBackground(cue.slide.id == controller.selectedSlideID ? ProShowTheme.well : Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowSeparator(.hidden)
                .contextMenu { SlideContextMenu(controller: controller, slideID: cue.slide.id) }
                .onTapGesture { controller.select(cue.slide.id) }
                .onTapGesture(count: 2) { controller.goLive(slideID: cue.slide.id) }
                .cueDragAndDrop(controller: controller, slideID: cue.slide.id, enabled: allowsSlideReorder)
                .moveDisabled(!allowsSlideReorder)
            }
            .onMove { offsets, destination in
                guard allowsSlideReorder else { return }
                controller.reorderCues(from: offsets, to: destination)
            }
        }
        .paneDrop(controller: controller, enabled: allowsSlideReorder)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, DeskSpace.sm, for: .scrollContent)
        .focusEffectDisabled()
    }

    private var slideOutline: some View {
        List {
            ForEach(controller.show.groups) { group in
                Section(group.name) {
                    ForEach(group.slides) { slide in
                        Text(slide.previewSummary)
                            .foregroundStyle(slide.id == controller.selectedSlideID ? .white : .primary)
                            .opacity(slide.isDisabled ? 0.4 : 1)
                            .listRowBackground(slide.id == controller.selectedSlideID ? ProShowTheme.accent : Color.clear)
                            .contextMenu { SlideContextMenu(controller: controller, slideID: slide.id) }
                            .onTapGesture { controller.select(slide.id) }
                        .cueDragAndDrop(controller: controller, slideID: slide.id, enabled: allowsSlideReorder)
                        .moveDisabled(!allowsSlideReorder)
                    }
                    .onMove { offsets, destination in
                        guard allowsSlideReorder else { return }
                        var ids = group.slides.map(\.id)
                        guard let first = offsets.first, ids.indices.contains(first) else { return }
                        let moving = ids[first]
                        ids.move(fromOffsets: offsets, toOffset: destination)
                        if let index = ids.firstIndex(of: moving), index + 1 < ids.count {
                            controller.moveSlide(moving, before: ids[index + 1])
                        } else {
                            controller.moveSlideToEnd(moving)
                        }
                    }
                }
            }
        }
        .paneDrop(controller: controller, enabled: allowsSlideReorder)
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focusEffectDisabled()
    }

    private var reflowWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            DeskSectionTitle(title: "Reflow")
            Text("Split on blank lines or word count, then generate slides.")
                .font(DeskType.body)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            TextEditor(text: $controller.reflowBuffer)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(ProShowTheme.well)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(minHeight: 140)
            Button("Generate slides") {
                controller.applyReflow()
            }
            .buttonStyle(.borderedProminent)
            List(controller.indexedCues) { cue in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(cue.number) · \(cue.group.name)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(ProShowTheme.groupColor(cue.group.colorHex))
                    Text(cue.slide.displayText.isEmpty ? cue.slide.title : cue.slide.displayText)
                        .font(.body)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focusEffectDisabled()
        }
        .padding(16)
    }

    private var bibleWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeskSectionTitle(title: "Bible")
            if BibleEngine.hasTranslationPackage {
                SearchFieldChrome(placeholder: "John 3:16", text: $controller.bibleQuery)
                ForEach(controller.bibleHits) { passage in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(passage.reference)
                            .font(.subheadline.weight(.semibold))
                        Text(passage.text)
                            .font(.callout)
                            .foregroundStyle(ProShowTheme.secondaryLabel)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ProShowTheme.well)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture { controller.triggerBible(passage) }
                }
            } else {
                Text("Install a .proshowbible translation package to enable scripture lookup.")
                    .font(.callout)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            Spacer()
        }
        .padding(16)
    }

    private var widgetsWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            DeskSectionTitle(title: "Widgets")
            ForEach(controller.chat.widgets.widgets) { widget in
                HStack {
                    Text(widget.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(widget.enabled ? "Live" : "Off")
                        .font(.caption)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                }
                .padding(10)
                .background(ProShowTheme.well)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            if let card = controller.chat.overlay, card.visible {
                Text("\(card.message.author): \(card.message.text)")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ProShowTheme.well)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Spacer()
        }
        .padding(16)
    }
}

/// One slide grid tile. Owns the reads of the selection and the live stack (isolated live state).
private struct SlideGridCell: View {
    let controller: ShowController
    let cue: IndexedCue

    var body: some View {
        SlideThumbnailCard(
            index: cue.number,
            slide: cue.slide,
            groupName: cue.group.name,
            groupColor: cue.group.colorHex,
            isSelected: cue.slide.id == controller.selectedSlideID,
            isLive: controller.liveStack.isSlideActive(slideID: cue.slide.id),
            mediaProjectRoot: controller.mediaProjectRoot,
            controller: controller
        )
        .equatable()
    }
}

struct SlideThumbnailCard: View, Equatable {
    let index: Int
    let slide: Slide
    var groupName: String = ""
    var groupColor: String = "#5B8DEF"
    let isSelected: Bool
    let isLive: Bool
    var mediaProjectRoot: URL? = nil
    var controller: ShowController? = nil

    var body: some View {
        let thumb = thumbnailRowPreview
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                if thumb.slide.isProgramMediaCue {
                    ProShowTheme.stageBlack
                } else if thumb.slide.paintsOpaqueBackground {
                    Color(hex: thumb.slide.backgroundHex) ?? ProShowTheme.stageBlack
                } else if thumb.slide.needsProgramLiveCameraPreview {
                    Color.black
                } else {
                    DeskTransparencyGrid(cell: 6)
                }

                if !thumb.canvas.isEmpty, let controller {
                    ProgramSlideThumbnailPreview(
                        controller: controller,
                        slide: thumb.slide,
                        objects: thumb.canvas
                    )
                    .clipped()
                } else if let pageURL = thumb.pageURL {
                    RundownSlidePageThumb(pageURL: pageURL)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if thumb.slide.showsLinkedProgramMediaUnderCanvas, let media = thumb.slide.mediaAction {
                    MediaPreviewFrame(
                        filePath: media.filePath,
                        artworkURL: media.resolvedFileURL(projectRoot: mediaProjectRoot),
                        kind: media.isImage ? .image : .video(duration: media.duration ?? ""),
                        tintHex: media.tintHex,
                        cornerRadius: 0
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !thumb.canvas.isEmpty {
                    ProgramSlideCanvas(
                        objects: thumb.canvas,
                        canvasWidth: CanvasConfig.width,
                        canvasHeight: CanvasConfig.height,
                        evaluationMode: .thumbnailPreview
                    )
                    .clipped()
                } else if !thumb.slide.isBlank, !thumb.slide.displayText.isEmpty {
                    Text(thumb.slide.displayText)
                        .font(DeskType.meta)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(ProShowTheme.lyricWhite)
                        .padding(DeskSpace.xs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .minimumScaleFactor(0.5)
                }

                Text("\(index)")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .padding(6)
                    .accessibilityHidden(true)

                if isLive {
                    Text(ProShowCopy.Status.live)
                        .font(DeskType.micro.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(ProShowTheme.liveRed, in: Capsule(style: .continuous))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(6)
                }
            }
            .aspectRatio(DeskLayout.programAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                    .strokeBorder(
                        isLive ? ProShowTheme.liveRed : (isSelected ? ProShowTheme.accent : ProShowTheme.hairline),
                        lineWidth: isLive || isSelected ? 2 : 1
                    )
            )

            HStack(spacing: 4) {
                DeskChip(
                    text: groupName.isEmpty ? "Group" : groupName,
                    color: ProShowTheme.groupColor(groupColor)
                )
                .opacity(groupName.isEmpty ? 0 : 1)
                Text(slide.label.isEmpty ? "Label" : slide.label)
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .opacity(slide.label.isEmpty ? 0 : 1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 20, alignment: .leading)
        }
        .opacity(slide.isDisabled ? 0.38 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(isLive ? "Live" : (slide.isDisabled ? "Disabled" : ""))
        .accessibilityHint("Drag to reposition")
    }

    static func == (lhs: SlideThumbnailCard, rhs: SlideThumbnailCard) -> Bool {
        lhs.index == rhs.index
            && lhs.slide == rhs.slide
            && lhs.groupName == rhs.groupName
            && lhs.groupColor == rhs.groupColor
            && lhs.isSelected == rhs.isSelected
            && lhs.isLive == rhs.isLive
            && lhs.mediaProjectRoot == rhs.mediaProjectRoot
    }

    private var thumbnailRowPreview: ProgramOutlineRowPreview {
        if let controller {
            return controller.slideGridThumbnailPreview(for: slide)
        }
        #if os(macOS)
        let pageURL = ProgramOutlinePresentation.pageURL(in: slide)
        #else
        let pageURL: String? = nil
        #endif
        return ProgramOutlineRowPreview(
            slide: slide,
            canvas: slide.audienceCanvas(),
            pageURL: pageURL
        )
    }

    private func programSlidePageURL(in slide: Slide) -> String? {
        #if os(macOS)
        ProgramOutlinePresentation.pageURL(in: slide)
        #else
        nil
        #endif
    }

    private var accessibilityName: String {
        if let pageURL = ProgramOutlinePresentation.pageURL(in: slide) {
            return "Slide \(index), web page, \(ProgramPageViewport.displayHost(for: pageURL))"
        }
        let body = slide.displayText.isEmpty ? slide.title : slide.displayText
        let extras = [groupName, slide.label].filter { !$0.isEmpty }.joined(separator: ", ")
        if extras.isEmpty {
            return "Slide \(index), \(body)"
        }
        return "Slide \(index), \(extras), \(body)"
    }
}

#if os(macOS)
private struct RundownSlidePageThumb: View {
    let pageURL: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: reduceMotion)) { _ in
            let raster = ProgramPageRaster.shared
            ZStack {
                Color.black
                LivePixelPreview(
                    pixelBuffer: raster.displayBuffer(for: pageURL),
                    stamp: raster.presentationStamp,
                    style: MediaFrameEngine.pageFitStyle,
                    isPaused: reduceMotion
                )
            }
        }
    }
}
#endif

private struct CueDragAndDropModifier: ViewModifier {
    let controller: ShowController
    let slideID: SlideID
    var enabled: Bool = true
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if enabled {
            draggable(content)
        } else {
            content
        }
    }

    private func draggable(_ content: Content) -> some View {
        content
            .workspaceDraggable(
                WorkspaceDragPayload.slide(
                    id: slideID,
                    title: controller.show.slide(id: slideID)?.title ?? "Slide"
                ),
                controller: controller
            )
            .dropDestination(for: WorkspaceDragPayload.self) { items, _ in
                guard let item = items.first else { return false }
                switch item.kind {
                case .media:
                    return controller.applyWorkspaceDrop(item, insertAfter: slideID)
                default:
                    return controller.applyWorkspaceDrop(item, before: slideID)
                }
            } isTargeted: {
                isTargeted = $0
            }
            .overlay(alignment: .leading) {
                if isTargeted {
                    Capsule(style: .continuous)
                        .fill(ProShowTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 2)
                        .offset(x: -6)
                }
            }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                        .fill(ProShowTheme.accent.opacity(0.12))
                }
            }
    }
}

private struct PaneDropModifier: ViewModifier {
    let controller: ShowController
    var enabled: Bool = true

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: WorkspaceDragPayload.self) { items, _ in
                guard let item = items.first else { return false }
                return controller.applyWorkspaceDrop(item, before: nil)
            }
        } else {
            content
        }
    }
}

extension View {
    func cueDragAndDrop(controller: ShowController, slideID: SlideID, enabled: Bool = true) -> some View {
        modifier(CueDragAndDropModifier(controller: controller, slideID: slideID, enabled: enabled))
    }

    func paneDrop(controller: ShowController, enabled: Bool = true) -> some View {
        modifier(PaneDropModifier(controller: controller, enabled: enabled))
    }

    func workspaceDraggable(_ payload: WorkspaceDragPayload, controller: ShowController) -> some View {
        modifier(WorkspaceDraggableModifier(payload: payload, controller: controller))
    }
}

private struct WorkspaceDraggableModifier: ViewModifier {
    let payload: WorkspaceDragPayload
    let controller: ShowController

    func body(content: Content) -> some View {
        #if os(macOS)
        if payload.kind == .slide {
            content.draggable(payload)
        } else {
            content
                .draggable(payload)
                .onDrag {
                    controller.beginWorkspaceDrag(payload)
                    return NSItemProvider(object: payload.token as NSString)
                }
        }
        #else
        content.draggable(payload)
        #endif
    }
}

struct SlideContextMenu: View {
    @Bindable var controller: ShowController
    let slideID: SlideID

    var body: some View {
        Button("Quick Edit") { controller.quickEditSlide(id: slideID) }
        Button("Edit Slide") { controller.editSlide(id: slideID) }
        Button(slide?.isDisabled == true ? "Enable" : "Disable") {
            controller.toggleSlideDisabled(id: slideID)
        }
        if let media = slide?.mediaAction, !media.clearsLayer {
            Toggle("Hold Media", isOn: Binding(
                get: { media.hold },
                set: { value in controller.mutateSlide(id: slideID) { $0.mediaAction?.hold = value } }
            ))
            .help("Keeps playing across slides.")
        }

        #if os(macOS)
        if controller.browserPageURL(for: slideID) != nil {
            Divider()
            Menu("Web Page") {
                Button("Refresh Page") {
                    controller.refreshSlideBrowserPage(slideID: slideID)
                }
            }
        }
        #endif

        Divider()

        Menu("Themes") {
            ForEach(controller.themeMenuVariants, id: \.id) { variant in
                Button(variant.name) { controller.applyThemeVariant(variant, to: slideID) }
            }
            Divider()
            Menu("Apply to All Slides in Show") {
                ForEach(controller.themeMenuVariants, id: \.id) { variant in
                    Button(variant.name) {
                        controller.applyThemeVariantToAllSlidesInShow(variant)
                    }
                }
            }
            Menu("Apply to Group") {
                ForEach(controller.themeMenuVariants, id: \.id) { variant in
                    Button(variant.name) {
                        controller.applyThemeVariantToGroup(containing: slideID, variant: variant)
                    }
                }
            }
        }
        Menu("Transitions...") {
            ForEach(DeskSampleData.slideTransitions, id: \.self) { name in
                Button(name) { controller.setSlideTransition(name, id: slideID) }
            }
        }
        Menu("Hot Key...") {
            Button("None") { controller.setSlideHotKey("", id: slideID) }
            ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init), id: \.self) { key in
                Button(key) { controller.setSlideHotKey(key, id: slideID) }
            }
        }
        Menu("Go to Next Timer...") {
            Button("None") { controller.setSlideNextTimer("", id: slideID) }
            if controller.compositor.stack.timers.isEmpty {
                Button("Timer 1") { controller.setSlideNextTimer("Timer 1", id: slideID) }
            } else {
                ForEach(controller.compositor.stack.timers) { timer in
                    Button(timer.name) { controller.setSlideNextTimer(timer.name, id: slideID) }
                }
            }
        }

        Divider()

        Menu("Add Action") {
            ForEach(DeskSampleData.slideActions, id: \.self) { action in
                Button(action) { controller.addSlideAction(action, id: slideID) }
            }
        }
        Button("Add Media Action...") { controller.addMediaAction(to: slideID) }

        Menu("Group") {
            ForEach(controller.show.groups, id: \.id) { group in
                Button(group.name) { controller.moveSlide(slideID, toGroupNamed: group.name) }
            }
            Divider()
            Button("New Group") { controller.moveSlide(slideID, toGroupNamed: "Group \(controller.show.groups.count + 1)") }
        }
        Menu("Label") {
            Button("None") { controller.setSlideLabel("", id: slideID) }
            ForEach(DeskSampleData.slideLabels, id: \.self) { label in
                Button(label) { controller.setSlideLabel(label, id: slideID) }
            }
        }

        Divider()

        Button("Copy Text Style") { controller.copySlideTextStyle(id: slideID) }
        Button("Paste Text Style") { controller.pasteSlideTextStyle(id: slideID) }
            .disabled(!controller.canPasteSlideStyle)

        Divider()

        Button("Cut") { controller.cutSlides([slideID]) }
        Button("Copy") { controller.copySlides([slideID]) }
        Button("Paste") { controller.pasteSlides(after: slideID) }
            .disabled(!controller.canPasteSlides)
        Button("Delete", role: .destructive) { controller.deleteSlides([slideID]) }
    }

    private var slide: Slide? { controller.show.slide(id: slideID) }
}
