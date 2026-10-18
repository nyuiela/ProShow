import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Bottom media browser: source tree + breadcrumb + thumbnail pane.
struct MediaBinView: View {
    @Bindable var controller: ShowController
    @State private var zoom: Double = 0.55
    @State private var layoutIsGrid = true
    @State private var isImporterPresented = false
    @State private var importerAllowsDocuments = false
    @State private var newPlaylistName = ""
    @State private var isNamingPlaylist = false
    @State private var newLibraryName = ""
    @State private var isNamingLibrary = false
    @State private var renameMediaID: UUID?
    @State private var renameMediaTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            if controller.isMediaInspectorOpen, let item = controller.selectedMediaItemID.flatMap(controller.mediaItem(id:)) {
                mediaInspector(item)
            }
            assetArea
            footer
        }
        .background(Color.clear)
        .overlay { DeskDropCatcher(controller: controller, role: .mediaBin) }
        .onAppear { zoom = controller.workspaceLayout.mediaDrawer.zoomLevel }
        .onChange(of: zoom) { _, value in
            controller.workspaceLayout.mediaDrawer.zoomLevel = value
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importerAllowsDocuments ? [.json, .item] : [.image, .movie, .audio],
            allowsMultipleSelection: !importerAllowsDocuments
        ) { result in
            if importerAllowsDocuments {
                importPresentation(result)
            } else {
                importFiles(result)
            }
        }
        .alert("New Playlist", isPresented: $isNamingPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Create") {
                let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = controller.addMediaPlaylist(named: name.isEmpty ? "Playlist \(controller.collections(for: .playlists).count + 1)" : name)
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        }
        .alert("New Library", isPresented: $isNamingLibrary) {
            TextField("Name", text: $newLibraryName)
            Button("Create") {
                let name = newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = controller.addMediaLibrary(named: name.isEmpty ? "Library \(controller.libraryFolders.count + 1)" : name)
                newLibraryName = ""
            }
            Button("Cancel", role: .cancel) { newLibraryName = "" }
        }
        .alert("Rename", isPresented: Binding(
            get: { renameMediaID != nil },
            set: { if !$0 { renameMediaID = nil } }
        )) {
            TextField("Name", text: $renameMediaTitle)
            Button("Rename") {
                if let renameMediaID {
                    controller.renameMedia(id: renameMediaID, to: renameMediaTitle)
                }
                renameMediaID = nil
            }
            Button("Cancel", role: .cancel) { renameMediaID = nil }
        }
    }

}

/// MEDIA source tree that lives in the left column under the library.
struct MediaSourceSidebar: View {
    @Bindable var controller: ShowController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DeskSectionTitle(title: "Media")
                .padding(.horizontal, DeskSpace.sm)
                .padding(.top, DeskSpace.xs)
                .padding(.bottom, 6)

