#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

/// Phase 0 + 1 of docs/PROSHOW_ONAIR_AUDIO_PLAN.md: each "device added but silent" gate,
/// the solo rule, and the read-only resolver that explains them.
@Suite
struct OnAirAudioTests {
    // MARK: Fixtures

    private static func shot(_ name: String, _ type: SourceType, endpoint: String = "", muted: Bool = false) -> LayerShot {
        LayerShot(
            name: name,
            source: DiscoveredSourceItem(name: name, category: .all, groupName: "Test", sourceType: type, connectionString: endpoint),
            audioMuted: muted ? true : nil
        )
    }

    private static func layer(_ index: Int, _ shots: [LayerShot], live: LayerShot?) -> MasterLayer {
        MasterLayer(index: index, title: "Main Layer \(index)", shots: shots, liveShotID: live?.id)
    }

    private static func channels(micSolo: Bool = false, micMuted: Bool = false) -> [AudioMatrixChannel] {
        var list = DefaultSeedData.studioManifest().audioChannels
        for index in list.indices where list[index].role == .microphone {
            list[index].solo = micSolo
            list[index].muted = micMuted
            list[index].peak = -20
        }
        return list
    }

    private static func row(_ rows: [OnAirAudioSource], _ name: String) throws -> OnAirAudioSource {
        try #require(rows.first { $0.name == name })
    }

    // MARK: ProgramAudioGatePolicy (G1, G2)

    @Test
    func gatePolicy_micOpensOnlyForLiveUnmutedMicShot() {
        let mic = Self.shot("Mic", .systemMicrophone)
        #expect(ProgramAudioGatePolicy.derive(from: [Self.layer(1, [mic], live: mic)]).microphone)
        // G1: added but not taken.
        #expect(!ProgramAudioGatePolicy.derive(from: [Self.layer(1, [mic], live: nil)]).microphone)
        // Layer-muted live shot.
        let muted = Self.shot("Mic", .systemMicrophone, muted: true)
        #expect(!ProgramAudioGatePolicy.derive(from: [Self.layer(1, [muted], live: muted)]).microphone)
    }

    @Test
    func gatePolicy_camerasNeverOpenTheMic() {
        let camera = Self.shot("Cam", .systemCamera)
        let ndi = Self.shot("NDI", .ndiSource)
        let srt = Self.shot("SRT", .srtStream)
        for shot in [camera, ndi, srt] {
            let gates = ProgramAudioGatePolicy.derive(from: [Self.layer(1, [shot], live: shot)])
            #expect(!gates.microphone)
            #expect(!gates.desktop)
        }
    }

    @Test
    func gatePolicy_screenOpensDesktop() {
        let screen = Self.shot("Screen", .systemDisplay)
        let gates = ProgramAudioGatePolicy.derive(from: [Self.layer(1, [screen], live: screen)])
        #expect(gates.desktop)
        #expect(!gates.microphone)
    }

    // MARK: Solo rule (G3)

    @Test @MainActor
    func solo_silencesEveryOtherChannelOnTheStream() throws {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        let mic = try #require(matrix.channel(role: .microphone))
        let slide = try #require(matrix.channel(role: .slide))
        #expect(matrix.outputLevel(for: slide, bus: .stream) > 0)
        matrix.setSolo(id: mic.id, solo: true)
        let slideAfter = try #require(matrix.channel(role: .slide))
        #expect(matrix.outputLevel(for: slideAfter, bus: .stream) == 0)
        // Kaleel's case: Mic soloed AND muted. Nothing reaches the stream at all.
        matrix.setMute(id: mic.id, muted: true)
        let total = matrix.channels.reduce(0) { $0 + matrix.outputLevel(for: $1, bus: .stream) }
        #expect(total == 0)
    }

    @Test @MainActor
    func masterMeter_respectsSoloForSlideAudio() throws {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        ProgramSlideAudioMeter.note(mono: [Float](repeating: 0.5, count: 4_800), sampleRate: 48_000)
        matrix.processFrame()
        #expect(matrix.master.peakLeft > -20)
        let mic = try #require(matrix.channel(role: .microphone))
        matrix.setSolo(id: mic.id, solo: true)
        matrix.setMute(id: mic.id, muted: true)
        ProgramSlideAudioMeter.note(mono: [Float](repeating: 0.5, count: 4_800), sampleRate: 48_000)
        matrix.processFrame()
        // Before the fix the meter showed slide audio here while the stream was silent.
        #expect(matrix.master.peakLeft <= -119)
    }

