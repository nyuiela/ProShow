import CoreGraphics
import Foundation
import Observation

/// Ruler chrome geometry in the `canvasWorkbench` coordinate space.
enum GuideRulerWorkbench {
    static let leftRulerWidth: CGFloat = 24
    static let topRulerHeight: CGFloat = 20
}

/// Ephemeral ruler-guide interaction state (guides persist on `EditorDocument.userGuides`).
@MainActor
@Observable
final class GuideLineEngine {
    var activeDraggingGuideID: UUID?
    var spawnAxis: GuideAxis?
    var spawnPreviewPosition: CGFloat = 0
    /// Document position is committed on drag end; this drives the overlay while dragging.
    var draggingGuideLivePosition: CGFloat?

    var isInteracting: Bool {
        activeDraggingGuideID != nil || spawnAxis != nil
    }

    func clearInteraction() {
        activeDraggingGuideID = nil
        spawnAxis = nil
        spawnPreviewPosition = 0
        draggingGuideLivePosition = nil
    }

    /// Release on the guide's own ruler strip (not the opposite ruler or corner well).
    func droppedOnOriginatingRuler(axis: GuideAxis, workbenchPoint: CGPoint) -> Bool {
        switch axis {
        case .horizontal:
            workbenchPoint.y <= GuideRulerWorkbench.topRulerHeight
                && workbenchPoint.x > GuideRulerWorkbench.leftRulerWidth
        case .vertical:
            workbenchPoint.x <= GuideRulerWorkbench.leftRulerWidth
                && workbenchPoint.y > GuideRulerWorkbench.topRulerHeight
        }
    }

    /// Returns true when the guide should be deleted (off artboard or dropped on ruler chrome).
    func shouldRemoveUserGuide(
        position: CGFloat,
        axis: GuideAxis,
        canvasSize: CGSize,
        droppedInRuler: Bool
    ) -> Bool {
        if droppedInRuler { return true }
        switch axis {
        case .horizontal:
            return position < -8 || position > canvasSize.height + 8
        case .vertical:
            return position < -8 || position > canvasSize.width + 8
        }
    }

    /// When the pointer releases off the artboard, keep the last on-canvas position from the drag.
    func resolvedUserGuidePositionAfterDrag(
        releasePosition: CGFloat,
        storedPosition: CGFloat,
        axis: GuideAxis,
        canvasSize: CGSize,
        droppedInRuler: Bool
    ) -> CGFloat {
        if droppedInRuler { return releasePosition }
        let releaseOffCanvas = shouldRemoveUserGuide(
            position: releasePosition,
            axis: axis,
            canvasSize: canvasSize,
            droppedInRuler: false
        )
        let storedOnCanvas = !shouldRemoveUserGuide(
            position: storedPosition,
            axis: axis,
            canvasSize: canvasSize,
            droppedInRuler: false
        )
        if releaseOffCanvas, storedOnCanvas {
            return storedPosition
        }
        return releasePosition
    }
}
