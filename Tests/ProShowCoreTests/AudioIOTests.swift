#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct AudioIOTests {
    @Test @MainActor
    func enableLiveIO_doesNotStartAudioGraph() {
        let controller = TestSupport.sampleController()
        controller.enableLiveIO()
        controller.audioIO.muteProgram(true)
        controller.tickProgram()
        controller.audioIO.muteProgram(false)
        controller.tickProgram()
        #expect(controller.audioIO.hardwareEnabled)
        #expect(controller.audioIO.isRunning == false)
        #expect(controller.audioIO.outputNode == nil)
        #expect(controller.audioIO.programMuted == false)
    }

    @Test @MainActor
    func audioKitGraph_staysIdleUntilLiveIO() {
        let controller = TestSupport.sampleController()
        #expect(controller.audioIO.isRunning == false)
        #expect(controller.audioIO.fftNode == nil)
        #expect(controller.audioIO.meterNode == nil)
        #expect(controller.audioIO.outputNode == nil)
        controller.enableLiveIO()
        #expect(controller.audioIO.isRunning == false)
        #expect(controller.audioIO.outputNode == nil)
    }

    @Test @MainActor
    func liveMicPeak_ducksDesktop() throws {
        let controller = TestSupport.sampleController()
        controller.audioMatrix.duckingEnabled = true
        controller.audioMatrix.duckThresholdDb = -24
        controller.audioMatrix.duckAmountDb = -12
        controller.audioIO.injectPeak(role: .microphone, db: -10)
        controller.audioIO.injectPeak(role: .desktop, db: -6)
        controller.audioIO.applyPeaks(to: controller.audioMatrix)
        #expect(controller.audioMatrix.duckingActive)
        let desktop = try #require(controller.audioMatrix.channel(id: StudioSeedID.desktop))
        let ducked = controller.audioMatrix.outputLevel(for: desktop, bus: .stream)
        #expect(abs(ducked - AudioMatrixEngine.linearGain(db: -18)) < 0.001)
    }

    @Test @MainActor
    func clearAudio_mutesMixerNotOnlyStack() {
        let controller = TestSupport.sampleController()
        controller.audioMatrix.setPeak(id: StudioSeedID.desktop, db: -6)
        controller.audioMatrix.processFrame()
        #expect(controller.audioMatrix.monitorMixLevel() > 0)
        _ = controller.playSoundboardPad(StudioSeedID.applause)
        #expect(controller.soundboard.playing[StudioSeedID.applause] != nil)
        controller.clearAudio()
        #expect(controller.compositor.stack.audioMuted)
        #expect(controller.audioMatrix.programMuted)
        #expect(controller.audioIO.programMuted)
        #expect(controller.audioMatrix.streamMixLevel() == 0)
        #expect(controller.audioMatrix.monitorMixLevel() == 0)
        #expect(controller.soundboard.playing.isEmpty)
        #expect(controller.audioMatrix.channel(id: StudioSeedID.desktop)?.muted == true)
    }

    @Test @MainActor
    func tick_updatesSlideAndSoundboardPeaks() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        _ = controller.playSoundboardPad(StudioSeedID.applause)
        controller.tickProgram()
        let slide = controller.audioMatrix.channels.first(where: { $0.role == .slide })
        let board = controller.audioMatrix.channels.first(where: { $0.role == .soundboard })
        #expect((slide?.peak ?? -120) > -80)
        #expect((board?.peak ?? -120) > -80)
        #expect(controller.audioMatrix.programMuted == false)
    }

    @Test @MainActor
    func streamAndMonitor_areIndependentUntilMute() throws {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        matrix.setPeak(id: StudioSeedID.mic, db: -12)
        if let slide = matrix.channels.first(where: { $0.role == .slide }) {
            matrix.channels[matrix.channels.firstIndex(where: { $0.id == slide.id })!].bus = .stream
        }
        if let desktop = matrix.channels.firstIndex(where: { $0.id == StudioSeedID.desktop }) {
            matrix.channels[desktop].bus = .monitor
        }
        matrix.processFrame()
        #expect(matrix.streamMixLevel() > 0)
        #expect(matrix.monitorMixLevel() > 0)
        matrix.muteProgram(true)
        #expect(matrix.streamMixLevel() == 0)
        #expect(matrix.monitorMixLevel() == 0)
    }
}
