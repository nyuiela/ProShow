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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var editor: EditorEngine { controller.editors }
    var body: some View {
        let _ = editor.documents
        let _ = editor.selectedObjectIDs
        let _ = editor.selectedDocumentID
        let _ = controller.inspector.timers.map { "\($0.id)-\($0.displaySeconds)-\($0.isRunning)-\($0.durationSeconds)" }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: DeskLayout.sidebar)
                    .background(ProShowTheme.panel)
                canvasStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                EditorInspectorView(controller: controller)
                    .frame(width: InspectorTokens.panelWidth)
            }
            statusBar
        }
        .background(ProShowTheme.canvas)
        .lockFlickerFreeBackground()
        .environment(\.dynamicText, controller.dynamicTextContext())
        .environment(\.buildClock, controller.editorBuildClock())
        .environment(\.animationEvaluationMode, controller.isCanvasEditorPresented ? controller.editorAnimationMode() : .thumbnailPreview)
        .environment(\.buildPhaseFilter, controller.editorBuildPhaseFilter())
        // Program video uses AVPlayerLayer on canvas so playback is not tied to SharedTexture pulls.
        .environment(\.mirrorsProgramPlayer, false)
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear {
            if controller.isCanvasEditorPresented { mouseTracker.attach() }
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
                        ForEach(EditorCatalog.themeCollections, id: \.self) { name in
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
                                EditorSlideThumbnail(
                                    document: document,
                                    selected: document.id == editor.selectedDocumentID
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
        controller.isSandboxEditingLive ? ProShowTheme.sandboxOrange : ProShowTheme.liveRed
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
        HStack(spacing: 8) {
            islandModeButton(
                title: "Live",
                selected: controller.isEditorLockedToLive,
                color: ProShowTheme.liveRed
            ) {
                controller.setEditorLockedToLive(true)
            }
            islandModeButton(
                title: "Sandbox",
                selected: controller.isSandboxEditingLive,
                color: ProShowTheme.sandboxOrange
            ) {
                controller.setEditorLockedToLive(false)
            }
            if controller.isSandboxEditingLive {
                Button {
                    controller.applySandboxChanges()
                } label: {
                    Text("Apply Changes")
                        .font(DeskType.micro)
                        .foregroundStyle(controller.hasSandboxChanges ? Color.white : ProShowTheme.secondaryLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(controller.hasSandboxChanges ? ProShowTheme.sandboxOrange : ProShowTheme.well)
                        )
                }
                .buttonStyle(DeskPressButtonStyle())
                .disabled(!controller.hasSandboxChanges)
                .help("Push sandbox edits to the live audience")
                .accessibilityLabel("Apply Changes")
                .accessibilityHint("Moves sandbox edits onto the live output.")
            }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(controller.isSandboxEditingLive ? "Sandbox mode" : "Live edit mode")
    }

    private func islandModeButton(title: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(selected ? Color.white : color)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(title)
                    .font(DeskType.micro)
            }
            .foregroundStyle(selected ? Color.white : ProShowTheme.primaryLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? color : Color.clear)
            )
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                    LiveOriginRuler(
                        session: liveDrag,
                        axis: .horizontal,
                        scale: scale,
                        origin: originX,
                        majorTick: metrics.majorTick,
                        minorTick: metrics.minorTick
                    )
                    .frame(width: workspace.width, height: 20)
                }
                HStack(spacing: 0) {
                    LiveOriginRuler(
                        session: liveDrag,
                        axis: .vertical,
                        scale: scale,
                        origin: originY,
                        majorTick: metrics.majorTick,
                        minorTick: metrics.minorTick
                    )
                    .frame(width: 24, height: workspace.height)
                    workspacePane(
                        document: document,
                        canvasWidth: width,
                        canvasHeight: height,
                        gridStep: metrics.gridStep,
                        scale: scale,
                        canvasW: canvasW,
                        canvasH: canvasH,
                        originX: originX,
                        originY: originY,
                        workspace: workspace
                    )
                    .frame(width: workspace.width, height: workspace.height)
                    .clipped()
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
        canvasW: Double,
        canvasH: Double,
        originX: Double,
        originY: Double,
        workspace: CGSize
    ) -> some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.31, green: 0.31, blue: 0.33)
                .onTapGesture { editor.clearObjectSelection() }
                .gesture(workspacePan)
                .contextMenu { CanvasBlankContextMenu(editor: editor, controller: controller) }
            canvasSurface(
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
                gridStep: gridStep,
                scale: scale,
                canvasW: canvasW,
                canvasH: canvasH,
                originX: originX,
                originY: originY
            )
            .modifier(CanvasLivePanModifier(session: liveDrag, originX: originX, originY: originY))
        }
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

    private func canvasSurface(
        canvasWidth: Double,
        canvasHeight: Double,
        gridStep: Double,
        scale: Double,
        canvasW: Double,
        canvasH: Double,
        originX: CGFloat,
        originY: CGFloat
    ) -> some View {
        canvasBackdrop
            .frame(width: canvasW, height: canvasH)
            .clipped()
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
                                originY: originY
                            )
                        )
                        .contextMenu { CanvasBlankContextMenu(editor: editor, controller: controller) }
                    if editor.snapToGrid {
                        CanvasGridOverlay(width: canvasWidth, height: canvasHeight, scale: scale, step: gridStep)
                            .frame(width: canvasW, height: canvasH)
                            .allowsHitTesting(false)
                    }
                    ForEach(editor.selectedDocument?.sortedObjects.reversed() ?? []) { object in
                        CanvasObjectView(
                            object: object,
                            slideSteps: editor.selectedDocument?.objects.flatMap(\.resolvedBuildSteps) ?? [],
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
                            editor.selectObject(
                                object.id,
                                additive: EditorObjectTreeModifiers.shiftHeld || EditorObjectTreeModifiers.commandHeld
                            )
                        }
                    }
                    if editor.showsCompoundChrome, let box = editor.selectionBounds {
                        CompoundSelectionChromeView(editor: editor, bounds: box, scale: scale)
                            .modifier(CanvasLiveOffsetModifier(session: liveDrag, applies: true))
                    } else {
                        ForEach(editor.selectedObjects) { object in
                            SelectionChromeView(editor: editor, object: object, scale: scale)
                                .modifier(CanvasLiveOffsetModifier(session: liveDrag, applies: true))
                        }
                    }
                    if let parent = editor.isolatedParentBounds {
                        GroupIsolationOutline(bounds: parent, scale: scale)
                    }
                    if let marquee = canvasMarqueeRect {
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
                    SmartGuidesOverlay(
                        guides: editor.lastGuides,
                        canvasWidth: canvasWidth,
                        canvasHeight: canvasHeight,
                        scale: scale
                    )
                    .frame(width: canvasW, height: canvasH)
                    .allowsHitTesting(false)
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
                .coordinateSpace(name: "editorCanvas")
                .frame(width: canvasW, height: canvasH, alignment: .topLeading)
            }
    }

    private var canvasBackdrop: some View {
        ZStack {
            if showsCanvasTransparencyGrid {
                CheckerboardFill()
            }
            Rectangle()
                .fill(canvasFill)
        }
        .accessibilityLabel(showsCanvasTransparencyGrid ? "Transparent canvas" : "Canvas background")
    }

    private var showsCanvasTransparencyGrid: Bool {
        editor.checkerboard || !(editor.selectedDocument?.backgroundEnabled ?? true)
    }

    private var canvasFill: Color {
        guard let document = editor.selectedDocument, document.backgroundEnabled else {
            return .clear
        }
        return Color(hex: document.backgroundHex) ?? ProShowTheme.stageBlack
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
                    editor.beginDrag(id: id)
                }
                liveDrag.offset = value.translation
            }
            .onEnded { value in
                if isPanning {
                    commitLivePan()
                    return
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if !editor.dragOrigins.isEmpty {
                        editor.updateDrag(
                            translationX: Double(value.translation.width / max(scale, 0.0001)),
                            translationY: Double(value.translation.height / max(scale, 0.0001))
                        )
                        editor.endDrag()
                    }
                    liveDrag.offset = .zero
                }
            }
    }

    private func canvasBlankGesture(
        scale: CGFloat,
        canvasWidth: Double,
        canvasHeight: Double,
        originX: CGFloat,
        originY: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("editorWorkspace"))
            .onChanged { value in
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

    private var floatingToolbar: some View {
        HStack(spacing: 14) {
            ForEach(toolbarItems, id: \.self) { kind in
                Button {
                    _ = editor.addObject(kind)
                    if kind == .image || kind == .videoInput || kind == .prop {
                        controller.openAddShotToAssign()
                    }
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
                } label: {
                    Image(systemName: "square.on.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .help("Add Shape")
                .accessibilityLabel("Add Shape")
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
            if editor.selectedDocument?.backgroundEnabled == false {
                Text("Transparent")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .accessibilityLabel("Transparent canvas. Program media stays on output.")
            }
            toggleIcon("square.split.2x2", isOn: editorFlag(\.checkerboard))
            toggleIcon("line.3.horizontal", isOn: editorFlag(\.snapGuides))
            toggleIcon("grid", isOn: editorFlag(\.snapToGrid))
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

    private func toggleIcon(_ name: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Image(systemName: name)
                .foregroundStyle(isOn.wrappedValue ? .white : ProShowTheme.secondaryLabel)
        }
        .buttonStyle(.plain)
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

    private func addSidebarItem() {
        switch editor.kind {
        case .presentation:
            controller.addEditorSlide()
        case .theme:
            editor.addThemeVariant("Custom \(editor.documents.count + 1)")
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
    case .webView: "globe"
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
        }
        Button("Add Image") {
            _ = editor.addObject(.image)
            controller.openAddShotToAssign()
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
    let object: CanvasObject
    var slideSteps: [ElementBuildStep] = []
    var scale: CGFloat
    var selected: Bool
    var editing: Bool = false
    var onEdit: ((String) -> Void)? = nil
    var onCommit: ((String) -> Void)? = nil
    @Environment(\.dynamicText) private var dynamicText
    @Environment(\.proShowPlayback) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationEvaluationMode) private var evaluationMode

    private var width: CGFloat { max(1, object.bounds.width * scale) }
    private var height: CGFloat { max(1, object.bounds.height * scale) }

    var body: some View {
        BuildAnimated(object: object, slideSteps: slideSteps, scale: scale) { state in
            let stack = objectStack(state)
                .frame(width: width, height: height)
                .overlay(selectionRing)
            Group {
                if object.hostsLayerBackedMedia {
                    stack
                        .shadow(color: dropShadowColor, radius: dropShadowRadius, x: dropShadowX, y: dropShadowY)
                        .rotationEffect(.degrees(object.transform.rotation))
                        .scaleEffect(x: object.transform.flipHorizontal ? -1 : 1, y: object.transform.flipVertical ? -1 : 1)
                        .blendMode(layerBlend)
                        .offset(x: object.bounds.x * scale, y: object.bounds.y * scale)
                        .opacity(object.opacity * (object.visibleOnAudience ? 1 : 0.32))
                        .hiddenKeepingAlive(object.opacity < 0.02 || !object.visibleOnAudience)
                } else {
                    stack
                        .clipped()
                        .shadow(color: dropShadowColor, radius: dropShadowRadius, x: dropShadowX, y: dropShadowY)
                        .blur(radius: featherRadius)
                        .rotationEffect(.degrees(object.transform.rotation))
                        .scaleEffect(x: object.transform.flipHorizontal ? -1 : 1, y: object.transform.flipVertical ? -1 : 1)
                        .blendMode(layerBlend)
                        .offset(x: object.bounds.x * scale, y: object.bounds.y * scale)
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
    }

    @ViewBuilder
    private func overlayContent(_ state: TransformedRenderState) -> some View {
        if object.isTextLike {
            objectLabel(state)
                .padding(textInsets)
                .frame(width: width, height: height, alignment: textFrameAlignment)
                .clipped()
        } else if object.assignedSource == nil && object.fill.type != .image && (object.kind == .image || object.kind == .videoInput || object.kind == .webView) {
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

    private var textInsets: EdgeInsets {
        EdgeInsets(
            top: object.textLayout.margins.top * scale,
            leading: object.textLayout.margins.left * scale,
            bottom: object.textLayout.margins.bottom * scale,
            trailing: object.textLayout.margins.right * scale
        )
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
        ZStack(alignment: textFrameAlignment) {
            TimelineView(.periodic(from: .now, by: textTimelineInterval)) { timeline in
                let resolved = editing
                    ? object.text
                    : DynamicTextEngine.resolve(object, context: countdownContext(at: timeline.date))
                if object.textLayout.isLooping, !editing {
                    TextLoopMarquee(object: object, text: resolved, scale: scale, reduceMotion: reduceMotion) {
                        styledText(resolved, expands: false)
                    }
                    .allowsHitTesting(false)
                } else {
                    marqueeText(resolved, state: state)
                        .allowsHitTesting(!editing)
                }
            }
            if editing {
                TransparentCanvasTextInput(
                    text: object.text,
                    fontName: object.typography.fontFamily,
                    fontSize: max(1, object.typography.fontSize * scale),
                    weightToken: object.typography.fontWeight,
                    bold: object.typography.isBold,
                    italic: object.typography.isItalic,
                    caret: Color(hex: object.typography.color) ?? .white,
                    alignment: textAlignment,
                    onChange: { onEdit?($0) },
                    onCommit: { latest in onCommit?(latest) }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textFrameAlignment)
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
        var context = dynamicText.ticking(now: date)
        if object.resolvedCountdownValueSource == .programMedia, let playback, playback.duration > 0.05 {
            context.mediaRemainingSeconds = Int(playback.remaining.rounded(.towardZero))
        }
        return context
    }

    @ViewBuilder
    private func marqueeText(_ value: String, state: TransformedRenderState) -> some View {
        if state.usesMarquee {
            Group {
                if state.marqueeVertical {
                    VStack(spacing: max(0, state.marqueeGapPx * scale)) {
                        styledText(value).fixedSize(horizontal: false, vertical: true)
                        styledText(value).fixedSize(horizontal: false, vertical: true)
                    }
                    .offset(y: state.scrollOffsetPx * scale)
                } else {
                    HStack(spacing: max(0, state.marqueeGapPx * scale)) {
                        styledText(value).fixedSize(horizontal: true, vertical: false)
                        styledText(value).fixedSize(horizontal: true, vertical: false)
                    }
                    .offset(x: state.scrollOffsetPx * scale)
                }
            }
        } else {
            styledText(value)
        }
    }

    private func styledText(_ value: String, expands: Bool = true) -> some View {
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
            .modifier(LoopingTextFit(layout: object.textLayout, maxLines: 20))
            .frame(
                maxWidth: expands ? .infinity : nil,
                maxHeight: expands ? .infinity : nil,
                alignment: textFrameAlignment
            )
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

    private var textFrameAlignment: Alignment {
        switch object.textLayout.verticalAlign {
        case .top:
            object.textLayout.horizontalAlign == .right ? .topTrailing : (object.textLayout.horizontalAlign == .center ? .top : .topLeading)
        case .middle:
            object.textLayout.horizontalAlign == .right ? .trailing : (object.textLayout.horizontalAlign == .center ? .center : .leading)
        case .bottom, .baseline:
            object.textLayout.horizontalAlign == .right ? .bottomTrailing : (object.textLayout.horizontalAlign == .center ? .bottom : .bottomLeading)
        }
    }
}

private struct CheckerboardFill: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = 0
                var col = 0
                while x < size.width {
                    if (row + col).isMultiple(of: 2) {
                        context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)), with: .color(Color.white.opacity(0.18)))
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

    var body: some View {
        let ratio = CGFloat(document.canvasWidth / max(document.canvasHeight, 1))
        ZStack {
            if document.backgroundEnabled {
                Color(hex: document.backgroundHex) ?? ProShowTheme.stageBlack
            } else {
                CheckerboardFill()
            }
            ProgramSlideCanvas(
                objects: document.objects,
                canvasWidth: document.canvasWidth,
                canvasHeight: document.canvasHeight,
                evaluationMode: .thumbnailPreview
            )
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
/// Invisible input layer. Visible glyphs always come from SwiftUI `Text` so edit-in-place
/// cannot change family, weight, italic, or size.
private struct TransparentCanvasTextInput: NSViewRepresentable {
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var weightToken: FontWeightToken
    var bold: Bool
    var italic: Bool
    var caret: Color
    var alignment: TextAlignment
    var onChange: (String) -> Void
    var onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> CanvasInputTextView {
        let textView = CanvasInputTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.focusRingType = .none
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.string = text
        applyChrome(to: textView)
        context.coordinator.textView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return textView
    }

    func updateNSView(_ textView: CanvasInputTextView, context: Context) {
        if textView.string != text {
            textView.string = text
        }
        applyChrome(to: textView)
        context.coordinator.onChange = onChange
        context.coordinator.onCommit = onCommit
    }

    private func applyChrome(to textView: CanvasInputTextView) {
        let font = CanvasTypeface.nsFont(
            family: fontName,
            size: fontSize,
            weight: weightToken,
            bold: bold,
            italic: italic
        )
        let style = NSMutableParagraphStyle()
        style.alignment = nsAlignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.clear,
            .paragraphStyle: style,
        ]
        textView.font = font
        textView.alignment = nsAlignment
        textView.textColor = .clear
        textView.insertionPointColor = NSColor(caret)
        textView.typingAttributes = attrs
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.22),
            .foregroundColor: NSColor.clear,
        ]
        let range = NSRange(location: 0, length: textView.string.utf16.count)
        textView.textStorage?.setAttributes(attrs, range: range)
    }

    private var nsAlignment: NSTextAlignment {
        switch alignment {
        case .leading: .left
        case .trailing: .right
        default: .center
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onChange: (String) -> Void
        var onCommit: (String) -> Void
        weak var textView: NSTextView?

        init(onChange: @escaping (String) -> Void, onCommit: @escaping (String) -> Void) {
            self.onChange = onChange
            self.onCommit = onCommit
        }

        func textDidChange(_ notification: Notification) {
            onChange(textView?.string ?? "")
        }

        func textDidEndEditing(_ notification: Notification) {
            onCommit(textView?.string ?? "")
        }
    }
}

private final class CanvasInputTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        focusRingType = .none
        return accepted
    }
}
#else
private struct TransparentCanvasTextInput: View {
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var weightToken: FontWeightToken
    var bold: Bool
    var italic: Bool
    var caret: Color
    var alignment: TextAlignment
    var onChange: (String) -> Void
    var onCommit: (String) -> Void

    var body: some View {
        TextField("", text: Binding(get: { text }, set: onChange), axis: .vertical)
            .textFieldStyle(.plain)
            .font(.custom(fontName.isEmpty ? "Helvetica" : fontName, size: fontSize))
            .foregroundStyle(.clear)
            .tint(caret)
            .multilineTextAlignment(alignment)
            .onSubmit { onCommit(text) }
    }
}
#endif

struct LoopingTextFit: ViewModifier {
    var layout: TextLayout
    var maxLines: Int

    func body(content: Content) -> some View {
        content
            .minimumScaleFactor(layout.isLooping ? 1 : (layout.autoFitMode == .shrink ? 0.2 : 1))
            .lineLimit(layout.isLooping && !layout.resolvedLoopDirection.isVertical ? 1 : (layout.linesOnly == true ? 1 : maxLines))
    }
}

struct TextLoopMarquee<Copy: View>: View {
    var object: CanvasObject
    var text: String
    var scale: CGFloat
    var reduceMotion: Bool
    @ViewBuilder var copy: () -> Copy

    private var direction: TextLoopDirection { object.textLayout.resolvedLoopDirection }
    private var gap: Double { object.textLayout.resolvedLoopGap }

    /// AppKit measurement stays stable; SwiftUI geometry was retuning the scroll cycle mid-flight.
    private var cycleLength: Double {
        if direction.isVertical {
            return BuildAnimationEngine.measuredTextHeight(for: object, text: text)
        }
        return BuildAnimationEngine.measuredTextWidth(for: object, text: text)
    }

    private var stripAlignment: Alignment {
        switch direction {
        case .left: .leading
        case .right: .trailing
        case .up: .top
        case .down: .bottom
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 60.0, paused: reduceMotion)) { timeline in
            let offset = reduceMotion
                ? 0
                : BuildAnimationEngine.marqueeOffset(
                    elapsed: timeline.date.timeIntervalSinceReferenceDate,
                    contentWidth: cycleLength,
                    gap: gap,
                    speed: object.textLayout.resolvedLoopSpeed,
                    left: direction == .left || direction == .up
                )
            Group {
                if direction.isVertical {
                    VStack(spacing: max(0, gap * scale)) {
                        loopCopy(horizontal: false)
                        loopCopy(horizontal: false)
                    }
                    .offset(y: offset * scale)
                } else {
                    HStack(spacing: max(0, gap * scale)) {
                        loopCopy(horizontal: true)
                        loopCopy(horizontal: true)
                    }
                    .offset(x: offset * scale)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: stripAlignment)
            .clipped()
            .transaction { $0.animation = nil }
        }
        .accessibilityLabel(text)
    }

    private func loopCopy(horizontal: Bool) -> some View {
        copy()
            .fixedSize(horizontal: horizontal, vertical: !horizontal)
    }
}
