import Foundation

extension ShowController {
    var programLayerRows: [ProgramLayerRow] {
        var rows = rawProgramLayerRows.filter { !documentState.isTombstoned($0.id) }
        guard isCanvasEditorPresented, editors.isOpen else { return rows }
        let editorObjects = compositionEditorObjectsForLayerOverlay()
        guard !editorObjects.isEmpty else { return rows }
        let byID = Dictionary(uniqueKeysWithValues: editorObjects.map { ($0.id, $0) })
        for index in rows.indices {
            let objectID: UUID?
            switch rows[index].target {
            case .slideCanvasObject:
                objectID = rows[index].id
            case .propCanvasObject(_, let id):
                objectID = id
            default:
                objectID = nil
            }
            guard let objectID, let object = byID[objectID] else { continue }
            rows[index].item.isLocked = object.isCanvasLocked
            rows[index].item.isVisible = object.visibleOnAudience
        }
        return rows
    }

    /// Canvas objects from the open editor session used to keep the Layers panel in sync while editing.
    fileprivate func compositionEditorObjectsForLayerOverlay() -> [CanvasObject] {
        if editors.kind == .presentation {
            let slideID = liveSlideID ?? editors.selectedDocument?.slideID ?? selectedSlideID
            if let slideID,
               let document = editors.documents.first(where: { $0.slideID == slideID }) {
                return document.objects
            }
        }
        return editors.selectedDocument?.objects ?? []
    }

    func programLayerRow(id: UUID) -> ProgramLayerRow? {
        rawProgramLayerRows.first { $0.id == id }
    }

    /// Same row as programLayerRow(id:), built once per main run loop turn. Each of the ~40 layer rows
    /// asked for its own row while drawing, and every ask rebuilt all rows (thumbnails included), so one
    /// layer list pass was O(n^2). Only for lookups that read the row kind while rendering.
    func programLayerRowForRendering(id: UUID) -> ProgramLayerRow? {
        ProgramLayerRowTurnCache.rows(for: self)[id]
    }

    func programLayerToggleVisibility(id: UUID) {
        if isCanvasEditorPresented {
            compositionToggleVisibility(id: id)
            return
        }
        guard let row = programLayerRow(id: id) else { return }
        switch row.target {
        case .slideCanvasObject:
            mutateLiveSlideCanvas { canvas in
                guard let index = canvas.firstIndex(where: { $0.id == id }) else { return }
                canvas[index].visibleOnAudience.toggle()
            }
        case .propCanvasObject(let propID, let objectID):
            mutatePropElements(propID: propID) { elements in
                guard let index = elements.firstIndex(where: { $0.id == objectID }) else { return }
                elements[index].visibleOnAudience.toggle()
            }
        case .programMedia:
            toggleLayer(.media)
            if compositor.stack.isCleared(.media) { applyProgramAudioMute() }
        case .programVideoInput:
            toggleLayer(.videoInput)
        case .slideLyric:
            toggleLayer(.slide)
        case .outputMessage(let messageID):
            if messageID == ProgramLayerSyntheticID.announcement {
                hideLayer(.announcements)
            } else {
                hideInspectorMessage(id: messageID)
            }
        case .activeProp(let propID):
            _ = toggleInspectorProp(id: propID)
        }
        refreshLiveStack()
        tickProgram()
    }

    func programLayerReorder(from offsets: IndexSet, to destination: Int) {
        if isCanvasEditorPresented {
            compositionReorderLayers(from: offsets, to: destination)
            return
        }
        var rows = programLayerRows
        rows.move(fromOffsets: offsets, toOffset: destination)

        let slideIDs = rows.compactMap { row -> UUID? in
            if case .slideCanvasObject = row.target { return row.id }
            return nil
        }
        if !slideIDs.isEmpty {
            var z = slideIDs.count
            mutateLiveSlideCanvas { canvas in
                for id in slideIDs {
                    guard let index = canvas.firstIndex(where: { $0.id == id }) else { continue }
                    canvas[index].zIndex = z
                    z -= 1
                }
            }
        }

        var propZ = 9000
        for row in rows {
            guard case let .propCanvasObject(propID, objectID) = row.target else { continue }
            mutatePropElements(propID: propID) { elements in
                guard let index = elements.firstIndex(where: { $0.id == objectID }) else { return }
                elements[index].zIndex = propZ
            }
            propZ -= 1
        }
        refreshLiveStack()
        tickProgram()
    }

