import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(AudioKit)
import AudioKit
#endif

/// Hardware I/O for the matrix: mic tap, pad players, slide/desktop peaks, stream vs monitor.
@MainActor
@Observable
final class AudioIOEngine {
    var hardwareEnabled = false
    var isRunning = false
    var programMuted = false
    var lastPeaks: [AudioChannelRole: Double] = [:]
    var lastStereoPeaks: [AudioChannelRole: (left: Double, right: Double)] = [:]
    var onInputBuffer: ((AudioChannelRole, [Float], Double) -> Void)?

    #if canImport(AudioKit)
    private var kit: AudioEngine?
    private var analysisMixer: Mixer?
    private var meterMixer: Mixer?
    private var fftMixer: Mixer?
    private var outputMixer: Mixer?
    #endif
    #if canImport(AVFoundation)
    private var engine: AVAudioEngine?
    private var captureEngine: AVAudioEngine?
    private var padPlayers: [UUID: AVAudioPlayerNode] = [:]
    #endif

    #if canImport(AudioKit)
    var meterNode: Node? { meterMixer }
    var fftNode: Node? { fftMixer }
    var outputNode: Node? { outputMixer }
    #endif

    func startIfNeeded() {
        guard hardwareEnabled, !isRunning else { return }
        #if canImport(AudioKit)
        startAudioKitGraph()
        #elseif canImport(AVFoundation)
        startLegacyGraph()
        #else
        isRunning = false
        #endif
    }

    /// Default mic tap for live stream / ISO when capture devices are not providing mic PCM.
    func startCaptureIfNeeded() {
        guard hardwareEnabled else { return }
        #if canImport(AVFoundation)
        if captureEngine != nil { return }
        #if !canImport(AudioKit)
        if isRunning { return }
        #endif
        let graph = AVAudioEngine()
        let input = graph.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate >= 8_000, inputFormat.channelCount >= 1 else { return }
        installAnalysisTap(on: input)
        do {
            try graph.start()
            captureEngine = graph
            ProgramStreamAudioGates.setSystemInputTapOpen(true)
        } catch {
            input.removeTap(onBus: 0)
        }
        #endif
    }

    func stopCapture() {
        #if canImport(AVFoundation)
        captureEngine?.inputNode.removeTap(onBus: 0)
        captureEngine?.stop()
        captureEngine = nil
        ProgramStreamAudioGates.setSystemInputTapOpen(false)
        #endif
    }

    func stop() {
        stopCapture()
        #if canImport(AVFoundation)
        engine?.inputNode.removeTap(onBus: 0)
        #if canImport(AudioKit)
        analysisMixer?.avAudioNode.removeTap(onBus: 0)
        kit?.stop()
        kit = nil
        analysisMixer = nil
        meterMixer = nil
        fftMixer = nil
        outputMixer = nil
        #endif
        engine?.stop()
        padPlayers.values.forEach { $0.stop() }
        padPlayers.removeAll()
        engine = nil
        #endif
        isRunning = false
    }

    func muteProgram(_ muted: Bool) {
        programMuted = muted
        applyMixerMute()
    }

    /// Desk title bar — silence local graph output without affecting stream capture lanes.
    func syncLocalSpeakerPolicy() {
        applyMixerMute()
    }

    func injectPeak(role: AudioChannelRole, db: Double) {
        lastPeaks[role] = db
        lastStereoPeaks[role] = (db, db)
    }

    func playPad(_ pad: SoundboardPad, fileURL: URL? = nil) {
        lastPeaks[.soundboard] = pad.ducksProgram ? -3 : -8
        guard hardwareEnabled else { return }
        startIfNeeded()
        #if canImport(AVFoundation)
        playPadFile(pad, fileURL: fileURL)
        #endif
    }

    func stopPad(_ id: UUID) {
        lastPeaks[.soundboard] = -120
        #if canImport(AVFoundation)
        padPlayers[id]?.stop()
        #endif
    }

