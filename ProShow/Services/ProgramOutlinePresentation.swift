import Foundation

/// The virtual `.program` playlist item — real slides stored in the `.program` file, in outline order.
enum ProgramOutlinePresentation {
    static let showID = UUID(uuidString: "C0FFEE00-0000-4000-8000-0000000000B1")!
    static let playlistTitle = ".program"

    static func makeShow(from document: ProgramDocumentModel) -> Show {
        let slides: [Slide] = document.rundownBlocks.compactMap { block in
            guard let slideID = block.programSlideID else { return nil }
            return document.programSlides.first(where: { $0.id == slideID })
        }
        let group = SlideGroup(name: "Program", colorHex: "#5B8DEF", slides: slides)
        return Show(
            id: showID,
            name: playlistTitle,
            groups: slides.isEmpty ? [] : [group]
        )
    }

    /// The library keeps a saved copy of the `.program` show. That copy can be older than the
    /// repaired document (camera rows with the background flag a reopen flipped), so the
    /// program show always goes on air from the document. Other shows pass through.
    static func currentShow(for found: Show, document: ProgramDocumentModel) -> Show {
        guard found.id == showID else { return found }
        let built = makeShow(from: document)
        return built.allSlides.isEmpty ? found : built
    }

    static func applyShow(_ show: Show, to document: inout ProgramDocumentModel) {
        guard show.id == showID else { return }
        for slide in show.allSlides {
            document.upsertProgramSlide(slide)
            guard let index = document.rundownBlocks.firstIndex(where: { $0.programSlideID == slide.id }) else {
                continue
            }
            if !slide.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                document.rundownBlocks[index].title = slide.title
            }
            if let url = pageURL(in: slide) {
                setPageURL(url, on: &document.rundownBlocks[index])
            }
            if case .camera = RundownBlockSlideSource.resolve(document.rundownBlocks[index]),
               RundownBlockSlideSource.placeholderLetter(in: document.rundownBlocks[index]) == nil,
               let camera = cameraConnection(in: slide),
               !camera.connection.hasPrefix("placeholder://") {
                setCameraConnection(name: camera.name, connection: camera.connection, on: &document.rundownBlocks[index])
            }
        }
    }

    /// Creates or updates program slides for outline rows that take the screen (URL page, slide, or display).
    static func syncProgramSlides(
        in document: inout ProgramDocumentModel,
        mediaLookup: (UUID) -> MediaBinItem? = { _ in nil },
        showLookup: (UUID) -> Show? = { _ in nil },
        playlistShowLookup: (UUID) -> Show? = { _ in nil }
    ) {
        sanitizeOutlineSlideBindings(in: &document)
        for index in document.rundownBlocks.indices {
            syncProgramSlide(
                at: index,
                in: &document,
                mediaLookup: mediaLookup,
                showLookup: showLookup,
                playlistShowLookup: playlistShowLookup
            )
        }
        let liveIDs = Set(document.rundownBlocks.compactMap(\.programSlideID))
        document.programSlides.removeAll { !liveIDs.contains($0.id) }
    }

    /// Fixes legacy `.program` files: orphan slide IDs, blank placeholders, camera rows with stale browser shapes.
    @discardableResult
    static func repairStoredProgramDocument(
        in document: inout ProgramDocumentModel,
        mediaLookup: (UUID) -> MediaBinItem? = { _ in nil },
        showLookup: (UUID) -> Show? = { _ in nil },
        playlistShowLookup: (UUID) -> Show? = { _ in nil }
    ) -> Bool {
        var changed = false
        sanitizeOutlineSlideBindings(in: &document)
        for index in document.rundownBlocks.indices {
            if let slideID = document.rundownBlocks[index].programSlideID,
               !document.programSlides.contains(where: { $0.id == slideID }) {
                document.rundownBlocks[index].programSlideID = nil
                changed = true
            }
        }
        let slidesBeforeSync = document.programSlides
        syncProgramSlides(
            in: &document,
            mediaLookup: mediaLookup,
            showLookup: showLookup,
            playlistShowLookup: playlistShowLookup
        )
        // The sync merges too; count what it fixed so the repaired file gets saved.
        if document.programSlides != slidesBeforeSync { changed = true }
        for index in document.rundownBlocks.indices {
            var block = document.rundownBlocks[index]
            let source = RundownBlockSlideSource.resolve(block)
            guard let slideID = block.programSlideID,
                  let slideIndex = document.programSlides.firstIndex(where: { $0.id == slideID })
            else { continue }
            let built = buildProgramSlide(
                for: block,
                source: source,
                slideID: slideID,
                mediaLookup: mediaLookup
            )
            var stored = document.programSlides[slideIndex]
            let before = stored
            // Never replace the saved canvas with the outline template. Operators
            // delete shapes and assign sources on these slides; a reopen must keep that.
            mergeProgramSlidePreservingEdits(stored: &stored, from: built, source: source, block: block)
            if stored != before {
                document.programSlides[slideIndex] = stored
                changed = true
            }
            document.rundownBlocks[index] = block
        }
        let liveIDs = Set(document.rundownBlocks.compactMap(\.programSlideID))
        let beforeCount = document.programSlides.count
        document.programSlides.removeAll { !liveIDs.contains($0.id) }
        if document.programSlides.count != beforeCount { changed = true }
        return changed
    }

    static func syncProgramSlide(
        at blockIndex: Int,
        in document: inout ProgramDocumentModel,
        mediaLookup: (UUID) -> MediaBinItem? = { _ in nil },
        showLookup: (UUID) -> Show? = { _ in nil },
        playlistShowLookup: (UUID) -> Show? = { _ in nil },
        rebuildFromSource: Bool = false
    ) {
        guard document.rundownBlocks.indices.contains(blockIndex) else { return }
        var block = document.rundownBlocks[blockIndex]
        let source = RundownBlockSlideSource.resolve(block)

        if source.isLinkedToExternalPresentation {
            releaseOwnedProgramSlide(block: &block, document: &document)
            if case .playlistItem(let playlistID) = source,
               block.linkedPresentationShowID == nil,
               let show = playlistShowLookup(playlistID),
               let slide = show.allSlides.first {
                block.linkedPresentationShowID = show.id
                block.linkedPresentationSlideID = slide.id
            }
            document.rundownBlocks[blockIndex] = block
            return
        }

        if case .blank = source {
            releaseOwnedProgramSlide(block: &block, document: &document)
            document.rundownBlocks[blockIndex] = block
            return
        }

        let slideID = block.programSlideID ?? UUID()
        block.programSlideID = slideID
        releaseExternalPresentationLink(on: &block)

        let built = buildProgramSlide(
            for: block,
            source: source,
            slideID: slideID,
            mediaLookup: mediaLookup
        )

        if let existingIndex = document.programSlides.firstIndex(where: { $0.id == slideID }) {
            if rebuildFromSource {
                var next = built
                if case .camera = source {
                    preserveCameraAssignment(from: document.programSlides[existingIndex], onto: &next)
                }
                document.programSlides[existingIndex] = next
            } else {
                var slide = document.programSlides[existingIndex]
                mergeProgramSlidePreservingEdits(stored: &slide, from: built, source: source, block: block)
                document.programSlides[existingIndex] = slide
            }
        } else {
            document.upsertProgramSlide(built)
        }
        document.rundownBlocks[blockIndex] = block
    }

    private static func releaseOwnedProgramSlide(block: inout RundownBlock, document: inout ProgramDocumentModel) {
        if let owned = block.programSlideID {
            document.programSlides.removeAll { $0.id == owned }
            block.programSlideID = nil
        }
    }

    private static func releaseExternalPresentationLink(on block: inout RundownBlock) {
        block.linkedPresentationShowID = nil
        block.linkedPresentationSlideID = nil
        block.linkedPlaylistId = nil
    }

    /// Keeps operator canvas edits unless the outline source kind changed in a way that requires rebuild.
    private static func mergeProgramSlidePreservingEdits(
        stored: inout Slide,
        from built: Slide,
        source: RundownBlockSlideSourceKind,
        block: RundownBlock
    ) {
        stored.title = block.title
        stored.label = block.itemNumber
        switch source {
        case .webPage(let url):
            if pageURL(in: stored) != url {
                applyWebURL(url, to: &stored)
            }
        case .camera:
            let hadStaleBrowser = stored.canvas.contains { $0.kind.isBrowserLike }
            stored.canvas.removeAll { $0.kind.isBrowserLike }
            stored.backgroundEnabled = cameraRowBackgroundEnabled(
                stored: stored,
                built: built,
                hadStaleBrowser: hadStaleBrowser
            )
            // A camera row that still has a leftover browser and no input gets the
            // input back. A rectangle the operator deleted stays deleted.
            if hadStaleBrowser,
               !stored.canvas.contains(where: { $0.kind == .videoInput }),
               let camera = built.canvas.first(where: { $0.kind == .videoInput }) {
                stored.canvas.insert(camera, at: 0)
            }
        case .mediaBin, .mediaFile:
            if stored.mediaAction?.filePath != built.mediaAction?.filePath {
                stored.mediaAction = built.mediaAction
            }
        case .blank, .playlistItem, .presentationSlide:
            break
        }
    }

    /// A camera row keeps the background its canvas was authored with. The primary Stream board
    /// is what the editor shows, so it wins; a bare legacy browser row takes the camera template's.
    /// Before, every reopen forced the template's `false`, and the stream then dropped full-frame
    /// design layers and the background colour while the editor still showed them.
    static func cameraRowBackgroundEnabled(stored: Slide, built: Slide, hadStaleBrowser: Bool) -> Bool {
        if let primary = stored.editorCanvases.first(where: \.isPrimary) {
            return primary.backgroundEnabled
        }
        if hadStaleBrowser, stored.canvas.allSatisfy({ $0.kind == .videoInput }) {
            return built.backgroundEnabled
        }
        return stored.backgroundEnabled
    }

    private static func buildProgramSlide(
        for block: RundownBlock,
        source: RundownBlockSlideSourceKind,
        slideID: UUID,
        mediaLookup: (UUID) -> MediaBinItem?
    ) -> Slide {
        switch source {
        case .blank:
            return makeBlankProgramSlide(id: slideID, title: block.title, itemNumber: block.itemNumber)
        case .webPage(let url):
            return makeProgramSlide(id: slideID, title: block.title, itemNumber: block.itemNumber, pageURL: url)
        case .camera:
            return makeCameraProgramSlide(id: slideID, title: block.title, itemNumber: block.itemNumber, block: block)
        case .mediaBin(let mediaID):
            let item = mediaLookup(mediaID)
            return makeMediaProgramSlide(
                id: slideID,
                title: block.title,
                itemNumber: block.itemNumber,
                filePath: item?.filePath,
                titleName: item?.title ?? block.title,
                tintHex: item?.tintHex ?? "#1B3A4B",
                isImage: item.map { if case .image = $0.kind { true } else { false } } ?? false
            )
        case .mediaFile(let path):
            let lower = path.lowercased()
            let isImage = [".png", ".jpg", ".jpeg", ".gif", ".webp"].contains { lower.hasSuffix($0) }
            return makeMediaProgramSlide(
                id: slideID,
                title: block.title,
                itemNumber: block.itemNumber,
                filePath: path,
                titleName: (path as NSString).lastPathComponent,
                tintHex: "#1B3A4B",
                isImage: isImage
            )
        case .playlistItem, .presentationSlide:
            return makeBlankProgramSlide(id: slideID, title: block.title, itemNumber: block.itemNumber)
        }
    }

    private static func makeBlankProgramSlide(id: UUID, title: String, itemNumber: String) -> Slide {
        Slide(
            id: id,
            title: title,
            lines: [],
            notes: "",
            isBlank: true,
            canvas: [],
            label: itemNumber,
            backgroundEnabled: false,
            backgroundHex: "#000000"
        )
    }

    private static func makeCameraProgramSlide(id: UUID, title: String, itemNumber: String, block: RundownBlock) -> Slide {
        var slide = makeBlankProgramSlide(id: id, title: title, itemNumber: itemNumber)
        let direction = block.screenDirections.first(where: { $0.kind == .camera })
        let cameraName = direction?.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (cameraName?.isEmpty == false) ? cameraName! : "Camera"
        var object = CanvasObject(
            name: name,
            kind: .videoInput,
            bounds: .canvas,
            zIndex: 0,
            text: "",
            fillHex: "#000000"
        )
        if let direction, let letter = RundownBlockSlideSource.placeholderLetter(in: direction) {
            object.assignedSource = AssignedMediaSource(
                sourceID: "placeholder-\(letter)",
                name: "Placeholder \(letter)",
                sourceType: .placeholderSlot,
                category: .placeholders,
                connectionString: "placeholder://\(letter)",
                placeholderLetter: letter
            )
            object.token = letter
            object.name = "Placeholder \(letter)"
        } else if let connection = direction?.url?.trimmingCharacters(in: .whitespacesAndNewlines), !connection.isEmpty {
            object.assignedSource = AssignedMediaSource(
                sourceID: connection,
                name: name,
                sourceType: liveSourceType(for: connection),
                category: .videoCapture,
                connectionString: connection
            )
            object.token = connection
        }
        object.visibleOnAudience = true
        object.visibleOnStage = true
        slide.canvas = [object]
        slide.isBlank = false
        slide.themeApplication = .native
        slide.backgroundEnabled = false
        return slide
    }

    private static func makeMediaProgramSlide(
        id: UUID,
        title: String,
        itemNumber: String,
        filePath: String?,
        titleName: String,
        tintHex: String,
        isImage: Bool
    ) -> Slide {
        var slide = makeBlankProgramSlide(id: id, title: title, itemNumber: itemNumber)
        guard let filePath, !filePath.isEmpty else { return slide }
        slide.isBlank = false
        slide.themeApplication = .native
        slide.backgroundEnabled = false
        slide.mediaAction = MediaAction(
            id: UUID(),
            title: titleName,
            tintHex: tintHex,
            isImage: isImage,
            filePath: filePath
        )
        return slide
    }

    static func slideCount(in document: ProgramDocumentModel) -> Int {
        document.rundownBlocks.compactMap(\.programSlideID).count
    }

    static func linkedPresentationIDs(for block: RundownBlock) -> (showID: UUID, slideID: UUID)? {
        guard let showID = block.linkedPresentationShowID,
              let slideID = block.linkedPresentationSlideID
        else { return nil }
        return (showID, slideID)
    }

    static func programSlide(
        for block: RundownBlock,
        in document: ProgramDocumentModel,
        showLookup: (UUID) -> Show? = { _ in nil }
    ) -> Slide? {
        if let slideID = block.programSlideID,
           let owned = document.programSlides.first(where: { $0.id == slideID }) {
            return owned
        }
        if block.programSlideID != nil {
            return nil
        }
        if let showID = block.linkedPresentationShowID,
           let slideID = block.linkedPresentationSlideID,
           let show = showLookup(showID) {
            return show.slide(id: slideID)
        }
        return nil
    }

    static func outlineReferencesSlide(_ block: RundownBlock) -> Bool {
        block.programSlideID != nil || block.linkedPresentationSlideID != nil
    }

    /// Outline URL, or the browser URL on the owned or linked slide.
    static func resolvedPageURL(
        for block: RundownBlock,
        in document: ProgramDocumentModel,
        showLookup: (UUID) -> Show? = { _ in nil }
    ) -> String? {
        if case .camera = RundownBlockSlideSource.resolve(block) { return nil }
        let cut = RundownProgramCut.resolve(block)
        if cut.picture == .camera { return nil }
        if let url = cut.pageURL { return url }
        guard let slide = programSlide(for: block, in: document, showLookup: showLookup) else { return nil }
        return pageURL(in: airPrepareSlide(slide, in: document))
    }

    /// Cleans mixed metadata from older `.program` files (copied slides + leftover link IDs).
    static func sanitizeOutlineSlideBindings(in document: inout ProgramDocumentModel) {
        for index in document.rundownBlocks.indices {
            RundownBlockSlideSource.sanitizeSlideBindings(&document.rundownBlocks[index])
        }
    }

    // MARK: - Slide factory

    static func browserCanvasIndex(in slide: Slide) -> Int? {
        slide.canvas.firstIndex(where: { $0.kind.isBrowserLike })
    }

    private static func makeProgramSlide(
        id: UUID,
        title: String,
        itemNumber: String,
        pageURL: String?
    ) -> Slide {
        var slide = Slide(
            id: id,
            title: title,
            lines: [],
            notes: "",
            isBlank: true,
            canvas: [],
            label: itemNumber,
            backgroundEnabled: true,
            backgroundHex: "#000000"
        )
        if let pageURL, let url = URL(string: pageURL) {
            slide.canvas = [browserObject(url: url)]
        }
        return slide
    }

    private static func browserObject(url: URL) -> CanvasObject {
        var object = CanvasObject(
            name: "Browser",
            kind: .browser,
            bounds: .canvas,
            zIndex: 0,
            text: "",
            fillHex: "#000000"
        )
        object.assignedSource = AssignedMediaSource(
            sourceID: url.absoluteString,
            name: ProgramPageViewport.displayHost(for: url.absoluteString),
            sourceType: .webPage,
            category: .network,
            connectionString: url.absoluteString,
            tintHex: "#000000"
        )
        object.fill.type = .image
        object.fill.imageURI = url.absoluteString
        object.visibleOnAudience = true
        object.visibleOnStage = true
        return object
    }

    private static func applyWebURL(_ urlString: String, to slide: inout Slide) {
        guard let url = URL(string: urlString) else { return }
        if let index = browserCanvasIndex(in: slide) {
            applyWebURL(url, to: &slide.canvas[index])
        } else {
            slide.canvas.insert(browserObject(url: url), at: 0)
        }
    }

    private static func applyWebURL(_ url: URL, to object: inout CanvasObject) {
        object.kind = .browser
        object.assignedSource = AssignedMediaSource(
            sourceID: url.absoluteString,
            name: ProgramPageViewport.displayHost(for: url.absoluteString),
            sourceType: .webPage,
            category: .network,
            connectionString: url.absoluteString,
            tintHex: "#000000"
        )
        object.fill.type = .image
        object.fill.imageURI = url.absoluteString
    }

    static func pageURL(in slide: Slide) -> String? {
        guard let object = slide.canvas.first(where: { $0.kind.isBrowserLike }) else { return nil }
        return object.assignedSource?.connectionString ?? object.fill.imageURI
    }

    /// Stale `.program` slides can keep a browser shape after a row switches to camera; strip it before air.
    static func airPrepareSlide(_ slide: Slide, block: RundownBlock) -> Slide {
        guard case .camera = RundownBlockSlideSource.resolve(block) else { return slide }
        var next = slide
        next.canvas.removeAll { $0.kind.isBrowserLike }
        if !next.canvas.contains(where: { $0.kind == .videoInput }) {
            return makeCameraProgramSlide(id: slide.id, title: slide.title, itemNumber: slide.label, block: block)
        }
        return next
    }

    static func airPrepareSlide(_ slide: Slide, in document: ProgramDocumentModel) -> Slide {
        guard let block = document.rundownBlocks.first(where: { $0.programSlideID == slide.id }) else { return slide }
        return airPrepareSlide(slide, block: block)
    }

    /// Keeps a camera the operator already assigned when the outline row has no device address.
    private static func preserveCameraAssignment(from stored: Slide, onto built: inout Slide) {
        guard let builtIndex = built.canvas.firstIndex(where: { $0.kind == .videoInput }),
              built.canvas[builtIndex].assignedSource == nil,
              let kept = stored.canvas.first(where: { $0.kind == .videoInput })?.assignedSource
        else { return }
        built.canvas[builtIndex].assignedSource = kept
        let name = kept.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            built.canvas[builtIndex].name = name
        }
        if let connection = kept.connectionString, !connection.isEmpty {
            built.canvas[builtIndex].token = connection
        }
    }

    static func cameraConnection(in slide: Slide) -> (name: String, connection: String)? {
        guard let assigned = slide.canvas.first(where: { $0.kind == .videoInput })?.assignedSource else { return nil }
        let connection = assigned.connectionString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !connection.isEmpty else { return nil }
        let name = assigned.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "Camera" : name, connection)
    }

    static func setCameraConnection(name: String, connection: String, on block: inout RundownBlock) {
        let trimmed = connection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = label.isEmpty ? "Camera" : label
        if let index = block.screenDirections.firstIndex(where: { $0.kind == .camera }) {
            block.screenDirections[index].label = resolved
            block.screenDirections[index].url = trimmed
            return
        }
        block.screenDirections.insert(
            ScreenDirection(kind: .camera, label: resolved, url: trimmed),
            at: 0
        )
    }

    private static func liveSourceType(for connection: String) -> SourceType {
        if connection.hasPrefix("sck://window/") { return .systemWindow }
        if connection.hasPrefix("sck://") { return .systemDisplay }
        if connection.hasPrefix("ndi://") || !connection.contains("://") { return .ndiSource }
        return .systemCamera
    }

    private static func setPageURL(_ url: String, on block: inout RundownBlock) {
        if let index = block.screenDirections.firstIndex(where: { $0.kind == .url }) {
            block.screenDirections[index].url = url
            return
        }
        block.screenDirections.append(
            ScreenDirection(kind: .url, label: ProgramPageViewport.displayHost(for: url), url: url)
        )
    }
}

extension Slide {
    var needsProgramLiveCameraPreview: Bool {
        audienceCanvas().contains { object in
            object.kind == .videoInput || object.assignedSource?.sourceType == .systemCamera
        }
    }
}

extension ProgramDocumentModel {
    mutating func upsertProgramSlide(_ slide: Slide) {
        if let index = programSlides.firstIndex(where: { $0.id == slide.id }) {
            programSlides[index] = slide
        } else {
            programSlides.append(slide)
        }
    }
}
