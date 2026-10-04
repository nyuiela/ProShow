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
            TopToolbarView(
                controller: controller,
                projectName: controller.projectDisplayName,
                projectIsDirty: {
                    let _ = controller.projectSaveRevision
                    let _ = controller.documentState.tracker.activeRevision
                    return controller.projectHasUnsavedChanges
                }(),
                onOpenAudience: { onOpenAudienceWindow?() },
                onOpenStage: { onOpenStageWindow?() },
                onOpenStream: { onOpenStreamWindow?() },
                onOpenMultiViewer: { onOpenMultiViewerWindow?() }
            )
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
        .background(ProShowTheme.canvas)
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
        .overlay(alignment: controller.isCanvasEditorPresented ? .bottomTrailing : .bottomLeading) {
            DeskSignalProbeView(controller: controller)
                .padding(8)
        }
        .onAppear {
            controller.evaluateProgramClockState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .proShowProjectSaveStateChanged)) { _ in
            controller.bumpProjectSaveRevision()
        }
        .sheet(isPresented: Binding(
            get: { controller.isAddShotOpen },
            set: { if $0 { controller.isAddShotOpen = true } else { controller.closeAddShot() } }
        )) {
            AddShotModalView(controller: controller)
                .frame(
                    maxWidth: AddShotModalView.modalMaxWidth,
                    maxHeight: AddShotModalView.modalMaxHeight
                )
                .frame(width: AddShotModalView.modalWidth, height: AddShotModalView.modalHeight)
        }
        .sheet(isPresented: $controller.isPreFlightPresented) {
            PreFlightHealthView(controller: controller)
        }
        .sheet(isPresented: $controller.isGoLiveSetupPresented) {
            GoLiveSetupSheet(controller: controller)
        }
    }

    private var programRail: some View {
        OutputSidebarView(controller: controller)
            .id("proshow.program-rail")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Slide/media transport + layout controls sitting between the cue grid and the media pane.
struct WorkspaceControlBar: View {
    @Bindable var controller: ShowController

    var body: some View {
        HStack(spacing: DeskSpace.xs) {
            DeskIconButton(systemImage: "plus", label: "New presentation") {
                _ = controller.addPresentationToActivePlaylist(named: "Untitled \(controller.playlist.items.count + 1)")
            }
            DeskIconButton(systemImage: "plus.rectangle.on.folder", label: "Add shot") {
                controller.openAddShot(layerIndex: controller.addShotLayerIndex)
            }
            Menu {
                ForEach(Array(controller.masterLayers.enumerated()), id: \.element.id) { index, layer in
                    Button(layer.title) { controller.openAddShot(layerIndex: index) }
                }
            } label: {
                Text(controller.masterLayers.indices.contains(controller.addShotLayerIndex)
                     ? controller.masterLayers[controller.addShotLayerIndex].title
                     : "Main Layer 1")
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            .frame(width: 110)
            .accessibilityLabel("Target master layer")
            DeskIconButton(systemImage: "pause.fill", label: "Pause") {
                controller.inspector.pauseTransport()
                controller.tickProgram()
            }
            DeskIconButton(systemImage: "shuffle", label: "Play or pause transport") {
                controller.transportPlayPause()
            }
            DeskIconButton(systemImage: "play.fill", label: "Go live") {
                controller.inspector.playTransport()
                controller.requestGoLive()
                controller.tickProgram()
            }

            Text(String(format: "%.1fs", controller.slideTransitionSeconds))
                .font(DeskType.mono)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .frame(width: 40, alignment: .trailing)
                .accessibilityLabel("Transition \(String(format: "%.1f seconds", controller.slideTransitionSeconds))")
            Slider(value: $controller.slideTransitionSeconds, in: 0...2, step: 0.1)
                .tint(ProShowTheme.accent)
                .frame(maxWidth: 150)
                .accessibilityLabel("Slide transition")

            Spacer(minLength: DeskSpace.md)

            DeskIconButton(systemImage: "square.grid.2x2", label: "Grid view", isOn: controller.slideLayoutMode == .grid) {
                controller.slideLayoutMode = .grid
            }
            DeskIconButton(systemImage: "textformat", label: "Outline view", isOn: controller.slideLayoutMode == .outline) {
                controller.slideLayoutMode = .outline
            }
            DeskIconButton(systemImage: "list.bullet", label: "List view", isOn: controller.slideLayoutMode == .list) {
                controller.slideLayoutMode = .list
            }

            Slider(value: $controller.slideThumbZoom, in: 0.25...1)
                .tint(ProShowTheme.accent)
                .frame(maxWidth: 96)
                .accessibilityLabel("Thumbnail size")
        }
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
    }
}

/// Shots on the selected master layer — adding from the modal lands here and can go live.
struct LayerShotStrip: View {
    @Bindable var controller: ShowController
    @State private var renameShotID: UUID?
    @State private var renameShotTitle = ""

    private var layerIndex: Int {
        min(max(0, controller.addShotLayerIndex), max(controller.masterLayers.count - 1, 0))
    }

    private var layer: MasterLayer? {
        controller.masterLayers.indices.contains(layerIndex) ? controller.masterLayers[layerIndex] : nil
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(layer?.title ?? "Main Layer 1")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ProShowTheme.primaryLabel)
                Text(layer?.shots.isEmpty == false ? "\(layer?.shots.count ?? 0) shots" : "Empty")
                    .font(.system(size: 10))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            .frame(width: 88, alignment: .leading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let layer {
                        ForEach(layer.shots) { shot in
                            shotThumb(shot, isLive: layer.liveShotID == shot.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    controller.takeShotLive(shot, layerIndex: layerIndex)
                                }
                                .contextMenu {
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
                    Button {
                        controller.openAddShot(layerIndex: layerIndex)
                    } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(ProShowTheme.well)
                            .overlay {
                                Image(systemName: "plus")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(ProShowTheme.primaryLabel)
                            }
                            .frame(width: 72, height: 44)
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .accessibilityLabel("Add shot")
                }
            }
            .focusEffectDisabled()
        }
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 8)
        .frame(minHeight: 60)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layer shots")
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
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(hex: source.tintHex ?? "") ?? ProShowTheme.well)
                    .overlay {
                        Text(shot.name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(6)
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
                controller.clearLiveShot(layerIndex: layerIndex)
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            controller.removeShot(shot.id, layerIndex: layerIndex)
        }
    }
}

private struct DeskSignalProbeView: View {
    var controller: ShowController
    @State private var displayed = DeskSignalProbeSnapshot.hidden
    @State private var lastMetricsCommit = Date.distantPast

    private static let metricsRefreshInterval: TimeInterval = 2.0
    private static let pollInterval: TimeInterval = 0.5

    var body: some View {
        Group {
            if displayed.isVisible {
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayed.headline)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(displayed.severity.color)
                    Text(displayed.metrics)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ProShowTheme.primaryLabel.opacity(0.94))
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(nil, value: displayed.metrics)
                    if let advisory = displayed.advisory {
                        Text(advisory)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(displayed.severity.color.opacity(0.95))
                            .fixedSize(horizontal: false, vertical: true)
                            .animation(nil, value: advisory)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: 420, alignment: .leading)
                .background(ProShowTheme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(deskProbeAccessibilityLabel(displayed))
            }
        }
        .task {
            while !Task.isCancelled {
                let fresh = DeskSignalProbeBuilder.make(controller: controller)
                commitDisplay(fresh)
                try? await Task.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    private func commitDisplay(_ fresh: DeskSignalProbeSnapshot) {
        if fresh.isVisible != displayed.isVisible {
            displayed = fresh
            lastMetricsCommit = Date()
            return
        }
        if !fresh.isVisible { return }

        if deskProbeSeverityRank(fresh.severity) > deskProbeSeverityRank(displayed.severity) {
            displayed = fresh
            lastMetricsCommit = Date()
            return
        }
        if fresh.headline != displayed.headline || fresh.advisory != displayed.advisory {
            displayed = fresh
            lastMetricsCommit = Date()
            return
        }

        let elapsed = Date().timeIntervalSince(lastMetricsCommit)
        guard elapsed >= Self.metricsRefreshInterval else { return }
        guard fresh != displayed else { return }
        displayed = fresh
        lastMetricsCommit = Date()
    }

    private func deskProbeSeverityRank(_ severity: DeskSignalSeverity) -> Int {
        switch severity {
        case .hidden: 0
        case .ok: 1
        case .caution: 2
        case .critical: 3
        }
    }

    private func deskProbeAccessibilityLabel(_ snapshot: DeskSignalProbeSnapshot) -> String {
        [snapshot.headline, snapshot.metrics, snapshot.advisory]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ". ")
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
