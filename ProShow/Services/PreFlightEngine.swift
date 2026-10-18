import Foundation
#if canImport(Network)
import Network
#endif
#if os(macOS)
import AppKit
#endif

enum PreFlightCheckKind: String, Codable, Sendable, CaseIterable {
    case missingMedia
    case streamHandshake
    case audioClock
    case displayOutput
    case audioRouting
}

enum PreFlightSeverity: String, Codable, Sendable {
    case pass
    case warn
    case fail
}

enum PreFlightIntent: String, Codable, Sendable {
    case inspect
    case goLive
    case startStream
}

struct PreFlightFinding: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var kind: PreFlightCheckKind
    var severity: PreFlightSeverity
    var title: String
    var detail: String
    var relinkHint: String?

    init(
        id: UUID = UUID(),
        kind: PreFlightCheckKind,
        severity: PreFlightSeverity,
        title: String,
        detail: String,
        relinkHint: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.relinkHint = relinkHint
    }
}

struct PreFlightReport: Hashable, Codable, Sendable {
    var scannedAt: Date
    var intent: PreFlightIntent
    var findings: [PreFlightFinding]
    var uniqueAssetCount: Int
    var handshakeCount: Int

    var failCount: Int { findings.filter { $0.severity == .fail }.count }
    var warnCount: Int { findings.filter { $0.severity == .warn }.count }
    var canProceed: Bool { failCount == 0 }
    /// A solo (or similar) silences program audio: show the sheet so the operator confirms.
    var needsAudioConfirm: Bool {
        findings.contains { $0.kind == .audioRouting && $0.severity != .pass }
    }

    var jsonObject: [String: Any] {
        [
            "ok": canProceed,
            "intent": intent.rawValue,
            "fail_count": failCount,
            "warn_count": warnCount,
            "unique_assets": uniqueAssetCount,
            "handshakes": handshakeCount,
            "findings": findings.map { finding in
                [
                    "kind": finding.kind.rawValue,
                    "severity": finding.severity.rawValue,
                    "title": finding.title,
                    "detail": finding.detail,
                    "relink": finding.relinkHint ?? NSNull(),
                ] as [String: Any]
            },
        ]
    }
}

struct StreamHandshakeSample: Hashable, Sendable {
    var reachable: Bool
    var latencyMs: Double
}

protocol StreamHandshakeProbing: Sendable {
    func probe(host: String, port: UInt16, timeoutMs: Int) -> StreamHandshakeSample
}

struct StreamEndpointHint: Hashable, Sendable {
    var host: String
    var port: UInt16

    static func parse(_ raw: String) -> StreamEndpointHint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if !candidate.contains("://") {
            candidate = "rtmp://\(candidate)"
        }
        guard let url = URL(string: candidate), let host = url.host, !host.isEmpty else { return nil }
        let scheme = url.scheme?.lowercased() ?? "rtmp"
        let fallback: UInt16
        switch scheme {
        case "rtmps", "https": fallback = 443
        case "srt": fallback = 9000
        default: fallback = 1935
        }
        let port = url.port.map { UInt16(truncatingIfNeeded: $0) } ?? fallback
        return StreamEndpointHint(host: host, port: port)
    }
}

struct TCPStreamHandshakeProbe: StreamHandshakeProbing {
    func probe(host: String, port: UInt16, timeoutMs: Int) -> StreamHandshakeSample {
        #if canImport(Network)
        let semaphore = DispatchSemaphore(value: 0)
        let started = DispatchTime.now()
        var sample = StreamHandshakeSample(reachable: false, latencyMs: Double(timeoutMs))
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 1935,
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
                sample = StreamHandshakeSample(reachable: true, latencyMs: elapsed)
                connection.cancel()
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        _ = semaphore.wait(timeout: .now() + .milliseconds(max(timeoutMs, 40)))
        connection.cancel()
        return sample
        #else
        return StreamHandshakeSample(reachable: false, latencyMs: Double(timeoutMs))
        #endif
    }
}

struct AudioClockSource: Hashable, Sendable {
    var name: String
    var sampleRateHz: Double
    var kind: String
}

