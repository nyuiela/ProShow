import SwiftUI
#if os(macOS)
import AppKit
#endif

@Observable
final class CanvasLiveDragSession {
    var offset: CGSize = .zero
    var pan: CGSize = .zero
}

private struct CanvasLiveOffsetModifier: ViewModifier {
    @Bindable var session: CanvasLiveDragSession
    var applies: Bool

    func body(content: Content) -> some View {
        content
            .offset(applies ? session.offset : .zero)
            .transaction { $0.animation = nil }
    }
}

private struct CanvasLivePanModifier: ViewModifier {
    @Bindable var session: CanvasLiveDragSession
    var originX: CGFloat
    var originY: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(x: originX + session.pan.width, y: originY + session.pan.height)
            .transaction { $0.animation = nil }
    }
}

private struct LiveOriginRuler: View {
    @Bindable var session: CanvasLiveDragSession
    var axis: Axis
    var scale: Double
    var origin: Double
    var majorTick: Double
    var minorTick: Double

    var body: some View {
        let extra = axis == .horizontal ? session.pan.width : session.pan.height
        InfinitePaneRuler(
            axis: axis,
            scale: scale,
            origin: origin + extra,
            majorTick: majorTick,
            minorTick: minorTick
        )
        .transaction { $0.animation = nil }
    }
}

