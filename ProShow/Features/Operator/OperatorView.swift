import SwiftUI

/// ProPresenter-class operator desk: task menu + library/media | workspace | output.
struct OperatorView: View {
    @Bindable var controller: ShowController
    var onOpenAudienceWindow: (() -> Void)?
    var onOpenStageWindow: (() -> Void)?
    var onOpenStreamWindow: (() -> Void)?
    var onOpenMultiViewerWindow: (() -> Void)? = nil

    var body: some View {
        let _ = controller.inspector.timers.map { "\($0.id)-\($0.displaySeconds)-\($0.isRunning)-\($0.durationSeconds)" }
        let _ = controller.liveQuotePresentationStamp
        let _ = controller.programFrameRevisionStamp
        VStack(spacing: 0) {
            #if os(macOS)
            AppWorkspaceRouter(controller: controller)
            #else
            TopToolbarView(
                controller: controller,
                onOpenAudience: { onOpenAudienceWindow?() }
            )
            AppWorkspaceRouter(controller: controller)
            if controller.operatorMode != .map {
                programRail
                    .frame(height: 300)
            }
            #endif
        }
        .environment(\.deskWindowActions, DeskWindowActions(
            openAudience: { onOpenAudienceWindow?() },
            openStage: { onOpenStageWindow?() },
            openStream: { onOpenStreamWindow?() },
            openMultiViewer: { onOpenMultiViewerWindow?() }
        ))
        .background(ProShowTheme.canvas.ignoresSafeArea())
        .lockFlickerFreeBackground()
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .environment(\.proShowVideoInputs, controller.videoInputs)
        .environment(\.proShowPlayback, controller.playback)
        .environment(\.resolvePlaceholderSource) { letter in
            controller.resolvedAssignedSource(forPlaceholder: letter)
        }
        .environment(\.dynamicText, controller.canonicalProgramDynamicText())
        .environment(\.liveQuoteEngine, controller.liveQuotes)
        .environment(\.buildClock, controller.liveBuildClock())
        .environment(\.mirrorsProgramPlayer, true)
        .overlay(alignment: .topLeading) {
            #if os(macOS)
            ProgramPlayerOwnerView(playback: controller.playback)
                .id("proshow.program-player-owner")
            #endif
        }
        .onAppear {
            controller.evaluateProgramClockState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .proShowProjectSaveStateChanged)) { _ in
            controller.bumpProjectSaveRevision()
        }
        .sheet(isPresented: Binding(
            get: {
                controller.isAddShotOpen && controller.addShotPurpose != .assignRundownProgramSlide
            },
            set: { if $0 { controller.isAddShotOpen = true } else { controller.closeAddShot() } }
        )) {
            AddShotModalView(controller: controller)
                .frame(
                    maxWidth: AddShotModalView.modalMaxWidth,
                    maxHeight: AddShotModalView.modalMaxHeight
                )
                .frame(minWidth: AddShotModalView.modalWidth, idealWidth: AddShotModalView.modalWidth, maxWidth: AddShotModalView.modalMaxWidth,
               minHeight: AddShotModalView.modalHeight, idealHeight: AddShotModalView.modalHeight, maxHeight: AddShotModalView.modalMaxHeight)
        }
        .sheet(isPresented: $controller.isPreFlightPresented) {
            PreFlightHealthView(controller: controller)
        }
        .sheet(isPresented: $controller.isGoLiveSetupPresented) {
            GoLiveSetupSheet(controller: controller)
                .frame(
                    maxWidth: GoLiveSetupSheet.modalMaxWidth,
                    maxHeight: GoLiveSetupSheet.modalMaxHeight
                )
                .frame(minWidth: GoLiveSetupSheet.modalWidth, idealWidth: GoLiveSetupSheet.modalWidth, maxWidth: GoLiveSetupSheet.modalMaxWidth,
               minHeight: GoLiveSetupSheet.modalHeight, idealHeight: GoLiveSetupSheet.modalHeight, maxHeight: GoLiveSetupSheet.modalMaxHeight)
        }
    }

    private var programRail: some View {
        OutputSidebarView(controller: controller)
            .id("proshow.program-rail")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Bottom center pane: shots and media on one sidebar-style surface.
struct StudioMediaDrawerStack: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            LayerShotStrip(controller: controller)
            MediaBinView(controller: controller)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ShowDrawerPalette.background(scheme))
        .modifier(ShowSidebarSystemScheme())
    }
}

/// List and grid as one control, icon color only for the active mode.
struct PaneLayoutToggle: View {
    var gridOn: Bool
    var listOn: Bool
    var onGrid: () -> Void
    var onList: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            modeButton("square.grid.2x2", label: "Grid view", isOn: gridOn, action: onGrid)
            modeButton("list.bullet", label: "List view", isOn: listOn, action: onList)
        }
        .padding(1)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(ShowSidebarPalette.field(scheme))
        }
        .accessibilityElement(children: .contain)
    }

    private func modeButton(_ systemImage: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? ProShowTheme.accent : ShowSidebarPalette.symbol)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct BorderlessMenuChrome: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        #else
        content
        #endif
    }
}

