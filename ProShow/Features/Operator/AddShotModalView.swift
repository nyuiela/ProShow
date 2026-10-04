import SwiftUI
import UniformTypeIdentifiers
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Source picker using the same home language as the start screen.
struct AddShotModalView: View {
    @Bindable var controller: ShowController
    @State private var discovery = SourceDiscoveryManager()
    @State private var previewStore = InputPreviewStore()
    @State private var category: AddShotCategory = .all
    @State private var query = ""
    @State private var selectedID: String?
    @State private var isGrid = false
    @State private var isImporterPresented = false
    @State private var isAddingColor = false
    @State private var draftColor = Color(red: 0.98, green: 0.84, blue: 0.18)
    @State private var draftColorName = "Custom Color"
    @State private var expandedGroups: Set<String> = [
        "Placeholders",
        "Solid Colors",
        "Library",
        "Playlists",
        "Media Files",
        "Shots",
        "System Device",
        "Displays",
        "Windows",
        "System Audio Capture",
        "NDI™ Source",
        "Rendezvous / Remote Stream",
    ]
    @FocusState private var searchFocused: Bool

    static let modalWidth: CGFloat = 840
    static let modalHeight: CGFloat = 620
    static let modalMaxWidth: CGFloat = 880
    static let modalMaxHeight: CGFloat = 680

    private var layerTitle: String {
        controller.masterLayers[safe: controller.addShotLayerIndex]?.title ?? "Main Layer 1"
    }

    private var groups: [SourceGroup] {
        discovery.groups(category: category, query: query)
    }

    private var selectedItem: DiscoveredSourceItem? {
        discovery.items.first { $0.id == selectedID }
    }

    private var addShotContextTitle: String {
        switch controller.addShotPurpose {
        case .assignToSelectedObjects: "Selected objects"
        case .assignRundownProgramSlide: "Program slide"
        case .addToLayer: layerTitle
        }
    }

    private var addShotContextSubtitle: String {
        switch controller.addShotPurpose {
        case .assignToSelectedObjects:
            "Assign a placeholder, media file, or source"
        case .assignRundownProgramSlide:
            "Link a slide, web page, camera, or media to this outline item"
        case .addToLayer:
            "Choose a source for this layer"
        }
    }

