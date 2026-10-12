import Foundation

/// Bridges rundown clock stage cues to confidence monitors and alert banners.
@MainActor
enum StageCueController {
    static func applyStageMessage(_ message: String, flash: Bool, controller: ShowController) {
        controller.stageAlertBanner = message
        controller.stageDisplayLayout.showAlertBanner = true
        if flash {
            controller.stageDisplayLayout.showCountdown = true
        }
    }

    static func clearStageMessage(controller: ShowController) {
        controller.stageAlertBanner = ""
    }

    static func syncStageRundownOverlay(controller: ShowController) {
        let clock = controller.rundownClock
        guard clock.isShowRunning, let block = clock.activeBlock else {
            controller.rundownStageSegmentTitle = nil
            controller.rundownStageCountdownText = nil
            controller.rundownStageNextCue = nil
            return
        }
        controller.rundownStageSegmentTitle = block.title
        let remaining = max(0, clock.activeBlockRemainingSeconds)
        controller.rundownStageCountdownText = ProgramTimecode.format(remaining)
        controller.rundownStageNextCue = clock.upcomingTalentCueText
        if let message = clock.currentStageMessage, !message.isEmpty {
            controller.stageAlertBanner = message
        }
    }
}