    func programLayerToggleLock(id: UUID) {
        if isCanvasEditorPresented {
            compositionToggleLock(id: id)
            return
        }
        guard let row = programLayerRow(id: id) else { return }
        switch row.target {
        case .slideCanvasObject:
            mutateLiveSlideCanvas { canvas in
                guard let index = canvas.firstIndex(where: { $0.id == id }) else { return }
                canvas[index].isCanvasLocked.toggle()
            }
        case .propCanvasObject(let propID, let objectID):
            mutatePropElements(propID: propID) { elements in
                guard let index = elements.firstIndex(where: { $0.id == objectID }) else { return }
                elements[index].isCanvasLocked.toggle()
            }
        case .programMedia:
            compositor.toggleLayerLock(.media)
        case .programVideoInput:
            compositor.toggleLayerLock(.videoInput)
        case .slideLyric:
            compositor.toggleLayerLock(.slide)
        case .outputMessage:
            compositor.toggleLayerLock(.messages)
        case .activeProp:
            compositor.toggleLayerLock(.props)
        }
        refreshLiveStack()
        tickProgram()
    }

    func programLayerRename(id: UUID, name: String) {
        if isCanvasEditorPresented {
            compositionRenameLayer(id: id, name: name)
            return
        }
        guard let row = programLayerRow(id: id) else { return }
        switch row.target {
        case .slideCanvasObject:
            mutateLiveSlideCanvas { canvas in
                guard let index = canvas.firstIndex(where: { $0.id == id }) else { return }
                canvas[index].name = name
            }
        case .propCanvasObject(let propID, let objectID):
            mutatePropElements(propID: propID) { elements in
                guard let index = elements.firstIndex(where: { $0.id == objectID }) else { return }
                elements[index].name = name
            }
        default:
            break
        }
    }

    func programLayerDelete(id: UUID) {
        deleteElement(id: id)
    }

    private func mutateLiveSlideCanvas(_ body: (inout [CanvasObject]) -> Void) {
        var canvas = compositor.stack.slideCanvas
        body(&canvas)
        compositor.applyLiveSceneDelta(
            LiveSceneDelta(
                slideID: liveSlideID ?? selectedSlideID ?? show.allSlides.first?.id ?? show.id,
                canvas: canvas,
                slideText: compositor.stack.slideElements,
                backgroundEnabled: compositor.stack.slideBackgroundEnabled,
                backgroundHex: compositor.stack.slideBackgroundHex,
                canvasWidth: compositor.stack.slideCanvasWidth,
                canvasHeight: compositor.stack.slideCanvasHeight
            )
        )
        if let slideID = liveSlideID ?? selectedSlideID, let slide = show.slide(id: slideID) {
            configureSlide(id: slide.id) { $0.canvas = canvas }
            persistCurrentShow()
        }
    }

    func applyLiveStackSlideText(_ elements: [SlideElement]) {
        compositor.applyLiveSceneDelta(
            LiveSceneDelta(
                slideID: liveSlideID ?? selectedSlideID ?? show.allSlides.first?.id ?? show.id,
                canvas: compositor.stack.slideCanvas,
                slideText: elements,
                backgroundEnabled: compositor.stack.slideBackgroundEnabled,
                backgroundHex: compositor.stack.slideBackgroundHex,
                canvasWidth: compositor.stack.slideCanvasWidth,
                canvasHeight: compositor.stack.slideCanvasHeight
            )
        )
    }

    func mutatePropElements(propID: UUID, _ body: (inout [CanvasObject]) -> Void) {
        guard var prop = inspector.props.first(where: { $0.id == propID }) else { return }
        var elements = prop.elements
        body(&elements)
        inspector.setPropElements(id: propID, elements: elements)
        syncActivePropsToCompositor()
        refreshLiveStack()
        persistStudio()
    }
}

@MainActor
private enum ProgramLayerRowTurnCache {
    private static var rows: [UUID: ProgramLayerRow]?
    private static var owner: ObjectIdentifier?

    static func rows(for controller: ShowController) -> [UUID: ProgramLayerRow] {
        let key = ObjectIdentifier(controller)
        if let rows, owner == key { return rows }
        let built = Dictionary(
            controller.rawProgramLayerRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let scheduleDrop = rows == nil
        rows = built
        owner = key
        if scheduleDrop {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ProgramLayerRowTurnCache.rows = nil
                    ProgramLayerRowTurnCache.owner = nil
                }
            }
        }
        return built
    }
}