/// Shared 3-pane canvas chrome used by every specialized editor.
struct CanvasEditorView: View {
    @Bindable var controller: ShowController
    @State private var workspaceSize: CGSize = .zero
    @State private var fittedDocumentID: EditorKind?
    @State private var pinchStartZoom: Double?
    @State private var isPanning = false
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var liveDrag = CanvasLiveDragSession()
    @State private var liveGlowPulse = false
    @State private var mouseTracker = CanvasEditorMouseTracker()
    @State private var rulerDraggingGuideID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var editor: EditorEngine { controller.editors }
    var body: some View {
        let _ = editor.documents
        let _ = editor.selectedObjectIDs
        let _ = editor.selectedDocumentID
        let _ = editor.activeCanvasID
        let _ = editor.liveHandleBounds
        let _ = editor.guideLines.isInteracting
        let _ = editor.guideLines.draggingGuideLivePosition
        let _ = controller.inspector.timers.map { "\($0.id)-\($0.displaySeconds)-\($0.isRunning)-\($0.durationSeconds)" }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: max(DeskLayout.sidebar, DeskLayout.sidebarMin))
                    .background(ProShowTheme.panel)
                canvasStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                EditorInspectorView(controller: controller)
                    .frame(width: InspectorTokens.panelWidth)
            }
            statusBar
                .background(EnvironmentChurnProbe(name: "env.editor"))
        }
        .background(ProShowTheme.canvas)
        .lockFlickerFreeBackground()
        .background {
            let _ = controller.liveQuotePresentationStamp
            Color.clear
        }
        .environment(\.dynamicTextSource, controller.environmentHandles.editorText)
        .environment(\.liveQuoteEngine, controller.liveQuotes)
        .environment(\.proShowVideoInputs, controller.videoInputs)
        .environment(\.proShowProgramVideoInput, editorCameraPreviewInput)
        .environment(\.buildClock, controller.editorBuildClock())
        .environment(\.animationEvaluationMode, controller.isCanvasEditorPresented ? controller.editorAnimationMode() : .thumbnailPreview)
        .environment(\.buildPhaseFilter, controller.editorBuildPhaseFilter())
        // Same copied program frame as Audience. A second AVPlayerLayer stalls the decoder after a few seconds.
        .environment(\.mirrorsProgramPlayer, true)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear {
            if controller.isCanvasEditorPresented { mouseTracker.attach() }
            warmEditorCameraPreview()
        }
        .onChange(of: editor.selectedDocumentID) { _, _ in
            warmEditorCameraPreview()
        }
        .onDisappear { mouseTracker.detach() }
        .onChange(of: controller.isCanvasEditorPresented, initial: true) { _, visible in
            if visible { mouseTracker.attach() } else { mouseTracker.detach() }
        }
        .onChange(of: editor.selectedObjectIDs) { _, _ in
            mouseTracker.refresh(editor: editor)
        }
        .onChange(of: mouseTracker.isOptionHeld) { _, _ in
            mouseTracker.refresh(editor: editor)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            SidebarTitleGroupSlot {
                WorkspaceTitleGroup(controller: controller)
            }
            header
            itemList
                .frame(maxHeight: .infinity)
            Rectangle()
                .fill(ProShowTheme.hairline)
                .frame(height: DeskPaneDivider.width)
            objectsTree
                .frame(height: 228)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerTitle)
                .font(DeskType.bodyEmph)
                .lineLimit(1)
            Spacer()
            DeskIconButton(systemImage: "plus", label: "Add item") {
                addSidebarItem()
            }
        }
        .foregroundStyle(ProShowTheme.toolbarIcon)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ProShowTheme.well.opacity(0.45))
    }

    private var headerTitle: String {
        switch editor.kind {
        case .presentation: controller.selectedPlaylistItemTitle
        case .theme: editor.themeCollection
        case .props: editor.selectedDocument?.collectionName ?? "Default Collection"
        case .stage: "Stage Layouts"
        case .ccli: "Copyright"
        case .masks: "Masks"
        case .overlays: "Overlays"
        case nil: editor.kind?.title ?? "Editor"
        }
    }

    private var itemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if editor.kind == .theme {
                    Picker("Collection", selection: Binding(
                        get: { editor.themeCollection },
                        set: { editor.themeCollection = $0 }
                    )) {
                        ForEach(Array(Set(controller.themePacksStorage.map(\.collectionName))).sorted(), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                }
                ForEach(Array(editor.documents.enumerated()), id: \.element.id) { index, document in
                    Button {
                        editor.selectDocument(document.id)
                        if let slideID = document.slideID {
                            controller.select(slideID)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            if editor.kind == .presentation {
                                let slide = document.slideID.flatMap { controller.show.slide(id: $0) }
                                EditorSlideThumbnail(
                                    document: document,
                                    selected: document.id == editor.selectedDocumentID,
                                    mediaProjectRoot: controller.mediaProjectRoot,
                                    linkedMedia: slide?.showsLinkedProgramMediaUnderCanvas == true
                                    ? slide.flatMap { controller.resolvedAssociatedMedia(for: $0) }
                                    : nil,
                                    controller: controller,
                                    slide: slide
                                )
                            }
                            Text(editor.kind == .presentation ? "\(index + 1). \(document.name)" : document.name)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(document.id == editor.selectedDocumentID ? ProShowTheme.well : Color.clear)
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var objectsTree: some View {
        EditorObjectsTree(editor: editor, controller: controller)
    }

    /// Same camera the slide thumbnail paints, so the artboard is not an empty video well.
    private var editorCameraPreviewInput: VideoInputSource? {
        guard editor.kind == .presentation, let document = editor.selectedDocument else { return nil }
        let hostsCamera = document.objects.contains {
            $0.kind == .videoInput || $0.rendersLiveVideoInputOnCanvas
        }
        guard hostsCamera, let slideID = document.slideID, let slide = controller.show.slide(id: slideID) else {
            return nil
        }
        return controller.previewVideoInput(for: slide, forThumbnail: true)
    }

    private func warmEditorCameraPreview() {
        guard let slideID = editor.selectedDocument?.slideID,
              let slide = controller.show.slide(id: slideID),
              slide.needsProgramLiveCameraPreview
                || editor.selectedDocument?.objects.contains(where: { $0.kind == .videoInput }) == true
        else { return }
        controller.prepareSlidePreviewCapture(for: slide)
    }

    private var canvasStage: some View {
        ZStack(alignment: .top) {
            Color(red: 0.31, green: 0.31, blue: 0.33)
            canvasBoard
            floatingToolbar
                .padding(.top, 28)
            if controller.isEditingLiveSlide {
                liveEditorIsland
                    .padding(.top, 8)
            }
        }
        .overlay {
            if controller.isEditingLiveSlide {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(islandAccent.opacity(liveBorderOpacity), lineWidth: 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay { DeskDropCatcher(controller: controller, role: .editor) }
        .onChange(of: controller.isEditingLiveSlide) { _, isLive in
            startLiveGlow(isLive)
        }
        .onChange(of: controller.isEditorLockedToLive) { _, _ in
            startLiveGlow(controller.isEditingLiveSlide)
        }
        .onAppear { startLiveGlow(controller.isEditingLiveSlide) }
    }

    private var islandAccent: Color {
        controller.isEditingLiveSlide ? ProShowTheme.liveRed : ProShowTheme.secondaryLabel
    }

    private var liveBorderOpacity: Double {
        if reduceMotion { return 0.72 }
        return liveGlowPulse ? 0.88 : 0.38
    }

    private func startLiveGlow(_ isLive: Bool) {
        guard isLive, !reduceMotion else {
            liveGlowPulse = false
            return
        }
        liveGlowPulse = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            liveGlowPulse = true
        }
    }

    private var liveEditorIsland: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(islandAccent)
                .frame(width: 8, height: 8)
            Text(controller.isEditingLiveSlide ? "PROGRAM EDIT" : "SLIDE EDIT")
                .font(DeskType.micro)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.72))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(islandAccent.opacity(0.55), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(controller.isEditingLiveSlide ? "Editing live program slide" : "Editing slide")
    }

    private var canvasBoard: some View {
        GeometryReader { proxy in
            let document = editor.selectedDocument
            let width = document?.canvasWidth ?? CanvasConfig.width
            let height = document?.canvasHeight ?? CanvasConfig.height
            let metrics = CanvasConfig.metrics(width: width, height: height)
            let workspace = CGSize(width: max(0, proxy.size.width - 24), height: max(0, proxy.size.height - 20))
            let scale = editor.zoom
            let canvasW = width * scale
            let canvasH = height * scale
            let originX = (workspace.width - canvasW) / 2 + editor.canvasPanX
            let originY = (workspace.height - canvasH) / 2 + editor.canvasPanY
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ProShowTheme.panel.frame(width: 24, height: 20)
                    CanvasRulerView(
                        axis: .horizontal,
                        scale: scale,
                        origin: originX + liveDrag.pan.width,
                        majorTick: metrics.majorTick,
                        minorTick: metrics.minorTick,
                        isActive: editor.guideLines.spawnAxis == .horizontal || rulerDraggingGuideOnHorizontalRuler,
                        userGuides: editor.userGuides.filter { $0.axis == .vertical }
                    )
                    .frame(width: workspace.width, height: 20)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        userGuideWorkbenchGesture(
                            scale: scale,
                            originX: originX,
                            originY: originY,
                            canvasWidth: width,
                            canvasHeight: height,
                            startMode: .horizontalRulerBand
                        )
                    )
                }
                HStack(spacing: 0) {
                    CanvasRulerView(
                        axis: .vertical,
                        scale: scale,
                        origin: originY + liveDrag.pan.height,
                        majorTick: metrics.majorTick,
                        minorTick: metrics.minorTick,
                        isActive: editor.guideLines.spawnAxis == .vertical || rulerDraggingGuideOnVerticalRuler,
                        userGuides: editor.userGuides.filter { $0.axis == .horizontal }
                    )
                    .frame(width: 24, height: workspace.height)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        userGuideWorkbenchGesture(
                            scale: scale,
                            originX: originX,
                            originY: originY,
                            canvasWidth: width,
                            canvasHeight: height,
                            startMode: .verticalRulerBand
                        )
                    )
                    workspacePane(
                        document: document,
                        canvasWidth: width,
                        canvasHeight: height,
                        gridStep: metrics.gridStep,
                        scale: scale,
                        originX: originX,
                        originY: originY,
                        workspace: workspace
                    )
                    .frame(width: workspace.width, height: workspace.height)
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        if editor.gridConfig.showCanvasMinimap {
                            CanvasMinimapView(
                                canvasSize: CGSize(width: width, height: height),
                                objects: document?.objects ?? [],
                                currentZoom: CGFloat(scale),
                                viewportOriginCanvas: viewportOriginCanvas(
                                    originX: originX,
                                    originY: originY,
                                    scale: scale
                                ),
                                paneSize: workspace,
                                onNavigate: { point in
                                    editor.centerViewportOn(
                                        canvasX: Double(point.x),
                                        canvasY: Double(point.y),
                                        paneWidth: workspace.width,
                                        paneHeight: workspace.height,
                                        canvasWidth: width,
                                        canvasHeight: height
                                    )
                                }
                            )
                            .padding(10)
                            .fixedSize()
                        }
                    }
                    .onAppear {
                        fittedDocumentID = nil
                        rememberAndFit(session: editor.kind, workspace: workspace, canvasWidth: width, canvasHeight: height)
                    }
                    .onChange(of: editor.kind) { _, kind in
                        rememberAndFit(session: kind, workspace: workspace, canvasWidth: width, canvasHeight: height)
                    }
                    .onChange(of: workspace) { _, size in
                        workspaceSize = size
                        if fittedDocumentID == nil {
                            rememberAndFit(session: editor.kind, workspace: size, canvasWidth: width, canvasHeight: height)
                        }
                    }
                }
            }
            .coordinateSpace(name: "canvasWorkbench")
            .overlay {
                if editor.guideLines.isInteracting || rulerDraggingGuideID != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            userGuideWorkbenchGesture(
                                scale: scale,
                                originX: originX,
                                originY: originY,
                                canvasWidth: width,
                                canvasHeight: height,
                                startMode: .continuationOnly
                            )
                        )
                }
            }
            #if os(macOS)
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .left: editor.nudgeSelected(dx: -1, dy: 0)
                case .right: editor.nudgeSelected(dx: 1, dy: 0)
                case .up: editor.nudgeSelected(dx: 0, dy: -1)
                case .down: editor.nudgeSelected(dx: 0, dy: 1)
                default: break
                }
            }
            .onDeleteCommand {
                editor.deleteSelected()
            }
            #endif
        }
    }

    private func workspacePane(
        document: EditorDocument?,
        canvasWidth: Double,
        canvasHeight: Double,
        gridStep: Double,
        scale: Double,
        originX: Double,
        originY: Double,
        workspace: CGSize
    ) -> some View {
        let canvasOrigin = CGPoint(
            x: CanvasEditorScreenAlign.screenPoint(originX + liveDrag.pan.width),
            y: CanvasEditorScreenAlign.screenPoint(originY + liveDrag.pan.height)
        )
        let primaryShowsGrid = document.flatMap { editor.canvasBoards(in: $0).first(where: \.isPrimary)?.showsGrid } ?? true
        var pasteboardGrid = editor.gridConfig
        pasteboardGrid.isGridVisible = primaryShowsGrid
        let viewport = workspace
        return ZStack(alignment: .topLeading) {
            Color(red: 0.31, green: 0.31, blue: 0.33)
                .frame(width: viewport.width, height: viewport.height)
            CanvasWorkbenchGuideOverlay(
                gridConfig: pasteboardGrid,
                snapState: editor.layoutSnapState,
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                scale: CGFloat(scale),
                viewportSize: viewport,
                canvasOrigin: canvasOrigin
            )
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(width: viewport.width, height: viewport.height)
                    .contentShape(Rectangle())
                    .onTapGesture { editor.clearObjectSelection() }
                    .gesture(workspacePan)
                    .contextMenu { CanvasBlankContextMenu(editor: editor, controller: controller) }
                canvasBoards(
                    document: document,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    gridStep: gridStep,
                    scale: scale,
                    originX: originX,
                    originY: originY
                )
                .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            }
            .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
            .clipped()
            CanvasUserGuideViewportOverlay(
                viewportSize: viewport,
                canvasOrigin: canvasOrigin,
                scale: CGFloat(scale),
                userGuides: displayedUserGuides,
                spawnPreview: guideSpawnPreview(
                    axis: editor.guideLines.spawnAxis,
                    position: editor.guideLines.spawnPreviewPosition
                )
            )
            .frame(width: viewport.width, height: viewport.height)
            CanvasFloatingContextBarLayer(
                editor: editor,
                scale: scale,
                canvasOrigin: CGPoint(
                    x: originX + editor.selectionFrameOrigin().x * scale,
                    y: originY + editor.selectionFrameOrigin().y * scale
                ),
                panOffset: liveDrag.pan,
                viewportSize: viewport
            )
            .frame(width: viewport.width, height: viewport.height)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        .coordinateSpace(name: "editorWorkspace")
        .simultaneousGesture(workspaceMagnify(canvasWidth: canvasWidth, canvasHeight: canvasHeight, workspace: workspace))
    }

    private var workspacePan: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("editorWorkspace"))
            .onChanged { value in
                beginLivePanIfNeeded()
                liveDrag.pan = value.translation
            }
            .onEnded { _ in
                commitLivePan()
            }
    }

    private func workspaceMagnify(canvasWidth: Double, canvasHeight: Double, workspace: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartZoom == nil {
                    pinchStartZoom = editor.zoom
                }
                editor.setZoom(
                    (pinchStartZoom ?? editor.zoom) * Double(value.magnification),
                    focusX: value.startLocation.x,
                    focusY: value.startLocation.y,
                    paneWidth: workspace.width,
                    paneHeight: workspace.height,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight
                )
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private func rememberAndFit(session: EditorKind?, workspace: CGSize, canvasWidth: Double, canvasHeight: Double) {
        workspaceSize = workspace
        editor.lastPaneWidth = workspace.width
        editor.lastPaneHeight = workspace.height
        guard workspace.width > 8, workspace.height > 8 else { return }
        guard fittedDocumentID != session else { return }
        editor.fitToView(
            paneWidth: workspace.width,
            paneHeight: workspace.height,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight
        )
        fittedDocumentID = session
    }

    private func zoomAroundCenter(_ newZoom: Double) {
        let document = editor.selectedDocument
        editor.setZoom(
            newZoom,
            focusX: workspaceSize.width / 2,
            focusY: workspaceSize.height / 2,
            paneWidth: max(workspaceSize.width, 1),
            paneHeight: max(workspaceSize.height, 1),
            canvasWidth: document?.canvasWidth ?? CanvasConfig.width,
            canvasHeight: document?.canvasHeight ?? CanvasConfig.height
        )
    }

    private func fitWorkspace() {
        let document = editor.selectedDocument
        editor.fitToView(
            paneWidth: max(workspaceSize.width, 1),
            paneHeight: max(workspaceSize.height, 1),
            canvasWidth: document?.canvasWidth ?? CanvasConfig.width,
            canvasHeight: document?.canvasHeight ?? CanvasConfig.height
        )
    }

    private func canvasBoards(
        document: EditorDocument?,
        canvasWidth: Double,
        canvasHeight: Double,
        gridStep: Double,
        scale: Double,
        originX: Double,
        originY: Double
    ) -> some View {
        let boards = document.map { editor.canvasBoards(in: $0) } ?? [
            EditorCanvasFrame(
                id: UUID(),
                name: "Desktop",
                width: canvasWidth,
                height: canvasHeight,
                originX: 0,
                originY: 0,
                isPrimary: true
            )
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(boards) { board in
                let drag = draggingCanvasID == board.id ? canvasDragTranslation : .zero
                let screenX = originX + board.originX * scale + liveDrag.pan.width + drag.width
                let screenY = originY + board.originY * scale + liveDrag.pan.height + drag.height
                let boardW = board.width * scale
                let boardH = board.height * scale
                let selected = document.map { editor.isCanvasActive(board, in: $0) } ?? board.isPrimary
                let objects = board.isPrimary ? (document?.objects ?? []) : board.objects
                let propPhone = document.map { $0.kind == .props && EditorEngine.isPropPhoneBoard(board, of: $0) } ?? false
                let propPhoneDerived = propPhone && document?.propPhoneMode != .custom
                canvasSurface(
                    canvasWidth: board.width,
                    canvasHeight: board.height,
                    gridStep: gridStep,
                    scale: scale,
                    canvasW: boardW,
                    canvasH: boardH,
                    originX: originX + board.originX * scale,
                    originY: originY + board.originY * scale,
                    board: board,
                    objects: objects
                )
                .frame(width: boardW, height: boardH, alignment: .topLeading)
                .opacity(propPhoneDerived ? 0.45 : 1)
                .allowsHitTesting(!propPhoneDerived)
                .overlay(alignment: .bottomLeading) {
                    if propPhone, let document {
                        propPhoneControls(document)
                            .offset(y: 40)
                            .fixedSize()
                    }
                }
                .overlay {
                    Rectangle()
                        .strokeBorder(selected ? ProShowTheme.accent : Color.white.opacity(0.35), lineWidth: selected ? 2 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .overlay(alignment: .topLeading) {
                    canvasFrameLabel(board, selected: selected, scale: scale)
                        .offset(y: -28)
                        .fixedSize()
                }
                .offset(x: CanvasEditorScreenAlign.screenPoint(screenX), y: CanvasEditorScreenAlign.screenPoint(screenY))
            }
        }
    }

    /// Phone canvas of a prop: Linked follows Stream, Custom is edited here, Hidden skips Phone.
    private func propPhoneControls(_ document: EditorDocument) -> some View {
        HStack(spacing: 8) {
            Picker("Phone", selection: Binding(
                get: { document.propPhoneMode },
                set: { editor.setPropPhoneMode($0, documentID: document.id) }
            )) {
                ForEach(PropPhoneMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            if document.propPhoneMode == .linked {
                Button("Customise for Phone") {
                    editor.setPropPhoneMode(.custom, documentID: document.id)
                    editor.selectCanvas(EditorEngine.propPhoneBoardID(for: document.id))
                }
                .controlSize(.small)
            }
            Text(document.propPhoneMode == .linked ? "Auto-fit from Stream" : (document.propPhoneMode == .hidden ? "Not on Phone" : "Own Phone layout"))
                .font(DeskType.micro)
                .foregroundStyle(.white.opacity(0.75))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.78)))
    }

    private func canvasFrameLabel(_ board: EditorCanvasFrame, selected: Bool, scale: Double) -> some View {
        let pixels = "\(Int(board.width.rounded())) × \(Int(board.height.rounded()))"
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text("\(board.name)  \(pixels)")
                .font(DeskType.micro)
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(selected ? ProShowTheme.accent : Color.white.opacity(0.28), lineWidth: 1)
                }
        }
        .contentShape(Capsule())
        .onTapGesture { editor.selectCanvas(board.id) }
        .highPriorityGesture(canvasMoveGesture(board, scale: scale))
        .help("Drag \(board.name)")
        .accessibilityLabel("\(board.name) canvas")
        .accessibilityValue("\(pixels). Drag to move.")
        .accessibilityAddTraits(.isButton)
    }

    private func canvasMoveGesture(_ board: EditorCanvasFrame, scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("editorWorkspace"))
            .onChanged { value in
                draggingCanvasID = board.id
                canvasDragTranslation = value.translation
            }
            .onEnded { value in
                let dx = Double(value.translation.width) / max(scale, 0.0001)
                let dy = Double(value.translation.height) / max(scale, 0.0001)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    editor.moveCanvas(id: board.id, dx: dx, dy: dy)
                    canvasDragTranslation = .zero
                    draggingCanvasID = nil
                }
            }
    }

    private func canvasSurface(
        canvasWidth: Double,
        canvasHeight: Double,
        gridStep: Double,
        scale: Double,
        canvasW: Double,
        canvasH: Double,
        originX: CGFloat,
        originY: CGFloat,
        board: EditorCanvasFrame,
        objects: [CanvasObject]
    ) -> some View {
        let sorted = objects.sorted { $0.zIndex > $1.zIndex }
        let showsTransparency = board.showsCheckerboard || !board.backgroundEnabled
        return canvasBackdrop(scale: scale, showsTransparency: showsTransparency, backgroundEnabled: board.backgroundEnabled, backgroundHex: board.backgroundHex, hostsProgramMedia: board.isPrimary)
            .frame(width: canvasW, height: canvasH)
            .contextMenu { CanvasBlankContextMenu(editor: editor, controller: controller) }
            .overlay(alignment: .topLeading) {
                PulsedBuildEnvironment(
                    isActive: controller.editorFollowsLiveBuilds,
                    clock: { controller.editorBuildClock() }
                ) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            canvasBlankGesture(
                                scale: scale,
                                canvasWidth: canvasWidth,
                                canvasHeight: canvasHeight,
                                originX: originX,
                                originY: originY,
                                canvasID: board.id
                            )
                        )
                        .contextMenu { CanvasBlankContextMenu(editor: editor, controller: controller) }
                    if board.showsGrid {
                        CanvasArtboardGridView(
                            gridConfig: editor.gridConfig,
                            canvasWidth: canvasWidth,
                            canvasHeight: canvasHeight,
                            scale: CGFloat(scale)
                        )
                    }
                    CanvasCenterOriginMark()
                        .frame(width: canvasW, height: canvasH)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    ForEach(sorted.reversed()) { object in
                        CanvasObjectView(
                            editor: editor,
                            object: object,
                            canvasObjects: sorted,
                            slideSteps: objects.flatMap(\.resolvedBuildSteps),
                            scale: scale,
                            selected: editor.selectedObjectIDs.contains(object.id),
                            editing: editor.inlineEditID == object.id,
                            onEdit: { editor.setInlineText($0, id: object.id) },
                            onCommit: { editor.commitInlineText($0, id: object.id) }
                        )
                        .modifier(CanvasLiveOffsetModifier(
                            session: liveDrag,
                            applies: editor.selectedObjectIDs.contains(object.id)
                        ))
                        .contextMenu { CanvasObjectContextMenu(editor: editor, controller: controller, objectID: object.id) }
                        .gesture(objectDrag(object.id, scale: scale))
                        .onTapGesture(count: 2) {
                            if object.groupID != nil, editor.isolatedObjectID != object.id {
                                editor.isolateObject(object.id)
                            } else if object.isTextLike {
                                editor.beginInlineEdit(id: object.id)
                            }
                        }
                        .onTapGesture {
                            editor.activeCanvasID = board.id
                            editor.selectObject(
                                object.id,
                                additive: EditorObjectTreeModifiers.shiftHeld || EditorObjectTreeModifiers.commandHeld
                            )
                        }
                    }
                    let isEditingBoard = editor.activeCanvasID == board.id || (editor.activeCanvasID == nil && board.isPrimary)
                    if isEditingBoard, editor.showsCompoundChrome, let box = editor.selectionBounds {
                        CompoundSelectionChromeView(editor: editor, bounds: box, scale: scale)
                            .modifier(CanvasLiveOffsetModifier(session: liveDrag, applies: true))
                    } else if isEditingBoard {
                        ForEach(editor.selectedObjects) { object in
                            SelectionChromeView(editor: editor, object: object, scale: scale)
                                .modifier(CanvasLiveOffsetModifier(session: liveDrag, applies: true))
                        }
                    }
                    if isEditingBoard, let parent = editor.isolatedParentBounds {
                        GroupIsolationOutline(bounds: parent, scale: scale)
                    }
                    if isEditingBoard, let marquee = canvasMarqueeRect {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(ProShowTheme.accent.opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .strokeBorder(ProShowTheme.accent, lineWidth: 1)
                            }
                            .frame(width: max(1, marquee.width), height: max(1, marquee.height))
                            .offset(x: marquee.minX, y: marquee.minY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    BroadcastFrameGuideView(
                        documentSize: CGSize(width: canvasWidth, height: canvasHeight),
                        scale: CGFloat(scale),
                        showSafeAreas: board.showsSafeAreas,
                        showHeaderFooterGuides: board.showsHeaderFooter,
                        showColumnGrid: board.showsColumnGrid
                    )
                    .frame(width: canvasW, height: canvasH)
                    CanvasGuideOverlayView(
                        gridConfig: editor.gridConfig,
                        snapState: editor.layoutSnapState,
                        canvasWidth: canvasWidth,
                        canvasHeight: canvasHeight,
                        scale: scale,
                        workbenchGuidesEnabled: true
                    )
                    .frame(width: canvasW, height: canvasH)
                    #if os(macOS)
                    CanvasHoverTrackingView(scale: scale, editor: editor, tracker: mouseTracker)
                        .frame(width: canvasW, height: canvasH)
                        .allowsHitTesting(false)
                    #endif
                    SmartMeasurementOverlayView(state: mouseTracker.overlay, scale: scale)
                        .frame(width: canvasW, height: canvasH)
                        .allowsHitTesting(false)
                }
                }
                .onContinuousHover { phase in
                    guard board.isPrimary || editor.activeCanvasID == board.id else { return }
                    if isPanning || !editor.dragOrigins.isEmpty { return }
                    switch phase {
                    case .active(let location):
                        mouseTracker.hoverMoved(
                            x: Double(location.x / max(scale, 0.0001)),
                            y: Double(location.y / max(scale, 0.0001)),
                            editor: editor
                        )
                    case .ended:
                        mouseTracker.hoverEnded(editor: editor)
                    }
                }
                .coordinateSpace(name: editor.activeCanvasID == board.id || (editor.activeCanvasID == nil && board.isPrimary) ? "editorCanvas" : "editorCanvasInactive")
                .frame(width: canvasW, height: canvasH, alignment: .topLeading)
            }
    }

    private func canvasBackdrop(
        scale: Double,
        showsTransparency: Bool,
        backgroundEnabled: Bool,
        backgroundHex: String,
        hostsProgramMedia: Bool
    ) -> some View {
        let gridUnit = editor.gridConfig.gridSizePoints
        let cellSize = CanvasGridDisplay.checkerboardCellSize(documentUnit: gridUnit, scale: CGFloat(scale))
        let fill = backgroundEnabled ? (Color(hex: backgroundHex) ?? ProShowTheme.stageBlack) : Color.clear
        return ZStack {
            if showsTransparency {
                CheckerboardFill(cellSize: cellSize)
            }
            Rectangle()
                .fill(fill)
            if hostsProgramMedia, let media = programMediaCueBackdrop {
                programMediaCuePreview(media)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(showsTransparency ? "Transparent canvas" : "Canvas background")
    }

    /// Linked Layer 3 media under transparent canvas (stays visible after adding text/shapes).
    private var programMediaCueBackdrop: MediaAction? {
        guard editor.kind == .presentation,
              let document = editor.selectedDocument,
              let slideID = document.slideID,
              let slide = controller.show.slide(id: slideID),
              slide.showsLinkedProgramMediaUnderCanvas,
              let media = controller.editorWorkspaceMedia(for: document)
        else { return nil }
        return media
    }

    @ViewBuilder
    private func programMediaCuePreview(_ media: MediaAction) -> some View {
        let onAir = controller.isAudienceOutputOn && !controller.isAudienceCleared
        let mirrorLiveVideo = !onAir
            && !media.isImage
            && controller.playback.sharesClock(with: media)
            && controller.playback.canPresentVideo
        if mirrorLiveVideo {
            SharedProgramPlayerView(playback: controller.playback)
        } else {
            MediaPreviewFrame(
                filePath: media.filePath,
                artworkURL: media.resolvedFileURL(projectRoot: controller.mediaProjectRoot),
                kind: media.isImage ? .image : .video(duration: media.duration ?? ""),
                tintHex: media.tintHex,
                cornerRadius: 0
            )
        }
    }

    private func objectDrag(_ id: UUID, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("editorWorkspace"))
            .onChanged { value in
                if editor.activeTool.pansCanvas || editor.spaceHeld {
                    liveDrag.offset = .zero
                    beginLivePanIfNeeded()
                    liveDrag.pan = value.translation
                    return
                }
                if editor.activeTool == .zoom || editor.activeTool.insertionKind != nil {
                    return
                }
                if editor.dragOrigins.isEmpty {
        guard let object = editor.canvasObject(id: id),
              !object.isCanvasLocked
        else { return }
                    editor.beginDrag(id: id)
                }
                editor.bypassSnapping = EditorObjectTreeModifiers.commandHeld
                let tx = Double(value.translation.width / max(scale, 0.0001))
                let ty = Double(value.translation.height / max(scale, 0.0001))
                editor.updateDrag(translationX: tx, translationY: ty)
                liveDrag.offset = .zero
            }
            .onEnded { _ in
                if isPanning {
                    commitLivePan()
                    return
                }
                editor.endDrag()
                liveDrag.offset = .zero
            }
    }

    private func canvasBlankGesture(
        scale: CGFloat,
        canvasWidth: Double,
        canvasHeight: Double,
        originX: CGFloat,
        originY: CGFloat,
        canvasID: UUID
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("editorWorkspace"))
            .onChanged { value in
                editor.activeCanvasID = canvasID
                if editor.activeTool.pansCanvas || editor.spaceHeld {
                    marqueeStart = nil
                    marqueeCurrent = nil
                    beginLivePanIfNeeded()
                    liveDrag.pan = value.translation
                    return
                }
                if let kind = editor.activeTool.insertionKind {
                    let start = canvasPoint(fromWorkspace: value.startLocation, scale: scale, originX: originX, originY: originY)
                    let current = canvasPoint(fromWorkspace: value.location, scale: scale, originX: originX, originY: originY)
                    if editor.creationStart == nil {
                        editor.beginCreation(kind: kind, x: start.x, y: start.y)
                    }
                    editor.updateCreation(kind: kind, x: current.x, y: current.y)
                    return
                }
                if isPanning {
                    liveDrag.pan = value.translation
                    return
                }
                if isMarqueeGesture(value) {
                    if marqueeStart == nil {
                        marqueeStart = canvasLocation(fromWorkspace: value.startLocation, originX: originX, originY: originY)
                    }
                    marqueeCurrent = canvasLocation(fromWorkspace: value.location, originX: originX, originY: originY)
                    return
                }
                if hypot(value.translation.width, value.translation.height) >= 2 {
                    beginLivePanIfNeeded()
                    liveDrag.pan = value.translation
                }
            }
            .onEnded { value in
                if let start = marqueeStart {
                    let end = marqueeCurrent ?? canvasLocation(fromWorkspace: value.location, originX: originX, originY: originY)
                    let box = CanvasBounds.fromCorners(
                        x1: Double(start.x / max(scale, 0.0001)),
                        y1: Double(start.y / max(scale, 0.0001)),
                        x2: Double(end.x / max(scale, 0.0001)),
                        y2: Double(end.y / max(scale, 0.0001))
                    )
                    if box.width > 2 || box.height > 2 {
                        editor.selectObjects(
                            intersecting: box,
                            additive: EditorObjectTreeModifiers.shiftHeld || EditorObjectTreeModifiers.commandHeld
                        )
                    }
                    marqueeStart = nil
                    marqueeCurrent = nil
                    return
                }
                if isPanning {
                    commitLivePan()
                    return
                }
                let point = canvasPoint(fromWorkspace: value.location, scale: scale, originX: originX, originY: originY)
                if editor.activeTool == .zoom {
                    let optionHeld: Bool = {
                        #if os(macOS)
                        NSEvent.modifierFlags.contains(.option)
                        #else
                        false
                        #endif
                    }()
                    clickZoom(
                        at: value.location,
                        canvasWidth: canvasWidth,
                        canvasHeight: canvasHeight,
                        zoomOut: optionHeld
                    )
                    return
                }
                if let kind = editor.activeTool.insertionKind {
                    editor.endCreation(kind: kind, x: point.x, y: point.y)
                    return
                }
                if hypot(value.translation.width, value.translation.height) < 3 {
                    editor.clearObjectSelection()
                }
            }
    }

    private var canvasMarqueeRect: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        return CGRect(x: x, y: y, width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    private func isMarqueeGesture(_ value: DragGesture.Value) -> Bool {
        if marqueeStart != nil { return true }
        #if os(macOS)
        return (NSApp.currentEvent?.clickCount ?? 1) >= 2
            && hypot(value.translation.width, value.translation.height) >= 2
        #else
        return hypot(value.translation.width, value.translation.height) >= 12
        #endif
    }

    private func beginLivePanIfNeeded() {
        guard !isPanning else { return }
        isPanning = true
        liveDrag.offset = .zero
        liveDrag.pan = .zero
    }

    private func commitLivePan() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            editor.canvasPanX += Double(liveDrag.pan.width)
            editor.canvasPanY += Double(liveDrag.pan.height)
            liveDrag.pan = .zero
            liveDrag.offset = .zero
            isPanning = false
        }
    }

    private func canvasLocation(fromWorkspace point: CGPoint, originX: CGFloat, originY: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x - originX - liveDrag.pan.width,
            y: point.y - originY - liveDrag.pan.height
        )
    }

    private func canvasPoint(
        fromWorkspace point: CGPoint,
        scale: CGFloat,
        originX: CGFloat,
        originY: CGFloat
    ) -> (x: Double, y: Double) {
        let local = canvasLocation(fromWorkspace: point, originX: originX, originY: originY)
        return (Double(local.x / max(scale, 0.0001)), Double(local.y / max(scale, 0.0001)))
    }

    private func clickZoom(at paneLocation: CGPoint, canvasWidth: Double, canvasHeight: Double, zoomOut: Bool) {
        let document = editor.selectedDocument
        editor.setZoom(
            editor.zoom * (zoomOut ? 1 / 1.25 : 1.25),
            focusX: paneLocation.x,
            focusY: paneLocation.y,
            paneWidth: max(workspaceSize.width, 1),
            paneHeight: max(workspaceSize.height, 1),
            canvasWidth: document?.canvasWidth ?? canvasWidth,
            canvasHeight: document?.canvasHeight ?? canvasHeight
        )
    }

    private func textAlignment(_ align: TextHorizontalAlign) -> TextAlignment {
        switch align {
        case .left, .justify, .justifyLeft, .justifyAll: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private func frameAlignment(_ layout: TextLayout) -> Alignment {
        switch layout.verticalAlign {
        case .top:
            return layout.horizontalAlign == .right ? .topTrailing : (layout.horizontalAlign == .center ? .top : .topLeading)
        case .middle, .baseline:
            return layout.horizontalAlign == .right ? .trailing : (layout.horizontalAlign == .center ? .center : .leading)
        case .bottom:
            return layout.horizontalAlign == .right ? .bottomTrailing : (layout.horizontalAlign == .center ? .bottom : .bottomLeading)
        }
    }

    @State private var showsQRCodeTool = false
    @State private var qrCodePayload = "https://"
    @State private var draggingCanvasID: UUID?
    @State private var canvasDragTranslation: CGSize = .zero

    private var floatingToolbar: some View {
        HStack(spacing: 14) {
            ForEach(toolbarItems, id: \.self) { kind in
                Button {
                    _ = editor.addObject(kind)
                } label: {
                    Image(systemName: toolbarSymbol(kind))
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help(kind.title)
                .accessibilityLabel(kind.title)
            }
            if EditorCatalog.showsShapeMenu(editor.kind) {
                Menu {
                    ForEach(EditorCatalog.shapes, id: \.self) { shape in
                        Button(shape.title) { _ = editor.addObject(shape) }
                    }
                    Divider()
                    Section("Tools") {
                        Button {
                            qrCodePayload = "https://"
                            showsQRCodeTool = true
                        } label: {
                            Label("QR Code…", systemImage: "qrcode")
                        }
                    }
                } label: {
                    Image(systemName: "square.on.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .help("Add Shape")
                .accessibilityLabel("Add Shape")
                .popover(isPresented: $showsQRCodeTool, arrowEdge: .bottom) {
                    QRCodeToolPopover(
                        payload: $qrCodePayload,
                        onInsert: insertQRCodeObject,
                        onCancel: { showsQRCodeTool = false }
                    )
                }
            }
            if EditorCatalog.showsLiveMenu(editor.kind) {
                Menu {
                    ForEach(EditorCatalog.liveObjects, id: \.self) { kind in
                        Button(kind.title) { addLiveObject(kind) }
                    }
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .semibold))
                }
                .help("Add Live Element")
                .accessibilityLabel("Add Live Element")
            }
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)
            CanvasAddMenu(editor: editor)
        }
        .foregroundStyle(ProShowTheme.toolbarIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ProShowTheme.panel.opacity(0.96), in: Capsule())
    }

    private var toolbarItems: [CanvasObjectKind] {
        EditorCatalog.toolbarItems(for: editor.kind)
    }

    private func toolbarSymbol(_ kind: CanvasObjectKind) -> String {
        canvasObjectSymbol(kind)
    }


    private var statusBar: some View {
        HStack(spacing: 12) {
            ForEach(CanvasTool.allCases) { tool in
                Button {
                    editor.setTool(tool)
                } label: {
                    Text(tool.shortcut)
                        .font(.system(size: 9, weight: editor.activeTool == tool ? .bold : .regular).monospaced())
                        .foregroundStyle(editor.activeTool == tool ? ProShowTheme.accent : ProShowTheme.secondaryLabel)
                }
                .buttonStyle(.plain)
                .help(tool.title)
            }
            let box = editor.selectionBounds
            statusMetric("X", box?.x ?? 0)
            statusMetric("Y", box?.y ?? 0)
            statusMetric("W", box?.width ?? 0)
            statusMetric("H", box?.height ?? 0)
            Spacer()
            if editor.activeCanvasFrame()?.backgroundEnabled == false {
                Text("Transparent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .accessibilityLabel("Transparent canvas. Program media stays on output.")
            }
            toggleIcon("square.split.2x2", isOn: canvasFlag(\.showsCheckerboard), help: "Checkerboard")
            precisionToggle("eye", title: "Grid", isOn: canvasFlag(\.showsGrid))
            precisionToggle("arrow.up.and.down.and.arrow.left.and.right", title: "Snap", isOn: gridBinding(\.isSnapToGridEnabled))
            precisionToggle("ruler", title: "Smart guides", isOn: gridBinding(\.isSmartGuidesEnabled))
            canvasOverlayMenu
            Button {
                zoomAroundCenter(editor.zoom / 1.15)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Zoom Out")
            Button {
                fitWorkspace()
            } label: {
                Text("\(Int((editor.zoom * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .help("Fit to View")
            Button {
                zoomAroundCenter(editor.zoom * 1.15)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Zoom In")
            Slider(
                value: Binding(
                    get: { editor.zoom },
                    set: { zoomAroundCenter($0) }
                ),
                in: EditorEngine.minZoom...EditorEngine.maxZoom
            )
            .frame(width: 90)
            if editor.kind == .presentation {
                Text("Slide Notes")
                    .font(.caption2)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            Button("Show") { controller.pushEditorLive() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(ProShowTheme.titlebar)
    }

    private func statusMetric(_ label: String, _ value: Double) -> some View {
        Text("\(label): \(Int(value.rounded()))")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(ProShowTheme.secondaryLabel)
    }

    private func toggleIcon(_ name: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: name)
                .foregroundStyle(isOn.wrappedValue ? .white : ProShowTheme.secondaryLabel)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func canvasFlag(_ keyPath: WritableKeyPath<EditorCanvasFrame, Bool>) -> Binding<Bool> {
        Binding(
            get: { editor.activeCanvasFrame()?[keyPath: keyPath] ?? false },
            set: { value in
                editor.updateActiveCanvas { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func gridBinding(_ keyPath: WritableKeyPath<CanvasGridConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { editor.gridConfig[keyPath: keyPath] },
            set: { editor.gridConfig[keyPath: keyPath] = $0 }
        )
    }

    private var canvasOverlayMenu: some View {
        Menu {
            Toggle("Action & title safe", isOn: canvasFlag(\.showsSafeAreas))
            Toggle("Header & footer zones", isOn: canvasFlag(\.showsHeaderFooter))
            Toggle("12-column grid", isOn: canvasFlag(\.showsColumnGrid))
            Toggle("Snap to user guides", isOn: gridBinding(\.snapToUserGuides))
            Toggle("Minimap navigator", isOn: gridBinding(\.showCanvasMinimap))
        } label: {
            let frame = editor.activeCanvasFrame()
            Image(systemName: "rectangle.dashed")
                .foregroundStyle(
                    (frame?.showsSafeAreas == true)
                        || (frame?.showsHeaderFooter == true)
                        || (frame?.showsColumnGrid == true)
                        ? ProShowTheme.accent
                        : ProShowTheme.secondaryLabel
                )
        }
        .menuStyle(.borderlessButton)
        .help("Canvas overlay guides")
        .accessibilityLabel("Canvas overlay guides")
    }

    private func guideSpawnPreview(axis: GuideAxis?, position: CGFloat) -> UserGuideLine? {
        guard let axis else { return nil }
        return UserGuideLine(axis: axis, position: position)
    }

    private var displayedUserGuides: [UserGuideLine] {
        var guides = editor.userGuides
        guard let dragID = editor.guideLines.activeDraggingGuideID,
              let live = editor.guideLines.draggingGuideLivePosition,
              let index = guides.firstIndex(where: { $0.id == dragID })
        else { return guides }
        guides[index].position = live
        return guides
    }

    private func viewportOriginCanvas(originX: CGFloat, originY: CGFloat, scale: Double) -> CGPoint {
        let safeScale = max(scale, 0.0001)
        return CGPoint(
            x: CGFloat(-(originX + liveDrag.pan.width) / safeScale),
            y: CGFloat(-(originY + liveDrag.pan.height) / safeScale)
        )
    }

    private var rulerDraggingGuideOnHorizontalRuler: Bool {
        guard let id = rulerDraggingGuideID,
              let guide = editor.userGuides.first(where: { $0.id == id })
        else { return false }
        return guide.axis == .vertical
    }

    private var rulerDraggingGuideOnVerticalRuler: Bool {
        guard let id = rulerDraggingGuideID,
              let guide = editor.userGuides.first(where: { $0.id == id })
        else { return false }
        return guide.axis == .horizontal
    }

    private enum UserGuideGestureStart {
        case horizontalRulerBand
        case verticalRulerBand
        case continuationOnly
    }

    private func userGuideWorkbenchGesture(
        scale: Double,
        originX: CGFloat,
        originY: CGFloat,
        canvasWidth: Double,
        canvasHeight: Double,
        startMode: UserGuideGestureStart
    ) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvasWorkbench"))
            .onChanged { value in
                if startMode != .continuationOnly,
                   rulerDraggingGuideID == nil,
                   editor.guideLines.spawnAxis == nil {
                    if let hit = rulerUserGuideID(
                        at: value.startLocation,
                        scale: CGFloat(scale),
                        originX: originX,
                        originY: originY
                    ) {
                        rulerDraggingGuideID = hit
                        editor.guideLines.activeDraggingGuideID = hit
                        if let guide = editor.userGuides.first(where: { $0.id == hit }) {
                            editor.guideLines.draggingGuideLivePosition = guide.position
                        }
                    } else if startMode == .horizontalRulerBand,
                              value.startLocation.y <= GuideRulerWorkbench.topRulerHeight,
                              value.startLocation.x > GuideRulerWorkbench.leftRulerWidth {
                        editor.guideLines.spawnAxis = .horizontal
                    } else if startMode == .verticalRulerBand,
                              value.startLocation.x <= GuideRulerWorkbench.leftRulerWidth,
                              value.startLocation.y > GuideRulerWorkbench.topRulerHeight {
                        editor.guideLines.spawnAxis = .vertical
                    } else {
                        return
                    }
                }

                guard editor.guideLines.isInteracting || rulerDraggingGuideID != nil else { return }

                if let dragID = rulerDraggingGuideID,
                   let guide = editor.userGuides.first(where: { $0.id == dragID }) {
                    let workspacePoint = workspacePoint(fromWorkbench: value.location)
                    let mapped = canvasPoint(
                        fromWorkspace: workspacePoint,
                        scale: CGFloat(scale),
                        originX: originX,
                        originY: originY
                    )
                    let pos = guide.axis == .horizontal ? mapped.y : mapped.x
                    editor.guideLines.draggingGuideLivePosition = pos
                    return
                }

                guard let spawnAxis = editor.guideLines.spawnAxis else { return }
                let workspacePoint = workspacePoint(fromWorkbench: value.location)
                let mapped = canvasPoint(
                    fromWorkspace: workspacePoint,
                    scale: CGFloat(scale),
                    originX: originX,
                    originY: originY
                )
                switch spawnAxis {
                case .horizontal:
                    editor.guideLines.spawnPreviewPosition = mapped.y
                case .vertical:
                    editor.guideLines.spawnPreviewPosition = mapped.x
                }
            }
            .onEnded { value in
                defer { clearRulerGuideInteractionState() }

                if let dragID = rulerDraggingGuideID,
                   let guide = editor.userGuides.first(where: { $0.id == dragID }) {
                    let workspacePoint = workspacePoint(fromWorkbench: value.location)
                    let mapped = canvasPoint(
                        fromWorkspace: workspacePoint,
                        scale: CGFloat(scale),
                        originX: originX,
                        originY: originY
                    )
                    let releasePos = guide.axis == .horizontal ? mapped.y : mapped.x
                    let stored = editor.guideLines.draggingGuideLivePosition ?? guide.position
                    let droppedInRuler = editor.guideLines.droppedOnOriginatingRuler(
                        axis: guide.axis,
                        workbenchPoint: value.location
                    )
                    let canvasSize = CGSize(width: canvasWidth, height: canvasHeight)
                    let pos = editor.guideLines.resolvedUserGuidePositionAfterDrag(
                        releasePosition: releasePos,
                        storedPosition: stored,
                        axis: guide.axis,
                        canvasSize: canvasSize,
                        droppedInRuler: droppedInRuler
                    )
                    editor.finishUserGuideDrag(
                        id: dragID,
                        position: pos,
                        axis: guide.axis,
                        canvasSize: canvasSize,
                        droppedInRuler: droppedInRuler
                    )
                    return
                }

                guard let spawnAxis = editor.guideLines.spawnAxis else { return }
                editor.guideLines.spawnAxis = nil
                let workspacePoint = workspacePoint(fromWorkbench: value.location)
                guard isOnCanvasArtboard(
                    workspacePoint: workspacePoint,
                    canvasWidth: canvasWidth,
                    canvasHeight: canvasHeight,
                    scale: CGFloat(scale),
                    originX: originX,
                    originY: originY
                ) else { return }

                let mapped = canvasPoint(
                    fromWorkspace: workspacePoint,
                    scale: CGFloat(scale),
                    originX: originX,
                    originY: originY
                )
                let raw = spawnAxis == .horizontal ? mapped.y : mapped.x
                let limit = spawnAxis == .horizontal ? canvasHeight : canvasWidth
                let clamped = min(max(0, raw), limit)
                editor.addUserGuide(axis: spawnAxis, position: CGFloat(clamped))
            }
    }

    private func clearRulerGuideInteractionState() {
        rulerDraggingGuideID = nil
        editor.guideLines.clearInteraction()
    }

    private func workspacePoint(fromWorkbench point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - 24, y: point.y - 20)
    }

    private func isOnCanvasArtboard(
        workspacePoint: CGPoint,
        canvasWidth: Double,
        canvasHeight: Double,
        scale: CGFloat,
        originX: CGFloat,
        originY: CGFloat
    ) -> Bool {
        let origin = CGPoint(x: originX + liveDrag.pan.width, y: originY + liveDrag.pan.height)
        let width = canvasWidth * Double(scale)
        let height = canvasHeight * Double(scale)
        return workspacePoint.x >= origin.x
            && workspacePoint.x <= origin.x + width
            && workspacePoint.y >= origin.y
            && workspacePoint.y <= origin.y + height
    }

    private func rulerUserGuideID(
        at workbenchPoint: CGPoint,
        scale: CGFloat,
        originX: CGFloat,
        originY: CGFloat
    ) -> UUID? {
        let threshold: CGFloat = 10
        let pan = liveDrag.pan
        for guide in editor.userGuides where !guide.isLocked {
            switch guide.axis {
            case .vertical:
                let markerX = 24 + originX + pan.width + guide.position * scale
                if workbenchPoint.y <= 20, workbenchPoint.x >= 24,
                   abs(workbenchPoint.x - markerX) <= threshold {
                    return guide.id
                }
            case .horizontal:
                let markerY = 20 + originY + pan.height + guide.position * scale
                if workbenchPoint.x <= 24, workbenchPoint.y >= 20,
                   abs(workbenchPoint.y - markerY) <= threshold {
                    return guide.id
                }
            }
        }
        return nil
    }

    private func precisionToggle(_ name: String, title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: name)
                .foregroundStyle(isOn.wrappedValue ? ProShowTheme.accent : ProShowTheme.secondaryLabel)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            content()
        }
    }

    private func metaField(_ title: String, _ keyPath: WritableKeyPath<CopyrightInfo, String>) -> some View {
        labeled(title) {
            TextField(title, text: Binding(
                get: { editor.copyright[keyPath: keyPath] },
                set: { editor.copyright[keyPath: keyPath] = $0 }
            ))
            .textFieldStyle(.plain)
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ProShowTheme.secondaryLabel.opacity(0.25)).frame(height: 1)
            }
        }
    }

    private func documentBinding<Value>(_ keyPath: WritableKeyPath<EditorDocument, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { editor.selectedDocument?[keyPath: keyPath] ?? defaultValue },
            set: { value in editor.mutateSelectedDocument { $0[keyPath: keyPath] = value } }
        )
    }

    private func selectedObjectBinding<Value>(_ keyPath: WritableKeyPath<CanvasObject, Value>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { editor.selectedObjects.first?[keyPath: keyPath] ?? defaultValue },
            set: { value in editor.mutateSelectedObjects { $0[keyPath: keyPath] = value } }
        )
    }

    private func editorFlag(_ keyPath: ReferenceWritableKeyPath<EditorEngine, Bool>) -> Binding<Bool> {
        Binding(
            get: { controller.editors[keyPath: keyPath] },
            set: { controller.editors[keyPath: keyPath] = $0 }
        )
    }

    private func editorValue(_ keyPath: ReferenceWritableKeyPath<EditorEngine, Double>) -> Binding<Double> {
        Binding(
            get: { controller.editors[keyPath: keyPath] },
            set: { controller.editors[keyPath: keyPath] = $0 }
        )
    }

    private func addLiveObject(_ kind: CanvasObjectKind) {
        controller.finishAddingLiveObject(editor.addObject(kind))
    }

    private func insertQRCodeObject() {
        let trimmed = qrCodePayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = editor.addObject(.qrCode)
        editor.mutateSelectedObjects { $0.text = trimmed }
        showsQRCodeTool = false
    }

    private func addSidebarItem() {
        switch editor.kind {
        case .presentation:
            controller.addEditorSlide()
        case .theme:
            controller.addThemeVariant(named: "Custom \(editor.documents.count + 1)")
        case .props, .masks, .stage, .ccli, .overlays:
            _ = editor.addDocument(named: "\(editor.kind?.title ?? "Item") \(editor.documents.count + 1)")
        case nil:
            break
        }
    }
}

private enum EditorObjectTreeModifiers {
    static var commandHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }

    static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
}

struct EditorObjectsTree: View {
    var editor: EditorEngine
    var controller: ShowController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskSectionTitle(title: "Objects")
                .padding(.horizontal, DeskSpace.sm)
                .padding(.vertical, 6)
                .background(ProShowTheme.well.opacity(0.45))
            List {
                ForEach(editor.objectTreeRows) { row in
                    EditorObjectTreeRow(
                        editor: editor,
                        controller: controller,
                        row: row
                    )
                }
                .onMove { editor.reorderObjectTree(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focusEffectDisabled()
            .accessibilityLabel("Objects")
        }
    }
}

private struct EditorObjectTreeRow: View {
    var editor: EditorEngine
    var controller: ShowController
    let row: ObjectTreeItem

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 12)
            switch row {
            case .group(let id, let name, let childIDs, let isExpanded):
                groupContent(id: id, name: name, childIDs: childIDs, isExpanded: isExpanded)
            case .object(let object, _):
                objectContent(object)
            }
        }
        .listRowBackground(rowBackground)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .contextMenu { rowContextMenu }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var isSelected: Bool { editor.isObjectTreeRowSelected(row) }
    private var isPartial: Bool { editor.isObjectTreeRowPartiallySelected(row) }

    private var rowBackground: Color {
        if isSelected { return ProShowTheme.well }
        if isPartial { return ProShowTheme.well.opacity(0.45) }
        return Color.clear
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        switch row {
        case .group(let id, _, _, _):
            CanvasGroupContextMenu(editor: editor, controller: controller, groupID: id)
        case .object(let object, _):
            CanvasObjectContextMenu(editor: editor, controller: controller, objectID: object.id)
        }
    }

    private func groupContent(id: UUID, name: String, childIDs: [UUID], isExpanded: Bool) -> some View {
        let children = editor.selectedDocument?.objects.filter { childIDs.contains($0.id) } ?? []
        let hidden = children.contains { !$0.visibleOnAudience }
        let muted = children.contains(where: \.isAudioMuted)
        return HStack(spacing: 6) {
            Button {
                editor.toggleGroupExpanded(id)
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(isExpanded ? "Collapse \(name)" : "Expand \(name)")
            .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")

            Button {
                selectRow(id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.caption2)
                        .frame(width: 14)
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                    Text("\(childIDs.count)")
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel("\(name), group, \(childIDs.count) objects")
            .accessibilityHint(isExpanded ? "Expanded" : "Collapsed")

            DeskMuteButton(
                isMuted: muted,
                label: name,
                compact: true
            ) {
                controller.toggleEditorObjectAudio(ids: childIDs)
            }
            Button {
                editor.toggleAudienceVisibility(ids: childIDs)
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .font(.caption2)
                    .foregroundStyle(hidden ? ProShowTheme.liveRed : ProShowTheme.secondaryLabel)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(hidden ? "Show \(name) on audience" : "Hide \(name) on audience")
            .accessibilityLabel(hidden ? "Show \(name) on audience" : "Hide \(name) on audience")
        }
    }

    private func objectContent(_ object: CanvasObject) -> some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 22, height: 22)
            Button {
                selectRow(object.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: canvasObjectSymbol(object.kind))
                        .font(.caption2)
                        .frame(width: 14)
                    Text(object.name)
                        .font(.caption)
                        .lineLimit(1)
                        .strikethrough(!object.visibleOnAudience)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(object.name)
            DeskMuteButton(
                isMuted: object.isAudioMuted,
                label: object.name,
                compact: true
            ) {
                controller.toggleEditorObjectAudio(id: object.id)
            }
            Button {
                editor.toggleAudienceVisibility(id: object.id)
            } label: {
                Image(systemName: object.visibleOnAudience ? "eye" : "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(object.visibleOnAudience ? ProShowTheme.secondaryLabel : ProShowTheme.liveRed)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(object.visibleOnAudience ? "Hide on audience" : "Show on audience")
            .accessibilityLabel(object.visibleOnAudience ? "Hide \(object.name) on audience" : "Show \(object.name) on audience")
            Button {
                editor.toggleCanvasLock(id: object.id)
            } label: {
                Image(systemName: object.isCanvasLocked ? "lock.fill" : "lock.open")
                    .font(.caption2)
                    .foregroundStyle(object.isCanvasLocked ? ProShowTheme.accent : ProShowTheme.secondaryLabel)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .help(object.isCanvasLocked ? "Unlock \(object.name)" : "Lock \(object.name)")
            .accessibilityLabel(object.isCanvasLocked ? "Unlock \(object.name)" : "Lock \(object.name)")
        }
    }

    private func selectRow(_ id: UUID) {
        editor.selectObjectTreeRow(
            id,
            additive: EditorObjectTreeModifiers.commandHeld || EditorObjectTreeModifiers.shiftHeld,
            extending: EditorObjectTreeModifiers.shiftHeld
        )
    }
}

func canvasObjectSymbol(_ kind: CanvasObjectKind) -> String {
    switch kind {
    case .text, .title: "textformat"
    case .pen, .bezier: "pencil.tip"
    case .image: "photo"
    case .videoInput: "video"
    case .webView, .browser: "globe"
    case .currentSlide: "text.justify.left"
    case .nextSlide: "text.justify.right"
    case .stageNotes: "note.text"
    case .systemClock: "clock"
    case .systemDate: "calendar"
    case .timerCountdown: "timer"
    case .liveQuote: "chart.line.uptrend.xyaxis"
    case .textField: "character.textbox"
    case .subtitle: "text.alignleft"
    case .rectangle, .maskShape: "rectangle"
    case .roundedRectangle: "rectangle.roundedtop"
    case .ellipse: "oval"
    case .line: "line.diagonal"
    case .polygon: "triangle"
    case .copyrightToken: "c.square"
    case .prop: "rectangle.on.rectangle"
    case .cutout: "circle.slash"
    case .edgeBlend: "square.split.2x1"
    case .qrCode: "qrcode"
    }
}

private struct QRCodeToolPopover: View {
    @Binding var payload: String
    var onInsert: () -> Void
    var onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QR Code")
                .font(.system(size: 13, weight: .semibold))
            Text("Link, text, or tokens such as {segment.link} or {Speaker}.")
                .font(.system(size: 11))
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Payload", text: $payload, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .focused($focused)
            HStack {
                QRCodeCanvasView(payload: payload)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(InspectorTokens.dividerColor, lineWidth: 1)
                    }
                Spacer(minLength: 8)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Insert", action: onInsert)
                    .keyboardShortcut(.defaultAction)
                    .disabled(payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { focused = true }
    }
}

struct CanvasGroupContextMenu: View {
    var editor: EditorEngine
    var controller: ShowController
    let groupID: UUID

    var body: some View {
        Button("Select Group") { editor.selectObjectTreeRow(groupID) }
        Button(editor.collapsedGroupIDs.contains(groupID) ? "Expand" : "Collapse") {
            editor.toggleGroupExpanded(groupID)
        }
        Divider()
        Button("Ungroup") {
            editor.selectObjectTreeRow(groupID)
            editor.ungroupSelected()
        }
        .disabled(!editor.canUngroup)
        Button("Delete", role: .destructive) {
            editor.selectObjectTreeRow(groupID)
            editor.deleteSelected()
        }
    }
}

struct CanvasObjectContextMenu: View {
    var editor: EditorEngine
    var controller: ShowController
    let objectID: UUID

    var body: some View {
        Button("Assign Source…") {
            editor.selectObject(objectID)
            controller.openAddShotToAssign()
        }
        Divider()
        Button("Bring Forward") { editor.selectObject(objectID); editor.bringForward() }
        Button("Send Backward") { editor.selectObject(objectID); editor.sendBackward() }
        Divider()
        Button("Duplicate") { editor.selectObject(objectID); editor.duplicateSelected() }
        Button("Copy Style") { editor.selectObject(objectID); editor.copySelectedTextStyle() }
        Button("Paste Style") { editor.pasteSelectedTextStyle() }
            .disabled(!editor.canPasteTextStyle)
        Menu("Align") {
            Button("Left") { editor.selectObject(objectID); editor.alignSelected(.left) }
            Button("Center") { editor.selectObject(objectID); editor.alignSelected(.centerX) }
            Button("Right") { editor.selectObject(objectID); editor.alignSelected(.right) }
            Button("Top") { editor.selectObject(objectID); editor.alignSelected(.top) }
            Button("Middle") { editor.selectObject(objectID); editor.alignSelected(.centerY) }
            Button("Bottom") { editor.selectObject(objectID); editor.alignSelected(.bottom) }
        }
        Button("Flip Horizontal") { editor.selectObject(objectID); editor.mutateSelectedObjects { $0.transform.flipHorizontal.toggle() } }
        Button("Flip Vertical") { editor.selectObject(objectID); editor.mutateSelectedObjects { $0.transform.flipVertical.toggle() } }
        Button("Hide on Audience") { editor.selectObject(objectID); editor.mutateSelectedObjects { $0.visibleOnAudience.toggle() } }
        Button("Hide on Stage") { editor.selectObject(objectID); editor.mutateSelectedObjects { $0.visibleOnStage.toggle() } }
        Button((editor.selectedDocument?.objects.first(where: { $0.id == objectID })?.isAudioMuted == true) ? "Unmute Audio" : "Mute Audio") {
            controller.toggleEditorObjectAudio(id: objectID)
        }
        Divider()
        Button("Cut") { editor.selectObject(objectID); editor.cutSelectedObjects() }
        Button("Copy") { editor.selectObject(objectID); editor.copySelectedObjects() }
        Button("Paste") { editor.pasteObjects() }
            .disabled(!editor.canPasteObjects)
        Button("Select All") { editor.selectAllObjects() }
        Divider()
        Button("Group") {
            if !editor.selectedObjectIDs.contains(objectID) {
                editor.selectObject(objectID)
            }
            editor.groupSelected()
        }
        .disabled(!editor.canGroup)
        Button("Ungroup") { editor.ungroupSelected() }
            .disabled(!editor.canUngroup)
        Divider()
        Button("Delete", role: .destructive) { editor.selectObject(objectID); editor.deleteSelected() }
    }
}

struct CanvasBlankContextMenu: View {
    var editor: EditorEngine
    var controller: ShowController

    var body: some View {
        Button("Paste") { editor.pasteObjects() }
            .disabled(!editor.canPasteObjects)
        Button("Select All") { editor.selectAllObjects() }
        Divider()
        Button("Add Text") { _ = editor.addObject(.text) }
        Menu("Add Shape") {
            ForEach(EditorCatalog.shapes, id: \.self) { shape in
                Button(shape.title) { _ = editor.addObject(shape) }
            }
            Divider()
            Section("Tools") {
                Button("QR Code…") {
                    _ = editor.addObject(.qrCode)
                }
            }
        }
        Button("Add Image") {
            _ = editor.addObject(.image)
        }
        Menu("Add Live Element") {
            ForEach(EditorCatalog.liveObjects, id: \.self) { kind in
                Button(kind.title) {
                    controller.finishAddingLiveObject(editor.addObject(kind))
                }
            }
        }
    }
}

private struct InfinitePaneRuler: View {
    var axis: Axis
    var scale: Double
    var origin: Double
    var majorTick: Double = CanvasConfig.majorTick
    var minorTick: Double = CanvasConfig.minorTick

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ProShowTheme.panel))
            let span = axis == .horizontal ? size.width : size.height
            let safeScale = max(scale, 0.0001)
            let step = Self.tickStep(for: safeScale, majorTick: majorTick)
            let minor = step == majorTick ? minorTick : max(step / 5, 1)
            let minValue = (0 - origin) / safeScale
            let maxValue = (span - origin) / safeScale
            let start = (minValue / minor).rounded(.down) * minor
            var value = start
            var drawn = 0
            while value <= maxValue + minor, drawn < 400 {
                let pos = origin + value * safeScale
                let isMajor = abs(value.truncatingRemainder(dividingBy: step)) < 0.001 || abs(value.truncatingRemainder(dividingBy: step) - step) < 0.001
                var path = Path()
                if axis == .horizontal {
                    path.move(to: CGPoint(x: pos, y: isMajor ? 5 : 12))
                    path.addLine(to: CGPoint(x: pos, y: size.height))
                } else {
                    path.move(to: CGPoint(x: isMajor ? 5 : 12, y: pos))
                    path.addLine(to: CGPoint(x: size.width, y: pos))
                }
                context.stroke(path, with: .color(Color.white.opacity(isMajor ? 0.5 : 0.2)), lineWidth: 1)
                if isMajor {
                    let label = Text(Self.label(value)).font(.system(size: 7)).foregroundColor(ProShowTheme.secondaryLabel)
                    context.draw(label, at: axis == .horizontal ? CGPoint(x: pos + 10, y: 7) : CGPoint(x: 11, y: pos + 8))
                }
                value += minor
                drawn += 1
            }
        }
    }

    private static func tickStep(for scale: Double, majorTick: Double) -> Double {
        if majorTick * scale >= 36 {
            return majorTick
        }
        let target = 72 / scale
        let nice = [1.0, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000]
        return nice.first { $0 >= target } ?? 5000
    }

    private static func label(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(rounded) < 0.001 { return "0" }
        return String(Int(rounded))
    }
}

private struct CanvasGridOverlay: View {
    var width: Double
    var height: Double
    var scale: CGFloat
    var step: Double

    var body: some View {
        Canvas { context, _ in
            var x = 0.0
            while x <= width {
                var path = Path()
                path.move(to: CGPoint(x: x * scale, y: 0))
                path.addLine(to: CGPoint(x: x * scale, y: height * scale))
                context.stroke(path, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
                x += step
            }
            var y = 0.0
            while y <= height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y * scale))
                path.addLine(to: CGPoint(x: width * scale, y: y * scale))
                context.stroke(path, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CanvasObjectView: View {
    var editor: EditorEngine
    let object: CanvasObject
    var canvasObjects: [CanvasObject] = []
    var slideSteps: [ElementBuildStep] = []
    var scale: CGFloat
    var selected: Bool
    var editing: Bool = false
    var onEdit: ((String) -> Void)? = nil
    var onCommit: ((String) -> Void)? = nil
    @Environment(\.dynamicText) private var explicitDynamicText
    @Environment(\.dynamicTextSource) private var dynamicTextSource
    private var dynamicText: DynamicTextContext { dynamicTextSource?.context ?? explicitDynamicText }
    @Environment(\.liveQuoteEngine) private var liveQuoteEngine
    @Environment(\.proShowPlayback) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationEvaluationMode) private var evaluationMode

    private var displayBounds: CanvasBounds { editor.displayBounds(for: object) }
    private var committedBounds: CanvasBounds { object.bounds }
    private var layoutBounds: CanvasBounds {
        editor.usesDecoderFreeResizePreview(for: object) ? committedBounds : displayBounds
    }
    private func screenLength(_ document: CGFloat) -> CGFloat {
        max(1, CanvasEditorScreenAlign.screenPoint(document * scale))
    }

    private func screenOffset(_ document: Double) -> CGFloat {
        CanvasEditorScreenAlign.screenPoint(CGFloat(document) * scale)
    }

    private var width: CGFloat { screenLength(CGFloat(layoutBounds.width)) }
    private var height: CGFloat { screenLength(CGFloat(layoutBounds.height)) }
    private var rotation: Double { editor.displayRotation(for: object) }
    private var resizePreviewTransform: CGAffineTransform {
        guard editor.usesDecoderFreeResizePreview(for: object),
              let live = editor.liveHandleBounds[object.id]
        else { return .identity }
        return VideoResizePreviewScaler.previewTransformInViewSpace(
            from: committedBounds,
            to: live,
            canvasScale: scale
        )
    }

    var body: some View {
        BuildAnimated(object: object, slideSteps: slideSteps, scale: scale) { state in
            let stack = objectStack(state)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .overlay(selectionRing)
            Group {
                if object.hostsLayerBackedMedia {
                    stack
                        .transformEffect(resizePreviewTransform)
                        .shadow(color: dropShadowColor, radius: dropShadowRadius, x: dropShadowX, y: dropShadowY)
                        .rotationEffect(.degrees(rotation))
                        .scaleEffect(x: object.transform.flipHorizontal ? -1 : 1, y: object.transform.flipVertical ? -1 : 1)
                        .blendMode(layerBlend)
                        .offset(x: screenOffset(layoutBounds.x), y: screenOffset(layoutBounds.y))
                        .opacity(object.opacity * (object.visibleOnAudience ? 1 : 0.32))
                        .hiddenKeepingAlive(object.opacity < 0.02 || !object.visibleOnAudience)
                } else {
                    stack
                        .clipped()
                        .shadow(color: dropShadowColor, radius: dropShadowRadius, x: dropShadowX, y: dropShadowY)
                        .blur(radius: featherRadius)
                        .rotationEffect(.degrees(rotation))
                        .scaleEffect(x: object.transform.flipHorizontal ? -1 : 1, y: object.transform.flipVertical ? -1 : 1)
                        .blendMode(layerBlend)
                        .offset(x: screenOffset(displayBounds.x), y: screenOffset(displayBounds.y))
                        .opacity(object.opacity * (object.visibleOnAudience ? 1 : 0.32))
                }
            }
            .transaction { $0.animation = nil }
        }
    }

    private func objectStack(_ state: TransformedRenderState) -> some View {
        ZStack {
            CanvasObjectShapeLayer(
                object: object,
                width: width,
                height: height,
                scale: scale,
                playsAssignedVideo: true,
                muteAssignedVideo: true
            )
            overlayContent(state)
        }
        .canvasElementShimmer(object.resolvedShimmer, scale: scale)
    }

    @ViewBuilder
    private func overlayContent(_ state: TransformedRenderState) -> some View {
        if object.isTextLike {
            objectLabel(state)
                .frame(width: width, height: height)
                .clipped()
        } else if object.assignedSource == nil && object.fill.type != .image && (object.kind == .image || object.kind == .videoInput || object.kind.isBrowserLike) {
            mediaPlaceholder
        }
    }

    private var selectionRing: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .strokeBorder(selected ? Color.yellow : .clear, lineWidth: selected ? 1.5 : 0)
    }

    private var layerBlend: BlendMode {
        switch object.blendMode ?? .normal {
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .colorBurn: .colorBurn
        case .colorDodge: .colorDodge
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        case .linearBurn: .plusDarker
        case .linearDodge: .plusLighter
        default: .normal
        }
    }

    private var dropShadowColor: Color {
        object.shadow.enabled ? (Color(hex: object.shadow.color) ?? .black).opacity(0.7) : .clear
    }

    private var dropShadowRadius: CGFloat {
        object.shadow.enabled ? max(0, object.shadow.blur * scale) : 0
    }

    private var dropShadowX: CGFloat {
        object.shadow.enabled ? cos(object.shadow.angle * .pi / 180) * object.shadow.offset * scale : 0
    }

    private var dropShadowY: CGFloat {
        object.shadow.enabled ? sin(object.shadow.angle * .pi / 180) * object.shadow.offset * scale : 0
    }

    private var featherRadius: CGFloat {
        object.shadow.feather > 0 ? object.shadow.feather * scale : 0
    }

    private func objectLabel(_ state: TransformedRenderState) -> some View {
        ZStack(alignment: object.canvasTextFrameAlignment) {
            if editing {
                CanvasAttributedTextInput(
                    object: object,
                    layoutScale: scale,
                    text: object.text,
                    onChange: { onEdit?($0) },
                    onCommit: { latest in onCommit?(latest) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let liveQuoteEngine {
                LiveQuoteRefreshScope(engine: liveQuoteEngine) {
                    objectLabelLiveText(state)
                }
            } else {
                objectLabelLiveText(state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: object.canvasTextFrameAlignment)
    }

    @ViewBuilder
    private func objectLabelLiveText(_ state: TransformedRenderState) -> some View {
        // Static text (60 s interval) skips TimelineView: a periodic schedule built from `.now` restarts on every
        // parent update, so each text object re-rendered continuously (main thread pegged, editor lag).
        if textTimelineInterval >= 60 {
            objectLabelLiveTextContent(at: Date(), state)
        } else {
            TimelineView(.periodic(from: TimelineAnchor.start, by: textTimelineInterval)) { timeline in
                objectLabelLiveTextContent(at: timeline.date, state)
            }
        }
    }

    @ViewBuilder
    private func objectLabelLiveTextContent(at date: Date, _ state: TransformedRenderState) -> some View {
            let context = countdownContext(at: date)
            let resolved = DynamicTextEngine.resolve(object, context: context)
            if object.textLayout.isLooping {
                MarqueeTextLoopView(
                    object: object,
                    text: DynamicTextEngine.loopScrollText(for: object, resolved: resolved),
                    scale: scale,
                    reduceMotion: reduceMotion,
                    canvasObjects: canvasObjects,
                    liveQuotes: context.quotes,
                    dynamicTextContext: context
                )
                .allowsHitTesting(false)
            } else if MarketTickerRouting.usesStaticColoredLiveQuote(object) {
                StaticColoredLiveQuoteView(
                    object: object,
                    canvasObjects: canvasObjects,
                    scale: scale,
                    liveQuotes: context.quotes
                )
                .allowsHitTesting(false)
            } else {
                marqueeText(resolved, context: context, state: state)
                    .allowsHitTesting(true)
            }
        }
    

    private var textTimelineInterval: TimeInterval {
        if object.textLayout.isLooping, !editing {
            return object.kind.usesLiveText ? 1 : 60
        }
        if object.resolvedCountdownValueSource == .programMedia { return 0.25 }
        if evaluationMode.usesSettledRestState { return 60 }
        if object.kind.usesLiveText { return 1 }
        return 60
    }

    private func countdownContext(at date: Date) -> DynamicTextContext {
        var context = LiveQuoteEnvironment.mergedContext(
            base: dynamicText,
            engine: liveQuoteEngine,
            at: date
        )
        if object.resolvedCountdownValueSource == .programMedia, let playback, playback.duration > 0.05 {
            context.mediaRemainingSeconds = Int(playback.remaining.rounded(.towardZero))
        }
        return context
    }

    @ViewBuilder
    private func marqueeText(_ value: String, context: DynamicTextContext, state: TransformedRenderState) -> some View {
        if state.usesMarquee {
            Group {
                if state.marqueeVertical {
                    VStack(spacing: max(0, state.marqueeGapPx * scale)) {
                        styledText(value, context: context).fixedSize(horizontal: false, vertical: true)
                        styledText(value, context: context).fixedSize(horizontal: false, vertical: true)
                    }
                    .offset(y: state.scrollOffsetPx * scale)
                } else {
                    HStack(spacing: max(0, state.marqueeGapPx * scale)) {
                        styledText(value, context: context).fixedSize(horizontal: true, vertical: false)
                        styledText(value, context: context).fixedSize(horizontal: true, vertical: false)
                    }
                    .offset(x: state.scrollOffsetPx * scale)
                }
            }
        } else {
            styledText(value, context: context)
        }
    }

    private func styledText(_ value: String, context: DynamicTextContext? = nil, expands: Bool = true) -> some View {
        Group {
            #if os(macOS)
            if LiveQuoteDisplayRouting.usesTokenDisplayTemplate(object),
               let context,
               let liveQuote = LiveQuoteTemplateRenderer.makeAttributedString(
                   object: object,
                   scale: scale,
                   context: context,
                   colorConfig: TickerConfigStore.shared.colorConfig
               ) {
                CanvasStaticAttributedTextView(object: object, attributed: liveQuote, layoutScale: scale)
            } else {
                CanvasRasterizedTextView(object: object, text: value, layoutScale: scale)
            }
            #else
            Text(value)
                .font(canvasFont)
                .italic(object.typography.isItalic)
                .underline(object.typography.isUnderline)
                .strikethrough(object.typography.isStrikethrough)
                .baselineOffset(object.typography.isSuperscript ? object.typography.fontSize * scale * 0.35 : (object.typography.isSubscript ? -object.typography.fontSize * scale * 0.25 : 0))
                .foregroundStyle(Color(hex: object.typography.color) ?? .white)
                .shadow(color: outlineColor, radius: 0, x: outlineWidth, y: 0)
                .shadow(color: outlineColor, radius: 0, x: -outlineWidth, y: 0)
                .shadow(color: outlineColor, radius: 0, x: 0, y: outlineWidth)
                .shadow(color: outlineColor, radius: 0, x: 0, y: -outlineWidth)
                .shadow(color: textShadowColor, radius: textShadowRadius, x: textShadowX, y: textShadowY)
                .multilineTextAlignment(textAlignment)
                .lineSpacing(max(0, (object.textLayout.lineHeight - 1) * object.typography.fontSize * scale))
                .kerning(object.textLayout.characterSpacing * scale)
            #endif
        }
        .frame(maxWidth: expands ? .infinity : nil, maxHeight: expands ? .infinity : nil)
    }

    private var canvasFont: Font {
        CanvasSwiftUIFont.resolve(
            family: object.typography.fontFamily,
            size: max(1, object.typography.fontSize * scale),
            weight: object.typography.fontWeight,
            bold: object.typography.isBold,
            italic: object.typography.isItalic
        )
    }

    private var outlineWidth: CGFloat {
        object.textOutline.enabled ? max(0.2, object.textOutline.width * scale) : 0
    }

    private var outlineColor: Color {
        object.textOutline.enabled ? (Color(hex: object.textOutline.color) ?? .black) : .clear
    }

    private var textShadowColor: Color {
        object.textShadow.enabled ? (Color(hex: object.textShadow.color) ?? .black) : .clear
    }

    private var textShadowRadius: CGFloat {
        object.textShadow.enabled ? max(0, object.textShadow.blur * scale) : 0
    }

    private var textShadowX: CGFloat {
        object.textShadow.enabled
            ? cos(object.textShadow.angle * .pi / 180) * object.textShadow.offset * scale
            : 0
    }

    private var textShadowY: CGFloat {
        object.textShadow.enabled
            ? sin(object.textShadow.angle * .pi / 180) * object.textShadow.offset * scale
            : 0
    }

    private var mediaPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: object.kind == .image ? "photo" : (object.kind == .videoInput ? "video" : "globe"))
                .font(.title2)
            Text(object.name)
                .font(.caption2)
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    private var textAlignment: TextAlignment {
        switch object.textLayout.horizontalAlign {
        case .left, .justify, .justifyLeft: .leading
        case .center: .center
        case .right: .trailing
        case .justifyAll: .leading
        }
    }

}

private struct CheckerboardFill: View {
    /// Scaled layout-grid cell size in canvas points (one document grid unit).
    var cellSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let cell = max(1, cellSize)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col).isMultiple(of: 2) {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: cell, height: cell)),
                            with: .color(Color.white.opacity(0.2))
                        )
                    }
                    x += cell
                    col += 1
                }
                y += cell
                row += 1
            }
        }
    }
}

