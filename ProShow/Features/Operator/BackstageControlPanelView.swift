import SwiftUI

/// Backstage green room, virtual camera status, and live chat stream controls.
struct BackstageControlPanelView: View {
    @Bindable var controller: ShowController
    @Environment(\.colorScheme) private var scheme
    @State private var guestPendingRemoval: LiveKitGuestFeed?

    private var backstage: ProShowBackstageEngine { controller.backstage }
    private var chatStream: LiveChatStreamManager? { controller.chatStream }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DeskSpace.md) {
                backstageSection
                chatSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Backstage")
        .onAppear { controller.activateGuestRoomIfNeeded() }
        .confirmationDialog(
            guestPendingRemoval.map { "Remove \($0.name)?" } ?? "Remove guest?",
            isPresented: Binding(
                get: { guestPendingRemoval != nil },
                set: { if !$0 { guestPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let feed = guestPendingRemoval {
                    controller.removeLiveKitGuest(identity: feed.identity)
                }
                guestPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                guestPendingRemoval = nil
            }
        } message: {
            Text("They leave the room. Their audio strip is removed.")
        }
    }

    @State private var roomNameDraft = ""
    @State private var roomNameInvalid = false
    @State private var roomNameEditing = false

    private func applyRoomName() {
        roomNameInvalid = !controller.setBackstageRoomName(roomNameDraft)
        if !roomNameInvalid {
            roomNameDraft = ""
            roomNameEditing = false
        }
    }

    private var virtualCameraOn: Binding<Bool> {
        Binding(
            get: { controller.deviceSettings.document.virtualCameraEnabled },
            set: { value in
                controller.deviceSettings.document.virtualCameraEnabled = value
                controller.deviceSettings.save()
                controller.virtualCameraOutput?.setPublishing(value)
                controller.syncVirtualAudioLoopbackPublishing()
            }
        )
    }

    /// Room, guests, return feed, talk and virtual camera in one flat section.
    private var backstageSection: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            HStack(spacing: 6) {
                DeskSectionTitle(title: "Backstage")
                    .fixedSize()
                if controller.deviceSettings.document.virtualCameraEnabled {
                    Image(systemName: "web.camera.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ProShowTheme.statusOn)
                        .help("Virtual camera on")
                        .accessibilityLabel("Virtual camera on")
                }
                Spacer(minLength: 4)
                TalkPillButton(controller: controller)
                returnFeedMenu
                backstageMoreMenu
            }
            HStack(spacing: 6) {
                Text(backstage.inviteURLString)
                    .font(DeskType.mono)
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button { controller.copyBackstageInviteLink() } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                }
                .buttonStyle(.borderless)
                .help("Copy link")
                .accessibilityLabel("Copy invite link")
            }
            if roomNameEditing {
                HStack(spacing: 6) {
                    TextField("Room name", text: $roomNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { applyRoomName() }
                    Button("Set") { applyRoomName() }
                        .controlSize(.small)
                    Button { roomNameEditing = false; roomNameInvalid = false } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .help("Cancel")
                    .accessibilityLabel("Cancel rename")
                }
                if roomNameInvalid {
                    Text("3 to 40 lowercase letters, numbers or dashes")
                        .font(DeskType.micro)
                        .foregroundStyle(.red)
                }
            }
            if let output = controller.virtualCameraOutput, output.needsExtension,
               controller.deviceSettings.document.virtualCameraEnabled {
                Text(output.blockedReason ?? "Camera extension missing.")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.sandboxOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.liveKitDesk.guests.isEmpty {
                Text(controller.liveKitDesk.status)
                    .font(DeskType.micro)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isStaticText)
            } else {
                ForEach(controller.liveKitDesk.guests) { feed in
                    guestRow(feed)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var returnFeedMenu: some View {
        let mode = controller.backstage.returnFeedMode
        return Menu {
            Picker("Return feed", selection: Binding(
                get: { controller.backstage.returnFeedMode },
                set: { controller.setReturnMode(identity: nil, mode: $0) }
            )) {
                ForEach(BackstageReturnFeedMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.uturn.backward")
                Text(mode.pickerShortLabel)
            }
            .font(DeskType.micro)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .controlSize(.small)
        .fixedSize()
        .help("Return feed to guests")
        .accessibilityLabel("Return feed, \(mode.rawValue)")
    }

    private var backstageMoreMenu: some View {
        Menu {
            Button("Copy link") { controller.copyBackstageInviteLink() }
            Button("New room") { controller.newGuestRoom() }
            Button("Rename room") { roomNameEditing = true }
            Divider()
            Toggle("Virtual camera", isOn: virtualCameraOn)
        } label: {
            Text("More").font(DeskType.micro)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("More backstage options")
    }

    private func guestRow(_ feed: LiveKitGuestFeed) -> some View {
        let guestID = LiveKitGuestEndpoint.stableID(feed.identity)
        let profile = backstage.guests.first(where: { $0.id == guestID || $0.profile.id == guestID })?.profile
        let muted = profile?.isAudioMuted ?? false
        let videoOff = profile?.isVideoDisabled ?? false
        let onAir = profile?.connectionStatus == .liveOnAir
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "person.crop.rectangle")
                    .font(.body)
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .accessibilityHidden(true)
                Text(feed.name)
                    .font(DeskType.bodyEmph)
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let profile {
                    statusChip(profile.connectionStatus)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { guestControls(feed, muted: muted, videoOff: videoOff, onAir: onAir) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 28), spacing: 8)], alignment: .leading, spacing: 8) {
                    guestControls(feed, muted: muted, videoOff: videoOff, onAir: onAir)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            InspectorSelectionRibbon(selected: onAir, color: ProShowTheme.liveRed)
        }
    }

    @ViewBuilder
    private func guestControls(
        _ feed: LiveKitGuestFeed,
        muted: Bool,
        videoOff: Bool,
        onAir: Bool
    ) -> some View {
        guestIconButton(
            systemName: muted ? "mic.slash.fill" : "mic.fill",
            label: muted ? "Unmute \(feed.name)" : "Mute \(feed.name)",
            active: muted
        ) {
            ensureGuest(feed)
            controller.muteLiveKitGuest(identity: feed.identity, muted: !muted)
        }
        guestIconButton(
            systemName: videoOff ? "video.slash.fill" : "video.fill",
            label: videoOff ? "Show \(feed.name)’s video" : "Hide \(feed.name)’s video",
            active: videoOff
        ) {
            ensureGuest(feed)
            controller.setLiveKitGuestVideoDisabled(identity: feed.identity, disabled: !videoOff)
        }
        guestIconButton(
            systemName: onAir ? "pause.fill" : "dot.radiowaves.left.and.right",
            label: onAir ? "Hold \(feed.name)" : "Take \(feed.name) live",
            active: onAir
        ) {
            let id = ensureGuest(feed)
            backstage.setGuestOnAir(id: id, onAir: !onAir)
        }
        guestIconButton(systemName: "arrow.up.right.square", label: "Route \(feed.name)’s video") {
            let id = ensureGuest(feed)
            controller.routeGuestToCanvas(guestID: id)
        }
        guestIconButton(systemName: "minus.circle", label: "Remove \(feed.name)") {
            guestPendingRemoval = feed
        }
    }

    @discardableResult
    private func ensureGuest(_ feed: LiveKitGuestFeed) -> UUID {
        let id = LiveKitGuestEndpoint.stableID(feed.identity)
        _ = backstage.connectSignaledGuest(
            id: id,
            displayName: feed.name,
            cameraEndpoint: LiveKitGuestEndpoint.camera(room: backstage.room.roomSlug, identity: feed.identity)
        )
        _ = controller.audioMatrix.ensureGuestChannel(guestID: id, displayName: feed.name)
        return id
    }

    private func guestIconButton(
        systemName: String,
        label: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? ProShowTheme.liveRed : ShowSidebarPalette.symbol)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(active ? ProShowTheme.liveRed.opacity(0.16) : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityLabel(label)
        .help(label)
    }

    private func statusChip(_ status: GuestConnectionStatus) -> some View {
        Text(status.displayTitle)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status == .liveOnAir ? ProShowTheme.liveRed : ShowSidebarPalette.subtitle)
            .lineLimit(1)
            .accessibilityLabel(status.accessibilityTitle)
    }

    private var chatSection: some View {
        LiveChatFeedView(controller: controller, style: .panel)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Talk to guests. Tap toggles, press and hold talks while held. Glows while live.
/// Wired to startTalkback and stopTalkback exactly like the old checkbox.
struct TalkPillButton: View {
    @Bindable var controller: ShowController
    @Bindable private var model = TalkButtonModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var active: Bool { OnAirAudioControls.shared.talkActive }
    private var enabled: Bool { controller.liveKitDesk.hasStartedConnection }
    private var holding: Bool { active && model.isPressed }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: active ? "mic.fill" : "mic")
                .font(.system(size: 10, weight: .bold))
                .symbolEffect(.variableColor.iterative, isActive: active && !reduceMotion)
            Text(active ? "Talking" : "Talk")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if active && !holding {
                Image(systemName: "lock.fill")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(active ? Color.white : ShowSidebarPalette.title)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(active ? ProShowTheme.liveRed : ShowSidebarPalette.subtitle.opacity(0.16))
        }
        .overlay {
            if active {
                Capsule(style: .continuous)
                    .stroke(ProShowTheme.liveRed.opacity(pulse ? 0.15 : 0.7), lineWidth: pulse ? 6 : 1.5)
                    .padding(pulse ? -3 : 0)
            }
        }
        .shadow(color: active ? ProShowTheme.liveRed.opacity(holding ? 0.9 : (pulse ? 0.35 : 0.75)) : .clear,
                radius: active ? (holding ? 9 : 6) : 0)
        .scaleEffect(holding && !reduceMotion ? 1.06 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: holding)
        .contentShape(Capsule())
        .opacity(enabled ? 1 : 0.45)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard enabled, !model.isPressed else { return }
                    model.press(isActive: active) { controller.startTalkback() }
                }
                .onEnded { _ in
                    model.release { controller.stopTalkback() }
                }
        )
        .onChange(of: active, initial: true) { _, on in
            guard on, !reduceMotion else { pulse = false; return }
            pulse = false
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .help(enabled ? "Click to talk, hold to talk while held. Hold T also works. Never on program." : "Room off")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(active ? "Talking to guests" : "Talk to guests")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard enabled else { return }
            model.toggle(isActive: active, start: { controller.startTalkback() }, stop: { controller.stopTalkback() })
        }
    }
}
