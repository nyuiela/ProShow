import Foundation
import Observation

/// Shared session for the six specialized canvas editors.
@MainActor
@Observable
final class EditorEngine {
    var kind: EditorKind?
    var documents: [EditorDocument] = []
    var selectedDocumentID: UUID?
    var selectedObjectIDs: Set<UUID> = []
    var zoom: Double = 0.42
    var canvasPanX: Double = 0
    var canvasPanY: Double = 0
    var lastPaneWidth: Double = 1200
    var lastPaneHeight: Double = 700
    var gridConfig = CanvasGridConfig()
    var guideLines = GuideLineEngine()
    var userGuides: [UserGuideLine] {
        selectedDocument?.userGuides ?? []
    }

    var snapToGrid: Bool {
        get { gridConfig.isSnapToGridEnabled }
        set { gridConfig.isSnapToGridEnabled = newValue }
    }
    var snapGuides: Bool {
        get { gridConfig.isSmartGuidesEnabled }
        set { gridConfig.isSmartGuidesEnabled = newValue }
    }
    var layoutSnapState = LayoutSnapState()
    var checkerboard = false
    var inspectorTab: EditorInspectorTab = .shape
    var copyright = CopyrightInfo()
    var themeCollection = "Black"
    var textStyleClipboard: TextTypography?
    var textLayoutClipboard: TextLayout?
    var undoStack: [EditorSnapshot] = []
    var redoStack: [EditorSnapshot] = []
    var isGroupingUndo = false
    var objectClipboard: [CanvasObject] = []
    var dragOrigins: [UUID: CanvasBounds] = [:]
    var activeTool: CanvasTool = .pointer
    var handleOrigins: [UUID: CanvasBounds] = [:]
    var handleRotations: [UUID: Double] = [:]
    var liveHandleBounds: [UUID: CanvasBounds] = [:]
    var liveHandleRotations: [UUID: Double] = [:]
    var liveHandleFontSizes: [UUID: Double] = [:]
    var activeHandle: TransformHandle?
    /// True while the operator is dragging, scaling, or rotating the current selection.
    var isSelectionTransformActive: Bool {
        !dragOrigins.isEmpty || activeHandle != nil
    }

    var selectionContainsLockedObjects: Bool {
        selectedObjects.contains(where: \.isCanvasLocked)
    }

    func isTransformLocked(_ object: CanvasObject) -> Bool {
        object.isCanvasLocked
    }
    var bypassSnapping = false
    var isEditingText = false
    var inlineEditID: UUID?
    var spaceHeld = false
    var toolBeforeSpace: CanvasTool?
    var creatingObjectID: UUID?
    var creationStart: (x: Double, y: Double)?
    var isolatedObjectID: UUID?
    var handleFontSizes: [UUID: Double] = [:]
    var collapsedGroupIDs: Set<UUID> = []
    var objectTreeAnchorID: UUID?
    var onDocumentsChanged: (() -> Void)?
    @ObservationIgnored private var undoGroupEndTask: DispatchWorkItem?

    var isOpen: Bool { kind != nil }

    var selectedDocument: EditorDocument? {
        guard let selectedDocumentID else { return nil }
        return documents.first { $0.id == selectedDocumentID }
    }

    var selectedObjects: [CanvasObject] {
        guard let document = selectedDocument else { return [] }
        let pool = document.objects + document.boards.flatMap(\.objects)
        return pool.filter { selectedObjectIDs.contains($0.id) }
    }

    var selectionBounds: CanvasBounds? {
        guard let document = selectedDocument else { return nil }
        let pool = document.objects + document.boards.flatMap(\.objects)
        let bounds = pool
            .filter { selectedObjectIDs.contains($0.id) }
            .map { liveHandleBounds[$0.id] ?? $0.bounds }
        return CanvasBounds.union(bounds)
    }

    func displayBounds(for object: CanvasObject) -> CanvasBounds {
        liveHandleBounds[object.id] ?? object.bounds
    }

    func displayRotation(for object: CanvasObject) -> Double {
        liveHandleRotations[object.id] ?? object.transform.rotation
    }

    func displayFontSize(for object: CanvasObject) -> Double {
        liveHandleFontSizes[object.id] ?? object.typography.fontSize
    }

    /// Layer-backed video uses committed decoder size + affine preview while handle drag is active.
    func usesDecoderFreeResizePreview(for object: CanvasObject) -> Bool {
        activeHandle != nil
            && liveHandleBounds[object.id] != nil
            && object.hostsLayerBackedMedia
    }

    var showsCompoundChrome: Bool {
        isolatedObjectID == nil && selectedObjectIDs.count > 1
    }

    var canGroup: Bool { selectedObjectIDs.count > 1 }

    var canUngroup: Bool {
        guard let objects = selectedDocument?.objects else { return false }
        return !GroupSelectionController.groupIDs(in: selectedObjectIDs, objects: objects).isEmpty
    }

    var isolatedParentBounds: CanvasBounds? {
        guard let isolatedObjectID,
              let document = selectedDocument,
              let groupID = document.objects.first(where: { $0.id == isolatedObjectID })?.groupID
        else { return nil }
        return GroupSelectionController.compoundBounds(of: GroupSelectionController.members(of: groupID, in: document.objects))
    }

    var objectTreeRows: [ObjectTreeItem] {
        guard let document = selectedDocument else { return [] }
        if let index = activeExtraBoardIndex(in: document) {
            return GroupSelectionController.treeRows(
                objects: document.boards[index].objects,
                groups: [],
                collapsedGroupIDs: collapsedGroupIDs
            )
        }
        let groups = document.groups ?? GroupSelectionController.inferredGroups(from: document.objects)
        return GroupSelectionController.treeRows(
            objects: document.objects,
            groups: groups,
            collapsedGroupIDs: collapsedGroupIDs
        )
    }

    func openTheme(pack: ProShowThemePack, documents: [EditorDocument]) {
        kind = .theme
        selectedObjectIDs = []
        inspectorTab = .slide
        undoStack = []
        redoStack = []
        canvasPanX = 0
        canvasPanY = 0
        zoom = 0.42
        themeCollection = pack.collectionName
        self.documents = documents
        selectedDocumentID = documents.first?.id
        if let first = documents.first?.objects.first {
            selectedObjectIDs = [first.id]
            inspectorTab = first.isTextLike ? .text : .shape
        }
    }

    func openStagePack(pack: ProShowThemePack, documents: [EditorDocument], selectedVariantID: UUID?) {
        kind = .stage
        selectedObjectIDs = []
        inspectorTab = .slide
        undoStack = []
        redoStack = []
        canvasPanX = 0
        canvasPanY = 0
        zoom = 0.42
        themeCollection = pack.collectionName
        self.documents = documents
        selectedDocumentID = documents.first(where: { $0.id == selectedVariantID })?.id ?? documents.first?.id
        if let firstObject = selectedDocument?.objects.first {
            selectedObjectIDs = [firstObject.id]
            inspectorTab = firstObject.isTextLike ? .text : .shape
        }
    }

    func insertThemeVariant(id: UUID, name: String, collectionName: String, objects: [CanvasObject]) {
        guard kind == .theme else { return }
        let document = EditorDocument(
            id: id,
            name: name,
            kind: .theme,
            objects: objects,
            collectionName: collectionName,
            variantName: name
        )
        documents.append(document)
        selectedDocumentID = document.id
        selectedObjectIDs = Set(objects.prefix(1).map(\.id))
        notifyDocumentsChanged()
    }

    func open(_ kind: EditorKind, show: Show, selectedSlideID: SlideID?) {
        open(kind, show: show, selectedSlideID: selectedSlideID, props: [])
    }

    func open(_ kind: EditorKind, show: Show, selectedSlideID: SlideID?, props: [ProShowProp]) {
        self.kind = kind
        selectedObjectIDs = []
        inspectorTab = .slide
        undoStack = []
        redoStack = []
        canvasPanX = 0
        canvasPanY = 0
        zoom = 0.42
        documents = Self.seed(kind: kind, show: show, props: props)
        if kind == .presentation, let selectedSlideID,
           let match = documents.first(where: { $0.slideID == selectedSlideID }) {
            selectedDocumentID = match.id
        } else {
            selectedDocumentID = documents.first?.id
        }
        if let first = selectedDocument?.objects.first {
            selectedObjectIDs = [first.id]
            inspectorTab = first.isTextLike ? .text : .shape
        }
    }

    func close() {
        kind = nil
        documents = []
        selectedDocumentID = nil
        selectedObjectIDs = []
        isolatedObjectID = nil
        collapsedGroupIDs = []
        objectTreeAnchorID = nil
        canvasPanX = 0
        canvasPanY = 0
        zoom = 0.42
    }

    static let minZoom = 0.1
    static let maxZoom = 4.0

    func clampZoom(_ value: Double) -> Double {
        min(Self.maxZoom, max(Self.minZoom, value))
    }

    func fitToView(paneWidth: Double, paneHeight: Double, canvasWidth: Double, canvasHeight: Double) {
        lastPaneWidth = paneWidth
        lastPaneHeight = paneHeight
        let zoomX = paneWidth / max(canvasWidth, 1)
        let zoomY = paneHeight / max(canvasHeight, 1)
        zoom = clampZoom(min(zoomX, zoomY) * 0.82)
        canvasPanX = 0
        canvasPanY = 0
    }

    func applyCanvasSize(width: Double, height: Double, scaleObjects: Bool, scale: Double) {
        for index in documents.indices {
            documents[index].canvasWidth = width
            documents[index].canvasHeight = height
            if scaleObjects {
                documents[index].objects = CanvasRescaleEngine.rescale(documents[index].objects, by: scale)
            }
        }
    }

    func fitCurrentDocument() {
        fitToView(
            paneWidth: lastPaneWidth,
            paneHeight: lastPaneHeight,
            canvasWidth: selectedDocument?.canvasWidth ?? CanvasConfig.width,
            canvasHeight: selectedDocument?.canvasHeight ?? CanvasConfig.height
        )
    }

