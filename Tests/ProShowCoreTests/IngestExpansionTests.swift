#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct IngestExpansionTests {
    @Test
    func srtEndpoint_parsesListenerMode() {
        let endpoint = SRTStreamEndpoint.parse("srt://0.0.0.0:9000?mode=listener")
        #expect(endpoint?.port == 9000)
        #expect(endpoint?.mode == .listener)
    }

    @Test
    func inputFailover_detectsHalfSecondStall() {
        InputFailoverEngine.shared.resetAll()
        InputFailoverEngine.shared.noteFrame(sourceKey: "cam-a", now: Date(timeIntervalSince1970: 100))
        #expect(!InputFailoverEngine.shared.isStalled(sourceKey: "cam-a", now: Date(timeIntervalSince1970: 100.4)))
        #expect(InputFailoverEngine.shared.isStalled(sourceKey: "cam-a", now: Date(timeIntervalSince1970: 100.6)))
    }

    @Test @MainActor
    func multiDeviceMatrix_listsPhysicalAndNetworkRows() {
        let ingest = VideoIngestEngine()
        MultiDeviceIngestManager.shared.attach(ingest: ingest)
        let rows = MultiDeviceIngestManager.shared.matrixRows(hardwareEnabled: false)
        #expect(rows.contains { $0.group.contains("ScreenCaptureKit") || $0.group.contains("Physical") })
        #expect(rows.contains { $0.id == "srt:listener" })
    }
}
