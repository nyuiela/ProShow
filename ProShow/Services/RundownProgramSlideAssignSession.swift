import Foundation

/// Holds the rundown block editor callback while **Assign Source** is open.
@MainActor
enum RundownProgramSlideAssignSession {
    private static var handler: ((DiscoveredSourceItem) -> Void)?

    static func begin(_ onAssign: @escaping (DiscoveredSourceItem) -> Void) {
        handler = onAssign
    }

    static func fire(_ item: DiscoveredSourceItem) {
        handler?(item)
        handler = nil
    }

    static func cancel() {
        handler = nil
    }
}
