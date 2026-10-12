import Foundation
import Observation

/// Scene switching, hotkeys, and instant serialization into the compositor stack.
@MainActor
@Observable
final class SceneManager {
    var scenes: [ProShowScene] = []
    var activeSceneID: UUID?
    var lastTransitionMS: Double = 0

    var activeScene: ProShowScene? {
        scenes.first(where: { $0.id == activeSceneID })
    }

    func install(_ scenes: [ProShowScene], activeID: UUID? = nil) {
        self.scenes = scenes
        if let activeID, scenes.contains(where: { $0.id == activeID }) {
            activeSceneID = activeID
        } else {
            activeSceneID = scenes.first?.id
        }
    }

    @discardableResult
    func switchTo(_ id: UUID) -> ProShowScene? {
        guard let scene = scenes.first(where: { $0.id == id }) else { return nil }
        let started = Date()
        activeSceneID = scene.id
        lastTransitionMS = Date().timeIntervalSince(started) * 1000
        return scene
    }

    @discardableResult
    func switchToIndex(_ index: Int) -> ProShowScene? {
        guard scenes.indices.contains(index) else { return nil }
        return switchTo(scenes[index].id)
    }

    @discardableResult
    func triggerHotkey(_ digit: String) -> ProShowScene? {
        if let scene = scenes.first(where: { $0.hotKey == digit }) {
            return switchTo(scene.id)
        }
        if let index = Int(digit), index >= 1 {
            return switchToIndex(index - 1)
        }
        return nil
    }

    func apply(
        _ scene: ProShowScene,
        compositor: CompositorEngine,
        video: VideoInputEngine,
        audio: AudioMatrixEngine
    ) {
        let primary = scene.primarySourceID.flatMap(video.source(id:))
        let pip = scene.pipSourceID.flatMap(video.source(id:))
        if let primary, Self.shouldEngage(primary, on: video) {
            video.activatePrimary(primary.id)
        }
        if let pip {
            if Self.shouldEngage(pip, on: video) {
                video.activatePIP(pip.id)
            }
        } else {
            video.clearPIP()
        }
        compositor.applySceneLayout(
            primary: primary?.inputSource,
            pip: pip?.inputSource,
            primaryBounds: scene.primaryBounds,
            pipBounds: scene.pipBounds
        )
        compositor.syncVideoInputs(from: video)
        audio.applyMix(scene.mix)
        audio.duckingEnabled = scene.duckDesktopAudio
        _ = switchTo(scene.id)
    }

    func snapshot() -> [ProShowScene] { scenes }

    /// Once live I/O is on, only bind sources the operator actually assigned.
    /// Seed "Presenter Camera" has no endpoint — activating it opens the default
    /// camera and tears down CMIO while other lanes are running.
    private static func shouldEngage(_ source: StudioVideoSource, on video: VideoInputEngine) -> Bool {
        !video.hardwareEnabled || source.hasBindableHardwareEndpoint || video.isRunning(source)
    }
}
