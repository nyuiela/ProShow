#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct AudioMatrixTests {
    @Test @MainActor
    func ducking_lowersDesktopWhenMicExceedsThreshold() throws {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        matrix.duckingEnabled = true
        matrix.duckThresholdDb = -24
        matrix.duckAmountDb = -12
        matrix.setPeak(id: StudioSeedID.mic, db: -10)
        matrix.setPeak(id: StudioSeedID.desktop, db: -6)
        matrix.processFrame()
        #expect(matrix.duckingActive)
        let desktop = try #require(matrix.channel(id: StudioSeedID.desktop))
        let ducked = matrix.outputLevel(for: desktop, bus: .stream)
        #expect(abs(ducked - AudioMatrixEngine.linearGain(db: -18)) < 0.001)

        matrix.setPeak(id: StudioSeedID.mic, db: -40)
        matrix.processFrame()
        #expect(!matrix.duckingActive)
    }

    @Test @MainActor
    func soundboard_playsPadAndControlRoute() {
        let controller = TestSupport.sampleController()
        #expect(controller.soundboard.pads.contains(where: { $0.id == StudioSeedID.applause }))
        #expect(controller.soundboard.play(StudioSeedID.applause))
        #expect(controller.soundboard.playing[StudioSeedID.applause] != nil)
        #expect(controller.soundboard.waveform(for: StudioSeedID.applause).isEmpty == false)

        let play = controller.handleControl(
            method: "POST",
            path: "/v1/soundboard/\(StudioSeedID.applause.uuidString)/play"
        )
        #expect(play.0 == 200)
        let meters = controller.handleControl(method: "GET", path: "/v1/audio/meters")
        #expect(meters.0 == 200)
        #expect(meters.1.contains("Mic"))
    }

    @Test @MainActor
    func duckTargetOff_leavesDesktopUnducked() throws {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        matrix.duckingEnabled = true
        matrix.duckThresholdDb = -24
        matrix.duckAmountDb = -12
        matrix.setDuckTarget(id: StudioSeedID.desktop, enabled: false)
        matrix.setPeak(id: StudioSeedID.mic, db: -10)
        matrix.setPeak(id: StudioSeedID.desktop, db: -6)
        matrix.processFrame()
        #expect(matrix.duckingActive)
        let desktop = try #require(matrix.channel(id: StudioSeedID.desktop))
        let level = matrix.outputLevel(for: desktop, bus: .stream)
        #expect(abs(level - AudioMatrixEngine.linearGain(db: desktop.gainDb)) < 0.02)
    }

    @MainActor @Test
    func strip_gateSilencesQuietAudioAndCompTamesPeaks() {
        var runtime = ChannelStripRuntime()
        let gate = ChannelStripSettings(filters: [], gateEnabled: true, compEnabled: false)
        let quiet = runtime.process(Array(repeating: 0.001, count: 64), settings: gate, sampleRate: 48_000)
        #expect(quiet.last ?? 1 < 0.0002)

        runtime = ChannelStripRuntime()
        let comp = ChannelStripSettings(filters: [], gateEnabled: false, compEnabled: true)
        let hot = runtime.process(Array(repeating: 0.9, count: 32), settings: comp, sampleRate: 48_000)
        #expect((hot.first ?? 1) < 0.9)

        var fader = AudioMatrixEngine()
        let channel = AudioMatrixChannel(name: "Mic", role: .microphone, gainDb: 12)
        fader.install([channel])
        let level = fader.outputLevel(for: channel, bus: .stream)
        #expect(level > 1.5)
    }
}

@Suite struct ProgramAudioGatePolicyTests {
    private func shot(_ type: SourceType, muted: Bool = false) -> LayerShot {
        LayerShot(
            name: "s",
            source: DiscoveredSourceItem(name: "s", category: .all, groupName: "g", sourceType: type, connectionString: "x"),
            isCopy: false,
            audioMuted: muted
        )
    }

    private func layer(_ shots: [LayerShot], live: Int?) -> MasterLayer {
        var l = MasterLayer.defaults[0]
        l.shots = shots
        l.liveShotID = live.map { shots[$0].id }
        return l
    }

    @Test func cameraNeverOpensMicrophone() {
        let g = ProgramAudioGatePolicy.derive(from: [layer([shot(.systemCamera)], live: 0)])
        #expect(g.microphone == false)
    }

    @Test func liveMicOpensAndRemovingItCloses() {
        let mic = shot(.systemMicrophone)
        #expect(ProgramAudioGatePolicy.derive(from: [layer([mic], live: 0)]).microphone)
        #expect(ProgramAudioGatePolicy.derive(from: [layer([mic], live: nil)]).microphone == false)
        #expect(ProgramAudioGatePolicy.derive(from: [layer([], live: nil)]).microphone == false)
    }

    @Test func mutedMicStaysClosed() {
        #expect(ProgramAudioGatePolicy.derive(from: [layer([shot(.systemMicrophone, muted: true)], live: 0)]).microphone == false)
    }

    @Test func nonLiveMicShotOnLayerIsClosed() {
        let g = ProgramAudioGatePolicy.derive(from: [layer([shot(.systemCamera), shot(.systemMicrophone)], live: 0)])
        #expect(g.microphone == false)
    }
}
