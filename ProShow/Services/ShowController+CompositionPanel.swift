import Foundation

extension ShowController {
    /// Canvas objects for the composition / layers panel (top = front).
    var compositionCanvasObjects: [CanvasObject] {
        programLayerRows.compactMap { row -> CanvasObject? in
            switch row.target {
            case .slideCanvasObject(let objectID):
                return compositor.stack.slideCanvas.first(where: { $0.id == objectID })
                    ?? liveSlide.flatMap { slide in
                        resolvedCanvasObjects(slide.audienceCanvas()).first(where: { $0.id == objectID })
                    }
            case .propCanvasObject(_, let objectID):
                for canvas in compositor.propCanvases {
                    if let object = canvas.objects.first(where: { $0.id == objectID }) { return object }
                }
                return nil
            default:
                return nil
            }
        }
    }

    /// Editor document for the visible canvas editor (not the hidden mounted presentation host).
    private var editorObjectsForCompositionSlide: [CanvasObject]? {
        guard isCanvasEditorPresented, editors.isOpen else { return nil }
        let targetSlideID = compositionPanelSlide?.id ?? selectedSlideID
        if editors.kind == .presentation, let targetSlideID,
           let document = editors.documents.first(where: { $0.slideID == targetSlideID }) {
            return document.objects
        }
        return editors.selectedDocument?.objects
    }

    var compositionPanelSelection: Set<UUID> {
        if isCanvasEditorPresented {
            return editors.selectedObjectIDs
        }
        return compositionPanelSelectedIDs
    }

    /// Slide whose canvas objects appear in the layers panel (live program first; library selection only while editing).
    private var compositionPanelSlide: Slide? {
        if let liveSlideID, let slide = show.slide(id: liveSlideID) { return slide }
        guard isCanvasEditorPresented else { return nil }
        if let docID = editors.selectedDocument?.slideID, let slide = show.slide(id: docID) { return slide }
        if let selectedSlideID, let slide = show.slide(id: selectedSlideID) { return slide }
        return nil
    }

    func compositionSelectLayer(id: UUID, additive: Bool) {
        if isCanvasEditorPresented {
            editors.selectObject(id, additive: additive)
            return
        }
        if additive {
            if compositionPanelSelectedIDs.contains(id) {
                compositionPanelSelectedIDs.remove(id)
            } else {
                compositionPanelSelectedIDs.insert(id)
            }
        } else {
            compositionPanelSelectedIDs = [id]
        }
    }

    func compositionToggleVisibility(id: UUID) {
        if isCanvasEditorPresented {
            editors.toggleAudienceVisibility(id: id)
            pushCompositionToLiveIfNeeded()
            return
        }
        mutateCompositionCanvas { canvas in
            guard let index = canvas.firstIndex(where: { $0.id == id }) else { return }
            canvas[index].visibleOnAudience.toggle()
        }
    }

    func compositionToggleLock(id: UUID) {
        if isCanvasEditorPresented {
            editors.toggleCanvasLock(id: id)
            pushCompositionToLiveIfNeeded()
            return
        }
        mutateCompositionCanvas { canvas in
            guard let index = canvas.firstIndex(where: { $0.id == id }) else { return }
            canvas[index].isCanvasLocked.toggle()
        }
    }

    func compositionRenameLayer(id: UUID, name: String) {
        if isCanvasEditorPresented {
            editors.renameObject(id: id, name: name)
            pushCompositionToLiveIfNeeded()
            return
        }
        mutateCompositionCanvas { canvas in
            guard let index = canvas.firstIndex(where: { $0.id == id }) else { return }
            canvas[index].name = name
        }
    }

    func compositionDeleteLayer(id: UUID) {
        deleteElement(id: id)
    }

    func compositionReorderLayers(from offsets: IndexSet, to destination: Int) {
        if isCanvasEditorPresented {
            editors.reorderCanvasLayers(from: offsets, to: destination)
            pushCompositionToLiveIfNeeded()
            return
        }
        var ordered = compositionCanvasObjects
        ordered.move(fromOffsets: offsets, toOffset: destination)
        let maxZ = ordered.count
        mutateCompositionCanvas { canvas in
            for (index, item) in ordered.enumerated() {
                guard let slot = canvas.firstIndex(where: { $0.id == item.id }) else { continue }
                canvas[slot].zIndex = maxZ - index
            }
        }
    }

    func compositionAddTextLayer() {
        if !isCanvasEditorPresented {
            presentCanvasEditorIfNeeded()
        }
        _ = editors.addObject(.text)
    }

    func compositionDeleteSelectedLayers() {
        let ids = compositionPanelSelection
        guard !ids.isEmpty else { return }
        if isCanvasEditorPresented {
            editors.selectedObjectIDs = ids
            editors.deleteSelected()
            pushCompositionToLiveIfNeeded()
            return
        }
        for id in ids {
            deleteElement(id: id)
        }
        compositionPanelSelectedIDs.subtract(ids)
    }

    private func presentCanvasEditorIfNeeded() {
        guard !isCanvasEditorPresented else { return }
        if editors.kind == nil {
            editors.open(.presentation, show: show, selectedSlideID: selectedSlideID, props: inspector.props)
        }
        operatorMode = .edit
    }

    private func pushCompositionToLiveIfNeeded() {
        guard isCanvasEditorPresented, !isSandboxEditingLive else { return }
        rehydrateFromEditor(persist: true)
        if let slideID = editors.selectedDocument?.slideID ?? selectedSlideID,
           let slide = show.slide(id: slideID) {
            applyLiveSceneDelta(for: slide)
        }
    }

    func mutateCompositionCanvas(_ body: (inout [CanvasObject]) -> Void) {
        guard let slide = compositionPanelSlide else { return }
        var canvas = slide.audienceCanvas()
        body(&canvas)
        configureSlide(id: slide.id) { $0.canvas = canvas }
        if let updated = show.slide(id: slide.id) {
            applyLiveSceneDelta(for: updated)
        }
        if isCanvasEditorPresented {
            editors.syncPresentation(from: show, selectedSlideID: slide.id)
        }
        persistCurrentShow()
    }
}