    func setZoom(
        _ newZoom: Double,
        focusX: Double,
        focusY: Double,
        paneWidth: Double,
        paneHeight: Double,
        canvasWidth: Double,
        canvasHeight: Double
    ) {
        let oldZoom = max(zoom, 0.0001)
        let next = clampZoom(newZoom)
        guard abs(next - oldZoom) > 0.0001 else { return }
        let oldOriginX = (paneWidth - canvasWidth * oldZoom) / 2 + canvasPanX
        let oldOriginY = (paneHeight - canvasHeight * oldZoom) / 2 + canvasPanY
        let canvasX = (focusX - oldOriginX) / oldZoom
        let canvasY = (focusY - oldOriginY) / oldZoom
        zoom = next
        canvasPanX = focusX - canvasX * next - (paneWidth - canvasWidth * next) / 2
        canvasPanY = focusY - canvasY * next - (paneHeight - canvasHeight * next) / 2
        CanvasEditorScreenAlign.pixelAlignCanvasPan(
            paneWidth: paneWidth,
            paneHeight: paneHeight,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            zoom: next,
            panX: &canvasPanX,
            panY: &canvasPanY
        )
    }

    func panCanvas(dx: Double, dy: Double) {
        canvasPanX += dx
        canvasPanY += dy
    }

    func selectDocument(_ id: UUID) {
        selectedDocumentID = id
        selectedObjectIDs = Set(selectedDocument?.objects.prefix(1).map(\.id) ?? [])
        if selectedObjectIDs.isEmpty {
            inspectorTab = .slide
        } else {
            inspectorTab = selectedObjects.first?.isTextLike == true ? .text : .shape
        }
    }

    func toggleGroupExpanded(_ id: UUID) {
        if collapsedGroupIDs.contains(id) {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }

    func setGroupExpanded(_ id: UUID, expanded: Bool) {
        if expanded {
            collapsedGroupIDs.remove(id)
        } else {
            collapsedGroupIDs.insert(id)
        }
    }

    func isObjectTreeRowSelected(_ item: ObjectTreeItem) -> Bool {
        let ids = item.representedObjectIDs
        guard !ids.isEmpty else { return false }
        return ids.allSatisfy(selectedObjectIDs.contains)
    }

    func isObjectTreeRowPartiallySelected(_ item: ObjectTreeItem) -> Bool {
        let ids = item.representedObjectIDs
        guard ids.count > 1 else { return false }
        let hit = ids.filter(selectedObjectIDs.contains)
        return !hit.isEmpty && hit.count < ids.count
    }

    /// Layers-panel selection: does not expand a group unless the folder row itself is clicked.
    func selectObjectTreeRow(_ id: UUID, additive: Bool = false, extending: Bool = false) {
        if inlineEditID != nil {
            endInlineEdit()
        }
        let rows = objectTreeRows
        guard let target = rows.first(where: { $0.id == id }) else { return }
        if extending, let anchor = objectTreeAnchorID {
            let ids = GroupSelectionController.objectIDs(in: rows, from: anchor, to: id)
            if !ids.isEmpty {
                isolatedObjectID = nil
                selectedObjectIDs = ids
                refreshInspectorTab()
                return
            }
        }
        let targetIDs = Set(target.representedObjectIDs)
        isolatedObjectID = nil
        if additive {
            var next = selectedObjectIDs
            if !targetIDs.isEmpty, targetIDs.isSubset(of: next) {
                next.subtract(targetIDs)
            } else {
                next.formUnion(targetIDs)
            }
            selectedObjectIDs = next
        } else {
            selectedObjectIDs = targetIDs
        }
        objectTreeAnchorID = id
        refreshInspectorTab()
    }

    func selectObjects(intersecting bounds: CanvasBounds, additive: Bool = false) {
        if inlineEditID != nil, !additive {
            endInlineEdit()
        }
        let objects = selectedDocument?.objects ?? []
        var ids = Set<UUID>()
        for object in objects {
            guard object.bounds.intersects(bounds) else { continue }
            if isolatedObjectID != nil {
                ids.insert(object.id)
            } else if let groupID = object.groupID {
                ids.formUnion(GroupSelectionController.members(of: groupID, in: objects).map(\.id))
            } else {
                ids.insert(object.id)
            }
        }
        isolatedObjectID = nil
        if additive {
            selectedObjectIDs.formUnion(ids)
        } else {
            selectedObjectIDs = ids
        }
        if let first = selectedObjectIDs.first {
            objectTreeAnchorID = first
        }
        refreshInspectorTab()
    }

    func selectObject(_ id: UUID, additive: Bool = false) {
        if let editing = inlineEditID, editing != id, !additive {
            endInlineEdit()
        }
        let objects = canvasObjectPool()
        let object = objects.first(where: { $0.id == id })
        if isolatedObjectID != nil, object?.groupID != objects.first(where: { $0.id == isolatedObjectID })?.groupID {
            isolatedObjectID = nil
        }
        if additive {
            isolatedObjectID = nil
            var next = selectedObjectIDs
            if next.contains(id) {
                next.remove(id)
            } else {
                next.insert(id)
            }
            selectedObjectIDs = next
        } else if isolatedObjectID == id {
            selectedObjectIDs = [id]
        } else if isolatedObjectID != nil, object?.groupID != nil {
            isolatedObjectID = id
            selectedObjectIDs = [id]
        } else if isolatedObjectID == nil, let groupID = object?.groupID {
            selectedObjectIDs = Set(GroupSelectionController.members(of: groupID, in: objects).map(\.id))
        } else {
            selectedObjectIDs = [id]
        }
        refreshInspectorTab()
    }

    func isolateObject(_ id: UUID) {
        endInlineEdit()
        isolatedObjectID = id
        selectedObjectIDs = [id]
        refreshInspectorTab()
        if selectedObjects.first(where: { $0.id == id })?.isTextLike == true {
            beginInlineEdit(id: id)
        }
    }

    func exitIsolation() {
        guard let isolatedObjectID else { return }
        let objects = selectedDocument?.objects ?? []
        let groupID = objects.first(where: { $0.id == isolatedObjectID })?.groupID
        self.isolatedObjectID = nil
        endInlineEdit()
        if let groupID {
            selectedObjectIDs = Set(GroupSelectionController.members(of: groupID, in: objects).map(\.id))
        }
        refreshInspectorTab()
    }

    func clearObjectSelection() {
        endInlineEdit()
        isolatedObjectID = nil
        selectedObjectIDs = []
        inspectorTab = .slide
    }

    private func refreshInspectorTab() {
        if selectedObjectIDs.isEmpty {
            inspectorTab = .slide
        } else if selectedObjects.contains(where: \.isTextLike) {
            inspectorTab = .text
        } else if inspectorTab == .slide || inspectorTab == .text {
            inspectorTab = .shape
        }
    }

    @discardableResult
    func addObject(_ kind: CanvasObjectKind, token: String = "") -> CanvasObject {
        guard let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else {
            return Self.makeObject(kind: kind, zIndex: 0, token: token)
        }
        let pool = activeEditingObjects(in: documents[index])
        let host = activeCanvasPixelSize(in: documents[index])
        let z = (pool.map(\.zIndex).max() ?? 0) + 1
        var object = Self.makeObject(kind: kind, zIndex: z, token: token)
        object.bounds = Self.boundsCentered(object.bounds, canvasWidth: host.width, canvasHeight: host.height)
        object.name = uniqueName(kind.defaultName, in: pool)
        registerUndo()
        if let boardIndex = activeExtraBoardIndex(in: documents[index]) {
            documents[index].boards[boardIndex].objects.append(object)
        } else {
            documents[index].objects.append(object)
        }
        selectedObjectIDs = [object.id]
        inspectorTab = object.isTextLike ? .text : .shape
        notifyDocumentsChanged()
        return object
    }

    func moveObject(id: UUID, to index: Int) {
        guard let documentID = selectedDocumentID,
              let docIndex = documents.firstIndex(where: { $0.id == documentID }),
              let from = documents[docIndex].objects.firstIndex(where: { $0.id == id })
        else { return }
        let object = documents[docIndex].objects.remove(at: from)
        let clamped = min(max(index, 0), documents[docIndex].objects.count)
        documents[docIndex].objects.insert(object, at: clamped)
        reindexZ(documentIndex: docIndex)
    }

    func reorderObjects(from offsets: IndexSet, to destination: Int) {
        reorderObjectTree(from: offsets, to: destination)
    }

    func reorderObjectTree(from offsets: IndexSet, to destination: Int) {
        guard let documentID = selectedDocumentID,
              let docIndex = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        var rows = objectTreeRows
        guard !rows.isEmpty else { return }
        var move = Set(offsets)
        for index in offsets where rows.indices.contains(index) {
            if case .group(_, _, _, true) = rows[index] {
                var child = index + 1
                while child < rows.count, rows[child].depth > 0 {
                    move.insert(child)
                    child += 1
                }
            }
        }
        rows.move(fromOffsets: IndexSet(move), toOffset: destination)
        let order = rows.flatMap(\.representedObjectIDs)
        var seen = Set<UUID>()
        let unique = order.filter { seen.insert($0).inserted }
        for (offset, id) in unique.enumerated() {
            let zIndex = unique.count - offset
            if let item = documents[docIndex].objects.firstIndex(where: { $0.id == id }) {
                documents[docIndex].objects[item].zIndex = zIndex
            }
            for boardIndex in documents[docIndex].boards.indices {
                if let item = documents[docIndex].boards[boardIndex].objects.firstIndex(where: { $0.id == id }) {
                    documents[docIndex].boards[boardIndex].objects[item].zIndex = zIndex
                }
            }
        }
        notifyDocumentsChanged()
    }

    func updateSelectedBounds(_ bounds: CanvasBounds) {
        mutateSelectedObjects {
            guard !$0.isCanvasLocked else { return }
            $0.bounds = bounds
        }
    }

    func applyInspectorChange<T: Equatable>(_ current: T?, _ new: T, _ body: (T) -> Void) {
        guard !selectedObjectIDs.isEmpty else { return }
        guard current != new else { return }
        body(new)
    }

    func commonValue<T: Equatable>(_ keyPath: KeyPath<CanvasObject, T>) -> T? {
        let values = selectedObjects.map { $0[keyPath: keyPath] }
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    var hasMixedSelection: Bool { selectedObjects.count > 1 && selectedObjects.dropFirst().contains { $0.id != selectedObjects[0].id } }

    func mutateMatchingObjects(_ matches: (CanvasObject) -> Bool, _ body: (inout CanvasObject) -> Void) {
        var next = documents
        var changed = false
        for docIndex in next.indices {
            var objects = next[docIndex].objects
            var docChanged = false
            for itemIndex in objects.indices where matches(objects[itemIndex]) {
                body(&objects[itemIndex])
                docChanged = true
            }
            if docChanged {
                next[docIndex].objects = objects
                changed = true
            }
        }
        guard changed else { return }
        registerUndoIfNeeded()
        documents = next
        notifyDocumentsChanged()
    }

    func addBuildStep(phase: BuildPhase) {
        guard let object = selectedObjects.first else { return }
        let nextOrder = (selectedDocument?.objects.flatMap(\.resolvedBuildSteps).map(\.sequenceOrder).max() ?? 0) + 1
        let existingInPhase = (object.buildSteps ?? []).filter { $0.phase == phase }
        let trigger: BuildTriggerMode
        if existingInPhase.isEmpty {
            trigger = phase == .buildOut ? .beforeSlideLeave : .onSlideEnter
        } else {
            trigger = .afterPrevious
        }
        let step = ElementBuildStep(
            elementId: object.id,
            phase: phase,
            trigger: trigger,
            sequenceOrder: nextOrder
        )
        mutateObject(id: object.id) { target in
            var steps = target.buildSteps ?? []
            steps.append(step)
            target.buildSteps = steps
        }
    }

    func updateBuildStep(id: UUID, _ body: (inout ElementBuildStep) -> Void) {
        mutateSelectedObjects { object in
            guard var steps = object.buildSteps, let index = steps.firstIndex(where: { $0.id == id }) else { return }
            body(&steps[index])
            object.buildSteps = steps
        }
    }

    func removeBuildStep(id: UUID) {
        mutateSelectedObjects { object in
            object.buildSteps?.removeAll { $0.id == id }
            if object.buildSteps?.isEmpty == true {
                object.buildSteps = nil
            }
        }
    }

    func moveBuildSteps(from offsets: IndexSet, to destination: Int) {
        guard let object = selectedObjects.first else { return }
        mutateObject(id: object.id) { target in
            var steps = (target.buildSteps ?? []).sorted { $0.sequenceOrder < $1.sequenceOrder }
            steps.move(fromOffsets: offsets, toOffset: destination)
            reindexBuildSteps(&steps)
            target.buildSteps = steps
        }
    }

    func moveBuildStep(id: UUID, by delta: Int) {
        guard let object = selectedObjects.first else { return }
        mutateObject(id: object.id) { target in
            var steps = (target.buildSteps ?? []).sorted { $0.sequenceOrder < $1.sequenceOrder }
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            let next = index + delta
            guard steps.indices.contains(next) else { return }
            steps.swapAt(index, next)
            reindexBuildSteps(&steps)
            target.buildSteps = steps
        }
    }

    private func reindexBuildSteps(_ steps: inout [ElementBuildStep]) {
        for index in steps.indices {
            steps[index].sequenceOrder = index + 1
        }
    }

    func mutateObject(id: UUID, _ body: (inout CanvasObject) -> Void) {
        let previous = selectedObjectIDs
        selectedObjectIDs = [id]
        mutateSelectedObjects(body)
        selectedObjectIDs = previous
    }

    func mutateSelectedObjects(_ body: (inout CanvasObject) -> Void) {
        guard let documentID = selectedDocumentID,
              let docIndex = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        registerUndoIfNeeded()
        var next = documents
        var objects = next[docIndex].objects
        for itemIndex in objects.indices where selectedObjectIDs.contains(objects[itemIndex].id) {
            body(&objects[itemIndex])
        }
        next[docIndex].objects = objects
        for boardIndex in next[docIndex].boards.indices {
            for itemIndex in next[docIndex].boards[boardIndex].objects.indices
            where selectedObjectIDs.contains(next[docIndex].boards[boardIndex].objects[itemIndex].id) {
                body(&next[docIndex].boards[boardIndex].objects[itemIndex])
            }
        }
        documents = next
        notifyDocumentsChanged()
    }

    func toggleAudienceVisibility(id: UUID) {
        toggleAudienceVisibility(ids: [id])
    }

    func toggleAudienceVisibility(ids: [UUID]) {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }
        let visible = unique.compactMap { id in selectedDocument?.objects.first(where: { $0.id == id })?.visibleOnAudience }
        let hide = visible.allSatisfy { $0 }
        mutateObjects(ids: Set(unique)) { $0.visibleOnAudience = !hide }
    }

    func toggleCanvasLock(id: UUID) {
        mutateObjects(ids: [id]) { $0.isCanvasLocked.toggle() }
    }

    func toggleLockSelected() {
        guard !selectedObjectIDs.isEmpty else { return }
        let lock = !selectedObjects.allSatisfy(\.isCanvasLocked)
        mutateSelectedObjects { $0.isCanvasLocked = lock }
    }

    var selectionIsCanvasLocked: Bool {
        !selectedObjects.isEmpty && selectedObjects.allSatisfy(\.isCanvasLocked)
    }

    func renameObject(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateObjects(ids: [id]) { $0.name = trimmed }
    }

    func reorderCanvasLayers(from offsets: IndexSet, to destination: Int) {
        guard let documentID = selectedDocumentID,
              let docIndex = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        registerUndoIfNeeded()
        var ordered = documents[docIndex].objects.sorted { $0.zIndex > $1.zIndex }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        let maxZ = ordered.count
        for (index, item) in ordered.enumerated() {
            guard let objectIndex = documents[docIndex].objects.firstIndex(where: { $0.id == item.id }) else { continue }
            documents[docIndex].objects[objectIndex].zIndex = max(maxZ - index, 1)
        }
        notifyDocumentsChanged()
    }

    func toggleAudioMute(id: UUID) {
        toggleAudioMute(ids: [id])
    }

    func toggleAudioMute(ids: [UUID]) {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return }
        let muted = unique.compactMap { id in selectedDocument?.objects.first(where: { $0.id == id }) }.allSatisfy(\.isAudioMuted)
        mutateObjects(ids: Set(unique)) { $0.audioMuted = !muted }
    }

