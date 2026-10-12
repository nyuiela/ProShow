import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SelectionChromeView: View {
    var editor: EditorEngine
    let object: CanvasObject
    var scale: CGFloat

    private var bounds: CanvasBounds { editor.displayBounds(for: object) }
    private var width: CGFloat { max(16, bounds.width * scale) }
    private var height: CGFloat { max(12, bounds.height * scale) }
    private var transformLocked: Bool { object.isCanvasLocked }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .strokeBorder(transformLocked ? Color.orange.opacity(0.85) : Color.yellow, lineWidth: 1.2)
                .allowsHitTesting(false)
            if transformLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.orange)
                    .offset(y: -10)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Locked")
            }
            handle(.topLeft, x: 0, y: 0)
            handle(.top, x: width / 2, y: 0)
            handle(.topRight, x: width, y: 0)
            handle(.right, x: width, y: height / 2)
            handle(.bottomRight, x: width, y: height)
            handle(.bottom, x: width / 2, y: height)
            handle(.bottomLeft, x: 0, y: height)
            handle(.left, x: 0, y: height / 2)
            handle(.rotation, x: width / 2, y: -CanvasTransformEngine.rotationHandleOffset)
            Circle()
                .strokeBorder(Color.white, lineWidth: 1)
                .background(Circle().fill(Color.yellow))
                .frame(width: 8, height: 8)
                .position(
                    x: width * object.transform.resolvedOriginX,
                    y: height * object.transform.resolvedOriginY
                )
                .gesture(drag(.origin))
            if object.usesRoundedMediaFrame {
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 7, height: 7)
                    .position(x: 14, y: 14)
                    .gesture(drag(.cornerRadius))
            }
        }
        .frame(width: width, height: height)
        .rotationEffect(.degrees(editor.displayRotation(for: object)))
        .offset(x: bounds.x * scale, y: bounds.y * scale)
        .transaction { $0.animation = nil }
    }

    private func handle(_ kind: TransformHandle, x: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(kind == .rotation ? Color.orange : Color.white)
            .overlay(Rectangle().stroke(Color.yellow, lineWidth: 1))
            .frame(width: 8, height: 8)
            .position(x: x, y: y)
            .opacity(transformLocked ? 0 : 1)
            .allowsHitTesting(!transformLocked)
            .gesture(transformLocked ? nil : drag(kind))
    }

    private func drag(_ handle: TransformHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("editorCanvas"))
            .onChanged { value in
                if editor.activeHandle != handle {
                    editor.beginHandleDrag(id: object.id, handle: handle)
                }
                editor.updateHandleDrag(
                    translationX: Double(value.translation.width / max(scale, 0.0001)),
                    translationY: Double(value.translation.height / max(scale, 0.0001)),
                    shiftHeld: Self.shiftHeld,
                    optionHeld: Self.optionHeld,
                    commandHeld: Self.commandHeld
                )
            }
            .onEnded { _ in
                editor.endHandleDrag()
            }
    }

    fileprivate static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    fileprivate static var optionHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }

    fileprivate static var commandHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.command)
        #else
        false
        #endif
    }
}

struct CompoundSelectionChromeView: View {
    var editor: EditorEngine
    var bounds: CanvasBounds
    var scale: CGFloat

    private var width: CGFloat { max(16, bounds.width * scale) }
    private var height: CGFloat { max(12, bounds.height * scale) }
    private var transformLocked: Bool { editor.selectionContainsLockedObjects }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .strokeBorder(transformLocked ? Color.orange.opacity(0.85) : Color.yellow, lineWidth: 1.2)
                .allowsHitTesting(false)
            handle(.topLeft, x: 0, y: 0)
            handle(.top, x: width / 2, y: 0)
            handle(.topRight, x: width, y: 0)
            handle(.right, x: width, y: height / 2)
            handle(.bottomRight, x: width, y: height)
            handle(.bottom, x: width / 2, y: height)
            handle(.bottomLeft, x: 0, y: height)
            handle(.left, x: 0, y: height / 2)
            handle(.rotation, x: width / 2, y: -CanvasTransformEngine.rotationHandleOffset)
        }
        .frame(width: width, height: height)
        .offset(x: bounds.x * scale, y: bounds.y * scale)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Group selection handles")
    }

    private func handle(_ kind: TransformHandle, x: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(kind == .rotation ? Color.orange : Color.white)
            .overlay(Rectangle().stroke(Color.yellow, lineWidth: 1))
            .frame(width: 8, height: 8)
            .position(x: x, y: y)
            .opacity(transformLocked ? 0 : 1)
            .allowsHitTesting(!transformLocked)
            .gesture(transformLocked ? nil : drag(kind))
            .accessibilityLabel(kind.rawValue)
    }

    private func drag(_ handle: TransformHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("editorCanvas"))
            .onChanged { value in
                guard let anchor = editor.selectedObjects.first?.id else { return }
                if editor.activeHandle != handle {
                    editor.beginHandleDrag(id: anchor, handle: handle)
                }
                editor.updateHandleDrag(
                    translationX: Double(value.translation.width / max(scale, 0.0001)),
                    translationY: Double(value.translation.height / max(scale, 0.0001)),
                    shiftHeld: SelectionChromeView.shiftHeld,
                    optionHeld: SelectionChromeView.optionHeld,
                    commandHeld: SelectionChromeView.commandHeld
                )
            }
            .onEnded { _ in
                editor.endHandleDrag()
            }
    }
}

struct GroupIsolationOutline: View {
    var bounds: CanvasBounds
    var scale: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .strokeBorder(Color.yellow.opacity(0.55), style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [6, 4]))
            .frame(width: max(16, bounds.width * scale), height: max(12, bounds.height * scale))
            .offset(x: bounds.x * scale, y: bounds.y * scale)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct SmartGuidesOverlay: View {
    var guides: [SmartGuide]
    var canvasWidth: Double
    var canvasHeight: Double
    var scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            for guide in guides {
                var path = Path()
                if guide.vertical {
                    path.move(to: CGPoint(x: guide.position * scale, y: 0))
                    path.addLine(to: CGPoint(x: guide.position * scale, y: canvasHeight * scale))
                } else {
                    path.move(to: CGPoint(x: 0, y: guide.position * scale))
                    path.addLine(to: CGPoint(x: canvasWidth * scale, y: guide.position * scale))
                }
                context.stroke(path, with: .color(guide.canvasAligned ? .pink : .cyan), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
