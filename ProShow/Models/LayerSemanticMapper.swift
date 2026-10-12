import Foundation

/// Human-facing production roles mapped from the fixed eight-layer compositor stack.
enum ProductionRole: String, CaseIterable, Codable, Sendable {
    case background = "Background"
    case camera = "Live Camera"
    case mainContent = "Presentation"
    case lowerThird = "Lower Third"
    case graphicOverlay = "Overlay"
    case emergencyAlert = "Alert"

    var iconName: String {
        switch self {
        case .background: "photo.fill"
        case .camera: "video.fill"
        case .mainContent: "textformat"
        case .lowerThird: "rectangle.stack.badge.person.crop"
        case .graphicOverlay: "square.on.square"
        case .emergencyAlert: "exclamationmark.triangle.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .background: "Background"
        case .camera: "Camera"
        case .mainContent: "Presentation"
        case .lowerThird: "Lower Third"
        case .graphicOverlay: "Overlay"
        case .emergencyAlert: "Alert"
        }
    }
}

struct UserVisibleElement: Identifiable, Sendable, Hashable {
    var id: UUID
    var displayName: String
    var subtitleText: String
    var role: ProductionRole
    var isVisible: Bool
    var isLocked: Bool

    var isOnAir: Bool { isVisible }
}

enum LayerSemanticMapper {
    /// Maps compositor slot indices (1…8) to production roles.
    static func role(forInternalLayerIndex index: Int) -> ProductionRole {
        switch index {
        case 1, 3: return .background
        case 2: return .camera
        case 4: return .mainContent
        case 5, 6: return .graphicOverlay
        case 7: return .lowerThird
        case 8: return .emergencyAlert
        default: return .mainContent
        }
    }

    static func role(for renderLayer: RenderLayer) -> ProductionRole {
        role(forInternalLayerIndex: renderLayer.rawValue)
    }

    @MainActor
    static func role(for row: ProgramLayerRow) -> ProductionRole {
        switch row.target {
        case .programVideoInput:
            return .camera
        case .programMedia:
            return .background
        case .slideLyric, .slideCanvasObject:
            return mainContentRole(for: row)
        case .propCanvasObject, .activeProp:
            return propRole(for: row)
        case .outputMessage:
            return messageRole(for: row)
        }
    }

    @MainActor
    static func subtitle(for row: ProgramLayerRow, controller: ShowController) -> String {
        switch row.target {
        case .programMedia:
            let media = controller.compositor.stack.media
            if controller.playback.isPlaying, !(media?.isImage == true) {
                let rate = controller.playback.isLooping ? " · Looping" : ""
                return "Playing\(rate)"
            }
            if media?.isImage == true { return "Still image" }
            return "Background video"
        case .programVideoInput:
            return "Live program input"
        case .slideLyric:
            return "Main display text"
        case .slideCanvasObject:
            return row.item.kind == .text ? "Slide text" : "Slide graphic"
        case .propCanvasObject, .activeProp:
            return propRole(for: row) == .lowerThird ? "Speaker / title card" : "On-screen graphic"
        case .outputMessage:
            if row.item.kindDetail.localizedCaseInsensitiveContains("announcement") {
                return "Ticker / announcement"
            }
            return "Audience message"
        }
    }

    private static func mainContentRole(for row: ProgramLayerRow) -> ProductionRole {
        if row.item.kind == .text { return .mainContent }
        return .graphicOverlay
    }

    private static func propRole(for row: ProgramLayerRow) -> ProductionRole {
        let name = row.item.name.lowercased()
        let detail = row.item.kindDetail.lowercased()
        if name.contains("lower third") || name.contains("speaker") || detail.contains("lower") {
            return .lowerThird
        }
        if row.item.kind == .text { return .lowerThird }
        return .graphicOverlay
    }

    private static func messageRole(for row: ProgramLayerRow) -> ProductionRole {
        if row.item.kindDetail.localizedCaseInsensitiveContains("announcement") {
            return .graphicOverlay
        }
        return .graphicOverlay
    }
}