private struct EditorSlideThumbnail: View {
    let document: EditorDocument
    var selected: Bool
    var mediaProjectRoot: URL?
    var linkedMedia: MediaAction?
    var controller: ShowController? = nil
    var slide: Slide? = nil

    var body: some View {
        let ratio = CGFloat(document.canvasWidth / max(document.canvasHeight, 1))
        ZStack {
            if document.backgroundEnabled {
                Color(hex: document.backgroundHex) ?? ProShowTheme.stageBlack
            } else if slide?.needsProgramLiveCameraPreview == true {
                Color.black
            } else {
                CheckerboardFill()
            }
            if let linkedMedia, !document.backgroundEnabled {
                MediaPreviewFrame(
                    filePath: linkedMedia.filePath,
                    artworkURL: linkedMedia.resolvedFileURL(projectRoot: mediaProjectRoot),
                    kind: linkedMedia.isImage ? .image : .video(duration: linkedMedia.duration ?? ""),
                    tintHex: linkedMedia.tintHex,
                    cornerRadius: 0
                )
            }
            if !document.objects.isEmpty, let controller, let slide {
                ProgramSlideThumbnailPreview(
                    controller: controller,
                    slide: slide,
                    objects: document.objects,
                    canvasWidth: document.canvasWidth,
                    canvasHeight: document.canvasHeight
                )
            } else if !document.objects.isEmpty {
                ProgramSlideCanvas(
                    objects: document.objects,
                    canvasWidth: document.canvasWidth,
                    canvasHeight: document.canvasHeight,
                    evaluationMode: .thumbnailPreview
                )
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(ratio, contentMode: .fit)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(selected ? Color.yellow : Color.white.opacity(0.12), lineWidth: selected ? 1.4 : 0.5)
        }
        .accessibilityLabel(document.name)
    }
}

#if os(macOS)
/// Canvas edit-in-place using the same CoreText attributes as program/audience text (caret aligns with glyphs).
private struct CanvasAttributedTextInput: NSViewRepresentable {
    var object: CanvasObject
    var layoutScale: CGFloat
    var text: String
    var onChange: (String) -> Void
    var onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, onChange: onChange, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> CanvasInputTextView {
        let textView = CanvasInputTextView()
        textView.canvasVerticalAlign = object.textLayout.verticalAlign
        textView.canvasLayoutScale = layoutScale
        textView.canvasObject = object
        textView.delegate = context.coordinator
        configureChrome(textView)
        textView.textStorage?.setAttributedString(attributedString(for: text, elementBounds: textView.bounds))
        context.coordinator.textView = textView
        context.coordinator.styleSignature = styleSignature
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.syncVerticalAlignmentInset()
        }
        return textView
    }

