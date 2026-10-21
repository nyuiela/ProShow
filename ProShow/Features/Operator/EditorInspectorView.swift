import SwiftUI

/// Context-aware Shape / Text / Build / Slide inspector.
struct EditorInspectorView: View {
    @Bindable var controller: ShowController
    @State private var lastHAlign: InspectorHAlign = .center
    @State private var lastVAlign: InspectorVAlign = .middle
    @State private var lastDistribute: InspectorDistribute = .horizontal
    @State private var dataLinkDomain: DataLinkDomain = .outline
    @State private var dataLinkDurationFormat = CountdownFormatCatalog.default
    @State private var dataLinkClockFormat = "h:mm:ss a"
    @State private var dataLinkAgendaCount = 3
    @State private var dataLinkGraphKey = ""

    private var editor: EditorEngine { controller.editors }

    var body: some View {
        let _ = editor.documents
        let _ = editor.selectedObjectIDs
        VStack(spacing: 0) {
            SidebarTitleGroupSlot(alignment: .trailing) {
                InspectorTitleGroup(controller: controller)
            }
            inspectorTabs
            ScrollView {
                VStack(alignment: .leading, spacing: InspectorTokens.sectionSpacing) {
                    switch editor.inspectorTab {
                    case .shape:
                        shapeInspector
                    case .text:
                        textInspector
                    case .build:
                        BuildInspectorView(controller: controller)
                    case .slide:
                        slideInspector
                    }
                }
                .padding(InspectorTokens.horizontalPadding)
            }
            if editor.kind == .presentation {
                slideFooter
            }
        }
        .frame(width: InspectorTokens.panelWidth)
        .background(ProShowTheme.panel)
        .focusEffectDisabled()
    }

