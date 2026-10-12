import Foundation

extension ShowController {
    /// Exactly one workspace capsule should match this at a time.
    var workspaceToolbarSelection: WorkspaceToolbarSelection {
        if isProjectSettingsOpen || isPreFlightPresented {
            return .more
        }
        if editors.isOpen, let kind = editors.kind {
            switch kind {
            case .presentation:
                return .edit
            case .props:
                return .props
            case .stage, .theme, .masks, .overlays, .ccli:
                return .more
            }
        }
        switch operatorMode {
        case .show, .reflow, .widgets, .bible:
            return .show
        case .edit:
            return .edit
        case .rundown:
            return .rundown
        case .map:
            return .map
        }
    }

    /// Close settings / pre-flight sheets when the operator picks a different workspace.
    func dismissDeskWorkspaceSheets() {
        isProjectSettingsOpen = false
        isPreFlightPresented = false
        isGoLiveSetupPresented = false
    }

    func presentProjectSettings() {
        dismissDeskWorkspaceSheets()
        isProjectSettingsOpen = true
    }
}
