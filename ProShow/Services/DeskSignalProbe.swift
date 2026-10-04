import Foundation
import SwiftUI

enum DeskSignalSeverity: Equatable {
    case hidden
    case ok
    case caution
    case critical

    var color: Color {
        switch self {
        case .hidden: ProShowTheme.secondaryLabel
        case .ok: ThemeTokens.previewGreen
        case .caution: ThemeTokens.warningAmber
        case .critical: ThemeTokens.programRed
        }
    }
}

struct DeskSignalProbeSnapshot: Equatable {
    var severity: DeskSignalSeverity = .hidden
    var headline: String = ""
    var metrics: String = ""
    var advisory: String?

    static let hidden = DeskSignalProbeSnapshot()

    var isVisible: Bool {
        severity != .hidden && !headline.isEmpty
    }
}

enum DeskSignalProbeBuilder {
    @MainActor
    static func make(controller: ShowController, now: Date = Date()) -> DeskSignalProbeSnapshot {
        guard shouldShow(for: controller) else { return .hidden }

        if !controller.playback.isPlaying {
            controller.playback.refreshPlaybackProbe()
        }
        var severity: DeskSignalSeverity = .ok
        var advisories: [String] = []
        var metricParts: [String] = []

        let headline = headline(for: controller, now: now)

        if controller.streaming.isLive || controller.streaming.state == .starting {
            appendStreamMetrics(controller: controller, now: now, into: &metricParts, severity: &severity, advisories: &advisories)
        }

        if controller.isoRecorder.isRecording {
            metricParts.append("ISO recording")
        }

        if let program = programMetrics(controller: controller, now: now) {
            metricParts.append(program)
        }

        if controller.playback.canPresentVideo,
           controller.playback.isPlaying || controller.playback.playbackStats != nil {
            appendPlaybackMetrics(controller: controller, into: &metricParts, severity: &severity, advisories: &advisories)
        } else if controller.playback.canPresentVideo, controller.playback.fileURL != nil {
            metricParts.append("Media loaded · paused")
        }

        if let audio = audioMetrics() {
            metricParts.append(audio.text)
            severity = max(severity, audio.severity)
            if let note = audio.advisory { advisories.append(note) }
        }

        if let transport = rtmpDropMetrics(controller: controller) {
            metricParts.append(transport.text)
            severity = max(severity, transport.severity)
            if let note = transport.advisory { advisories.append(note) }
        }

        if let error = controller.streaming.lastError, !error.isEmpty,
           controller.streaming.isLive || controller.streaming.state == .starting {
            advisories.append(error)
            severity = .critical
        }

        let metrics = metricParts.filter { !$0.isEmpty }.joined(separator: " · ")
        let advisory = advisories.isEmpty ? nil : advisories.joined(separator: " · ")

        if metrics.isEmpty, advisory == nil {
            return DeskSignalProbeSnapshot(severity: .ok, headline: headline, metrics: "Monitoring program output")
        }

        return DeskSignalProbeSnapshot(
            severity: severity,
            headline: headline,
            metrics: metrics,
            advisory: advisory
        )
    }

    @MainActor
    private static func shouldShow(for controller: ShowController) -> Bool {
        if controller.streaming.isLive || controller.streaming.state == .starting { return true }
        if controller.isoRecorder.isRecording { return true }
        if controller.usesCanonicalProgramMonitor || controller.wantsEncodedPreview { return true }
        if controller.isBroadcasting { return true }
        if controller.playback.canPresentVideo,
           controller.playback.isPlaying || controller.playback.fileURL != nil {
            return true
        }
        return false
    }

    @MainActor
    private static func headline(for controller: ShowController, now: Date) -> String {
        if controller.streaming.state == .starting { return "STREAM · CONNECTING" }
        if controller.streaming.isLive {
            if let started = controller.streaming.startedAt {
                let minutes = Int(now.timeIntervalSince(started) / 60)
                return minutes > 0 ? "ON AIR · \(minutes)m" : "ON AIR"
            }
            return "ON AIR"
        }
        if controller.isoRecorder.isRecording, controller.streaming.isLive {
            return "ON AIR · REC"
        }
        if controller.isoRecorder.isRecording { return "RECORDING" }
        if controller.playback.isPlaying, controller.playback.canPresentVideo {
            let title = controller.playback.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title == MediaTransportState.idle.title {
                return "PLAYING"
            }
            return "PLAYING · \(title)"
        }
        if controller.usesCanonicalProgramMonitor { return "preview" }
        return controller.deskProgramOutputStatusTitle
    }

    @MainActor
    private static func appendStreamMetrics(
        controller: ShowController,
        now: Date,
        into parts: inout [String],
        severity: inout DeskSignalSeverity,
        advisories: inout [String]
    ) {
        let telemetry = controller.streaming.telemetry
        let preset = controller.streaming.streamEncoderConfig
        parts.append("\(telemetry.measuredVideoBitrateKbps.formatted()) / \(preset.targetBitrateKbps) Kbps")
        parts.append(telemetry.stabilityLabel)
        if telemetry.droppedFrameCount > 0 {
            parts.append("\(telemetry.droppedFrameCount) enc drops")
            severity = max(severity, telemetry.droppedFrameCount > 12 ? .critical : .caution)
        }
        if let encFps = controller.deskProbeEncodeFPS(now: now) {
            parts.append(String(format: "%.0f enc fps", encFps))
            let target = Double(controller.projectSettings.frameRate.encoderFPS)
            if target > 0, encFps < target * 0.62 {
                severity = max(severity, encFps < target * 0.4 ? .critical : .caution)
                advisories.append("Encode cadence below program frame rate — output may stutter")
            }
        }
        let enc = controller.streaming.hardwareEncoder.encodedFrameCount
        if enc > 0 {
            parts.append("\(enc) enc frames")
        }
        if controller.streaming.hardwareEncoder.encodeFailureCount > 0 {
            parts.append("\(controller.streaming.hardwareEncoder.encodeFailureCount) enc errors")
            severity = .critical
            advisories.append("Hardware encoder reported failures — check CPU/GPU load")
        }
        if telemetry.measuredVideoBitrateKbps > 0,
           Double(telemetry.measuredVideoBitrateKbps) < Double(preset.targetBitrateKbps) * 0.55 {
            severity = max(severity, .caution)
            advisories.append("Outbound bitrate is well below target — network or encoder may be constrained")
        }
    }

