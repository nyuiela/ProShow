import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension ShowController {
    func bootstrapBackstageServices() {
        chatStream = LiveChatStreamManager(chatEngine: chat)
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
