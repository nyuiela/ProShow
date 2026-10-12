import SwiftUI

/// Operator-facing clears that unload program content or remove on-air elements.
enum DeskDestructiveConfirmAction: Equatable, Identifiable, Sendable {
    case clearLyrics
    case clearLowerThirds
    case clearAllOnAir
    case removeSelectedCompositionElements(count: Int)
    case removeOnAirElement(displayName: String, id: UUID)
    case emptyProgramLayer(RenderLayer)
    case hideAllProgramLayers
    case hideClearStripLayer(ClearStripAction)
    case clearLiveShot(layerName: String, layerIndex: Int)
    case emergencyClearAll

    var id: String {
        switch self {
        case .clearLyrics: "clearLyrics"
        case .clearLowerThirds: "clearLowerThirds"
        case .clearAllOnAir: "clearAllOnAir"
        case .removeSelectedCompositionElements(let count): "removeSelected-\(count)"
        case .removeOnAirElement(_, let id): "removeElement-\(id.uuidString)"
        case .emptyProgramLayer(let layer): "emptyLayer-\(layer.rawValue)"
        case .hideAllProgramLayers: "hideAll"
        case .hideClearStripLayer(let action): "stripHide-\(action.rawValue)"
        case .clearLiveShot(_, let index): "clearLive-\(index)"
        case .emergencyClearAll: "emergencyClearAll"
        }
    }

    var title: String {
        switch self {
        case .clearLyrics: "Clear Lyrics?"
        case .clearLowerThirds: "Clear Thirds?"
        case .clearAllOnAir: "Clear All Layers?"
        case .removeSelectedCompositionElements: "Remove Elements?"
        case .removeOnAirElement(let name, _): "Remove “\(name)”?"
        case .emptyProgramLayer(let layer): "Empty \(layer.title)?"
        case .hideAllProgramLayers: "Hide All Layers?"
        case .hideClearStripLayer(let action): action == .all ? "Hide All Layers?" : "\(action.title)?"
        case .clearLiveShot(let layerName, _): "Clear \(layerName)?"
        case .emergencyClearAll: "Clear All Layers?"
        }
    }

    var message: String {
        switch self {
        case .clearLyrics:
            "Removes the live slide. Library files stay."
        case .clearLowerThirds:
            "Removes lower thirds and props."
        case .clearAllOnAir:
            "Clears every program layer."
        case .removeSelectedCompositionElements(let count):
            count == 1
                ? "Removes the selected element."
                : "Removes \(count) elements."
        case .removeOnAirElement:
            "Removes it from program. Library files stay."
        case .emptyProgramLayer:
            "Unloads this layer from program."
        case .hideAllProgramLayers, .hideClearStripLayer(.all), .emergencyClearAll:
            "Hides every layer. Content stays loaded."
        case .hideClearStripLayer:
            "Hides this layer. Content stays loaded."
        case .clearLiveShot:
            "Clears the live source on this layer."
        }
    }

    var confirmButtonTitle: String {
        switch self {
        case .clearLyrics: "Clear Lyrics"
        case .clearLowerThirds: "Clear Thirds"
        case .clearAllOnAir: "Clear All"
        case .removeSelectedCompositionElements: "Remove"
        case .removeOnAirElement: "Remove"
        case .emptyProgramLayer: "Empty Layer"
        case .hideAllProgramLayers, .hideClearStripLayer(.all), .emergencyClearAll: "Hide All"
        case .hideClearStripLayer: "Hide"
        case .clearLiveShot: "Clear Live"
        }
    }

    /// Whether hiding via the preview clear strip should ask first (restore actions skip confirmation).
    static func clearStripHideNeedsConfirm(_ action: ClearStripAction, currentlyHidden: Bool) -> Bool {
        if currentlyHidden { return false }
        switch action {
        case .audio: return false
        case .messages, .props, .slide, .media, .videoInput, .all: return true
        }
    }
}

extension View {
    /// Presents a single confirmation dialog driven by `ShowController.deskDestructiveConfirmRequest`.
    func deskDestructiveConfirmation(controller: ShowController) -> some View {
        modifier(DeskDestructiveConfirmationModifier(controller: controller))
    }
}

private struct DeskDestructiveConfirmationModifier: ViewModifier {
    @Bindable var controller: ShowController

    private var isPresented: Binding<Bool> {
        Binding(
            get: { controller.deskDestructiveConfirmRequest != nil },
            set: { if !$0 { controller.cancelDeskDestructiveConfirm() } }
        )
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            controller.deskDestructiveConfirmRequest?.title ?? "",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(
                controller.deskDestructiveConfirmRequest?.confirmButtonTitle ?? "Continue",
                role: .destructive
            ) {
                controller.confirmDeskDestructiveAction()
            }
            Button("Cancel", role: .cancel) {
                controller.cancelDeskDestructiveConfirm()
            }
        } message: {
            if let request = controller.deskDestructiveConfirmRequest {
                Text(request.message)
            }
        }
    }
}
