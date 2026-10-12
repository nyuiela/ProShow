import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MultiScreenManagerView: View {
    @Bindable var controller: ShowController
    @Bindable var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(title: "Connected displays") {
                HStack {
                    Spacer()
                    Button("Refresh") { refreshScreens() }
                        .buttonStyle(DeskPressButtonStyle())
                        .help("Rescan attached displays")
                        .accessibilityLabel("Refresh displays")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)

                if store.document.screens.isEmpty {
                    DeskEmptyState(title: "No displays reported", detail: "Refresh after a monitor is attached.")
                        .padding(14)
                } else {
                    ForEach(Array(store.document.screens.enumerated()), id: \.element.id) { index, screen in
                        SettingsHairline()
                        screenRow(screen)
                    }
                }
            }

            SettingsGroup(title: "Studio window") {
                HStack {
                    Spacer()
                    Button("Open Studio") {
                        #if os(macOS)
                        NotificationCenter.default.post(name: .proShowOpenMultiViewerWindow, object: nil)
                        #endif
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .help("Open the studio window")
                    .accessibilityLabel("Open studio window")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            SettingsGroup(title: "Network and virtual outputs") {
                ndiRow
                SettingsHairline()
                virtualCameraRow
            }

            SettingsGroup(title: "Edge blending") {
                SettingsRow(title: "Blend width") {
                    TextField("px", value: Binding(
                        get: { store.document.blendWidth },
                        set: { store.document.blendWidth = $0; store.save() }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Blend width in pixels")
                }
                SettingsHairline()
                SettingsRow(title: "Gamma") {
                    TextField("γ", value: Binding(
                        get: { store.document.blendGamma },
                        set: { store.document.blendGamma = $0; store.save() }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Blend gamma")
                }
                SettingsHairline()
                SettingsRow(title: "Alignment pattern") {
                    Toggle("Alignment pattern", isOn: Binding(
                        get: { store.document.showAlignmentPattern },
                        set: { store.document.showAlignmentPattern = $0; store.save() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
        .onAppear { refreshScreens() }
    }

    private func screenRow(_ screen: OutputScreenConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                SettingsMark(hex: markHex(for: screen.targetType), systemImage: markImage(for: screen.targetType))
                VStack(alignment: .leading, spacing: 2) {
                    Text(screen.name)
                        .font(DeskType.bodyEmph)
                        .foregroundStyle(ShowSidebarPalette.title)
                    Text("\(Int(screen.width))×\(Int(screen.height)) @ \(Int(screen.refreshHz)) Hz · \(screen.colorProfile)")
                        .font(DeskType.micro)
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                }
                Spacer(minLength: 8)
                Button("Identify") { ScreenIdentifyOverlay.flash(index: screen.displayIndex + 1, on: screen) }
                    .buttonStyle(DeskPressButtonStyle())
                    .help("Flash a number on this display")
                    .accessibilityLabel("Identify \(screen.name)")
            }
            HStack {
                Text("Layout")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                Picker("Layout target for \(screen.name)", selection: targetBinding(screen.id)) {
                    ForEach(ScreenTargetType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Text(screen.alphaKeyEnabled ? "Alpha key on" : "Alpha key off")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
            HStack {
                Text("Theme")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                Picker("Theme variant for \(screen.name)", selection: screenThemeBinding(screen)) {
                    Text("Follow slide").tag(UUID?.none)
                    ForEach(controller.themeMenuVariants, id: \.id) { variant in
                        Text(variant.name).tag(Optional(variant.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var ndiRow: some View {
        SettingsRow(
            title: "NDI broadcast",
            detail: NDIRuntime.isAvailable ? "NDI 6 HX3 available" : "SDK not loaded on this Mac"
        ) {
            TextField("Output name", text: Binding(
                get: { store.document.ndiOutputName },
                set: { store.document.ndiOutputName = $0; store.save() }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .accessibilityLabel("NDI output name")
            .onChange(of: store.document.ndiOutputName) { _, _ in
                controller.syncNDIProgramOutput()
            }
        }
    }

    private var virtualCameraRow: some View {
        SettingsRow(title: "System virtual camera", detail: "CoreMediaIO DAL") {
            Toggle("Virtual camera active", isOn: Binding(
                get: { store.document.virtualCameraEnabled },
                set: { store.document.virtualCameraEnabled = $0; store.save() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private func markHex(for target: ScreenTargetType) -> String {
        switch target {
        case .stageConfidence: "#C9A24A"
        case .multiViewer: "#3B82F6"
        case .ndiOutput: "#2F9E44"
        default: "#6B9FE0"
        }
    }

    private func markImage(for target: ScreenTargetType) -> String {
        switch target {
        case .multiViewer: "rectangle.split.3x3"
        case .ndiOutput: "dot.radiowaves.left.and.right"
        case .virtualCamera: "web.camera"
        default: "display"
        }
    }

    private func screenThemeBinding(_ screen: OutputScreenConfig) -> Binding<UUID?> {
        let outputID = "screen-\(screen.displayIndex + 1)"
        return Binding(
            get: {
                store.document.screens.first(where: { $0.id == screen.id })?.themeVariantID
                    ?? controller.themeProjectSettings.variantID(for: .outputScreen(id: outputID))
            },
            set: { value in
                if let index = store.document.screens.firstIndex(where: { $0.id == screen.id }) {
                    store.document.screens[index].themeVariantID = value
                    store.save()
                }
                controller.setThemeBinding(value, for: .outputScreen(id: outputID))
            }
        )
    }

    private func targetBinding(_ id: UUID) -> Binding<ScreenTargetType> {
        Binding(
            get: { store.document.screens.first(where: { $0.id == id })?.targetType ?? .audienceProgram },
            set: { value in
                if let index = store.document.screens.firstIndex(where: { $0.id == id }) {
                    store.document.screens[index].targetType = value
                    store.save()
                }
                controller.syncNDIProgramOutput()
            }
        )
    }

    private func refreshScreens() {
        let previous = Dictionary(uniqueKeysWithValues: store.document.screens.map { ($0.displayIndex, $0) })
        store.document.screens = ScreenCatalog.settingsTargets().map { next in
            var next = next
            if let old = previous[next.displayIndex] {
                next.id = old.id
                next.targetType = old.targetType
                next.alphaKeyEnabled = old.alphaKeyEnabled
                next.linkedStageLayoutId = old.linkedStageLayoutId
                next.isEnabled = old.isEnabled
                next.colorProfile = old.colorProfile
                next.themeVariantID = old.themeVariantID
            }
            return next
        }
        store.save()
    }
}

enum ScreenIdentifyOverlay {
    #if os(macOS)
    @MainActor
    private static var flashingWindow: NSWindow?

    @MainActor
    static func flash(index: Int, on screen: OutputScreenConfig) {
        let displays = NSScreen.screens
        let target = displays.indices.contains(screen.displayIndex) ? displays[screen.displayIndex] : displays.first
        guard let target else { return }
        let window = NSWindow(
            contentRect: target.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: IdentifyFlashView(index: index))
        window.setFrame(target.frame, display: true)
        flashingWindow = window
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            window.orderOut(nil)
            if flashingWindow === window { flashingWindow = nil }
        }
    }
    #else
    static func flash(index: Int, on screen: OutputScreenConfig) {}
    #endif
}

#if os(macOS)
private struct IdentifyFlashView: View {
    let index: Int

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            Text("\(index)")
                .font(.system(size: 220, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Display \(index)")
    }
}
#endif

extension ScreenCatalog {
    static func settingsTargets() -> [OutputScreenConfig] {
        #if os(macOS)
        return NSScreen.screens.enumerated().map { index, screen in
            let frame = screen.frame
            return OutputScreenConfig(
                displayIndex: index,
                name: screen.localizedName.isEmpty ? "Display \(index + 1)" : screen.localizedName,
                targetType: index == 0 ? .audienceProgram : .stageConfidence,
                originX: frame.origin.x,
                originY: frame.origin.y,
                width: frame.width,
                height: frame.height,
                refreshHz: Double(screen.maximumFramesPerSecond),
                isEnabled: true
            )
        }
        #else
        return [
            OutputScreenConfig(displayIndex: 0, name: "Built-in Display", targetType: .audienceProgram)
        ]
        #endif
    }
}
