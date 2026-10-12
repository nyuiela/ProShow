import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Binds Layer 3 media, hardware taps, and the matrix into one Fairlight-style pipeline.
@MainActor
@Observable
final class ShowAudioController {
    var spectrum: [Float] = Array(repeating: 0, count: AudioDSP.bandCount)
    var waveform: [Double] = []
    var attachedMediaID: UUID?
    var eqChannelID: UUID?

    private weak var matrix: AudioMatrixEngine?
    private weak var io: AudioIOEngine?
    private weak var playback: MediaPlaybackEngine?

    func attach(matrix: AudioMatrixEngine, io: AudioIOEngine, playback: MediaPlaybackEngine) {
        self.matrix = matrix
        self.io = io
        self.playback = playback
        io.onInputBuffer = { [weak self] role, samples, rate in
            self?.ingestSamples(role: role, samples: samples, sampleRate: rate)
        }
    }

    func tick(streamEncodeActive: Bool = false) {
        guard let matrix, let playback else { return }
        attachActiveMediaTrack(id: playback.mediaID, playerItem: nil)
        applySlideMix(matrix: matrix, playback: playback, streamEncodeActive: streamEncodeActive)
        if let slide = matrix.channel(role: .slide) {
            if let window = ProgramSlideAudioMeter.spectrumWindow() {
                spectrum = AudioDSP.fftMagnitudes(samples: window.samples, sampleRate: window.sampleRate)
            } else {
                let linear = AudioDSP.linear(fromDb: slide.peak)
                if spectrum.allSatisfy({ $0 < 0.02 }) || (io?.lastPeaks[.microphone] ?? -120) < -40 {
                    spectrum = AudioDSP.voicedSpectrum(peakLinear: linear, playhead: playback.playhead)
                }
            }
        }
        matrix.processFrame()
    }

    func attachActiveMediaTrack(id: UUID?, playerItem: Any? = nil) {
        let _ = playerItem
        guard attachedMediaID != id else { return }
        attachedMediaID = id
        waveform = []
        guard let playback, let url = playback.fileURL else { return }
        waveform = decodeWaveform(url: url)
    }

    func openEQ(for id: UUID) {
        eqChannelID = id
    }

    func closeEQ() {
        eqChannelID = nil
    }

    func setBand(_ band: ParametricEQBand, on channelID: UUID) {
        guard let matrix, var eq = matrix.channel(id: channelID)?.resolvedEQ else { return }
        if let index = eq.bands.firstIndex(where: { $0.id == band.id }) {
            eq.bands[index] = band
            matrix.setEQ(id: channelID, eq: eq)
        }
    }

    func ingestCaptureSamples(role: AudioChannelRole, samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        ProgramStreamAudioGates.enqueueCapture(role: role, mono: samples, sampleRate: sampleRate)
        let fft = AudioDSP.fftMagnitudes(samples: samples, sampleRate: sampleRate)
        if role == .microphone || fft.contains(where: { $0 > 0.08 }) {
            spectrum = fft
        }
    }

    private func ingestSamples(role: AudioChannelRole, samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty else { return }
        ProgramStreamAudioGates.enqueueCapture(role: role, mono: samples, sampleRate: sampleRate)
        let fft = AudioDSP.fftMagnitudes(samples: samples, sampleRate: sampleRate)
        if role == .microphone || fft.contains(where: { $0 > 0.08 }) {
            spectrum = fft
        }
    }

    private func applySlideMix(
        matrix: AudioMatrixEngine,
        playback: MediaPlaybackEngine,
        streamEncodeActive: Bool
    ) {
        let programMixHeadphones = ProgramAudioMonitorBridge.shared.isRunning
            && AudioMonitoringEngine.shared.monitorMode == .programMix
        let gain: Double
        if programMixHeadphones {
            // Tap still feeds stream lanes; operator hears only the post-mix monitor bridge.
            gain = 0
        } else {
            gain = Self.programPlayerGain(
                isMuted: playback.isMuted,
                slide: matrix.channel(role: .slide),
                matrix: matrix,
                streamEncodeActive: streamEncodeActive
            )
        }
        playback.applyMixGain(gain)
    }

    /// Synthesizes a return mix for remote guests (master program minus their own mic when enabled).
    func mixMinusProgramLinear(guestMicLinear: Double, programLinear: Double) -> Double {
        let minus = max(0, programLinear - guestMicLinear)
        return min(1, minus)
    }

    func mixMinusReturnLinear(forGuestID guestID: UUID?, matrix: AudioMatrixEngine, mode: BackstageReturnFeedMode) -> Double {
        switch mode {
        case .intercomOnly:
            guard let mic = matrix.channel(role: .microphone) else { return 0 }
            return matrix.outputLevel(for: mic, bus: .monitor)
        case .programFull:
            return matrix.monitorMixLinear()
        case .programMixMinus:
            return matrix.mixMinusLinear(excludingGuestID: guestID)
        }
    }

    /// Local speakers follow the slide fader on monitor or stream. Previews stay silent copies.
    static func programPlayerGain(
        isMuted: Bool,
        slide: AudioMatrixChannel?,
        matrix: AudioMatrixEngine,
        streamEncodeActive: Bool = false
    ) -> Double {
        if isMuted || matrix.programMuted || matrix.master.muted { return 0 }
        guard let slide else { return 1 }
        if slide.muted { return 0 }
        let anySolo = matrix.channels.contains(where: \.solo)
        if anySolo && !slide.solo { return 0 }
        if streamEncodeActive {
            let stream = matrix.outputLevel(for: slide, bus: .stream)
            if stream > 0.0001 { return min(1, stream) }
            return 0
        }
        let routed = max(
            matrix.outputLevel(for: slide, bus: .monitor),
            matrix.outputLevel(for: slide, bus: .stream)
        )
        if routed > 0.0001 {
            return min(1, routed)
        }
        if slide.bus == .stage { return 0 }
        return min(1, max(0, AudioDSP.linear(fromDb: slide.resolvedTrimDb + slide.gainDb)))
    }

    private func decodeWaveform(url: URL, buckets: Int = 120) -> [Double] {
        #if canImport(AVFoundation)
        guard let file = try? AVAudioFile(forReading: url) else {
            return (0..<buckets).map { index in 0.18 + 0.12 * sin(Double(index) / 4) }
        }
        let frames = Int(file.length)
        guard frames > 0 else { return [] }
        let hop = max(1, frames / buckets)
        var peaks = [Double](repeating: 0, count: buckets)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(hop, 4_096))) else {
            return []
        }
        for bucket in 0..<buckets {
            let position = AVAudioFramePosition(bucket * hop)
            file.framePosition = min(position, file.length - 1)
            do {
                try file.read(into: buffer)
            } catch {
                break
            }
            let stereo = AudioDSP.stereoPeaks(from: buffer)
            peaks[bucket] = AudioDSP.meterLevel(fromDb: max(stereo.left, stereo.right))
        }
        return peaks
        #else
        return (0..<buckets).map { index in 0.18 + 0.12 * sin(Double(index) / 4) }
        #endif
    }
}