            List {
                ForEach(controller.orderedMediaSources) { source in
                    VStack(alignment: .leading, spacing: 0) {
                        sourceRow(source)
                        if source.hasChildCollections, controller.expandedMediaSources.contains(source) {
                            ForEach(controller.collections(for: source)) { collection in
                                collectionRow(collection, parent: source)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove(perform: controller.moveMediaSources)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .focusEffectDisabled()
            Spacer(minLength: 0)

            SearchFieldChrome(placeholder: "Filter", text: $controller.mediaFilterQuery)
                .padding(8)
        }
        .deskChromePlane(elevation: .workspace)
    }

    private func sourceRow(_ source: MediaSourceID) -> some View {
        let selected = controller.selectedMediaSource == source && controller.selectedCollectionID == nil
        return Button {
            if source.hasChildCollections {
                if controller.expandedMediaSources.contains(source) && controller.selectedMediaSource == source {
                    controller.expandedMediaSources.remove(source)
                } else {
                    controller.expandedMediaSources.insert(source)
                }
            }
            controller.openMediaPane(source: source)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: source.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(source.title)
                    .font(DeskType.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if source == .playlists || source == .libraries {
                    Button {
                        switch source {
                        case .playlists:
                            _ = controller.addMediaPlaylist(named: "Playlist \(controller.collections(for: .playlists).count + 1)")
                        case .libraries:
                            _ = controller.addMediaLibrary(named: "Library \(controller.libraryFolders.count + 1)")
                        default:
                            break
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(ProShowTheme.secondaryLabel)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .accessibilityLabel("Add \(source.title)")
                }
                if source.hasChildCollections {
                    Image(systemName: controller.expandedMediaSources.contains(source) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(ProShowTheme.secondaryLabel)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? ProShowTheme.primaryLabel : ProShowTheme.toolbarIcon)
            .padding(.horizontal, DeskSpace.sm)
            .frame(minHeight: DeskLayout.hit)
            .background(selected ? ProShowTheme.accent.opacity(0.22) : Color.clear)
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func collectionRow(_ collection: MediaCollection, parent: MediaSourceID) -> some View {
        let selected = controller.selectedCollectionID == collection.id
        return Button {
            controller.openMediaPane(source: parent, collectionID: collection.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: parent == .playlists ? "list.bullet.rectangle" : "folder.fill")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(collection.name)
                    .font(DeskType.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? ProShowTheme.primaryLabel : ProShowTheme.toolbarIcon)
            .padding(.leading, 28)
            .padding(.trailing, DeskSpace.sm)
            .frame(minHeight: DeskLayout.hit)
            .background(selected ? ProShowTheme.accent.opacity(0.18) : Color.clear)
        }
        .buttonStyle(DeskPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension MediaBinView {
    func mediaInspector(_ item: MediaBinItem) -> some View {
        HStack(spacing: 12) {
            Text("Inspector")
                .font(.caption.weight(.bold))
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
            Text(item.scaling)
                .font(.system(size: 12))
                .foregroundStyle(ShowSidebarPalette.subtitle)
            Text(item.behavior)
                .font(.system(size: 12))
                .foregroundStyle(ShowSidebarPalette.subtitle)
            Spacer()
            Button {
                controller.isMediaInspectorOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(ShowSidebarPalette.symbol)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel("Close inspector")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ShowSidebarPalette.title)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    var breadcrumb: some View {
        HStack(spacing: 6) {
            Button(controller.selectedMediaSource.title) {
                controller.openMediaPane(source: controller.selectedMediaSource)
            }
            .buttonStyle(DeskPressButtonStyle())
            if let collection = controller.selectedMediaCollection {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ShowSidebarPalette.subtitle)
                    .accessibilityHidden(true)
                Text(collection.name)
            }
            if controller.isMediaLayerCleared {
                Text("Media cleared")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ProShowTheme.liveRed)
            }
            Spacer()
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(ShowSidebarPalette.title)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var assetArea: some View {
        if layoutIsGrid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth, maximum: tileWidth + 24), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(controller.visibleMediaFolders) { folder in
                        FolderThumbCard(name: folder.name, scale: zoom)
                            .onTapGesture {
                                controller.openMediaPane(source: folder.source, collectionID: folder.id)
                            }
                    }
                    if controller.selectedMediaSource == .libraries {
                        ForEach(controller.libraryShows) { show in
                            PresentationThumbCard(show: show, scale: zoom)
                                .onTapGesture { controller.loadPresentation(id: show.id) }
                        }
                    }
                    ForEach(controller.visibleMediaItems) { item in
                        MediaThumbCard(
                            item: item,
                            scale: zoom,
                            isCleared: controller.isMediaLayerCleared,
                            artworkURL: controller.mediaArtworkURL(for: item),
                            isPlaying: controller.isProgramMediaPlaying(item),
                            isSelected: controller.selectedMediaItemID == item.id,
                            playback: controller.playback
                        )
                            .contentShape(Rectangle())
                            .contextMenu { let _ = MenuRenderProbe.hit("MediaBinView:291:MediaSourceSidebar.assetArea");
                                MediaContextMenu(controller: controller, itemID: item.id) {
                                    renameMediaID = item.id
                                    renameMediaTitle = item.title
                                }
                            }
                            .onTapGesture(count: 2) { controller.selectMediaInPane(item, takeProgram: true) }
                            .onTapGesture { controller.selectMediaInPane(item) }
                            .workspaceDraggable(WorkspaceDragPayload.media(item), controller: controller)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            List {
                ForEach(controller.visibleMediaFolders) { folder in
                    Button {
                        controller.openMediaPane(source: folder.source, collectionID: folder.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(ShowSidebarPalette.symbol)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(folder.name)
                                .font(.system(size: 13))
                                .foregroundStyle(ShowSidebarPalette.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DeskPressButtonStyle())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(controller.visibleMediaItems) { item in
                    let selected = controller.selectedMediaItemID == item.id
                    HStack(spacing: 10) {
                        MediaPreviewFrame(
                            filePath: item.filePath,
                            artworkURL: controller.mediaArtworkURL(for: item),
                            kind: item.kind,
                            tintHex: item.tintHex,
                            cornerRadius: 6
                        )
                        .frame(width: 52, height: 30)
                        Text(item.title)
                            .font(.system(size: 13))
                            .foregroundStyle(ShowSidebarPalette.title)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if controller.isProgramMediaPlaying(item) {
                            PlayheadTimecodeView(
                                playback: controller.playback,
                                fontSize: 11,
                                color: ProShowTheme.meterSafe
                            )
                            .frame(width: 64, alignment: .trailing)
                        } else if case let .video(duration) = item.kind {
                            Text(duration)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                        } else if case let .audio(duration) = item.kind, !duration.isEmpty {
                            Text(duration)
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(ShowSidebarPalette.subtitle)
                        }
                        Circle()
                            .fill(selected ? ShowSidebarPalette.title : Color.clear)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu { let _ = MenuRenderProbe.hit("MediaBinView:371:MediaSourceSidebar.assetArea");
                        MediaContextMenu(controller: controller, itemID: item.id) {
                            renameMediaID = item.id
                            renameMediaTitle = item.title
                        }
                    }
                    .onTapGesture(count: 2) { controller.selectMediaInPane(item, takeProgram: true) }
                    .onTapGesture { controller.selectMediaInPane(item) }
                    .workspaceDraggable(WorkspaceDragPayload.media(item), controller: controller)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .focusEffectDisabled()
        }
    }

    private var tileWidth: CGFloat { 118 + CGFloat(zoom) * 70 }

    private var footer: some View {
        HStack(spacing: DeskSpace.xs) {
            Menu { let _ = MenuRenderProbe.hit("MediaBinView:393:MediaSourceSidebar.footer");
                Button("Import Media…") {
                    importerAllowsDocuments = false
                    isImporterPresented = true
                }
                Button("Import Presentation…") {
                    importerAllowsDocuments = true
                    isImporterPresented = true
                }
                Divider()
                Button("New Playlist…") { isNamingPlaylist = true }
                Button("New Library…") { isNamingLibrary = true }
                Divider()
                Button("Add shot", systemImage: "plus.rectangle.on.folder") {
                    controller.openAddShot(layerIndex: controller.addShotLayerIndex)
                }
            } label: {
                Image(systemName: "plus")
                    .font(DeskControlSize.regular.iconFont)
                    .foregroundStyle(ShowSidebarPalette.symbol)
                    .frame(width: DeskLayout.hit, height: DeskLayout.hit)
                    .contentShape(Rectangle())
            }
            .modifier(BorderlessMenuChrome())
            .help("Add")
            .accessibilityLabel("Add")

            ShowSidebarSearchField(placeholder: "Filter media", text: $controller.mediaFilterQuery)
                .frame(maxWidth: 280)

            Spacer(minLength: DeskSpace.md)

            PaneLayoutToggle(
                gridOn: layoutIsGrid,
                listOn: !layoutIsGrid,
                onGrid: { layoutIsGrid = true },
                onList: { layoutIsGrid = false }
            )
        }
        .padding(.horizontal, DeskSpace.sm)
        .padding(.vertical, 6)
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            _ = controller.importMedia(url: url)
        }
    }

    private func importPresentation(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url), let imported = try? controller.importPresentation(data: data) {
            controller.openMediaPane(source: .libraries)
            controller.loadPresentation(id: imported.id)
        }
    }
}

struct MediaContextMenu: View {
    @Bindable var controller: ShowController
    let itemID: UUID
    var onRename: () -> Void

    var body: some View {
        Button("Inspector...") { controller.inspectMedia(id: itemID) }
        Menu("Transitions...") { let _ = MenuRenderProbe.hit("MediaBinView:463:MediaContextMenu.body");
            ForEach(DeskSampleData.slideTransitions, id: \.self) { name in
                Button(name) { controller.setMediaTransition(name, id: itemID) }
            }
        }

        Divider()

        Menu("Behavior") { let _ = MenuRenderProbe.hit("MediaBinView:471:MediaContextMenu.body");
            ForEach(DeskSampleData.mediaBehaviors, id: \.self) { name in
                Button(name) { controller.setMediaBehavior(name, id: itemID) }
            }
        }
        Menu("Scaling") { let _ = MenuRenderProbe.hit("MediaBinView:476:MediaContextMenu.body");
            ForEach(DeskSampleData.mediaScaling, id: \.self) { name in
                Button(name) { controller.setMediaScaling(name, id: itemID) }
            }
        }
        Menu("Alpha Type") { let _ = MenuRenderProbe.hit("MediaBinView:481:MediaContextMenu.body");
            ForEach(DeskSampleData.mediaAlphaTypes, id: \.self) { name in
                Button(name) { controller.setMediaAlphaType(name, id: itemID) }
            }
        }

        Divider()

        Menu("Playback Behavior") { let _ = MenuRenderProbe.hit("MediaBinView:489:MediaContextMenu.body");
            ForEach(DeskSampleData.mediaPlayback, id: \.self) { name in
                Button(name) { controller.setMediaPlayback(name, id: itemID) }
            }
        }
        Menu("Loop Behavior") { let _ = MenuRenderProbe.hit("MediaBinView:494:MediaContextMenu.body");
            ForEach(DeskSampleData.mediaLoop, id: \.self) { name in
                Button(name) { controller.setMediaLoop(name, id: itemID) }
            }
        }
        Menu("End Behavior") { let _ = MenuRenderProbe.hit("MediaBinView:499:MediaContextMenu.body");
            ForEach(DeskSampleData.mediaEnd, id: \.self) { name in
                Button(name) { controller.setMediaEndBehavior(name, id: itemID) }
            }
        }

        Divider()

        Menu("Next Cue") { let _ = MenuRenderProbe.hit("MediaBinView:507:MediaContextMenu.body");
            Button("None") { controller.setMediaNextCue("None", id: itemID) }
            ForEach(controller.indexedCues.prefix(12)) { cue in
                Button("\(cue.number). \(cue.slide.previewSummary)") {
                    controller.setMediaNextCue(cue.slide.id.uuidString, id: itemID)
                }
            }
        }

        Divider()

        Button("Cut") { controller.cutMedia([itemID]) }
        Button("Copy") { controller.copyMedia([itemID]) }
        Button("Paste") { controller.pasteMedia() }
            .disabled(!controller.canPasteMedia)
        Button("Duplicate") { controller.duplicateMedia(id: itemID) }
        Button("Rename...") { onRename() }
        Button("Delete", role: .destructive) { controller.deleteMedia([itemID]) }

        Divider()

        Button("Show in Finder") { revealInFinder() }
            .disabled(controller.mediaFileURL(id: itemID) == nil)
        Menu("Clean Up By") { let _ = MenuRenderProbe.hit("MediaBinView:530:MediaContextMenu.body");
            ForEach(DeskSampleData.mediaCleanup, id: \.self) { name in
                Button(name) { controller.cleanUpMedia(by: name) }
            }
        }
    }

    private func revealInFinder() {
        #if os(macOS)
        guard let url = controller.mediaFileURL(id: itemID) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}

struct PaneHairlineVertical: View {
    var body: some View {
        Rectangle()
            .fill(ProShowTheme.hairline)
            .frame(width: DeskPaneDivider.width)
    }
}

private struct FolderThumbCard: View {
    let name: String
    let scale: Double
    @Environment(\.colorScheme) private var scheme
    private var width: CGFloat { 118 + CGFloat(scale) * 70 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ShowSidebarPalette.field(scheme))
                Image(systemName: "folder.fill")
                    .font(.title2)
                    .foregroundStyle(ProShowTheme.accent.opacity(0.85))
            }
            .frame(width: width, height: width * 9 / 16)
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .foregroundStyle(ShowSidebarPalette.title)
        }
    }
}

private struct PresentationThumbCard: View {
    let show: Show
    let scale: Double
    private var width: CGFloat { 118 + CGFloat(scale) * 70 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                    .fill(ProShowTheme.stageBlack)
                Text(show.allSlides.first?.previewSummary ?? show.name)
                    .font(.system(size: 11, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(ProShowTheme.lyricWhite)
                    .padding(8)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: width, height: width * 9 / 16)
            Text(show.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .foregroundStyle(ShowSidebarPalette.title)
        }
    }
}

private struct MediaThumbCard: View {
    let item: MediaBinItem
    let scale: Double
    var isCleared: Bool = false
    var artworkURL: URL? = nil
    var isPlaying: Bool = false
    var isSelected: Bool = false
    var playback: MediaPlaybackEngine?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { 118 + CGFloat(scale) * 70 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if case .placeholder = item.kind, PlaceholderLetter.allCases.map(\.rawValue).contains(item.title) {
                        PlaceholderLetterCard(letter: item.title, tintHex: item.tintHex, cornerRadius: DeskRadius.control)
                    } else {
                        MediaPreviewFrame(
                            filePath: item.filePath,
                            artworkURL: artworkURL,
                            kind: item.kind,
                            tintHex: item.tintHex,
                            cornerRadius: DeskRadius.control
                        )
                    }
                }
                .opacity(isCleared ? 0.35 : 1)

                if item.showsPlaybackTransport, isPlaying, let playback {
                    HStack(spacing: 6) {
                        PlayingEqualizerBars(reduceMotion: reduceMotion)
                        PlayheadTimecodeView(
                            playback: playback,
                            fontSize: 10,
                            color: .white
                        )
                        .frame(width: 52)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.72), in: Capsule(style: .continuous))
                    .foregroundStyle(.white)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else if case let .video(duration) = item.kind {
                    Text(duration)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.72))
                        .foregroundStyle(.white)
                        .padding(4)
                } else if case let .audio(duration) = item.kind, !duration.isEmpty {
                    Text(duration)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.72))
                        .foregroundStyle(.white)
                        .padding(4)
                } else if case .microphone = item.kind {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(6)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipped()
            .overlay(
                RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous)
                    .strokeBorder(isPlaying ? ProShowTheme.meterSafe : (isSelected ? ProShowTheme.accent : Color.clear), lineWidth: isPlaying || isSelected ? 2 : 0)
            )

            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(width: width, alignment: .leading)
                .foregroundStyle(isPlaying ? ProShowTheme.accent : ShowSidebarPalette.title)
        }
        .accessibilityAddTraits(isPlaying ? .updatesFrequently : [])
        .accessibilityValue(isPlaying ? "Playing" : "")
    }
}

private struct PlayingEqualizerBars: View {
    var reduceMotion: Bool
    @State private var onScreen = false

    var body: some View {
        Group {
            if reduceMotion || !onScreen {
                bars(heights: [8, 12, 7] as [CGFloat])
            } else {
                TimelineView(.animation(minimumInterval: 0.08, paused: false)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    bars(heights: (0..<3).map { index in
                        CGFloat(6 + (sin(t * 7 + Double(index) * 1.1) + 1) * 5)
                    })
                }
            }
        }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .accessibilityHidden(true)
    }

    private func bars(heights: [CGFloat]) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(ProShowTheme.meterSafe)
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 16, alignment: .bottom)
    }
}