    /// Found by the tone test: a muted mic still metered room sound and ducked slides and guests by 12 dB.
    @Test @MainActor
    func ducking_ignoresMutedOrSoloedOutMic() throws {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        matrix.duckingEnabled = true
        matrix.duckThresholdDb = -24
        matrix.setPeak(id: StudioSeedID.mic, db: -10)
        matrix.processFrame()
        #expect(matrix.duckingActive)
        matrix.setMute(id: StudioSeedID.mic, muted: true)
        matrix.processFrame()
        #expect(!matrix.duckingActive)
        matrix.setMute(id: StudioSeedID.mic, muted: false)
        matrix.setSolo(id: StudioSeedID.desktop, solo: true)
        matrix.processFrame()
        #expect(!matrix.duckingActive)
    }

    // MARK: Resolver, one test per gate

    @Test
    func resolver_liveMicIsOnAir() throws {
        let mic = Self.shot("Desk mic", .systemMicrophone)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [mic], live: mic)]
        input.channels = Self.channels()
        let row = try Self.row(OnAirAudioResolver.resolve(input), "Desk mic")
        #expect(row.state == .live)
        #expect(row.reason == nil)
        #expect(row.origin == "L1")
    }

    @Test
    func resolver_G1_notTaken() throws {
        let mic = Self.shot("Desk mic", .systemMicrophone)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [mic], live: nil)]
        input.channels = Self.channels()
        let row = try Self.row(OnAirAudioResolver.resolve(input), "Desk mic")
        #expect(row.state == .notRouted)
        #expect(row.reason == "Not live: shot added, not taken")
    }

    @Test
    func resolver_G2_cameraIsPictureOnly() throws {
        let camera = Self.shot("FaceTime", .systemCamera)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [camera], live: camera)]
        input.channels = Self.channels()
        let row = try Self.row(OnAirAudioResolver.resolve(input), "FaceTime")
        #expect(row.state == .notRouted)
        #expect(row.reason?.hasPrefix("Picture only") == true)
    }

    @Test
    func resolver_G3_soloSilencesSlideAndGuests() throws {
        let mic = Self.shot("Desk mic", .systemMicrophone)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [mic], live: mic)]
        input.channels = Self.channels(micSolo: true, micMuted: true)
        input.slide = .init(name: "Slide 3 audio", blockReason: nil, peakDb: -12)
        let guestID = UUID()
        var strip = AudioMatrixChannel(name: "Ama", role: .guest)
        strip.linkedGuestID = guestID
        input.channels.append(strip)
        input.guests = [.init(identity: "ama", name: "Ama", guestID: guestID, hasMic: true, peakDb: -15)]
        let rows = OnAirAudioResolver.resolve(input)
        #expect(try Self.row(rows, "Slide 3 audio").state == .soloOff)
        #expect(try Self.row(rows, "Slide 3 audio").reason == "Silenced by solo on Mic")
        #expect(try Self.row(rows, "Ama").state == .soloOff)
        // The soloed mic is itself muted: muted wins for its own row.
        #expect(try Self.row(rows, "Desk mic").state == .muted)
        #expect(rows.filter(\.isOnAir).isEmpty)
    }

    @Test
    func resolver_G4_muteOrder() throws {
        let mic = Self.shot("Desk mic", .systemMicrophone, muted: true)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [mic], live: mic)]
        input.channels = Self.channels()
        #expect(try Self.row(OnAirAudioResolver.resolve(input), "Desk mic").reason == "Muted on this layer")
        let unmuted = Self.shot("Desk mic", .systemMicrophone)
        input.layers = [Self.layer(1, [unmuted], live: unmuted)]
        input.channels = Self.channels(micMuted: true)
        #expect(try Self.row(OnAirAudioResolver.resolve(input), "Desk mic").reason == "Muted on the Mic channel")
        input.programMuted = true
        #expect(try Self.row(OnAirAudioResolver.resolve(input), "Desk mic").reason == "Program audio is muted")
    }

    @Test
    func resolver_G5_slideConditionIsNamed() throws {
        var input = OnAirAudioInputs()
        input.channels = Self.channels()
        input.slide = .init(name: "Intro video", blockReason: "Slide layer is hidden", peakDb: -10)
        let row = try Self.row(OnAirAudioResolver.resolve(input), "Intro video")
        #expect(row.state == .muted)
        #expect(row.reason == "Slide audio off: Slide layer is hidden")
    }

    @Test
    func resolver_G6_secondMicIsArmed() throws {
        let first = Self.shot("USB mic", .systemMicrophone, endpoint: "avf://usb")
        let second = Self.shot("iPhone mic", .systemMicrophone, endpoint: "avf://iphone")
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [first], live: first), Self.layer(2, [second], live: second)]
        input.channels = Self.channels()
        input.micOwner = "avf://usb"
        let rows = OnAirAudioResolver.resolve(input)
        #expect(try Self.row(rows, "USB mic").state == .live)
        let armed = try Self.row(rows, "iPhone mic")
        #expect(armed.state == .armed)
        #expect(armed.reason == "Second mic: USB mic owns the mic")
        let alerts = OnAirAudioResolver.alerts(sources: rows, channels: input.channels, capture: [:],
                                               programSilentSeconds: 0, isLive: true, clippedRecently: false)
        #expect(alerts.contains { $0.kind == .doubled })
    }

    @Test
    func resolver_G7_screenHeldByMic() throws {
        let screen = Self.shot("Screen", .systemDisplay)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [screen], live: screen)]
        input.channels = Self.channels()
        input.desktopHeldByMic = true
        let row = try Self.row(OnAirAudioResolver.resolve(input), "Screen")
        #expect(row.state == .held)
        #expect(row.reason == "Held: the mic owns the mix")
    }

    @Test
    func resolver_G8_ndiAndSrtHaveNoAudioPath() throws {
        let ndi = Self.shot("OBS NDI", .ndiSource)
        let srt = Self.shot("SRT in", .srtStream)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [ndi], live: ndi), Self.layer(2, [srt], live: srt)]
        input.channels = Self.channels()
        let rows = OnAirAudioResolver.resolve(input)
        for name in ["OBS NDI", "SRT in"] {
            let row = try Self.row(rows, name)
            #expect(row.state == .notRouted)
            #expect(row.reason == "No audio path for NDI/SRT yet")
        }
    }

    @Test
    func resolver_G9_guestMutedByDesk() throws {
        let guestID = UUID()
        var strip = AudioMatrixChannel(name: "Ama", role: .guest, muted: true)
        strip.linkedGuestID = guestID
        var input = OnAirAudioInputs()
        input.channels = Self.channels() + [strip]
        input.guests = [.init(identity: "ama", name: "Ama", guestID: guestID, hasMic: true, peakDb: -15)]
        let row = try Self.row(OnAirAudioResolver.resolve(input), "Ama")
        #expect(row.state == .muted)
        #expect(row.reason == "Muted by the desk")
        input.channels = Self.channels()
        input.guests = [.init(identity: "ama", name: "Ama", guestID: guestID, hasMic: false, peakDb: nil)]
        #expect(try Self.row(OnAirAudioResolver.resolve(input), "Ama").state == .notRouted)
    }

    @Test
    func resolver_G10_noSignalAfterTenSeconds() throws {
        let mic = Self.shot("Desk mic", .systemMicrophone)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [mic], live: mic)]
        input.channels = Self.channels()
        input.silentSeconds = ["shot:\(mic.id.uuidString)": 11]
        let row = try Self.row(OnAirAudioResolver.resolve(input), "Desk mic")
        #expect(row.state == .noSignal)
        #expect(!row.isOnAir)
    }

    // MARK: Alerts, pre-flight, loudness

    @Test
    func alerts_soloClipSilence() {
        var channels = Self.channels(micSolo: true)
        var alerts = OnAirAudioResolver.alerts(sources: [], channels: channels, capture: [:],
                                               programSilentSeconds: 6, isLive: true, clippedRecently: true)
        #expect(Set(alerts.map(\.kind)) == [.solo, .clipping, .silence])
        channels = Self.channels()
        alerts = OnAirAudioResolver.alerts(sources: [], channels: channels, capture: [.microphone: ["a", "b"]],
                                           programSilentSeconds: 6, isLive: false, clippedRecently: false)
        #expect(alerts.map(\.kind) == [.doubled])
    }

    @Test
    func preflight_warnsWhenAnyChannelSoloed() throws {
        #expect(PreFlightEngine.auditAudioSolo(soloed: []) == nil)
        let finding = try #require(PreFlightEngine.auditAudioSolo(soloed: ["Mic"]))
        #expect(finding.severity == .warn)
        #expect(finding.kind == .audioRouting)
        #expect(!finding.detail.contains("\u{2014}"))
        let report = PreFlightReport(scannedAt: Date(), intent: .goLive, findings: [finding], uniqueAssetCount: 0, handshakeCount: 0)
        #expect(report.canProceed)
        #expect(report.needsAudioConfirm)
    }

    @Test @MainActor
    func preflight_controllerScanAddsSoloFinding() throws {
        let controller = TestSupport.sampleController()
        let mic = try #require(controller.audioMatrix.channel(role: .microphone))
        controller.audioMatrix.setSolo(id: mic.id, solo: true)
        let report = controller.runPreFlight(intent: .inspect)
        #expect(report.findings.first?.kind == .audioRouting)
        controller.clearAllAudioSolos()
        #expect(!controller.runPreFlight(intent: .inspect).needsAudioConfirm)
    }

    @Test @MainActor
    func mediaReason_matchesIsProgramMediaMuted() {
        let controller = TestSupport.sampleController()
        #expect((controller.programMediaAudioBlockReason == nil) == !controller.isProgramMediaMuted)
        controller.compositor.setLayerAudioMuted(.media, muted: true)
        #expect(controller.isProgramMediaMuted)
        #expect(controller.programMediaAudioBlockReason == "Media layer audio is muted")
        controller.compositor.setLayerAudioMuted(.media, muted: false)
        #expect((controller.programMediaAudioBlockReason == nil) == !controller.isProgramMediaMuted)
    }

    @Test
    func loudness_sineAtMinus20IsAboutMinus20LUFS() {
        var meter = ProgramLoudnessMeter()
        let frames = 1_024
        var phase = 0.0
        let step = 2 * Double.pi * 997 / 48_000
        for _ in 0..<200 {
            var block = [Float](repeating: 0, count: frames * 2)
            for index in 0..<frames {
                let sample = Float(0.1 * sin(phase))
                phase += step
                block[index * 2] = sample
                block[index * 2 + 1] = sample
            }
            meter.ingest(interleavedStereo: block)
        }
        #expect(abs(meter.shortTermLUFS - -20) < 0.6)
        #expect(abs(meter.momentaryLUFS - -20) < 0.6)
        #expect(abs(meter.peakDb - -20) < 0.5)
        #expect(!meter.clippedRecently())
        meter.ingest(interleavedStereo: [1, 1, 0, 0])
        #expect(meter.clippedRecently())
    }

    // MARK: Camera audio through the single mic lane

    @Test
    func cameraWithMic_opensMicGate_andRowIsLiveViaItsMic() throws {
        let camera = Self.shot("MacBook Pro Camera", .systemCamera, endpoint: "avf://cam1")
        let layers = [Self.layer(1, [camera], live: camera)]
        #expect(!ProgramAudioGatePolicy.derive(from: layers).microphone)
        #expect(ProgramAudioGatePolicy.derive(from: layers, cameraHasMic: { _ in true }).microphone)
        var input = OnAirAudioInputs()
        input.layers = layers
        input.channels = Self.channels()
        input.cameraMics[camera.id] = "MacBook Pro Microphone"
        let row = try Self.row(OnAirAudioResolver.resolve(input), "MacBook Pro Camera")
        #expect(row.state == .live)
        #expect(row.via == "MacBook Pro Microphone")
    }

    @Test
    func cameraNotRouted_hasActionableFix() throws {
        let camera = Self.shot("Cam", .systemCamera, endpoint: "avf://cam1")
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [camera], live: camera)]
        input.channels = Self.channels()
        input.camerasWithoutMic = [camera.id]
        let none = try Self.row(OnAirAudioResolver.resolve(input), "Cam")
        #expect(none.state == .notRouted)
        #expect(none.fix == .addMic)
        let muted = Self.shot("Muted", .systemCamera, endpoint: "avf://cam1", muted: true)
        input.camerasWithoutMic = []
        input.layers = [Self.layer(1, [muted], live: muted)]
        let off = try Self.row(OnAirAudioResolver.resolve(input), "Muted")
        #expect(off.state == .muted)
        #expect(off.fix == .useCameraMic(layer: 0, shotID: muted.id))
    }

    @Test
    func micShotOwnsTheMic_cameraIsArmed_notDoubled() throws {
        let camera = Self.shot("Cam", .systemCamera, endpoint: "avf://cam1")
        let mic = Self.shot("Desk mic", .systemMicrophone)
        var input = OnAirAudioInputs()
        input.layers = [Self.layer(1, [camera], live: camera), Self.layer(2, [mic], live: mic)]
        input.channels = Self.channels()
        input.cameraMics[camera.id] = "MacBook Pro Microphone"
        let rows = OnAirAudioResolver.resolve(input)
        #expect(try Self.row(rows, "Cam").state == .armed)
        #expect(try Self.row(rows, "Desk mic").state == .live)
        let alerts = OnAirAudioResolver.alerts(
            sources: rows, channels: input.channels, capture: [:],
            programSilentSeconds: 0, isLive: false, clippedRecently: false
        )
        #expect(!alerts.contains { $0.kind == .doubled })
    }

}
