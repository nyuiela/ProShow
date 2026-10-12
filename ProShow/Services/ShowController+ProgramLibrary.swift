import Foundation

/// Runtime / footer preview for one outline row — always the row’s slide, not the live program cue.
struct ProgramOutlineRowPreview: Sendable {
    var slide: Slide
    var canvas: [CanvasObject]
    var pageURL: String?
}

extension ShowController {
    func programDocumentRepairLookups() -> (
        media: (UUID) -> MediaBinItem?,
        show: (UUID) -> Show?,
        playlist: (UUID) -> Show?
    ) {
        (
            media: { id in self.allMediaItems.first(where: { $0.id == id }) },
            show: { id in self.show(matching: id) },
            playlist: { playlistItemID in
                guard let item = self.playlist.items.first(where: { $0.id == playlistItemID }),
                      let showID = item.showID
                else { return nil }
                return self.show(matching: showID)
            }
        )
    }

    @discardableResult
    func repairProgramDocumentIfNeeded() -> Bool {
        let lookups = programDocumentRepairLookups()
        var doc = rundownClock.program ?? programDocument
        let changed = ProgramOutlinePresentation.repairStoredProgramDocument(
            in: &doc,
            mediaLookup: lookups.media,
            showLookup: lookups.show,
            playlistShowLookup: lookups.playlist
        )
        guard changed else { return false }
        programDocument = doc
        rundownClock.replaceProgram(doc)
        refreshProgramOutlinePresentationIfSelected()
        return true
    }

    func programPreview(for block: RundownBlock) -> ProgramOutlineRowPreview? {
        let doc = rundownClock.program ?? programDocument
        let stored = doc.rundownBlocks.first(where: { $0.id == block.id }) ?? block
        guard let raw = ProgramOutlinePresentation.programSlide(
            for: stored,
            in: doc,
            showLookup: { id in self.show(matching: id) }
        ) else { return nil }
        let slide = ProgramOutlinePresentation.airPrepareSlide(raw, in: doc)
        let canvas = resolvedCanvasObjects(slide.audienceCanvas())
        var page = ProgramOutlinePresentation.pageURL(in: slide)
        if case .camera = RundownBlockSlideSource.resolve(stored) {
            page = nil
        }
        return ProgramOutlineRowPreview(slide: slide, canvas: canvas, pageURL: page)
    }

    /// Show grid / list thumbs — same prepared slide + canvas as rundown footer previews.
    func slideGridThumbnailPreview(for slide: Slide) -> ProgramOutlineRowPreview {
        if show.id == ProgramOutlinePresentation.showID {
            return programPreview(forProgramShowSlide: slide)
        }
        let canvas = resolvedCanvasObjects(slide.audienceCanvas())
        let pageURL = ProgramOutlinePresentation.pageURL(in: slide)
        return ProgramOutlineRowPreview(slide: slide, canvas: canvas, pageURL: pageURL)
    }

