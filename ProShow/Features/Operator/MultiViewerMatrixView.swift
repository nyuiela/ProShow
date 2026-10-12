import SwiftUI

/// Edge-to-edge 16:9 MultiViewer: grid viewport plus a 36 pt toolbar.
struct MultiViewerMatrixView: View {
    @Bindable var controller: ShowController
    var showsInspector: Bool = false
    @State private var isConfigOpen = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let frames = MultiViewerGridEngine.calculateGridFrames(
                    containerSize: proxy.size,
                    preset: controller.multiViewerLayout.grid
                )
                let tiles = controller.multiViewerLayout.orderedTiles
                ZStack(alignment: .topLeading) {
                    ProShowTheme.stageBlack
                    ForEach(frames) { frame in
                        if tiles.indices.contains(frame.id) {
                            MultiViewerTileView(controller: controller, tile: tiles[frame.id])
                                .frame(width: frame.rect.width, height: frame.rect.height)
                                .position(x: frame.rect.midX, y: frame.rect.midY)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            MultiViewerToolbarView(controller: controller, isConfigOpen: $isConfigOpen)
            if showsInspector {
                MultiViewerInspector(controller: controller)
                    .frame(height: 200)
            }
        }
        .background(ProShowTheme.stageBlack)
        .onAppear {
            controller.ensureMultiViewerLayout()
            controller.tickProgram()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MultiViewer")
    }
}

struct MultiViewerTileView: View {
    @Bindable var controller: ShowController
    let tile: MultiViewerTileConfig
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tally = controller.multiViewerTally(for: tile)
        ZStack(alignment: .bottom) {
            ProShowTheme.stageBlack
            feed
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            tallyStroke(tally)
            if tile.type != .audioMeterBridge {
                footer(tally: tally)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(resolvedTitle), \(tally.label)")
    }

    @ViewBuilder
    private var feed: some View {
        switch tile.type {
        case .program:
            SharedTextureHostView(style: .plain)
                .background(ProShowTheme.stageBlack)
        case .preview:
            OperatorPreviewPicture(controller: controller)
        case .phoneProgram:
            PhoneCanvasPicture(controller: controller, feed: .stream)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .phonePreview:
            PhoneCanvasPicture(controller: controller, feed: .audience)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .cameraInput, .displayShare:
            inputFeed
        case .stageMonitor:
            StageDisplayView(controller: controller)
        case .audioMeterBridge:
            MultiViewerAudioBridgeView(controller: controller)
        }
    }

    @ViewBuilder
    private var inputFeed: some View {
        if let source = controller.multiViewerVideoSource(id: tile.sourceId) {
            ZStack {
                ProShowTheme.stageBlack
                LivePixelPreview(
                    endpoint: source.endpoint,
                    sourceID: source.id.uuidString
                )
            }
        } else {
            tilePlaceholder(tile.type == .displayShare ? "No display assigned" : "No camera assigned")
        }
    }

    private func tallyStroke(_ tally: MultiViewerTally) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .strokeBorder(borderColor(tally), lineWidth: tally.borderWidth)
            .shadow(
                color: reduceMotion || tally == .standby ? .clear : borderColor(tally).opacity(0.45),
                radius: 4
            )
            .allowsHitTesting(false)
    }

    private func footer(tally: MultiViewerTally) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(ProShowTheme.lyricWhite)
                    .frame(width: 5, height: 5)
                Text(tally.label)
                    .font(DeskType.mono.weight(.bold))
                    .foregroundStyle(ProShowTheme.lyricWhite)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(borderColor(tally), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityHidden(true)

            Text(resolvedTitle)
                .font(DeskType.meta.weight(.semibold))
                .foregroundStyle(ProShowTheme.lyricWhite)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(controller.multiViewerFormatLabel(for: tile))
                .font(DeskType.mono)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .lineLimit(1)

            if tile.showAudioMeter {
                MicroVuMeterView(peakDb: controller.multiViewerPeakDb(for: tile))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(ProShowTheme.titlebar.opacity(0.92))
    }

    private var resolvedTitle: String {
        let custom = tile.customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        if let source = controller.multiViewerVideoSource(id: tile.sourceId) {
            return source.label
        }
        return tile.type.title
    }

    private func borderColor(_ tally: MultiViewerTally) -> Color {
        switch tally {
        case .program: ProShowTheme.liveRed
        case .preview: ProShowTheme.meterSafe
        case .standby: ProShowTheme.hairline
        }
    }

    private func tilePlaceholder(_ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: tile.type.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(ProShowTheme.secondaryLabel)
            Text(detail)
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProShowTheme.stageBlack)
    }
}

private struct MicroVuMeterView: View {
    var peakDb: Double

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<8, id: \.self) { index in
                let threshold = -40.0 + Double(index) * 5.5
                Rectangle()
                    .fill(barColor(threshold: threshold, active: peakDb >= threshold))
                    .frame(width: 2, height: 8)
            }
        }
        .accessibilityLabel("Tile meter")
        .accessibilityValue(peakDb <= -80 ? "Silent" : String(format: "%.0f dB", peakDb))
    }

    private func barColor(threshold: Double, active: Bool) -> Color {
        guard active else { return ProShowTheme.well }
        if threshold >= -3 { return ProShowTheme.liveRed }
        if threshold >= -12 { return ProShowTheme.meterWarn }
        return ProShowTheme.meterSafe
    }
}

