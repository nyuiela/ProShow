#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct AudioDSPTests {
    @Test
    func sineFFT_hasEnergyInMidBands() {
        let sampleRate = 44_100.0
        let frequency = 1_000.0
        let samples: [Float] = (0..<512).map { index in
            Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
        let bands = AudioDSP.fftMagnitudes(samples: samples, sampleRate: sampleRate, bands: 64)
        #expect(bands.count == 64)
        #expect((bands.max() ?? 0) > 0.05)
    }

    @Test
    func eqResponse_peakBoostsCenter() {
        var eq = ParametricEQ.studioDefault
        eq.bands[2].frequency = 1_000
        eq.bands[2].gainDb = 6
        let response = AudioDSP.eqResponse(eq: eq, frequencies: [80, 1_000, 12_000])
        #expect(response[1] > response[0])
        #expect(response[1] > 2)
    }

    @Test
    func limiter_clampsAboveCeiling() {
        let open = AudioDSP.applyLimiter(2.0, enabled: false, ceilingDb: -0.1)
        let limited = AudioDSP.applyLimiter(2.0, enabled: true, ceilingDb: -0.1)
        #expect(open == 2.0)
        #expect(limited <= AudioDSP.linear(fromDb: -0.1) + 0.0001)
    }

    @Test @MainActor
    func attachSlideMedia_createsLiveStripAndSpectrum() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        controller.tickProgram()
        #expect(controller.studioAudio.attachedMediaID == controller.playback.mediaID)
        #expect(controller.audioMatrix.channel(role: .slide) != nil)
        let slide = controller.audioMatrix.channel(role: .slide)
        #expect((slide?.peak ?? -120) > -80)
        #expect(controller.studioAudio.spectrum.count == AudioDSP.bandCount)
        #expect((controller.studioAudio.spectrum.max() ?? 0) > 0)
    }

    @Test @MainActor
    func programPlayerGain_followsSlideFaderOnMonitorOrStream() {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        let slide = matrix.channel(role: .slide)!
        let open = ShowAudioController.programPlayerGain(isMuted: false, slide: slide, matrix: matrix)
        #expect(open > 0.5)

        matrix.channels[matrix.channels.firstIndex(where: { $0.id == slide.id })!].bus = .monitor
        let monitorOnly = ShowAudioController.programPlayerGain(isMuted: false, slide: matrix.channel(role: .slide), matrix: matrix)
        #expect(monitorOnly > 0.5)

        #expect(ShowAudioController.programPlayerGain(isMuted: true, slide: slide, matrix: matrix) == 0)
        matrix.setMute(id: slide.id, muted: true)
        #expect(ShowAudioController.programPlayerGain(isMuted: false, slide: matrix.channel(role: .slide), matrix: matrix) == 0)
    }

    @Test @MainActor
    func programMedia_keepsPlayerAudibleWhenLive() {
        let controller = TestSupport.sampleController()
        let media = MediaAction(
            id: UUID(),
            title: "worship-loop.mp4",
            tintHex: "#112233",
            duration: "1:00.00",
            isImage: false,
            filePath: "/tmp/worship-loop.mp4"
        )
        controller.compositor.transitionLayer(.media, to: media, transitionDuration: 0)
        controller.playback.load(media, restart: true)
        controller.applyProgramAudioMute()
        controller.studioAudio.tick()
        #expect(controller.isProgramMediaMuted == false)
        #expect(controller.playback.isMuted == false)
        #expect(controller.playback.mixGain > 0.4)
    }

    @Test @MainActor
    func goLive_armsProgramAudioWithoutInspectorPlay() {
        let controller = TestSupport.sampleController()
        let slide = controller.addSlide(named: "Live Audio")
        controller.configureSlide(id: slide.id) {
            $0.backgroundEnabled = false
            $0.mediaAction = MediaAction(
                id: UUID(),
                title: "worship-loop.mp4",
                tintHex: "#112233",
                duration: "1:00.00",
                isImage: false,
                filePath: "/tmp/worship-loop.mp4"
            )
        }
        controller.goLive(slideID: slide.id)
        #expect(controller.playback.isPlaying)
        #expect(controller.playback.isMuted == false)
        #expect(controller.playback.mixGain > 0.4)
        #expect(controller.isProgramMediaMuted == false)
    }

    @Test @MainActor
    func soloAndEQ_updateMatrix() {
        let matrix = AudioMatrixEngine()
        matrix.install(DefaultSeedData.studioManifest().audioChannels)
        let slide = matrix.channel(role: .slide)!
        matrix.toggleSolo(id: slide.id)
        #expect(matrix.channel(id: slide.id)?.solo == true)
        var eq = ParametricEQ.studioDefault
        eq.bands[2].gainDb = 4
        matrix.setEQ(id: slide.id, eq: eq)
        #expect(matrix.channel(id: slide.id)?.resolvedEQ.bands[2].gainDb == 4)
        matrix.setTrim(id: slide.id, db: 2)
        #expect(matrix.channel(id: slide.id)?.resolvedTrimDb == 2)
    }
}