    func mutateObjects(ids: Set<UUID>, _ body: (inout CanvasObject) -> Void) {
        guard let documentID = selectedDocumentID,
              let docIndex = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        registerUndo()
        for itemIndex in documents[docIndex].objects.indices where ids.contains(documents[docIndex].objects[itemIndex].id) {
            body(&documents[docIndex].objects[itemIndex])
        }
        notifyDocumentsChanged()
    }

    func mutateSelectedDocument(_ body: (inout EditorDocument) -> Void) {
        guard let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        registerUndoIfNeeded()
        var next = documents
        var document = next[index]
        body(&document)
        next[index] = document
        documents = next
        if !defersDocumentNotification {
            notifyDocumentsChanged()
        }
    }

    func setSelectedWidth(_ width: Double) {
        mutateSelectedObjects { object in
            let ratio = object.transform.height / max(object.transform.width, 1)
            object.transform.width = max(1, width)
            if object.transform.lockAspectRatio {
                object.transform.height = max(1, width * ratio)
            }
        }
    }

    func setSelectedHeight(_ height: Double) {
        mutateSelectedObjects { object in
            let ratio = object.transform.width / max(object.transform.height, 1)
            object.transform.height = max(1, height)
            if object.transform.lockAspectRatio {
                object.transform.width = max(1, height * ratio)
            }
        }
    }

    func alignSelected(_ alignment: CanvasAlign) {
        guard let document = selectedDocument else { return }
        let unlocked = selectedObjects.filter { !$0.isCanvasLocked }
        guard !unlocked.isEmpty else { return }
        let canvas = CanvasBounds(x: 0, y: 0, width: document.canvasWidth, height: document.canvasHeight)
        let box = unlocked.count > 1 ? (CanvasBounds.union(unlocked.map(\.bounds)) ?? canvas) : canvas
        registerUndoIfNeeded()
        var objects = unlocked
        AlignmentController.align(alignment, elements: &objects, in: box)
        for object in objects {
            mutateObject(id: object.id, register: false) { $0.transform = object.transform }
        }
        notifyDocumentsChanged()
    }

    func distributeSelected(_ axis: CanvasDistribute) {
        let unlocked = selectedObjects.filter { !$0.isCanvasLocked }
        guard unlocked.count >= 3 else { return }
        registerUndoIfNeeded()
        var objects = unlocked
        AlignmentController.distribute(axis, elements: &objects)
        for object in objects {
            mutateObject(id: object.id, register: false) { $0.transform = object.transform }
        }
        notifyDocumentsChanged()
    }

    func copySelectedTextStyle() {
        guard let object = selectedObjects.first else { return }
        textStyleClipboard = object.typography
        textLayoutClipboard = object.textLayout
    }

    func pasteSelectedTextStyle() {
        guard let typography = textStyleClipboard else { return }
        mutateSelectedObjects {
            $0.typography = typography
            if let layout = textLayoutClipboard {
                $0.textLayout = layout
            }
        }
    }

    func setSelectedTextLooping(_ enabled: Bool) {
        mutateSelectedObjects { object in
            object.textLayout.scrolling = enabled
            guard enabled else { return }
            if object.textLayout.loopDirection == nil {
                if object.kind == .liveQuote {
                    object.textLayout.loopDirection = .left
                } else {
                    object.textLayout.loopDirection = object.text.contains("\n") ? .up : .left
                }
            }
            if object.textLayout.loopSpeedPxPerSec == nil {
                object.textLayout.loopSpeedPxPerSec = 80
            }
            if object.textLayout.loopGapPx == nil {
                object.textLayout.loopGapPx = 80
            }
            if object.textLayout.autoFitMode == .shrink {
                object.textLayout.autoFitMode = .none
            }
        }
    }

    func snapshot() -> EditorSnapshot {
        EditorSnapshot(
            documents: documents,
            selectedDocumentID: selectedDocumentID,
            selectedObjectIDs: selectedObjectIDs,
            inspectorTab: inspectorTab
        )
    }

