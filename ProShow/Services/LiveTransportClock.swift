import Foundation
import CoreMedia
import Observation

/// Active program-media session shared by audience, stage, and the canvas editor.
struct LiveMediaSession: Equatable, Sendable {
    var slideID: UUID?
    var mediaID: UUID?
    var filePath: String?
    var playhead: TimeInterval
    var rate: Double
    var isPlaying: Bool
    var frameIndex: Int
    var liveBuildStartedAt: Date?
}

/// In-place Layer 4 (slide) mutation. Layer 3 media is never named here.
struct LiveSceneDelta: Equatable, Sendable {
    var slideID: UUID
    var canvas: [CanvasObject]
    var slideText: [SlideElement]
    var backgroundEnabled: Bool
    var backgroundHex: String
    var canvasWidth: Double
    var canvasHeight: Double
}

/// Master transport clock for live outputs and editor attach.
@MainActor
@Observable
final class LiveTransportClock {
    private(set) weak var playback: MediaPlaybackEngine?
    var liveBuildStartedAt: Date?
    @ObservationIgnored var programFrame: Int = 0
    var boundSlideID: UUID?

    var elapsedSeconds: TimeInterval {
        guard let started = liveBuildStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(started))
    }

    var activeMediaSession: LiveMediaSession? {
        guard let playback else { return nil }
        guard playback.hasProgramClock || boundSlideID != nil else { return nil }
        return LiveMediaSession(
            slideID: boundSlideID,
            mediaID: playback.mediaID,
            filePath: playback.boundFilePath ?? playback.fileURL?.path,
            playhead: playback.playhead,
            rate: playback.isPlaying ? 1 : 0,
            isPlaying: playback.isPlaying,
            frameIndex: programFrame,
            liveBuildStartedAt: liveBuildStartedAt
        )
    }

    func attach(playback: MediaPlaybackEngine) {
        self.playback = playback
    }

    func bind(slideID: UUID?, liveBuildStartedAt: Date?, programFrame: Int) {
        boundSlideID = slideID
        self.liveBuildStartedAt = liveBuildStartedAt
        self.programFrame = programFrame
    }

    func currentPlayheadSeconds() -> TimeInterval {
        playback?.playhead ?? 0
    }

    func getCurrentTimecode(for layerIndex: Int) -> CMTime {
        switch RenderLayer(rawValue: layerIndex) {
        case .media:
            return mediaTimecode()
        case .slide:
            return CMTime(seconds: elapsedSeconds, preferredTimescale: 600)
        default:
            return .zero
        }
    }

    private func mediaTimecode() -> CMTime {
        playback?.currentTimecode ?? .zero
    }
}
