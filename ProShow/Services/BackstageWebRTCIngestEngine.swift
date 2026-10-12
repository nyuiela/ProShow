import Foundation
import Observation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if os(macOS)
import AppKit
#endif

/// Ingests guest camera frames from signaling (WebRTC SDP relay or JPEG fallback) into `VideoIngestEngine`.
@MainActor
@Observable
final class BackstageWebRTCIngestEngine {
    weak var ingest: VideoIngestEngine?
    weak var backstage: ProShowBackstageEngine?

    private var guestSourceIDs: [String: UUID] = [:]

    func registerGuest(id: String, displayName: String, roleOrTitle: String? = nil, endpoint: String) {
        let uuid = UUID(uuidString: id) ?? UUID()
        let source = StudioVideoSource(
            id: uuid,
            label: displayName,
            kind: .webrtc,
            endpoint: endpoint
        )
        guestSourceIDs[id] = uuid
        _ = ingest?.start(source, pip: false)
        backstage?.connectSignaledGuest(
            id: uuid,
            displayName: displayName,
            roleOrTitle: roleOrTitle,
            cameraEndpoint: endpoint
        )
    }

    func disconnectGuest(id: String) {
        guestSourceIDs.removeValue(forKey: id)
    }

    func applySignal(_ message: BackstageSignalMessage) {
        // Native WebRTC (`RTCPeerConnection`) attaches here when the WebRTC package is linked.
        // Until then, guests can push `mediaFrame` JPEG payloads over the signaling socket.
        _ = message
    }

    func applyMediaFrame(_ message: BackstageSignalMessage) {
        guard message.kind == .mediaFrame,
              let guestID = message.guestID,
              let payload = message.mediaPayload,
              let data = Data(base64Encoded: payload)
        else { return }
        #if os(macOS)
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let buffer = ProgramOutputComposer.shared.pixelBuffer(
                  from: cgImage,
                  width: cgImage.width,
                  height: cgImage.height
              )
        else { return }
        let sourceID = guestSourceIDs[guestID] ?? UUID(uuidString: guestID) ?? UUID()
        let frame = VideoIngestFrame(
            sourceID: sourceID,
            label: message.displayName ?? "Guest",
            kind: .webrtc,
            width: cgImage.width,
            height: cgImage.height,
            timestamp: message.timestamp ?? Date().timeIntervalSinceReferenceDate,
            backend: "webrtc-signaling",
            sample: RGBA8(r: 0.12, g: 0.14, b: 0.18, a: 1)
        )
        ingest?.inject(frame, pip: false, pixelBuffer: buffer)
        LivePixelHub.shared.publish(endpoint: "webrtc://guest/\(guestID)", sourceID: guestID, buffer: buffer)
        #endif
    }
}

extension VideoInputRuntime {
    static func webrtcSignalingEnabled(for source: VideoInputSource) -> Bool {
        source.kind == .webrtc && source.endpoint?.contains("webrtc://guest/") == true
    }

    static func activateWebRTCIfSignaled(_ source: VideoInputSource) -> Result {
        if webrtcSignalingEnabled(for: source) {
            return .started
        }
        return .unsupported("WebRTC guest capture requires an active backstage signaling session.")
    }
}
