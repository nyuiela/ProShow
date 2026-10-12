import Foundation

extension ShowController {
    var userVisibleElements: [UserVisibleElement] {
        programLayerRows.map { row in
            UserVisibleElement(
                id: row.id,
                displayName: row.item.name,
                subtitleText: LayerSemanticMapper.subtitle(for: row, controller: self),
                role: LayerSemanticMapper.role(for: row),
                isVisible: row.item.isVisible,
                isLocked: row.item.isLocked
            )
        }
    }

    var activeElementCount: Int {
        userVisibleElements.filter(\.isOnAir).count
    }

    func toggleVisibility(for elementID: UUID) {
        programLayerToggleVisibility(id: elementID)
    }

    func toggleLock(for elementID: UUID) {
        programLayerToggleLock(id: elementID)
    }

    func dismissElement(id elementID: UUID) {
        deleteElement(id: elementID)
    }

    func clearMainContent() {
        emptyProgramLayer(.slide)
        tickProgram()
    }

    func clearLowerThirds() {
        let lowerThirdIDs = userVisibleElements.filter { $0.role == .lowerThird }.map(\.id)
        for id in lowerThirdIDs {
            programLayerDelete(id: id)
        }
        if compositor.stack.activeProps.isEmpty == false {
            emptyProgramLayer(.props)
        }
        tickProgram()
    }

    func clearAllProgramOutputs() {
        hideAllLayers()
        tickProgram()
    }

    func requestDeskDestructiveConfirm(_ action: DeskDestructiveConfirmAction) {
        deskDestructiveConfirmRequest = action
    }

    func cancelDeskDestructiveConfirm() {
        deskDestructiveConfirmRequest = nil
    }

    func confirmDeskDestructiveAction() {
        guard let action = deskDestructiveConfirmRequest else { return }
        deskDestructiveConfirmRequest = nil
        performDeskDestructiveConfirm(action)
    }

    func performDeskDestructiveConfirm(_ action: DeskDestructiveConfirmAction) {
        switch action {
        case .clearLyrics:
            clearMainContent()
        case .clearLowerThirds:
            clearLowerThirds()
        case .clearAllOnAir:
            clearAllProgramOutputs()
        case .removeSelectedCompositionElements:
            compositionDeleteSelectedLayers()
        case .removeOnAirElement(_, let id):
            dismissElement(id: id)
        case .emptyProgramLayer(let layer):
            emptyProgramLayer(layer)
        case .hideAllProgramLayers, .emergencyClearAll:
            hideAllLayers()
        case .hideClearStripLayer(let strip):
            _ = clearLayer(named: strip.layerName)
        case .clearLiveShot(_, let layerIndex):
            clearLiveShot(layerIndex: layerIndex)
        }
    }
}
