import Foundation
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// vDSP FFT, stereo peak, limiter, and 6-band EQ response math for the studio desk.
enum AudioDSP {
    static let bandCount = 64
    static let fftSize = 512
    #if canImport(Accelerate)
    private static let fftLock = NSLock()
    private static var cachedFFTSetup: FFTSetup?
    private static var cachedFFTLog2: vDSP_Length = 0

    /// One setup for the process. `fftMagnitudes` used to create and destroy this on every tick.
    private static func sharedFFTSetup(log2n: vDSP_Length) -> FFTSetup? {
        fftLock.lock()
        defer { fftLock.unlock() }
        if let cachedFFTSetup, cachedFFTLog2 == log2n {
            return cachedFFTSetup
        }
        if let cachedFFTSetup {
            vDSP_destroy_fftsetup(cachedFFTSetup)
        }
        guard let created = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            cachedFFTSetup = nil
            return nil
        }
        cachedFFTSetup = created
        cachedFFTLog2 = log2n
        return created
    }
    #endif
    static let meterFloorDb: Double = -60
    static let meterCeilDb: Double = 6

    static func db(from linear: Double) -> Double {
        let value = max(linear, 1e-8)
        return 20 * log10(value)
    }

    static func linear(fromDb db: Double) -> Double {
        pow(10, db / 20)
    }

    static func meterLevel(fromDb db: Double) -> Double {
        min(1, max(0, (db - meterFloorDb) / (meterCeilDb - meterFloorDb)))
    }

    static func holdPeak(current: Double, hold: Double, decayDb: Double = 0.8) -> Double {
        current >= hold ? current : max(current, hold - decayDb)
    }

    static func applyLimiter(_ linear: Double, enabled: Bool, ceilingDb: Double) -> Double {
        guard enabled else { return max(0, linear) }
        return min(max(0, linear), Self.linear(fromDb: ceilingDb))
    }

    static func fftMagnitudes(samples: [Float], sampleRate: Double, bands: Int = bandCount) -> [Float] {
        guard samples.count >= 16, bands > 1, sampleRate > 0 else {
            return Array(repeating: 0, count: max(bands, 1))
        }
        let n = min(fftSize, samples.count)
        var windowed = Array(samples.prefix(n))
        if windowed.count < fftSize {
            windowed.append(contentsOf: repeatElement(Float(0), count: fftSize - windowed.count))
        }
        #if canImport(Accelerate)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(windowed, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = sharedFFTSetup(log2n: log2n) else {
            return logBands(from: windowed, sampleRate: sampleRate, bands: bands)
        }

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        var scale = Float(1) / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(magnitudes.count))
        return logBands(from: magnitudes, sampleRate: sampleRate, bands: bands, isPowerSpectrum: true)
        #else
        return logBands(from: windowed, sampleRate: sampleRate, bands: bands)
        #endif
    }

    static func voicedSpectrum(peakLinear: Double, playhead: TimeInterval, bands: Int = bandCount) -> [Float] {
        let peak = Float(min(1, max(0, peakLinear)))
        guard peak > 0.0008 else { return Array(repeating: 0, count: bands) }
        return (0..<bands).map { index in
            let t = Float(index) / Float(max(bands - 1, 1))
            let envelope = exp(-3.2 * t) * (0.35 + 0.65 * peak)
            let motion = 0.72 + 0.28 * sin(Float(playhead) * 2.1 + t * 9)
            return min(1, envelope * motion)
        }
    }

    static func eqResponse(eq: ParametricEQ, frequencies: [Double]) -> [Double] {
        frequencies.map { frequency in
            eq.bands.reduce(0) { partial, band in
                guard band.enabled else { return partial }
                return partial + bandGain(band, at: frequency)
            }
        }
    }

    static func bandGain(_ band: ParametricEQBand, at frequency: Double) -> Double {
        let f = max(frequency, 1)
        let f0 = max(band.frequency, 1)
        let ratio = log2(f / f0)
        let width = max(band.q, 0.15)
        switch band.filter {
        case .highPass:
            return f < f0 ? -12 * min(1, (f0 / f - 1) / 3) : 0
        case .lowPass:
            return f > f0 ? -12 * min(1, (f / f0 - 1) / 3) : 0
        case .lowShelf:
            return band.gainDb / (1 + exp(3.2 * ratio))
        case .highShelf:
            return band.gainDb / (1 + exp(-3.2 * ratio))
        case .parametric:
            return band.gainDb * exp(-0.5 * pow(ratio * width * 1.6, 2))
        }
    }

    #if canImport(AVFoundation)
    static func stereoPeaks(from buffer: AVAudioPCMBuffer) -> (left: Double, right: Double) {
        guard let data = buffer.floatChannelData else { return (-120, -120) }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return (-120, -120) }
        let channels = Int(buffer.format.channelCount)
        let left = peakDb(samples: data[0], count: count)
        let right = channels > 1 ? peakDb(samples: data[1], count: count) : left
        return (left, right)
    }

    static func fftMagnitudes(from buffer: AVAudioPCMBuffer, bands: Int = bandCount) -> [Float] {
        guard let data = buffer.floatChannelData else { return Array(repeating: 0, count: bands) }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return Array(repeating: 0, count: bands) }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: min(count, fftSize)))
        return fftMagnitudes(samples: samples, sampleRate: buffer.format.sampleRate, bands: bands)
    }
    #endif

    private static func peakDb(samples: UnsafePointer<Float>, count: Int) -> Double {
        var peak: Float = 0
        for index in 0..<count {
            peak = max(peak, abs(samples[index]))
        }
        return db(from: Double(peak))
    }

    private static func logBands(from bins: [Float], sampleRate: Double, bands: Int, isPowerSpectrum: Bool = false) -> [Float] {
        guard !bins.isEmpty else { return Array(repeating: 0, count: bands) }
        let nyquist = sampleRate / 2
        return (0..<bands).map { index in
            let lowHz = logFrequency(index: index, bands: bands, nyquist: nyquist)
            let highHz = logFrequency(index: index + 1, bands: bands, nyquist: nyquist)
            let lowBin = max(0, Int(lowHz / nyquist * Double(bins.count - 1)))
            let highBin = min(bins.count - 1, max(lowBin + 1, Int(highHz / nyquist * Double(bins.count - 1))))
            var sum: Float = 0
            var weight: Float = 0
            for bin in lowBin...highBin {
                let value = isPowerSpectrum ? sqrt(max(0, bins[bin])) : abs(bins[bin])
                sum += value
                weight += 1
            }
            let magnitude = weight > 0 ? sum / weight : 0
            let db = 20 * log10(max(magnitude, 1e-6))
            return Float(meterLevel(fromDb: Double(db)))
        }
    }

    private static func logFrequency(index: Int, bands: Int, nyquist: Double) -> Double {
        let t = Double(index) / Double(max(bands, 1))
        return 20 * pow(nyquist / 20, t)
    }
}

