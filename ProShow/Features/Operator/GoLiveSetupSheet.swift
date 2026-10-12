import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Broadcast setup. Same sidebar language as the desk: system appearance, ribbon selection, drawer content.
struct GoLiveSetupSheet: View {
    @Bindable var controller: ShowController
    @AppStorage(ProShowFeatureFlags.multiDestinationRoutingV1Key) private var multiDestinationRouting = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var section: BroadcastSetupSection = .thumbnail
    @State private var selectedIDs: Set<UUID> = []
    @State private var expandedIngestAccountIDs: Set<UUID> = []
    @State private var isAdding = false
    @State private var oauthMessage: String?
    @State private var isPickingThumbnail = false
    @State private var thumbnailDropTargeted = false

    static let modalWidth: CGFloat = AddShotModalView.modalWidth
    static let modalHeight: CGFloat = AddShotModalView.modalHeight
    static let modalMaxWidth: CGFloat = AddShotModalView.modalMaxWidth
    static let modalMaxHeight: CGFloat = AddShotModalView.modalMaxHeight

    private var store: SettingsStore { controller.deviceSettings }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                contentPane
                dock
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ShowDrawerPalette.background(scheme))
        }
        .frame(width: Self.modalWidth, height: Self.modalHeight)
        .frame(maxWidth: Self.modalMaxWidth, maxHeight: Self.modalMaxHeight)
        .background(ShowDrawerPalette.background(scheme))
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.sheet, style: .continuous))
        .modifier(ShowSidebarSystemScheme())
        .focusEffectDisabled()
        .onAppear { hydrateSelection() }
        .sheet(isPresented: $isAdding) {
            addAccount
                .presentationBackground(ShowDrawerPalette.background(scheme))
        }
        .fileImporter(
            isPresented: $isPickingThumbnail,
            allowedContentTypes: [.jpeg, .png, .heic, .webP],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                loadThumbnail(from: url)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Broadcast setup")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(controller.streaming.isLive ? ProShowTheme.liveRed : ShowSidebarPalette.symbol)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(sidebarTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(BroadcastSetupSection.allCases) { item in
                        navButton(item.title, systemImage: item.iconName, selected: section == item) {
                            section = item
                        }
                    }
                }
            }
            .focusEffectDisabled()
            .frame(maxHeight: .infinity, alignment: .top)

            Spacer(minLength: 0)

            navButton("Cancel", systemImage: "xmark") { closeSheet() }
                .padding(.bottom, 12)
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 220, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ShowSidebarPalette.background(scheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Broadcast sections")
    }

    private var sidebarTitle: String {
        switch controller.streaming.state {
        case .live: "Live broadcast"
        case .starting: "Connecting"
        default: "Broadcast setup"
        }
    }

    private func navButton(
        _ title: String,
        systemImage: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        DeskModalNavRow(title: title, systemImage: systemImage, selected: selected, action: action)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(controller.streaming.isLive ? ProShowTheme.liveRed : ShowSidebarPalette.subtitle)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.headerTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                headerSubtitle
            }
            Spacer(minLength: 12)

            if section == .destinations, !selectedAccounts.isEmpty {
                outlineChip("\(selectedAccounts.count) selected", selected: true) {}
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var headerSubtitle: some View {
        switch controller.streaming.state {
        case .live:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ProShowCopy.liveClock(StreamingEngine.broadcastTimecode(from: controller.streaming.startedAt, now: context.date)))
                    .font(.system(size: 13))
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .monospacedDigit()
            }
        case .starting:
            Text(ProShowCopy.Status.connecting)
                .font(.system(size: 13))
                .foregroundStyle(ShowSidebarPalette.subtitle)
        case .failed:
            Text(ProShowCopy.error(for: controller.streaming.lastError))
                .font(.system(size: 13))
                .foregroundStyle(ProShowTheme.liveRed.opacity(0.9))
        default:
            Text(section == .destinations && multiDestinationRouting ? "One Encode" : section.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(ShowSidebarPalette.subtitle)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var contentPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch section {
                case .thumbnail:
                    thumbnailSection
                case .details:
                    detailsFields
                case .destinations:
                    destinations
                case .encoder:
                    encoder
                }

                if let error = controller.lastBroadcastError ?? oauthMessage {
                    Text(ProShowCopy.error(for: error))
                        .font(.system(size: 12))
                        .foregroundStyle(ProShowTheme.liveRed)
                        .accessibilityLabel(ProShowCopy.error(for: error))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusEffectDisabled()
    }

    private var thumbnailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        thumbnailDropTargeted ? ProShowTheme.accent : Color.primary.opacity(0.16),
                        lineWidth: thumbnailDropTargeted ? 1.5 : 1
                    )
                thumbnailDropContent
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture { isPickingThumbnail = true }
            .onDrop(of: [.fileURL, .image], isTargeted: $thumbnailDropTargeted) { providers in
                importThumbnail(from: providers)
            }
            .accessibilityLabel("Thumbnail drop zone")
            .accessibilityHint("Drop an image or click to choose. Used for platform live posts.")

            HStack(spacing: 12) {
                Text(thumbnailCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if controller.broadcastMetadata.thumbnailJPEG != nil {
                    Button("Clear") {
                        controller.broadcastMetadata.thumbnailJPEG = nil
                        controller.broadcastMetadata.thumbnailFileName = ""
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .buttonStyle(DeskPressButtonStyle())
                    .accessibilityLabel("Clear thumbnail")
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnailDropContent: some View {
        #if os(macOS)
        if let data = controller.broadcastMetadata.thumbnailJPEG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            emptyThumbnailPrompt
        }
        #else
        emptyThumbnailPrompt
        #endif
    }

    private var emptyThumbnailPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(ShowSidebarPalette.subtitle)
            Text("Drop image here")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            Text("PNG or JPG · optional — program frame if empty")
                .font(.system(size: 12))
                .foregroundStyle(ShowSidebarPalette.subtitle)
        }
        .padding(16)
    }

    private var thumbnailCaption: String {
        let name = controller.broadcastMetadata.thumbnailFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        if controller.broadcastMetadata.thumbnailJPEG != nil { return "Custom thumbnail" }
        return "Uses program frame when live"
    }

    private var detailsFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            fieldBlock("Title") {
                outlineTextField("Broadcast title", text: $controller.broadcastMetadata.title)
                    .accessibilityLabel("Broadcast title")
            }
            fieldBlock("Description") {
                outlineTextEditor(
                    text: $controller.broadcastMetadata.description,
                    minHeight: 72,
                    label: "Broadcast description"
                )
            }
            HStack(alignment: .top, spacing: 14) {
                fieldBlock("Privacy") {
                    Picker("Privacy", selection: $controller.broadcastMetadata.privacy) {
                        ForEach(StreamPrivacyLevel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                fieldBlock("Category") {
                    Picker("Category", selection: $controller.broadcastMetadata.category) {
                        ForEach(BroadcastMetadata.categories, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if selectedAccounts.contains(where: { $0.platform == .twitter }) {
                Text(
                    controller.broadcastMetadata.privacy == .privateAccess
                        ? "Private skips the X go-live post. YouTube and Facebook use their private or unpublished modes."
                        : "X posts a link to your live broadcast using this title and description."
                )
                .font(.system(size: 12))
                .foregroundStyle(ShowSidebarPalette.subtitle)
            }
        }
    }

    private var destinations: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.document.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No accounts")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ShowSidebarPalette.title)
                    Text("Connect YouTube, X, or LinkedIn to choose where you stream.")
                        .font(.system(size: 13))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.document.accounts) { account in
                        destinationRow(account)
                        if selectedIDs.contains(account.id),
                           account.needsManualIngest,
                           expandedIngestAccountIDs.contains(account.id) {
                            DestinationIngestEditor(account: account, store: store)
                        }
                    }
                }
            }

            Button {
                isAdding = true
            } label: {
                Label("Connect account", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ProShowTheme.accent)
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel("Connect a destination")
        }
    }

    private func destinationRow(_ account: StreamAccount) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Toggle(isOn: Binding(
                get: { selectedIDs.contains(account.id) },
                set: { on in
                    if on {
                        selectedIDs.insert(account.id)
                    } else {
                        selectedIDs.remove(account.id)
                        expandedIngestAccountIDs.remove(account.id)
                    }
                    controller.setStreamDestination(account.id, enabled: on)
                }
            )) {
                HStack(alignment: .center, spacing: 12) {
                    StreamDestinationAvatar(account: account, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.accountName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ShowSidebarPalette.title)
                            .lineLimit(1)
                        Text(destinationSubtitle(account))
                            .font(.system(size: 12))
                            .foregroundStyle(account.isAuthenticated ? ShowSidebarPalette.subtitle : ThemeTokens.warningAmber)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.checkbox)

            if multiDestinationRouting, account.screenKind == .phone {
                PhoneDestinationThumbnail(boards: selectedSlideBoards) {
                    currentStreamPreview()
                }
            }
            if selectedIDs.contains(account.id), account.needsManualIngest {
                DeskIconButton(
                    systemImage: "gearshape",
                    label: "Stream settings for \(account.accountName)",
                    isOn: expandedIngestAccountIDs.contains(account.id)
                ) {
                    if expandedIngestAccountIDs.contains(account.id) {
                        expandedIngestAccountIDs.remove(account.id)
                    } else {
                        expandedIngestAccountIDs.insert(account.id)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.accountName) on \(account.platform.title)")
    }

    private var selectedSlideBoards: [EditorCanvasFrame] {
        guard let slideID = controller.selectedSlideID,
              let slide = controller.show.slide(id: slideID) else { return [] }
        return slide.editorCanvases
    }

    private func currentStreamPreview() -> PlatformPreviewImage? {
        #if canImport(CoreVideo)
        guard let buffer = controller.compositor.programOutput.current() else { return nil }
        return InputPreviewImaging.image(from: buffer)
        #else
        return nil
        #endif
    }

    private func destinationSubtitle(_ account: StreamAccount) -> String {
        if account.isAuthenticated {
            return account.platform.title
        }
        return "\(account.platform.title) · Sign in required"
    }

    private var encoderDestinations: [StreamAccount] {
        let chosen = store.document.accounts.filter { selectedIDs.contains($0.id) }
        return chosen.isEmpty ? store.document.accounts : chosen
    }

    private var encoder: some View {
        EncoderPresetPickerView(
            config: Binding(
                get: { controller.streamEncoderConfig },
                set: { controller.applyStreamEncoderConfig($0) }
            ),
            destinations: encoderDestinations,
            onCommit: { controller.applyStreamEncoderConfig($0) },
            showsSectionTitle: false
        )
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Dock

    private var dock: some View {
        HStack(spacing: 12) {
            dockBadge
            VStack(alignment: .leading, spacing: 2) {
                Text(dockTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(1)
                Text(dockSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button("Cancel") { closeSheet() }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ShowSidebarPalette.title)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(ShowSidebarPalette.field(scheme), in: Capsule(style: .continuous))
                .buttonStyle(DeskPressButtonStyle())
                .keyboardShortcut(.cancelAction)

            if controller.streaming.isLive {
                Button("Stop broadcast") {
                    controller.stopBroadcast()
                    closeSheet()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(ProShowTheme.liveRed, in: Capsule(style: .continuous))
                .buttonStyle(DeskPressButtonStyle())
            } else {
                Button {
                    Task { await start() }
                } label: {
                    Text(controller.isProvisioningStreams ? "Provisioning…" : "Start broadcasting")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(canStart && !controller.isProvisioningStreams ? ProShowTheme.liveRed : ShowSidebarPalette.field(scheme), in: Capsule(style: .continuous))
                .buttonStyle(DeskPressButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isProvisioningStreams || !canStart)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(ShowSidebarPalette.background(scheme))
    }

    @ViewBuilder
    private var dockBadge: some View {
        #if os(macOS)
        if let data = controller.broadcastMetadata.thumbnailJPEG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let account = selectedAccounts.first {
            StreamDestinationAvatar(account: account, size: 44)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ProShowTheme.sandboxOrange)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
        }
        #else
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(ProShowTheme.sandboxOrange)
            .frame(width: 44, height: 44)
        #endif
    }

    private var dockTitle: String {
        let title = controller.broadcastMetadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled broadcast" : title
    }

    private var dockSubtitle: String {
        let count = selectedAccounts.count
        let dest = count == 0 ? "No destinations" : (count == 1 ? "1 destination" : "\(count) destinations")
        let preset = StreamEncoderPreset.named(controller.streamEncoderConfig.presetName)?.menuTitle
            ?? controller.streamEncoderConfig.presetName
        return "\(dest) · \(preset)"
    }

    // MARK: Field chrome

    private func fieldBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
            content()
        }
    }

    private func outlineTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(ShowSidebarPalette.title)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func outlineTextEditor(text: Binding<String>, minHeight: CGFloat, label: String) -> some View {
        TextEditor(text: text)
            .font(.system(size: 13))
            .foregroundStyle(ShowSidebarPalette.title)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: minHeight)
            .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(label)
    }

    private func outlineChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : ShowSidebarPalette.title)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? ProShowTheme.accent : ShowSidebarPalette.field(scheme), in: Capsule(style: .continuous))
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var addAccount: some View {
        ConnectDestinationSheet(controller: controller, isPresented: $isAdding, message: $oauthMessage)
    }

    private func closeSheet() {
        controller.isGoLiveSetupPresented = false
        dismiss()
    }

    private func hydrateSelection() {
        if controller.streamMatrix.activeAccountIds.isEmpty, let first = store.document.accounts.first {
            selectedIDs = [first.id]
            controller.setStreamDestination(first.id, enabled: true)
        } else {
            selectedIDs = controller.streamMatrix.activeAccountIds
        }
    }

    private var selectedAccounts: [StreamAccount] {
        store.document.accounts.filter { selectedIDs.contains($0.id) }
    }

    private var canStart: Bool {
        let selected = selectedAccounts
        guard !selected.isEmpty else { return false }
        return selected.allSatisfy { !$0.needsManualIngest || $0.hasStoredStreamKey }
    }

    private func importThumbnail(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else { return false }

        let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            ? UTType.fileURL.identifier
            : UTType.image.identifier

        provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
            DispatchQueue.main.async {
                if let url = item as? URL {
                    loadThumbnail(from: url)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    loadThumbnail(from: url)
                }
            }
        }
        return true
    }

    private func loadThumbnail(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let jpeg = BroadcastThumbnailEncoder.jpeg(fromImageData: data)
        else { return }
        controller.broadcastMetadata.thumbnailJPEG = jpeg
        controller.broadcastMetadata.thumbnailFileName = url.lastPathComponent
    }

    private func start() async {
        let accounts = store.document.accounts.filter { selectedIDs.contains($0.id) }
        _ = await controller.startMultiPlatformBroadcast(
            metadata: controller.broadcastMetadata,
            accounts: accounts
        )
    }
}

// MARK: Sections

private enum BroadcastSetupSection: String, CaseIterable, Identifiable {
    case thumbnail
    case details
    case destinations
    case encoder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thumbnail: "Thumbnail"
        case .details: "Details"
        case .destinations: "Destinations"
        case .encoder: "Encode"
        }
    }

    var iconName: String {
        switch self {
        case .thumbnail: "photo"
        case .details: "text.alignleft"
        case .destinations: "antenna.radiowaves.left.and.right"
        case .encoder: "waveform.path"
        }
    }

    var headerTitle: String {
        switch self {
        case .thumbnail: "Thumbnail"
        case .details: "Broadcast details"
        case .destinations: "Destinations"
        case .encoder: "Encoding"
        }
    }

    var subtitle: String {
        switch self {
        case .thumbnail: "Cover for live posts."
        case .details: "Title and visibility."
        case .destinations: "One encode. Extras use relay."
        case .encoder: "Resolution and bitrate."
        }
    }
}

private struct DestinationIngestEditor: View {
    let account: StreamAccount
    @Bindable var store: SettingsStore
    @State private var draftKey = ""
    @State private var hasSavedKey = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(account.platform.ingestHint)
                .font(.system(size: 12))
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .fixedSize(horizontal: false, vertical: true)
            ingestField("RTMP URL", text: urlBinding)
            SecureField(hasSavedKey ? "Stream key saved" : "Stream key", text: $draftKey)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(ShowSidebarPalette.title)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: draftKey) { _, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.upsert(account, secret: trimmed)
                    hasSavedKey = true
                }
            if let studio = account.platform.studioURL {
                Button("Open \(account.platform.title) studio") {
                    #if os(macOS)
                    NSWorkspace.shared.open(studio)
                    #endif
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ProShowTheme.accent)
                .buttonStyle(DeskPressButtonStyle())
            }
        }
        .padding(.leading, 14)
        .padding(.vertical, 4)
        .onAppear {
            hasSavedKey = account.hasStoredStreamKey
        }
    }

    private func ingestField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(ShowSidebarPalette.title)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: {
                store.document.accounts.first(where: { $0.id == account.id })?.rtmpUrl ?? account.rtmpUrl
            },
            set: { value in
                var next = store.document.accounts.first(where: { $0.id == account.id }) ?? account
                next.rtmpUrl = value.trimmingCharacters(in: .whitespacesAndNewlines)
                store.upsert(next, secret: nil)
            }
        )
    }
}