    func registerUndo() {
        undoStack.append(snapshot())
        if undoStack.count > 40 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    func beginUndoGroup() {
        if !isGroupingUndo {
            registerUndo()
            isGroupingUndo = true
        }
    }

    func endUndoGroup() {
        undoGroupEndTask?.cancel()
        undoGroupEndTask = nil
        isGroupingUndo = false
    }

    /// Coalesce inspector slider drags into one undo step while still pushing live program updates each tick.
    func scheduleEndUndoGroup(after delay: TimeInterval = 0.4) {
        undoGroupEndTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.endUndoGroup()
        }
        undoGroupEndTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    func mutateSelectedObjectsFromInspector(_ body: (inout CanvasObject) -> Void) {
        beginUndoGroup()
        mutateSelectedObjects(body)
        scheduleEndUndoGroup()
    }

    func mutateSelectedDocumentFromInspector(_ body: (inout EditorDocument) -> Void) {
        beginUndoGroup()
        mutateSelectedDocument(body)
        scheduleEndUndoGroup()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(next)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var canPasteTextStyle: Bool { textStyleClipboard != nil }
    var canPasteObjects: Bool { ClipboardController.hasObjects || !objectClipboard.isEmpty }

    func beginDrag(id: UUID) {
        if !selectedObjectIDs.contains(id) {
            selectObject(id)
        }
        let draggable = selectedObjects.filter { !$0.isCanvasLocked }
        guard !draggable.isEmpty else { return }
        beginUndoGroup()
        dragOrigins = Dictionary(uniqueKeysWithValues: draggable.map { ($0.id, $0.bounds) })
    }

    func updateDrag(translationX: Double, translationY: Double) {
        layoutSnapState = LayoutSnapState()
        guard !dragOrigins.isEmpty else { return }

        var snapDX = 0.0
        var snapDY = 0.0
        if let document = selectedDocument, let anchor = dragOrigins.first {
            let (_, anchorOrigin) = anchor
            let host = canvasHost(for: anchor.key, in: document)
            let canvas = CanvasBounds(x: 0, y: 0, width: host.width, height: host.height)
            let others = host.objects.filter { !dragOrigins.keys.contains($0.id) }.map(\.bounds)
            let rawX = anchorOrigin.x + translationX
            let rawY = anchorOrigin.y + translationY
            let result = SmartGuideEngine.compute(
                x: rawX,
                y: rawY,
                width: anchorOrigin.width,
                height: anchorOrigin.height,
                others: others,
                canvas: canvas,
                config: gridConfig,
                bypass: bypassSnapping,
                userGuides: userGuides
            )
            snapDX = result.x - rawX
            snapDY = result.y - rawY
            layoutSnapState = result.state
        }

        for (id, origin) in dragOrigins {
            mutateObject(id: id, register: false) {
                $0.transform.x = origin.x + translationX + snapDX
                $0.transform.y = origin.y + translationY + snapDY
            }
        }
    }

    func endDrag() {
        dragOrigins = [:]
        layoutSnapState = LayoutSnapState()
        syncSelectedGroupBounds()
        endUndoGroup()
        notifyDocumentsChanged()
    }

    func beginHandleDrag(id: UUID, handle: TransformHandle) {
        if !selectedObjectIDs.contains(id) {
            selectObject(id)
        }
        let transformable = selectedObjects.filter { !$0.isCanvasLocked }
        guard !transformable.isEmpty else { return }
        beginUndoGroup()
        activeHandle = handle
        handleOrigins = Dictionary(uniqueKeysWithValues: transformable.map { ($0.id, $0.bounds) })
        handleRotations = Dictionary(uniqueKeysWithValues: transformable.map { ($0.id, $0.transform.rotation) })
        handleFontSizes = Dictionary(uniqueKeysWithValues: transformable.map { ($0.id, $0.typography.fontSize) })
        liveHandleBounds = [:]
        liveHandleRotations = [:]
        liveHandleFontSizes = [:]
    }

    func updateHandleDrag(
        translationX: Double,
        translationY: Double,
        shiftHeld: Bool = false,
        optionHeld: Bool = false,
        commandHeld: Bool = false
    ) {
        guard let handle = activeHandle else { return }
        if handle == .rotation {
            if handleOrigins.count > 1, let compound = CanvasBounds.union(Array(handleOrigins.values)) {
                let start = CanvasTransformEngine.angle(
                    from: compound.midX,
                    originY: compound.midY,
                    to: compound.midX,
                    toY: compound.minY - CanvasTransformEngine.rotationHandleOffset
                )
                let current = CanvasTransformEngine.angle(
                    from: compound.midX,
                    originY: compound.midY,
                    to: compound.midX + translationX,
                    toY: compound.minY - CanvasTransformEngine.rotationHandleOffset + translationY
                )
                let delta = CanvasTransformEngine.rotate(from: start, to: current, baseRotation: 0, snap15: shiftHeld)
                for (id, origin) in handleOrigins {
                    let moved = TransformHandleEngine.rotateChild(
                        origin,
                        aroundX: compound.midX,
                        aroundY: compound.midY,
                        degrees: delta
                    )
                    setLiveHandleBound(id: id, bounds: moved)
                    setLiveHandleRotation(id: id, rotation: (handleRotations[id] ?? 0) + delta)
                }
                return
            }
            for (id, origin) in handleOrigins {
                let start = CanvasTransformEngine.angle(
                    from: origin.x + origin.width / 2,
                    originY: origin.y + origin.height / 2,
                    to: origin.x + origin.width / 2,
                    toY: origin.y - CanvasTransformEngine.rotationHandleOffset
                )
                let current = CanvasTransformEngine.angle(
                    from: origin.x + origin.width / 2,
                    originY: origin.y + origin.height / 2,
                    to: origin.x + origin.width / 2 + translationX,
                    toY: origin.y - CanvasTransformEngine.rotationHandleOffset + translationY
                )
                let next = CanvasTransformEngine.rotate(
                    from: start,
                    to: current,
                    baseRotation: handleRotations[id] ?? 0,
                    snap15: shiftHeld
                )
                setLiveHandleRotation(id: id, rotation: next)
            }
            return
        }
        if handle == .origin {
            for (id, origin) in handleOrigins {
                mutateObject(id: id, register: false) {
                    $0.transform.originX = min(1, max(0, $0.transform.resolvedOriginX + translationX / max(origin.width, 1)))
                    $0.transform.originY = min(1, max(0, $0.transform.resolvedOriginY + translationY / max(origin.height, 1)))
                }
            }
            return
        }
        if handle == .cornerRadius {
            for (id, origin) in handleOrigins {
                mutateObject(id: id, register: false) {
                    let radius = CanvasTransformEngine.clampCornerRadius(origin.height * 0.1 - translationY, bounds: origin)
                    $0.stroke.cornerRadius = radius
                    $0.stroke.corners = .uniform(radius)
                    if $0.kind == .rectangle, radius > 0 {
                        $0.kind = .roundedRectangle
                    }
                }
            }
            return
        }
        if commandHeld && optionHeld && handle.isMidpoint {
            for (id, origin) in handleOrigins {
                let shear = CanvasTransformEngine.shear(origin, handle: handle, delta: handle == .top || handle == .bottom ? translationX : translationY)
                mutateObject(id: id, register: false) {
                    $0.transform.shearX = shear.shearX
                    $0.transform.shearY = shear.shearY
                }
            }
            return
        }
        if handleOrigins.count > 1, let oldCompound = CanvasBounds.union(Array(handleOrigins.values)) {
            let lock = TransformHandleEngine.shouldLockAspect(
                handle: handle,
                elementLocked: selectedObjects.contains(where: \.transform.lockAspectRatio),
                shiftHeld: shiftHeld
            )
            let newCompound = CanvasTransformEngine.resize(
                oldCompound,
                handle: handle,
                deltaX: translationX,
                deltaY: translationY,
                lockAspect: lock,
                fromCenter: optionHeld
            )
            let scaleY = newCompound.height / max(oldCompound.height, TransformHandleEngine.minSize)
            for (id, origin) in handleOrigins {
                let scaledBounds = TransformHandleEngine.scaleChild(origin, from: oldCompound, to: newCompound)
                setLiveHandleBound(id: id, bounds: scaledBounds)
                if let object = canvasObject(id: id),
                   object.isTextLike,
                   let base = handleFontSizes[id] {
                    setLiveHandleFontSize(id: id, fontSize: max(1, base * scaleY))
                }
            }
            return
        }
        for (id, origin) in handleOrigins {
            guard let object = canvasObject(id: id) else { continue }
            let lock = TransformHandleEngine.shouldLockAspect(
                handle: handle,
                elementLocked: CanvasTransformEngine.defaultLockAspect(
                    for: object.kind,
                    locked: object.transform.lockAspectRatio
                ),
                shiftHeld: shiftHeld
            )
            setLiveHandleBound(
                id: id,
                bounds: CanvasTransformEngine.resize(
                    origin,
                    handle: handle,
                    deltaX: translationX,
                    deltaY: translationY,
                    lockAspect: lock,
                    fromCenter: optionHeld
                )
            )
        }
    }

    func endHandleDrag() {
        commitLiveHandlePreview()
        activeHandle = nil
        handleOrigins = [:]
        handleRotations = [:]
        handleFontSizes = [:]
        syncSelectedGroupBounds()
        endUndoGroup()
        notifyDocumentsChanged()
    }

    private func setLiveHandleBound(id: UUID, bounds: CanvasBounds) {
        var next = liveHandleBounds
        next[id] = bounds
        liveHandleBounds = next
    }

    private func setLiveHandleRotation(id: UUID, rotation: Double) {
        var next = liveHandleRotations
        next[id] = rotation
        liveHandleRotations = next
    }

    private func setLiveHandleFontSize(id: UUID, fontSize: Double) {
        var next = liveHandleFontSizes
        next[id] = fontSize
        liveHandleFontSizes = next
    }

    private func commitLiveHandlePreview() {
        let boundsIDs = Set(liveHandleBounds.keys)
        for (id, bounds) in liveHandleBounds {
            mutateObject(id: id, register: false) { object in
                object.bounds = bounds
                if let rotation = liveHandleRotations[id] {
                    object.transform.rotation = rotation
                }
                if let fontSize = liveHandleFontSizes[id] {
                    object.typography.fontSize = fontSize
                }
            }
        }
        for (id, rotation) in liveHandleRotations where !boundsIDs.contains(id) {
            mutateObject(id: id, register: false) { $0.transform.rotation = rotation }
        }
        liveHandleBounds = [:]
        liveHandleRotations = [:]
        liveHandleFontSizes = [:]
    }

    func unlinkSelectedCorners() {
        mutateSelectedObjects {
            $0.stroke.unlinkedCorners = true
            $0.stroke.corners = CanvasTransformEngine.unlinkCorners($0.stroke.cornerRadius)
        }
    }

    func setCornerSmoothing(_ value: Double) {
        mutateSelectedObjects { $0.stroke.cornerSmoothing = min(1, max(0, value)) }
    }

    func applyBoolean(_ operation: BooleanOperation) {
        let items = selectedObjects.sorted { $0.zIndex < $1.zIndex }
        guard items.count >= 2, let rear = items.first, let front = items.last else { return }
        var result = rear
        result.id = UUID()
        result.name = operation.rawValue.capitalized
        result.bounds = CanvasTransformEngine.boolean(rear.bounds, front.bounds, operation: operation)
        result.booleanOp = operation
        let rearPath = rear.vectorPath ?? CanvasTransformEngine.rectanglePath(bounds: rear.bounds)
        let frontPath = front.vectorPath ?? CanvasTransformEngine.rectanglePath(bounds: front.bounds)
        result.vectorPath = PathGeometryEngine.booleanPath(rearPath, frontPath, operation: operation)
        guard let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        registerUndo()
        documents[index].objects.append(result)
        selectedObjectIDs = [result.id]
        notifyDocumentsChanged()
    }

    func flattenBoolean() {
        mutateSelectedObjects {
            $0.booleanOp = nil
            $0.vectorPath = CanvasTransformEngine.rectanglePath(bounds: $0.bounds)
        }
    }

    func groupSelected() {
        guard canGroup, let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        registerUndo()
        isolatedObjectID = nil
        var objects = documents[index].objects
        var groups = documents[index].groups ?? []
        guard let node = GroupSelectionController.groupSelectedElements(
            selectedIds: selectedObjects.map(\.id),
            objects: &objects,
            groups: &groups
        ) else { return }
        documents[index].objects = objects
        documents[index].groups = groups
        selectedObjectIDs = Set(node.childElementIds)
        collapsedGroupIDs.remove(node.id)
        objectTreeAnchorID = node.id
        notifyDocumentsChanged()
    }

    func ungroupSelected() {
        guard let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        var objects = documents[index].objects
        var groups = documents[index].groups ?? GroupSelectionController.inferredGroups(from: objects)
        let ids = GroupSelectionController.groupIDs(in: selectedObjectIDs, objects: objects)
        guard !ids.isEmpty else { return }
        registerUndo()
        isolatedObjectID = nil
        for id in ids {
            GroupSelectionController.ungroupNode(groupId: id, objects: &objects, groups: &groups)
        }
        documents[index].objects = objects
        documents[index].groups = groups
        notifyDocumentsChanged()
    }

    private func syncSelectedGroupBounds() {
        guard let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        var groups = documents[index].groups ?? GroupSelectionController.inferredGroups(from: documents[index].objects)
        for id in GroupSelectionController.groupIDs(in: selectedObjectIDs, objects: documents[index].objects) {
            GroupSelectionController.refreshBounds(groupId: id, objects: documents[index].objects, groups: &groups)
        }
        GroupSelectionController.pruneEmptyGroups(objects: documents[index].objects, groups: &groups)
        documents[index].groups = groups
    }

    func applyAutoLayout() {
        guard let document = selectedDocument, selectedObjects.count >= 2 else { return }
        var layout = selectedObjects.first?.autoLayout ?? AutoLayoutFrame.default
        layout.enabled = true
        let result = CanvasTransformEngine.autoLayout(
            children: selectedObjects.map(\.bounds),
            container: selectionBounds ?? CanvasBounds(x: 0, y: 0, width: document.canvasWidth, height: document.canvasHeight),
            layout: layout
        )
        let ids = selectedObjects.map(\.id)
        mutateSelectedObjects { object in
            object.autoLayout = layout
            if let index = ids.firstIndex(of: object.id) {
                object.bounds = result.children[index]
            }
        }
    }

    func tidySelected(horizontal: Bool) {
        let items = selectedObjects
        guard items.count >= 3 else { return }
        let next = CanvasTransformEngine.equalGaps(items.map(\.bounds), horizontal: horizontal)
        for (object, bounds) in zip(items.sorted(by: { horizontal ? $0.bounds.x < $1.bounds.x : $0.bounds.y < $1.bounds.y }), next) {
            mutateObject(id: object.id, register: false) { $0.bounds = bounds }
        }
        notifyDocumentsChanged()
    }

    func measureDistance(to id: UUID) -> DistanceReadout? {
        guard let from = selectedObjects.first, let document = selectedDocument,
              let other = document.objects.first(where: { $0.id == id })
        else { return nil }
        return CanvasTransformEngine.distance(from: from.bounds, to: other.bounds)
    }

    func joinSelectedPaths() {
        let paths = selectedObjects.compactMap(\.vectorPath)
        guard paths.count >= 2 else { return }
        let joined = paths.dropFirst().reduce(paths[0], CanvasTransformEngine.join)
        mutateSelectedObjects { $0.vectorPath = joined }
    }

    func cutSelectedPath(at index: Int) {
        guard let path = selectedObjects.first?.vectorPath else { return }
        let parts = CanvasTransformEngine.cut(path, at: index)
        mutateSelectedObjects { $0.vectorPath = parts.first }
        if parts.count == 2, let extra = parts.last {
            _ = addObject(.pen)
            mutateSelectedObjects { $0.vectorPath = extra }
        }
    }

    func convertSelectedTextToOutlines() {
        mutateSelectedObjects {
            guard $0.isTextLike else { return }
            $0.vectorPath = CanvasTransformEngine.convertTextToPath(
                text: $0.text,
                bounds: $0.bounds,
                fontFamily: $0.typography.fontFamily,
                fontSize: $0.typography.fontSize
            )
            $0.kind = .pen
        }
    }

    func bringToFront() {
        let ceiling = (selectedDocument?.objects.map(\.zIndex).max() ?? 0) + 1
        mutateSelectedObjects { $0.zIndex = ceiling }
    }

    func sendToBack() {
        mutateSelectedObjects { $0.zIndex = 0 }
    }

    func addUserGuide(axis: GuideAxis, position: CGFloat) {
        mutateSelectedDocument { document in
            document.userGuides.append(UserGuideLine(axis: axis, position: position))
        }
    }

    func updateUserGuide(id: UUID, position: CGFloat) {
        mutateSelectedDocument { document in
            guard let index = document.userGuides.firstIndex(where: { $0.id == id && !$0.isLocked }) else { return }
            document.userGuides[index].position = position
        }
    }

    func removeUserGuide(id: UUID) {
        mutateSelectedDocument { document in
            document.userGuides.removeAll { $0.id == id }
        }
    }

    func finishUserGuideDrag(
        id: UUID,
        position: CGFloat,
        axis: GuideAxis,
        canvasSize: CGSize,
        droppedInRuler: Bool
    ) {
        guideLines.activeDraggingGuideID = nil
        if guideLines.shouldRemoveUserGuide(
            position: position,
            axis: axis,
            canvasSize: canvasSize,
            droppedInRuler: droppedInRuler
        ) {
            removeUserGuide(id: id)
        } else {
            updateUserGuide(id: id, position: position)
        }
    }

    func centerViewportOn(
        canvasX: Double,
        canvasY: Double,
        paneWidth: Double,
        paneHeight: Double,
        canvasWidth: Double,
        canvasHeight: Double
    ) {
        let canvasW = canvasWidth * zoom
        let canvasH = canvasHeight * zoom
        canvasPanX = paneWidth / 2 - canvasX * zoom - (paneWidth - canvasW) / 2
        canvasPanY = paneHeight / 2 - canvasY * zoom - (paneHeight - canvasH) / 2
    }

    func zoomToActualPixels() {
        zoom = 1
        canvasPanX = 0
        canvasPanY = 0
    }

    func zoomToSelection() {
        guard let box = selectionBounds else {
            fitCurrentDocument()
            return
        }
        fitToView(paneWidth: lastPaneWidth, paneHeight: lastPaneHeight, canvasWidth: box.width, canvasHeight: box.height)
    }

    func setTool(_ tool: CanvasTool) {
        activeTool = tool
        spaceHeld = false
        toolBeforeSpace = nil
        if tool != .text {
            endInlineEdit()
        }
    }

    func beginSpacePan() {
        guard !spaceHeld else { return }
        spaceHeld = true
        toolBeforeSpace = activeTool
        if activeTool != .hand {
            activeTool = .hand
        }
    }

    func endSpacePan() {
        guard spaceHeld else { return }
        spaceHeld = false
        if let toolBeforeSpace, toolBeforeSpace != .hand {
            activeTool = toolBeforeSpace
        }
        self.toolBeforeSpace = nil
    }

    func beginCreation(kind: CanvasObjectKind, x: Double, y: Double) {
        creationStart = (x, y)
        creatingObjectID = nil
        _ = kind
    }

    func updateCreation(kind: CanvasObjectKind, x: Double, y: Double) {
        guard let start = creationStart else { return }
        let width = abs(x - start.x)
        let height = abs(y - start.y)
        if creatingObjectID == nil {
            guard width >= 4 || height >= 4 else { return }
            creatingObjectID = addObject(kind).id
        }
        guard let id = creatingObjectID else { return }
        mutateObject(id: id, register: false) { object in
            object.bounds = CanvasBounds(
                x: min(start.x, x),
                y: min(start.y, y),
                width: max(1, width),
                height: max(1, height)
            )
            if object.kind == .ellipse || object.kind == .cutout {
                ShapeDefaults.applyEllipseRadius(&object)
            }
        }
    }

    func endCreation(kind: CanvasObjectKind, x: Double, y: Double) {
        let trackedID = creatingObjectID
        defer {
            creatingObjectID = nil
            creationStart = nil
        }
        guard let start = creationStart else { return }
        if creatingObjectID == nil {
            let added = addObject(kind)
            mutateObject(id: added.id, register: false) { object in
                object.bounds.x = x - object.bounds.width / 2
                object.bounds.y = y - object.bounds.height / 2
            }
        } else if abs(x - start.x) < 4, abs(y - start.y) < 4, let id = creatingObjectID {
            mutateObject(id: id, register: false) { object in
                object.bounds.x = x - object.bounds.width / 2
                object.bounds.y = y - object.bounds.height / 2
            }
        }
        if trackedID != nil {
            notifyDocumentsChanged()
        }
    }

    func beginInlineEdit(id: UUID) {
        guard let object = canvasObject(id: id),
              !object.isCanvasLocked
        else { return }
        selectObject(id)
        inlineEditID = id
        isEditingText = true
    }

    func setInlineText(_ text: String, id: UUID? = nil) {
        if let id {
            selectObject(id)
        }
        mutateSelectedObjects { $0.text = text }
    }

    func commitInlineText(_ text: String, id: UUID? = nil) {
        setInlineText(text, id: id)
        endInlineEdit()
    }

    func endInlineEdit() {
        inlineEditID = nil
        isEditingText = false
    }

    func object(atX x: Double, y: Double) -> CanvasObject? {
        selectedDocument?.sortedObjects.first { object in
            !object.isCanvasLocked && PathGeometryEngine.hitTest(object, x: x, y: y)
        }
    }

    func applyTextFrameMode(_ mode: TextFrameMode) {
        mutateSelectedObjects { object in
            object.textLayout.frameMode = mode
            if object.isTextLike {
                object.bounds = CanvasTransformEngine.fittedTextBounds(
                    text: object.text,
                    fontSize: object.typography.fontSize,
                    mode: mode,
                    current: object.bounds
                )
            }
        }
    }

    func nudgeSelected(dx: Double, dy: Double) {
        mutateSelectedObjects {
            guard !$0.isCanvasLocked else { return }
            $0.transform.x += dx
            $0.transform.y += dy
        }
    }

    func deleteSelected() {
        guard let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        registerUndo()
        documents[index].objects.removeAll { selectedObjectIDs.contains($0.id) }
        for boardIndex in documents[index].boards.indices {
            documents[index].boards[boardIndex].objects.removeAll { selectedObjectIDs.contains($0.id) }
        }
        var groups = documents[index].groups ?? []
        GroupSelectionController.pruneEmptyGroups(objects: documents[index].objects, groups: &groups)
        documents[index].groups = groups
        isolatedObjectID = nil
        selectedObjectIDs = []
        inspectorTab = .slide
        notifyDocumentsChanged()
    }

    func duplicateSelected() {
        insertCopies(selectedObjects, offset: ClipboardController.duplicateOffset)
    }

    func copySelectedObjects() {
        objectClipboard = selectedObjects
        ClipboardController.write(selectedObjects)
    }

    func cutSelectedObjects() {
        copySelectedObjects()
        deleteSelected()
    }

    func pasteObjects() {
        let source = ClipboardController.read().isEmpty ? objectClipboard : ClipboardController.read()
        insertCopies(source, offset: ClipboardController.pasteOffset)
    }

    private func insertCopies(_ objects: [CanvasObject], offset: Double) {
        guard let documentID = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == documentID }),
              !objects.isEmpty
        else { return }
        var copies = ClipboardController.rematerialize(objects, offset: offset)
        let boardIndex = activeExtraBoardIndex(in: documents[index])
        var existing = boardIndex.map { documents[index].boards[$0].objects } ?? documents[index].objects
        for copyIndex in copies.indices {
            copies[copyIndex].name = uniqueName(copies[copyIndex].name, in: existing)
            copies[copyIndex].zIndex = (existing.map(\.zIndex).max() ?? 0) + 1
            existing.append(copies[copyIndex])
        }
        registerUndo()
        if let boardIndex {
            documents[index].boards[boardIndex].objects.append(contentsOf: copies)
        } else {
            documents[index].objects.append(contentsOf: copies)
        }
        selectedObjectIDs = Set(copies.map(\.id))
        inspectorTab = copies.contains(where: \.isTextLike) && copies.allSatisfy(\.isTextLike) ? .text : .shape
        notifyDocumentsChanged()
    }