struct AudioClockSnapshot: Hashable, Sendable {
    var sources: [AudioClockSource] = []
}

struct PreFlightTarget: Hashable, Sendable {
    var platform: String
    var accountName: String
    var rtmpUrl: String
    var keychainIdentifier: String
    var keyPresent: Bool
    var mintsIngestOnGoLive: Bool
    var isAuthenticated: Bool

    init(
        platform: String,
        accountName: String,
        rtmpUrl: String,
        keychainIdentifier: String,
        keyPresent: Bool,
        mintsIngestOnGoLive: Bool = false,
        isAuthenticated: Bool = false
    ) {
        self.platform = platform
        self.accountName = accountName
        self.rtmpUrl = rtmpUrl
        self.keychainIdentifier = keychainIdentifier
        self.keyPresent = keyPresent
        self.mintsIngestOnGoLive = mintsIngestOnGoLive
        self.isAuthenticated = isAuthenticated
    }
}

/// One-pass production health scan. Unique media paths are stat'd once; stream keys stay in Keychain.
enum PreFlightEngine {
    static let targetSampleRateHz = 48_000.0
    static let handshakeBudgetMs = 50.0
    static let liveEndpointPrefixes = ["avf://", "sck://", "ndi://", "cmio://"]

    static func scan(
        slides: [Slide],
        projectRoot: URL?,
        targets: [PreFlightTarget],
        streamConfigURL: String,
        audioSettingsRateHz: Double,
        encoderRateHz: Double,
        audioClock: AudioClockSnapshot,
        audienceAssigned: Bool,
        stageAssigned: Bool,
        physicalDisplayCount: Int,
        intent: PreFlightIntent,
        handshake: StreamHandshakeProbing? = nil
    ) -> PreFlightReport {
        var findings: [PreFlightFinding] = []
        let media = auditMedia(
            slides: slides,
            projectRoot: projectRoot,
            intent: intent
        )
        findings.append(contentsOf: media.findings)

        let streams = auditStreams(
            targets: targets,
            streamConfigURL: streamConfigURL,
            intent: intent,
            handshake: handshake
        )
        findings.append(contentsOf: streams.findings)

        findings.append(contentsOf: auditAudioClock(
            settingsRateHz: audioSettingsRateHz,
            encoderRateHz: encoderRateHz,
            snapshot: audioClock
        ))
        findings.append(contentsOf: auditDisplays(
            audienceAssigned: audienceAssigned,
            stageAssigned: stageAssigned,
            physicalDisplayCount: physicalDisplayCount,
            intent: intent
        ))

        if findings.isEmpty {
            findings.append(
                PreFlightFinding(
                    kind: .missingMedia,
                    severity: .pass,
                    title: "Show dependencies",
                    detail: "Media, destinations, clocks, and outputs are ready."
                )
            )
        }

        return PreFlightReport(
            scannedAt: Date(),
            intent: intent,
            findings: findings,
            uniqueAssetCount: media.uniqueCount,
            handshakeCount: streams.handshakeCount
        )
    }

    static func collectMediaRefs(slides: [Slide]) -> [String: String] {
        var refs: [String: String] = [:]
        for slide in slides {
            if let path = slide.mediaAction?.filePath, !path.isEmpty {
                refs[path] = slide.title.isEmpty ? "Slide media" : slide.title
            }
            for object in slide.canvas {
                let uri = object.fill.imageURI
                if !uri.isEmpty {
                    refs[uri] = object.name.isEmpty ? "Canvas fill" : object.name
                }
            }
        }
        return refs
    }

    static func isLiveEndpoint(_ path: String) -> Bool {
        let lower = path.lowercased()
        return liveEndpointPrefixes.contains { lower.hasPrefix($0) }
    }

    /// File paths only. Live inputs, placeholders, and media-bin IDs are not relink targets.
    static func isFileBackedMedia(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isLiveEndpoint(trimmed) { return false }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(), !scheme.isEmpty {
            return scheme == "file"
        }
        if UUID(uuidString: trimmed) != nil { return false }
        return true
    }

