import SwiftUI
import UniformTypeIdentifiers

struct MapSourcePickerView: View {
    var sources: [PlaceholderSourceChoice]
    var selectedID: String?
    var artworkURL: (PlaceholderSourceChoice) -> URL?
    var onPick: (String?) -> Void
    var onImport: (URL) -> Void

    @State private var query = ""
    @State private var isImporterPresented = false
    @FocusState private var searchFocused: Bool

    private var filtered: [PlaceholderSourceChoice] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sources }
        return sources.filter {
            $0.name.lowercased().contains(needle) || $0.subtitle.lowercased().contains(needle)
        }
    }

    private var devices: [PlaceholderSourceChoice] { filtered.filter { $0.group == .device } }
    private var media: [PlaceholderSourceChoice] { filtered.filter { $0.group == .media } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .accessibilityHidden(true)
                TextField("Search sources…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search sources")
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Rectangle()
                .fill(ProShowTheme.hairline)
                .frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    sourceRow(
                        title: "Unassigned",
                        subtitle: "No input mapped",
                        symbol: "slash.circle",
                        tint: "#3A3A40",
                        selected: selectedID == nil,
                        preview: nil
                    ) {
                        onPick(nil)
                    }
                    Button {
                        isImporterPresented = true
                    } label: {
                        HStack(spacing: 10) {
                            roundedMark(tint: "#FFE9A8", symbol: "folder.badge.plus")
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Choose from Files…")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Import image or video")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ProShowTheme.secondaryLabel)
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(ProShowTheme.primaryLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .accessibilityLabel("Choose media from files")

                    if !devices.isEmpty {
                        sectionLabel("Devices")
                        ForEach(devices) { source in
                            choiceRow(source)
                        }
                    }
                    if !media.isEmpty {
                        sectionLabel("Media library")
                        ForEach(media) { source in
                            choiceRow(source)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 320)
        .background(ProShowTheme.panel)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image, .movie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onImport(url)
            }
        }
        .onAppear { searchFocused = true }
    }

    private func choiceRow(_ source: PlaceholderSourceChoice) -> some View {
        sourceRow(
            title: source.name,
            subtitle: source.subtitle,
            symbol: source.symbolName,
            tint: source.tintHex,
            selected: selectedID == source.id,
            preview: source
        ) {
            onPick(source.id)
        }
    }

    private func sourceRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: String,
        selected: Bool,
        preview: PlaceholderSourceChoice?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let preview {
                    MediaPreviewFrame(
                        filePath: preview.filePath,
                        artworkURL: artworkURL(preview),
                        kind: mediaKind(preview.previewKind),
                        tintHex: preview.tintHex,
                        cornerRadius: 7
                    )
                    .frame(width: 52, height: 30)
                } else {
                    roundedMark(tint: tint, symbol: symbol)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ProShowTheme.accent)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(ProShowTheme.primaryLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? ProShowTheme.well : Color.clear)
            )
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : subtitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func roundedMark(tint: String, symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color(hex: tint) ?? ProShowTheme.well)
            .frame(width: 52, height: 30)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StartHome.ink.opacity(0.82))
            }
            .accessibilityHidden(true)
    }

    private func mediaKind(_ kind: PlaceholderSourceChoice.PreviewKind) -> MediaBinItem.Kind {
        switch kind {
        case .video: .video(duration: "")
        case .image: .image
        case .camera: .camera(label: "")
        case .placeholder: .placeholder
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(ProShowTheme.secondaryLabel)
            .padding(.top, 8)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

struct MapSourceMenuButton: View {
    var title: String
    var sources: [PlaceholderSourceChoice]
    var selectedID: String?
    var artworkURL: (PlaceholderSourceChoice) -> URL?
    var onPick: (String?) -> Void
    var onImport: (URL) -> Void

    @State private var isOpen = false

    private var selected: PlaceholderSourceChoice? {
        sources.first { $0.id == selectedID }
    }

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 8) {
                if let selected {
                    MediaPreviewFrame(
                        filePath: selected.filePath,
                        artworkURL: artworkURL(selected),
                        kind: mediaKind(selected.previewKind),
                        tintHex: selected.tintHex,
                        cornerRadius: 5
                    )
                    .frame(width: 36, height: 20)
                    Text(selected.name)
                        .lineLimit(1)
                } else {
                    Image(systemName: "slash.circle")
                    Text("Unmapped")
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .accessibilityHidden(true)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(ProShowTheme.well, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(selected?.name ?? "Unmapped")
        .popover(isPresented: $isOpen, arrowEdge: .leading) {
            MapSourcePickerView(
                sources: sources,
                selectedID: selectedID,
                artworkURL: artworkURL,
                onPick: { id in
                    onPick(id)
                    isOpen = false
                },
                onImport: { url in
                    onImport(url)
                    isOpen = false
                }
            )
        }
    }

    private func mediaKind(_ kind: PlaceholderSourceChoice.PreviewKind) -> MediaBinItem.Kind {
        switch kind {
        case .video: .video(duration: "")
        case .image: .image
        case .camera: .camera(label: "")
        case .placeholder: .placeholder
        }
    }
}