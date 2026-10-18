import SwiftUI

struct CanvasFloatingContextBarLayer: View {
    @Bindable var editor: EditorEngine
    var scale: CGFloat
    var canvasOrigin: CGPoint
    var panOffset: CGSize
    var viewportSize: CGSize

    @State private var measuredSize: CGSize = .init(width: 320, height: ContextBarPositionCalculator.barHeight)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool {
        !editor.selectedObjectIDs.isEmpty
            && editor.inlineEditID == nil
            && !editor.isSelectionTransformActive
    }

    var body: some View {
        Group {
            if isVisible, let bounds = editor.selectionBounds {
                let placement = ContextBarPositionCalculator.placement(
                    selection: bounds,
                    scale: scale,
                    canvasOrigin: canvasOrigin,
                    panOffset: panOffset,
                    viewportSize: viewportSize,
                    barSize: measuredSize
                )
                CanvasContextBarView(editor: editor)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ContextBarSizeKey.self, value: proxy.size)
                        }
                    }
                    .onPreferenceChange(ContextBarSizeKey.self) { measuredSize = $0 }
                    .offset(x: placement.origin.x, y: placement.origin.y)
                    .opacity(isVisible ? 1 : 0)
                    .allowsHitTesting(isVisible)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Selection quick actions")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: editor.selectedObjectIDs)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: editor.isSelectionTransformActive)
                    .zIndex(50)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .allowsHitTesting(isVisible)
    }
}

private struct ContextBarSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .init(width: 320, height: ContextBarPositionCalculator.barHeight)
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct CanvasContextBarView: View {
    @Bindable var editor: EditorEngine

    var body: some View {
        HStack(spacing: 6) {
            contextSpecificControls
            ContextBarDivider()
            ContextBarCommonActions(editor: editor)
        }
        .deskFloatingToolbarCapsule()
    }

    @ViewBuilder
    private var contextSpecificControls: some View {
        if editor.selectedObjectIDs.count > 1 {
            ContextBarMultiSelectControls(editor: editor)
        } else if let object = editor.selectedObjects.first {
            switch object.kind {
            case _ where object.isTextLike:
                ContextBarTextControls(editor: editor)
            case .image, .videoInput, .prop:
                ContextBarMediaControls(editor: editor)
            case .rectangle, .roundedRectangle, .ellipse, .line, .polygon, .pen:
                ContextBarShapeControls(editor: editor)
            default:
                ContextBarGenericControls(editor: editor)
            }
        }
    }
}

// MARK: - Shared chrome

private struct ContextBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 1, height: 16)
    }
}

