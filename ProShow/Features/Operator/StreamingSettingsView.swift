import SwiftUI

struct StreamingSettingsView: View {
    @Bindable var controller: ShowController
    @Bindable var store: SettingsStore
    @AppStorage(ProShowFeatureFlags.multiDestinationRoutingV1Key) private var multiDestinationRouting = false
    @State private var isConnecting = false
    @State private var reconnecting: StreamAccount?
    @State private var connectMessage: String?

    private var projectName: String {
        controller.projectDisplayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.lg) {
            SettingsGroup(
                title: "Screens",
                footnote: "Applies on the next Go Live."
            ) {
                SettingsRow(title: "Multiple screens", detail: "Each destination picks Stream or Phone.") {
                    Toggle("Multiple screens", isOn: $multiDestinationRouting)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsGroup(
                title: "Destinations",
                footnote: destinationFootnote
            ) {
                if store.document.accounts.isEmpty {
                    DeskEmptyState(
                        title: "No accounts connected",
                        detail: "Connect YouTube, X, LinkedIn, or custom RTMP. Profile photos appear after sign-in."
                    )
                    .padding(.vertical, 8)
                } else {
                    ForEach(Array(store.document.accounts.enumerated()), id: \.element.id) { index, account in
                        destinationRow(account)
                        if index < store.document.accounts.count - 1 {
                            SettingsHairline()
                        }
                    }
                }

                if !store.document.accounts.isEmpty {
                    SettingsHairline()
                }

                Button {
                    reconnecting = nil
                    isConnecting = true
                } label: {
                    Label("Connect account", systemImage: "plus")
                        .font(DeskType.body)
                        .foregroundStyle(ProShowTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
                .accessibilityLabel("Connect account")
            }

            SettingsGroup(
                title: "Stream theme",
                footnote: "Optional variant for RTMP and ISO encode. Audience windows can use per-display overrides."
            ) {
                SettingsRow(title: "Variant") {
                    Picker("Stream theme variant", selection: streamThemeBinding) {
                        Text("Follow program").tag(UUID?.none)
                        ForEach(controller.themeMenuVariants, id: \.id) { variant in
                            Text(variant.name).tag(Optional(variant.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            }

            SettingsGroup(
                title: "Encoding",
                footnote: "Hardware VideoToolbox H.264 on this Mac. Presets set resolution, frame rate, and bitrate ceiling."
            ) {
                EncoderPresetPickerView(
                    config: Binding(
                        get: { controller.streamEncoderConfig },
                        set: { controller.applyStreamEncoderConfig($0) }
                    ),
                    destinations: encoderDestinations,
                    onCommit: { controller.applyStreamEncoderConfig($0) },
                    showsSectionTitle: false
                )
            }

            if let connectMessage {
                Text(connectMessage)
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.liveRed)
                    .accessibilityLabel(connectMessage)
            }
        }
        .sheet(isPresented: $isConnecting) {
            ConnectDestinationSheet(
                controller: controller,
                isPresented: $isConnecting,
                message: $connectMessage,
                reconnecting: reconnecting
            )
            .presentationBackground(ProShowTheme.canvas)
        }
    }

    private var streamThemeBinding: Binding<UUID?> {
        Binding(
            get: {
                controller.themeProjectSettings.variantID(
                    for: .streamDestination(id: ThemeStreamBinding.programDestinationID)
                )
            },
            set: { value in
                controller.setThemeBinding(
                    value,
                    for: .streamDestination(id: ThemeStreamBinding.programDestinationID)
                )
            }
        )
    }

    private var encoderDestinations: [StreamAccount] {
        let armed = store.document.accounts.filter { controller.streamMatrix.isActive($0.id) }
        return armed.isEmpty ? store.document.accounts : armed
    }

    private func destinationRow(_ account: StreamAccount) -> some View {
        let active = controller.streamMatrix.isActive(account.id)
        return HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: Binding(
                get: { active },
                set: { controller.setStreamDestination(account.id, enabled: $0) }
            )) {
                HStack(alignment: .center, spacing: 12) {
                    StreamDestinationAvatar(account: account, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.accountName)
                            .font(DeskType.bodyEmph)
                            .foregroundStyle(ShowSidebarPalette.title)
                            .lineLimit(1)
                        Text(destinationSubtitle(account))
                            .font(DeskType.meta)
                            .foregroundStyle(
                                account.isAuthenticated ? ProShowTheme.secondaryLabel : ThemeTokens.warningAmber
                            )
                            .lineLimit(2)
                        if multiDestinationRouting {
                            DestinationScreenControls(
                                account: account,
                                store: store,
                                upscaled: streamIsUpscaled(account)
                            )
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 4) {
                if multiDestinationRouting, account.screenKind == .phone {
                    PhoneDestinationThumbnail(boards: selectedSlideBoards) {
                        currentStreamPreview()
                    }
                }
                if account.supportsOAuth {
                    Button("Reconnect") {
                        reconnecting = account
                        isConnecting = true
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .font(DeskType.meta)
                    .accessibilityLabel("Reconnect \(account.accountName)")
                }
                DeskIconButton(systemImage: "trash", label: "Remove \(account.accountName)") {
                    controller.setStreamDestination(account.id, enabled: false)
                    store.removeAccount(account.id)
                }
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.accountName) destination for \(projectName)")
    }

    private var destinationFootnote: String {
        guard multiDestinationRouting else {
            return "One encode on this Mac. Check every target for this project; two or more fan out through the cloud relay."
        }
        let armed = store.document.accounts.filter { controller.streamMatrix.isActive($0.id) }
        let pool = armed.isEmpty ? store.document.accounts : armed
        let members = pool.map {
            LaneMember(
                id: $0.id,
                screen: $0.screenKind,
                scaleMode: $0.scaleMode,
                bitrateBps: max(400_000, $0.targetBitrateKbps * 1000),
                ceilingBps: max(400_000, $0.targetBitrateKbps * 1200)
            )
        }
        let plan = EncodeLaneGrouper.group(members: members, streamPreset: controller.streamEncoderConfig)
        if !plan.refusedIDs.isEmpty {
            return "Max two encodes."
        }
        if plan.lanes.count > 1 {
            return "Live · \(pool.count)"
        }
        return "One Encode"
    }

    private func streamIsUpscaled(_ account: StreamAccount) -> Bool {
        guard account.screenKind == .stream,
              let slideID = controller.selectedSlideID,
              let slide = controller.show.slide(id: slideID),
              let board = slide.editorCanvases.first(where: \.isPrimary)
        else { return false }
        let preset = controller.streamEncoderConfig
        return FrameScale.placement(
            sourceWidth: Int(board.width),
            sourceHeight: Int(board.height),
            destWidth: preset.width,
            destHeight: preset.height,
            mode: .fit
        ).upscaled
    }

    private func destinationSubtitle(_ account: StreamAccount) -> String {
        if account.isAuthenticated {
            return "\(account.platform.title) · \(account.profileSummary)"
        }
        return "\(account.platform.title) · Sign in required"
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

}

private struct DestinationScreenControls: View {
    let account: StreamAccount
    var store: SettingsStore
    var upscaled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Picker("Screen", selection: screenBinding) {
                ForEach(DestinationScreenKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("Screen")

            Picker("Scale", selection: scaleBinding) {
                ForEach(DestinationScaleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 120)
            .accessibilityLabel("Scale")

            if upscaled {
                Text("Upscaled")
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
            }
        }
        }
    }

    private var screenBinding: Binding<DestinationScreenKind> {
        Binding(
            get: { account.screenKind },
            set: { kind in
                var next = account
                next.screenId = kind == .stream ? nil : kind.rawValue
                store.upsert(next, secret: nil)
            }
        )
    }

    private var scaleBinding: Binding<DestinationScaleMode> {
        Binding(
            get: { account.scaleMode },
            set: { mode in
                var next = account
                next.scaleMode = mode
                store.upsert(next, secret: nil)
            }
        )
    }
}

struct PhoneDestinationThumbnail: View {
    var boards: [EditorCanvasFrame]
    var streamImage: () -> PlatformPreviewImage?

    private var phoneBoard: EditorCanvasFrame? {
        boards.first {
            $0.isPhoneArtboard
        }
    }

    private var followsStream: Bool {
        phoneBoard == nil
    }

    var body: some View {
        TimelineView(.periodic(from: TimelineAnchor.start, by: 1)) { _ in
            frame(streamImage())
        }
        .frame(width: 40, height: 72)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(followsStream ? "Phone preview, From Stream" : "Phone preview")
    }

    private func frame(_ image: PlatformPreviewImage?) -> some View {
        ZStack {
            Color.black
            if let phoneBoard {
                objectLayer(phoneBoard)
            } else {
                fittedStream(image)
            }
        }
        .frame(width: 40, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1)
        }
    }

    private func fittedStream(_ image: PlatformPreviewImage?) -> some View {
        VStack(spacing: 0) {
            Color.black.frame(height: 18)
            Group {
                if let image {
                    #if os(macOS)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                    #else
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                    #endif
                } else {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.16))
                }
            }
            .frame(width: 40, height: 22)
            Text("From Stream")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
        }
    }

    private func objectLayer(_ board: EditorCanvasFrame) -> some View {
        let scaleX = 40 / max(board.width, 1)
        let scaleY = 72 / max(board.height, 1)
        return ZStack(alignment: .topLeading) {
            (Color(hex: board.backgroundHex) ?? Color.black)
                .opacity(board.backgroundEnabled ? 1 : 0)
            ForEach(board.objects.sorted { $0.zIndex < $1.zIndex }) { object in
                let width = max(1, object.transform.width * scaleX)
                let height = max(1, object.transform.height * scaleY)
                ZStack {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(hex: object.fill.color) ?? Color.white)
                    if object.isTextLike, !object.text.isEmpty {
                        Text(object.text)
                            .font(.system(size: max(6, object.typography.fontSize * scaleY)))
                            .foregroundStyle(Color(hex: object.typography.color) ?? .white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.4)
                            .frame(width: width, height: height, alignment: .center)
                    }
                }
                .frame(width: width, height: height)
                .offset(x: object.transform.x * scaleX, y: object.transform.y * scaleY)
            }
        }
        .frame(width: 40, height: 72, alignment: .topLeading)
    }
}
