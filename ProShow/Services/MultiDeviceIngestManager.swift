import Foundation
import Observation

struct IngestMatrixRow: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var group: String
    var backend: String
    var endpoint: String?
    var isConnected: Bool
}

/// Enterprise ingest matrix: physical capture, ScreenCaptureKit, NDI 6 / HX3, SRT, WebRTC guest.
@MainActor
@Observable
final class MultiDeviceIngestManager {
    static let shared = MultiDeviceIngestManager()

    weak var ingest: VideoIngestEngine?

    private(set) var srtReceivers: [String: SRTStreamReceiver] = [:]
    private(set) var lastRefresh = Date()

    func attach(ingest: VideoIngestEngine) {
        self.ingest = ingest
    }

    func matrixRows(hardwareEnabled: Bool, srtPort: Int = 9000) -> [IngestMatrixRow] {
        var rows: [IngestMatrixRow] = []
        if let ingest {
            for source in ingest.discoverPresentHardware(scanCameras: hardwareEnabled) {
                rows.append(
                    IngestMatrixRow(
                        id: source.id.uuidString,
                        name: source.label,
                        group: groupName(for: source.kind),
                        backend: ingest.isRunning(source) ? "Live" : "Ready",
                        endpoint: source.endpoint,
                        isConnected: ingest.isRunning(source)
                    )
                )
            }
        }
        if hardwareEnabled, NDIRuntime.shouldActivate {
            for ndi in NDIRuntime.findSources(timeoutMs: 400) {
                rows.append(
                    IngestMatrixRow(
                        id: "ndi:\(ndi.name)",
                        name: ndi.name,
                        group: "NDI 6 / HX3",
                        backend: NDIRuntime.connect(sourceName: ndi.name) ? "Discovered" : "NDI",
                        endpoint: ndi.url.isEmpty ? "ndi://\(ndi.name)" : ndi.url,
                        isConnected: false
                    )
                )
            }
        }
        rows.append(
            IngestMatrixRow(
                id: "srt:listener",
                name: "SRT Listener",
                group: "Network & IP",
                backend: srtReceivers["listener"]?.isRunning == true ? "Listening" : "Idle",
                endpoint: "srt://0.0.0.0:\(srtPort)?mode=listener",
                isConnected: srtReceivers["listener"]?.isRunning == true
            )
        )
        rows.append(
            IngestMatrixRow(
                id: "webrtc:guest",
                name: "WebRTC Remote Guest",
                group: "Network & IP",
                backend: "Backstage",
                endpoint: "webrtc://guest",
                isConnected: false
            )
        )
        lastRefresh = Date()
        return rows
    }

    @discardableResult
    func startSRT(connectionString: String, key: String = "listener") -> Bool {
        guard let endpoint = SRTStreamEndpoint.parse(connectionString) else { return false }
        let receiver = srtReceivers[key] ?? SRTStreamReceiver()
        receiver.onPacket = { _ in
            // Decoded frames bind through VideoIngestEngine / codec bridge when libsrt is linked.
        }
        receiver.start(endpoint: endpoint)
        srtReceivers[key] = receiver
        return receiver.isRunning
    }

    func stopSRT(key: String = "listener") {
        srtReceivers[key]?.stop()
        srtReceivers.removeValue(forKey: key)
    }

    func refreshNDISources() -> [StudioVideoSource] {
        guard NDIRuntime.shouldActivate else { return [] }
        return NDIRuntime.findSources(timeoutMs: 800).map { ndi in
            StudioVideoSource(
                id: HardwareSourceIdentity.uuid(for: "ndi://\(ndi.name)"),
                label: ndi.name,
                kind: .ndi,
                endpoint: ndi.url.isEmpty ? "ndi://\(ndi.name)" : ndi.url
            )
        }
    }

    private func groupName(for kind: StudioVideoKind) -> String {
        switch kind {
        case .camera, .continuity: "Physical / AVFoundation"
        case .captureCard: "Capture Cards (DeckLink / Elgato)"
        case .screenShare: "ScreenCaptureKit"
        case .ndi: "NDI 6 / HX3"
        case .webrtc: "WebRTC Guest"
        case .rtsp: "Network Stream"
        }
    }
}