    func stopAllPads() {
        lastPeaks[.soundboard] = -120
        #if canImport(AVFoundation)
        padPlayers.values.forEach { $0.stop() }
        #endif
    }

    func tick(
        playback: MediaPlaybackEngine,
        soundboard: SoundboardStore,
        matrix: AudioMatrixEngine
    ) {
        matrix.ensureStandardBuses()
        refreshSlideMeter(playback)
        let slideDb = ProgramSlideAudioMeter.peakDb()
        lastPeaks[.slide] = slideDb
        lastStereoPeaks[.slide] = (slideDb, slideDb)
        if soundboard.playing.isEmpty {
            lastPeaks[.soundboard] = -120
        } else if lastPeaks[.soundboard] == nil || lastPeaks[.soundboard] == -120 {
            lastPeaks[.soundboard] = -9
        }
        if lastPeaks[.desktop] == nil {
            lastPeaks[.desktop] = -120
        }
        if lastPeaks[.microphone] == nil {
            lastPeaks[.microphone] = matrix.channel(id: StudioSeedID.mic)?.peak ?? -120
        }
        applyPeaks(to: matrix)
        applyMixerMute()
    }

    private func refreshSlideMeter(_ playback: MediaPlaybackEngine) {
        #if canImport(AVFoundation)
        let playerPlaying = playback.player.timeControlStatus == .playing
        #else
        let playerPlaying = false
        #endif
        let playing = playback.isPlaying || playerPlaying
        if playing, let url = playback.fileURL {
            let audible = !playback.isMuted && playback.mixGain > 0.0001
            AudibleVideoClock.note(
                id: AudibleVideoClock.programID,
                url: url,
                playhead: playback.playhead,
                audible: audible
            )
            ProgramSlideFileMeter.request(url: url, playhead: playback.playhead)
            return
        }
        if let clip = AudibleVideoClock.latest() {
            ProgramSlideFileMeter.request(url: clip.url, playhead: clip.playhead)
        }
    }

    func applyPeaks(to matrix: AudioMatrixEngine) {
        let guestPeaks = GuestAudioLevels.snapshot()
        for channel in matrix.channels {
            if channel.role == .guest {
                if let linked = channel.linkedGuestID, let stereo = guestPeaks[linked] {
                    matrix.setStereoPeak(id: channel.id, left: stereo.left, right: stereo.right)
                } else {
                    matrix.setPeak(id: channel.id, db: -120)
                }
                continue
            }
            if let stereo = lastStereoPeaks[channel.role] {
                matrix.setStereoPeak(id: channel.id, left: stereo.left, right: stereo.right)
            } else if let peak = lastPeaks[channel.role] {
                matrix.setPeak(id: channel.id, db: peak)
            }
        }
        matrix.processFrame()
    }