/// Shots on the selected master layer — adding from the modal lands here and can go live.
struct LayerShotStrip: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme
    @State private var renameShotID: UUID?
    @State private var renameShotTitle = ""

    private var layerIndex: Int {
        min(max(0, controller.addShotLayerIndex), max(controller.masterLayers.count - 1, 0))
    }

    private var layer: MasterLayer? {
        controller.masterLayers.indices.contains(layerIndex) ? controller.masterLayers[layerIndex] : nil
    }

    var body: some View {
        Group {
            if let layer, !layer.shots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(layer.shots) { shot in
                            VStack(alignment: .leading, spacing: 4) {
                                shotThumb(shot, isLive: layer.liveShotID == shot.id)
                                Text(shot.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(ShowSidebarPalette.title)
                                    .lineLimit(1)
                                    .frame(width: 72, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                controller.takeShotLive(shot, layerIndex: layerIndex)
                            }
                            .contextMenu { let _ = MenuRenderProbe.hit("OperatorView:194:LayerShotStrip.body");
                                    LayerShotContextMenu(
                                        controller: controller,
                                        shot: shot,
                                        layerIndex: layerIndex,
                                        isLive: layer.liveShotID == shot.id,
                                        onRename: {
                                            renameShotID = shot.id
                                            renameShotTitle = shot.name
                                        }
                                    )
                                }
                                .workspaceDraggable(WorkspaceDragPayload.shot(shot), controller: controller)
                                .accessibilityLabel(shot.name)
                                .accessibilityAddTraits(layer.liveShotID == shot.id ? .isSelected : [])
                                .accessibilityHint("Drag onto the slide pane to insert. Control-click or right-click for more actions.")
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .focusEffectDisabled()
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Layer shots")
            }
        }
        .alert("Rename Shot", isPresented: Binding(
            get: { renameShotID != nil },
            set: { if !$0 { renameShotID = nil } }
        )) {
            TextField("Name", text: $renameShotTitle)
            Button("Cancel", role: .cancel) { renameShotID = nil }
            Button("Rename") {
                if let id = renameShotID {
                    controller.renameShot(id, layerIndex: layerIndex, to: renameShotTitle)
                }
                renameShotID = nil
            }
        }
    }

    @ViewBuilder
    private func shotThumb(_ shot: LayerShot, isLive: Bool) -> some View {
        let source = shot.source
        ZStack(alignment: .bottomLeading) {
            if let letter = source.placeholderLetter, let mapped = controller.resolvedAssignedSource(forPlaceholder: letter) {
                AssignedSourcePreview(source: mapped, cornerRadius: 8)
            } else if let letter = source.placeholderLetter {
                PlaceholderLetterCard(letter: letter, tintHex: source.tintHex ?? "#D8F5D0", cornerRadius: 8)
            } else if source.sourceType == .solidColor, let hex = source.tintHex ?? source.connectionString {
                SolidColorCard(hex: hex, cornerRadius: 8)
            } else if let tint = Color(hex: source.tintHex ?? "") {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(tint)
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ShowSidebarPalette.field(scheme))
                    .overlay {
                        Image(systemName: "video.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ShowSidebarPalette.symbol)
                            .accessibilityHidden(true)
                    }
            }
        }
        .frame(width: 72, height: 44)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isLive ? StartHome.lemon : Color.clear, lineWidth: 2)
        }
        .accessibilityHint(isLive ? "Live on program" : "Take live")
    }
}

/// Right-click / Control-click actions for master-layer shots (cameras, displays, etc.).
struct LayerShotContextMenu: View {
    @Bindable var controller: ShowController
    let shot: LayerShot
    let layerIndex: Int
    let isLive: Bool
    var onRename: () -> Void

    var body: some View {
        Button(isLive ? "Live on Program" : "Take Live", systemImage: isLive ? "record.circle.fill" : "play.circle") {
            controller.takeShotLive(shot, layerIndex: layerIndex)
        }
        if shot.source.sourceType.needsMainLayerShot {
            Button("Refresh Source", systemImage: "arrow.clockwise") {
                controller.refreshLiveShot(shot.id, layerIndex: layerIndex)
            }
        }
        Button("Replace Source…", systemImage: "arrow.triangle.2.circlepath") {
            controller.openReplaceShot(shotID: shot.id, layerIndex: layerIndex)
        }
        Divider()
        Button("Duplicate", systemImage: "plus.square.on.square") {
            controller.duplicateShot(shot.id, layerIndex: layerIndex)
        }
        Button("Rename…", systemImage: "pencil") {
            onRename()
        }
        if isLive {
            Button("Clear Live", systemImage: "record.circle") {
                let name = controller.masterLayers.displayName(at: layerIndex)
                controller.requestDeskDestructiveConfirm(
                    .clearLiveShot(layerName: name, layerIndex: layerIndex)
                )
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            controller.removeShot(shot.id, layerIndex: layerIndex)
        }
    }
}
