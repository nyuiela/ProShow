import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Left column: selected library’s playlists, then that playlist’s presentations. Media sits beneath.
struct LibrarySidebarView: View {
    @Bindable var controller: ShowController
    @State private var expandedGroup: SidebarGroup?
    @State private var renameTarget: SidebarRenameTarget?
    @State private var renameText = ""
    @State private var createDraft: SidebarCreateDraft?

    private var selectedLibrary: ContentLibrary? {
        controller.selectedContentLibrary
    }

    private var playlistsInLibrary: [Playlist] {
        guard let library = selectedLibrary else { return [] }
        return controller.playlists(in: library)
    }

    private var filteredLibraries: [ContentLibrary] {
        filterLibraries(controller.contentLibraries)
    }

    private var filteredPlaylists: [Playlist] {
        filterPlaylists(playlistsInLibrary)
    }

    private var filteredItems: [LibraryShowItem] {
        let query = controller.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = controller.libraryItems
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var showsProgramPlaylistItem: Bool {
        controller.programPlaylistItemMatchesFilter(controller.libraryQuery)
    }

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            SidebarTitleGroupSlot {
                WorkspaceTitleGroup(controller: controller)
            }
            if controller.isSearchOpen {
                ShowSidebarSearchField(placeholder: "Search songs, presentations, and media", text: $controller.libraryQuery)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !controller.searchHits.isEmpty {
                        SidebarSectionHeader(title: "Search", showsAdd: false)
                        ForEach(controller.searchHits) { hit in
                            Button {
                                controller.activateSearchHit(hit)
                            } label: {
                                SidebarRow(title: hit.title, systemImage: searchIcon(hit.kind))
                            }
                            .buttonStyle(DeskPressButtonStyle())
                            .accessibilityLabel(hit.title)
                        }
                    }

                    SidebarDisclosureGroup(
                        title: selectedLibrary?.name ?? "Library",
                        isExpanded: expandedGroup == .library,
                        onToggle: { toggleGroup(.library) }
                    ) {
                        ForEach(filteredLibraries) { library in
                            SidebarHierarchyRow(
                                title: library.name,
                                systemImage: "folder.fill",
                                isSelected: controller.selectedContentLibraryID == library.id,
                                embedded: true
                            ) {
                                controller.selectContentLibrary(id: library.id)
                                expandedGroup = nil
                            }
                            .contextMenu {
                                libraryContextMenu(library)
                            }
                        }
                    }

                    SidebarFixedSection(title: "Playlists") {
                        ForEach(filteredPlaylists) { playlist in
                            SidebarHierarchyRow(
                                title: playlist.name,
                                systemImage: "list.bullet.rectangle",
                                isSelected: controller.playlist.id == playlist.id,
                                embedded: true
                            ) {
                                controller.selectPlaylist(id: playlist.id)
                            }
                            .contextMenu {
                                playlistContextMenu(playlist)
                            }
                        }
                        if filteredPlaylists.isEmpty {
                            SidebarEmptyNote(text: "No playlists in this library.")
                        }
                    }

                    SidebarFixedSection(title: "Presentations") {
                        if showsProgramPlaylistItem {
                            SidebarHierarchyRow(
                                title: ProgramOutlinePresentation.playlistTitle,
                                subtitle: controller.programPlaylistItemSubtitle,
                                systemImage: "rectangle.stack",
                                isSelected: controller.isProgramPlaylistItemSelected,
                                embedded: true
                            ) {
                                controller.selectProgramPlaylistItem()
                            }
                            .accessibilityHint("Outline slides in rundown order")
                        }
                        ForEach(filteredItems) { item in
                            SidebarHierarchyRow(
                                title: item.title,
                                subtitle: item.subtitle,
                                systemImage: item.showID == nil ? "note.text" : "rectangle.stack",
                                isSelected: isPlaylistItemSelected(item),
                                embedded: true
                            ) {
                                controller.clearProgramPlaylistSelection()
                                if let showID = item.showID {
                                    controller.loadPresentation(id: showID)
                                } else {
                                    controller.selectedPlaylistItemTitle = item.title
                                }
                            }
                            .contextMenu {
                                presentationContextMenu(item)
                            }
                        }
                        if filteredItems.isEmpty, !showsProgramPlaylistItem {
                            SidebarEmptyNote(text: "No presentations in this playlist.")
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            SidebarAddMenu(controller: controller) { createDraft = $0 }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 10)
            .padding(.bottom, 4)

            ShowSidebarSearchField(placeholder: "Filter library and playlists", text: $controller.libraryQuery)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            ShowSidebarMediaDock(controller: controller)
        }
        .background {
            ShowSidebarPalette.background(scheme)
                .ignoresSafeArea(edges: .top)
        }
        .modifier(ShowSidebarSystemScheme())
        .sheet(item: $createDraft) { draft in
            SidebarCreateSheet(draft: draft, controller: controller) {
                switch draft {
                case .library: expandedGroup = .library
                case .playlist: expandedGroup = .playlist
                case .presentation: break
                }
            }
        }
        .alert("Rename", isPresented: renamePresented) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {
                renameTarget = nil
            }
            Button("Save") {
                commitRename()
            }
        }
    }