/// One biquad section. Coefficients are normalized so a0 = 1.
struct BiquadFilter: Sendable {
    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double
    var x1 = 0.0
    var x2 = 0.0
    var y1 = 0.0
    var y2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = x
        y2 = y1
        y1 = y
        if y.isNaN || abs(y) > 8 { reset() ; return 0 }
        return y
    }

    mutating func reset() {
        x1 = 0
        x2 = 0
        y1 = 0
        y2 = 0
    }

    static func make(band: ParametricEQBand, sampleRate: Double) -> BiquadFilter {
        let sr = max(sampleRate, 8_000)
        let frequency = min(max(band.frequency, 20), sr * 0.45)
        let q = min(max(band.q, 0.2), 12)
        let w0 = 2 * Double.pi * frequency / sr
        let cosine = cos(w0)
        let sine = sin(w0)
        let alpha = sine / (2 * q)
        let a = pow(10, band.gainDb / 40)
        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double
        switch band.filter {
        case .highPass:
            b0 = (1 + cosine) / 2
            b1 = -(1 + cosine)
            b2 = (1 + cosine) / 2
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        case .lowPass:
            b0 = (1 - cosine) / 2
            b1 = 1 - cosine
            b2 = (1 - cosine) / 2
            a0 = 1 + alpha
            a1 = -2 * cosine
            a2 = 1 - alpha
        case .parametric:
            b0 = 1 + alpha * a
            b1 = -2 * cosine
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosine
            a2 = 1 - alpha / a
        case .lowShelf:
            let twoSqrtAAlpha = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) - (a - 1) * cosine + twoSqrtAAlpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosine)
            b2 = a * ((a + 1) - (a - 1) * cosine - twoSqrtAAlpha)
            a0 = (a + 1) + (a - 1) * cosine + twoSqrtAAlpha
            a1 = -2 * ((a - 1) + (a + 1) * cosine)
            a2 = (a + 1) + (a - 1) * cosine - twoSqrtAAlpha
        case .highShelf:
            let twoSqrtAAlpha = 2 * sqrt(a) * alpha
            b0 = a * ((a + 1) + (a - 1) * cosine + twoSqrtAAlpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosine)
            b2 = a * ((a + 1) + (a - 1) * cosine - twoSqrtAAlpha)
            a0 = (a + 1) - (a - 1) * cosine + twoSqrtAAlpha
            a1 = 2 * ((a - 1) - (a + 1) * cosine)
            a2 = (a + 1) - (a - 1) * cosine - twoSqrtAAlpha
        }
        let inv = a0 == 0 ? 1 : 1 / a0
        return BiquadFilter(b0: b0 * inv, b1: b1 * inv, b2: b2 * inv, a1: a1 * inv, a2: a2 * inv)
    }
}

