import SwiftUI

struct MapWorkspaceView: View {
    @Bindable var controller: ShowController
    @State private var testFrame = PlaceholderTransitionFrame.identity

    private var matrix: PlaceholderMatrixEngine { controller.placeholderMatrix }

    var body: some View {
        mapSplit
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StartHome.page)
        .lockFlickerFreeBackground()
        .environment(\.proShowPlayback, controller.playback)
        .environment(\.mirrorsProgramPlayer, true)
        .environment(\.resolvePlaceholderSource) { letter in
            controller.resolvedAssignedSource(forPlaceholder: letter)
        }
        .onAppear { controller.refreshPlaceholderRoutes() }
        .onReceive(Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()) { _ in
            guard matrix.isTesting else { return }
            testFrame = matrix.tickTest(delta: 1.0 / 30.0)
        }
    }

    @ViewBuilder
    private var mapSplit: some View {
        #if os(macOS)
        HSplitView {
            VStack(spacing: 0) {
                SidebarTitleGroupSlot {
                    WorkspaceTitleGroup(controller: controller)
                }
                routerBench
            }
            .frame(minWidth: max(360, DeskLayout.sidebarMin), maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                SidebarTitleGroupSlot(alignment: .trailing) {
                    InspectorTitleGroup(controller: controller)
                }
                inspector
            }
            .frame(minWidth: DeskLayout.inspectorMin, idealWidth: 320, maxWidth: DeskLayout.inspectorMax)
        }
        #else
        VStack(spacing: 0) {
            routerBench
            inspector
                .frame(minHeight: 220, maxHeight: 360)
        }
        #endif
    }

    private var routerBench: some View {
        #if os(macOS)
        VSplitView {
            liveBench
                .frame(minHeight: 140, idealHeight: 260, maxHeight: .infinity)
            graphColumn
                .frame(minHeight: 180, maxHeight: .infinity)
        }
        #else
        VStack(spacing: 0) {
            liveBench
                .frame(minHeight: 140, maxHeight: 260)
            graphColumn
        }
        #endif
    }

    private var graphColumn: some View {
        VStack(spacing: 0) {
            RoutingNodeGraphView(controller: controller) { id in
                matrix.select(id)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            testControls
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var liveBench: some View {
        GeometryReader { geo in
            ZStack {
                StartHome.page
                if let selected = matrix.selected {
                    let fitted = fittedPreviewSize(in: geo.size, aspect: previewAspect(selected.aspectRatio))
                    ZStack {
                        previewContent(selected)
                            .frame(width: fitted.width, height: fitted.height)
                            .clipShape(RoundedRectangle(cornerRadius: selected.cornerRadius, style: .continuous))
                            .offset(x: testFrame.offsetX * 0.12, y: testFrame.offsetY * 0.12)
                            .scaleEffect(testFrame.scale)
                            .opacity(testFrame.opacity)
                        if selected.showTallyBorder {
                            RoundedRectangle(cornerRadius: selected.cornerRadius, style: .continuous)
                                .strokeBorder(tallyColor(selected), lineWidth: 3)
                                .frame(width: fitted.width, height: fitted.height)
                        }
                    }
                    VStack {
                        HStack {
                            Text("Placeholder \(selected.letter) · \(selected.aspectRatio)")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.55), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(12)
                    .foregroundStyle(.white)
                } else {
                    Text("Select a placeholder node")
                        .foregroundStyle(Color.white.opacity(0.4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .topLeading) {
            Text("Live Preview")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.45))
                .padding(12)
        }
    }

    private func previewContent(_ selected: PlaceholderConfiguration) -> some View {
        if let mapped = controller.resolvedAssignedSource(forPlaceholder: selected.letter) {
            let shares = controller.playback.sharesClock(with: mapped)
                || controller.playback.sharesClock(withPlaceholder: selected.letter)
            return AnyView(
                AssignedSourcePreview(
                    source: mapped,
                    cornerRadius: selected.cornerRadius,
                    playsVideo: true,
                    mutesVideo: true,
                    preferSharedProgramClock: shares,
                    style: MediaFrameStyle(
                        cornerRadius: selected.cornerRadius,
                        continuous: selected.squircleSmoothing > 0.01,
                        scaleMode: .fill,
                        opacity: 1,
                        cropX: 0.5,
                        cropY: 0.5,
                        cropZoom: 1
                    )
                )
            )
        }
        return AnyView(
            PlaceholderLetterCard(
                letter: selected.letter,
                tintHex: selected.fallbackColorHex,
                cornerRadius: selected.cornerRadius
            )
        )
    }

    private func previewAspect(_ ratio: String) -> CGFloat {
        switch ratio {
        case "9:16": 9 / 16
        case "4:3": 4 / 3
        case "Square": 1
        default: 16 / 9
        }
    }

    private func fittedPreviewSize(in size: CGSize, aspect: CGFloat) -> CGSize {
        let pad: CGFloat = 28
        let maxWidth = max(120, size.width - pad * 2)
        let maxHeight = max(80, size.height - pad * 2)
        let widthByHeight = maxHeight * aspect
        if widthByHeight <= maxWidth {
            return CGSize(width: widthByHeight, height: maxHeight)
        }
        return CGSize(width: maxWidth, height: maxWidth / aspect)
    }

    private var testControls: some View {
        HStack(spacing: 10) {
            Button("Test Enter") {
                matrix.beginTest(entering: true)
                testFrame = matrix.tickTest(delta: 0)
            }
            Button("Test Exit") {
                matrix.beginTest(entering: false)
                testFrame = matrix.tickTest(delta: 0)
            }
            Button("Swap") {
                controller.swapPlaceholderPreview()
            }
            Button("Simulate Drop") {
                if let id = matrix.selectedID {
                    controller.simulatePlaceholderSignalDrop(id: id)
                }
            }
            Spacer()
        }
        .buttonStyle(MapGhostButtonStyle())
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(inspectorTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            if matrix.selected != nil {
                inspectorTabs
                ScrollView {
                    Group {
                        if let selected = matrix.selected {
                            switch matrix.inspectorTab {
                            case .source: sourcePane(selected)
                            case .geometry: geometryPane(selected)
                            case .transitions: transitionPane(selected)
                            case .macros: macroPane(selected)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Select a placeholder on the map")
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(16)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(StartHome.dock)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(inspectorTitle)
    }

    private var inspectorTabs: some View {
        HStack(spacing: 0) {
            ForEach(MapInspectorTab.allCases) { tab in
                Button {
                    controller.placeholderMatrix.inspectorTab = tab
                } label: {
                    Text(tab.shortTitle)
                        .font(InspectorTokens.sectionHeaderFont)
                        .foregroundStyle(matrix.inspectorTab == tab ? InspectorTokens.headerColor : InspectorTokens.labelColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .frame(height: InspectorTokens.headerHeight)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(matrix.inspectorTab == tab ? InspectorTokens.activeAccent : Color.clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(DeskPressButtonStyle())
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(matrix.inspectorTab == tab ? .isSelected : [])
            }
        }
        .background(ProShowTheme.canvas)
    }

    private var inspectorTitle: String {
        if let node = matrix.selectedGraphNode, node.kind == .inputSource {
            return "Source node"
        }
        if let selected = matrix.selected {
            return "Placeholder \(selected.letter) Properties"
        }
        return "Inspector"
    }

    private func sourcePane(_ selected: PlaceholderConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled("Primary") {
                MapSourceMenuButton(
                    title: "Primary source",
                    sources: controller.placeholderSourceChoices,
                    selectedID: selected.primarySourceId,
                    artworkURL: { controller.artworkURL(forSource: $0) },
                    onPick: { sourceBinding(\.primarySourceId, selected).wrappedValue = $0 },
                    onImport: { url in
                        if let item = controller.importMedia(url: url) {
                            sourceBinding(\.primarySourceId, selected).wrappedValue = item.id.uuidString
                        }
                    }
                )
            }
            labeled("Failover") {
                MapSourceMenuButton(
                    title: "Failover source",
                    sources: controller.placeholderSourceChoices,
                    selectedID: selected.failoverSourceId,
                    artworkURL: { controller.artworkURL(forSource: $0) },
                    onPick: { sourceBinding(\.failoverSourceId, selected).wrappedValue = $0 },
                    onImport: { url in
                        if let item = controller.importMedia(url: url) {
                            sourceBinding(\.failoverSourceId, selected).wrappedValue = item.id.uuidString
                        }
                    }
                )
            }
            Toggle("Mute Audio", isOn: Binding(
                get: { selected.isAudioMuted },
                set: { value in
                    controller.updatePlaceholder(selected.id) { $0.audioMuted = value }
                    controller.applyProgramAudioMute()
                    controller.tickProgram()
                }
            ))
            .accessibilityLabel("Mute placeholder audio")
            Toggle("Auto-Failover Guard", isOn: boolBinding(\.autoFailoverEnabled, selected))
            stepper("Timeout", value: doubleBinding(\.failoverTimeoutSeconds, selected), range: 0.25...8, step: 0.25, format: "%.2fs")
            Toggle("GPU Chroma Key", isOn: boolBinding(\.chromaKeyEnabled, selected))
            if selected.chromaKeyEnabled {
                stepper("Smoothness", value: doubleBinding(\.chromaKeySmoothness, selected), range: 0...1, step: 0.05, format: "%.2f")
            }
        }
        .foregroundStyle(.white)
    }

    private func geometryPane(_ selected: PlaceholderConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled("Aspect") {
                Picker("Aspect", selection: stringBinding(\.aspectRatio, selected)) {
                    ForEach(["16:9", "9:16", "4:3", "Square", "Freeform"], id: \.self) { Text($0).tag($0) }
                }
            }
            stepper("Corner Radius", value: doubleBinding(\.cornerRadius, selected), range: 0...64, step: 1, format: "%.0f")
            stepper("Squircle", value: doubleBinding(\.squircleSmoothing, selected), range: 0...1, step: 0.05, format: "%.2f")
            Toggle("Live Tally Glow", isOn: boolBinding(\.showTallyBorder, selected))
            labeled("Theme variant") {
                Picker("Theme variant", selection: mapThemeBinding(selected)) {
                    Text("Follow program").tag(UUID?.none)
                    ForEach(controller.themeMenuVariants, id: \.id) { variant in
                        Text(variant.name).tag(Optional(variant.id))
                    }
                }
                .labelsHidden()
            }
        }
        .foregroundStyle(.white)
    }

    private func mapThemeBinding(_ selected: PlaceholderConfiguration) -> Binding<UUID?> {
        Binding(
            get: {
                placeholderMatrixValue(selected.id)?.themeVariantID
                    ?? controller.themeProjectSettings.variantID(for: .mapPlaceholder(id: selected.id))
            },
            set: { value in
                controller.updatePlaceholder(selected.id) { $0.themeVariantID = value }
                controller.setThemeBinding(value, for: .mapPlaceholder(id: selected.id))
            }
        )
    }

    private func placeholderMatrixValue(_ id: String) -> PlaceholderConfiguration? {
        controller.placeholderMatrix.placeholders.first { $0.id == id }
    }

    private func transitionPane(_ selected: PlaceholderConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TransitionPickerView(
                selection: Binding(
                    get: { selected.transitionPresetID ?? "dissolve" },
                    set: { value in
                        controller.applyTransitionPreset(TransitionCatalog.preset(id: value), workspace: .mapMatrix)
                    }
                ),
                compact: true
            )
            labeled("Entrance") {
                Picker("Entrance", selection: styleBinding(\.entranceTransition, selected)) {
                    ForEach(TransitionPhysicsStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            labeled("Exit") {
                Picker("Exit", selection: styleBinding(\.exitTransition, selected)) {
                    ForEach(TransitionPhysicsStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            stepper("Duration", value: doubleBinding(\.transitionDurationSec, selected), range: 0.1...3, step: 0.05, format: "%.2fs")
            stepper("Damping", value: doubleBinding(\.springDampingRatio, selected), range: 0.15...1.2, step: 0.05, format: "%.2f")
        }
        .foregroundStyle(.white)
    }

    private func macroPane(_ selected: PlaceholderConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled("On Live") { macroPicker(\.onLiveMacroId, selected) }
            labeled("On Clear") { macroPicker(\.onClearMacroId, selected) }
            labeled("On Failover") { macroPicker(\.onFailoverMacroId, selected) }
        }
        .foregroundStyle(.white)
    }

    private func macroPicker(_ key: WritableKeyPath<PlaceholderConfiguration, UUID?>, _ selected: PlaceholderConfiguration) -> some View {
        Picker("Macro", selection: macroBinding(key, selected)) {
            Text("None").tag(UUID?.none)
            ForEach(controller.inspector.macros) { macro in
                Text(macro.name).tag(Optional(macro.id))
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.4))
            content()
        }
    }

    private func stepper(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(String(format: format, value.wrappedValue))
                .foregroundStyle(Color.white.opacity(0.5))
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
        }
    }

    private func tallyColor(_ item: PlaceholderConfiguration) -> Color {
        switch item.state {
        case .activeLive: ProShowTheme.liveRed
        case .activePreview: Color.green
        case .inactiveStandby: Color.white.opacity(0.28)
        }
    }

    private func sourceBinding(_ key: WritableKeyPath<PlaceholderConfiguration, String?>, _ selected: PlaceholderConfiguration) -> Binding<String?> {
        Binding(
            get: {
                controller.placeholderMatrix.placeholders.first { $0.id == selected.id }?[keyPath: key]
            },
            set: { value in
                controller.updatePlaceholder(selected.id) { $0[keyPath: key] = value }
                if key == \.primarySourceId {
                    controller.reroutePlaceholder(selected.id)
                }
            }
        )
    }

    private func boolBinding(_ key: WritableKeyPath<PlaceholderConfiguration, Bool>, _ selected: PlaceholderConfiguration) -> Binding<Bool> {
        Binding(
            get: { selected[keyPath: key] },
            set: { value in controller.updatePlaceholder(selected.id) { $0[keyPath: key] = value } }
        )
    }

    private func doubleBinding(_ key: WritableKeyPath<PlaceholderConfiguration, Double>, _ selected: PlaceholderConfiguration) -> Binding<Double> {
        Binding(
            get: { selected[keyPath: key] },
            set: { value in controller.updatePlaceholder(selected.id) { $0[keyPath: key] = value } }
        )
    }

    private func stringBinding(_ key: WritableKeyPath<PlaceholderConfiguration, String>, _ selected: PlaceholderConfiguration) -> Binding<String> {
        Binding(
            get: { selected[keyPath: key] },
            set: { value in controller.updatePlaceholder(selected.id) { $0[keyPath: key] = value } }
        )
    }

    private func styleBinding(_ key: WritableKeyPath<PlaceholderConfiguration, TransitionPhysicsStyle>, _ selected: PlaceholderConfiguration) -> Binding<TransitionPhysicsStyle> {
        Binding(
            get: { selected[keyPath: key] },
            set: { value in controller.updatePlaceholder(selected.id) { $0[keyPath: key] = value } }
        )
    }

    private func macroBinding(_ key: WritableKeyPath<PlaceholderConfiguration, UUID?>, _ selected: PlaceholderConfiguration) -> Binding<UUID?> {
        Binding(
            get: { selected[keyPath: key] },
            set: { value in controller.updatePlaceholder(selected.id) { $0[keyPath: key] = value } }
        )
    }
}

private struct MapGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Capsule())
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
    }
}