    @ViewBuilder
    private func libraryContextMenu(_ library: ContentLibrary) -> some View {
        Button("Rename…") {
            beginRename(.library(library.id), current: library.name)
        }
        Button("New Playlist") {
            createDraft = .playlist(library.id)
        }
        if controller.contentLibraries.count > 1 {
            Divider()
            Button("Delete", role: .destructive) {
                controller.deleteContentLibrary(id: library.id)
            }
        }
    }

    @ViewBuilder
    private func playlistContextMenu(_ playlist: Playlist) -> some View {
        Button("Rename…") {
            beginRename(.playlist(playlist.id), current: playlist.name)
        }
        Button("New Presentation") {
            createDraft = .presentation(playlist.id)
        }
        Button("Duplicate") {
            controller.duplicatePlaylist(id: playlist.id)
        }
        if playlistsInLibrary.count > 1 {
            Divider()
            Button("Delete", role: .destructive) {
                controller.deletePlaylist(id: playlist.id)
            }
        }
    }

    @ViewBuilder
    private func presentationContextMenu(_ item: LibraryShowItem) -> some View {
        Button("Rename…") {
            beginRename(.item(item.id), current: item.title)
        }
        if let showID = item.showID {
            Button("Add Slide") {
                controller.addSlide(toPresentation: showID)
            }
            Button("Duplicate") {
                _ = controller.duplicatePresentationItem(id: item.id)
            }
            Button("Take Live") {
                controller.takePresentationLive(showID: showID)
            }
            if !otherPlaylistsInLibrary.isEmpty {
                Menu("Move to Playlist") {
                    ForEach(otherPlaylistsInLibrary) { playlist in
                        Button(playlist.name) {
                            controller.movePlaylistItem(id: item.id, to: playlist.id)
                        }
                    }
                }
            }
            Divider()
            Button("Remove from Playlist") {
                controller.removePlaylistItem(id: item.id, deletePresentationFile: false)
            }
            Button("Delete", role: .destructive) {
                controller.removePlaylistItem(id: item.id, deletePresentationFile: true)
            }
        } else {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                controller.removePlaylistItem(id: item.id, deletePresentationFile: false)
            }
        }
    }

    private var otherPlaylistsInLibrary: [Playlist] {
        playlistsInLibrary.filter { $0.id != controller.playlist.id }
    }

    private func toggleGroup(_ group: SidebarGroup) {
        expandedGroup = expandedGroup == group ? nil : group
    }

    private func isPlaylistItemSelected(_ item: LibraryShowItem) -> Bool {
        guard !controller.isProgramPlaylistItemSelected else { return false }
        if let showID = item.showID {
            return controller.show.id == showID
        }
        return controller.selectedPlaylistItemTitle == item.title
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private func beginRename(_ target: SidebarRenameTarget, current: String) {
        renameTarget = target
        renameText = current
    }

    private func commitRename() {
        let target = renameTarget
        let text = renameText
        renameTarget = nil
        renameText = ""
        guard let target else { return }
        DispatchQueue.main.async {
            applyRename(target: target, text: text)
        }
    }

    private func applyRename(target: SidebarRenameTarget, text: String) {
        switch target {
        case .library(let id):
            controller.renameContentLibrary(id: id, to: text)
        case .playlist(let id):
            controller.renamePlaylist(id: id, to: text)
        case .item(let id):
            controller.renamePlaylistItem(id: id, to: text)
        }
    }

    private func searchIcon(_ kind: SearchHit.Kind) -> String {
        switch kind {
        case .media: "film"
        case .presentation: "rectangle.stack"
        case .playlist: "list.bullet.rectangle"
        case .library: "folder"
        case .bible: "book"
        }
    }

    private func filterLibraries(_ libraries: [ContentLibrary]) -> [ContentLibrary] {
        let query = controller.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return libraries }
        return libraries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func filterPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        let query = controller.libraryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return playlists }
        return playlists.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