    func updateNSView(_ textView: CanvasInputTextView, context: Context) {
        textView.canvasVerticalAlign = object.textLayout.verticalAlign
        textView.canvasLayoutScale = layoutScale
        textView.canvasObject = object
        context.coordinator.parent = self
        context.coordinator.onChange = onChange
        context.coordinator.onCommit = onCommit

        let signature = styleSignature
        if signature != context.coordinator.styleSignature {
            context.coordinator.styleSignature = signature
            configureChrome(textView)
        }

        if textView.string != text, !context.coordinator.isApplyingLocalEdit {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributedString(for: text, elementBounds: textView.bounds))
            let length = (textView.string as NSString).length
            let location = min(selection.location, length)
            let selLength = min(selection.length, max(0, length - location))
            textView.setSelectedRange(NSRange(location: location, length: selLength))
        }

        textView.syncVerticalAlignmentInset()
    }

    private func configureChrome(_ textView: CanvasInputTextView) {
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.focusRingType = .none
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.autoresizingMask = [.width]
        textView.insertionPointColor = NSColor(Color(hex: object.typography.color) ?? .white)
        textView.typingAttributes = typingAttributes(for: text.isEmpty ? " " : text, elementBounds: textView.bounds)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.22),
            .foregroundColor: NSColor(Color(hex: object.typography.color) ?? .white),
        ]
    }

    private func attributedString(for value: String, elementBounds: CGRect) -> NSAttributedString {
        let body = value.isEmpty ? " " : value
        let textRect = CoreTextRasterizer.textLayoutRectForDisplay(
            object: object,
            elementBounds: elementBounds,
            layoutScale: layoutScale
        )
        let base = CoreTextRasterizer.displayAttributedString(
            object: object,
            text: body,
            layoutScale: layoutScale,
            textRect: textRect
        )
        guard object.typography.isSuperscript || object.typography.isSubscript else { return base }
        let mutable = NSMutableAttributedString(attributedString: base)
        let offset = object.typography.isSuperscript
            ? object.typography.fontSize * layoutScale * 0.35
            : -object.typography.fontSize * layoutScale * 0.25
        if mutable.length > 0 {
            mutable.addAttribute(.baselineOffset, value: offset, range: NSRange(location: 0, length: mutable.length))
        }
        return mutable
    }

    private func typingAttributes(for sample: String, elementBounds: CGRect) -> [NSAttributedString.Key: Any] {
        let attributed = attributedString(for: sample, elementBounds: elementBounds)
        guard attributed.length > 0 else { return [:] }
        var attrs = attributed.attributes(at: 0, effectiveRange: nil)
        attrs[.foregroundColor] = NSColor(Color(hex: object.typography.color) ?? .white)
        return attrs
    }

    private var styleSignature: String {
        let t = object.typography
        let l = object.textLayout
        return [
            t.fontFamily,
            "\(t.fontSize)",
            "\(t.fontWeight.rawValue)",
            "\(t.isBold)",
            "\(t.isItalic)",
            t.color,
            "\(l.characterSpacing)",
            "\(l.lineHeight)",
            "\(l.wordSpacing)",
            l.horizontalAlign.rawValue,
            l.verticalAlign.rawValue,
            "\(object.textOutline.enabled)",
            "\(object.textShadow.enabled)",
            "\(layoutScale)",
        ].joined(separator: "|")
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CanvasAttributedTextInput
        var onChange: (String) -> Void
        var onCommit: (String) -> Void
        weak var textView: NSTextView?
        var styleSignature = ""
        var isApplyingLocalEdit = false

        init(parent: CanvasAttributedTextInput, onChange: @escaping (String) -> Void, onCommit: @escaping (String) -> Void) {
            self.parent = parent
            self.onChange = onChange
            self.onCommit = onCommit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let plain = textView.string
            let selection = textView.selectedRange()
            isApplyingLocalEdit = true
            onChange(plain)
            isApplyingLocalEdit = false
            textView.textStorage?.setAttributedString(
                parent.attributedString(for: plain, elementBounds: textView.bounds)
            )
            let length = (textView.string as NSString).length
            let location = min(selection.location, length)
            let selLength = min(selection.length, max(0, length - location))
            textView.setSelectedRange(NSRange(location: location, length: selLength))
            textView.typingAttributes = parent.typingAttributes(
                for: plain.isEmpty ? " " : plain,
                elementBounds: textView.bounds
            )
            (textView as? CanvasInputTextView)?.syncVerticalAlignmentInset()
        }

        func textDidEndEditing(_ notification: Notification) {
            onCommit(textView?.string ?? "")
        }
    }
}