    func bringForward() {
        guard let document = selectedDocument else { return }
        let pool = activeEditingObjects(in: document)
        let ceiling = (pool.map(\.zIndex).max() ?? 0) + 1
        mutateSelectedObjects { $0.zIndex = min(ceiling, $0.zIndex + 1) }
    }

    func sendBackward() {
        mutateSelectedObjects { $0.zIndex = max(0, $0.zIndex - 1) }
    }

    func selectAllObjects() {
        guard let document = selectedDocument else { return }
        selectedObjectIDs = Set(activeEditingObjects(in: document).map(\.id))
        if selectedObjectIDs.isEmpty {
            inspectorTab = .slide
        } else if inspectorTab == .slide {
            inspectorTab = .shape
        }
    }

    func setResolution(_ resolution: CanvasResolution) {
        setCanvasSize(width: resolution.size.width, height: resolution.size.height)
    }

    /// Changes the artboard the editor is showing and fits it in the pane.
    /// Pixel objects stay put. The live program still composites at the project canvas size.
    func setCanvasSize(width: Double, height: Double) {
        let width = Self.clampedEvenCanvas(width)
        let height = Self.clampedEvenCanvas(height)
        guard let document = selectedDocument else { return }
        if abs(document.canvasWidth - width) < 0.5, abs(document.canvasHeight - height) < 0.5 {
            return
        }
        mutateSelectedDocument {
            $0.canvasWidth = width
            $0.canvasHeight = height
            if let index = $0.boards.firstIndex(where: \.isPrimary) {
                $0.boards[index].width = width
                $0.boards[index].height = height
                $0.boards[index].name = CanvasResolution.screenFamily(width: width, height: height).title
            }
        }
        fitCurrentDocument()
    }

