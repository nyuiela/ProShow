import SwiftUI

/// Align and distribute controls for the canvas editor inspector.
struct AlignmentToolbarView: View {
    @Bindable var editor: EditorEngine

    @State private var lastHAlign: HorizontalAlign = .left
    @State private var lastVAlign: VerticalAlign = .top
    @State private var lastDistribute: DistributeAxis = .horizontal

    private enum HorizontalAlign: Hashable {
        case left, center, right
    }

    private enum VerticalAlign: Hashable {
        case top, middle, bottom
    }

    private enum DistributeAxis: Hashable {
        case horizontal, vertical
    }

    var body: some View {
        InspectorSection("Alignment") {
            PropertyRow("Align") {
                IconSegmentedPicker(selection: Binding(
                    get: { lastHAlign },
                    set: { value in
                        lastHAlign = value
                        switch value {
                        case .left: editor.alignSelected(.left)
                        case .center: editor.alignSelected(.centerX)
                        case .right: editor.alignSelected(.right)
                        }
                    }
                ), options: [
                    .init(value: .left, iconName: "align.horizontal.left", tooltip: "Align Left (⌘⌥L)"),
                    .init(value: .center, iconName: "align.horizontal.center", tooltip: "Align Center (⌘⌥C)"),
                    .init(value: .right, iconName: "align.horizontal.right", tooltip: "Align Right (⌘⌥R)"),
                ])
            }
            PropertyRow("Vertical") {
                IconSegmentedPicker(selection: Binding(
                    get: { lastVAlign },
                    set: { value in
                        lastVAlign = value
                        switch value {
                        case .top: editor.alignSelected(.top)
                        case .middle: editor.alignSelected(.centerY)
                        case .bottom: editor.alignSelected(.bottom)
                        }
                    }
                ), options: [
                    .init(value: .top, iconName: "align.vertical.top", tooltip: "Align Top (⌘⌥T)"),
                    .init(value: .middle, iconName: "align.vertical.center", tooltip: "Align Middle (⌘⌥M)"),
                    .init(value: .bottom, iconName: "align.vertical.bottom", tooltip: "Align Bottom (⌘⌥B)"),
                ])
            }
            PropertyRow("Distribute") {
                IconSegmentedPicker(selection: Binding(
                    get: { lastDistribute },
                    set: { value in
                        lastDistribute = value
                        editor.distributeSelected(value == .horizontal ? .horizontal : .vertical)
                    }
                ), options: [
                    .init(value: .horizontal, iconName: "distribute.horizontal.center", tooltip: "Distribute Horizontally"),
                    .init(value: .vertical, iconName: "distribute.vertical.center", tooltip: "Distribute Vertically"),
                ])
                .disabled(editor.selectedObjects.count < 3)
            }
        }
    }
}
