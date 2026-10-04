import Foundation

extension ShowController {
    var programPlaylistItemSubtitle: String {
        let doc = rundownClock.program ?? programDocument
        let count = ProgramOutlinePresentation.slideCount(in: doc)
        let slideWord = count == 1 ? "slide" : "slides"
        let title = doc.showTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return "\(count) program \(slideWord)"
        }
        return "\(count) program \(slideWord) · \(title)"
    }

    func selectProgramPlaylistItem() {
        if !isProgramPlaylistItemSelected {
            syncProgramSlidesFromOutline()
        }
        isProgramPlaylistItemSelected = true
        selectedPlaylistItemTitle = ProgramOutlinePresentation.playlistTitle
        loadProgramOutlinePresentation()
        prefetchProgramSlidePageFrames()
    }

    #if os(macOS)
    func prefetchProgramSlidePageFrames() {
        let doc = rundownClock.program ?? programDocument
        let urls = doc.rundownBlocks.compactMap { block in
            ProgramOutlinePresentation.resolvedPageURL(
                for: block,
                in: doc,
                showLookup: { id in self.show(matching: id) }
            )
        }
        guard !urls.isEmpty else { return }
        for url in urls.prefix(4) {
            ProgramPageRaster.shared.prefetch([url])
        }
    }
    #else
    func prefetchProgramSlidePageFrames() {}
    #endif

    func syncProgramSlidesFromOutline() {
        mutateProgramDocument { doc in
            ProgramOutlinePresentation.syncProgramSlides(
                in: &doc,
                mediaLookup: { id in self.allMediaItems.first(where: { $0.id == id }) },
                showLookup: { id in self.show(matching: id) },
                playlistShowLookup: { playlistItemID in
                    guard let item = self.playlist.items.first(where: { $0.id == playlistItemID }),
                          let showID = item.showID
                    else { return nil }
                    return self.show(matching: showID)
                }
            )
        }
    }

    func show(matching id: UUID) -> Show? {
        if show.id == id { return show }
        if id == ProgramOutlinePresentation.showID {
            let doc = rundownClock.program ?? programDocument
            return ProgramOutlinePresentation.makeShow(from: doc)
        }
        return libraryShows.first(where: { $0.id == id })
    }

    func ensureProgramSlide(for block: RundownBlock) {
        mutateProgramDocument { doc in
            guard let index = doc.rundownBlocks.firstIndex(where: { $0.id == block.id }) else { return }
            ProgramOutlinePresentation.syncProgramSlide(
                at: index,
                in: &doc,
                mediaLookup: { id in self.allMediaItems.first(where: { $0.id == id }) },
                showLookup: { id in self.show(matching: id) },
                playlistShowLookup: { playlistItemID in
                    guard let item = self.playlist.items.first(where: { $0.id == playlistItemID }),
                          let showID = item.showID
                    else { return nil }
                    return self.show(matching: showID)
                }
            )
        }
    }

    func programSlideID(for block: RundownBlock) -> UUID? {
        let doc = rundownClock.program ?? programDocument
        let blockID = doc.rundownBlocks.first(where: { $0.id == block.id })?.programSlideID ?? block.programSlideID
        guard let blockID, doc.programSlides.contains(where: { $0.id == blockID }) else { return nil }
        return blockID
    }

    func programSlide(for block: RundownBlock) -> Slide? {
        let doc = rundownClock.program ?? programDocument
        let stored = doc.rundownBlocks.first(where: { $0.id == block.id }) ?? block
        return ProgramOutlinePresentation.programSlide(
            for: stored,
            in: doc,
            showLookup: { id in self.show(matching: id) }
        )
    }

    func linkedPresentationTarget(for block: RundownBlock) -> (show: Show, slideID: UUID)? {
        let doc = rundownClock.program ?? programDocument
        let stored = doc.rundownBlocks.first(where: { $0.id == block.id }) ?? block
        guard let link = ProgramOutlinePresentation.linkedPresentationIDs(for: stored),
              let show = show(matching: link.showID),
              show.id != ProgramOutlinePresentation.showID,
              show.slide(id: link.slideID) != nil
        else { return nil }
        return (show, link.slideID)
    }

    func openAddShotForRundownProgramSlide(onAssign: @escaping (DiscoveredSourceItem) -> Void) {
        RundownProgramSlideAssignSession.begin(onAssign)
        addShotPurpose = .assignRundownProgramSlide
        isAddShotOpen = true
    }

    func clearProgramPlaylistSelection() {
        isProgramPlaylistItemSelected = false
    }

    func refreshProgramOutlinePresentationIfSelected() {
        guard isProgramPlaylistItemSelected else { return }
        loadProgramOutlinePresentation()
    }

    func programPlaylistItemMatchesFilter(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if ProgramOutlinePresentation.playlistTitle.localizedCaseInsensitiveContains(query) { return true }
        return programPlaylistItemSubtitle.localizedCaseInsensitiveContains(query)
    }

    func syncProgramOutlineFromActiveShowIfNeeded() {
        guard isProgramPlaylistItemSelected, show.id == ProgramOutlinePresentation.showID else { return }
        var doc = rundownClock.program ?? programDocument
        ProgramOutlinePresentation.applyShow(show, to: &doc)
        programDocument = doc
        rundownClock.replaceProgram(doc)
    }

}