    static func clampedEvenCanvas(_ value: Double) -> Double {
        let rounded = value.rounded()
        let even = rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded - 1
        return min(7680, max(16, even))
    }

    var activeCanvasID: UUID?

    func canvasBoards(in document: EditorDocument) -> [EditorCanvasFrame] {
        if document.boards.isEmpty {
            return [.primary(for: document, guides: gridConfig, checkerboard: checkerboard)]
        }
        var boards = document.boards
        if let index = boards.firstIndex(where: \.isPrimary) {
            boards[index].width = document.canvasWidth
            boards[index].height = document.canvasHeight
        } else {
            boards.insert(.primary(for: document, guides: gridConfig, checkerboard: checkerboard), at: 0)
        }
        return boards.sorted { lhs, rhs in
            if lhs.id == activeCanvasID { return false }
            if rhs.id == activeCanvasID { return true }
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.originX < rhs.originX
        }
    }

    func isCanvasActive(_ board: EditorCanvasFrame, in document: EditorDocument) -> Bool {
        if let activeCanvasID { return activeCanvasID == board.id }
        return board.isPrimary || board.id == document.id
    }

    func selectCanvas(_ id: UUID) {
        activeCanvasID = id
        selectedObjectIDs = []
    }

    /// Page position of the canvas that owns the current selection. Quick actions and handles use this origin.
    func selectionFrameOrigin() -> CGPoint {
        guard let document = selectedDocument else { return .zero }
        if let id = selectedObjectIDs.first {
            if document.objects.contains(where: { $0.id == id }) {
                let primary = canvasBoards(in: document).first(where: \.isPrimary)
                return CGPoint(x: primary?.originX ?? 0, y: primary?.originY ?? 0)
            }
            if let board = document.boards.first(where: { $0.objects.contains(where: { $0.id == id }) }) {
                return CGPoint(x: board.originX, y: board.originY)
            }
        }
        if let frame = activeCanvasFrame() {
            return CGPoint(x: frame.originX, y: frame.originY)
        }
        return .zero
    }

    private func activeCanvasPixelSize(in document: EditorDocument) -> (width: Double, height: Double) {
        if let index = activeExtraBoardIndex(in: document) {
            let board = document.boards[index]
            return (board.width, board.height)
        }
        return (document.canvasWidth, document.canvasHeight)
    }

    /// Puts a new object on the center of its canvas, shrinking it so the box stays inside the frame.
    private static func boundsCentered(_ bounds: CanvasBounds, canvasWidth: Double, canvasHeight: Double) -> CanvasBounds {
        let margin = 48.0
        let maxW = max(16, canvasWidth - margin * 2)
        let maxH = max(16, canvasHeight - margin * 2)
        var next = bounds
        if next.width > maxW || next.height > maxH {
            let fit = min(maxW / max(next.width, 1), maxH / max(next.height, 1))
            next.width *= fit
            next.height *= fit
        }
        next.x = (canvasWidth - next.width) / 2
        next.y = (canvasHeight - next.height) / 2
        return next
    }

    /// Guides and background for the canvas that is selected. Falls back to the session guides when the slide still has one implicit frame.
    func activeCanvasFrame() -> EditorCanvasFrame? {
        guard let document = selectedDocument else { return nil }
        let boards = canvasBoards(in: document)
        if let activeCanvasID, let board = boards.first(where: { $0.id == activeCanvasID }) {
            return board
        }
        return boards.first(where: \.isPrimary) ?? boards.first
    }

    func updateActiveCanvas(_ body: (inout EditorCanvasFrame) -> Void) {
        mutateSelectedDocument { document in
            if document.boards.isEmpty {
                document.boards = [.primary(for: document, guides: gridConfig, checkerboard: checkerboard)]
            } else if !document.boards.contains(where: \.isPrimary) {
                document.boards.insert(.primary(for: document, guides: gridConfig, checkerboard: checkerboard), at: 0)
            }
            let targetID = activeCanvasID ?? document.boards.first(where: \.isPrimary)?.id
            guard let targetID, let index = document.boards.firstIndex(where: { $0.id == targetID }) else { return }
            body(&document.boards[index])
            if document.boards[index].isPrimary {
                document.backgroundEnabled = document.boards[index].backgroundEnabled
                document.backgroundHex = document.boards[index].backgroundHex
                document.canvasWidth = document.boards[index].width
                document.canvasHeight = document.boards[index].height
            }
        }
    }

    func setActiveCanvasSize(width: Double, height: Double) {
        let width = Self.clampedEvenCanvas(width)
        let height = Self.clampedEvenCanvas(height)
        let frame = activeCanvasFrame()
        if frame?.isPrimary != false {
            setCanvasSize(width: width, height: height)
            return
        }
        updateActiveCanvas {
            $0.width = width
            $0.height = height
        }
    }

    func canvasObject(id: UUID) -> CanvasObject? {
        guard let document = selectedDocument else { return nil }
        if let object = document.objects.first(where: { $0.id == id }) { return object }
        for board in document.boards {
            if let object = board.objects.first(where: { $0.id == id }) { return object }
        }
        return nil
    }

    private func activeExtraBoardIndex(in document: EditorDocument) -> Int? {
        guard let activeCanvasID,
              let index = document.boards.firstIndex(where: { $0.id == activeCanvasID }),
              !document.boards[index].isPrimary
        else { return nil }
        return index
    }

