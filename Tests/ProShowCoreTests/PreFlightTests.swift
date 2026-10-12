#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

struct StubHandshakeProbe: StreamHandshakeProbing, Sendable {
    var reachable: Bool
    var latencyMs: Double

    func probe(host: String, port: UInt16, timeoutMs: Int) -> StreamHandshakeSample {
        StreamHandshakeSample(reachable: reachable, latencyMs: latencyMs)
    }
}

@Suite
struct PreFlightTests {
    @Test
    func missingMedia_flagsBrokenPathOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = try TestSupport.writePNGFixture(in: directory)
        let slides = [
            Slide(title: "A", mediaAction: MediaAction(id: UUID(), title: "Loop", tintHex: "#111", isImage: true, filePath: png.path)),
            Slide(title: "B", mediaAction: MediaAction(id: UUID(), title: "Gone", tintHex: "#111", isImage: false, filePath: "/tmp/proshow-missing-\(UUID().uuidString).mov")),
        ]
        let report = PreFlightEngine.scan(
            slides: slides,
            projectRoot: directory,
            targets: [],
            streamConfigURL: "",
            audioSettingsRateHz: 48_000,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(),
            audienceAssigned: true,
            stageAssigned: true,
            physicalDisplayCount: 2,
            intent: .goLive,
            handshake: nil
        )
        let missing = report.findings.filter { $0.kind == .missingMedia && $0.severity == .fail }
        #expect(missing.count == 1)
        #expect(missing.first?.relinkHint?.contains("proshow-missing") == true)
        #expect(!report.canProceed)
    }

    @Test
    func liveEndpoints_areNotRelinked() {
        let slides = [
            Slide(title: "Cam", mediaAction: MediaAction(id: UUID(), title: "Cam", tintHex: "#111", isImage: false, filePath: "avf://built-in"))
        ]
        let report = PreFlightEngine.scan(
            slides: slides,
            projectRoot: nil,
            targets: [],
            streamConfigURL: "",
            audioSettingsRateHz: 48_000,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(),
            audienceAssigned: true,
            stageAssigned: true,
            physicalDisplayCount: 1,
            intent: .goLive
        )
        #expect(report.findings.contains { $0.kind == .missingMedia && $0.severity == .pass })
        #expect(report.canProceed)
    }

    @Test
    func streamHandshake_neverIncludesKey() {
        let report = PreFlightEngine.scan(
            slides: [],
            projectRoot: nil,
            targets: [
                PreFlightTarget(
                    platform: "YouTube Live",
                    accountName: "Main",
                    rtmpUrl: "rtmp://a.rtmp.youtube.com/live2",
                    keychainIdentifier: "stream.test",
                    keyPresent: true
                )
            ],
            streamConfigURL: "",
            audioSettingsRateHz: 48_000,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(),
            audienceAssigned: true,
            stageAssigned: true,
            physicalDisplayCount: 2,
            intent: .startStream,
            handshake: StubHandshakeProbe(reachable: true, latencyMs: 18)
        )
        let encoded = ControlJSON.encode(report.jsonObject)
        #expect(!encoded.contains("sk_"))
        #expect(!encoded.lowercased().contains("streamkey"))
        #expect(report.findings.contains { $0.kind == .streamHandshake && $0.severity == .pass })
        #expect(report.handshakeCount == 1)
    }

    @Test
    func audioClock_failsOn44k() {
        let report = PreFlightEngine.scan(
            slides: [],
            projectRoot: nil,
            targets: [],
            streamConfigURL: "",
            audioSettingsRateHz: 44_100,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(sources: [
                AudioClockSource(name: "NDI Guest", sampleRateHz: 48_000, kind: "ndi")
            ]),
            audienceAssigned: true,
            stageAssigned: true,
            physicalDisplayCount: 2,
            intent: .inspect
        )
        #expect(report.findings.contains { $0.kind == .audioClock && $0.severity == .fail })
        #expect(!report.canProceed)
    }

    @Test
    func display_failsWhenAudienceUnassigned() {
        let report = PreFlightEngine.scan(
            slides: [],
            projectRoot: nil,
            targets: [],
            streamConfigURL: "",
            audioSettingsRateHz: 48_000,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(),
            audienceAssigned: false,
            stageAssigned: false,
            physicalDisplayCount: 1,
            intent: .startStream
        )
        #expect(report.findings.contains { $0.kind == .displayOutput && $0.severity == .fail })
    }

    @Test
    func endpointParse_rtmpsUses443() {
        let hint = StreamEndpointHint.parse("rtmps://live-api-s.facebook.com/rtmp/")
        #expect(hint?.host == "live-api-s.facebook.com")
        #expect(hint?.port == 443)
    }

    @Test @MainActor
    func confirmPreFlight_requiresPass() {
        let controller = TestSupport.sampleController()
        controller.lastPreFlight = PreFlightEngine.scan(
            slides: [
                Slide(
                    title: "Broken",
                    mediaAction: MediaAction(
                        id: UUID(),
                        title: "Missing",
                        tintHex: "#111",
                        isImage: false,
                        filePath: "/tmp/does-not-exist-\(UUID().uuidString).mp4"
                    )
                )
            ],
            projectRoot: nil,
            targets: [],
            streamConfigURL: "",
            audioSettingsRateHz: 48_000,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(),
            audienceAssigned: true,
            stageAssigned: true,
            physicalDisplayCount: 2,
            intent: .goLive
        )
        controller.preFlightIntent = .goLive
        controller.confirmPreFlight()
        #expect(controller.liveSlideID == nil)
        #expect(controller.lastPreFlight?.canProceed == false)
    }

    @Test
    func oauthDestination_doesNotRequireKeychainStreamKey() {
        let report = PreFlightEngine.scan(
            slides: [],
            projectRoot: nil,
            targets: [
                PreFlightTarget(
                    platform: "YouTube Live",
                    accountName: "Sunrise",
                    rtmpUrl: "rtmp://a.rtmp.youtube.com/live2",
                    keychainIdentifier: "stream.youtube.test",
                    keyPresent: false,
                    mintsIngestOnGoLive: true,
                    isAuthenticated: true
                )
            ],
            streamConfigURL: "",
            audioSettingsRateHz: 48_000,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(),
            audienceAssigned: true,
            stageAssigned: true,
            physicalDisplayCount: 2,
            intent: .startStream
        )
        #expect(!report.findings.contains { $0.title == "Stream key missing" })
        #expect(report.findings.contains { $0.kind == .streamHandshake && $0.severity == .pass })
        #expect(report.canProceed)
    }

    @Test
    func unusedAndNonFileMedia_doNotBlockGoLive() {
        let unused = Slide(
            title: "Unused",
            mediaAction: MediaAction(
                id: UUID(),
                title: "Gone",
                tintHex: "#111",
                isImage: false,
                filePath: "/tmp/proshow-unused-\(UUID().uuidString).mov"
            )
        )
        let current = Slide(
            title: "Current",
            mediaAction: MediaAction(
                id: UUID(),
                title: "Cam",
                tintHex: "#111",
                isImage: false,
                filePath: "placeholder://A"
            )
        )
        let report = PreFlightEngine.scan(
            slides: [current],
            projectRoot: nil,
            targets: [],
            streamConfigURL: "",
            audioSettingsRateHz: 48_000,
            encoderRateHz: 48_000,
            audioClock: AudioClockSnapshot(),
            audienceAssigned: true,
            stageAssigned: true,
            physicalDisplayCount: 2,
            intent: .goLive
        )
        #expect(!report.findings.contains { $0.kind == .missingMedia && $0.severity == .fail })
        #expect(report.canProceed)
        #expect(PreFlightEngine.isFileBackedMedia(unused.mediaAction?.filePath ?? ""))
        #expect(!PreFlightEngine.isFileBackedMedia("placeholder://A"))
        #expect(!PreFlightEngine.isFileBackedMedia(UUID().uuidString))
    }
}
