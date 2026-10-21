import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension ShowController {
    func bootstrapBackstageServices() {
        chatStream = LiveChatStreamManager(chatEngine: chat)
        bootstrapChatTemplate()
        virtualCameraOutput = VirtualCameraOutputService(sink: virtualCamera)
        virtualCameraOutput?.syncProjectOutput(
            width: projectSettings.resolution.width,
            height: projectSettings.resolution.height,
            fps: projectSettings.frameRate.encoderFPS
        )
        VirtualCameraFramePublisher.shared.start()
        VirtualCameraFramePublisher.shared.setExtensionConnectionHandler { [weak self] connected in
            Task { @MainActor in
                self?.virtualCamera.extensionAvailable = connected
            }
        }
        virtualCameraOutput?.transport = VirtualCameraFramePublisher.shared
        virtualCameraOutput?.setPublishing(deviceSettings.document.virtualCameraEnabled)

        guestWebRTCIngest.ingest = videoInputs.ingest
        guestWebRTCIngest.backstage = backstage
        backstageSignaling.ingest = guestWebRTCIngest

        syncVirtualAudioLoopbackPublishing()
        audioMatrix.pruneGuestChannels(keeping: [])
        liveKitDesk.onGuests = { [weak self] feeds in
            self?.syncLiveKitGuests(feeds)
        }
        liveKitDesk.onRoomActive = { [weak self] active in
            guard let self else { return }
            self.liveKitGuestReturnActive = active
            PreviewProgramAudioPump.setGuestReturnWantsPump(active)
            if active { self.noteProgramMutation() }
        }
        liveKitDesk.onRoomActive?(false)
    }

    /// Loads LiveKit settings the first time a guest surface is used.
    func activateGuestRoomIfNeeded() {
        guard !liveKitDesk.hasStartedConnection else { return }
        liveKitDesk.connect(roomSlug: backstage.room.roomSlug)
    }

    /// Per-project custom room name. Reconnects the desk to the new LiveKit room if one is active.
    @discardableResult
    func setBackstageRoomName(_ raw: String?) -> Bool {
        let before = backstage.room.roomSlug
        guard backstage.setCustomRoomName(raw) else { return false }
        if backstage.room.roomSlug != before, liveKitDesk.hasStartedConnection {
            backstage.guests.removeAll { $0.cameraEndpoint.hasPrefix("livekit://") }
            audioMatrix.pruneGuestChannels(keeping: [])
            liveKitDesk.connect(roomSlug: backstage.room.roomSlug)
        }
        return true
    }

    func newGuestRoom() {
        backstage.guests.removeAll { $0.cameraEndpoint.hasPrefix("livekit://") }
        audioMatrix.pruneGuestChannels(keeping: [])
        backstage.rotateRoom()
        liveKitDesk.connect(roomSlug: backstage.room.roomSlug)
    }

    func syncLiveKitGuests(_ feeds: [LiveKitGuestFeed]) {
        let room = backstage.room.roomSlug
        var seen = Set<UUID>()
        for feed in feeds {
            let id = LiveKitGuestEndpoint.stableID(feed.identity)
            seen.insert(id)
            let endpoint = LiveKitGuestEndpoint.camera(room: room, identity: feed.identity)
            _ = backstage.connectSignaledGuest(
                id: id,
                displayName: feed.name,
                cameraEndpoint: endpoint
            )
            if feed.hasScreen {
                backstage.attachScreenShare(guestID: id, label: "\(feed.name) Screen")
                if let index = backstage.guests.firstIndex(where: { $0.id == id }) {
                    backstage.guests[index].screenShareEndpoint = LiveKitGuestEndpoint.screen(room: room, identity: feed.identity)
                }
            }
            _ = audioMatrix.ensureGuestChannel(guestID: id, displayName: feed.name)
        }
        for guest in backstage.guests where guest.cameraEndpoint.hasPrefix("livekit://") && !seen.contains(guest.id) {
            backstage.removeGuest(id: guest.id)
        }
        audioMatrix.pruneGuestChannels(keeping: seen)
    }

    func muteLiveKitGuest(identity: String, muted: Bool) {
        let id = LiveKitGuestEndpoint.stableID(identity)
        backstage.setGuestMuted(id: id, muted: muted)
        audioMatrix.setGuestChannelMuted(guestID: id, muted: muted)
        liveKitDesk.setGuestMicrophoneMuted(identity: identity, muted: muted)
    }

    func setLiveKitGuestVideoDisabled(identity: String, disabled: Bool) {
        let id = LiveKitGuestEndpoint.stableID(identity)
        backstage.setGuestVideoDisabled(id: id, disabled: disabled)
        liveKitDesk.setGuestVideoSuppressed(identity: identity, suppressed: disabled)
    }

    func removeLiveKitGuest(identity: String) {
        let id = LiveKitGuestEndpoint.stableID(identity)
        backstage.removeGuest(id: id)
        audioMatrix.pruneGuestChannels(keeping: Set(backstage.guests.map(\.id)))
        liveKitDesk.removeGuest(identity: identity)
    }

    func syncLiveKitTally() {
        var identities: [String] = []
        func consider(_ endpoint: String?) {
            guard let identity = LiveKitGuestEndpoint.identity(from: endpoint),
                  !identities.contains(identity)
            else { return }
            identities.append(identity)
        }
        consider(compositor.stack.videoInput?.endpoint)
        consider(compositor.stack.pipInput?.endpoint)
        if let slide = liveSlide {
            for object in resolvedCanvasObjects(slide.canvas) {
                consider(object.assignedSource?.connectionString)
            }
        }
        for identity in identities {
            let id = LiveKitGuestEndpoint.stableID(identity)
            backstage.setGuestOnAir(id: id, onAir: true)
        }
        for guest in backstage.guests where guest.cameraEndpoint.hasPrefix("livekit://") {
            let onAir = identities.contains { LiveKitGuestEndpoint.stableID($0) == guest.id }
            if !onAir, guest.profile.connectionStatus == .liveOnAir {
                backstage.setGuestOnAir(id: guest.id, onAir: false)
            }
        }
        liveKitDesk.publishProgram(identities)
    }

    func syncVirtualAudioLoopbackPublishing() {
        virtualAudioLoopback.refreshDriverPresence()
        let publishAudio = deviceSettings.document.virtualCameraEnabled && virtualAudioLoopback.driverInstalled
        virtualAudioLoopback.setPublishing(publishAudio)
    }

    func copyBackstageInviteLink() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(backstage.inviteURLString, forType: .string)
        #endif
    }

    func triggerChatOverlay(_ message: LiveChatMessage) {
        guard let chatStream else { return }
        _ = chatStream.triggerChatOverlay(message, on: compositor)
        refreshLiveStack()
    }

    // MARK: Chat template prop

    static let chatTemplateFallbackName = "Chat highlight"

    /// The marked prop, else a prop named "Chat highlight". Nil keeps the built-in card.
    var chatTemplateProp: ProShowProp? {
        inspector.props.first(where: \.isChatTemplate)
            ?? inspector.props.first {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(Self.chatTemplateFallbackName) == .orderedSame
            }
    }

    func setPropChatTemplate(id: UUID, on: Bool) {
        inspector.setPropChatTemplate(id: id, on: on)
        persistStudio()
    }

    static func chatTemplateFields(for message: LiveChatMessage) -> [String: String] {
        [
            "chat.name": message.senderName,
            "chat.message": message.messageText,
            "chat.platform": message.platformSource,
            "chat.avatar": message.senderAvatarUrl ?? "",
        ]
    }

    /// Puts the message on the template prop. A pick while it is up swaps the text in place.
    /// False when there is no template, so the caller draws the built-in card.
    func showChatOnTemplate(_ message: LiveChatMessage, at date: Date = Date()) -> Bool {
        guard let prop = chatTemplateProp else { return false }
        chatTemplateClearTask?.cancel()
        chatTemplateClearTask = nil
        if let shown = chatTemplateShownID, shown != prop.id,
           inspector.props.contains(where: { $0.id == shown && $0.isActive }) {
            _ = toggleInspectorProp(id: shown, at: date)
        }
        featuredChatFields = Self.chatTemplateFields(for: message)
        chatTemplateShownID = prop.id
        if prop.isActive {
            // Re-resolve so a bound avatar layer swaps (or falls back) with the text.
            syncActivePropsToCompositor()
            tickProgram()
        } else {
            _ = toggleInspectorProp(id: prop.id, at: date)
        }
        fetchChatAvatarIfBound(prop)
        return true
    }

    /// Fetches the featured avatar when the template has a layer bound to it, then re-resolves.
    private func fetchChatAvatarIfBound(_ prop: ProShowProp) {
        let url = featuredChatFields["chat.avatar"] ?? ""
        guard !url.isEmpty else { return }
        let objects = prop.elements + (prop.phoneElements ?? [])
        guard objects.contains(where: { $0.imageBinding == "chat.avatar" }) else { return }
        ChatAvatarFileCache.shared.prefetch(url) { [weak self] path in
            guard let self, path != nil, self.featuredChatFields["chat.avatar"] == url else { return }
            self.syncActivePropsToCompositor()
            self.tickProgram()
        }
    }

    /// Hides the template prop through its exit animation, then drops the chat values.
    func hideChatTemplate(at date: Date = Date()) {
        guard let id = chatTemplateShownID else {
            clearFeaturedChatFields()
            return
        }
        chatTemplateShownID = nil
        guard let prop = inspector.props.first(where: { $0.id == id }), prop.isActive else {
            clearFeaturedChatFields()
            return
        }
        _ = toggleInspectorProp(id: id, at: date)
        // Keep the message on the card while it fades; the sample comes back after.
        let hold = BuildAnimationEngine.authoredBuildOutDuration(in: prop.elements) + 0.15
        chatTemplateClearTask?.cancel()
        chatTemplateClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, hold)))
            guard !Task.isCancelled, let self, self.chatTemplateShownID == nil else { return }
            self.clearFeaturedChatFields()
        }
    }

    private func clearFeaturedChatFields() {
        guard !featuredChatFields.isEmpty else { return }
        featuredChatFields = [:]
        syncActivePropsToCompositor()
        tickProgram()
    }

    /// Binds (or unbinds) an image layer of a prop to a live chat value. Saves the project.
    @discardableResult
    func setPropImageBinding(propID: UUID, layerID: UUID, binding: String?) -> Bool {
        guard let p = inspector.props.firstIndex(where: { $0.id == propID }) else { return false }
        let value = binding?.trimmingCharacters(in: .whitespacesAndNewlines)
        var found = false
        for i in inspector.props[p].elements.indices where inspector.props[p].elements[i].id == layerID {
            inspector.props[p].elements[i].imageBinding = (value?.isEmpty ?? true) ? nil : value
            found = true
        }
        guard found else { return false }
        if var phone = inspector.props[p].phoneElements {
            for i in phone.indices where phone[i].id == layerID {
                phone[i].imageBinding = (value?.isEmpty ?? true) ? nil : value
            }
            inspector.props[p].phoneElements = phone
        }
        if editors.kind == .props, let d = editors.documents.firstIndex(where: { $0.id == propID }) {
            for o in editors.documents[d].objects.indices where editors.documents[d].objects[o].id == layerID {
                editors.documents[d].objects[o].imageBinding = (value?.isEmpty ?? true) ? nil : value
            }
            for b in editors.documents[d].boards.indices {
                for o in editors.documents[d].boards[b].objects.indices where editors.documents[d].boards[b].objects[o].id == layerID {
                    editors.documents[d].boards[b].objects[o].imageBinding = (value?.isEmpty ?? true) ? nil : value
                }
            }
        }
        syncActivePropsToCompositor()
        persistStudio()
        return true
    }

    /// Same calls as the chat panel's Display on screen and Dismiss.
    func handleChatFeatureControl(method: String, body: Data?) -> (Int, String) {
        guard let chatStream else { return (503, #"{"ok":false,"error":"chat_unavailable"}"#) }
        if method == "POST" {
            let parsed = ControlHTTP.jsonObject(body)
            if parsed["dismiss"] == "1" || parsed["dismiss"] == "true" {
                dismissChatOverlay()
            } else {
                let message = parsed["id"].flatMap { id in chatStream.inbox.first { $0.id == id } }
                    ?? parsed["index"].flatMap(Int.init).flatMap { chatStream.inbox.indices.contains($0) ? chatStream.inbox[$0] : nil }
                guard let message else { return (404, #"{"ok":false,"error":"message_not_found"}"#) }
                triggerChatOverlay(message)
            }
        }
        let template = chatTemplateProp
        return (200, ControlJSON.encode([
            "ok": true,
            "template": template?.name ?? NSNull(),
            "template_marked": template?.isChatTemplate ?? false,
            "template_active": template?.isActive ?? false,
            "on_template": chatStream.overlayOnTemplate,
            "card": compositor.stack.chatOverlay != nil,
            "featured": chatStream.activeOverlay?.id ?? NSNull(),
            "fields": featuredChatFields,
            "avatar_cached": featuredChatFields["chat.avatar"].flatMap { ChatAvatarFileCache.shared.localPath(for: $0) } != nil,
            "avatar_layers": (template?.elements ?? []).filter { $0.imageBinding == "chat.avatar" }.map(\.name),
            "inbox": chatStream.inbox.prefix(5).map { ["id": $0.id, "name": $0.senderName, "platform": $0.platformSource] },
        ]))
    }

    func bootstrapChatTemplate() {
        chatStream?.templatePresenter = { [weak self] message in
            self?.showChatOnTemplate(message) ?? false
        }
        chatStream?.templateDismisser = { [weak self] in
            self?.hideChatTemplate()
        }
    }

    func dismissChatOverlay() {
        chatStream?.dismissOverlay(compositor: compositor)
        refreshLiveStack()
    }

    func routeGuestToCanvas(guestID: UUID) {
        guard let guest = backstage.guests.first(where: { $0.id == guestID }) else { return }
        let source = VideoInputSource(
            id: guest.videoInputID ?? UUID(),
            label: guest.profile.displayName,
            kind: .camera,
            endpoint: guest.cameraEndpoint
        )
        activateVideoInput(source, presentOnProgram: true)
    }

    /// Mix-minus return feed: program monitor bus without the target guest's microphone.
    func mixMinusReturnDescription(excludingGuestID: UUID?) -> String {
        guard backstage.room.mixMinusEnabled else { return BackstageReturnFeedMode.programFull.rawValue }
        if let excludingGuestID, let guest = backstage.guests.first(where: { $0.id == excludingGuestID }) {
            return "Program − \(guest.profile.displayName) mic"
        }
        return BackstageReturnFeedMode.programMixMinus.rawValue
    }

    func toggleBackstageIntercom() {
        guard backstage.room.intercomEnabled else { return }
        setReturnMode(identity: nil, mode: backstage.intercomActive ? .programMixMinus : .intercomOnly)
    }

    func cycleBackstageGuestOnProgram() {
        let sources = backstage.videoSourcesForGraph()
        guard !sources.isEmpty else { return }
        backstageGuestSourceIndex = (backstageGuestSourceIndex + 1) % sources.count
        let row = sources[backstageGuestSourceIndex]
        if let guest = backstage.guests.first(where: { $0.id == row.guestID }) {
            routeGuestToCanvas(guestID: guest.id)
        }
    }

    func ensureGuestAudioChannels() {
        for guest in backstage.guests where guest.profile.connectionStatus != .disconnected {
            _ = audioMatrix.ensureGuestChannel(guestID: guest.id, displayName: guest.profile.displayName)
        }
    }

    func backstageSignalingResponse(forWebSocketText text: String, path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "v1", parts[1] == "backstage", parts[3] == "signal" else {
            return nil
        }
        return backstageSignaling.handleWebSocketText(text, roomSlug: parts[2])
    }
}
