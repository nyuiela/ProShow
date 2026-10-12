import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Native pasteboard encoding for canvas objects.
enum ClipboardController {
    static let pasteOffset = 20.0
    static let duplicateOffset = 10.0
    static let pasteboardTypeName = "com.proshow.canvas-objects"

    private static var memory: [CanvasObject] = []

    static func write(_ objects: [CanvasObject]) {
        memory = objects
        #if canImport(AppKit)
        let board = NSPasteboard.general
        board.clearContents()
        if let data = try? JSONEncoder().encode(objects) {
            board.setData(data, forType: NSPasteboard.PasteboardType(pasteboardTypeName))
        }
        #endif
    }

    static func read() -> [CanvasObject] {
        #if canImport(AppKit)
        let board = NSPasteboard.general
        if let data = board.data(forType: NSPasteboard.PasteboardType(pasteboardTypeName)),
           let objects = try? JSONDecoder().decode([CanvasObject].self, from: data) {
            return objects
        }
        #endif
        return memory
    }

    static var hasObjects: Bool {
        !read().isEmpty
    }

    static func rematerialize(_ objects: [CanvasObject], offset: Double) -> [CanvasObject] {
        var groupMap: [UUID: UUID] = [:]
        return objects.map { source in
            var copy = source
            copy.id = UUID()
            copy.transform.x += offset
            copy.transform.y += offset
            if let groupID = copy.groupID {
                if groupMap[groupID] == nil {
                    groupMap[groupID] = UUID()
                }
                copy.groupID = groupMap[groupID]
            }
            if var steps = copy.buildSteps {
                steps = steps.map { step in
                    var next = step
                    next.id = UUID()
                    next.elementId = copy.id
                    return next
                }
                copy.buildSteps = steps
            }
            return copy
        }
    }
}
