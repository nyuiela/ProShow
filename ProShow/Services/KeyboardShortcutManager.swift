import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum ShortcutAction: Equatable, Sendable {
    case setTool(CanvasTool)
    case copy
    case paste
    case cut
    case duplicate
    case delete
    case selectAll
    case group
    case ungroup
    case bringForward
    case sendBackward
    case bringToFront
    case sendToBack
    case nudge(dx: Double, dy: Double)
    case align(CanvasAlign)
    case workspace(OperatorMode)
    case openEditor(EditorKind)
    case clearLayer(Int)
    case emergencyClear
    case advance
    case spaceDown
    case pointer
    case map(NodeGraphCommand)
    case backstageIntercom
    case backstageCycleGuestSource
}

struct ShortcutContext: Equatable, Sendable {
    var editorOpen: Bool
    var isEditingText: Bool
    var isTypingInField: Bool
    var hasObjectSelection: Bool
    var operatorMode: OperatorMode
}

struct ShortcutInput: Equatable, Sendable {
    var characters: String
    var keyCode: UInt16
    var command: Bool
    var shift: Bool
    var option: Bool
    var control: Bool
    var isARepeat: Bool

    var letter: String {
        characters.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// ⌘1…⌘5 match the left title-bar workspace capsule (`TaskMenuItem.workspaceTools`).
enum WorkspaceTitleBarShortcuts {
    static func action(forDigit digit: String) -> ShortcutAction? {
        switch digit {
        case "1": return .workspace(.show)
        case "2": return .workspace(.edit)
        case "3": return .workspace(.rundown)
        case "4": return .workspace(.map)
        case "5": return .openEditor(.props)
        default: return nil
        }
    }
}

enum KeyboardShortcutResolver {
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let escape: UInt16 = 53
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117
    static let keypadClear: UInt16 = 71
    static let functionKeyLayer: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8,
    ]

    static func resolve(_ input: ShortcutInput, context: ShortcutContext) -> ShortcutAction? {
        if input.keyCode == space, !input.command, !input.control, !input.isARepeat {
            if context.isTypingInField || context.isEditingText { return nil }
            if input.option, !input.shift, context.operatorMode == .show {
                return .backstageIntercom
            }
            if input.shift, !input.option, context.operatorMode == .show {
                return .backstageCycleGuestSource
            }
            if context.editorOpen { return .spaceDown }
            if context.operatorMode == .map {
                return .map(input.shift ? .palette : .spacePan)
            }
            if context.operatorMode == .rundown { return .advance }
            if context.operatorMode == .show { return .advance }
            return nil
        }

        if let layer = functionKeyLayer[input.keyCode], !input.command, !input.option, !input.control {
            return .clearLayer(layer)
        }

        if input.keyCode == escape {
            if input.command {
                return .emergencyClear
            }
            if context.operatorMode == .map, !context.editorOpen, !context.isTypingInField {
                return .map(.deselect)
            }
            if context.editorOpen, !context.isTypingInField {
                return .pointer
            }
            return nil
        }

        if input.command, input.keyCode == keypadClear {
            return .emergencyClear
        }

        if context.isTypingInField || context.isEditingText {
            return nil
        }

        if context.operatorMode == .map, !context.editorOpen, let map = NodeGraphHotkey.resolve(input) {
            return .map(map)
        }

        if input.command {
            return resolveCommand(input, context: context)
        }

        if context.editorOpen {
            return resolveEditor(input, context: context)
        }
        return nil
    }

    private static func resolveCommand(_ input: ShortcutInput, context: ShortcutContext) -> ShortcutAction? {
        if input.option, !input.shift {
            switch input.letter {
            case "l": return .align(.left)
            case "c": return .align(.centerX)
            case "r": return .align(.right)
            case "t": return .align(.top)
            case "m": return .align(.centerY)
            case "b": return .align(.bottom)
            default: break
            }
        }

        if !input.shift, !input.option, let workspace = WorkspaceTitleBarShortcuts.action(forDigit: input.letter) {
            return workspace
        }

        guard context.editorOpen else { return nil }

        if input.letter == "g" {
            return input.shift ? .ungroup : .group
        }
        if input.letter == "]" {
            return input.shift ? .bringToFront : .bringForward
        }
        if input.letter == "[" {
            return input.shift ? .sendToBack : .sendBackward
        }

        guard !input.shift, !input.option else { return nil }
        switch input.letter {
        case "c": return context.hasObjectSelection ? .copy : nil
        case "v": return .paste
        case "x": return context.hasObjectSelection ? .cut : nil
        case "d": return context.hasObjectSelection ? .duplicate : nil
        case "a": return .selectAll
        default: return nil
        }
    }

    private static func resolveEditor(_ input: ShortcutInput, context: ShortcutContext) -> ShortcutAction? {
        if input.keyCode == delete || input.keyCode == forwardDelete {
            return context.hasObjectSelection ? .delete : nil
        }

        if context.hasObjectSelection {
            let step = input.shift ? 10.0 : 1.0
            switch input.keyCode {
            case leftArrow: return .nudge(dx: -step, dy: 0)
            case rightArrow: return .nudge(dx: step, dy: 0)
            case upArrow: return .nudge(dx: 0, dy: -step)
            case downArrow: return .nudge(dx: 0, dy: step)
            default: break
            }
        }

        guard !input.option, !input.control else { return nil }
        switch input.letter {
        case "v": return .setTool(.pointer)
        case "t": return .setTool(.text)
        case "r": return .setTool(.rectangle)
        case "o", "c": return .setTool(.ellipse)
        case "p": return input.shift ? .setTool(.pen) : .setTool(.placeholder)
        case "h": return .setTool(.hand)
        case "z": return .setTool(.zoom)
        case "a": return .setTool(.direct)
        case "b": return input.shift ? .setTool(.bend) : nil
        default: return nil
        }
    }
}

#if os(macOS)
@MainActor
final class KeyboardShortcutManager {
    static let shared = KeyboardShortcutManager()