private final class CanvasInputTextView: NSTextView {
    var canvasVerticalAlign: TextVerticalAlign = .middle
    var canvasLayoutScale: CGFloat = 1
    var canvasObject: CanvasObject?
    private var isSyncingInset = false

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// The text box is a fixed frame. Scrolling it on each key moves the glyphs down.
    override func scrollRangeToVisible(_ range: NSRange) {}

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        focusRingType = .none
        return accepted
    }

    override func layout() {
        super.layout()
        syncVerticalAlignmentInset()
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        syncVerticalAlignmentInset()
    }

    func syncVerticalAlignmentInset() {
        guard !isSyncingInset else { return }
        guard let layoutManager, let textContainer, let canvasObject else { return }
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }

        isSyncingInset = true
        defer { isSyncingInset = false }

        if bounds.origin != .zero {
            setBoundsOrigin(.zero)
        }

        let elementBounds = CGRect(origin: .zero, size: size)
        let textRect = CoreTextRasterizer.textLayoutRectForDisplay(
            object: canvasObject,
            elementBounds: elementBounds,
            layoutScale: canvasLayoutScale
        )
        textContainer.lineFragmentPadding = 0
        textContainer.size = NSSize(width: max(1, textRect.width), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let used = layoutManager.usedRect(for: textContainer)
        let align = CanvasTextBoxLayout.coreTextVerticalAlignment(for: canvasObject)
        let contentTop: CGFloat
        let glyphCount = layoutManager.numberOfGlyphs
        if glyphCount > 0, let storage = textStorage, storage.length > 0 {
            // Same visual-block rule as CoreTextRasterizer (font ascender/descender around baselines).
            func baseline(_ glyph: Int) -> CGFloat {
                layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    + layoutManager.location(forGlyphAt: glyph).y
            }
            let lastGlyph = glyphCount - 1
            let firstChar = layoutManager.characterIndexForGlyph(at: 0)
            let lastFragment = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let lastLineFirstGlyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: lastFragment.midY), in: textContainer)
            let lastChar = layoutManager.characterIndexForGlyph(at: lastLineFirstGlyph)
            let topMetrics = CoreTextRasterizer.fontMetrics(of: storage, at: firstChar)
            let bottomMetrics = CoreTextRasterizer.fontMetrics(of: storage, at: lastChar)
            contentTop = CoreTextRasterizer.visualAlignedLayoutTop(
                firstBaselineFromTop: baseline(0),
                lastBaselineFromTop: baseline(lastGlyph),
                ascent: topMetrics.ascent,
                descent: bottomMetrics.descent,
                in: textRect,
                align: align
            )
            let target = NSSize(width: max(0, textRect.minX), height: max(0, contentTop))
            if abs(textContainerInset.width - target.width) > 0.01 || abs(textContainerInset.height - target.height) > 0.01 {
                textContainerInset = target
            }
            return
        }
        let contentHeight = max(used.height, 1)
        switch align {
        case .top:
            contentTop = textRect.minY
        case .middle:
            contentTop = textRect.minY + max(0, (textRect.height - contentHeight) / 2)
        case .bottom, .baseline:
            contentTop = textRect.maxY - contentHeight
        }
        let target = NSSize(
            width: max(0, textRect.minX),
            height: max(0, contentTop - used.minY)
        )
        if abs(textContainerInset.width - target.width) > 0.5 || abs(textContainerInset.height - target.height) > 0.5 {
            textContainerInset = target
        }
    }
}
#else
private struct CanvasAttributedTextInput: View {
    var object: CanvasObject
    var scale: CGFloat
    var text: String
    var onChange: (String) -> Void
    var onCommit: (String) -> Void