    private var inspectorTabs: some View {
        HStack(spacing: 0) {
            ForEach(EditorInspectorTab.allCases) { tab in
                Button {
                    editor.inspectorTab = tab
                } label: {
                    Text(tab.title)
                        .font(InspectorTokens.sectionHeaderFont)
                        .foregroundColor(editor.inspectorTab == tab ? InspectorTokens.headerColor : InspectorTokens.labelColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: InspectorTokens.headerHeight)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(editor.inspectorTab == tab ? InspectorTokens.activeAccent : Color.clear)
                                .frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(editor.inspectorTab == tab ? .isSelected : [])
            }
        }
        .background(ProShowTheme.canvas)
    }

    private var slideFooter: some View {
        HStack(spacing: 8) {
            Button("Slide Notes") { editor.inspectorTab = .slide }
            Button("Show") { controller.pushEditorLive() }
        }
        .buttonStyle(.plain)
        .font(InspectorTokens.labelFont)
        .foregroundColor(InspectorTokens.labelColor)
        .frame(maxWidth: .infinity)
        .frame(height: InspectorTokens.headerHeight)
        .background(ProShowTheme.canvas)
    }

    @ViewBuilder
    private var shapeInspector: some View {
        if editor.selectedObjects.isEmpty {
            emptyHint("Select an object to edit shape properties.")
        } else {
            if editor.selectedObjects.allSatisfy({ $0.kind == .qrCode }) {
                InspectorSection("QR Code") {
                    PropertyRow("Payload") {
                        TextField(
                            "URL, text, or {Field}",
                            text: qrCodePayloadBinding,
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                    }
                    Text("Use {segment.link} for the current outline URL, or other data linkage tokens at show time.")
                        .font(InspectorTokens.labelFont)
                        .foregroundStyle(InspectorTokens.labelColor)
                }
            }

            InspectorSection("Source") {
                PropertyRow("Assigned") {
                    Text(editor.selectedObjects.count == 1
                         ? (editor.selectedObjects.first?.sourceSummary ?? "None")
                         : "Mixed")
                        .font(InspectorTokens.labelFont)
                        .foregroundColor(InspectorTokens.headerColor)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Button("Assign…") { controller.openAddShotToAssign() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(editor.selectedObjects.allSatisfy(\.isTextLike))
                    if editor.selectedObjects.contains(where: { $0.assignedSource != nil || !$0.fill.imageURI.isEmpty }) {
                        Button("Clear") { controller.clearAssignedSourceOnSelectedObjects() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
                if editor.selectedObjects.contains(where: \.canCarryAudio) {
                    PropertyRow("Mute Audio") {
                        Toggle("", isOn: Binding(
                            get: {
                                let audible = editor.selectedObjects.filter(\.canCarryAudio)
                                return !audible.isEmpty && audible.allSatisfy(\.isAudioMuted)
                            },
                            set: { controller.setSelectedObjectsAudioMuted($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Mute audio")
                    }
                }
            }

            if editor.selectedObjects.contains(where: \.isMediaLike) {
                InspectorSection("Media Frame") {
                    mediaFrameControls
                }
            }

            InspectorSection("Transform") {
                BoundsMatrixInput(
                    x: objectDouble(\.transform.x),
                    y: objectDouble(\.transform.y),
                    width: Binding(
                        get: { common(\.transform.width) ?? 0 },
                        set: { editor.setSelectedWidth($0) }
                    ),
                    height: Binding(
                        get: { common(\.transform.height) ?? 0 },
                        set: { editor.setSelectedHeight($0) }
                    ),
                    keepAspectRatio: objectToggle(\.transform.lockAspectRatio)
                )

                RadialAngleInput(angleDegrees: objectDouble(\.transform.rotation))

                PropertyRow("Flip") {
                    HStack(spacing: 4) {
                        inspectorIconButton(
                            "arrow.left.and.right.righttriangle.left.righttriangle.right",
                            selected: common(\.transform.flipHorizontal) == true
                        ) {
                            editor.mutateSelectedObjects { $0.transform.flipHorizontal.toggle() }
                        }
                        .help("Flip Horizontal")
                        inspectorIconButton(
                            "arrow.up.and.down.righttriangle.up.righttriangle.down",
                            selected: common(\.transform.flipVertical) == true
                        ) {
                            editor.mutateSelectedObjects { $0.transform.flipVertical.toggle() }
                        }
                        .help("Flip Vertical")
                    }
                }
            }

            AlignmentToolbarView(editor: editor)

            InspectorSection("Fill & Stroke") {
                PropertyRow("Fill Style") {
                    Picker("", selection: Binding(
                        get: { common(\.fill.type) ?? .color },
                        set: { value in editor.mutateSelectedObjects { $0.fill.type = value } }
                    )) {
                        Text("Solid").tag(ElementFillType.color)
                        Text("Gradient").tag(ElementFillType.gradient)
                        Text("Image").tag(ElementFillType.image)
                        Text("None").tag(ElementFillType.none)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                if (common(\.fill.type) ?? .color) == .color {
                    PropertyRow("Fill Color") {
                        CompactColorSwatch(
                            color: hexColor(common(\.fill.color) ?? "#FFFFFF") { value in
                                editor.mutateSelectedObjects { $0.fill.color = value }
                            },
                            accessibilityLabel: "Fill color"
                        )
                    }
                }

                if common(\.fill.type) == .gradient {
                    PropertyRow("Kind") {
                        Picker("", selection: Binding(
                            get: { common(\.fill.gradientType) ?? .linear },
                            set: { value in editor.mutateSelectedObjects { $0.fill.gradientType = value } }
                        )) {
                            ForEach(GradientKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    PropertyRow("Start") {
                        CompactColorSwatch(
                            color: hexColor(editor.selectedObjects.first?.fill.gradientStops.first?.color ?? "#000000") { value in
                            editor.mutateSelectedObjects {
                                if $0.fill.gradientStops.isEmpty {
                                    $0.fill.gradientStops = [GradientStop(offset: 0, color: value)]
                                } else {
                                    $0.fill.gradientStops[0].color = value
                                }
                            }
                            },
                            accessibilityLabel: "Gradient start color"
                        )
                    }
                    PropertyRow("End") {
                        CompactColorSwatch(
                            color: hexColor(editor.selectedObjects.first?.fill.gradientStops.last?.color ?? "#FFFFFF") { value in
                            editor.mutateSelectedObjects {
                                if $0.fill.gradientStops.count < 2 {
                                    $0.fill.gradientStops.append(GradientStop(offset: 1, color: value))
                                } else {
                                    $0.fill.gradientStops[$0.fill.gradientStops.count - 1].color = value
                                }
                            }
                            },
                            accessibilityLabel: "Gradient end color"
                        )
                    }
                    NumericSliderRow(label: "Angle", value: objectDouble(\.fill.gradientAngle), range: 0...360, step: 5, unit: "°")
                }

                if common(\.fill.type) == .image {
                    PropertyRow("Image") {
                        TextField("file or URI", text: Binding(
                            get: { common(\.fill.imageURI) ?? "" },
                            set: { value in editor.mutateSelectedObjects { $0.fill.imageURI = value } }
                        ))
                        .font(InspectorTokens.labelFont)
                        .textFieldStyle(.squareBorder)
                        .controlSize(.small)
                        .frame(width: 140)
                    }
                    HStack {
                        Button("Choose from Library…") { controller.openAddShotToAssign() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Spacer(minLength: 0)
                    }
                    PropertyRow("Live source") {
                        Picker("", selection: Binding(
                            get: { editor.selectedObjects.first?.imageBinding ?? "" },
                            set: { value in editor.mutateSelectedObjects { $0.imageBinding = value.isEmpty ? nil : value } }
                        )) {
                            Text("This image").tag("")
                            Text("Chat avatar").tag("chat.avatar")
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 140)
                        .help("Chat avatar: while a chat message is on screen, show the sender's picture here. This image is used when there is none.")
                        .accessibilityLabel("Image live source")
                    }
                }

                ScrubbableComboInput(
                    label: "Fill",
                    value: percentBinding(common(\.fill.opacity) ?? 1) { value in
                        editor.mutateSelectedObjects { $0.fill.opacity = value }
                    },
                    range: 0...100,
                    step: 1,
                    unit: "%"
                )

                PropertyRow("Stroke") {
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(
                            get: { common(\.stroke.style) ?? .none },
                            set: { value in editor.mutateSelectedObjects { $0.stroke.style = value } }
                        )) {
                            ForEach(StrokeStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(maxWidth: 88)

                        CompactColorSwatch(
                            color: hexColor(common(\.stroke.color) ?? "#FFFFFF") { value in
                                editor.mutateSelectedObjects { $0.stroke.color = value }
                            },
                            size: 20,
                            accessibilityLabel: "Stroke color"
                        )

                        ScrubbableComboInput(
                            label: "W",
                            value: objectDouble(\.stroke.width),
                            range: 0.5...100,
                            step: 0.5,
                            unit: "pt",
                            labelWidth: 14,
                            fieldWidth: 40
                        )
                    }
                }
                PropertyRow("Position") {
                    Picker("", selection: Binding(
                        get: { common(\.stroke.position) ?? .outside },
                        set: { value in editor.mutateSelectedObjects { $0.stroke.position = value } }
                    )) {
                        ForEach(StrokePosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                ScrubbableComboInput(
                    label: "Radius",
                    value: Binding(
                        get: { common(\.stroke.cornerRadius) ?? 0 },
                        set: { value in
                            editor.mutateSelectedObjectsFromInspector { object in
                                object.stroke.cornerRadius = value
                                object.stroke.corners = .uniform(value)
                                if object.kind == .rectangle, value > 0 {
                                    object.kind = .roundedRectangle
                                }
                            }
                        }
                    ),
                    range: 0...max(50, (common(\.transform.width) ?? 200) / 2),
                    step: 1,
                    unit: "px"
                )
                PropertyRow("Cap") {
                    Picker("", selection: Binding(
                        get: { commonOptional(\.stroke.cap) ?? .butt },
                        set: { value in editor.mutateSelectedObjects { $0.stroke.cap = value } }
                    )) {
                        ForEach(StrokeCap.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Join") {
                    Picker("", selection: Binding(
                        get: { commonOptional(\.stroke.join) ?? .miter },
                        set: { value in editor.mutateSelectedObjects { $0.stroke.join = value } }
                    )) {
                        ForEach(StrokeJoin.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                NumericSliderRow(
                    label: "Smooth",
                    value: Binding(
                        get: { (commonOptional(\.stroke.cornerSmoothing) ?? 0) * 100 },
                        set: { value in
                            editor.beginUndoGroup()
                            editor.setCornerSmoothing(value / 100)
                            editor.scheduleEndUndoGroup()
                        }
                    ),
                    range: 0...100,
                    step: 1,
                    unit: "%"
                )
            }

            InspectorSection("Auto Layout") {
                PropertyRow("Auto Layout") {
                    Toggle("", isOn: Binding(
                        get: { editor.selectedObjects.first?.autoLayout?.enabled == true },
                        set: { _ in editor.applyAutoLayout() }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Direction") {
                    Picker("", selection: Binding(
                        get: { editor.selectedObjects.first?.autoLayout?.direction ?? .horizontal },
                        set: { value in
                            editor.mutateSelectedObjects {
                                var layout = $0.autoLayout ?? .default
                                layout.direction = value
                                $0.autoLayout = layout
                            }
                            editor.applyAutoLayout()
                        }
                    )) {
                        ForEach(AutoLayoutDirection.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                NumericSliderRow(
                    label: "Gap",
                    value: Binding(
                        get: { editor.selectedObjects.first?.autoLayout?.gap ?? 12 },
                        set: { value in
                            editor.beginUndoGroup()
                            editor.mutateSelectedObjects {
                                var layout = $0.autoLayout ?? .default
                                layout.gap = value
                                $0.autoLayout = layout
                            }
                            editor.applyAutoLayout()
                            editor.scheduleEndUndoGroup()
                        }
                    ),
                    range: 0...120,
                    step: 1,
                    unit: "px"
                )
            }

            InspectorSection("Blend") {
                PropertyRow("Blend") {
                    Picker("", selection: Binding(
                        get: { commonOptional(\.blendMode) ?? .normal },
                        set: { value in editor.mutateSelectedObjects { $0.blendMode = value } }
                    )) {
                        ForEach(LayerBlendMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Clip Below") {
                    Toggle("", isOn: Binding(
                        get: { editor.selectedObjects.first?.clipToBelow == true },
                        set: { value in editor.mutateSelectedObjects { $0.clipToBelow = value } }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            InspectorSection("Effects") {
                InlineOpacityField(
                    percent: percentBinding(common(\.opacity) ?? 1) { value in
                        editor.mutateSelectedObjects { $0.opacity = value }
                    }
                )
                PropertyRow("Drop Shadow") {
                    Toggle("", isOn: objectToggle(\.shadow.enabled))
                        .labelsHidden()
                        .controlSize(.small)
                }
                if common(\.shadow.enabled) == true {
                    PropertyRow("Shadow Color") {
                        ColorPicker("", selection: hexColor(common(\.shadow.color) ?? "#80000000", includeAlpha: true) { value in
                            editor.mutateSelectedObjects { $0.shadow.color = value }
                        })
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    NumericSliderRow(label: "Blur", value: objectDouble(\.shadow.blur), range: 0...30, step: 1, unit: "px")
                    NumericSliderRow(label: "Angle", value: objectDouble(\.shadow.angle), range: 0...360, step: 5, unit: "°")
                    NumericSliderRow(label: "Offset", value: objectDouble(\.shadow.offset), range: 0...200, step: 1, unit: "px")
                    NumericSliderRow(label: "Feather", value: objectDouble(\.shadow.feather), range: 0...40, step: 1, unit: "px")
                }
                PropertyRow("Shimmer") {
                    Toggle("", isOn: shimmerEnabledBinding)
                        .labelsHidden()
                        .controlSize(.small)
                }
                if shimmerEnabledBinding.wrappedValue {
                    NumericSliderRow(
                        label: "Cycle",
                        value: shimmerDoubleBinding(\.cycleDuration),
                        range: 0.8...6,
                        step: 0.1,
                        unit: "s"
                    )
                    NumericSliderRow(label: "Intensity", value: shimmerPercentBinding(\.intensity), range: 0...100, step: 1, unit: "%")
                    NumericSliderRow(label: "Band", value: shimmerPercentBinding(\.bandWidth, scale: 100), range: 5...85, step: 1, unit: "%")
                    NumericSliderRow(label: "Angle", value: shimmerDoubleBinding(\.angle), range: -90...90, step: 5, unit: "°")
                    PropertyRow("Highlight") {
                        ColorPicker("", selection: shimmerColorBinding)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
                PropertyRow("Hide Audience") {
                    Toggle("", isOn: invertedToggle(\.visibleOnAudience))
                        .labelsHidden()
                        .controlSize(.small)
                }
                PropertyRow("Hide Stage") {
                    Toggle("", isOn: invertedToggle(\.visibleOnStage))
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
        }
    }

    private var themeSlotInspector: some View {
        InspectorSection("Theme Slot") {
            PropertyRow("Role") {
                Picker("", selection: themeSlotBinding) {
                    Text("Auto").tag(Optional<ThemeSlotRole>.none)
                    ForEach(ThemeSlotRole.allCases.filter { $0 != .decor }, id: \.self) { role in
                        Text(themeSlotLabel(role)).tag(Optional(role))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            Text("Maps slide text onto this placeholder when the variant is applied at cue time.")
                .font(.system(size: 10))
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var themeSlotBinding: Binding<ThemeSlotRole?> {
        Binding(
            get: { editor.commonValue(\.themeSlot) ?? nil },
            set: { value in editor.mutateSelectedObjects { $0.themeSlot = value } }
        )
    }

    private func themeSlotLabel(_ role: ThemeSlotRole) -> String {
        switch role {
        case .primaryBody: "Primary text"
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .secondaryBody: "Secondary body"
        case .reference: "Reference"
        case .speakerName: "Speaker name"
        case .speakerRole: "Speaker role"
        case .decor: "Decor"
        }
    }

    @ViewBuilder
    private var textInspector: some View {
        if editor.selectedObjects.isEmpty {
            emptyHint("Select a text object to edit typography.")
        } else {
            if editor.kind == .theme {
                themeSlotInspector
            }
            if editor.selectedObjects.contains(where: { $0.kind.usesLiveText || $0.kind == .text }) {
                liveContentInspector
            }
            InspectorSection("Style") {
                HStack(spacing: 6) {
                    Button("Copy Style") { editor.copySelectedTextStyle() }
                        .controlSize(.small)
                    Button("Paste Style") { editor.pasteSelectedTextStyle() }
                        .controlSize(.small)
                        .disabled(!editor.canPasteTextStyle)
                    Spacer(minLength: 0)
                }

                PropertyRow("Font") {
                    Picker("", selection: Binding(
                        get: { common(\.typography.fontFamily) ?? "Arial" },
                        set: { value in editor.mutateSelectedObjects { $0.typography.fontFamily = value } }
                    )) {
                        ForEach(SystemFontCatalog.menu(including: common(\.typography.fontFamily)), id: \.self) { name in
                            Text(name)
                                .font(.custom(name, size: 13))
                                .tag(name)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .id("Font-\(editor.selectedObjectIDs)")
                }

                PropertyRow("Weight") {
                    Picker("", selection: Binding(
                        get: { common(\.typography.fontWeight) ?? .regular },
                        set: { value in
                            editor.mutateSelectedObjects {
                                $0.typography.fontWeight = value
                                $0.typography.isBold = (value == .bold || value == .black || value == .semibold)
                            }
                        }
                    )) {
                        ForEach(FontWeightToken.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                ScrubbableComboInput(
                    label: "Size",
                    value: objectDouble(\.typography.fontSize),
                    range: 1...400,
                    step: 1,
                    unit: "pt",
                    presets: [12, 14, 18, 24, 32, 48, 72, 96, 120, 144]
                )

                PropertyRow("Emphasis") {
                    HStack(spacing: 2) {
                        inspectorIconButton("bold", selected: editor.commonValue(\.typography.isBold) ?? false) {
                            editor.mutateSelectedObjects { $0.typography.isBold.toggle() }
                        }
                        .help("Bold")
                        inspectorIconButton("italic", selected: editor.commonValue(\.typography.isItalic) ?? false) {
                            editor.mutateSelectedObjects { $0.typography.isItalic.toggle() }
                        }
                        .help("Italic")
                        inspectorIconButton("underline", selected: editor.commonValue(\.typography.isUnderline) ?? false) {
                            editor.mutateSelectedObjects { $0.typography.isUnderline.toggle() }
                        }
                        .help("Underline")
                        inspectorIconButton("strikethrough", selected: editor.commonValue(\.typography.isStrikethrough) ?? false) {
                            editor.mutateSelectedObjects { $0.typography.isStrikethrough.toggle() }
                        }
                        .help("Strikethrough")
                    }
                    .padding(2)
                    .background(InspectorTokens.controlBackground)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(InspectorTokens.dividerColor, lineWidth: 0.5))
                }

                PropertyRow("Caps") {
                    Picker("", selection: Binding(
                        get: { common(\.typography.textTransform) ?? .none },
                        set: { value in editor.mutateSelectedObjects { $0.typography.textTransform = value } }
                    )) {
                        ForEach(TextTransformToken.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }

                PropertyRow("Color") {
                    CompactColorSwatch(
                        color: hexColor(common(\.typography.color) ?? "#FFFFFF") { value in
                            editor.mutateSelectedObjects { $0.typography.color = value }
                        },
                        accessibilityLabel: "Text color"
                    )
                }
            }

            InspectorSection("Spacing") {
                HStack(spacing: 8) {
                    ScrubbableComboInput(
                        label: "Line",
                        value: objectDouble(\.textLayout.lineHeight),
                        range: 0.5...4,
                        step: 0.05,
                        unit: "×",
                        fractionDigits: 2,
                        labelWidth: 32,
                        fieldWidth: 42
                    )
                    ScrubbableComboInput(
                        label: "Track",
                        value: objectDouble(\.textLayout.characterSpacing),
                        range: -20...40,
                        step: 0.5,
                        unit: "pt",
                        fractionDigits: 1,
                        labelWidth: 36,
                        fieldWidth: 42
                    )
                }
                NumericSliderRow(
                    label: "Word Spacing",
                    value: objectDouble(\.textLayout.wordSpacing),
                    range: -10...60,
                    step: 0.5,
                    unit: "pt"
                )
                NumericSliderRow(
                    label: "Space Before",
                    value: objectDouble(\.textLayout.paragraphSpacingBefore),
                    range: 0...80,
                    step: 1,
                    unit: "pt"
                )
                NumericSliderRow(
                    label: "Space After",
                    value: objectDouble(\.textLayout.paragraphSpacingAfter),
                    range: 0...80,
                    step: 1,
                    unit: "pt"
                )
                NumericSliderRow(
                    label: "First Line Indent",
                    value: layoutOptionalDouble(\.firstLineIndent),
                    range: 0...120,
                    step: 1,
                    unit: "pt"
                )
                PropertyRow("Inset Top") {
                    insetField(\.top)
                }
                PropertyRow("Inset Bottom") {
                    insetField(\.bottom)
                }
                PropertyRow("Inset Left") {
                    insetField(\.left)
                }
                PropertyRow("Inset Right") {
                    insetField(\.right)
                }
            }

            InspectorSection("Layout") {
                PropertyRow("Scaling") {
                    Picker("", selection: Binding(
                        get: { common(\.textLayout.autoFitMode) ?? .none },
                        set: { value in editor.mutateSelectedObjects { $0.textLayout.autoFitMode = value } }
                    )) {
                        ForEach(TextAutoFitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Lines") {
                    Picker("", selection: Binding(
                        get: { commonOptional(\.textLayout.lineTransform) ?? .none },
                        set: { value in editor.mutateSelectedObjects { $0.textLayout.lineTransform = value } }
                    )) {
                        ForEach(TextLineTransform.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Align") {
                    IconSegmentedPicker(selection: Binding(
                        get: { common(\.textLayout.horizontalAlign) ?? .center },
                        set: { value in editor.mutateSelectedObjects { $0.textLayout.horizontalAlign = value } }
                    ), options: [
                        .init(value: .left, iconName: "text.alignleft", tooltip: "Align left"),
                        .init(value: .center, iconName: "text.aligncenter", tooltip: "Align center"),
                        .init(value: .right, iconName: "text.alignright", tooltip: "Align right"),
                        .init(value: .justify, iconName: "text.justify", tooltip: "Justify")
                    ])
                }
                PropertyRow("Vertical") {
                    IconSegmentedPicker(selection: Binding(
                        get: { common(\.textLayout.verticalAlign) ?? .middle },
                        set: { value in editor.mutateSelectedObjects { $0.textLayout.verticalAlign = value } }
                    ), options: [
                        .init(value: .top, iconName: "arrow.up.to.line", tooltip: "Top"),
                        .init(value: .middle, iconName: "arrow.up.and.down", tooltip: "Middle"),
                        .init(value: .bottom, iconName: "arrow.down.to.line", tooltip: "Bottom")
                    ])
                }
                PropertyRow("Stroke") {
                    Toggle("", isOn: objectToggle(\.textOutline.enabled))
                        .labelsHidden()
                        .controlSize(.small)
                }
                if common(\.textOutline.enabled) == true {
                    PropertyRow("Stroke Color") {
                        ColorPicker("", selection: hexColor(common(\.textOutline.color) ?? "#000000") { value in
                            editor.mutateSelectedObjects { $0.textOutline.color = value }
                        })
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    NumericSliderRow(label: "Stroke", value: objectDouble(\.textOutline.width), range: 0.5...20, step: 0.5, unit: "pt")
                }
                PropertyRow("Shadow") {
                    Toggle("", isOn: objectToggle(\.textShadow.enabled))
                        .labelsHidden()
                        .controlSize(.small)
                }
                if common(\.textShadow.enabled) == true {
                    PropertyRow("Shadow Color") {
                        ColorPicker("", selection: hexColor(common(\.textShadow.color) ?? "#CC000000", includeAlpha: true) { value in
                            editor.mutateSelectedObjects { $0.textShadow.color = value }
                        })
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    NumericSliderRow(label: "Blur", value: objectDouble(\.textShadow.blur), range: 0...40, step: 0.5, unit: "px")
                }
                PropertyRow("Lines Only") {
                    Toggle("", isOn: layoutFlag(\.linesOnly))
                        .labelsHidden()
                        .controlSize(.small)
                }
                PropertyRow("List") {
                    Toggle("", isOn: Binding(
                        get: { (common(\.textLayout.listType) ?? .none) != .none },
                        set: { on in editor.mutateSelectedObjects { $0.textLayout.listType = on ? .bullet : .none } }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Linked") {
                    Toggle("", isOn: layoutFlag(\.linkedText))
                        .labelsHidden()
                        .controlSize(.small)
                }
                PropertyRow("Frame") {
                    Picker("", selection: Binding(
                        get: { commonOptional(\.textLayout.frameMode) ?? .fixed },
                        set: { value in editor.applyTextFrameMode(value) }
                    )) {
                        ForEach(TextFrameMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            InspectorSection("Loop") {
                PropertyRow("Loop Text") {
                    Toggle("", isOn: Binding(
                        get: { editor.selectedObjects.contains(where: \.textLayout.isLooping) },
                        set: { editor.setSelectedTextLooping($0) }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Loop text")
                }
                if editor.selectedObjects.contains(where: \.textLayout.isLooping) {
                    Text("Repeats the text forever inside this box. Use Left for a price ticker, Up for a long list.")
                        .font(InspectorTokens.labelFont)
                        .foregroundStyle(InspectorTokens.labelColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if editor.selectedObjects.contains(where: { $0.kind != .liveQuote }) {
                        PropertyRow("Live prices") {
                            Toggle("", isOn: Binding(
                                get: { editor.selectedObjects.contains(where: \.textLayout.resolvedMarketTickerStrip) },
                                set: { enabled in
                                    editor.mutateSelectedObjects { $0.textLayout.marketTickerStrip = enabled }
                                }
                            ))
                            .labelsHidden()
                            .controlSize(.small)
                            .accessibilityLabel("Live prices with green and red change colors")
                        }
                        Text("Polls live quotes (same as Live Quote objects). Put symbols in the text box as comma-separated tickers, e.g. AAPL, BTC, ETH.")
                            .font(InspectorTokens.labelFont)
                            .foregroundStyle(InspectorTokens.labelColor)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Optional: turn Loop on for a scrolling ticker. Live prices and green ▲ / red ▼ updates work with Loop off too.")
                            .font(InspectorTokens.labelFont)
                            .foregroundStyle(InspectorTokens.labelColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PropertyRow("Direction") {
                        Picker("", selection: Binding(
                            get: { editor.selectedObjects.first?.textLayout.resolvedLoopDirection ?? .left },
                            set: { value in editor.mutateSelectedObjects { $0.textLayout.loopDirection = value } }
                        )) {
                            ForEach(TextLoopDirection.allCases) { direction in
                                Text(direction.title).tag(direction)
                            }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel("Loop direction")
                    }
                    NumericSliderRow(
                        label: "Speed",
                        value: layoutDouble(\.loopSpeedPxPerSec, default: 80),
                        range: 8...400,
                        step: 4,
                        unit: "px/s"
                    )
                    NumericSliderRow(
                        label: "Gap",
                        value: layoutDouble(\.loopGapPx, default: 80),
                        range: 0...400,
                        step: 4,
                        unit: "px"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var slideInspector: some View {
        InspectorSection("Canvas") {
            PropertyRow("Display") {
                Picker("", selection: Binding<CanvasResolution?>(
                    get: {
                        let frame = editor.activeCanvasFrame()
                        return CanvasResolution.exact(
                            width: frame?.width ?? editor.selectedDocument?.canvasWidth ?? CanvasConfig.width,
                            height: frame?.height ?? editor.selectedDocument?.canvasHeight ?? CanvasConfig.height
                        )
                    },
                    set: { resolution in
                        guard let resolution else { return }
                        editor.setActiveCanvasSize(width: resolution.size.width, height: resolution.size.height)
                    }
                )) {
                    if CanvasResolution.exact(
                        width: editor.activeCanvasFrame()?.width ?? editor.selectedDocument?.canvasWidth ?? CanvasConfig.width,
                        height: editor.activeCanvasFrame()?.height ?? editor.selectedDocument?.canvasHeight ?? CanvasConfig.height
                    ) == nil {
                        let width = Int((editor.activeCanvasFrame()?.width ?? editor.selectedDocument?.canvasWidth ?? CanvasConfig.width).rounded())
                        let height = Int((editor.activeCanvasFrame()?.height ?? editor.selectedDocument?.canvasHeight ?? CanvasConfig.height).rounded())
                        Text("Custom \(width) × \(height)").tag(CanvasResolution?.none)
                    }
                    ForEach(CanvasResolution.allCases) { resolution in
                        Text(resolution.menuTitle).tag(Optional(resolution))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Canvas size")
            }
        }
        InspectorSection("Background") {
            PropertyRow("Enabled") {
                Toggle("", isOn: Binding(
                    get: { editor.activeCanvasFrame()?.backgroundEnabled ?? true },
                    set: { enabled in
                        editor.updateActiveCanvas { $0.backgroundEnabled = enabled }
                    }
                ))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Background")
            }
            PropertyRow("Color") {
                ColorPicker("", selection: hexColor(editor.activeCanvasFrame()?.backgroundHex ?? "#000000", requiresObjectSelection: false) { value in
                    editor.updateActiveCanvas {
                        $0.backgroundHex = value
                        $0.backgroundEnabled = true
                    }
                })
                .labelsHidden()
                .controlSize(.small)
            }
            if editor.activeCanvasFrame()?.backgroundEnabled == false {
                Text("Transparent. Program media stays on output.")
                    .font(InspectorTokens.labelFont)
                    .foregroundStyle(InspectorTokens.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .accessibilityLabel("Transparent background. Program media stays on output.")
            }
        }
        InspectorSection("Transition") {
            PropertyRow("Style") {
                TransitionPickerView(
                    selection: Binding(
                        get: { editor.selectedDocument?.transition ?? "cut" },
                        set: { value in
                            let preset = TransitionCatalog.preset(id: value)
                            controller.applyTransitionPreset(preset, workspace: .slideInspector)
                        }
                    ),
                    compact: true
                )
            }
            NumericSliderRow(
                label: "Duration",
                value: Binding(
                    get: { editor.selectedDocument?.transitionDuration ?? 0 },
                    set: { value in
                        editor.mutateSelectedDocumentFromInspector { $0.transitionDuration = value }
                        controller.slideTransitionSeconds = value
                    }
                ),
                range: 0...10,
                step: 0.1,
                unit: "s"
            )
        }
        liveFieldsInspector
        InspectorSection("Notes") {
            TextField("Enter speaker prompts or cue notes here...", text: Binding(
                get: { editor.selectedDocument?.notes ?? "" },
                set: { value in editor.mutateSelectedDocument { $0.notes = value } }
            ), axis: .vertical)
            .font(InspectorTokens.labelFont)
            .textFieldStyle(.squareBorder)
            .controlSize(.small)
            .lineLimit(4...8)
        }
        extraDocumentFields
    }

    @ViewBuilder
    private var extraDocumentFields: some View {
        switch editor.kind {
        case .ccli, .presentation:
            InspectorSection("Copyright") {
                PropertyRow("On Screen") {
                    Toggle("", isOn: Binding(
                        get: { editor.copyright.showOnScreen },
                        set: { editor.copyright.showOnScreen = $0 }
                    ))
                    .labelsHidden()
                    .controlSize(.small)
                }
                copyrightField("Title", \.title)
                copyrightField("Artist", \.artist)
                copyrightField("CCLI #", \.ccliNumber)
            }
        case .theme:
            InspectorSection("Media Action") {
                HStack {
                    Button("Add Motion Background") { editor.bindMediaAction("Motion Background") }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        case .props:
            InspectorSection("Auto-Clear") {
                PropertyRow("Rule") {
                    Picker("", selection: Binding(
                        get: { editor.selectedDocument?.autoClear ?? "Never" },
                        set: { value in editor.mutateSelectedDocument { $0.autoClear = value } }
                    )) {
                        ForEach(EditorCatalog.autoClearRules, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        case .masks:
            InspectorSection("Mask") {
                PropertyRow("Invert") {
                    Toggle("", isOn: documentToggle(\.invertMask))
                        .labelsHidden()
                        .controlSize(.small)
                }
            }
        default:
            EmptyView()
        }
    }

    private func copyrightField(_ title: String, _ keyPath: WritableKeyPath<CopyrightInfo, String>) -> some View {
        PropertyRow(title) {
            TextField(title, text: Binding(
                get: { editor.copyright[keyPath: keyPath] },
                set: { editor.copyright[keyPath: keyPath] = $0 }
            ))
            .font(InspectorTokens.labelFont)
            .textFieldStyle(.squareBorder)
            .controlSize(.small)
            .frame(width: 140)
        }
    }

    @ViewBuilder
    private var mediaFrameControls: some View {
        PropertyRow("Scale") {
            Picker("Media scale", selection: Binding(
                get: { common(\.fill.imageScaleMode) ?? .fill },
                set: { value in editor.mutateSelectedObjects { $0.fill.imageScaleMode = value } }
            )) {
                ForEach(ImageScaleMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Media scale")
        }
        Text(scaleModeHelp)
            .font(.system(size: 10))
            .foregroundColor(InspectorTokens.labelColor)
            .fixedSize(horizontal: false, vertical: true)
        if (common(\.fill.imageScaleMode) ?? .fill) == .crop {
            NumericSliderRow(
                label: "Crop X",
                value: percentBinding(commonOptional(\.fill.cropX) ?? 0.5) { value in
                    editor.mutateSelectedObjects { $0.fill.cropX = value }
                },
                range: 0...100,
                step: 1,
                unit: "%"
            )
            NumericSliderRow(
                label: "Crop Y",
                value: percentBinding(commonOptional(\.fill.cropY) ?? 0.5) { value in
                    editor.mutateSelectedObjects { $0.fill.cropY = value }
                },
                range: 0...100,
                step: 1,
                unit: "%"
            )
            NumericSliderRow(
                label: "Crop Zoom",
                value: Binding(
                    get: { commonOptional(\.fill.cropZoom) ?? 1 },
                    set: { value in editor.mutateSelectedObjects { $0.fill.cropZoom = value } }
                ),
                range: 1...4,
                step: 0.05,
                unit: "×"
            )
        }
    }

    private var scaleModeHelp: String {
        switch common(\.fill.imageScaleMode) ?? .fill {
        case .fit: "Shows the whole picture. Empty edges stay empty."
        case .fill: "Covers the frame. Edges of the picture may be clipped."
        case .crop: "Zoom in, then pan with Crop X and Crop Y."
        case .tile: "Repeats the picture to fill the frame."
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(InspectorTokens.labelFont)
            .foregroundColor(InspectorTokens.labelColor)
            .padding(.top, 12)
    }

    private func inspectorIconButton(_ systemName: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(InspectorTokens.iconFont)
                .frame(width: InspectorTokens.iconButtonSize, height: InspectorTokens.iconButtonSize)
                .background(selected ? InspectorTokens.activeAccent : Color.clear)
                .foregroundColor(selected ? .white : InspectorTokens.headerColor)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func hexColor(
        _ hex: String,
        includeAlpha: Bool = false,
        requiresObjectSelection: Bool = true,
        set: @escaping (String) -> Void
    ) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex) ?? .white },
            set: { color in
                if requiresObjectSelection, editor.selectedObjectIDs.isEmpty { return }
                let next = color.hexString(includeAlpha: includeAlpha)
                guard next.caseInsensitiveCompare(hex) != .orderedSame else { return }
                editor.beginUndoGroup()
                set(next)
                editor.scheduleEndUndoGroup()
            }
        )
    }

    private func objectDouble(_ keyPath: WritableKeyPath<CanvasObject, Double>) -> Binding<Double> {
        Binding(
            get: { common(keyPath) ?? 0 },
            set: { value in
                editor.mutateSelectedObjectsFromInspector { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func percentBinding(_ value: Double, set: @escaping (Double) -> Void) -> Binding<Double> {
        Binding(
            get: { value * 100 },
            set: { next in
                editor.beginUndoGroup()
                set(next / 100)
                editor.scheduleEndUndoGroup()
            }
        )
    }

    private func layoutDouble(_ keyPath: WritableKeyPath<TextLayout, Double?>, default defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { editor.selectedObjects.first?.textLayout[keyPath: keyPath] ?? defaultValue },
            set: { value in
                editor.mutateSelectedObjectsFromInspector { $0.textLayout[keyPath: keyPath] = value }
            }
        )
    }

    private func layoutOptionalDouble(_ keyPath: WritableKeyPath<TextLayout, Double?>) -> Binding<Double> {
        Binding(
            get: { editor.selectedObjects.first?.textLayout[keyPath: keyPath] ?? 0 },
            set: { value in
                editor.mutateSelectedObjectsFromInspector {
                    $0.textLayout[keyPath: keyPath] = value > 0.001 ? value : nil
                }
            }
        )
    }

    private func insetField(_ keyPath: WritableKeyPath<TextBoxMargins, Double>) -> some View {
        TextField("", value: Binding(
            get: { editor.selectedObjects.first?.textLayout.margins[keyPath: keyPath] ?? 0 },
            set: { value in
                editor.mutateSelectedObjectsFromInspector {
                    $0.textLayout.margins[keyPath: keyPath] = max(0, value)
                }
            }
        ), format: .number.precision(.fractionLength(0...1)))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .frame(width: 56)
    }

    private func layoutFlag(_ keyPath: WritableKeyPath<TextLayout, Bool?>) -> Binding<Bool> {
        Binding(
            get: { editor.selectedObjects.first?.textLayout[keyPath: keyPath] ?? false },
            set: { value in
                editor.mutateSelectedObjects { $0.textLayout[keyPath: keyPath] = value }
            }
        )
    }

    private func common<T: Equatable>(_ keyPath: KeyPath<CanvasObject, T>) -> T? {
        editor.commonValue(keyPath)
    }

    private func commonOptional<T: Equatable>(_ keyPath: KeyPath<CanvasObject, T?>) -> T? {
        let values = editor.selectedObjects.map { $0[keyPath: keyPath] }
        guard let first = values.first else { return nil }
        guard values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    private func objectToggle(_ keyPath: WritableKeyPath<CanvasObject, Bool>) -> Binding<Bool> {
        Binding(
            get: { editor.commonValue(keyPath) ?? false },
            set: { value in
                guard !editor.selectedObjectIDs.isEmpty else { return }
                editor.mutateSelectedObjects { $0[keyPath: keyPath] = value }
            }
        )
    }

    private var shimmerEnabledBinding: Binding<Bool> {
        Binding(
            get: { editor.selectedObjects.contains(where: { $0.resolvedShimmer.enabled }) },
            set: { value in
                editor.mutateSelectedObjectsFromInspector { object in
                    var effect = object.resolvedShimmer
                    effect.enabled = value
                    object.shimmer = effect
                }
            }
        )
    }

    private func shimmerDoubleBinding(_ keyPath: WritableKeyPath<ElementShimmerEffect, Double>) -> Binding<Double> {
        Binding(
            get: { commonOptional(\.shimmer)?[keyPath: keyPath] ?? ElementShimmerEffect()[keyPath: keyPath] },
            set: { value in
                editor.mutateSelectedObjectsFromInspector { object in
                    var effect = object.resolvedShimmer
                    effect[keyPath: keyPath] = value
                    object.shimmer = effect
                }
            }
        )
    }

    private func shimmerPercentBinding(
        _ keyPath: WritableKeyPath<ElementShimmerEffect, Double>,
        scale: Double = 1
    ) -> Binding<Double> {
        Binding(
            get: {
                let raw = commonOptional(\.shimmer)?[keyPath: keyPath] ?? ElementShimmerEffect()[keyPath: keyPath]
                return raw * scale
            },
            set: { value in
                editor.mutateSelectedObjectsFromInspector { object in
                    var effect = object.resolvedShimmer
                    effect[keyPath: keyPath] = value / scale
                    object.shimmer = effect
                }
            }
        )
    }

    private var shimmerColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: commonOptional(\.shimmer)?.highlightColor ?? "#FFFFFF") ?? .white },
            set: { color in
                let hex = color.hexString()
                editor.mutateSelectedObjectsFromInspector { object in
                    var effect = object.resolvedShimmer
                    effect.highlightColor = hex
                    object.shimmer = effect
                }
            }
        )
    }

    private func invertedToggle(_ keyPath: WritableKeyPath<CanvasObject, Bool>) -> Binding<Bool> {
        Binding(
            get: { !(editor.commonValue(keyPath) ?? true) },
            set: { value in
                guard !editor.selectedObjectIDs.isEmpty else { return }
                editor.mutateSelectedObjects { $0[keyPath: keyPath] = !value }
            }
        )
    }

    private func documentToggle(_ keyPath: WritableKeyPath<EditorDocument, Bool>) -> Binding<Bool> {
        Binding(
            get: { editor.selectedDocument?[keyPath: keyPath] ?? false },
            set: { value in editor.mutateSelectedDocument { $0[keyPath: keyPath] = value } }
        )
    }

    @ViewBuilder
    private var liveContentInspector: some View {
        let kinds = Set(editor.selectedObjects.map(\.kind))
        if kinds.contains(where: Self.acceptsDataLink) {
            dataLinkageInspector
        }
        if kinds.contains(.timerCountdown) {
            countdownInspector
        }
        if kinds.contains(.systemClock) || kinds.contains(.systemDate) {
            InspectorSection(kinds.contains(.systemDate) && !kinds.contains(.systemClock) ? "Date" : "Time") {
                PropertyRow("Format") {
                    Picker("", selection: Binding(
                        get: { common(\.token) ?? (kinds.contains(.systemDate) ? "EEEE, MMMM d" : "h:mm:ss a") },
                        set: { value in editor.mutateSelectedObjects { $0.token = value } }
                    )) {
                        ForEach(kinds.contains(.systemDate) ? ClockFormatCatalog.date : ClockFormatCatalog.time, id: \.self) { format in
                            Text(ClockFormatCatalog.title(for: format)).tag(format)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
        if kinds.contains(.liveQuote) {
            InspectorSection("Live Quote") {
                PropertyRow("Market") {
                    Picker("", selection: Binding(
                        get: {
                            DynamicTextEngine.quoteSpec(for: editor.selectedObjects.first ?? CanvasObject(
                                name: "Quote",
                                kind: .liveQuote,
                                bounds: .centered(width: 100, height: 40)
                            )).kind
                        },
                        set: { kind in
                            editor.mutateSelectedObjects { object in
                                let current = DynamicTextEngine.quoteSpec(for: object)
                                object.token = DynamicTextEngine.encodeQuoteToken(
                                    LiveQuoteRequest(symbol: current.symbol, kind: kind)
                                )
                            }
                        }
                    )) {
                        ForEach(LiveQuoteKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Symbol") {
                    TextField("AAPL", text: Binding(
                        get: { DynamicTextEngine.quoteSpec(for: editor.selectedObjects.first ?? CanvasObject(name: "Quote", kind: .liveQuote, bounds: .centered(width: 100, height: 40))).symbol },
                        set: { symbol in
                            editor.mutateSelectedObjects { object in
                                let kind = DynamicTextEngine.quoteSpec(for: object).kind
                                object.token = DynamicTextEngine.encodeQuoteToken(
                                    LiveQuoteRequest(symbol: symbol, kind: kind)
                                )
                            }
                        }
                    ))
                    .textFieldStyle(.squareBorder)
                    .controlSize(.small)
                    .accessibilityLabel("Quote symbol")
                }
                PropertyRow("Display") {
                    Picker("", selection: Binding(
                        get: { common(\.text) ?? LiveQuoteCatalog.defaultTemplate },
                        set: { value in editor.mutateSelectedObjects { $0.text = value } }
                    )) {
                        ForEach(LiveQuoteCatalog.templates, id: \.self) { template in
                            Text(template).tag(template)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                Text("Display is the template in the text box ({symbol}, {price}, {change} — line breaks allowed). Pick a preset or double-click the object to edit. Use {quote:AAPL} {quote:BTC} only for a multi-symbol colored ticker.")
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if kinds.contains(.textField) {
            InspectorSection("Text Field") {
                PropertyRow("Name") {
                    TextField("Speaker", text: Binding(
                        get: { editor.selectedObjects.first.map(DynamicTextEngine.fieldKey(for:)) ?? "Speaker" },
                        set: { key in
                            editor.mutateSelectedObjects { $0.token = key }
                            controller.ensureTextField(key: key)
                        }
                    ))
                    .textFieldStyle(.squareBorder)
                    .controlSize(.small)
                    .accessibilityLabel("Field name")
                }
                PropertyRow("Fill") {
                    TextField("Type later…", text: Binding(
                        get: {
                            let key = editor.selectedObjects.first.map(DynamicTextEngine.fieldKey(for:)) ?? ""
                            return controller.textFields.first(where: { $0.normalizedKey.caseInsensitiveCompare(key) == .orderedSame })?.value ?? ""
                        },
                        set: { value in
                            let key = editor.selectedObjects.first.map(DynamicTextEngine.fieldKey(for:)) ?? "Speaker"
                            controller.setTextField(key, value: value)
                        }
                    ))
                    .textFieldStyle(.squareBorder)
                    .controlSize(.small)
                    .accessibilityLabel("Field value")
                }
            }
        }
    }

    private static func acceptsDataLink(_ kind: CanvasObjectKind) -> Bool {
        kind == .text || kind == .textField || kind == .title || kind == .subtitle
    }

    @ViewBuilder
    private var dataLinkageInspector: some View {
        InspectorSection("Data Linkage") {
            Picker("Source", selection: $dataLinkDomain) {
                ForEach(DataLinkDomain.allCases) { domain in
                    Text(domain.rawValue).tag(domain)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Data source")

            switch dataLinkDomain {
            case .outline:
                durationFormatRow
                PropertyRow("End time") {
                    Picker("End time", selection: $dataLinkClockFormat) {
                        ForEach(["h:mm a", "HH:mm", "h:mm:ss a"], id: \.self) { format in
                            Text(ClockFormatCatalog.title(for: format)).tag(format)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                PropertyRow("Agenda items") {
                    Stepper(value: $dataLinkAgendaCount, in: 1...8) {
                        Text("\(dataLinkAgendaCount)")
                            .font(InspectorTokens.labelFont)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Upcoming agenda count")
                }
            case .media:
                durationFormatRow
            case .system:
                PropertyRow("Clock") {
                    Picker("Clock", selection: $dataLinkClockFormat) {
                        ForEach(ClockFormatCatalog.time, id: \.self) { format in
                            Text(ClockFormatCatalog.title(for: format)).tag(format)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            case .graph:
                PropertyRow("Key") {
                    TextField("score.home", text: $dataLinkGraphKey)
                        .textFieldStyle(.squareBorder)
                        .controlSize(.small)
                        .accessibilityLabel("Graph data key")
                }
                Text("External feeds and graph nodes publish into this key. Every output reads the same value on the next frame.")
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(DataLinkCatalog.fields(in: dataLinkDomain)) { field in
                    Button(field.title) {
                        bindDataLink(tag(for: field))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(field.kind == .graph && dataLinkGraphKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Bind \(field.title)")
                }
            }

            if let preview = dataLinkPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On screen")
                        .font(InspectorTokens.labelFont)
                        .foregroundColor(InspectorTokens.labelColor)
                    Text(preview.isEmpty ? "—" : preview)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(InspectorTokens.headerColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Live evaluation preview")
                }
            }
        }
    }

    private var durationFormatRow: some View {
        PropertyRow("Time format") {
            Picker("Time format", selection: $dataLinkDurationFormat) {
                ForEach(CountdownFormatCatalog.all, id: \.self) { format in
                    Text(CountdownFormatCatalog.title(for: format)).tag(format)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }

    private func tag(for field: DataLinkField) -> String {
        let format = field.kind == .duration ? dataLinkDurationFormat : dataLinkClockFormat
        return DataLinkCatalog.tag(
            for: field,
            format: format,
            agendaCount: dataLinkAgendaCount,
            graphKey: dataLinkGraphKey
        )
    }

    private func bindDataLink(_ tag: String) {
        editor.mutateSelectedObjects { object in
            guard Self.acceptsDataLink(object.kind) else { return }
            let current = object.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty || current == object.name {
                object.text = tag
            } else if current.contains(tag) {
                return
            } else {
                object.text += " \(tag)"
            }
        }
    }

    private var dataLinkPreview: String? {
        guard let object = editor.selectedObjects.first(where: { Self.acceptsDataLink($0.kind) }) else { return nil }
        return DynamicTextEngine.resolve(object, context: controller.dynamicTextContext())
    }

    @ViewBuilder
    private var countdownInspector: some View {
        let selectedCountdowns = editor.selectedObjects.filter { $0.kind == .timerCountdown }
        let boundIDs = Set(selectedCountdowns.compactMap(\.timerID))
        let timer = boundIDs.count <= 1
            ? controller.inspector.timer(id: boundIDs.first ?? selectedCountdowns.first?.timerID)
            : nil
        let followsMedia = common(\.resolvedCountdownValueSource) == .programMedia
        InspectorSection("Countdown") {
            PropertyRow("Value from") {
                Picker("Value from", selection: Binding(
                    get: { common(\.resolvedCountdownValueSource) ?? .timer },
                    set: { value in
                        editor.mutateSelectedObjects { object in
                            guard object.kind == .timerCountdown else { return }
                            object.countdownValueSource = value
                        }
                    }
                )) {
                    ForEach(CountdownValueSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Countdown value source")
                .help("Timer uses a set length. Program Media counts down to the end of the playing video.")
            }
            if followsMedia {
                Text("Counts down to the end of the program video.")
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
                PropertyRow("Format") {
                    Picker("Format", selection: Binding(
                        get: { CountdownFormatCatalog.resolvedToken(common(\.token) ?? CountdownFormatCatalog.default) },
                        set: { value in
                            editor.mutateSelectedObjects { object in
                                guard object.kind == .timerCountdown else { return }
                                object.token = value
                            }
                        }
                    )) {
                        ForEach(CountdownFormatCatalog.all, id: \.self) { format in
                            Text(CountdownFormatCatalog.title(for: format)).tag(format)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Time format")
                }
                PropertyRow("Preview") {
                    TimelineView(.periodic(from: TimelineAnchor.start, by: 0.25)) { _ in
                        let seconds = controller.programMediaClock().remaining
                        Text(CountdownFormatCatalog.format(seconds, token: common(\.token) ?? CountdownFormatCatalog.default))
                            .font(InspectorTokens.valueFont)
                            .foregroundColor(InspectorTokens.headerColor)
                            .accessibilityLabel("Countdown preview")
                            .accessibilityValue(CountdownFormatCatalog.format(seconds, token: common(\.token) ?? CountdownFormatCatalog.default))
                    }
                }
            } else {
            PropertyRow("Timer") {
                Picker("Timer", selection: Binding(
                    get: { timer?.id ?? boundIDs.first },
                    set: { id in
                        guard let id else { return }
                        controller.bindSelectedCountdowns(to: id)
                    }
                )) {
                    ForEach(controller.inspector.timers) { item in
                        Text(item.name).tag(Optional(item.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .disabled(controller.inspector.timers.isEmpty)
                .accessibilityLabel("Which countdown")
            }
            HStack(spacing: 6) {
                Button("New Timer") {
                    _ = controller.addTimerForSelectedCountdowns()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Add a new countdown timer")
                Spacer(minLength: 0)
            }
            if let timer {
                PropertyRow("Name") {
                    TextField("Program Timer", text: Binding(
                        get: { timer.name },
                        set: { value in
                            _ = controller.inspector.setTimerName(id: timer.id, name: value)
                            controller.persistStudio()
                        }
                    ))
                    .font(InspectorTokens.labelFont)
                    .textFieldStyle(.squareBorder)
                    .controlSize(.small)
                    .frame(width: 140)
                    .accessibilityLabel("Timer name")
                }
                PropertyRow("Kind") {
                    Picker("Kind", selection: Binding(
                        get: { timer.kind },
                        set: { value in
                            _ = controller.inspector.setTimerKind(id: timer.id, kind: value)
                            controller.persistStudio()
                        }
                    )) {
                        ForEach(InspectorTimerKind.allCases, id: \.self) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Countdown kind")
                }
                switch timer.kind {
                case .countdown:
                    countdownDurationRow(timer)
                case .countdownToTime:
                    countdownTargetRow(timer)
                case .elapsed:
                    PropertyRow("Elapsed") {
                        Text(CountdownFormatCatalog.format(timer.elapsedSeconds, token: common(\.token) ?? CountdownFormatCatalog.default))
                            .font(InspectorTokens.valueFont)
                            .foregroundColor(InspectorTokens.headerColor)
                            .accessibilityLabel("Elapsed time")
                    }
                }
                PropertyRow("Format") {
                    Picker("Format", selection: Binding(
                        get: { CountdownFormatCatalog.resolvedToken(common(\.token) ?? CountdownFormatCatalog.default) },
                        set: { value in
                            editor.mutateSelectedObjects { object in
                                guard object.kind == .timerCountdown else { return }
                                object.token = value
                            }
                        }
                    )) {
                        ForEach(CountdownFormatCatalog.all, id: \.self) { format in
                            Text(CountdownFormatCatalog.title(for: format)).tag(format)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Time format")
                }
                PropertyRow("Preview") {
                    TimelineView(.periodic(from: TimelineAnchor.start, by: 0.25)) { _ in
                        let live = controller.inspector.timer(id: timer.id) ?? timer
                        Text(CountdownFormatCatalog.format(live.displaySeconds, token: common(\.token) ?? CountdownFormatCatalog.default))
                            .font(InspectorTokens.valueFont)
                            .foregroundColor(live.isOverrun ? Color.red : InspectorTokens.headerColor)
                            .accessibilityLabel("Countdown preview")
                            .accessibilityValue(CountdownFormatCatalog.format(live.displaySeconds, token: common(\.token) ?? CountdownFormatCatalog.default))
                    }
                }
                HStack(spacing: 6) {
                    Button(timer.isRunning ? "Pause" : "Start") {
                        if timer.isRunning {
                            _ = controller.inspector.stopTimer(id: timer.id)
                        } else {
                            _ = controller.inspector.startTimer(id: timer.id)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(timer.isRunning ? "Pause countdown" : "Start countdown")
                    Button("Reset") {
                        _ = controller.inspector.resetTimer(id: timer.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Reset countdown")
                    Spacer(minLength: 0)
                    Text(timer.isRunning ? "Running" : "Stopped")
                        .font(InspectorTokens.labelFont)
                        .foregroundColor(InspectorTokens.labelColor)
                        .accessibilityHidden(true)
                }
                PropertyRow("Start on") {
                    Picker("Start on", selection: Binding(
                        get: { common(\.resolvedCountdownStartOn) ?? .none },
                        set: { value in
                            editor.mutateSelectedObjects { object in
                                guard object.kind == .timerCountdown else { return }
                                object.countdownStartOn = value
                            }
                        }
                    )) {
                        ForEach(CountdownBuildLink.allCases) { link in
                            Text(link.title).tag(link)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Start countdown on build trigger")
                    .help("Start this timer when the chosen build trigger fires.")
                }
                PropertyRow("Reset on") {
                    Picker("Reset on", selection: Binding(
                        get: { common(\.resolvedCountdownResetOn) ?? .none },
                        set: { value in
                            editor.mutateSelectedObjects { object in
                                guard object.kind == .timerCountdown else { return }
                                object.countdownResetOn = value
                            }
                        }
                    )) {
                        ForEach(CountdownBuildLink.allCases) { link in
                            Text(link.title).tag(link)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Reset countdown on build trigger")
                    .help("Reset this timer when the chosen build trigger fires.")
                }
            } else if boundIDs.count > 1 {
                Text("Selected countdowns use different timers.")
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Add a timer to start and stop this countdown.")
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
        }
    }

    private func countdownDurationRow(_ timer: InspectorTimer) -> some View {
        let total = max(0, timer.durationSeconds)
        return PropertyRow("Duration") {
            HStack(spacing: 4) {
                countdownUnitField(
                    value: total / 3600,
                    label: "h",
                    accessibility: "Hours"
                ) { hours in
                    let minutes = (total % 3600) / 60
                    let seconds = total % 60
                    _ = controller.inspector.setTimerDuration(id: timer.id, seconds: hours * 3600 + minutes * 60 + seconds)
                    controller.persistStudio()
                }
                countdownUnitField(
                    value: (total % 3600) / 60,
                    label: "m",
                    accessibility: "Minutes"
                ) { minutes in
                    let hours = total / 3600
                    let seconds = total % 60
                    _ = controller.inspector.setTimerDuration(id: timer.id, seconds: hours * 3600 + min(59, minutes) * 60 + seconds)
                    controller.persistStudio()
                }
                countdownUnitField(
                    value: total % 60,
                    label: "s",
                    accessibility: "Seconds"
                ) { seconds in
                    let hours = total / 3600
                    let minutes = (total % 3600) / 60
                    _ = controller.inspector.setTimerDuration(id: timer.id, seconds: hours * 3600 + minutes * 60 + min(59, seconds))
                    controller.persistStudio()
                }
            }
        }
    }

    private func countdownTargetRow(_ timer: InspectorTimer) -> some View {
        PropertyRow("At") {
            HStack(spacing: 4) {
                countdownUnitField(
                    value: timer.targetHour,
                    label: "h",
                    accessibility: "Target hour"
                ) { hour in
                    _ = controller.inspector.setTimerTarget(id: timer.id, hour: hour, minute: timer.targetMinute)
                    controller.persistStudio()
                }
                countdownUnitField(
                    value: timer.targetMinute,
                    label: "m",
                    accessibility: "Target minute"
                ) { minute in
                    _ = controller.inspector.setTimerTarget(id: timer.id, hour: timer.targetHour, minute: minute)
                    controller.persistStudio()
                }
            }
        }
    }

    private func countdownUnitField(value: Int, label: String, accessibility: String, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            TextField("", text: Binding(
                get: { String(value) },
                set: { raw in
                    let digits = raw.filter(\.isNumber)
                    set(max(0, Int(digits) ?? 0))
                }
            ))
            .font(InspectorTokens.valueFont)
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.squareBorder)
            .controlSize(.small)
            .frame(width: 36)
            .accessibilityLabel(accessibility)
            Text(label)
                .font(InspectorTokens.labelFont)
                .foregroundColor(InspectorTokens.labelColor)
        }
    }

    private var qrCodePayloadBinding: Binding<String> {
        Binding(
            get: { editor.selectedObjects.first?.text ?? "" },
            set: { value in
                editor.mutateSelectedObjectsFromInspector { $0.text = value }
            }
        )
    }

    @ViewBuilder
    private var liveFieldsInspector: some View {
        InspectorSection("Fill-in Text") {
            if controller.textFields.isEmpty {
                Text("Add a Text Field from the live menu, or type {Speaker} in a text box.")
                    .font(InspectorTokens.labelFont)
                    .foregroundColor(InspectorTokens.labelColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(controller.textFields) { field in
                PropertyRow(field.key) {
                    TextField(field.hint, text: Binding(
                        get: { field.value },
                        set: { controller.setTextField(field.key, value: $0) }
                    ))
                    .textFieldStyle(.squareBorder)
                    .controlSize(.small)
                    .accessibilityLabel("\(field.key) value")
                }
            }
            HStack {
                Button("Add Field") { controller.addTextField() }
                    .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
    }
}