    private func programPreview(forProgramShowSlide slide: Slide) -> ProgramOutlineRowPreview {
        let doc = rundownClock.program ?? programDocument
        let prepared = ProgramOutlinePresentation.airPrepareSlide(slide, in: doc)
        let canvas = resolvedCanvasObjects(prepared.audienceCanvas())
        var pageURL = ProgramOutlinePresentation.pageURL(in: prepared)
        if let block = doc.rundownBlocks.first(where: { $0.programSlideID == slide.id }),
           case .camera = RundownBlockSlideSource.resolve(block) {
            pageURL = nil
        }
        return ProgramOutlineRowPreview(slide: prepared, canvas: canvas, pageURL: pageURL)
    }

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
        if show.id != ProgramOutlinePresentation.showID {
            rehydrateFromEditor(persist: true)
        }
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
        prefetchUpcomingRundownBrowserPages(fromBlockIndex: 0)
    }
    #else
    func prefetchProgramSlidePageFrames() {}
    #endif

    func syncProgramSlidesFromOutline() {
        _ = repairProgramDocumentIfNeeded()
    }

    func show(matching id: UUID) -> Show? {
        if show.id == id { return show }
        if id == ProgramOutlinePresentation.showID {
            let doc = rundownClock.program ?? programDocument
            return ProgramOutlinePresentation.makeShow(from: doc)
        }
        return libraryShows.first(where: { $0.id == id })
    }

    /// Writes the outline row and materializes its owned `.program` slide immediately.
    @discardableResult
    func commitOutlineSlideSource(for block: RundownBlock) -> RundownBlock? {
        var updated: RundownBlock?
        mutateProgramDocument { doc in
            guard let index = doc.rundownBlocks.firstIndex(where: { $0.id == block.id }) else { return }
            doc.rundownBlocks[index] = block
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
                },
                rebuildFromSource: true
            )
            updated = doc.rundownBlocks[index]
        }
        bindUnassignedProgramCameras()
        refreshProgramOutlinePresentationIfSelected()
        return updated
    }

    /// Camera outline rows are created as an empty video element. Attach the first real camera once, and keep that address on the row.
    func bindUnassignedProgramCameras() {
        guard let source = preferredBindableCamera(),
              let endpoint = source.endpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpoint.isEmpty
        else { return }
        let sourceType: SourceType = switch source.kind {
        case .ndi: .ndiSource
        case .rtsp: .srtStream
        case .webrtc: .rendezvousGuest
        case .screenShare: .systemDisplay
        default: .systemCamera
        }
        let assigned = AssignedMediaSource(
            sourceID: endpoint,
            name: source.label,
            sourceType: sourceType,
            category: .videoCapture,
            connectionString: endpoint
        )
        var doc = rundownClock.program ?? programDocument
        var changed = false
        for index in doc.rundownBlocks.indices {
            guard RundownBlockSlideSource.placeholderLetter(in: doc.rundownBlocks[index]) == nil else { continue }
            guard case .camera = RundownBlockSlideSource.resolve(doc.rundownBlocks[index]) else { continue }
            guard let slideID = doc.rundownBlocks[index].programSlideID,
                  let slideIndex = doc.programSlides.firstIndex(where: { $0.id == slideID })
            else { continue }
            var slide = doc.programSlides[slideIndex]
            var slideChanged = false
            for objectIndex in slide.canvas.indices
            where slide.canvas[objectIndex].kind == .videoInput && slide.canvas[objectIndex].assignedSource == nil {
                slide.canvas[objectIndex].applyAssignedSource(assigned)
                slide.canvas[objectIndex].name = source.label
                slideChanged = true
            }
            guard slideChanged else { continue }
            doc.programSlides[slideIndex] = slide
            ProgramOutlinePresentation.setCameraConnection(
                name: source.label,
                connection: endpoint,
                on: &doc.rundownBlocks[index]
            )
            changed = true
        }
        guard changed else { return }
        programDocument = doc
        rundownClock.replaceProgram(doc)
        refreshProgramOutlinePresentationIfSelected()
        persistProgramEdits()
    }

    private func preferredBindableCamera() -> StudioVideoSource? {
        let candidates = videoInputs.attachedSources.filter {
            $0.kind == .camera || $0.kind == .continuity || $0.kind == .captureCard || $0.kind == .ndi
        }
        return candidates.first(where: \.hasBindableHardwareEndpoint) ?? candidates.first
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
        programPreview(for: block)?.slide
    }

    /// First browser / program page URL on a slide (for context menu and reload).
    func browserPageURL(for slideID: SlideID) -> String? {
        guard let slide = show.slide(id: slideID) else { return nil }
        return ProgramOutlinePresentation.pageURL(in: slide)
    }

    #if os(macOS)
    func refreshSlideBrowserPage(slideID: SlideID) {
        guard let url = browserPageURL(for: slideID) else { return }
        ProgramPageRaster.shared.reload(url)
        guard liveSlideID == slideID, let slide = show.slide(id: slideID) else { return }
        applyLiveSceneDelta(for: slide)
        refreshLiveStack()
    }
    #endif

    func linkedPresentationTarget(for block: RundownBlock) -> (show: Show, slideID: UUID)? {
        let doc = rundownClock.program ?? programDocument
        let stored = doc.rundownBlocks.first(where: { $0.id == block.id }) ?? block
        guard stored.programSlideID == nil,
              let link = ProgramOutlinePresentation.linkedPresentationIDs(for: stored),
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
