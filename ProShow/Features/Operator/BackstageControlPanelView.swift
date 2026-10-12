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
                roomSection
                virtualCameraSection
                guestsSection
                intercomSection
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

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: DeskSpace.xs) {
            DeskSectionTitle(title: "Backstage room")
            Text(backstage.inviteURLString)
                .font(DeskType.mono)
                .foregroundStyle(ShowSidebarPalette.title)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button("Copy link") { controller.copyBackstageInviteLink() }
                    .controlSize(.small)
                Button("New room") { controller.newGuestRoom() }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var virtualCameraSection: some View {
        VStack(alignment: .leading, spacing: DeskSpace.xs) {
            DeskSectionTitle(title: "Virtual camera")
            Toggle("Virtual Camera", isOn: Binding(
                get: { controller.deviceSettings.document.virtualCameraEnabled },
                set: { value in
                    controller.deviceSettings.document.virtualCameraEnabled = value
                    controller.deviceSettings.save()
                    controller.virtualCameraOutput?.setPublishing(value)
                    controller.syncVirtualAudioLoopbackPublishing()
                }
            ))
            .font(DeskType.body)
            .fixedSize(horizontal: false, vertical: true)
            .help("Publish program as a camera.")
            .accessibilityLabel("Publish program as a camera")
            if let output = controller.virtualCameraOutput, output.needsExtension {
                Text(output.blockedReason ?? "Camera extension missing.")
                    .font(DeskType.micro)
                    .foregroundStyle(ProShowTheme.sandboxOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var guestsSection: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            DeskSectionTitle(title: "Remote guests")
            Text(controller.liveKitDesk.status)
                .font(DeskType.micro)
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isStaticText)
            ForEach(controller.liveKitDesk.guests) { feed in
                guestRow(feed)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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

    private var intercomSection: some View {
        VStack(alignment: .leading, spacing: DeskSpace.xs) {
            DeskSectionTitle(title: "Return feed")
            returnFeedPicker
            Toggle("Intercom", isOn: Binding(
                get: { controller.backstage.intercomActive },
                set: { controller.backstage.intercomActive = $0 }
            ))
            .font(DeskType.body)
            .fixedSize(horizontal: false, vertical: true)
            .help("Talk to the green room.")
            .accessibilityLabel("Talk to the green room")
            Text(controller.mixMinusReturnDescription(excludingGuestID: nil))
                .font(DeskType.micro)
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var returnFeedPicker: some View {
        let selection = Binding(
            get: { controller.backstage.returnFeedMode },
            set: { controller.backstage.returnFeedMode = $0 }
        )
        ViewThatFits(in: .horizontal) {
            Picker("Return feed", selection: selection) {
                ForEach(BackstageReturnFeedMode.allCases, id: \.self) { mode in
                    Text(mode.pickerShortLabel).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Return feed")

            Picker("Return feed", selection: selection) {
                ForEach(BackstageReturnFeedMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Return feed")
        }
    }

    private var chatSection: some View {
        VStack(alignment: .leading, spacing: DeskSpace.sm) {
            DeskSectionTitle(title: "Live chat stream")
            if let chatStream {
                chatSourceToggles(chatStream)
                if let active = chatStream.activeOverlay {
                    activeOverlayCard(active, chatStream: chatStream)
                }
                ForEach(chatStream.inbox.prefix(12), id: \.id) { message in
                    chatMessageRow(message, chatStream: chatStream)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ShowSidebarPalette.selection(scheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func chatSourceToggles(_ chatStream: LiveChatStreamManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach([ChatPlatform.zoom, .googleMeet, .backstage], id: \.self) { platform in
                Toggle(platform.displayTitle, isOn: Binding(
                    get: { chatStream.enabledSources.contains(platform) },
                    set: { chatStream.setSourceEnabled(platform, enabled: $0) }
                ))
                .font(DeskType.micro)
            }
        }
    }

    private func chatMessageRow(_ message: LiveChatMessage, chatStream: LiveChatStreamManager) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.senderName)
                        .font(DeskType.bodyEmph)
                        .lineLimit(1)
                    Text(message.platformSource)
                        .font(DeskType.micro)
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                }
                Spacer(minLength: 0)
                if message.isStarred {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(ProShowTheme.statusOn)
                        .accessibilityLabel("Starred")
                }
            }
            Text(message.messageText)
                .font(DeskType.body)
                .foregroundStyle(ShowSidebarPalette.title)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Display on screen") {
                    controller.triggerChatOverlay(message)
                }
                .controlSize(.small)
                Button(message.isStarred ? "Unstar" : "Star") {
                    chatStream.toggleStar(id: message.id)
                }
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activeOverlayCard(_ message: LiveChatMessage, chatStream: LiveChatStreamManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On-air overlay")
                .font(DeskType.meta)
                .foregroundStyle(ProShowTheme.liveRed)
            Text("\(message.senderName): \(message.messageText)")
                .font(DeskType.body)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Button("Dismiss") { controller.dismissChatOverlay() }
                    .controlSize(.small)
                Stepper("Auto-clear \(chatStream.autoClearSeconds)s", value: Binding(
                    get: { chatStream.autoClearSeconds },
                    set: { chatStream.autoClearSeconds = $0 }
                ), in: 0...120, step: 5)
                .font(DeskType.micro)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            InspectorSelectionRibbon(selected: true, color: ProShowTheme.liveRed)
        }
    }
}