    func addCanvas(name: String, width: Double, height: Double) {
        let width = Self.clampedEvenCanvas(width)
        let height = Self.clampedEvenCanvas(height)
        var added: EditorCanvasFrame?
        mutateSelectedDocument { document in
            if document.boards.isEmpty {
                document.boards = [.primary(for: document, guides: gridConfig, checkerboard: checkerboard)]
            }
            let gap = 480.0
            let maxX = document.boards.map { $0.originX + $0.width }.max() ?? 0
            let frame = EditorCanvasFrame(
                id: UUID(),
                name: Self.uniqueCanvasName(name, in: document.boards),
                width: width,
                height: height,
                originX: maxX + gap,
                originY: 0,
                isPrimary: false
            )
            document.boards.append(frame)
            added = frame
        }
        guard let added else { return }
        activeCanvasID = added.id
        revealCanvas(added)
    }

    func moveCanvas(id: UUID, dx: Double, dy: Double) {
        guard abs(dx) > 0.4 || abs(dy) > 0.4 else { return }
        mutateSelectedDocument { document in
            if document.boards.isEmpty {
                document.boards = [.primary(for: document, guides: gridConfig, checkerboard: checkerboard)]
            }
            guard let index = document.boards.firstIndex(where: { $0.id == id }) else { return }
            document.boards[index].originX += dx
            document.boards[index].originY += dy
        }
    }

    func revealCanvas(_ board: EditorCanvasFrame) {
        guard let document = selectedDocument else { return }
        let zoom = max(self.zoom, 0.0001)
        let centerX = board.originX + board.width / 2
        let centerY = board.originY + board.height / 2
        canvasPanX = (document.canvasWidth / 2 - centerX) * zoom
        canvasPanY = (document.canvasHeight / 2 - centerY) * zoom
    }

