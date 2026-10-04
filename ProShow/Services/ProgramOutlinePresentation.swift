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
        }
    }

    /// Creates or updates program slides for outline rows that take the screen (URL page, slide, or display).
    static func syncProgramSlides(
        in document: inout ProgramDocumentModel,
        mediaLookup: (UUID) -> MediaBinItem? = { _ in nil },
        showLookup: (UUID) -> Show? = { _ in nil },
        playlistShowLookup: (UUID) -> Show? = { _ in nil }
    ) {
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

    static func syncProgramSlide(
        at blockIndex: Int,
        in document: inout ProgramDocumentModel,
        mediaLookup: (UUID) -> MediaBinItem? = { _ in nil },
        showLookup: (UUID) -> Show? = { _ in nil },
        playlistShowLookup: (UUID) -> Show? = { _ in nil }
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
            var slide = document.programSlides[existingIndex]
            mergeProgramSlidePreservingEdits(stored: &slide, from: built, source: source, block: block)
            document.programSlides[existingIndex] = slide
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
            if !stored.canvas.contains(where: { $0.kind == .videoInput }) {
                stored.canvas = built.canvas
            }
        case .mediaBin, .mediaFile:
            if stored.mediaAction?.filePath != built.mediaAction?.filePath {
                stored.mediaAction = built.mediaAction
            }
        case .blank:
            break
        }
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
            return makeCameraProgramSlide(id: slideID, title: block.title, itemNumber: block.itemNumber)
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

    private static func makeCameraProgramSlide(id: UUID, title: String, itemNumber: String) -> Slide {
        var slide = makeBlankProgramSlide(id: id, title: title, itemNumber: itemNumber)
        var object = CanvasObject(
            name: "Camera",
            kind: .videoInput,
            bounds: .canvas,
            zIndex: 0,
            text: "",
            fillHex: "#000000"
        )
        object.visibleOnAudience = true
        object.visibleOnStage = true
        slide.canvas = [object]
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
        if let showID = block.linkedPresentationShowID,
           let slideID = block.linkedPresentationSlideID,
           let show = showLookup(showID) {
            return show.slide(id: slideID)
        }
        guard let slideID = block.programSlideID else { return nil }
        return document.programSlides.first(where: { $0.id == slideID })
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
        if let url = RundownProgramCut.resolve(block).pageURL { return url }
        guard let slide = programSlide(for: block, in: document, showLookup: showLookup) else { return nil }
        return pageURL(in: slide)
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

extension ProgramDocumentModel {
    mutating func upsertProgramSlide(_ slide: Slide) {
        if let index = programSlides.firstIndex(where: { $0.id == slide.id }) {
            programSlides[index] = slide
        } else {
            programSlides.append(slide)
        }
    }
}