    private static func auditMedia(
        slides: [Slide],
        projectRoot: URL?,
        intent: PreFlightIntent
    ) -> (findings: [PreFlightFinding], uniqueCount: Int) {
        let refs = collectMediaRefs(slides: slides)
        var findings: [PreFlightFinding] = []
        var seen = Set<String>()
        let severity: PreFlightSeverity = intent == .inspect ? .warn : .fail
        for (path, label) in refs {
            guard seen.insert(path).inserted else { continue }
            guard isFileBackedMedia(path) else { continue }
            if MediaPath.resolve(path, projectRoot: projectRoot) != nil { continue }
            findings.append(
                PreFlightFinding(
                    kind: .missingMedia,
                    severity: severity,
                    title: "Missing media",
                    detail: "\(label) points at a file that is missing or moved.",
                    relinkHint: path
                )
            )
        }
        if findings.isEmpty {
            findings.append(
                PreFlightFinding(
                    kind: .missingMedia,
                    severity: .pass,
                    title: "Media assets",
                    detail: refs.isEmpty
                        ? "No file-backed media in the active deck."
                        : "\(refs.count) unique file path\(refs.count == 1 ? "" : "s") resolved."
                )
            )
        }
        return (findings, refs.count)
    }

    private static func auditStreams(
        targets: [PreFlightTarget],
        streamConfigURL: String,
        intent: PreFlightIntent,
        handshake: StreamHandshakeProbing?
    ) -> (findings: [PreFlightFinding], handshakeCount: Int) {
        var findings: [PreFlightFinding] = []
        var handshakeCount = 0
        let armed = targets.isEmpty && !streamConfigURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [PreFlightTarget(
                platform: "Custom RTMP",
                accountName: "Direct",
                rtmpUrl: streamConfigURL,
                keychainIdentifier: "",
                keyPresent: true
            )]
            : targets

        if armed.isEmpty {
            let severity: PreFlightSeverity = intent == .startStream ? .fail : .pass
            findings.append(
                PreFlightFinding(
                    kind: .streamHandshake,
                    severity: severity,
                    title: "Stream destinations",
                    detail: intent == .startStream
                        ? "No YouTube, Facebook, X, or RTMP target is armed."
                        : "No stream destination is armed. Capture can stay idle."
                )
            )
            return (findings, 0)
        }

        for target in armed {
            if target.mintsIngestOnGoLive {
                if !target.isAuthenticated {
                    findings.append(
                        PreFlightFinding(
                            kind: .streamHandshake,
                            severity: intent == .inspect ? .warn : .fail,
                            title: "Destination not signed in",
                            detail: "\(target.platform) · \(target.accountName) needs a reconnect before going live."
                        )
                    )
                    continue
                }
                findings.append(
                    PreFlightFinding(
                        kind: .streamHandshake,
                        severity: .pass,
                        title: "Stream key on go-live",
                        detail: "\(target.platform) · \(target.accountName) issues the ingest key when you start broadcasting."
                    )
                )
                continue
            }
            if !target.keychainIdentifier.isEmpty, target.keyPresent == false {
                findings.append(
                    PreFlightFinding(
                        kind: .streamHandshake,
                        severity: .fail,
                        title: "Stream key missing",
                        detail: "\(target.platform) · \(target.accountName) has no Keychain stream key."
                    )
                )
                continue
            }
            guard let endpoint = StreamEndpointHint.parse(target.rtmpUrl) else {
                findings.append(
                    PreFlightFinding(
                        kind: .streamHandshake,
                        severity: .fail,
                        title: "Stream URL invalid",
                        detail: "\(target.accountName) has no parseable RTMP host."
                    )
                )
                continue
            }
            guard let handshake else {
                findings.append(
                    PreFlightFinding(
                        kind: .streamHandshake,
                        severity: .pass,
                        title: "Stream key present",
                        detail: "\(target.platform) · \(target.accountName) key is in Keychain. Handshake deferred."
                    )
                )
                continue
            }
            handshakeCount += 1
            let sample = handshake.probe(host: endpoint.host, port: endpoint.port, timeoutMs: Int(handshakeBudgetMs * 4))
            if !sample.reachable {
                findings.append(
                    PreFlightFinding(
                        kind: .streamHandshake,
                        severity: intent == .startStream ? .fail : .warn,
                        title: "Stream host unreachable",
                        detail: "\(target.platform) · \(endpoint.host):\(endpoint.port) did not complete a TCP handshake."
                    )
                )
            } else if sample.latencyMs > handshakeBudgetMs {
                findings.append(
                    PreFlightFinding(
                        kind: .streamHandshake,
                        severity: .warn,
                        title: "Stream latency high",
                        detail: String(
                            format: "%@ handshake %.0f ms (budget %.0f ms).",
                            target.platform,
                            sample.latencyMs,
                            handshakeBudgetMs
                        )
                    )
                )
            } else {
                findings.append(
                    PreFlightFinding(
                        kind: .streamHandshake,
                        severity: .pass,
                        title: "Stream handshake",
                        detail: String(
                            format: "%@ · %@ reached in %.0f ms.",
                            target.platform,
                            endpoint.host,
                            sample.latencyMs
                        )
                    )
                )
            }
        }
        return (findings, handshakeCount)
    }

