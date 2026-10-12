import Foundation

extension ShowController {
    /// Single entry for removing program / slide elements (layers panel, canvas delete key, context menu).
    func deleteElement(id elementId: UUID) {
        guard let row = rawProgramLayerRows.first(where: { $0.id == elementId }) else {
            deleteOrphanCanvasObject(elementId)
            return
        }
        switch row.target {
        case .slideCanvasObject:
            deleteSlideCanvasObject(id: elementId)
        case .slideLyric:
            clearSlideLyricText(elementId: elementId)
        case .propCanvasObject(let propID, let objectID):
            deletePropCanvasObject(propID: propID, objectID: objectID)
        case .programMedia:
            emptyProgramLayer(.media)
            finalizeElementDeletion(elementId: elementId)
        case .programVideoInput:
            compositor.clearProgramVideoInput()
            finalizeElementDeletion(elementId: elementId)
        case .outputMessage(let messageID):
            if messageID == ProgramLayerSyntheticID.announcement {
                hideLayer(.announcements)
            } else {
                hideInspectorMessage(id: messageID)
            }
            finalizeElementDeletion(elementId: elementId)
        case .activeProp(let propID):
            if inspector.props.contains(where: { $0.id == propID && $0.isActive }) {
                _ = toggleInspectorProp(id: propID)
            }
            finalizeElementDeletion(elementId: elementId)
        }
    }

    /// Wipes canvas, legacy text elements, and linked media cue metadata on the active library / live slide.
    func clearActiveSlideContent() {
        guard let slideID = liveSlideID ?? selectedSlideID,
              let slide = show.slide(id: slideID)
        else { return }
        let doomed = slide.canvas.map(\.id) + slide.elements.map(\.id)
        configureSlide(id: slideID) { draft in
            draft.canvas = []
            draft.elements = []
            draft.lines = []
            draft.isBlank = true
            draft.mediaAction = nil
        }
        compositor.clearProgramSlide()
        UnifiedCacheRegistry.shared.invalidate(entityId: slideID)
        if liveSlideID == slideID, let updated = show.slide(id: slideID) {
            applyLiveSceneDelta(for: sanitizeSlide(updated))
        }
        if isCanvasEditorPresented {
            editors.syncPresentation(from: show, selectedSlideID: slideID)
        }
        for id in doomed {
            documentState.recordDeletion(entityId: id)
        }
        compositionPanelSelectedIDs.subtract(Set(doomed))
        persistCurrentShow()
        refreshLiveStack()
        tickProgram()
    }

    private func deleteSlideCanvasObject(id: UUID) {
        guard let slideID = slideIDContaining(canvasObject: id) ?? liveSlideID ?? selectedSlideID else {
            finalizeElementDeletion(elementId: id)
            return
        }
        if isCanvasEditorPresented {
            editors.removeObjectFromPresentation(id: id, slideID: slideID)
        }
        let liveCanvas = compositor.stack.slideCanvas
        configureSlide(id: slideID) { slide in
            let stored = slide.canvas.contains { $0.id == id }
            if !stored && liveCanvas.contains(where: { $0.id == id }) {
                // Theme graphics are generated on air with new ids. Keep the
                // canvas the operator just edited instead of rebuilding it.
                slide.canvas = liveCanvas.filter { $0.id != id }
                slide.themeApplication = .native
                slide.themeVariantID = nil
            } else {
                slide.canvas.removeAll { $0.id == id }
            }
            slide.elements.removeAll { $0.id == id }
            if !slide.canvas.contains(where: \.isTextLike) {
                slide.lines = []
                slide.elements = []
            }
            if slide.canvas.isEmpty {
                slide.lines = []
                slide.elements = []
                slide.isBlank = slide.mediaAction == nil
                slide.themeApplication = .native
            }
        }
        compositor.evictCanvasObject(id: id)
        UnifiedCacheRegistry.shared.invalidate(entityId: slideID)
        if liveSlideID == slideID, let slide = show.slide(id: slideID) {
            applyLiveSceneDelta(for: sanitizeSlide(slide))
        } else if isCanvasEditorPresented {
            editors.syncPresentation(from: show, selectedSlideID: slideID)
        }
        finalizeElementDeletion(elementId: id)
    }

    private func deletePropCanvasObject(propID: UUID, objectID: UUID) {
        mutatePropElements(propID: propID) { elements in
            elements.removeAll { $0.id == objectID }
        }
        finalizeElementDeletion(elementId: objectID)
    }

    private func clearSlideLyricText(elementId: UUID) {
        guard let slideID = liveSlideID ?? selectedSlideID else { return }
        configureSlide(id: slideID) { slide in
            slide.lines = []
            slide.elements = []
        }
        applyLiveStackSlideText([])
        if let slide = show.slide(id: slideID) {
            applyLiveSceneDelta(for: sanitizeSlide(slide))
        }
        finalizeElementDeletion(elementId: elementId)
    }

    private func deleteOrphanCanvasObject(_ id: UUID) {
        if deleteSlideCanvasObjectIfPresent(id: id) {
            finalizeElementDeletion(elementId: id)
        }
    }

    @discardableResult
    private func deleteSlideCanvasObjectIfPresent(id: UUID) -> Bool {
        guard let slideID = slideIDContaining(canvasObject: id) else { return false }
        configureSlide(id: slideID) { slide in
            slide.canvas.removeAll { $0.id == id }
            slide.elements.removeAll { $0.id == id }
        }
        compositor.evictCanvasObject(id: id)
        UnifiedCacheRegistry.shared.invalidate(entityId: slideID)
        if liveSlideID == slideID, let slide = show.slide(id: slideID) {
            applyLiveSceneDelta(for: sanitizeSlide(slide))
        }
        if isCanvasEditorPresented {
            editors.removeObjectFromPresentation(id: id, slideID: slideID)
            editors.syncPresentation(from: show, selectedSlideID: slideID)
        }
        return true
    }

    private func finalizeElementDeletion(elementId: UUID) {
        documentState.recordDeletion(entityId: elementId)
        compositionPanelSelectedIDs.remove(elementId)
        refreshLiveStack()
        persistCurrentShow()
        tickProgram()
    }

    func slideIDContaining(canvasObject id: UUID) -> SlideID? {
        for slide in show.allSlides where slide.canvas.contains(where: { $0.id == id }) {
            return slide.id
        }
        if compositor.stack.slideCanvas.contains(where: { $0.id == id }) {
            return liveSlideID ?? selectedSlideID
        }
        return nil
    }

    var rawProgramLayerRows: [ProgramLayerRow] {
        ProgramLayersEngine.rows(controller: self)
    }
}
