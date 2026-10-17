import Foundation

extension ShowController {
    var selectedContentLibrary: ContentLibrary? {
        guard let id = selectedContentLibraryID else { return contentLibraries.first }
        return contentLibraries.first(where: { $0.id == id }) ?? contentLibraries.first
    }

    func playlists(in library: ContentLibrary) -> [Playlist] {
        library.playlistIDs.compactMap { id in allPlaylists.first(where: { $0.id == id }) }
    }

    func ensureLibraryHierarchyLoaded(projectPlaylists: [Playlist]) {
        if !projectPlaylists.isEmpty {
            allPlaylists = projectPlaylists
        }
        if allPlaylists.isEmpty {
            allPlaylists = [DefaultSeedData.emptyPlaylist()]
        }
        if contentLibraries.isEmpty {
            contentLibraries = [DefaultSeedData.defaultContentLibrary(playlistIDs: allPlaylists.map(\.id))]
        }
        if selectedContentLibraryID == nil {
            selectedContentLibraryID = contentLibraries.first?.id
        }
        // Playlists saved in the project but listed in no library (e.g. built by a spec script)
        // were invisible in the sidebar. Attach them to the selected library so they show up.
        let listed = Set(contentLibraries.flatMap(\.playlistIDs))
        let orphans = allPlaylists.map(\.id).filter { !listed.contains($0) }
        if !orphans.isEmpty,
           let index = contentLibraries.firstIndex(where: { $0.id == selectedContentLibraryID }) ?? contentLibraries.indices.first {
            contentLibraries[index].playlistIDs.append(contentsOf: orphans)
        }
        let activeID = workspaceLayout.sidebar.selectedPlaylistId
        if !activeID.isEmpty,
           let uuid = UUID(uuidString: activeID),
           allPlaylists.contains(where: { $0.id == uuid }) {
            setActivePlaylist(id: uuid, persist: false)
        } else if !allPlaylists.contains(where: { $0.id == playlist.id }) {
            setActivePlaylist(id: allPlaylists[0].id, persist: false)
        } else {
            syncActivePlaylistFromStore()
        }
        syncLibraryItems()
        syncPlaylistItemTitlesFromLibraryShows()
    }

    func selectContentLibrary(id: UUID) {
        selectedContentLibraryID = id
        guard let library = contentLibraries.first(where: { $0.id == id }),
              let firstPlaylist = playlists(in: library).first
        else { return }
        setActivePlaylist(id: firstPlaylist.id, persist: true)
    }

    func selectPlaylist(id: UUID) {
        setActivePlaylist(id: id, persist: true)
    }

