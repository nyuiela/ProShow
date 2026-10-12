import Foundation

/// Speaker profiles and automated lower-third graphics on the program props layer.
@MainActor
enum TalentManager {
    static let rundownLowerThirdPropID = ActionSeedID.logoProp

    static func talent(with id: UUID, in program: ProgramDocumentModel) -> TalentProfile? {
        program.talentDatabase.first(where: { $0.id == id })
    }

    static func displayLine(for talent: TalentProfile) -> String {
        let org = talent.organization.trimmingCharacters(in: .whitespacesAndNewlines)
        if org.isEmpty { return talent.titleOrRole }
        return "\(talent.titleOrRole) · \(org)"
    }

    static func fireLowerThird(talent: TalentProfile, controller: ShowController) {
        let nameObject = CanvasObject(
            name: "LT Name",
            kind: .text,
            bounds: CanvasBounds(x: 120, y: 1720, width: 1200, height: 72),
            zIndex: 2,
            text: talent.fullName
        )
        var name = nameObject
        name.fontSize = 42
        name.fontColor = "#FFFFFF"
        name.fill.type = .none
        name.stroke.style = .none

        let titleObject = CanvasObject(
            name: "LT Title",
            kind: .text,
            bounds: CanvasBounds(x: 120, y: 1788, width: 1200, height: 48),
            zIndex: 1,
            text: displayLine(for: talent)
        )
        var title = titleObject
        title.fontSize = 26
        title.fontColor = "#CCCCCC"
        title.fill.type = .none
        title.stroke.style = .none

        controller.inspector.setPropElements(id: rundownLowerThirdPropID, elements: [name, title])
        if !controller.inspector.props.contains(where: { $0.id == rundownLowerThirdPropID && $0.isActive }) {
            _ = controller.toggleInspectorProp(id: rundownLowerThirdPropID)
        } else {
            controller.syncActivePropsToCompositor()
            controller.refreshLiveStack()
        }
    }

    static func clearLowerThird(controller: ShowController) {
        if controller.inspector.props.contains(where: { $0.id == rundownLowerThirdPropID && $0.isActive }) {
            _ = controller.toggleInspectorProp(id: rundownLowerThirdPropID)
        }
    }
}