    private(set) weak var controller: ShowController?
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    func attach(_ controller: ShowController) {
        self.controller = controller
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event) ?? event
        }
    }

    func detach() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
        }
        keyDownMonitor = nil
        keyUpMonitor = nil
        controller = nil
    }

    func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let controller else { return event }
        let context = ShortcutContext(
            editorOpen: controller.isCanvasEditorPresented,
            isEditingText: controller.editors.isEditingText,
            isTypingInField: Self.isTextInput(event.window?.firstResponder),
            hasObjectSelection: !controller.editors.selectedObjectIDs.isEmpty,
            operatorMode: controller.operatorMode
        )
        let input = ShortcutInput(
            characters: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control),
            isARepeat: event.isARepeat
        )
        guard let action = KeyboardShortcutResolver.resolve(input, context: context) else {
            return event
        }
        perform(action, on: controller)
        return nil
    }

    func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        guard let controller, event.keyCode == KeyboardShortcutResolver.space else {
            return event
        }
        if controller.editors.spaceHeld {
            controller.editors.endSpacePan()
            return nil
        }
        if controller.placeholderMatrix.graphSpaceHeld {
            controller.placeholderMatrix.graphSpaceHeld = false
            return nil
        }
        return event
    }

    private func perform(_ action: ShortcutAction, on controller: ShowController) {
        let editor = controller.editors
        switch action {
        case .setTool(let tool):
            editor.setTool(tool)
        case .pointer:
            if editor.isEditingText {
                editor.endInlineEdit()
            } else if editor.isolatedObjectID != nil {
                editor.exitIsolation()
            } else {
                editor.setTool(.pointer)
            }
        case .copy:
            editor.copySelectedObjects()
        case .paste:
            editor.pasteObjects()
        case .cut:
            editor.cutSelectedObjects()
        case .duplicate:
            editor.duplicateSelected()
        case .delete:
            editor.deleteSelected()
        case .selectAll:
            editor.selectAllObjects()
        case .group:
            editor.groupSelected()
        case .ungroup:
            editor.ungroupSelected()
        case .bringForward:
            editor.bringForward()
        case .sendBackward:
            editor.sendBackward()
        case .bringToFront:
            editor.bringToFront()
        case .sendToBack:
            editor.sendToBack()
        case .nudge(let dx, let dy):
            editor.nudgeSelected(dx: dx, dy: dy)
        case .align(let alignment):
            editor.alignSelected(alignment)
        case .workspace(let mode):
            controller.setMode(mode)
        case .openEditor(let kind):
            controller.openEditor(kind)
        case .clearLayer(let index):
            if let layer = RenderLayer(rawValue: index) {
                controller.hideLayer(layer)
            }
        case .emergencyClear:
            controller.requestDeskDestructiveConfirm(.emergencyClearAll)
        case .advance:
            if controller.operatorMode == .rundown, controller.rundownClock.isShowRunning {
                controller.rundownSpaceAction()
            } else {
                controller.advance()
            }
        case .spaceDown:
            editor.beginSpacePan()
        case .map(let command):
            controller.performMapGraphCommand(command)
        case .backstageIntercom:
            controller.toggleBackstageIntercom()
        case .backstageCycleGuestSource:
            controller.ensureGuestAudioChannels()
            controller.cycleBackstageGuestOnProgram()
        }
    }

    static func isTextInput(_ responder: NSResponder?) -> Bool {
        if responder is NSTextView || responder is NSTextField {
            return true
        }
        var view = responder as? NSView
        while let current = view {
            if current is NSTextView || current is NSTextField {
                return true
            }
            view = current.superview
        }
        return false
    }
}
#endif
