import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

public struct AlphaStingerCue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var mediaRelativePath: String
    public var totalDurationMs: Int
    public var cutPointMs: Int
    public var audioTrackPath: String?
    public var audioVolume: Double

    public init(
        id: UUID = UUID(),
        name: String,
        mediaRelativePath: String,
        totalDurationMs: Int,
        cutPointMs: Int,
        audioTrackPath: String? = nil,
        audioVolume: Double = 1
    ) {
        self.id = id
        self.name = name
        self.mediaRelativePath = mediaRelativePath
        self.totalDurationMs = totalDurationMs
        self.cutPointMs = cutPointMs
        self.audioTrackPath = audioTrackPath
        self.audioVolume = audioVolume
    }

    public static let flameWipe = AlphaStingerCue(
        name: "Flame Stinger Wipe",
        mediaRelativePath: "Assets/Stingers/flame_wipe.mov",
        totalDurationMs: 1000,
        cutPointMs: 500
    )
}

/// Frame-exact alpha stinger: overlay stays on layer 6 while the cut swaps A → B underneath.
@MainActor
@Observable
final class StingerPlayer {
    var cue: AlphaStingerCue?
    var playbackMs: Int = 0
    var outgoingSceneID: UUID?
    var incomingSceneID: UUID?
    var activeLowerSceneID: UUID?
    var overlayLayerIndex: Int = 6
    var isPlaying: Bool = false
    var didCut: Bool = false
    var lastPixelBufferTimeMs: Int?

    #if canImport(AVFoundation)
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    #endif

    var overlayVisible: Bool {
        guard isPlaying, let cue else { return false }
        return playbackMs >= 0 && playbackMs <= cue.totalDurationMs
    }

    var hasReachedCutPoint: Bool {
        guard let cue else { return false }
        return playbackMs >= cue.cutPointMs
    }

    func start(cue: AlphaStingerCue, from outgoing: UUID?, to incoming: UUID, mediaURL: URL? = nil) {
        self.cue = cue
        outgoingSceneID = outgoing
        incomingSceneID = incoming
        activeLowerSceneID = outgoing
        playbackMs = 0
        didCut = false
        isPlaying = true
        overlayLayerIndex = 6
        attachPlayer(url: mediaURL)
        evaluateCut()
    }

    func advance(toMs milliseconds: Int) {
        playbackMs = max(0, milliseconds)
        evaluateCut()
        if let cue, playbackMs >= cue.totalDurationMs {
            isPlaying = false
        }
    }

    func tick(deltaMs: Int) {
        advance(toMs: playbackMs + max(0, deltaMs))
    }

    func evaluateCut() {
        guard isPlaying, hasReachedCutPoint, !didCut else { return }
        didCut = true
        activeLowerSceneID = incomingSceneID
    }

    func stop() {
        isPlaying = false
        didCut = false
        overlayLayerIndex = 6
        #if canImport(AVFoundation)
        if let videoOutput, let item = player?.currentItem {
            item.remove(videoOutput)
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        videoOutput = nil
        #endif
    }

    #if canImport(AVFoundation)
    private func attachPlayer(url: URL?) {
        guard let url, MediaLoader.hasVideoTrack(at: url) else { return }
        let item = AVPlayerItem(url: url)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: settings)
        item.add(output)
        videoOutput = output
        player = AVPlayer(playerItem: item)
        player?.volume = Float(cue?.audioVolume ?? 1)
        player?.play()
    }

    func currentPixelBuffer(hostTime: TimeInterval) -> CVPixelBuffer? {
        guard let videoOutput else { return nil }
        let time = videoOutput.itemTime(forHostTime: hostTime)
        guard videoOutput.hasNewPixelBuffer(forItemTime: time) else { return nil }
        lastPixelBufferTimeMs = Int(CMTimeGetSeconds(time) * 1000)
        return videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }
    #else
    private func attachPlayer(url: URL?) {}
    #endif
}