    @discardableResult
    func addContentLibrary(named name: String) -> ContentLibrary? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let library = ContentLibrary(name: trimmedName)
        contentLibraries.append(library)
        selectedContentLibraryID = library.id
        persistLibraryHierarchy()
        rebuildSearchIndex()
        return library
    }

    func renameContentLibrary(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = contentLibraries.firstIndex(where: { $0.id == id })
        else { return }
        contentLibraries[index].name = trimmed
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    func deleteContentLibrary(id: UUID) {
        guard contentLibraries.count > 1,
              let index = contentLibraries.firstIndex(where: { $0.id == id })
        else { return }
        let removed = contentLibraries.remove(at: index)
        for playlistID in removed.playlistIDs {
            deletePlaylist(id: playlistID, allowLastInLibrary: true)
        }
        if selectedContentLibraryID == id {
            selectedContentLibraryID = contentLibraries.first?.id
        }
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    @discardableResult
    func addPlaylistToSelectedLibrary(named name: String) -> Playlist? {
        guard let libraryID = selectedContentLibrary?.id else { return nil }
        return addPlaylist(named: name, toLibrary: libraryID)
    }

    func renamePlaylist(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = allPlaylists.firstIndex(where: { $0.id == id })
        else { return }
        allPlaylists[index].name = trimmed
        syncActivePlaylistFromStore()
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    func deletePlaylist(id: UUID, allowLastInLibrary: Bool = false) {
        guard let libraryIndex = contentLibraries.firstIndex(where: { $0.playlistIDs.contains(id) }),
              allowLastInLibrary || contentLibraries[libraryIndex].playlistIDs.count > 1
        else { return }
        contentLibraries[libraryIndex].playlistIDs.removeAll { $0 == id }
        allPlaylists.removeAll { $0.id == id }
        if playlist.id == id {
            let next = contentLibraries[libraryIndex].playlistIDs.first.flatMap { pid in
                allPlaylists.first(where: { $0.id == pid })
            } ?? allPlaylists.first
            if let next {
                setActivePlaylist(id: next.id, persist: true)
            }
        } else {
            syncActivePlaylistFromStore()
        }
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    @discardableResult
    func addPresentationToActivePlaylist(named name: String) -> Show? {
        let created = addPresentation(named: name)
        appendShowToActivePlaylist(created)
        return created
    }

    func appendShowToActivePlaylist(_ show: Show) {
        mutateActivePlaylist { playlist in
            playlist.items.append(
                PlaylistItem(kind: .show, title: show.name, showID: show.id)
            )
        }
        syncLibraryItems()
        persistLibraryHierarchy()
    }

    func removePlaylistItem(id: UUID, deletePresentationFile: Bool) {
        var removedShowID: ShowID?
        mutateActivePlaylist { playlist in
            if let index = playlist.items.firstIndex(where: { $0.id == id }) {
                removedShowID = playlist.items[index].showID
                playlist.items.remove(at: index)
            }
        }
        syncLibraryItems()
        if deletePresentationFile, let removedShowID {
            deletePresentation(id: removedShowID)
        } else {
            persistLibraryHierarchy()
        }
    }

    func renamePlaylistItem(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var linkedShowID: ShowID?
        mutateActivePlaylist { playlist in
            guard let index = playlist.items.firstIndex(where: { $0.id == id }) else { return }
            playlist.items[index].title = trimmed
            if playlist.items[index].kind == .show {
                linkedShowID = playlist.items[index].showID
            }
        }
        if let linkedShowID {
            let isActivePresentation = linkedShowID == show.id
            renamePresentation(id: linkedShowID, to: trimmed, persistShowFile: !isActivePresentation)
        }
        syncLibraryItems()
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    /// Keeps playlist row titles aligned with on-disk presentation names (e.g. after crash mid-rename).
    func syncPlaylistItemTitlesFromLibraryShows() {
        let names = Dictionary(uniqueKeysWithValues: libraryShows.map { ($0.id, $0.name) })
        var changed = false
        for playlistIndex in allPlaylists.indices {
            for itemIndex in allPlaylists[playlistIndex].items.indices {
                guard allPlaylists[playlistIndex].items[itemIndex].kind == .show,
                      let showID = allPlaylists[playlistIndex].items[itemIndex].showID,
                      let canonical = names[showID],
                      allPlaylists[playlistIndex].items[itemIndex].title != canonical
                else { continue }
                allPlaylists[playlistIndex].items[itemIndex].title = canonical
                changed = true
            }
        }
        guard changed else { return }
        syncActivePlaylistFromStore()
        syncLibraryItems()
    }

    func persistLibraryHierarchy() {
        persistMediaLibrary()
        for playlist in allPlaylists {
            try? projectAutosave?.record(.upsertPlaylist(playlist))
        }
        workspaceLayout.sidebar.selectedLibraryId = selectedContentLibraryID?.uuidString ?? ""
        workspaceLayout.sidebar.selectedPlaylistId = playlist.id.uuidString
        try? projectAutosave?.record(.updateState(captureWorkspaceState()))
    }

    func mutateActivePlaylist(_ body: (inout Playlist) -> Void) {
        body(&playlist)
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            allPlaylists[index] = playlist
        }
    }

    func setActivePlaylist(id: UUID, persist: Bool) {
        guard let found = allPlaylists.first(where: { $0.id == id }) else { return }
        playlist = found
        workspaceLayout.sidebar.selectedPlaylistId = id.uuidString
        syncLibraryItems()
        if persist {
            persistLibraryHierarchy()
        }
    }

    func syncActivePlaylistFromStore() {
        if let index = allPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            playlist = allPlaylists[index]
        }
    }

    @discardableResult
    func addPlaylist(named name: String, toLibrary libraryID: UUID) -> Playlist? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let libraryIndex = contentLibraries.firstIndex(where: { $0.id == libraryID })
        else { return nil }
        let created = Playlist(name: trimmedName, items: [])
        allPlaylists.append(created)
        contentLibraries[libraryIndex].playlistIDs.append(created.id)
        selectedContentLibraryID = libraryID
        setActivePlaylist(id: created.id, persist: true)
        persistLibraryHierarchy()
        rebuildSearchIndex()
        return created
    }

    @discardableResult
    func addPresentation(named name: String, toPlaylist playlistID: UUID) -> Show? {
        let created = addPresentation(named: name)
        guard let index = allPlaylists.firstIndex(where: { $0.id == playlistID }) else { return created }
        allPlaylists[index].items.append(PlaylistItem(kind: .show, title: created.name, showID: created.id))
        if playlist.id == playlistID {
            syncActivePlaylistFromStore()
            syncLibraryItems()
        } else {
            setActivePlaylist(id: playlistID, persist: false)
        }
        persistLibraryHierarchy()
        return created
    }

    func duplicatePlaylist(id: UUID) {
        guard let source = allPlaylists.first(where: { $0.id == id }),
              let libraryIndex = contentLibraries.firstIndex(where: { $0.playlistIDs.contains(id) })
        else { return }
        var copy = Playlist(id: UUID(), name: copiedPlaylistName(source.name), typeName: source.typeName, items: [])
        for item in source.items {
            if item.kind == .show, let showID = item.showID, let duplicated = duplicateShowDocument(showID) {
                copy.items.append(PlaylistItem(kind: .show, title: duplicated.name, showID: duplicated.id))
            } else {
                var row = item
                row.id = UUID()
                copy.items.append(row)
            }
        }
        allPlaylists.append(copy)
        contentLibraries[libraryIndex].playlistIDs.append(copy.id)
        setActivePlaylist(id: copy.id, persist: true)
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    @discardableResult
    func duplicatePresentationItem(id: UUID) -> Show? {
        guard let item = playlist.items.first(where: { $0.id == id }),
              item.kind == .show,
              let showID = item.showID,
              let copy = duplicateShowDocument(showID)
        else { return nil }
        appendShowToActivePlaylist(copy)
        loadPresentation(id: copy.id)
        return copy
    }

    func addSlide(toPresentation showID: ShowID) {
        if show.id != showID {
            loadPresentation(id: showID)
        }
        guard show.id == showID else { return }
        _ = addSlide(named: "Slide \(show.allSlides.count + 1)")
        if editors.kind == .presentation {
            editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
        }
    }

    /// Explicit cut. Choosing a presentation in the sidebar only opens it for editing.
    func takePresentationLive(showID: ShowID) {
        if show.id != showID {
            loadPresentation(id: showID)
        }
        guard show.id == showID, let slideID = show.allSlides.first?.id else { return }
        goLive(slideID: slideID)
    }

    func movePlaylistItem(id: UUID, to playlistID: UUID) {
        guard playlistID != playlist.id else { return }
        var moved: PlaylistItem?
        mutateActivePlaylist { list in
            if let index = list.items.firstIndex(where: { $0.id == id }) {
                moved = list.items.remove(at: index)
            }
        }
        guard let moved, let index = allPlaylists.firstIndex(where: { $0.id == playlistID }) else { return }
        allPlaylists[index].items.append(moved)
        syncLibraryItems()
        persistLibraryHierarchy()
        rebuildSearchIndex()
    }

    private func duplicateShowDocument(_ showID: ShowID) -> Show? {
        if show.id == showID {
            rehydrateFromEditor(persist: true)
        }
        let source = show.id == showID ? show : libraryShows.first(where: { $0.id == showID })
        guard let source else { return nil }
        var copy = source
        copy.id = UUID()
        copy.name = copiedPresentationName(source.name)
        copy.groups = source.groups.map { group in
            var group = group
            group.id = UUID()
            group.slides = group.slides.map { $0.copyAsNew() }
            return group
        }
        libraryShows.append(copy)
        try? store.save(copy)
        try? projectAutosave?.record(.upsertLibrary(copy))
        rebuildSearchIndex()
        return copy
    }

    private func copiedPresentationName(_ name: String) -> String {
        let base = name.hasSuffix(" Copy") ? name : "\(name) Copy"
        let existing = Set(libraryShows.map(\.name))
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func copiedPlaylistName(_ name: String) -> String {
        let base = name.hasSuffix(" Copy") ? name : "\(name) Copy"
        let existing = Set(allPlaylists.map(\.name))
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
