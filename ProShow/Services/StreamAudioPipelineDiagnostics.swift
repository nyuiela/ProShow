import Foundation
import os

/// Live stream audio pipeline counters (ingest → AAC → RTMP). Rolled up at 1 Hz while broadcasting.
enum StreamAudioPipelineDiagnostics {
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "com.kaleel.proshow", category: "StreamAudio")

    private static var monoPCMDrops: [AudioChannelRole: Int] = [:]
    private static var gateRejects = 0
    private static var encodeFailures = 0
    private static var windowSilenceAUs = 0
    private static var windowRealAUs = 0
    private static var lastLaneDepthLine = ""

    private static var lastPeriodicEmit = CFAbsoluteTimeGetCurrent()
    private static var publishedDesk: (text: String, severity: DeskSignalSeverity, advisory: String?)?

    static func recordMonoPCMDrop(role: AudioChannelRole) {
        lock.lock()
        monoPCMDrops[role, default: 0] += 1
        lock.unlock()
    }

    static func recordGateReject() {
        lock.lock()
        gateRejects += 1
        lock.unlock()
    }

    static func recordEncodeFailure() {
        lock.lock()
        encodeFailures += 1
        lock.unlock()
    }

    static func recordSyntheticSilenceAU() {
        lock.lock()
        windowSilenceAUs += 1
        lock.unlock()
    }

    static func recordRealAU() {
        lock.lock()
        windowRealAUs += 1
        lock.unlock()
    }

    static func updateLaneDepths(_ summary: String) {
        lock.lock()
        lastLaneDepthLine = summary
        lock.unlock()
    }

    static func resetSession() {
        lock.lock()
        monoPCMDrops.removeAll()
        gateRejects = 0
        encodeFailures = 0
        windowSilenceAUs = 0
        windowRealAUs = 0
        lastLaneDepthLine = ""
        lastPeriodicEmit = CFAbsoluteTimeGetCurrent()
        publishedDesk = nil
        lock.unlock()
    }

    /// Call from the program tick while live (~1 Hz).
    static func periodicEmitIfNeeded(isLive: Bool) {
        guard isLive else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let elapsed = now - lastPeriodicEmit
        guard elapsed >= 0.95 else {
            lock.unlock()
            return
        }
        let silence = windowSilenceAUs
        let real = windowRealAUs
        let gates = gateRejects
        let encFail = encodeFailures
        let drops = monoPCMDrops
        let lanes = lastLaneDepthLine
        windowSilenceAUs = 0
        windowRealAUs = 0
        gateRejects = 0
        lastPeriodicEmit = now
        lock.unlock()

        let totalAU = silence + real
        let silencePct = totalAU > 0 ? Int((Double(silence) / Double(totalAU)) * 100) : 0
        let micDrops = drops[.microphone] ?? 0
        let desktopDrops = drops[.desktop] ?? 0
        let snapshot = makeSnapshot(
            silenceAUs: silence,
            realAUs: real,
            gateRejects: gates,
            encodeFailures: encFail,
            micMonoNil: micDrops,
            laneDepths: lanes
        )
        lock.lock()
        publishedDesk = snapshot
        lock.unlock()
        log.info(
            "stream-audio au real=\(real) silence=\(silence) silencePct=\(silencePct) monoNil mic=\(micDrops) desktop=\(desktopDrops) gateReject=\(gates) aacFail=\(encFail) lanes=\(lanes, privacy: .public)"
        )
    }

    /// Desk probe one-liner from the last 1 s rollup while live.
    static func deskProbeSnapshot() -> (text: String, severity: DeskSignalSeverity, advisory: String?)? {
        lock.lock()
        defer { lock.unlock() }
        return publishedDesk
    }

    private static func makeSnapshot(
        silenceAUs: Int,
        realAUs: Int,
        gateRejects: Int,
        encodeFailures: Int,
        micMonoNil: Int,
        laneDepths: String
    ) -> (text: String, severity: DeskSignalSeverity, advisory: String?)? {
        let totalAU = silenceAUs + realAUs
        guard totalAU > 0 || micMonoNil > 0 || gateRejects > 0 || encodeFailures > 0 || !laneDepths.isEmpty else {
            return nil
        }

        var parts: [String] = []
        if totalAU > 0 {
            let pct = Int((Double(silenceAUs) / Double(totalAU)) * 100)
            parts.append("AAC \(100 - pct)% live / \(pct)% silence")
        }
        if !laneDepths.isEmpty {
            parts.append(laneDepths)
        }
        if micMonoNil > 0 {
            parts.append("\(micMonoNil) monoPCM nil")
        }
        if gateRejects > 0 {
            parts.append("\(gateRejects) gate reject")
        }
        if encodeFailures > 0 {
            parts.append("\(encodeFailures) AAC fail")
        }

        let text = parts.joined(separator: " · ")
        if totalAU > 0, Double(silenceAUs) / Double(totalAU) > 0.35 {
            return (text, .critical, "Stream is padding silence AUs — check PCM lanes or ingest")
        }
        if micMonoNil > 8 || encodeFailures > 0 {
            return (text, .caution, "Capture or encode loss on the stream audio path")
        }
        return (text, .ok, nil)
    }
}
