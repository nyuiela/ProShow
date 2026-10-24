import Foundation

extension ShowController {
    static let rundownAutoAdvanceKey = "proshow.rundown.autoAdvance"

    func configureRundownEngine() {
        rundownClock.onStageCue = { [weak self] message, flash in
            guard let self else { return }
            StageCueController.applyStageMessage(message, flash: flash, controller: self)
        }
        rundownClock.onBlockStarted = { [weak self] block in
            self?.executeRundownBlock(block)
        }
        rundownClock.autoAdvanceEnabled = UserDefaults.standard.bool(forKey: Self.rundownAutoAdvanceKey)
        rundownClock.scriptStateProvider = { block in
            ShowController.promptScriptState(for: block, session: .shared, settings: .shared)
        }
        TeleprompterSession.shared.programWPMResolver = { [weak self] script in
            self?.programPromptWPM(for: script)
        }
    }

    /// Auto on/off, kept across launches.
    var rundownAutoAdvance: Bool {
        get { rundownClock.autoAdvanceEnabled }
        set {
            rundownClock.autoAdvanceEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: Self.rundownAutoAdvanceKey)
            StageCueController.syncStageRundownOverlay(controller: self)
        }
    }

    func toggleRundownAutoAdvance() {
        rundownAutoAdvance.toggle()
    }

    /// Hold freezes the item clock and auto-advance. Press again to resume.
    func toggleRundownHold() {
        rundownClock.toggleHold()
        StageCueController.syncStageRundownOverlay(controller: self)
    }

    /// +30 s on the live item.
    func extendRundownBlock() {
        rundownClock.extendActiveBlock()
        StageCueController.syncStageRundownOverlay(controller: self)
    }

    /// Space in the program: resumes a Hold, otherwise Next.
    func rundownSpaceAction() {
        if rundownClock.isShowRunning, rundownClock.isHeld {
            toggleRundownHold()
        } else {
            advanceRundownBlock()
        }
    }

    /// What the prompter says about this item's script, for the auto-advance guard.
    static func promptScriptState(
        for block: RundownBlock,
        session: TeleprompterSession,
        settings: TeleprompterSettingsStore
    ) -> RundownScriptState {
        let body = block.scriptBody
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, session.script == body else { return .none }
        switch settings.promptEngine {
        case .kinetic:
            if let at = session.engine.finishedAt { return .finished(at: at) }
            // At the end with no finish time (seeked there): nothing left to wait for.
            if session.engine.isFinished { return .none }
            if session.engine.isRunning || session.engine.activeIndex > 0 { return .reading }
        case .scroll:
            if let at = session.scroll.finishedAt { return .finished(at: at) }
            if session.scroll.isRunning || session.scroll.offset > 2 { return .reading }
        }
        // Loaded but never started: the prompter is not in use, so the duration rules.
        return .none
    }

    /// Fit-to-duration words per minute for a program script, or nil to use the prompter's own.
    func programPromptWPM(for script: String) -> Int? {
        let doc = rundownClock.program ?? programDocument
        let blocks = doc.rundownBlocks
        let preferred = [rundownClock.activeBlockIndex, rundownFocusedBlockIndex].compactMap { $0 }
        let block = preferred.compactMap { blocks.indices.contains($0) && blocks[$0].scriptBody == script ? blocks[$0] : nil }.first
            ?? blocks.first(where: { $0.scriptBody == script })
        guard let block else { return nil }
        let settings = TeleprompterSettingsStore.shared
        // The planned length only: +30 s must not change the speed of a script already rolling.
        return ProgramPromptPacing.wpm(for: block, plannedSeconds: block.plannedDurationSeconds, baseWPM: settings.baseWPM, pacing: settings.style.scriptPacing)
    }

    /// Every program advance (Next, auto, float window, double-click, start) lands here first:
    /// follow the item in the outline and the prompter, and keep the prompter rolling.
    func continueProgramPrompter(for block: RundownBlock) {
        let doc = rundownClock.program ?? programDocument
        if let index = doc.rundownBlocks.firstIndex(where: { $0.id == block.id }) {
            rundownFocusedBlockIndex = index
        }
        let session = TeleprompterSession.shared
        let keepRolling = session.rolledThrough || rundownClock.autoAdvanceEnabled
        session.loadProgramItem(script: block.scriptBody, settings: .shared, keepRolling: keepRolling)
    }

    private func noteRundownCut(block: RundownBlock, cutAt: Date, timings: [String: Int] = [:]) {
        let doc = rundownClock.program ?? programDocument
        var entry: [String: Any] = [
            "index": doc.rundownBlocks.firstIndex(where: { $0.id == block.id }) as Any? ?? NSNull(),
            "title": block.title,
            "cut_at": cutAt.timeIntervalSince1970,
            "prompter_running": TeleprompterSession.shared.isRunning,
        ]
        for (key, value) in timings { entry[key] = value }
        if let last = rundownClock.lastAdvance, last.toIndex == entry["index"] as? Int {
            entry["reason"] = last.reason.rawValue
            entry["fired_at"] = last.firedAt.timeIntervalSince1970
            if let due = last.dueAt {
                entry["due_at"] = due.timeIntervalSince1970
                entry["cut_late_ms"] = (cutAt.timeIntervalSince(due) * 1000).rounded()
            }
        }
        rundownCutLog.append(entry)
        if rundownCutLog.count > 64 { rundownCutLog.removeFirst(rundownCutLog.count - 64) }
    }

    /// Decodes the next item's design images so its cut does not wait on disk. Pages are prefetched
    /// by `prefetchRundownPageFrames`. Media and cameras are not preloaded (they start capture and audio).
    func preloadNextRundownItem(after block: RundownBlock) {
        let doc = rundownClock.program ?? programDocument
        guard let index = doc.rundownBlocks.firstIndex(where: { $0.id == block.id }) else { return }
        // A skip leaves the last preload unused: drop what the live item does not share.
        let livePaths = Set(rundownImagePaths(for: block, in: doc))
        let stale = rundownPreloadedPaths.subtracting(livePaths)
        if !stale.isEmpty, rundownPreloadedBlockID != block.id {
            for path in stale { DecodedImageCache.shared.remove(atPath: path, maxLongSide: nil) }
        }
        rundownPreloadedPaths = []
        rundownPreloadedBlockID = nil
        let nextIndex = rundownClock.autoAdvanceEnabled
            ? RundownAutoAdvanceRules.nextAutoIndex(after: index, in: doc.rundownBlocks)
            : (index + 1 < doc.rundownBlocks.count ? index + 1 : nil)
        guard let nextIndex else { return }
        let next = doc.rundownBlocks[nextIndex]
        let paths = rundownImagePaths(for: next, in: doc).filter { !livePaths.contains($0) }
        rundownPreloadedBlockID = next.id
        rundownPreloadedPaths = Set(paths.filter { !DecodedImageCache.shared.contains(atPath: $0, maxLongSide: nil) })
        guard !paths.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            for path in paths { _ = DecodedImageCache.shared.image(atPath: path, maxLongSide: nil) }
        }
    }

    /// Design image files on an item's program slide, resolved the way the program composite reads them.
    func rundownImagePaths(for block: RundownBlock, in doc: ProgramDocumentModel) -> [String] {
        guard let slideID = doc.rundownBlocks.first(where: { $0.id == block.id })?.programSlideID ?? block.programSlideID,
              let slide = doc.programSlides.first(where: { $0.id == slideID })
        else { return [] }
        var paths: [String] = []
        for object in slide.canvas {
            if object.isTextLike || object.kind.isBrowserLike { continue }
            if let path = object.assignedSource?.connectionString, !path.isEmpty,
               path.hasPrefix("/") || path.hasPrefix("~"),
               !AssignedMediaSource.pathLooksLikeVideo(path) {
                paths.append(path)
            }
            guard object.fill.type == .image else { continue }
            let raw = object.fill.imageURI.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, !AssignedMediaSource.pathLooksLikeVideo(raw) else { continue }
            #if os(macOS)
            paths.append(MediaPath.resolve(raw)?.path ?? raw)
            #else
            paths.append(raw)
            #endif
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    func loadProgramDocument(_ model: ProgramDocumentModel, url: URL? = nil) {
        var prepared = model
        let lookups = programDocumentRepairLookups()
        let repaired = ProgramOutlinePresentation.repairStoredProgramDocument(
            in: &prepared,
            mediaLookup: lookups.media,
            showLookup: lookups.show,
            playlistShowLookup: lookups.playlist
        )
        programDocument = prepared
        rundownClock.loadProgram(prepared)
        if let url {
            adoptProgramFile(url)
            if repaired {
                try? saveProgramDocument(to: url)
            }
            bindUnassignedProgramCameras()
        } else {
            programDocumentURL = nil
        }
        replaceStaleProgramShow()
        refreshProgramOutlinePresentationIfSelected()
    }

    func loadProgramDocument(from url: URL) throws {
        beginProgramFileAccess(url)
        var model = try ProgramDocumentStore.load(from: url)
        let lookups = programDocumentRepairLookups()
        let repaired = ProgramOutlinePresentation.repairStoredProgramDocument(
            in: &model,
            mediaLookup: lookups.media,
            showLookup: lookups.show,
            playlistShowLookup: lookups.playlist
        )
        programDocument = model
        rundownClock.loadProgram(model)
        adoptProgramFile(url)
        if repaired {
            try saveProgramDocument(to: url)
        }
        bindUnassignedProgramCameras()
        replaceStaleProgramShow()
        refreshProgramOutlinePresentationIfSelected()
    }

    func saveProgramDocument(to url: URL? = nil) throws {
        var model = rundownClock.program ?? programDocument
        if isProgramPlaylistItemSelected, show.id == ProgramOutlinePresentation.showID {
            ProgramOutlinePresentation.applyShow(show, to: &model)
        }
        model.runState.activeBlockIndex = rundownClock.activeBlockIndex
        model.runState.isShowRunning = rundownClock.isShowRunning
        model.runState.cumulativeDriftSeconds = rundownClock.cumulativeDriftSeconds
        programDocument = model
        rundownClock.replaceProgram(model)
        let target = url ?? programDocumentURL
        guard let target else { return }
        beginProgramFileAccess(target)
        try ProgramDocumentStore.save(model, to: target)
        adoptProgramFile(target)
    }

    /// Reopens the `.program` stored on the project after launch.
    func restoreLinkedProgram() {
        guard let url = resolveStoredProgramURL() else { return }
        beginProgramFileAccess(url)
        do {
            var model = try ProgramDocumentStore.load(from: url)
            let lookups = programDocumentRepairLookups()
            let repaired = ProgramOutlinePresentation.repairStoredProgramDocument(
                in: &model,
                mediaLookup: lookups.media,
                showLookup: lookups.show,
                playlistShowLookup: lookups.playlist
            )
            programDocument = model
            programDocumentURL = url.standardizedFileURL
            rundownClock.loadProgram(model)
            if repaired {
                try? saveProgramDocument(to: url)
            }
            bindUnassignedProgramCameras()
            replaceStaleProgramShow()
            refreshProgramOutlinePresentationIfSelected()
        } catch {
            mediaAlert = "Couldn’t reopen the program file. \(error.localizedDescription)"
        }
    }

    func releaseProgramFileAccess() {
        programFileAccessURL?.stopAccessingSecurityScopedResource()
        programFileAccessURL = nil
    }

    func startRundownShow(from index: Int? = nil) {
        let blocks = (rundownClock.program ?? programDocument).rundownBlocks
        guard !blocks.isEmpty else { return }
        let start = index ?? rundownFocusedBlockIndex
        let clamped = min(max(0, start), blocks.count - 1)
        rundownFocusedBlockIndex = clamped
        prefetchRundownPageFrames(near: clamped)
        rundownClock.startShow(at: clamped)
        evaluateProgramClockState()
        StageCueController.syncStageRundownOverlay(controller: self)
        tickProgram()
    }

    func advanceRundownBlock() {
        rundownClock.advanceToNextBlock()
        StageCueController.syncStageRundownOverlay(controller: self)
        tickProgram()
    }

    func mutateProgramDocument(_ body: (inout ProgramDocumentModel) -> Void) {
        var doc = rundownClock.program ?? programDocument
        body(&doc)
        programDocument = doc
        rundownClock.replaceProgram(doc)
        tickProgram()
        guard !isPersistingProgramDocument else { return }
        persistProgramEdits()
    }

    func addRundownBlock(_ block: RundownBlock) {
        mutateProgramDocument { $0.rundownBlocks.append(block) }
        syncProgramSlidesFromOutline()
        refreshProgramOutlinePresentationIfSelected()
    }

    func updateRundownBlock(at index: Int, with block: RundownBlock) {
        mutateProgramDocument { model in
            guard model.rundownBlocks.indices.contains(index) else { return }
            model.rundownBlocks[index] = block
        }
        syncProgramSlidesFromOutline()
        refreshProgramOutlinePresentationIfSelected()
    }

    func deleteRundownBlock(at index: Int) {
        mutateProgramDocument { model in
            guard model.rundownBlocks.indices.contains(index) else { return }
            model.rundownBlocks.remove(at: index)
        }
        syncProgramSlidesFromOutline()
        refreshProgramOutlinePresentationIfSelected()
    }

    func upsertTalentProfile(_ talent: TalentProfile) {
        mutateProgramDocument { model in
            if let idx = model.talentDatabase.firstIndex(where: { $0.id == talent.id }) {
                model.talentDatabase[idx] = talent
            } else {
                model.talentDatabase.append(talent)
            }
        }
    }

    func deleteTalentProfile(id: UUID) {
        mutateProgramDocument { model in
            model.talentDatabase.removeAll { $0.id == id }
            for index in model.rundownBlocks.indices {
                model.rundownBlocks[index].assignedTalentIds.removeAll { $0 == id }
            }
        }
    }

    func takeRundownBlockLive(at index: Int) {
        let blocks = (rundownClock.program ?? programDocument).rundownBlocks
        guard blocks.indices.contains(index) else { return }
        rundownFocusedBlockIndex = index
        if rundownClock.isShowRunning {
            rundownClock.jumpToBlock(index: index)
        } else {
            startRundownShow(from: index)
            return
        }
        StageCueController.syncStageRundownOverlay(controller: self)
        tickProgram()
    }

    func programDocumentSnapshot() -> ProgramDocumentModel {
        var model = rundownClock.program ?? programDocument
        model.runState.activeBlockIndex = rundownClock.activeBlockIndex
        model.runState.isShowRunning = rundownClock.isShowRunning
        model.runState.cumulativeDriftSeconds = rundownClock.cumulativeDriftSeconds
        return model
    }

    func executeRundownBlock(_ block: RundownBlock) {
        let startedAt = Date()
        StageCueController.clearStageMessage(controller: self)
        let program = rundownClock.program ?? programDocument

        if let layoutId = block.stageDisplayLayoutId,
           let uuid = UUID(uuidString: layoutId) {
            applyStageLayout(id: uuid)
        }

        if let mediaID = block.linkedMediaBinItemID,
           let item = allMediaItems.first(where: { $0.id == mediaID }) {
            triggerMedia(item, takeProgram: true)
        } else if let path = block.linkedMediaFilePath, !path.isEmpty {
            let action = MediaAction(
                id: UUID(),
                title: block.title,
                tintHex: "#111111",
                isImage: path.lowercased().hasSuffix(".png") || path.lowercased().hasSuffix(".jpg"),
                filePath: path
            )
            compositor.transitionLayer(.media, to: action)
        }

        if block.autoFireLowerThirdOnStart,
           let talentId = block.assignedTalentIds.first,
           let talent = TalentManager.talent(with: talentId, in: program) {
            TalentManager.fireLowerThird(talent: talent, controller: self)
        }

        // Picture first: the cut is what the audience sees. The prompter follows a few ms later.
        let pictureFrom = Date()
        applyRundownPicture(block)
        let cutAt = Date()
        rundownLastCutAt = cutAt
        continueProgramPrompter(for: block)
        let promptedAt = Date()
        prefetchRundownPageFrames(after: block)
        let prefetchedAt = Date()
        preloadNextRundownItem(after: block)
        let preloadedAt = Date()
        StageCueController.syncStageRundownOverlay(controller: self)
        let stagedAt = Date()
        tickProgram()
        let tickedAt = Date()
        func ms(_ a: Date, _ b: Date) -> Int { Int((b.timeIntervalSince(a) * 1000).rounded()) }
        noteRundownCut(block: block, cutAt: cutAt, timings: [
            "prep_ms": ms(startedAt, pictureFrom),
            "picture_ms": ms(pictureFrom, cutAt),
            "prompt_ms": ms(cutAt, promptedAt),
            "prefetch_ms": ms(promptedAt, prefetchedAt),
            "preload_ms": ms(prefetchedAt, preloadedAt),
            "stage_ms": ms(preloadedAt, stagedAt),
            "tick_ms": ms(stagedAt, tickedAt),
        ])
    }

    /// Next, start, and take-live all land here. The clock stays manual; this press is the cut.
    func applyRundownPicture(_ block: RundownBlock) {
        ensureProgramSlide(for: block)
        if let linked = linkedPresentationTarget(for: block) {
            loadPresentation(id: linked.show.id)
            goLive(slideID: linked.slideID)
        } else if let slideID = programSlideID(for: block) {
            let doc = rundownClock.program ?? programDocument
            if let slide = programSlide(for: block) {
                let prepared = ProgramOutlinePresentation.airPrepareSlide(slide, in: doc)
                ensureSlideLiveInputsOnMainLayer(prepared)
            }
            takeProgramOutlineSlideLive(slideID: slideID)
        } else if let page = RundownProgramCut.resolve(block).pageURL {
            fallbackRundownPageRaster(cut: RundownProgramCut(picture: .display, pageURL: page))
        } else {
            clearScriptOnlyOutlinePicture()
        }
        prefetchRundownPageFrames(after: block)
    }

    /// Script-only outline rows — no `.program` slide; drop slide/page layers from the program stack.
    func clearScriptOnlyOutlinePicture() {
        compositor.dismissRundownPage()
        ProgramPageRaster.shared.load(nil)
        if compositor.stack.media?.id == RundownPageMedia.id {
            compositor.clearProgramMedia()
        }
        compositor.clear(.slide)
        refreshLiveStack()
    }

    private func fallbackRundownPageRaster(cut: RundownProgramCut) {
        compositor.clear(.slide)
        if let page = cut.pageURL {
            compositor.presentRundownPage(page)
            ProgramPageRaster.shared.load(page)
        }
    }

    #if os(macOS)
    /// Distinct browser / program page URLs from `startIndex` through the end of the rundown.
    func rundownBrowserPageURLs(fromBlockIndex startIndex: Int) -> [String] {
        let doc = rundownClock.program ?? programDocument
        let blocks = doc.rundownBlocks
        guard !blocks.isEmpty else { return [] }
        let start = min(max(0, startIndex), blocks.count - 1)
        var seen = Set<String>()
        var urls: [String] = []
        for idx in start..<blocks.count {
            let block = blocks[idx]
            let url = ProgramOutlinePresentation.resolvedPageURL(
                for: block,
                in: doc,
                showLookup: { id in self.show(matching: id) }
            ) ?? RundownProgramCut.resolve(block).pageURL
            guard let url else { continue }
            let key = PromptWebsiteURL.canonical(url) ?? url
            if seen.insert(key).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    /// Queue every upcoming rundown browser page for background raster (live `load` still works if a page is not ready).
    func prefetchUpcomingRundownBrowserPages(fromBlockIndex startIndex: Int? = nil) {
        let blocks = (rundownClock.program ?? programDocument).rundownBlocks
        guard !blocks.isEmpty else { return }
        let start: Int
        if let startIndex {
            start = startIndex
        } else if rundownClock.isShowRunning, let active = rundownClock.activeBlockIndex {
            start = active
        } else {
            start = blocks.indices.contains(rundownFocusedBlockIndex) ? rundownFocusedBlockIndex : 0
        }
        let urls = rundownBrowserPageURLs(fromBlockIndex: start)
        guard let next = urls.first else { return }
        ProgramPageRaster.shared.prefetch([next])
    }

    /// Keeps upcoming display pages warm without blocking the live web view.
    func prefetchRundownPageFrames(near index: Int) {
        prefetchUpcomingRundownBrowserPages(fromBlockIndex: index)
    }

    func prefetchRundownPageFrames(after block: RundownBlock) {
        let blocks = (rundownClock.program ?? programDocument).rundownBlocks
        guard let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        prefetchUpcomingRundownBrowserPages(fromBlockIndex: index + 1)
    }
    #else
    func prefetchRundownPageFrames(near index: Int) {}
    func prefetchRundownPageFrames(after block: RundownBlock) {}
    func prefetchUpcomingRundownBrowserPages(fromBlockIndex startIndex: Int? = nil) {}
    #endif

    private func takeRundownCamera() {
        enableLiveIO()
        let source = videoInputs.sources.first { $0.kind == .camera || $0.kind == .continuity }
            ?? videoInputs.sources.first { $0.kind == .captureCard }
        guard let source else { return }
        activateVideoInput(source.inputSource, presentOnProgram: true)
    }

    private func takeRundownDisplay() {
        enableLiveIO()
        if let source = videoInputs.sources.first(where: { $0.kind == .screenShare }) {
            activateVideoInput(source.inputSource, presentOnProgram: true)
            return
        }
        let display = videoInputs.screenShareFeed()
        videoInputs.register(display)
        activateVideoInput(display.inputSource, presentOnProgram: true)
    }

    /// Moves the prompt and the rundown selection to the neighboring outline item.
    func stepRundownOutline(by delta: Int) {
        let blocks = (rundownClock.program ?? programDocument).rundownBlocks
        guard !blocks.isEmpty else { return }
        let current = blocks.indices.contains(rundownFocusedBlockIndex) ? rundownFocusedBlockIndex : 0
        let next = min(max(0, current + delta), blocks.count - 1)
        guard next != current else { return }
        stepRundownOutline(to: next)
    }

    func stepRundownOutline(to index: Int) {
        let blocks = (rundownClock.program ?? programDocument).rundownBlocks
        guard blocks.indices.contains(index) else { return }
        rundownFocusedBlockIndex = index
        TeleprompterSession.shared.loadIfNeeded(script: blocks[index].scriptBody, settings: .shared)
    }

    /// Previous or next outline item on air (clock + program cut), not selection-only.
    func takeAdjacentRundownBlockLive(by delta: Int) {
        let blocks = (rundownClock.program ?? programDocument).rundownBlocks
        guard !blocks.isEmpty else { return }
        let current: Int
        if rundownClock.isShowRunning, let active = rundownClock.activeBlockIndex, blocks.indices.contains(active) {
            current = active
        } else {
            current = blocks.indices.contains(rundownFocusedBlockIndex) ? rundownFocusedBlockIndex : 0
        }
        let next = min(max(0, current + delta), blocks.count - 1)
        guard next != current else { return }
        takeRundownBlockLive(at: next)
    }

    func refreshRundownTick() {
        if compositor.rundownPageURL != nil {
            ProgramPageRaster.shared.refreshIfNeeded()
        }
        guard rundownClock.isShowRunning else { return }
        StageCueController.syncStageRundownOverlay(controller: self)
    }

    func persistProgramEdits() {
        guard !isPersistingProgramDocument else { return }
        let target: URL
        if let existing = programDocumentURL {
            target = existing
        } else if let root = projectAutosave?.bundle.root {
            target = root.appendingPathComponent("Program.program", isDirectory: true)
        } else {
            return
        }
        isPersistingProgramDocument = true
        defer { isPersistingProgramDocument = false }
        do {
            try saveProgramDocument(to: target)
        } catch {
            mediaAlert = error.localizedDescription
        }
    }

    private func beginProgramFileAccess(_ url: URL) {
        let standardized = url.standardizedFileURL
        if programFileAccessURL == standardized { return }
        programFileAccessURL?.stopAccessingSecurityScopedResource()
        if standardized.startAccessingSecurityScopedResource() {
            programFileAccessURL = standardized
        } else {
            programFileAccessURL = nil
        }
    }

    private func adoptProgramFile(_ url: URL) {
        let standardized = url.standardizedFileURL
        beginProgramFileAccess(standardized)
        programDocumentURL = standardized
        let bookmark = Self.programBookmarkData(for: standardized)
        let path = standardized.path
        if projectSettings.programFilePath == path, projectSettings.programFileBookmark != nil {
            return
        }
        var settings = projectSettings
        settings.programFilePath = path
        if let bookmark {
            settings.programFileBookmark = bookmark
        }
        projectSettings = settings
        persistProgramLink()
    }

    private func persistProgramLink() {
        guard let engine = projectAutosave else { return }
        var manifest = engine.bundle.manifest
        manifest.settings = projectSettings
        manifest.updatedAt = Date()
        try? engine.record(.updateManifest(manifest))
    }

    private func resolveStoredProgramURL() -> URL? {
        if let data = projectSettings.programFileBookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
            stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        if let path = projectSettings.programFilePath, !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func programBookmarkData(for url: URL) -> Data? {
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