struct MultiViewerInspector: View {
    @Bindable var controller: ShowController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tile assignment")
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                Spacer()
                Button("Fill from sources") { controller.resetMultiViewerFromSources() }
                    .buttonStyle(DeskPressButtonStyle())
                    .accessibilityLabel("Fill MultiViewer from live sources")
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(Array(controller.multiViewerLayout.orderedTiles.enumerated()), id: \.element.id) { index, tile in
                        tileRow(tile, index: index)
                    }
                }
            }
            HStack {
                Button("Add tile") { controller.addMultiViewerTile() }
                    .buttonStyle(DeskPressButtonStyle())
                    .disabled(controller.multiViewerLayout.tiles.count >= controller.multiViewerLayout.grid.capacity)
                Spacer()
            }
        }
        .padding(10)
        .background(ProShowTheme.panel)
    }

    private func tileRow(_ tile: MultiViewerTileConfig, index: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: tile.type.systemImage)
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .frame(width: 16)
            Picker("Type", selection: typeBinding(tile.id)) {
                ForEach(MultiTileType.allCases) { type in
                    Text(type.title).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            if tile.type == .cameraInput || tile.type == .displayShare {
                Picker("Source", selection: sourceBinding(tile.id)) {
                    Text("Unassigned").tag("")
                    ForEach(controller.multiViewerAssignableSources(for: tile.type), id: \.id) { source in
                        Text(source.label).tag(source.id.uuidString)
                    }
                }
                .labelsHidden()
            }
            TextField("Title", text: titleBinding(tile.id))
                .textFieldStyle(.roundedBorder)
            Toggle("Meter", isOn: meterBinding(tile.id))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Show tile meter")
            Button {
                controller.moveMultiViewerTile(id: tile.id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(minWidth: DeskLayout.hit, minHeight: DeskLayout.hit)
            }
            .buttonStyle(DeskPressButtonStyle())
            .disabled(index == 0)
            .accessibilityLabel("Move tile up")
            Button {
                controller.moveMultiViewerTile(id: tile.id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(minWidth: DeskLayout.hit, minHeight: DeskLayout.hit)
            }
            .buttonStyle(DeskPressButtonStyle())
            .disabled(index >= controller.multiViewerLayout.tiles.count - 1)
            .accessibilityLabel("Move tile down")
            Button {
                controller.removeMultiViewerTile(id: tile.id)
            } label: {
                Image(systemName: "minus.circle")
                    .frame(minWidth: DeskLayout.hit, minHeight: DeskLayout.hit)
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel("Remove tile")
        }
        .font(DeskType.meta)
    }

    private func typeBinding(_ id: UUID) -> Binding<MultiTileType> {
        Binding(
            get: { controller.multiViewerLayout.tiles.first(where: { $0.id == id })?.type ?? .program },
            set: { value in controller.updateMultiViewerTile(id: id) { $0.type = value } }
        )
    }

    private func sourceBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { controller.multiViewerLayout.tiles.first(where: { $0.id == id })?.sourceId ?? "" },
            set: { value in controller.updateMultiViewerTile(id: id) { $0.sourceId = value } }
        )
    }

    private func titleBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { controller.multiViewerLayout.tiles.first(where: { $0.id == id })?.customTitle ?? "" },
            set: { value in controller.updateMultiViewerTile(id: id) { $0.customTitle = value } }
        )
    }

    private func meterBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { controller.multiViewerLayout.tiles.first(where: { $0.id == id })?.showAudioMeter ?? true },
            set: { value in controller.updateMultiViewerTile(id: id) { $0.showAudioMeter = value } }
        )
    }
}