private struct ContextBarIconButton: View {
    var systemName: String
    var label: String
    var tint: Color = .white
    var selected: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? ProShowTheme.accent : tint)
                .frame(width: 22, height: 22)
                .background(selected ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(ContextBarPressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct ContextBarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

// MARK: - Text

private struct ContextBarTextControls: View {
    @Bindable var editor: EditorEngine

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(SystemFontCatalog.menu(including: editor.commonValue(\.typography.fontFamily)), id: \.self) { name in
                    Button(name) {
                        editor.mutateSelectedObjects { $0.typography.fontFamily = name }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(editor.commonValue(\.typography.fontFamily) ?? "Font")
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 72, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .frame(height: 22)
            .accessibilityLabel("Font family")

            ContextBarIconButton(systemName: "minus", label: "Decrease font size") {
                editor.mutateSelectedObjects { $0.typography.fontSize = max(8, $0.typography.fontSize - 2) }
            }
            Text("\(Int(editor.commonValue(\.typography.fontSize) ?? 48))")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: 28)
                .accessibilityLabel("Font size")
            ContextBarIconButton(systemName: "plus", label: "Increase font size") {
                editor.mutateSelectedObjects { $0.typography.fontSize = min(400, $0.typography.fontSize + 2) }
            }

            ContextBarDivider()

            ContextBarIconButton(
                systemName: "bold",
                label: "Bold",
                selected: editor.commonValue(\.typography.isBold) ?? false
            ) {
                editor.mutateSelectedObjects { $0.typography.isBold.toggle() }
            }
            ContextBarIconButton(
                systemName: "italic",
                label: "Italic",
                selected: editor.commonValue(\.typography.isItalic) ?? false
            ) {
                editor.mutateSelectedObjects { $0.typography.isItalic.toggle() }
            }

            CompactColorSwatch(
                color: contextBarColor(getHex: { editor.commonValue(\.typography.color) ?? "#FFFFFF" }) { hex in
                    editor.mutateSelectedObjects { $0.typography.color = hex }
                },
                size: 22,
                accessibilityLabel: "Text color"
            )

            HStack(spacing: 2) {
                alignButton(.left, icon: "text.alignleft")
                alignButton(.center, icon: "text.aligncenter")
                alignButton(.right, icon: "text.alignright")
            }

            let loopOn = editor.commonValue(\.textLayout.loopDirection) != nil
            ContextBarIconButton(systemName: "arrow.left.and.right", label: "Ticker loop", selected: loopOn) {
                editor.mutateSelectedObjects { object in
                    if object.textLayout.loopDirection == nil {
                        object.textLayout.loopDirection = .left
                    } else {
                        object.textLayout.loopDirection = nil
                    }
                }
            }
        }
    }

    private func alignButton(_ align: TextHorizontalAlign, icon: String) -> some View {
        let current = editor.commonValue(\.textLayout.horizontalAlign) ?? .left
        return ContextBarIconButton(systemName: icon, label: "Align \(align.rawValue)", selected: current == align) {
            editor.mutateSelectedObjects { $0.textLayout.horizontalAlign = align }
        }
    }
}

// MARK: - Shape

private struct ContextBarShapeControls: View {
    @Bindable var editor: EditorEngine

    var body: some View {
        HStack(spacing: 4) {
            CompactColorSwatch(
                color: contextBarColor(getHex: { editor.commonValue(\.fill.color) ?? "#FFFFFF" }) { hex in
                    editor.mutateSelectedObjects { $0.fill.color = hex }
                },
                size: 22,
                accessibilityLabel: "Fill color"
            )

            CompactColorSwatch(
                color: contextBarColor(getHex: { editor.commonValue(\.stroke.color) ?? "#FFFFFF" }) { hex in
                    editor.mutateSelectedObjects { $0.stroke.color = hex }
                },
                size: 22,
                accessibilityLabel: "Stroke color"
            )

            Stepper(value: strokeWidthBinding, in: 0...24, step: 1) {
                Text("\(Int(editor.commonValue(\.stroke.width) ?? 0))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 24)
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Stroke width")

            if editor.selectedObjects.contains(where: { $0.kind == .roundedRectangle || $0.stroke.cornerRadius > 0 }) {
                Stepper(value: cornerRadiusBinding, in: 0...120, step: 2) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Corner radius")
            }

            ContextBarDivider()

            ContextBarIconButton(systemName: "square.2.layers.3d.top.filled", label: "Bring forward") {
                editor.bringForward()
            }
            ContextBarIconButton(systemName: "square.2.layers.3d.bottom.filled", label: "Send backward") {
                editor.sendBackward()
            }
        }
    }

    private var strokeWidthBinding: Binding<Double> {
        Binding(
            get: { editor.commonValue(\.stroke.width) ?? 0 },
            set: { value in editor.mutateSelectedObjects { $0.stroke.width = value } }
        )
    }

    private var cornerRadiusBinding: Binding<Double> {
        Binding(
            get: { editor.commonValue(\.stroke.cornerRadius) ?? 0 },
            set: { value in editor.mutateSelectedObjects { $0.stroke.cornerRadius = value } }
        )
    }
}

// MARK: - Media

private struct ContextBarMediaControls: View {
    @Bindable var editor: EditorEngine

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(ImageScaleMode.allCases) { mode in
                    Button(mode.title) {
                        editor.mutateSelectedObjects { $0.fill.imageScaleMode = mode }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text((editor.commonValue(\.fill.imageScaleMode) ?? .fill).title)
                        .font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Media scale mode")

            let muted = editor.selectedObjects.allSatisfy { $0.audioMuted == true }
            ContextBarIconButton(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Mute audio", selected: muted) {
                editor.mutateSelectedObjects { $0.audioMuted = !muted }
            }

            ContextBarDivider()

            ContextBarIconButton(systemName: "square.2.layers.3d.top.filled", label: "Bring forward") {
                editor.bringForward()
            }
            ContextBarIconButton(systemName: "square.2.layers.3d.bottom.filled", label: "Send backward") {
                editor.sendBackward()
            }
        }
    }
}

// MARK: - Multi-select & generic

private struct ContextBarMultiSelectControls: View {
    @Bindable var editor: EditorEngine

    var body: some View {
        HStack(spacing: 4) {
            if editor.canGroup {
                ContextBarIconButton(systemName: "square.3.layers.3d.top.filled", label: "Group (⌘G)") {
                    editor.groupSelected()
                }
            }
            if editor.canUngroup {
                ContextBarIconButton(systemName: "square.3.layers.3d.bottom.filled", label: "Ungroup (⌘⇧G)", tint: .cyan) {
                    editor.ungroupSelected()
                }
            }
            HStack(spacing: 2) {
                ContextBarIconButton(systemName: "align.horizontal.left", label: "Align left") {
                    editor.alignSelected(.left)
                }
                ContextBarIconButton(systemName: "align.horizontal.center", label: "Align center") {
                    editor.alignSelected(.centerX)
                }
                ContextBarIconButton(systemName: "align.horizontal.right", label: "Align right") {
                    editor.alignSelected(.right)
                }
            }
            ContextBarIconButton(systemName: "distribute.horizontal.center", label: "Distribute horizontally") {
                editor.distributeSelected(.horizontal)
            }
            .disabled(editor.selectedObjects.count < 3)
        }
    }
}

private struct ContextBarGenericControls: View {
    @Bindable var editor: EditorEngine

    var body: some View {
        if editor.canUngroup {
            ContextBarIconButton(systemName: "square.3.layers.3d.bottom.filled", label: "Ungroup (⌘⇧G)", tint: .cyan) {
                editor.ungroupSelected()
            }
        } else {
            Stepper(value: opacityBinding, in: 0...100, step: 5) {
                Text("\(Int((editor.commonValue(\.opacity) ?? 1) * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Opacity")
        }
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { (editor.commonValue(\.opacity) ?? 1) * 100 },
            set: { value in editor.mutateSelectedObjects { $0.opacity = value / 100 } }
        )
    }
}

private struct ContextBarCommonActions: View {
    @Bindable var editor: EditorEngine

    var body: some View {
        HStack(spacing: 6) {
            if editor.selectedObjectIDs.count == 1, editor.canUngroup {
                ContextBarIconButton(systemName: "square.3.layers.3d.bottom.filled", label: "Ungroup (⌘⇧G)", tint: .cyan) {
                    editor.ungroupSelected()
                }
            }

            ContextBarIconButton(
                systemName: editor.selectionIsCanvasLocked ? "lock.fill" : "lock.open",
                label: editor.selectionIsCanvasLocked ? "Unlock selection" : "Lock selection",
                tint: editor.selectionIsCanvasLocked ? .yellow : .gray
            ) {
                editor.toggleLockSelected()
            }

            ContextBarIconButton(systemName: "plus.square.on.square", label: "Duplicate (⌘D)") {
                editor.duplicateSelected()
            }

            ContextBarIconButton(systemName: "trash", label: "Delete", tint: Color.red.opacity(0.85)) {
                editor.deleteSelected()
            }
        }
    }
}

private func contextBarColor(getHex: @escaping @MainActor () -> String, apply: @escaping @MainActor (String) -> Void) -> Binding<Color> {
    Binding(
        get: { Color(hex: getHex()) ?? .white },
        set: { color in
            let next = color.hexString(includeAlpha: false)
            guard next.caseInsensitiveCompare(getHex()) != .orderedSame else { return }
            apply(next)
        }
    )
}