    @MainActor
    private static func programMetrics(controller: ShowController, now: Date) -> String? {
        guard controller.streaming.isLive || controller.usesCanonicalProgramMonitor || controller.wantsEncodedPreview else {
            return nil
        }
        if controller.streaming.isLive || controller.streaming.state == .starting {
            return nil
        }
        let settings = controller.projectSettings.resolution
        var chunks = [
            "\(settings.width)×\(settings.height)",
            String(format: "%d fps target", controller.projectSettings.frameRate.encoderFPS),
        ]
        if controller.usesCanonicalProgramMonitor {
            if case .preview(.operatorDesk) = controller.evaluateOutputMode() {
                let contract = controller.currentProgramRenderContract()
                chunks.append("preview \(contract.width)×\(contract.height)")
            } else {
                chunks.append("canonical encode")
            }
        }
        if let fps = controller.deskProbeEncodeFPS(now: now) {
            let rounded = (fps / 5).rounded() * 5
            chunks.append(String(format: "%.0f enc fps", max(0, rounded)))
        }
        return chunks.joined(separator: " · ")
    }

    @MainActor
    private static func appendPlaybackMetrics(
        controller: ShowController,
        into parts: inout [String],
        severity: inout DeskSignalSeverity,
        advisories: inout [String]
    ) {
        guard let stats = controller.playback.playbackStats else {
            if !controller.playback.playbackProbe.isEmpty {
                parts.append(controller.playback.playbackProbe)
            }
            return
        }
        parts.append(stats.deskProbeDisplayLine)
        if stats.isWaiting {
            severity = max(severity, .caution)
            advisories.append("Decoder buffering — playback may stutter")
        }
        if stats.rate > 0.05, abs(stats.rate - 1) > 0.045 {
            severity = max(severity, .caution)
            advisories.append("Playback rate drift — check CPU or source file")
        }
        let transportPaused = stats.control.lowercased().contains("paused")
        if !transportPaused, let age = stats.lastFrameAge {
            if age > 0.35 {
                severity = max(severity, .critical)
                advisories.append("Video frames stalled — check GPU / disk throughput")
            } else if age > 0.12 {
                severity = max(severity, .caution)
            }
        }
        let maxFrameGap = max(0.2, 2.5 / Double(max(stats.sourceFPS, 1)))
        let deliveryHealthy = transportPaused || (stats.lastFrameAge ?? 999) <= maxFrameGap
        if !transportPaused, stats.copied >= 30, stats.missed >= 3, !deliveryHealthy {
            let missRate = Double(stats.missed) / Double(max(1, stats.copied))
            if missRate > 0.35 {
                severity = max(severity, .critical)
                advisories.append("Decoder struggling to keep up — check disk or lower preview load")
            } else if missRate > 0.15 {
                severity = max(severity, .caution)
            }
        }
    }

    private static func audioMetrics() -> (text: String, severity: DeskSignalSeverity, advisory: String?)? {
        let queued = ProgramAudioBus.queuedAccessUnitCount()
        let pressure = ProgramAACEncoder.captureLanePressureRatio()
        guard queued > 0 || pressure > 0.05 else { return nil }
        let queueBucket = (queued / 4) * 4
        let pressureBucket = Int((pressure * 10).rounded()) * 10
        var text = "AAC queue \(queueBucket)"
        if pressure > 0.01 {
            text += " · PCM \(min(100, pressureBucket))% full"
        }
        if pressure > 0.88 || queued > 36 {
            return (text, .critical, "Stream audio backlog — risk of dropouts or drift")
        }
        if pressure > 0.65 || queued > 24 {
            return (text, .caution, "Stream audio queue filling")
        }
        return (text, .ok, nil)
    }

    @MainActor
    private static func rtmpDropMetrics(controller: ShowController) -> (text: String, severity: DeskSignalSeverity, advisory: String?)? {
        guard controller.streaming.isLive || controller.streaming.state == .starting else { return nil }
        let drops = controller.streaming.outboundNetworkDropCount
        guard drops > 0 else { return nil }
        let text = "\(drops) network drops"
        if drops > 40 {
            return (text, .critical, "RTMP socket backlog — ingest may be stuttering")
        }
        return (text, .caution, "Network send queue dropped packets")
    }
}

private func max(_ lhs: DeskSignalSeverity, _ rhs: DeskSignalSeverity) -> DeskSignalSeverity {
    switch (lhs, rhs) {
    case (.critical, _), (_, .critical): return .critical
    case (.caution, _), (_, .caution): return .caution
    case (.ok, _), (_, .ok): return .ok
    default: return rhs == .hidden ? lhs : rhs
    }
}
