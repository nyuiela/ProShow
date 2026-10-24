import SwiftUI

struct SettingsWindowView: View {
    @Bindable var controller: ShowController
    @Bindable var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var query = ""
    @State private var category: SettingsCategory = .general
    @State private var attachedAudio: [StudioAudioDevice] = []
    @FocusState private var searchFocused: Bool
    @AppStorage("proshow.layers.swipeDeleteDirection") private var layerSwipeDeleteDirection = "left"
    @Environment(\.colorScheme) private var scheme

    private var projectName: String {
        controller.projectDisplayName
    }

    private var usesStackedLayout: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if usesStackedLayout {
                stackedLayout
            } else {
                splitLayout
            }
        }
        .frame(
            width: usesStackedLayout ? nil : SettingsModalLayout.width,
            height: usesStackedLayout ? nil : SettingsModalLayout.height
        )
        .modifier(ShowSidebarSystemScheme())
        .onChange(of: query) { _, _ in
            revealCategoryIfHidden()
        }
        .background {
            Button("Find in Settings") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0.001)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    private var splitLayout: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: SettingsModalLayout.sidebarWidth)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 0) {
                settingsHeader
                detail
                settingsFooter
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ShowDrawerPalette.background(scheme))
        }
        .background(ShowSidebarPalette.background(scheme))
    }

    private var stackedLayout: some View {
        VStack(spacing: 0) {
            settingsHeader
            searchField
                .padding(.horizontal, DeskSpace.sm)
                .padding(.vertical, DeskSpace.xs)
            categoryPicker
                .padding(.horizontal, DeskSpace.sm)
                .padding(.bottom, DeskSpace.xs)
            detail
            settingsFooter
        }
        .background(ShowDrawerPalette.background(scheme))
    }

    private var settingsHeader: some View {
        HStack(alignment: .center, spacing: DeskSpace.sm) {
            ProShowMark(side: 22)
            Text("Settings")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, DeskSpace.md)
        .padding(.vertical, DeskSpace.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Settings")
    }

    private var settingsFooter: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .tint(ProShowTheme.accent)
                .controlSize(.regular)
                .help("Close settings")
                .accessibilityLabel("Done")
        }
        .padding(.horizontal, DeskSpace.md)
        .padding(.vertical, DeskSpace.sm)
    }

    private var visibleSections: [(SettingsNavSection, [SettingsCategory])] {
        SettingsNavSection.allCases.compactMap { section in
            let items = section.categories.filter { $0.matches(query) }
            return items.isEmpty ? nil : (section, items)
        }
    }

    private var visibleCategories: [SettingsCategory] {
        visibleSections.flatMap(\.1)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            projectCard
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 10)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if visibleSections.isEmpty {
                        Text("No matching settings")
                            .font(.system(size: 13))
                            .foregroundStyle(ShowSidebarPalette.subtitle)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                    ForEach(visibleSections, id: \.0.id) { section, items in
                        Text(section.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ShowSidebarPalette.subtitle)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(items) { item in
                            categoryRow(item)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ShowSidebarPalette.background(scheme)
                .ignoresSafeArea(edges: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }

    private var projectCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ProShowTheme.accent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 12))
                    .foregroundStyle(controller.streaming.isLive ? ProShowTheme.liveRed : ShowSidebarPalette.subtitle)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(projectName), \(statusLine)")
    }

    private var statusLine: String {
        if controller.streaming.isLive {
            return ProShowCopy.Status.live
        }
        return ProShowCopy.Status.ready
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ShowSidebarPalette.title)
                .focused($searchFocused)
                .accessibilityLabel("Search settings")
                .accessibilityHint("Command F focuses this field.")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                }
                .buttonStyle(DeskPressButtonStyle())
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var categoryPicker: some View {
        Picker("Category", selection: $category) {
            ForEach(visibleCategories) { item in
                Text(item.title).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .accessibilityLabel("Settings category")
    }

    private func categoryRow(_ item: SettingsCategory) -> some View {
        DeskModalNavRow(
            title: item.title,
            systemImage: item.systemImage,
            selected: item == category
        ) {
            select(item)
        }
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DeskSpace.lg) {
                Text(category.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(category.subtitle)
                pane
                    .id(category)
                    .transition(.opacity)
            }
            .padding(DeskSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: DeskMotion.toggle), value: category)
        }
        .background(ShowDrawerPalette.background(scheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(category.title)
    }

    @ViewBuilder
    private var pane: some View {
        switch category {
        case .general: generalPane
        case .streaming: StreamingSettingsView(controller: controller, store: store)
        case .screens: MultiScreenManagerView(controller: controller, store: store)
        case .audio: audioPane
        case .network: networkPane
        case .inputs: inputsPane.onAppear(perform: refreshAttachedInputs)
        case .recording: recordingPane
        case .media: mediaPane
        case .integrations: integrationsPane
        case .ai: aiPane
        case .groups: groupsPane
        case .teleprompter: TeleprompterSettingsPane(settings: .shared)
        case .cloud: cloudPane
        case .updates: updatesPane
        }
    }


    private var aiPane: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(title: "Ask ProShow", footnote: "⌥⌘A opens the Search or Ask overlay. Agent settings stay here.") {
                SettingsRow(title: "AI compose", detail: "Allow the agent to draft slides into AI Draft.") {
                    Toggle("AI compose", isOn: Binding(
                        get: { ProShowFeatureFlags.aiComposeV1 },
                        set: { ProShowFeatureFlags.aiComposeV1 = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsHairline()
                SettingsRow(title: "Provider", detail: "Practice stays on-device. xAI needs a key.") {
                    Picker("Provider", selection: Binding(
                        get: { AIAgentSession.shared.provider },
                        set: { AIAgentSession.shared.provider = $0 }
                    )) {
                        ForEach(AIAgentSession.ProviderChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
            }

            SettingsGroup(title: "xAI") {
                SettingsRow(title: "Status", detail: AIAgentSession.shared.keyConnected ? "Key saved in the stream vault on this Mac." : "No key on this Mac.") {
                    Text(AIAgentSession.shared.keyConnected ? "Connected" : "Missing")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AIAgentSession.shared.keyConnected ? ProShowTheme.accent : ShowSidebarPalette.subtitle)
                }
                SettingsHairline()
                AISettingsKeyRow()
                SettingsHairline()
                SettingsRow(title: "Model", detail: "Default grok-4.3 (low effort, cheapest current). Stored in UserDefaults.") {
                    TextField("grok-4.3", text: Binding(
                        get: { XAIConfig.model },
                        set: { XAIConfig.model = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                }
                SettingsHairline()
                SettingsRow(title: "Reasoning effort", detail: "none is cheapest and fastest; low is the default.") {
                    Picker("", selection: Binding(
                        get: { XAIConfig.reasoningEffort },
                        set: { XAIConfig.reasoningEffort = $0 }
                    )) {
                        ForEach(["none", "low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }
            }

            SettingsGroup(title: "Desk update", footnote: "Optional system note sent with the next Ask turn only.") {
                TextField("Default desk update (optional)", text: Binding(
                    get: { UserDefaults.standard.string(forKey: "proshow.ai.deskUpdateDefault") ?? "" },
                    set: { UserDefaults.standard.set($0, forKey: "proshow.ai.deskUpdateDefault") }
                ), axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            }

            SettingsGroup(
                title: "Conversation history",
                footnote: "Stored under Application Support/ProShow/Agent/History. Cap \(AgentHistoryStore.maxEntries) entries per show."
            ) {
                SettingsRow(
                    title: "Saved turns",
                    detail: AIAgentSession.shared.persistedEntries.isEmpty
                        ? "No Ask history for this show yet."
                        : "\(AIAgentSession.shared.persistedEntries.count) entries on this Mac."
                ) {
                    Button("Clear") { AIAgentSession.shared.clearPersistedHistory() }
                        .disabled(AIAgentSession.shared.persistedEntries.isEmpty)
                }
                if let last = AIAgentSession.shared.persistedEntries.last(where: { $0.deepLink != nil }) {
                    SettingsRow(title: "Last slide link", detail: last.locationLabel ?? last.deepLink) {
                        Button("Open") {
                            if let link = last.deepLink {
                                AIAgentSession.shared.openDeepLink(link)
                            }
                        }
                    }
                }
            }

            SettingsGroup(title: "Canvases", footnote: "Ask always authors Stream 16:9 and Phone 9:16 unless you say Stream-only.") {
                SettingsRow(title: "Default", detail: "stream + phone") {
                    Text("Dual")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ProShowTheme.accent)
                }
            }
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(title: "Startup") {
                SettingsRow(title: "When ProShow opens", detail: "Shift at launch always returns to the start menu.") {
                    Picker("When ProShow opens", selection: Binding(
                        get: { store.document.startup },
                        set: { store.document.startup = $0; store.save() }
                    )) {
                        ForEach(StartupBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            SettingsGroup(title: "Auto-save") {
                SettingsRow(title: "WAL flush", detail: "How often the open project writes its journal.") {
                    Picker("WAL flush", selection: Binding(
                        get: { store.document.walFlushSeconds },
                        set: { value in
                            store.document.walFlushSeconds = value
                            store.save()
                            controller.projectAutosave?.delayNanoseconds = UInt64(value * 1_000_000_000)
                        }
                    )) {
                        Text("1.0 s").tag(1.0)
                        Text("2.0 s").tag(2.0)
                        Text("5.0 s").tag(5.0)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                }
            }
            SettingsGroup(title: "Canvas defaults", footnote: "Used for new projects on this Mac.") {
                SettingsAlignedRow(label: "Background") {
                    HStack(spacing: 8) {
                        CompactColorSwatch(
                            color: Binding(
                                get: { Color(hex: UserSettingsStore.shared.canvasBgColorHex) ?? .black },
                                set: { UserSettingsStore.shared.canvasBgColorHex = $0.hexString(includeAlpha: false) }
                            ),
                            accessibilityLabel: "Default canvas background"
                        )
                        TextField("Hex", text: Binding(
                            get: { UserSettingsStore.shared.canvasBgColorHex },
                            set: { UserSettingsStore.shared.canvasBgColorHex = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .font(InspectorTokens.valueFont)
                        .padding(.horizontal, 6)
                        .frame(width: 72, height: InspectorTokens.controlHeight)
                        .background(ThemeTokens.bgControl, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(ThemeTokens.borderSubtle, lineWidth: 1)
                        }
                    }
                }
                SettingsHairline()
                SettingsRow(title: "Resolution") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Picker("Default resolution", selection: Binding(
                            get: { CaptureBudget.deliveryResolution(store.document.defaultResolution) },
                            set: { store.document.defaultResolution = $0; store.save() }
                        )) {
                            OutputResolutionChoices()
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                }
                SettingsHairline()
                SettingsRow(title: "Frame rate") {
                    Picker("Default frame rate", selection: Binding(
                        get: { store.document.defaultFrameRate },
                        set: { store.document.defaultFrameRate = $0; store.save() }
                    )) {
                        Text("60 fps").tag(TargetFrameRate.fps60)
                        Text("30 fps").tag(TargetFrameRate.fps30)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                }
                SettingsHairline()
                SettingsRow(title: "Restore") {
                    Button("Reset Defaults") {
                        store.resetToFactoryDefaults()
                    }
                    .accessibilityLabel("Reset defaults")
                    .help("Restore factory device settings, layout prefs, stream preset, and clear slide caches.")
                }
            }
            SettingsGroup(title: "This project") {
                SettingsRow(title: "Resolution") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Picker("Project resolution", selection: Binding(
                            get: { CaptureBudget.deliveryResolution(controller.projectSettings.resolution) },
                            set: { value in
                                var next = controller.projectSettings
                                next.resolution = value
                                controller.applyProjectSettings(next)
                            }
                        )) {
                            OutputResolutionChoices()
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        if CaptureBudget.deliveryResolution(controller.projectSettings.resolution) != controller.projectSettings.resolution {
                            Text("Sent at 1080p")
                                .font(DeskType.micro)
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                                .accessibilityLabel("Sent at 1080p")
                        }
                    }
                }
                SettingsHairline()
                SettingsRow(title: "Camera") {
                    Toggle("Capture above output size", isOn: Binding(
                        get: { controller.projectSettings.captureAboveOutput },
                        set: { value in
                            var next = controller.projectSettings
                            next.captureAboveOutput = value
                            controller.applyProjectSettings(next)
                        }
                    ))
                    .help("Larger camera frame for crop and zoom. Off matches the output size.")
                }
                SettingsHairline()
                SettingsRow(title: "Frame rate") {
                    Picker("Project frame rate", selection: Binding(
                        get: { controller.projectSettings.frameRate },
                        set: { value in
                            var next = controller.projectSettings
                            next.frameRate = value
                            controller.applyProjectSettings(next)
                        }
                    )) {
                        ForEach(TargetFrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                }
                SettingsHairline()
                SettingsRow(title: "Scale on resize", detail: "Keep objects proportional when the canvas changes.") {
                    Toggle("Scale elements when this project’s resolution changes", isOn: Binding(
                        get: { controller.projectSettings.scaleContentOnResolutionChange },
                        set: { value in
                            var next = controller.projectSettings
                            next.scaleContentOnResolutionChange = value
                            controller.applyProjectSettings(next)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            SettingsGroup(title: "Appearance") {
                SettingsRow(title: "Theme") {
                    Picker("Appearance", selection: Binding(
                        get: { store.document.appearance },
                        set: { value in
                            store.document.appearance = value
                            store.save()
                            store.applyAppearance()
                        }
                    )) {
                        ForEach(SettingsAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                SettingsHairline()
                SettingsRow(title: "Remove on-air layer", detail: "Swipe a layer this way to delete it.") {
                    Picker("Remove on-air layer", selection: $layerSwipeDeleteDirection) {
                        Text("Swipe left").tag("left")
                        Text("Swipe right").tag("right")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                    .accessibilityLabel("Remove on-air layer")
                }
            }
        }
    }

    private var audioPane: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(title: "Engine") {
                SettingsRow(title: "Sample rate") {
                    Picker("Sample rate", selection: Binding(
                        get: { store.document.audioSampleRate },
                        set: { store.document.audioSampleRate = $0; store.save() }
                    )) {
                        Text("44.1 kHz").tag(44100)
                        Text("48.0 kHz").tag(48000)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                }
                SettingsHairline()
                SettingsRow(title: "Buffer", detail: "128 samples is about 2.6 ms at 48 kHz.") {
                    Picker("Buffer size", selection: Binding(
                        get: { store.document.audioBufferSamples },
                        set: { store.document.audioBufferSamples = $0; store.save() }
                    )) {
                        Text("128").tag(128)
                        Text("256").tag(256)
                        Text("512").tag(512)
                        Text("1024").tag(1024)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 100)
                }
            }
            SettingsGroup(title: "Master ducking") {
                SettingsRow(title: "Threshold", detail: String(format: "%.0f dB", store.document.duckingThresholdDb)) {
                    Slider(value: Binding(
                        get: { store.document.duckingThresholdDb },
                        set: { store.document.duckingThresholdDb = $0; store.save() }
                    ), in: -60...0)
                    .frame(width: 160)
                    .accessibilityLabel("Master ducking threshold")
                    .accessibilityValue(Text(String(format: "%.0f decibels", store.document.duckingThresholdDb)))
                }
                SettingsHairline()
                SettingsRow(title: "Release") {
                    Stepper(
                        "\(store.document.duckingReleaseMs) ms",
                        value: Binding(
                            get: { store.document.duckingReleaseMs },
                            set: { store.document.duckingReleaseMs = $0; store.save() }
                        ),
                        in: 100...2000,
                        step: 50
                    )
                    .accessibilityLabel("Ducking release delay")
                }
            }
        }
    }

    private var networkPane: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(
                title: "Control API",
                footnote: "Binds to 127.0.0.1 only. Other hosts never reach this listener."
            ) {
                SettingsRow(title: "REST API") {
                    Toggle("Enable REST API", isOn: Binding(
                        get: { store.document.controlAPIEnabled },
                        set: { store.document.controlAPIEnabled = $0; store.save() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsHairline()
                SettingsRow(title: "Binding") {
                    Text("127.0.0.1")
                        .font(DeskType.mono)
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                        .accessibilityLabel("Binding IP 127.0.0.1")
                }
                SettingsHairline()
                SettingsRow(title: "Port") {
                    ScrubbableComboInput(
                        label: "",
                        value: Binding(
                            get: { Double(store.document.controlAPIPort) },
                            set: { store.document.controlAPIPort = Int($0.rounded()); store.save() }
                        ),
                        range: 1024...65535,
                        step: 1,
                        unit: "",
                        labelWidth: 0,
                        fieldWidth: 56
                    )
                    .accessibilityLabel("Control API port")
                }
                SettingsHairline()
                SettingsRow(title: "WebSocket", detail: "16 ms / 60 fps telemetry.") {
                    Toggle("WebSocket telemetry", isOn: Binding(
                        get: { store.document.webSocketEnabled },
                        set: { store.document.webSocketEnabled = $0; store.save() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
            SettingsGroup(
                title: "Platform OAuth",
                footnote: "Secrets stay on this Mac. Redirect URIs must match each developer console exactly."
            ) {
                SettingsRow(title: "YouTube secret", detail: "From Google Cloud Credentials.") {
                    OAuthClientSecretField(platform: .youtube)
                }
                SettingsHairline()
                SettingsRow(title: "YouTube redirect") {
                    TextField("Redirect URI", text: Binding(
                        get: { store.document.youtubeRedirectURI },
                        set: { store.document.youtubeRedirectURI = $0; store.save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 280)
                    .accessibilityLabel("YouTube OAuth redirect URI")
                }
                SettingsHairline()
                SettingsRow(title: "LinkedIn secret", detail: "From the LinkedIn Auth tab.") {
                    OAuthClientSecretField(platform: .linkedin)
                }
                SettingsHairline()
                SettingsRow(title: "LinkedIn redirect") {
                    TextField("Redirect URI", text: Binding(
                        get: { store.document.linkedinRedirectURI },
                        set: { store.document.linkedinRedirectURI = $0; store.save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 280)
                    .accessibilityLabel("LinkedIn OAuth redirect URI")
                }
                SettingsHairline()
                SettingsRow(title: "X secret", detail: "From the X developer app. Needed if the app is Confidential.") {
                    OAuthClientSecretField(platform: .twitter)
                }
                SettingsHairline()
                SettingsRow(title: "X redirect", detail: "Must match the X Callback URI exactly. Prefer http://127.0.0.1:55079/") {
                    TextField("Redirect URI", text: Binding(
                        get: { store.document.xRedirectURI },
                        set: { store.document.xRedirectURI = $0; store.save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 280)
                    .accessibilityLabel("X OAuth redirect URI")
                }
                SettingsHairline()
                SettingsRow(title: "Facebook redirect", detail: "Must match the Facebook app.") {
                    TextField("Redirect URI", text: Binding(
                        get: { store.document.facebookRedirectURI },
                        set: { store.document.facebookRedirectURI = $0; store.save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 280)
                    .accessibilityLabel("Facebook OAuth redirect URI")
                }
            }
            SettingsGroup(
                title: "OSC & MIDI",
                footnote: "Listens on this Mac only. Stream Deck, lighting desks, and controllers can send these."
            ) {
                SettingsRow(title: "OSC", detail: "UDP /proshow/slide/next") {
                    Toggle("Enable OSC", isOn: Binding(
                        get: { store.document.oscEnabled },
                        set: { store.document.oscEnabled = $0; store.save() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable OSC")
                }
                SettingsHairline()
                SettingsRow(title: "OSC Port") {
                    ScrubbableComboInput(
                        label: "",
                        value: Binding(
                            get: { Double(store.document.oscPort) },
                            set: { store.document.oscPort = Int($0.rounded()); store.save() }
                        ),
                        range: 1024...65535,
                        step: 1,
                        unit: "",
                        labelWidth: 0,
                        fieldWidth: 56
                    )
                    .accessibilityLabel("OSC port")
                }
                SettingsHairline()
                SettingsRow(title: "MIDI", detail: "Note 60 next, 61 previous, CC7 mute.") {
                    Toggle("Enable MIDI", isOn: Binding(
                        get: { store.document.midiEnabled },
                        set: { store.document.midiEnabled = $0; store.save() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Enable MIDI")
                }
            }
        }
    }

    private var attachedVideo: [StudioVideoSource] {
        controller.videoInputs.attachedSources
    }

    private var inputsPane: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(
                title: "Video",
                footnote: "Cameras and displays attached to this Mac right now."
            ) {
                if attachedVideo.isEmpty {
                    DeskEmptyState(title: "No video devices", detail: "Plug in a camera or connect a display. This list is not a history of past shots.")
                        .padding(12)
                } else {
                    ForEach(Array(attachedVideo.enumerated()), id: \.element.id) { index, source in
                        SettingsRow(title: source.label, detail: videoKindTitle(source.kind)) {
                            if source.kind == .screenShare, let endpoint = source.endpoint, !endpoint.isEmpty {
                                ScreenShareSmoothnessPicker(endpoint: endpoint, ingest: controller.videoInputs.ingest)
                            } else {
                                Image(systemName: "video.fill")
                                    .foregroundStyle(ShowSidebarPalette.subtitle)
                                    .accessibilityHidden(true)
                            }
                        }
                        if index < attachedVideo.count - 1 {
                            SettingsHairline()
                        }
                    }
                }
            }
            SettingsGroup(
                title: "Audio",
                footnote: "Microphones attached to this Mac right now."
            ) {
                if attachedAudio.isEmpty {
                    DeskEmptyState(title: "No audio devices", detail: "System mics appear here when they are connected. Mixer buses live in Audio.")
                        .padding(12)
                } else {
                    ForEach(Array(attachedAudio.enumerated()), id: \.element.id) { index, device in
                        SettingsRow(title: device.name, detail: "Microphone") {
                            Image(systemName: "mic.fill")
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                                .accessibilityHidden(true)
                        }
                        if index < attachedAudio.count - 1 {
                            SettingsHairline()
                        }
                    }
                }
            }
        }
    }

    private func refreshAttachedInputs() {
        controller.videoInputs.refreshDevices()
        attachedAudio = SystemAudioDeviceCatalog().microphones()
    }

    private func videoKindTitle(_ kind: StudioVideoKind) -> String {
        switch kind {
        case .camera: "Camera"
        case .continuity: "Continuity Camera"
        case .captureCard: "Capture Card"
        case .screenShare: "Display"
        case .ndi: "NDI"
        case .webrtc: "Guest"
        case .rtsp: "RTSP"
        }
    }

    private var recordingPane: some View {
        SettingsGroup(
            title: "ISO recording",
            footnote: "Program plus checked camera ISOs write next to the project Recordings folder."
        ) {
            SettingsRow(title: "Video format") {
                Picker("Video format", selection: Binding(
                    get: { store.document.isoCodec },
                    set: { store.document.isoCodec = $0; store.save() }
                )) {
                    Text("Apple ProRes 422").tag("prores")
                    Text("Apple ProRes 4444").tag("prores4444")
                    Text("H.264").tag("h264")
                    Text("HEVC (H.265)").tag("hevc")
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            SettingsHairline()
            SettingsRow(title: "Auto-split") {
                Picker("Auto-split", selection: Binding(
                    get: { store.document.autoSplit },
                    set: { store.document.autoSplit = $0; store.save() }
                )) {
                    Text("2 GB").tag("2 GB")
                    Text("4 GB").tag("4 GB")
                    Text("1 Hour").tag("1 Hour")
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }
        }
    }

    private var mediaPane: some View {
        SettingsGroup(title: "Import") {
            SettingsRow(title: "Copy into bundle", detail: "Off keeps a reference to the original file.") {
                Toggle("Copy imported media into the project bundle", isOn: Binding(
                    get: { store.document.copyMediaIntoBundle },
                    set: { store.document.copyMediaIntoBundle = $0; store.save() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            SettingsHairline()
            SettingsRow(title: "Poster frame") {
                ScrubbableComboInput(
                    label: "",
                    value: Binding(
                        get: { Double(store.document.thumbnailPosterPercent) },
                        set: { store.document.thumbnailPosterPercent = Int($0.rounded()); store.save() }
                    ),
                    range: 0...90,
                    step: 5,
                    unit: "%",
                    labelWidth: 0,
                    fieldWidth: 48
                )
                .accessibilityLabel("Poster frame percentage")
            }
            SettingsHairline()
            SettingsRow(title: "Waveform") {
                Stepper(
                    "\(store.document.waveformSamplesPerSecond)/s",
                    value: Binding(
                        get: { store.document.waveformSamplesPerSecond },
                        set: { store.document.waveformSamplesPerSecond = $0; store.save() }
                    ),
                    in: 25...200,
                    step: 25
                )
                .accessibilityLabel("Waveform samples per second")
            }
        }
    }

    private var integrationsPane: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            SettingsGroup(title: "Hardware") {
                SettingsRow(title: "Stream Deck / Companion", detail: "Incoming connections stay on localhost.") {
                    DeskChip(text: "Listening", color: ProShowTheme.accent.opacity(0.28))
                }
            }
            SettingsGroup(title: "Outbound webhooks") {
                DeskEmptyState(
                    title: "No webhooks configured",
                    detail: "Triggers can fire on show start, slide change, and stream fail. Nothing is sent until you add a URL."
                )
                .padding(14)
            }
            SettingsGroup(title: "Live chat") {
                DeskEmptyState(
                    title: "Tokens stay on this Mac",
                    detail: "YouTube, Twitch, and Facebook tokens are entered from the widget inspector, not from this pane."
                )
                .padding(14)
            }
        }
    }

    private var groupsPane: some View {
        SettingsGroup(title: "Slide groups") {
            ForEach(Array(store.document.groupLabels.enumerated()), id: \.element.id) { index, label in
                SettingsRow(title: label.name, detail: "Hotkey \(label.hotKey)") {
                    Circle()
                        .fill(Color(hex: label.colorHex) ?? ProShowTheme.accent)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("\(label.name) color")
                }
                if index < store.document.groupLabels.count - 1 {
                    SettingsHairline()
                }
            }
        }
    }

    private var cloudPane: some View {
        SettingsGroup(
            title: "Local backups",
            footnote: "Nothing leaves this Mac unless you pick a folder."
        ) {
            DeskEmptyState(
                title: "No backup folder",
                detail: "Cloud sync can copy the .proshow bundle to a folder you choose. This build keeps copies on this Mac only."
            )
            .padding(14)
        }
    }

    private var updatesPane: some View {
        SettingsGroup {
            SettingsRow(title: "Installed", detail: "Check releases when you are ready. This build does not phone home.") {
                Text("ProShow \(AppBuildInfo.display)")
                    .font(DeskType.mono)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
            }
        }
    }

    private func select(_ next: SettingsCategory) {
        guard next != category else { return }
        category = next
    }

    private func revealCategoryIfHidden() {
        guard !visibleCategories.contains(category), let first = visibleCategories.first else { return }
        category = first
    }
}

struct OAuthClientSecretField: View {
    let platform: StreamPlatform
    @State private var draft = ""

    var body: some View {
        SecureField(
            StreamOAuthConfiguration.hasClientSecret(for: platform)
                ? "Saved on this Mac"
                : "Client secret",
            text: $draft
        )
        .textFieldStyle(.roundedBorder)
        .frame(width: 260)
        .accessibilityLabel("\(platform.title) client secret")
        .onChange(of: draft) { _, value in
            StreamOAuthConfiguration.saveClientSecret(value, for: platform)
        }
    }
}

private struct OutputResolutionChoices: View {
    var body: some View {
        Group {
            if CaptureBudget.allows4KOutput() {
                Text("3840 × 2160").tag(DisplayResolution.res4K)
            }
            Text("1920 × 1080").tag(DisplayResolution.res1080p)
            Text("1280 × 720").tag(DisplayResolution.res720p)
        }
    }
}


#if os(macOS)
private struct AISettingsKeyRow: View {
    @State private var keyEntry = ""
    @Bindable private var session = AIAgentSession.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(title: "API key", detail: "Never written into project files or Settings JSON.") {
                EmptyView()
            }
            HStack(spacing: 8) {
                SecureField("xAI API key", text: $keyEntry)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    if session.saveKey(keyEntry) { keyEntry = "" }
                }
                .disabled(keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if session.keyConnected {
                    Button("Remove") { session.clearKey() }
                }
            }
            .font(.system(size: 13))
        }
    }
}
#else
private struct AISettingsKeyRow: View {
    var body: some View {
        SettingsRow(title: "API key", detail: "Configure xAI on Mac.") { EmptyView() }
    }
}
#endif

/// Smooth (30 fps) or Light (15 fps) for one display's screen share.
private struct ScreenShareSmoothnessPicker: View {
    let endpoint: String
    let ingest: VideoIngestEngine
    @State private var value: ScreenShareSmoothness

    init(endpoint: String, ingest: VideoIngestEngine) {
        self.endpoint = endpoint
        self.ingest = ingest
        _value = State(initialValue: ScreenShareSmoothness.current(endpoint: endpoint))
    }

    var body: some View {
        Picker("Screen share frame rate", selection: $value) {
            ForEach(ScreenShareSmoothness.allCases, id: \.self) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityLabel("Screen share frame rate")
        .onChange(of: value) { _, newValue in
            ingest.setScreenShareSmoothness(newValue, endpoint: endpoint)
        }
    }
}