    private var addShotConfirmHint: String {
        switch controller.addShotPurpose {
        case .assignToSelectedObjects:
            "Assigns the selected source to the current object"
        case .assignRundownProgramSlide:
            "Assigns the selected source to this rundown item"
        case .addToLayer:
            "Adds the selected source to \(layerTitle)"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                if let accessMessage = discovery.accessMessage {
                    accessBanner(accessMessage)
                }
                sourcePane
                dock
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StartHome.page)
        }
        .frame(width: Self.modalWidth, height: Self.modalHeight)
        .frame(maxWidth: Self.modalMaxWidth, maxHeight: Self.modalMaxHeight)
        .background(StartHome.page)
        .clipShape(RoundedRectangle(cornerRadius: DeskRadius.sheet, style: .continuous))
        .preferredColorScheme(.dark)
        .focusEffectDisabled()
        .onAppear { rescanHardware() }
        .onDisappear {
            previewStore.shutdown()
            RundownProgramSlideAssignSession.cancel()
        }
        .onChange(of: selectedID) { _, _ in
            previewStore.attachSelection(selectedItem, program: controller.videoInputs)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.movie, .image, .audio],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                for url in urls {
                    ingestImportedMedia(url)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(StartHome.ink)
                    Image(systemName: "film")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                Text(controller.addShotPurpose.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 28)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AddShotCategory.allCases) { item in
                        navButton(item.rawValue, systemImage: item.iconName, selected: category == item) {
                            category = item
                            if item == .placeholders || item == .backgrounds {
                                isGrid = true
                            }
                        }
                    }
                }
            }
            .focusEffectDisabled()

            navButton("Cancel", systemImage: "xmark") {
                controller.closeAddShot()
            }
            .padding(.bottom, 20)
            .keyboardShortcut(.cancelAction)
        }
        .frame(width: 200, alignment: .leading)
        .background(StartHome.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Source categories")
    }

    private func navButton(_ title: String, systemImage: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
            .padding(.horizontal, 18)
            .frame(height: 36)
            .background(selected ? Color.white.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .padding(.horizontal, 8)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(addShotContextTitle)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text(addShotContextSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                chip("List", selected: !isGrid) { isGrid = false }
                chip("Grid", selected: isGrid) { isGrid = true }
                chip("Offline", selected: discovery.showDisconnected) {
                    discovery.showDisconnected.toggle()
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .accessibilityHidden(true)
                    TextField("Search sources", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .focused($searchFocused)
                        .accessibilityLabel("Search sources")
                }
                .padding(.horizontal, 12)
                .frame(width: 220, height: 34)
                .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                Button {
                    rescanHardware()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .opacity(discovery.isRefreshingHardware ? 0.45 : 1)
                }
                .buttonStyle(DeskPressButtonStyle())
                .disabled(discovery.isRefreshingHardware)
                .help("Rescan cameras, screens, and NDI")
                .accessibilityLabel("Rescan cameras, screens, and NDI")
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }

    private func accessBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StartHome.tangerine)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if message.contains("Camera") {
                privacyButton("Camera Settings") { PrivacySettingsOpener.openCamera() }
            }
            if message.contains("Screen") {
                privacyButton("Screen Settings") { PrivacySettingsOpener.openScreenRecording() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func privacyButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(DeskPressButtonStyle())
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StartHome.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(StartHome.lemon, in: Capsule())
            .accessibilityLabel(title)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? StartHome.ink : Color.white.opacity(0.8))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(selected ? Color.white : Color.white.opacity(0.08), in: Capsule(style: .continuous))
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var sourcePane: some View {
        if isGrid {
            sourceGrid
        } else {
            sourceTree
        }
    }

    private var sourceTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            if expandedGroups.contains(group.groupName) {
                                expandedGroups.remove(group.groupName)
                            } else {
                                expandedGroups.insert(group.groupName)
                            }
                        } label: {
                            HStack {
                                Text(group.groupName)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                                Spacer(minLength: 0)
                                Image(systemName: expandedGroups.contains(group.groupName) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.4))
                            }
                        }
                        .buttonStyle(DeskPressButtonStyle())
                        .accessibilityLabel(group.groupName)
                        .accessibilityHint(expandedGroups.contains(group.groupName) ? "Collapse" : "Expand")

                        if expandedGroups.contains(group.groupName) {
                            VStack(spacing: 0) {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                    sourceRow(item, tint: StartHome.rowTint(index))
                                }
                            }
                        }
                    }
                }
                if groups.isEmpty {
                    Text(query.isEmpty ? "Nothing in this category yet. Add a media file or pick another group." : "No sources match “\(query)”.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .focusEffectDisabled()
    }

    private var sourceGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 14)], spacing: 14) {
                ForEach(Array(groups.flatMap(\.items).enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedID = item.id
                    } label: {
                        sourceCard(item, tint: StartHome.rowTint(index))
                            .overlay {
                                if selectedID == item.id {
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 3)
                                }
                            }
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                    .accessibilityHint(item.groupName)
                }
            }
            .padding(28)
        }
        .focusEffectDisabled()
    }

    @ViewBuilder
    private func sourceCard(_ item: DiscoveredSourceItem, tint: Color) -> some View {
        if let letter = item.placeholderLetter {
            VStack(alignment: .leading, spacing: 10) {
                PlaceholderLetterCard(letter: letter, tintHex: item.tintHex ?? "#D8F5D0", cornerRadius: 14)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text("Placeholder \(letter)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Maps later to a prop, screen, or source")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if item.sourceType == .solidColor, let hex = item.tintHex ?? item.connectionString {
            VStack(alignment: .leading, spacing: 10) {
                SolidColorCard(hex: hex, cornerRadius: 14)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(hex)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if item.sourceType.showsDevicePreview {
            VStack(alignment: .leading, spacing: 10) {
                devicePreview(item, cornerRadius: 14, prefersLive: selectedID == item.id)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                Text(item.name)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(item.groupName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if item.sourceType == .mediaFile {
            VStack(alignment: .leading, spacing: 10) {
                MediaPreviewFrame(
                    filePath: item.connectionString,
                    kind: mediaKind(for: item),
                    tintHex: item.tintHex ?? "#1B3A4B",
                    cornerRadius: 14
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                Text(item.groupName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: item.category.iconName)
                    .font(.system(size: 22, weight: .semibold))
                Spacer(minLength: 0)
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Text(item.groupName)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.58)
            }
            .foregroundStyle(StartHome.ink)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func sourceRow(_ item: DiscoveredSourceItem, tint: Color) -> some View {
        Button {
            selectedID = item.id
        } label: {
            HStack(spacing: 14) {
                sourceMark(item, tint: tint)
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(rowDetail(item))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(StartHome.lemon)
                        .accessibilityLabel("Favorite")
                }
                Image(systemName: selectedID == item.id ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selectedID == item.id ? StartHome.lemon : Color.white.opacity(0.28))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(selectedID == item.id ? Color.white.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .contextMenu {
            Button(item.isFavorite ? "Remove Favorite" : "Add to Favorites") {
                discovery.toggleFavorite(id: item.id)
            }
        }
        .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
        .accessibilityHint(item.groupName)
    }

    private var dock: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                dockMark
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedItem?.name ?? "No source selected")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(selectedItem.map(rowDetail) ?? "Pick a placeholder, color, or file")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button("New color") {
                isAddingColor = true
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
            .buttonStyle(DeskPressButtonStyle())
            .popover(isPresented: $isAddingColor, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("New background color")
                        .font(.system(size: 14, weight: .semibold))
                    ColorPicker("Color", selection: $draftColor, supportsOpacity: false)
                        .labelsHidden()
                    TextField("Name", text: $draftColorName)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                    Button("Add color") {
                        commitDraftColor()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StartHome.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(StartHome.lemon, in: Capsule(style: .continuous))
                    .buttonStyle(DeskPressButtonStyle())
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(width: 240)
                .background(StartHome.dock)
            }

            Button("Add media file") {
                #if os(macOS)
                if let urls = ProjectFilePanel.openMedia() {
                    for url in urls {
                        ingestImportedMedia(url)
                    }
                }
                #else
                isImporterPresented = true
                #endif
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
            .buttonStyle(DeskPressButtonStyle())
            .keyboardShortcut("o", modifiers: [.command])

            if !controller.addShotPurpose.isAssignFlow {
                Button("Add copy") {
                    addSelected(asCopy: true)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(Color.white.opacity(0.08), in: Capsule(style: .continuous))
                .buttonStyle(DeskPressButtonStyle())
                .disabled(selectedItem == nil)
                .opacity(selectedItem == nil ? 0.4 : 1)
            }

            Button(controller.addShotPurpose.confirmTitle) {
                addSelected(asCopy: false)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StartHome.ink)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(selectedItem == nil ? Color.white.opacity(0.35) : StartHome.lemon, in: Capsule(style: .continuous))
            .buttonStyle(DeskPressButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(selectedItem == nil)
            .accessibilityHint(addShotConfirmHint)
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
        .background(StartHome.dock)
    }

    @ViewBuilder
    private var dockMark: some View {
        if let item = selectedItem, let letter = item.placeholderLetter {
            PlaceholderLetterCard(letter: letter, tintHex: item.tintHex ?? "#D8F5D0", cornerRadius: 8)
        } else if let item = selectedItem, item.sourceType == .solidColor, let hex = item.tintHex ?? item.connectionString {
            SolidColorCard(hex: hex, cornerRadius: 8)
        } else if let item = selectedItem, item.sourceType.showsDevicePreview {
            devicePreview(item, cornerRadius: 8, prefersLive: true)
        } else if let item = selectedItem, item.sourceType == .mediaFile {
            MediaPreviewFrame(
                filePath: item.connectionString,
                kind: mediaKind(for: item),
                tintHex: item.tintHex ?? "#1B3A4B",
                cornerRadius: 8
            )
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selectedItem == nil ? Color.white.opacity(0.08) : StartHome.tangerine)
                .overlay {
                    Image(systemName: selectedItem?.category.iconName ?? "film")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selectedItem == nil ? Color.white.opacity(0.45) : StartHome.ink)
                }
        }
    }

    private func sourceMark(_ item: DiscoveredSourceItem, tint: Color) -> some View {
        Group {
            if let letter = item.placeholderLetter {
                PlaceholderLetterCard(letter: letter, tintHex: item.tintHex ?? "#D8F5D0", cornerRadius: 10)
            } else if item.sourceType == .solidColor, let hex = item.tintHex ?? item.connectionString {
                SolidColorCard(hex: hex, cornerRadius: 10)
            } else if item.sourceType.showsDevicePreview {
                devicePreview(item, cornerRadius: 10, prefersLive: false)
            } else if item.sourceType == .mediaFile {
                MediaPreviewFrame(
                    filePath: item.connectionString,
                    kind: mediaKind(for: item),
                    tintHex: item.tintHex ?? "#1B3A4B",
                    cornerRadius: 10
                )
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: item.tintHex ?? "") ?? tint)
                    .overlay {
                        Image(systemName: item.category.iconName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(StartHome.ink.opacity(0.85))
                    }
            }
        }
    }

    @ViewBuilder
    private func devicePreview(_ item: DiscoveredSourceItem, cornerRadius: CGFloat, prefersLive: Bool) -> some View {
        DevicePreviewPlate(
            item: item,
            store: previewStore,
            program: controller.videoInputs,
            cornerRadius: cornerRadius,
            prefersLive: prefersLive
        )
    }

    private func mediaKind(for item: DiscoveredSourceItem) -> MediaBinItem.Kind {
        let path = (item.connectionString ?? "").lowercased()
        if ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: path).pathExtension) {
            return .video(duration: "")
        }
        return .image
    }

    private func rowDetail(_ item: DiscoveredSourceItem) -> String {
        if item.placeholderLetter != nil {
            return "Slot · maps later to a prop or screen"
        }
        if item.sourceType == .solidColor {
            return item.connectionString ?? item.groupName
        }
        if !item.isConnected {
            return "Offline · \(item.groupName)"
        }
        return item.groupName
    }

    private func addSelected(asCopy: Bool) {
        guard let selectedItem else { return }
        if controller.addShotPurpose == .assignRundownProgramSlide {
            RundownProgramSlideAssignSession.fire(selectedItem)
            controller.isAddShotOpen = false
            controller.addShotPurpose = .addToLayer
            return
        }
        controller.completeAddShot(selectedItem, asCopy: asCopy)
    }

    private func commitDraftColor() {
        let swatch = controller.addSolidColor(name: draftColorName, hex: draftColor.hexString())
        selectedID = discovery.appendSolidColor(swatch).id
        category = .backgrounds
        isAddingColor = false
        draftColorName = "Custom Color"
    }

    private func ingestImportedMedia(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if let item = controller.importMedia(url: url) {
            _ = discovery.appendMediaFile(name: item.title, path: item.filePath ?? url.path)
        }
        refreshCatalog()
    }

    private func rescanHardware() {
        Task {
            await discovery.refreshLiveHardware(
                media: controller.importedMedia,
                mediaCollections: controller.mediaCollections,
                libraryShows: controller.libraryShows,
                playlistItems: controller.libraryItems,
                overlays: controller.inspector.props.map(\.name),
                customColors: controller.customSolidColors,
                templates: controller.scenes.scenes.map(\.name),
                existingShots: controller.masterLayers.flatMap(\.shots),
                favoriteIDs: Set(discovery.items.filter(\.isFavorite).map(\.id))
            )
            controller.enableLiveIO()
            controller.videoInputs.refreshDevices()
            expandedGroups.formUnion(Set(discovery.groups(category: .all, query: "").map(\.groupName)))
            previewStore.attachSelection(selectedItem, program: controller.videoInputs)
            await previewStore.refresh(items: discovery.items, program: controller.videoInputs)
        }
    }

    private func refreshCatalog() {
        discovery.refresh(
            media: controller.importedMedia,
            mediaCollections: controller.mediaCollections,
            libraryShows: controller.libraryShows,
            playlistItems: controller.libraryItems,
            overlays: controller.inspector.props.map(\.name),
            customColors: controller.customSolidColors,
            templates: controller.scenes.scenes.map(\.name),
            existingShots: controller.masterLayers.flatMap(\.shots),
            favoriteIDs: Set(discovery.items.filter(\.isFavorite).map(\.id))
        )
        expandedGroups.formUnion(Set(discovery.groups(category: .all, query: "").map(\.groupName)))
    }
}

private struct DevicePreviewPlate: View {
    let item: DiscoveredSourceItem
    var store: InputPreviewStore
    var program: VideoInputEngine
    var cornerRadius: CGFloat
    var prefersLive: Bool

    var body: some View {
        ZStack {
            Color.black
            liveLayer
            if !showsLivePicture, let image = store.image(for: item) {
                previewImage(image)
            } else if !showsLivePicture {
                Image(systemName: item.category.iconName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var showsLivePicture: Bool {
        prefersLive && (liveCameraSession != nil || livePixel != nil)
    }

    @ViewBuilder
    private var liveLayer: some View {
        if prefersLive, program.hasLiveCamera(endpoint: item.connectionString, sourceID: item.id, name: item.name) || livePixel != nil {
            LivePixelPreview(
                endpoint: item.connectionString,
                sourceID: item.id,
                pixelBuffer: livePixel,
                style: .plain
            )
        } else if prefersLive, let session = liveCameraSession {
            LiveCapturePreview(session: session)
        }
    }

    #if canImport(AVFoundation)
    private var liveCameraSession: AVCaptureSession? {
        guard item.sourceType == .systemCamera else { return nil }
        if program.hasLiveCamera(endpoint: item.connectionString, sourceID: item.id, name: item.name) {
            return nil
        }
        return store.previewSession
    }
    #else
    private var liveCameraSession: AVCaptureSession? { nil }
    #endif

    private var livePixel: CVPixelBuffer? {
        program.pixelBuffer(matching: item.connectionString, sourceID: item.id)
    }

    private var liveStamp: TimeInterval? {
        program.frameStamp(matching: item.connectionString, sourceID: item.id)
    }

    @ViewBuilder
    private func previewImage(_ image: PlatformPreviewImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFill()
        #else
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
        #endif
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
