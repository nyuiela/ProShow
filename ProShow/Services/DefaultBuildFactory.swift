import Foundation

/// Default Build In steps so new canvas elements animate on slide enter
/// while remaining fully visible in editor design and thumbnail rest modes.
struct DefaultBuildFactory {
    static func createDefaultBuildSteps(for elementId: UUID, elementType: ElementType) -> [ElementBuildStep] {
        switch elementType {
        case .text:
            return [
                ElementBuildStep(
                    elementId: elementId,
                    phase: .buildIn,
                    effect: .fade,
                    trigger: .onSlideEnter,
                    sequenceOrder: 1,
                    delaySeconds: 0,
                    durationSeconds: 0.3,
                    easing: .easeOut
                )
            ]
        case .shape:
            return [
                ElementBuildStep(
                    elementId: elementId,
                    phase: .buildIn,
                    effect: .fade,
                    trigger: .onSlideEnter,
                    sequenceOrder: 1,
                    delaySeconds: 0,
                    durationSeconds: 0.2,
                    easing: .linear
                )
            ]
        case .media, .placeholder:
            return [
                ElementBuildStep(
                    elementId: elementId,
                    phase: .buildIn,
                    effect: .fade,
                    trigger: .onSlideEnter,
                    sequenceOrder: 1,
                    delaySeconds: 0,
                    durationSeconds: 0.4,
                    easing: .easeInOut
                )
            ]
        }
    }

    static func createDefaultBuildSteps(for elementId: UUID, kind: CanvasObjectKind) -> [ElementBuildStep] {
        createDefaultBuildSteps(for: elementId, elementType: ElementType(kind: kind))
    }
}