private enum SidebarCreateDraft: Identifiable {
    case library
    case playlist(UUID)
    case presentation(UUID)

    var id: String {
        switch self {
        case .library: "library"
        case .playlist(let id): "playlist-\(id.uuidString)"
        case .presentation(let id): "presentation-\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .library: "New Library"
        case .playlist: "New Playlist"
        case .presentation: "New Presentation"
        }
    }

}

private struct SidebarCreateSheet: View {
    let draft: SidebarCreateDraft
    @Bindable var controller: ShowController
    var onCreated: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DeskSpace.md) {
            Text(draft.title)
                .font(DeskType.title)
                .foregroundStyle(ProShowTheme.primaryLabel)
            VStack(alignment: .leading, spacing: DeskSpace.xs) {
                Text("Name")
                    .font(DeskType.meta.weight(.semibold))
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { commit() }
            }
            if trimmedName.isEmpty {
                Text("Name is required.")
                    .font(DeskType.meta)
                    .foregroundStyle(ProShowTheme.secondaryLabel)
                    .accessibilityLabel("Name is required")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(DeskSpace.lg)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        switch draft {
        case .library:
            _ = controller.addContentLibrary(named: trimmedName)
        case .playlist(let libraryID):
            _ = controller.addPlaylist(named: trimmedName, toLibrary: libraryID)
        case .presentation(let playlistID):
            if let created = controller.addPresentation(named: trimmedName, toPlaylist: playlistID) {
                controller.loadPresentation(id: created.id)
            }
        }
        onCreated()
        dismiss()
    }
}

private enum SidebarGroup: Hashable {
    case library
    case playlist
    case items
}

private enum SidebarRenameTarget: Equatable {
    case library(UUID)
    case playlist(UUID)
    case item(UUID)
}

private struct ShowSidebarMediaDock: View {
    @Bindable var controller: ShowController

    var body: some View {
        VStack(spacing: 2) {
            ForEach(controller.orderedMediaSources.reversed()) { source in
                SidebarHierarchyRow(
                    title: source.title,
                    systemImage: source.systemImage,
                    isSelected: controller.selectedMediaSource == source
                ) {
                    controller.openMediaPane(source: source)
                }
            }

            #if os(macOS)
            ProShowResourceFooter()
            #endif
        }
    }
}

#if os(macOS)
private struct ProcessResourceSample: Equatable {
    var cpu = "—"
    var memory = "—"
    var gpu = "—"
    var spoken = "Measuring ProShow processor, memory, and graphics use"
}

/// CPU, resident memory, and GPU time for this ProShow process.
@MainActor
private final class ProcessResourceMeter {
    private var lastCPU: UInt64 = 0
    private var lastWall: UInt64 = 0
    private var lastGPU: UInt64 = 0
    private var primed = false