    private static func auditAudioClock(
        settingsRateHz: Double,
        encoderRateHz: Double,
        snapshot: AudioClockSnapshot
    ) -> [PreFlightFinding] {
        var rates: [(String, Double)] = [
            ("Device settings", settingsRateHz),
            ("Program encoder", encoderRateHz),
        ]
        rates.append(contentsOf: snapshot.sources.map { ($0.name, $0.sampleRateHz) })
        var findings: [PreFlightFinding] = []
        for (name, rate) in rates where rate > 0 {
            if abs(rate - targetSampleRateHz) > 0.5 {
                findings.append(
                    PreFlightFinding(
                        kind: .audioClock,
                        severity: .fail,
                        title: "Sample rate mismatch",
                        detail: String(format: "%@ is %.1f kHz; program clock is 48.0 kHz.", name, rate / 1000)
                    )
                )
            }
        }
        if findings.isEmpty {
            findings.append(
                PreFlightFinding(
                    kind: .audioClock,
                    severity: .pass,
                    title: "Audio clock",
                    detail: "Active inputs and the program encoder are aligned at 48.0 kHz."
                )
            )
        }
        return findings
    }

    private static func auditDisplays(
        audienceAssigned: Bool,
        stageAssigned: Bool,
        physicalDisplayCount: Int,
        intent: PreFlightIntent
    ) -> [PreFlightFinding] {
        var findings: [PreFlightFinding] = []
        if physicalDisplayCount == 0 {
            findings.append(
                PreFlightFinding(
                    kind: .displayOutput,
                    severity: .fail,
                    title: "No displays",
                    detail: "The system reports no connected monitors."
                )
            )
            return findings
        }
        if !audienceAssigned {
            findings.append(
                PreFlightFinding(
                    kind: .displayOutput,
                    severity: .fail,
                    title: "Audience output unassigned",
                    detail: "Audience program has no monitor or NDI target."
                )
            )
        }
        if !stageAssigned {
            findings.append(
                PreFlightFinding(
                    kind: .displayOutput,
                    severity: intent == .startStream ? .warn : .warn,
                    title: "Stage output unassigned",
                    detail: "Stage confidence has no second display or NDI stage target."
                )
            )
        }
        if findings.isEmpty {
            findings.append(
                PreFlightFinding(
                    kind: .displayOutput,
                    severity: .pass,
                    title: "Display outputs",
                    detail: "Audience and Stage have assigned destinations (\(physicalDisplayCount) monitor\(physicalDisplayCount == 1 ? "" : "s"))."
                )
            )
        }
        return findings
    }
}

