import Foundation

/// When live quotes should be force-refreshed for a prop (outside the normal program tick interval).
enum PropLiveQuoteRefresh: String, Codable, Sendable, CaseIterable, Identifiable {
    case onEnter
    case onLeave
    case enterAndLeave
    case programTickOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onEnter: "On prop enter"
        case .onLeave: "On prop leave"
        case .enterAndLeave: "On enter and leave"
        case .programTickOnly: "Program tick only"
        }
    }
}

/// Prop visibility lifecycle (mirrors build enter / build-out leave).
enum PropLifecyclePhase: String, Sendable {
    case start
    case enter
    case leave
}

enum SlideLifecyclePhase: Sendable {
    case enter(SlideID)
    case leave(SlideID)
}

enum PropLifecycleEngine {
    static func shouldForceQuoteRefresh(prop: ProShowProp, phase: PropLifecyclePhase) -> Bool {
        switch prop.liveQuoteRefresh {
        case .onEnter:
            return phase == .enter || phase == .start
        case .onLeave:
            return phase == .leave
        case .enterAndLeave:
            return true
        case .programTickOnly:
            return false
        }
    }
}