    func poll() -> ProcessResourceSample {
        var absolute = task_absolutetime_info()
        var basic = mach_task_basic_info()
        var power = task_power_info_v2()
        let cpuOK = Self.read(TASK_ABSOLUTETIME_INFO, &absolute)
        let memoryOK = Self.read(MACH_TASK_BASIC_INFO, &basic)
        let gpuOK = Self.read(TASK_POWER_INFO_V2, &power)
        let wall = mach_absolute_time()
        let cpuTicks = absolute.total_user &+ absolute.total_system
        let gpuTicks = power.gpu_energy.task_gpu_utilisation

        var cpuText = "—"
        var gpuText = "—"
        if primed, wall > lastWall {
            if cpuOK {
                let cpu = Double(cpuTicks &- lastCPU) / Double(wall &- lastWall) * 100
                cpuText = Self.percent(cpu)
            }
            if gpuOK {
                var timebase = mach_timebase_info_data_t()
                mach_timebase_info(&timebase)
                let wallNanoseconds = Double(wall &- lastWall) * Double(timebase.numer) / Double(timebase.denom)
                if wallNanoseconds > 0 {
                    let gpu = Double(gpuTicks &- lastGPU) / wallNanoseconds * 100
                    gpuText = Self.percent(gpu)
                }
            }
        }
        lastCPU = cpuTicks
        lastGPU = gpuTicks
        lastWall = wall
        primed = true

        let memoryText = memoryOK ? Self.memory(bytes: basic.resident_size) : "—"
        return ProcessResourceSample(
            cpu: cpuText,
            memory: memoryText,
            gpu: gpuText,
            spoken: "ProShow CPU \(cpuText), memory \(memoryText), GPU \(gpuText)"
        )
    }

    private static func percent(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < 10_000 else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private static func memory(bytes: mach_vm_size_t) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        return "\(Int(megabytes.rounded())) MB"
    }

    private static func read<T>(_ flavor: Int32, _ body: inout T) -> Bool {
        var count = mach_msg_type_number_t(MemoryLayout<T>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &body) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(flavor), $0, &count)
            }
        }
        return result == KERN_SUCCESS
    }
}

private struct ProShowResourceFooter: View {
    @State private var meter = ProcessResourceMeter()
    @State private var sample = ProcessResourceSample()

    var body: some View {
        HStack(spacing: 12) {
            readout("CPU", sample.cpu)
            readout("RAM", sample.memory)
            readout("GPU", sample.gpu)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ShowSidebarPalette.subtitle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sample.spoken)
        .task {
            while !Task.isCancelled {
                sample = meter.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func readout(_ name: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(name)
            Text(value)
                .foregroundStyle(ShowSidebarPalette.title)
                .monospacedDigit()
        }
        .lineLimit(1)
    }
}
#endif

enum ShowSidebarPalette {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.965, green: 0.965, blue: 0.972)
    }

    static func selection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    static func field(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)
    }

    static var title: Color { .primary }
    static var subtitle: Color { .secondary }
    static var symbol: Color { .secondary }
}

/// Media drawer surface. Same type and selection language as the sidebars, one step off their fill.
enum ShowDrawerPalette {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.16, green: 0.16, blue: 0.17)
            : Color(red: 0.925, green: 0.925, blue: 0.935)
    }
}

struct ShowSidebarSearchField: View {
    var placeholder: String
    @Binding var text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(ShowSidebarPalette.title)
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(ShowSidebarPalette.field(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ShowSidebarSystemScheme: ViewModifier {
    @State private var scheme: ColorScheme = .light

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(scheme)
            .onAppear { refresh() }
            #if os(macOS)
            .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
                refresh()
            }
            #endif
    }

    private func refresh() {
        #if os(macOS)
        let match = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        scheme = match == .darkAqua ? .dark : .light
        #else
        scheme = .dark
        #endif
    }
}

private struct SidebarHierarchyRow: View {
    let title: String
    var subtitle: String = ""
    var systemImage: String?
    var isSelected: Bool = false
    var embedded: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ShowSidebarPalette.symbol)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(ShowSidebarPalette.title)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(ShowSidebarPalette.subtitle)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Circle()
                        .fill(ShowSidebarPalette.title)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskPressButtonStyle())
        .padding(.horizontal, embedded ? 0 : 8)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }
}

private struct SidebarFixedSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ShowSidebarPalette.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ShowSidebarPalette.selection(scheme))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private struct SidebarEmptyNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(ShowSidebarPalette.subtitle)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .accessibilityLabel(text)
    }
}