    #if canImport(AVFoundation)
    nonisolated static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }
    #endif

    #if canImport(AVFoundation)
    nonisolated static func stereoPeakDb(from buffer: AVAudioPCMBuffer) -> (left: Double, right: Double) {
        guard let data = buffer.floatChannelData else { return (-120, -120) }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return (-120, -120) }
        func peak(_ samples: UnsafePointer<Float>) -> Double {
            var peak: Float = 0
            for index in 0..<count {
                peak = max(peak, abs(samples[index]))
            }
            if peak <= 0.0001 { return -120 }
            return Double(20 * log10(peak))
        }
        let left = peak(data[0])
        let right = buffer.format.channelCount > 1 ? peak(data[1]) : left
        return (left, right)
    }

    nonisolated static func peakDb(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?.pointee else { return -120 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -120 }
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(channel[index]))
        }
        if peak <= 0.0001 { return -120 }
        return Double(20 * log10(peak))
    }
    #endif

    private func applyMixerMute() {
        #if canImport(AudioKit)
        let silent = programMuted || AudioMonitoringEngine.shared.localSpeakerMuted
        outputMixer?.volume = silent ? 0 : 1
        #endif
    }

    #if canImport(AudioKit)
    private func startAudioKitGraph() {
        guard !isRunning else { return }
        let kit = AudioEngine()
        let analysis = Mixer()
        let meters = Mixer()
        let fft = Mixer()
        let output = Mixer()
        meters.addInput(analysis)
        fft.addInput(meters)
        output.addInput(fft)
        kit.output = output
        output.volume = (programMuted || AudioMonitoringEngine.shared.localSpeakerMuted) ? 0 : 1
        do {
            try kit.start()
            self.kit = kit
            analysisMixer = analysis
            meterMixer = meters
            fftMixer = fft
            outputMixer = output
            isRunning = true
        } catch {
            kit.stop()
            isRunning = false
        }
    }
    #endif

    #if canImport(AVFoundation) && !canImport(AudioKit)
    private func startLegacyGraph() {
        let graph = AVAudioEngine()
        let input = graph.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        let canTap = inputFormat.sampleRate >= 8_000 && inputFormat.channelCount >= 1
        if canTap {
            installAnalysisTap(on: input)
        }
        do {
            try graph.start()
            engine = graph
            isRunning = true
            applyMixerMute()
        } catch {
            if canTap {
                input.removeTap(onBus: 0)
            }
            engine = nil
            isRunning = false
        }
    }
    #endif

    #if canImport(AVFoundation)
    private func playPadFile(_ pad: SoundboardPad, fileURL: URL?) {
        guard let fileURL, let file = try? AVAudioFile(forReading: fileURL) else { return }
        #if canImport(AudioKit)
        guard let outputMixer, let engine = outputMixer.avAudioNode.engine else { return }
        #else
        guard let engine else { return }
        #endif
        let player = padPlayers[pad.id] ?? AVAudioPlayerNode()
        if padPlayers[pad.id] == nil {
            engine.attach(player)
            #if canImport(AudioKit)
            engine.connect(player, to: outputMixer.avAudioNode, format: nil)
            #else
            return
            #endif
            padPlayers[pad.id] = player
        }
        player.stop()
        player.scheduleFile(file, at: nil)
        player.volume = Float(max(0, min(1, pad.volume)))
        player.play()
    }

    private func installAnalysisTap(on node: AVAudioNode) {
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate >= 8_000, format.channelCount >= 1 else { return }
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            let stereo = AudioDSP.stereoPeaks(from: buffer)
            let samples = AudioIOEngine.monoSamples(from: buffer)
            let rate = buffer.format.sampleRate
            ProgramStreamAudioGates.enqueueCapture(role: .microphone, mono: samples, sampleRate: rate, source: "system-input")
            Task { @MainActor in
                self?.lastPeaks[.microphone] = max(stereo.left, stereo.right)
                self?.lastStereoPeaks[.microphone] = stereo
            }
        }
    }

    private static func toneBuffer() -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let frames: AVAudioFrameCount = 8_820
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?.pointee else { return nil }
        for index in 0..<Int(frames) {
            samples[index] = sin(Float(index) * 2 * .pi * 440 / 44_100) * 0.2
        }
        return buffer
    }
    #endif
}

/// Latest guest microphone peaks, written from the LiveKit audio thread and read on the mixer tick.
enum GuestAudioLevels {
    private static let lock = NSLock()
    private static var peaks: [UUID: (left: Double, right: Double, at: CFAbsoluteTime)] = [:]

    static func note(guestID: UUID, left: Double, right: Double) {
        lock.lock()
        peaks[guestID] = (left, right, CFAbsoluteTimeGetCurrent())
        lock.unlock()
    }

    static func snapshot() -> [UUID: (left: Double, right: Double)] {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        peaks = peaks.filter { now - $0.value.at < 0.35 }
        let copy = peaks.mapValues { (left: $0.left, right: $0.right) }
        lock.unlock()
        return copy
    }
}