    var body: some View {
        TextField("", text: Binding(get: { text }, set: onChange), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.custom(object.typography.fontFamily.isEmpty ? "Helvetica" : object.typography.fontFamily, size: max(1, object.typography.fontSize * scale)))
            .tint(Color(hex: object.typography.color) ?? .white)
            .onSubmit { onCommit(text) }
    }
}
#endif

/// Adds another canvas to the open slide. The label matches the tool island icons.
private struct CanvasAddMenu: View {
    var editor: EditorEngine
    @State private var showsCustom = false
    @State private var widthText = "1920"
    @State private var heightText = "1080"

    var body: some View {
        Menu {
            presetSection("Phone", presets: CanvasResolution.phonePresets)
            presetSection("Tablet", presets: CanvasResolution.tabletPresets)
            presetSection("Desktop", presets: CanvasResolution.desktopPresets)
            Divider()
            Button("Custom Size…") {
                widthText = "1920"
                heightText = "1080"
                showsCustom = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .help("Add canvas")
        .accessibilityLabel("Add canvas")
        .popover(isPresented: $showsCustom, arrowEdge: .bottom) {
            CustomCanvasSizePopover(
                widthText: $widthText,
                heightText: $heightText,
                onApply: { width, height in
                    editor.addCanvas(name: "Custom", width: width, height: height)
                    showsCustom = false
                },
                onCancel: { showsCustom = false }
            )
        }
    }

    @ViewBuilder
    private func presetSection(_ title: String, presets: [CanvasResolution]) -> some View {
        Section(title) {
            ForEach(presets) { preset in
                Button(preset.menuTitle) {
                    editor.addCanvas(name: preset.family.title, width: preset.size.width, height: preset.size.height)
                }
                .accessibilityLabel("Add \(title), \(preset.menuTitle)")
            }
        }
    }
}

private struct CustomCanvasSizePopover: View {
    @Binding var widthText: String
    @Binding var heightText: String
    var onApply: (Double, Double) -> Void
    var onCancel: () -> Void

    private var width: Double? { Self.evenPixel(widthText) }
    private var height: Double? { Self.evenPixel(heightText) }
    private var canApply: Bool { width != nil && height != nil }
    private var showsError: Bool {
        let widthTrimmed = !widthText.trimmingCharacters(in: .whitespaces).isEmpty
        let heightTrimmed = !heightText.trimmingCharacters(in: .whitespaces).isEmpty
        return (widthTrimmed && width == nil) || (heightTrimmed && height == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            Text("Custom canvas")
                .font(DeskType.bodyEmph)
                .foregroundStyle(ProShowTheme.primaryLabel)
            Text("Even pixels, from 16 to 7680.")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            HStack(spacing: DeskSpace.sm) {
                pixelField("Width", text: $widthText)
                pixelField("Height", text: $heightText)
            }
            if showsError {
                Text("Enter an even number from 16 to 7680.")
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.liveRed)
                    .accessibilityLabel("Enter an even number from 16 to 7680.")
            }
            HStack(spacing: DeskSpace.xs) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let width, let height else { return }
                    onApply(width, height)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
            }
        }
        .padding(DeskSpace.md)
        .frame(width: 280)
    }

    private func pixelField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(DeskType.mono)
                .accessibilityLabel(label)
        }
    }

    private static func evenPixel(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), (16...7680).contains(value), value.isMultiple(of: 2) else { return nil }
        return Double(value)
    }
}

/// Center of a canvas. New objects are placed on this point.
private struct CanvasCenterOriginMark: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 1, height: 16)
            Rectangle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 16, height: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Canvas center")
    }
}

struct LoopingTextFit: ViewModifier {
    var layout: TextLayout
    var maxLines: Int

    func body(content: Content) -> some View {
        content
            .minimumScaleFactor(layout.isLooping ? 1 : (layout.autoFitMode == .shrink ? 0.2 : 1))
            .lineLimit(layout.isLooping && !layout.resolvedLoopDirection.isVertical ? 1 : (layout.linesOnly == true ? 1 : maxLines))
    }
}