/// EQ, noise gate, and compressor applied to a bus before the stream and headphone mixes.
struct ChannelStripSettings: Equatable, Sendable {
    var filters: [ParametricEQBand] = []
    var gateEnabled = false
    var compEnabled = false

    static func make(channel: AudioMatrixChannel, gate: Bool, comp: Bool) -> ChannelStripSettings {
        let filters = channel.resolvedEQ.bands.filter { band in
            guard band.enabled else { return false }
            switch band.filter {
            case .highPass, .lowPass:
                return true
            case .lowShelf, .highShelf, .parametric:
                return abs(band.gainDb) > 0.05
            }
        }
        return ChannelStripSettings(filters: filters, gateEnabled: gate, compEnabled: comp)
    }

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(gateEnabled)
        hasher.combine(compEnabled)
        for band in filters {
            hasher.combine(band.id)
            hasher.combine(band.filter.rawValue)
            hasher.combine(band.frequency)
            hasher.combine(band.gainDb)
            hasher.combine(band.q)
            hasher.combine(band.enabled)
        }
        return hasher.finalize()
    }
}

struct ChannelStripRuntime: Sendable {
    var sampleRate: Double = 0
    var signature: Int = 0
    var filters: [BiquadFilter] = []
    var gateGain: Double = 1

    mutating func process(_ samples: [Float], settings: ChannelStripSettings, sampleRate: Double) -> [Float] {
        let rate = max(sampleRate, 8_000)
        let signature = settings.signature
        if self.sampleRate != rate || self.signature != signature {
            self.sampleRate = rate
            self.signature = signature
            filters = settings.filters.map { BiquadFilter.make(band: $0, sampleRate: rate) }
            gateGain = 1
        }
        guard !samples.isEmpty else { return samples }
        var output = samples
        if !filters.isEmpty {
            for index in output.indices {
                var sample = Double(output[index])
                for filterIndex in filters.indices {
                    sample = filters[filterIndex].process(sample)
                }
                output[index] = Float(max(-1, min(1, sample)))
            }
        }
        if settings.gateEnabled {
            var peak: Float = 0
            for sample in output { peak = max(peak, abs(sample)) }
            let target = peak >= 0.008 ? 1.0 : 0.0
            let step = (target - gateGain) / Double(max(output.count, 1))
            for index in output.indices {
                gateGain += step
                output[index] = Float(Double(output[index]) * gateGain)
            }
        }
        if settings.compEnabled {
            let threshold = 0.18
            let ratio = 4.0
            for index in output.indices {
                let sample = Double(output[index])
                let magnitude = abs(sample)
                guard magnitude > threshold else { continue }
                let compressed = threshold + (magnitude - threshold) / ratio
                let sign = sample < 0 ? -1.0 : 1.0
                output[index] = Float(max(-1, min(1, sign * compressed * 1.5)))
            }
        }
        return output
    }
}