private struct SidebarDisclosureGroup<Content: View>: View {
    let title: String
    var isExpanded: Bool
    var titlePlacement: SidebarGroupTitlePlacement = .top
    var onToggle: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titlePlacement == .bottom, isExpanded {
                content()
            }
            Button(action: onToggle) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DeskPressButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Hides the list" : "Shows the list")
            if titlePlacement == .top, isExpanded {
                content()
            }
        }
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ShowSidebarPalette.selection(scheme))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

private enum SidebarGroupTitlePlacement {
    case top
    case bottom
}

struct SidebarSectionHeader: View {
    let title: String
    var showsAdd: Bool
    var isExpanded: Bool = true
    var onToggle: (() -> Void)?
    var onAdd: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ShowSidebarPalette.subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsAdd {
                DeskIconButton(systemImage: "plus", label: "Add \(title.lowercased())") {
                    onAdd?()
                }
            }
            if onToggle != nil {
                DeskIconButton(
                    systemImage: isExpanded ? "chevron.up" : "chevron.down",
                    label: isExpanded ? "Collapse \(title)" : "Expand \(title)"
                ) {
                    onToggle?()
                }
            }
        }
        .padding(.horizontal, DeskSpace.xs)
        .padding(.vertical, 4)
    }
}

struct SidebarRow: View {
    let title: String
    let systemImage: String
    var indented: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ShowSidebarPalette.symbol)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(ShowSidebarPalette.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, indented ? 24 : DeskSpace.sm)
        .padding(.trailing, DeskSpace.xs)
        .frame(minHeight: DeskLayout.hit)
    }
}

struct SidebarSelectableRow: View {
    let title: String
    var subtitle: String = ""
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(ShowSidebarPalette.title)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ShowSidebarPalette.subtitle)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                isSelected ? ShowSidebarPalette.selection(scheme) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(DeskPressButtonStyle())
        .padding(.horizontal, 8)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Universal add control. Liquid glass circle; the menu is the place to create show material.
private struct SidebarAddMenu: View {
    @Bindable var controller: ShowController
    var onCreate: (SidebarCreateDraft) -> Void

    private var canAddPlaylist: Bool {
        controller.selectedContentLibrary != nil
    }

    private var canAddPresentation: Bool {
        guard let library = controller.selectedContentLibrary else { return false }
        return controller.playlists(in: library).contains(where: { $0.id == controller.playlist.id })
    }

    var body: some View {
        Menu {
            Button("New Library", systemImage: "folder.badge.plus") {
                onCreate(.library)
            }
            Button("New Playlist", systemImage: "list.bullet.rectangle") {
                guard let libraryID = controller.selectedContentLibraryID else { return }
                onCreate(.playlist(libraryID))
            }
            .disabled(!canAddPlaylist)
            Button("New Presentation", systemImage: "rectangle.stack.badge.plus") {
                onCreate(.presentation(controller.playlist.id))
            }
            .disabled(!canAddPresentation)
            Button("Add Shot", systemImage: "plus.rectangle.on.folder") {
                controller.openAddShot(layerIndex: controller.addShotLayerIndex)
            }
            Menu("Theme", systemImage: "paintpalette") {
                ForEach(DeskSampleData.themes, id: \.self) { name in
                    Button {
                        controller.applyTheme(name)
                    } label: {
                        if controller.selectedTheme == name {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .modifier(GlassCircleMenuChrome())
        .help("Add")
        .accessibilityLabel("Add")
    }
}

/// Round liquid-glass menu button. System glass on OS 26, material circle before that.
private struct GlassCircleMenuChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                #if os(macOS)
                .menuIndicator(.hidden)
                #endif
        } else {
            content
                .modifier(BorderlessMenuChrome())
                .frame(width: 36, height: 36)
                .deskChromeGlass(in: Circle(), interactive: true)
        }
    }
}

struct SearchFieldChrome: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ProShowTheme.secondaryLabel)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(DeskType.meta)
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(ProShowTheme.well, in: RoundedRectangle(cornerRadius: DeskRadius.control, style: .continuous))
    }
}

struct PaneHairline: View {
    var body: some View {
        Rectangle()
            .fill(ProShowTheme.hairline)
            .frame(height: DeskPaneDivider.width)
    }
}
