import Foundation
import Observation
#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

@MainActor
@Observable
final class CanvasEditorMouseTracker {
    var overlay = SmartMeasurementOverlayState()
    private(set) var isOptionHeld = false
    private(set) var hoveredElementID: UUID?
    private var hoverX: Double?
    private var hoverY: Double?

    #if os(macOS)
    private var flagMonitor: Any?
    #endif

    func attach() {
        #if os(macOS)
        guard flagMonitor == nil else { return }
        isOptionHeld = NSEvent.modifierFlags.contains(.option)
        flagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.setOptionHeld(event.modifierFlags.contains(.option))
            return event
        }
        #endif
    }

    func detach() {
        #if os(macOS)
        if let flagMonitor {
            NSEvent.removeMonitor(flagMonitor)
        }
        flagMonitor = nil
        #endif
        isOptionHeld = false
        hoveredElementID = nil
        hoverX = nil
        hoverY = nil
        overlay = SmartMeasurementOverlayState()
    }

    func setOptionHeld(_ held: Bool) {
        guard isOptionHeld != held else { return }
        isOptionHeld = held
        if !held {
            overlay.isOptionKeyHeld = false
            if !overlay.measurementVectors.isEmpty {
                overlay = SmartMeasurementOverlayState()
            }
        }
    }

    func hoverMoved(x: Double, y: Double, editor: EditorEngine) {
        hoverX = x
        hoverY = y
        refresh(editor: editor)
    }

    func hoverEnded(editor: EditorEngine) {
        hoverX = nil
        hoverY = nil
        hoveredElementID = nil
        refresh(editor: editor)
    }

    func refresh(editor: EditorEngine) {
        guard isOptionHeld,
              !editor.isEditingText,
              let selectedID = editor.selectedObjectIDs.first,
              let selected = editor.selectionBounds
        else {
            overlay = SmartMeasurementOverlayState(isOptionKeyHeld: isOptionHeld)
            return
        }

        let document = editor.selectedDocument
        let canvas = CanvasBounds(
            x: 0,
            y: 0,
            width: document?.canvasWidth ?? CanvasConfig.width,
            height: document?.canvasHeight ?? CanvasConfig.height
        )

        var target = canvas
        var hoveredID: UUID?
        var measuringToCanvas = true
        if let hoverX, let hoverY, let hit = editor.object(atX: hoverX, y: hoverY),
           !editor.selectedObjectIDs.contains(hit.id) {
            hoveredID = hit.id
            target = hit.bounds
            measuringToCanvas = false
        }
        hoveredElementID = hoveredID
        overlay = SmartMeasurementEngine.calculateOverlayState(
            optionHeld: true,
            selectedID: selectedID,
            hoveredID: hoveredID,
            selectedBounds: selected,
            targetBounds: target,
            measuringToCanvas: measuringToCanvas
        )
    }
}

#if os(macOS)
struct CanvasHoverTrackingView: NSViewRepresentable {
    var scale: CGFloat
    var editor: EditorEngine
    var tracker: CanvasEditorMouseTracker

    func makeNSView(context: Context) -> CanvasHoverTrackingNSView {
        let view = CanvasHoverTrackingNSView()
        view.scale = scale
        view.editor = editor
        view.tracker = tracker
        return view
    }

    func updateNSView(_ view: CanvasHoverTrackingNSView, context: Context) {
        view.scale = scale
        view.editor = editor
        view.tracker = tracker
    }
}

final class CanvasHoverTrackingNSView: NSView {
    var scale: CGFloat = 1
    weak var editor: EditorEngine?
    var tracker: CanvasEditorMouseTracker?
    private var tracking: NSTrackingArea?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .assumeInside],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func mouseMoved(with event: NSEvent) {
        report(event)
    }

    override func mouseDragged(with event: NSEvent) {
        report(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let editor else { return }
        tracker?.hoverEnded(editor: editor)
    }

    private func report(_ event: NSEvent) {
        guard let editor else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = max(scale, 0.0001)
        tracker?.hoverMoved(x: Double(point.x / scale), y: Double(point.y / scale), editor: editor)
    }
}
#endif