    private static func uniqueCanvasName(_ base: String, in boards: [EditorCanvasFrame]) -> String {
        let existing = Set(boards.map(\.name))
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    @discardableResult
    func addDocument(named name: String, id: UUID = UUID()) -> EditorDocument {
        guard let kind else {
            return EditorDocument(id: id, name: name, kind: .presentation)
        }
        var document = EditorDocument(
            id: id,
            name: name,
            kind: kind,
            collectionName: selectedDocument?.collectionName ?? "Default Collection"
        )
        if kind == .theme {
            document.variantName = name
            document.collectionName = themeCollection
        }
        if kind == .props {
            document.backgroundEnabled = false
        }
        documents.append(document)
        selectedDocumentID = document.id
        selectedObjectIDs = []
        notifyDocumentsChanged()
        return document
    }

    func insertDocument(from prop: ProShowProp) {
        guard kind == .props, !documents.contains(where: { $0.id == prop.id }) else {
            if kind == .props { selectDocument(prop.id) }
            return
        }
        documents.append(
            EditorDocument(
                id: prop.id,
                name: prop.name,
                kind: .props,
                backgroundEnabled: false,
                objects: prop.elements,
                collectionName: prop.collectionName,
                transition: prop.transition,
                transitionDuration: prop.transitionDuration,
                autoClear: prop.autoClearMode.title
            )
        )
        selectedDocumentID = prop.id
        selectedObjectIDs = []
    }

    func addThemeVariant(_ name: String) {
        themeCollection = selectedDocument?.collectionName ?? themeCollection
        var document = EditorDocument(
            name: name,
            kind: .theme,
            collectionName: themeCollection,
            variantName: name
        )
        document.objects = Self.themeObjects(for: name)
        documents.append(document)
        selectedDocumentID = document.id
        selectedObjectIDs = Set(document.objects.prefix(1).map(\.id))
    }

    func bindMediaAction(_ title: String) {
        mutateSelectedDocument { $0.mediaActionTitle = title }
    }

    func resolvedCopyright(template: String? = nil) -> String {
        copyright.resolvedLine(template: template ?? defaultCopyrightTemplate)
    }

    func commitLive(selectedSlideID: SlideID?) -> EditorLiveAction? {
        switch kind {
        case .presentation:
            if let slideID = selectedDocument?.slideID ?? selectedSlideID {
                return .goLive(slideID)
            }
            return nil
        case .stage:
            let kinds = Set(selectedDocument?.objects.map(\.kind) ?? [])
            return .setStageLook(
                StageLookConfig(
                    showCurrent: kinds.contains(.currentSlide),
                    showNext: kinds.contains(.nextSlide),
                    showNotes: kinds.contains(.stageNotes),
                    showClock: kinds.contains(.systemClock) || kinds.contains(.systemDate)
                )
            )
        case .theme:
            return .applyTheme(selectedDocument?.variantName.isEmpty == false ? selectedDocument!.variantName : selectedDocument?.name ?? "Default")
        case .ccli:
            copyright.showOnScreen = true
            return .setMessage(resolvedCopyright())
        case .props:
            guard let name = selectedDocument?.name else { return nil }
            return .toggleProp(name)
        case .masks:
            let invert = selectedDocument?.invertMask ?? false
            return .setMask(enabled: true, invert: invert, kind: invert ? "invert" : "custom")
        case .overlays:
            return .setMessage(selectedDocument?.name ?? "Live Overlay")
        case nil:
            return nil
        }
    }

    func removeObjectFromPresentation(id objectID: UUID, slideID: SlideID) {
        guard kind == .presentation,
              let docIndex = documents.firstIndex(where: { $0.slideID == slideID })
        else { return }
        if let objectIndex = documents[docIndex].objects.firstIndex(where: { $0.id == objectID }) {
            registerUndo()
            documents[docIndex].objects.remove(at: objectIndex)
        } else if let boardIndex = documents[docIndex].boards.firstIndex(where: { $0.objects.contains(where: { $0.id == objectID }) }),
                  let objectIndex = documents[docIndex].boards[boardIndex].objects.firstIndex(where: { $0.id == objectID }) {
            registerUndo()
            documents[docIndex].boards[boardIndex].objects.remove(at: objectIndex)
        } else {
            return
        }
        selectedObjectIDs.remove(objectID)
        notifyDocumentsChanged()
    }

    func purgeObjects(where shouldRemove: (UUID) -> Bool) {
        guard kind == .presentation else { return }
        var changed = false
        for index in documents.indices {
            let before = documents[index].objects.count
            documents[index].objects.removeAll { shouldRemove($0.id) }
            if documents[index].objects.count != before { changed = true }
        }
        if changed { notifyDocumentsChanged() }
    }

    func syncPresentation(from show: Show, selectedSlideID: SlideID?) {
        guard kind == .presentation else { return }
        documents = Self.seed(kind: .presentation, show: show)
        if let selectedSlideID, let match = documents.first(where: { $0.slideID == selectedSlideID }) {
            selectedDocumentID = match.id
        } else if selectedDocumentID == nil {
            selectedDocumentID = documents.first?.id
        }
    }

    @discardableResult
    func rehydrate(into show: inout Show) -> Set<SlideID> {
        guard kind == .presentation else { return [] }
        var changed: Set<SlideID> = []
        for document in documents {
            guard let slideID = document.slideID else { continue }
            var mutated = false
            show.updateSlide(id: slideID) { slide in
                let before = slide
                document.applyToSlide(&slide)
                mutated = slide != before
            }
            if mutated {
                changed.insert(slideID)
            }
        }
        return changed
    }

    private var defaultCopyrightTemplate: String {
        selectedDocument?.objects.first(where: { $0.kind == .copyrightToken })?.token
            ?? "{Title} · {Artist} · {Publisher} © {Copyright Year} CCLI {License Number}"
    }

    private func registerUndoIfNeeded() {
        if !isGroupingUndo {
            registerUndo()
        }
    }

    private func apply(_ snapshot: EditorSnapshot) {
        documents = snapshot.documents
        selectedDocumentID = snapshot.selectedDocumentID
        selectedObjectIDs = snapshot.selectedObjectIDs
        inspectorTab = snapshot.inspectorTab
        isolatedObjectID = nil
        notifyDocumentsChanged()
    }

    private func notifyDocumentsChanged() {
        onDocumentsChanged?()
    }

    /// Live transforms (drag, resize, marquee create) update the canvas without rehydrating the show every frame.
    private var defersDocumentNotification: Bool {
        activeHandle != nil || !dragOrigins.isEmpty || creatingObjectID != nil || guideLines.isInteracting
    }

    private func mutateObject(id: UUID, register: Bool, _ body: (inout CanvasObject) -> Void) {
        guard let documentID = selectedDocumentID,
              let docIndex = documents.firstIndex(where: { $0.id == documentID })
        else { return }
        if let itemIndex = documents[docIndex].objects.firstIndex(where: { $0.id == id }) {
            if register { registerUndoIfNeeded() }
            var next = documents
            var objects = next[docIndex].objects
            body(&objects[itemIndex])
            next[docIndex].objects = objects
            documents = next
        } else if let boardIndex = documents[docIndex].boards.firstIndex(where: { $0.objects.contains(where: { $0.id == id }) }),
                  let itemIndex = documents[docIndex].boards[boardIndex].objects.firstIndex(where: { $0.id == id }) {
            if register { registerUndoIfNeeded() }
            var next = documents
            body(&next[docIndex].boards[boardIndex].objects[itemIndex])
            documents = next
        } else {
            return
        }
        if !defersDocumentNotification {
            notifyDocumentsChanged()
        }
    }

    private func canvasObjectPool() -> [CanvasObject] {
        guard let document = selectedDocument else { return [] }
        return document.objects + document.boards.flatMap(\.objects)
    }

    private func activeEditingObjects(in document: EditorDocument) -> [CanvasObject] {
        if let index = activeExtraBoardIndex(in: document) {
            return document.boards[index].objects
        }
        return document.objects
    }

    private func canvasHost(for objectID: UUID, in document: EditorDocument) -> (width: Double, height: Double, objects: [CanvasObject]) {
        if let board = document.boards.first(where: { !$0.isPrimary && $0.objects.contains(where: { $0.id == objectID }) }) {
            return (board.width, board.height, board.objects)
        }
        return (document.canvasWidth, document.canvasHeight, document.objects)
    }

    private func snap(_ value: Double, _ increment: Double) -> Double {
        guard increment > 1 else { return value }
        return (value / increment).rounded() * increment
    }

    private func uniqueName(_ base: String, in objects: [CanvasObject]) -> String {
        let existing = Set(objects.map(\.name))
        if !existing.contains(base) { return base }
        var index = objects.count + 1
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func reindexZ(documentIndex: Int) {
        for (offset, _) in documents[documentIndex].objects.enumerated() {
            documents[documentIndex].objects[offset].zIndex = offset + 1
        }
    }

    private static func defaultBounds(for kind: CanvasObjectKind) -> CanvasBounds {
        switch kind {
        case .currentSlide:
            return CanvasBounds(x: 240, y: 200, width: 3360, height: 900)
        case .nextSlide:
            return CanvasBounds(x: 240, y: 1180, width: 3360, height: 560)
        case .systemClock, .systemDate:
            return CanvasBounds(x: 3000, y: 80, width: 720, height: 180)
        case .liveQuote, .textField:
            return CanvasBounds(x: 240, y: 160, width: 2200, height: 180)
        case .stageNotes, .timerCountdown:
            return CanvasBounds(x: 240, y: 1800, width: 1680, height: 240)
        case .copyrightToken:
            return CanvasBounds(x: 120, y: 1980, width: 1680, height: 120)
        case .image, .videoInput, .webView, .browser, .prop:
            return .centered(width: 1920, height: 1080)
        case .ellipse, .cutout:
            return .centered(width: 720, height: 720)
        case .rectangle, .roundedRectangle, .maskShape, .qrCode:
            return .centered(width: 640, height: 640)
        case .line:
            return .centered(width: 1600, height: 24)
        case .polygon:
            return .centered(width: 900, height: 780)
        case .title:
            return .centered(width: 2800, height: 200)
        case .subtitle:
            return .centered(width: 2400, height: 140)
        case .text:
            return .centered(width: 2400, height: 200)
        default:
            return .centered(width: 1280, height: 720)
        }
    }

    private static func resolvedToken(for kind: CanvasObjectKind, token: String) -> String {
        if !token.isEmpty { return token }
        switch kind {
        case .copyrightToken: return "{Title}"
        case .systemClock: return "h:mm:ss a"
        case .systemDate: return "EEEE, MMMM d"
        case .liveQuote: return "stock|AAPL"
        case .textField: return "Speaker"
        case .timerCountdown: return CountdownFormatCatalog.default
        default: return ""
        }
    }

    private static func defaultText(for kind: CanvasObjectKind, token: String) -> String {
        switch kind {
        case .copyrightToken: return token
        case .liveQuote: return LiveQuoteCatalog.defaultTemplate
        case .textField: return ""
        case .systemClock, .systemDate: return kind.title
        default: return kind.isTextLike ? kind.title : ""
        }
    }

    private static func makeObject(kind: CanvasObjectKind, zIndex: Int, token: String) -> CanvasObject {
        let resolvedToken = resolvedToken(for: kind, token: token)
        let bounds = defaultBounds(for: kind)
        var object = CanvasObject(
            name: kind.defaultName,
            kind: kind,
            bounds: bounds,
            zIndex: zIndex,
            text: defaultText(for: kind, token: resolvedToken),
            fontSize: defaultFontSize(for: kind, boxHeight: bounds.height),
            token: resolvedToken
        )
        ShapeDefaults.apply(&object)
        if object.isTextLike {
            object.textLayout.lineHeight = 1.2
        }
        if kind == .roundedRectangle {
            let radius = object.defaultRoundedRadius
            object.stroke.cornerRadius = radius
            object.stroke.corners = .uniform(radius)
        }
        object.build = ElementBuildAnimation(inEffect: .none, outEffect: .none)
        object.buildSteps = DefaultBuildFactory.createDefaultBuildSteps(for: object.id, kind: kind)
        if kind == .timerCountdown {
            object.countdownStartOn = .onSlideEnter
        }
        if kind.isBrowserLike {
            let placeholder = "https://"
            object.assignedSource = AssignedMediaSource(
                sourceID: placeholder,
                name: "Browser",
                sourceType: .webPage,
                category: .network,
                connectionString: placeholder,
                tintHex: "#000000"
            )
            object.fill.type = .image
            object.fill.imageURI = placeholder
        }
        return object
    }

    private static func defaultFontSize(for kind: CanvasObjectKind, boxHeight: Double) -> Double {
        switch kind {
        case .title: return min(120, boxHeight * 0.62)
        case .subtitle: return min(72, boxHeight * 0.55)
        case .copyrightToken: return min(36, boxHeight * 0.45)
        case .systemClock, .systemDate, .timerCountdown, .liveQuote, .textField: return min(64, boxHeight * 0.5)
        case .text: return ShapeDefaults.textSize
        default: return min(96, max(ShapeDefaults.textSize, boxHeight * 0.42))
        }
    }

    static func seed(kind: EditorKind, show: Show, props: [ProShowProp] = []) -> [EditorDocument] {
        switch kind {
        case .presentation:
            return show.allSlides.enumerated().map { index, slide in
                EditorDocument(
                    name: slide.previewSummary,
                    kind: .presentation,
                    slideID: slide.id,
                    canvasWidth: slide.editorCanvases.first(where: \.isPrimary)?.width ?? CanvasConfig.width,
                    canvasHeight: slide.editorCanvases.first(where: \.isPrimary)?.height ?? CanvasConfig.height,
                    backgroundEnabled: slide.backgroundEnabled,
                    backgroundHex: slide.backgroundHex,
                    objects: objects(from: slide, number: index + 1),
                    transition: slide.transition,
                    notes: slide.notes,
                    mediaActionTitle: slide.mediaAction?.title ?? "",
                    boards: slide.editorCanvases
                )
            }
        case .stage:
            return [
                EditorDocument(
                    name: "Current + Next Text",
                    kind: .stage,
                    objects: [
                        makeObject(kind: .currentSlide, zIndex: 3, token: ""),
                        makeObject(kind: .nextSlide, zIndex: 2, token: ""),
                        makeObject(kind: .systemClock, zIndex: 1, token: ""),
                    ]
                )
            ]
        case .theme:
            return EditorCatalog.themeVariants.map { name in
                EditorDocument(
                    name: name,
                    kind: .theme,
                    canvasWidth: CanvasConfig.width,
                    canvasHeight: CanvasConfig.height,
                    objects: themeObjects(for: name),
                    collectionName: "Black",
                    variantName: name
                )
            }
        case .ccli:
            return [
                EditorDocument(
                    name: "Copyright",
                    kind: .ccli,
                    backgroundEnabled: false,
                    backgroundHex: "#00000000",
                    objects: EditorCatalog.ccliTokens.enumerated().map { index, token in
                        var object = makeObject(kind: .copyrightToken, zIndex: EditorCatalog.ccliTokens.count - index, token: token)
                        object.name = token
                        object.bounds.y = 1960 - Double(index) * 56
                        object.fontSize = 44
                        return object
                    }
                )
            ]
        case .props:
            return props.map { prop in
                EditorDocument(
                    id: prop.id,
                    name: prop.name,
                    kind: .props,
                    canvasWidth: CanvasConfig.width,
                    canvasHeight: CanvasConfig.height,
                    backgroundEnabled: false,
                    objects: prop.elements,
                    collectionName: prop.collectionName,
                    transition: prop.transition,
                    transitionDuration: prop.transitionDuration,
                    autoClear: prop.autoClearMode.title
                )
            }
        case .masks:
            return [
                EditorDocument(
                    name: "Mask",
                    kind: .masks,
                    objects: [
                        CanvasObject(name: "Cutout", kind: .cutout, bounds: CanvasBounds(x: 480, y: 240, width: 2880, height: 1680), zIndex: 1, fillHex: "#000000")
                    ],
                    invertMask: false
                )
            ]
        case .overlays:
            return [
                EditorDocument(
                    name: "Chat Card",
                    kind: .overlays,
                    objects: [
                        makeObject(kind: .title, zIndex: 2, token: ""),
                        makeObject(kind: .subtitle, zIndex: 1, token: ""),
                    ]
                )
            ]
        }
    }

    static func objects(from slide: Slide, number: Int) -> [CanvasObject] {
        if slide.isProgramMediaCue {
            if slide.canvas.isEmpty { return [] }
            if isLegacyMediaCuePlaceholderCanvas(slide) { return [] }
        }
        if !slide.canvas.isEmpty {
            return slide.canvas
        }
        if !slide.elements.isEmpty {
            return slide.elements.enumerated().map { index, element in
                textObject(
                    name: "Text Box \(number * 10 + index)",
                    kind: .text,
                    bounds: CanvasBounds(
                        x: element.x * CanvasConfig.width - 1400,
                        y: element.y * CanvasConfig.height - 100,
                        width: 2800,
                        height: 200
                    ),
                    zIndex: slide.elements.count - index,
                    text: element.text,
                    fontSize: 80
                )
            }
        }
        var lines = slide.lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if slide.canvas.isEmpty && slide.themeVariantID == nil && slide.theme == "Default" {
            let title = slide.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if lines.isEmpty || lines.allSatisfy({ $0 == title }) {
                return []
            }
        }
        if lines.isEmpty {
            return []
        }
        return lines.enumerated().map { index, line in
            textObject(
                name: "Text Box \(max(1, 25 - index))",
                kind: .text,
                bounds: CanvasBounds(x: 320, y: 360 + Double(index) * 240, width: 3200, height: 200),
                zIndex: lines.count - index,
                text: line,
                fontSize: 80
            )
        }
    }

    static func themeObjects(for variant: String) -> [CanvasObject] {
        DefaultSeedData.themeObjects(for: variant)
    }

    /// Editor used to seed a title text box from `previewSummary`; drop that when opening media cues.
    private static func isLegacyMediaCuePlaceholderCanvas(_ slide: Slide) -> Bool {
        guard slide.canvas.count == 1, let object = slide.canvas.first, object.isTextLike else { return false }
        let text = object.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if text == slide.title { return true }
        if text == slide.previewSummary { return true }
        if let media = slide.mediaAction?.title, text == media { return true }
        return false
    }

    private static func textObject(
        name: String,
        kind: CanvasObjectKind,
        bounds: CanvasBounds,
        zIndex: Int,
        text: String,
        fontSize: Double = 64
    ) -> CanvasObject {
        var object = CanvasObject(name: name, kind: kind, bounds: bounds, zIndex: zIndex, text: text, fontSize: fontSize)
        object.fill.type = .none
        object.stroke.style = .none
        object.transform.lockAspectRatio = false
        object.textLayout.lineHeight = 1.2
        return object
    }
}
