import Foundation

extension ShowController {
    private enum DeskProbeEncodeSampler {
        static var lastCount: UInt64 = 0
        static var lastSampleDate = Date.distantPast
    }

    /// Rolling encode cadence while hardware encoder is active (live / ISO / encoded preview).
    func deskProbeEncodeFPS(now: Date = Date()) -> Double? {
        let count = UInt64(streaming.hardwareEncoder.encodedFrameCount)
        defer {
            DeskProbeEncodeSampler.lastCount = count
            DeskProbeEncodeSampler.lastSampleDate = now
        }
        let elapsed = now.timeIntervalSince(DeskProbeEncodeSampler.lastSampleDate)
        guard elapsed >= 0.45, DeskProbeEncodeSampler.lastSampleDate != .distantPast else { return nil }
        guard count >= DeskProbeEncodeSampler.lastCount else { return nil }
        let delta = count - DeskProbeEncodeSampler.lastCount
        guard delta > 0 else { return 0 }
        return Double(delta) / elapsed
    }
}

extension StreamingEngine {
    var outboundNetworkDropCount: Int {
        guard let transport else { return 0 }
        if let fanout = transport as? MultiRTMPTransport {
            return fanout.aggregateNetworkDropCount
        }
        if let direct = transport as? RTMPStreamTransport {
            return direct.networkDropCount
        }
        return 0
    }
}