extension PreFlightEngine {
    @MainActor
    static func scan(
        controller: ShowController,
        intent: PreFlightIntent,
        handshake: StreamHandshakeProbing? = nil,
        physicalDisplayCount: Int? = nil
    ) -> PreFlightReport {
        let slides = intent == .inspect
            ? controller.show.allSlides
            : programSlides(from: controller)
        let accounts = controller.deviceSettings.document.accounts.filter {
            controller.streamMatrix.isActive($0.id)
        }
        let targets = accounts.map { account in
            PreFlightTarget(
                platform: account.platform.title,
                accountName: account.accountName,
                rtmpUrl: account.rtmpUrl,
                keychainIdentifier: account.keychainStreamKeyIdentifier,
                keyPresent: KeychainStreamVault.load(identifier: account.keychainStreamKeyIdentifier)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                mintsIngestOnGoLive: account.supportsOAuth,
                isAuthenticated: account.isAuthenticated
            )
        }
        let settings = controller.deviceSettings.document
        let screens = settings.screens
        let audienceAssigned = audienceIsAssigned(
            screens: screens,
            outputScreens: controller.compositor.stack.outputScreens,
            audienceOn: controller.isAudienceOutputOn
        )
        let stageAssigned = stageIsAssigned(
            screens: screens,
            outputScreens: controller.compositor.stack.outputScreens,
            stageOn: controller.isStageOutputOn,
            ndiStage: settings.ndiOutputName.isEmpty == false && controller.stageDisplayLayout.ndiOutputEnabled
        )
        var report = scan(
            slides: slides,
            projectRoot: controller.mediaProjectRoot,
            targets: targets,
            streamConfigURL: controller.streaming.config.destinationURL,
            audioSettingsRateHz: Double(settings.audioSampleRate),
            encoderRateHz: Double(controller.streaming.config.sampleRateHz),
            audioClock: controller.audioClockSnapshot,
            audienceAssigned: audienceAssigned,
            stageAssigned: stageAssigned,
            physicalDisplayCount: physicalDisplayCount ?? connectedDisplayCount(),
            intent: intent,
            handshake: handshake
        )
        if let solo = auditAudioSolo(soloed: controller.audioMatrix.channels.filter(\.solo).map(\.name)) {
            // Replace the lone "all good" pass row so the warning is the first thing read.
            if report.findings.count == 1, report.findings[0].severity == .pass {
                report.findings.removeAll()
            }
            report.findings.insert(solo, at: 0)
        }
        return report
    }

    /// Channel solo silences every other channel on the stream, not just in headphones.
    static func auditAudioSolo(soloed: [String]) -> PreFlightFinding? {
        guard !soloed.isEmpty else { return nil }
        let names = soloed.joined(separator: ", ")
        return PreFlightFinding(
            kind: .audioRouting,
            severity: .warn,
            title: "Audio solo is on",
            detail: "Solo on \(names). Slides, guests and other sources will be silent on the stream. Clear solo in On-Air Audio or the Audio tab."
        )
    }

    static func connectedDisplayCount() -> Int {
        #if os(macOS)
        NSScreen.screens.count
        #else
        1
        #endif
    }

    static func audienceIsAssigned(
        screens: [OutputScreenConfig],
        outputScreens: [OutputScreen],
        audienceOn: Bool
    ) -> Bool {
        if screens.contains(where: {
            $0.isEnabled && $0.targetType == .audienceProgram && $0.displayIndex >= 0
        }) {
            return true
        }
        return audienceOn && outputScreens.contains(where: { $0.role == .audience })
    }

    static func stageIsAssigned(
        screens: [OutputScreenConfig],
        outputScreens: [OutputScreen],
        stageOn: Bool,
        ndiStage: Bool
    ) -> Bool {
        if ndiStage { return true }
        if screens.contains(where: {
            $0.isEnabled && ($0.targetType == .stageConfidence || $0.targetType == .ndiOutput)
        }) {
            return true
        }
        return stageOn && outputScreens.contains(where: { $0.role == .stage })
    }

    @MainActor
    static func programSlides(from controller: ShowController) -> [Slide] {
        var seen = Set<SlideID>()
        var slides: [Slide] = []
        func add(_ slide: Slide?) {
            guard let slide, seen.insert(slide.id).inserted else { return }
            slides.append(slide)
        }
        add(controller.liveSlide)
        add(controller.selectedSlide)
        add(controller.nextSlide)
        if slides.isEmpty {
            add(controller.show.allSlides.first)
        }
        return slides
    }
}
