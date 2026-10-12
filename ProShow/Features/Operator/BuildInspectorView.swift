import SwiftUI

struct BuildInspectorView: View {
    @Bindable var controller: ShowController

    private var editor: EditorEngine { controller.editors }

    private var selectedObject: CanvasObject? {
        editor.selectedObjects.count == 1 ? editor.selectedObjects.first : nil
    }

    private var steps: [ElementBuildStep] {
        (selectedObject?.buildSteps ?? []).sorted { $0.sequenceOrder < $1.sequenceOrder }
    }

    var body: some View {
        if editor.selectedObjects.isEmpty {
            Text("Select an object to edit builds.")
                .font(InspectorTokens.labelFont)
                .foregroundColor(InspectorTokens.labelColor)
                .padding(.top, 12)
        } else if editor.selectedObjects.count > 1 {
            Text("Select a single object to edit its build sequence.")
                .font(InspectorTokens.labelFont)
                .foregroundColor(InspectorTokens.labelColor)
                .padding(.top, 12)
        } else {
            InspectorSection("Selected") {
                Text(selectedObject?.name ?? "Element")
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.headerColor)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            InspectorSection("Add Step") {
                HStack(spacing: 6) {
                    addButton("Build In", phase: .buildIn)
                    addButton("Action", phase: .action)
                    addButton("Build Out", phase: .buildOut)
                }
            }

            InspectorSection("Sequence") {
                if steps.isEmpty {
                    Text("No build steps. Add an entrance, action, or exit.")
                        .font(InspectorTokens.labelFont)
                        .foregroundColor(InspectorTokens.labelColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: InspectorTokens.sectionSpacing) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            stepCard(step, index: index, isFirst: index == 0, isLast: index == steps.count - 1)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Animation sequence")
                }
            }

            Button {
                controller.previewSlideBuilds()
            } label: {
                Label("Preview Animation Build", systemImage: "play.fill")
                    .font(InspectorTokens.labelFont)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(previewDisabled)
            .accessibilityLabel("Preview animation build")
            .help("Play this element’s builds in the editor without taking the show live.")
        }
    }

    private var previewDisabled: Bool {
        selectedObject == nil || (selectedObject?.resolvedBuildSteps.isEmpty ?? true)
    }

    private func addButton(_ title: String, phase: BuildPhase) -> some View {
        Button(title) {
            editor.addBuildStep(phase: phase)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Add \(phase.title)")
    }

    @ViewBuilder
    private func stepCard(_ step: ElementBuildStep, index: Int, isFirst: Bool, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: InspectorTokens.rowSpacing) {
            HStack(spacing: 8) {
                Image(systemName: phaseSymbol(step.phase))
                    .font(InspectorTokens.iconFont)
                    .foregroundStyle(phaseColor(step.phase))
                    .accessibilityHidden(true)
                Text("\(index + 1). \(step.phase.title)")
                    .font(InspectorTokens.sectionHeaderFont)
                    .foregroundColor(InspectorTokens.headerColor)
                Spacer(minLength: 0)
                Button {
                    editor.moveBuildStep(id: step.id, by: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(InspectorTokens.iconFont)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .disabled(isFirst)
                .help("Move step earlier")
                .accessibilityLabel("Move \(step.phase.title) earlier")
                Button {
                    editor.moveBuildStep(id: step.id, by: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(InspectorTokens.iconFont)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .disabled(isLast)
                .help("Move step later")
                .accessibilityLabel("Move \(step.phase.title) later")
                Button {
                    editor.removeBuildStep(id: step.id)
                } label: {
                    Image(systemName: "trash")
                        .font(InspectorTokens.iconFont)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("Remove step")
                .accessibilityLabel("Remove \(step.phase.title) step")
            }

            PropertyRow("Effect") {
                Picker("", selection: stepBinding(step, \.effect)) {
                    ForEach(AnimationEffectStyle.defaults(for: step.phase)) { effect in
                        Text(effect.title).tag(effect)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Effect")
            }

            PropertyRow("Trigger") {
                Picker("", selection: Binding(
                    get: { step.trigger.resolved(for: step.phase) },
                    set: { value in editor.updateBuildStep(id: step.id) { $0.trigger = value } }
                )) {
                    ForEach(BuildTriggerMode.cases(for: step.phase)) { mode in
                        Text(mode.title(for: step.phase)).tag(mode)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Trigger")
            }

            if step.effect == .infiniteMarqueeHorizontal {
                PropertyRow("Speed") {
                    InspectorNumericField(value: stepBinding(step, \.marqueeSpeedPxPerSec), unit: "px/s")
                }
                PropertyRow("Gap") {
                    InspectorNumericField(value: stepBinding(step, \.marqueeGapPx), unit: "px")
                }
                PropertyRow("Direction") {
                    Picker("", selection: Binding(
                        get: { step.marqueeDirectionLeft },
                        set: { value in editor.updateBuildStep(id: step.id) { $0.marqueeDirectionLeft = value } }
                    )) {
                        Text("Left").tag(true)
                        Text("Right").tag(false)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Marquee direction")
                }
            } else if step.effect == .continuousRotate {
                PropertyRow("Period") {
                    InspectorNumericField(value: stepBinding(step, \.durationSeconds), unit: "s")
                }
            } else {
                PropertyRow("Duration") {
                    InspectorNumericField(value: stepBinding(step, \.durationSeconds), unit: "s")
                }
                PropertyRow("Delay") {
                    InspectorNumericField(value: stepBinding(step, \.delaySeconds), unit: "s")
                }
                PropertyRow("Easing") {
                    Picker("", selection: stepBinding(step, \.easing)) {
                        ForEach(EasingCurveStyle.allCases) { curve in
                            Text(curve.title).tag(curve)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Easing")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func stepBinding<Value>(_ step: ElementBuildStep, _ keyPath: WritableKeyPath<ElementBuildStep, Value>) -> Binding<Value> {
        Binding(
            get: {
                editor.selectedObjects.first?.buildSteps?.first(where: { $0.id == step.id })?[keyPath: keyPath] ?? step[keyPath: keyPath]
            },
            set: { value in
                editor.updateBuildStep(id: step.id) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func phaseSymbol(_ phase: BuildPhase) -> String {
        switch phase {
        case .buildIn: "arrow.down.right.circle.fill"
        case .action: "sparkles"
        case .buildOut: "arrow.up.forward.circle.fill"
        }
    }

    private func phaseColor(_ phase: BuildPhase) -> Color {
        switch phase {
        case .buildIn: Color(red: 0.23, green: 0.72, blue: 0.42)
        case .action: Color(red: 0.95, green: 0.72, blue: 0.18)
        case .buildOut: Color(red: 0.90, green: 0.32, blue: 0.32)
        }
    }
}
