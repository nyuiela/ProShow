import Foundation
import CoreGraphics
import Observation

struct PlaceholderTransitionFrame: Equatable, Sendable {
    var offsetX: Double
    var offsetY: Double
    var scale: Double
    var opacity: Double
    var progress: Double

    static let identity = PlaceholderTransitionFrame(offsetX: 0, offsetY: 0, scale: 1, opacity: 1, progress: 1)
}

enum PlaceholderTransitionEngine {
    static func clampedProgress(elapsed: Double, duration: Double) -> Double {
        let span = max(duration, 0.001)
        return min(1, max(0, elapsed / span))
    }

    static func easedProgress(
        elapsed: Double,
        duration: Double,
        style: TransitionPhysicsStyle,
        damping: Double = 0.72
    ) -> Double {
        let linear = clampedProgress(elapsed: elapsed, duration: duration)
        switch style {
        case .cut:
            return linear >= 1 ? 1 : 0
        case .dissolve, .pushLeft, .pushRight, .flyFromTop, .flyFromBottom, .smoothZoomScale:
            return 1 - pow(1 - linear, 3)
        case .springBounce:
            return spring(linear, damping: damping)
        }
    }

    static func spring(_ t: Double, damping: Double, stiffness: Double = 180) -> Double {
        let omega = max(8, stiffness / 12)
        let zeta = min(1.2, max(0.15, damping))
        let decay = exp(-zeta * omega * t)
        return min(1.15, max(0, 1 - decay * cos(omega * t * (1 - zeta * 0.35))))
    }

    static func frame(
        style: TransitionPhysicsStyle,
        progress: Double,
        bounds: CGRect,
        entering: Bool,
        damping: Double = 0.72
    ) -> PlaceholderTransitionFrame {
        let t = entering ? progress : (1 - progress)
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        switch style {
        case .cut:
            return PlaceholderTransitionFrame(offsetX: 0, offsetY: 0, scale: 1, opacity: t >= 1 ? 1 : 0, progress: t)
        case .dissolve:
            return PlaceholderTransitionFrame(offsetX: 0, offsetY: 0, scale: 1, opacity: t, progress: t)
        case .pushLeft:
            return PlaceholderTransitionFrame(offsetX: (1 - t) * -width, offsetY: 0, scale: 1, opacity: 1, progress: t)
        case .pushRight:
            return PlaceholderTransitionFrame(offsetX: (1 - t) * width, offsetY: 0, scale: 1, opacity: 1, progress: t)
        case .flyFromTop:
            return PlaceholderTransitionFrame(offsetX: 0, offsetY: (1 - t) * -height, scale: 1, opacity: 1, progress: t)
        case .flyFromBottom:
            return PlaceholderTransitionFrame(offsetX: 0, offsetY: (1 - t) * height, scale: 1, opacity: 1, progress: t)
        case .springBounce:
            let sprung = spring(t, damping: damping)
            return PlaceholderTransitionFrame(offsetX: 0, offsetY: (1 - sprung) * 48, scale: 0.86 + 0.14 * sprung, opacity: min(1, sprung), progress: sprung)
        case .smoothZoomScale:
            return PlaceholderTransitionFrame(offsetX: 0, offsetY: 0, scale: 0.72 + 0.28 * t, opacity: t, progress: t)
        }
    }
}

@Observable
final class PlaceholderMatrixEngine {
    var placeholders: [PlaceholderConfiguration]
    var selectedID: String?
    var inspectorTab: MapInspectorTab = .source
    var usingFailover: Set<String> = []
    var lastFrameAt: [String: Date] = [:]
    var testElapsed: Double = 0
    var testEntering: Bool = true
    var isTesting: Bool = false
    var lastFiredMacros: [PlaceholderMacroEvent: UUID] = [:]
    var graphPlacements: [MapGraphPlacement] = []
    var graphLinks: [MapGraphLink] = []
    var graphBackdrops: [MapBackdropGroup] = []
    var selectedGraphNodeID: UUID?
    var selectedGraphNodeIDs: Set<UUID> = []
    var graphSpaceHeld = false
    var isGraphPaletteOpen = false
    var showsGraphMinimap = false
    var renamingGraphNodeID: UUID?
    var highlightedGraphLinkID: UUID?

    init(placeholders: [PlaceholderConfiguration] = PlaceholderConfiguration.catalog()) {
        self.placeholders = placeholders
        self.selectedID = placeholders.first?.id
    }

    var selected: PlaceholderConfiguration? {
        guard let selectedID else { return nil }
        return placeholders.first { $0.id == selectedID }
    }

    var active: [PlaceholderConfiguration] { placeholders.filter(\.isActive) }
    var inactive: [PlaceholderConfiguration] { placeholders.filter { !$0.isActive } }

    func select(_ id: String) {
        selectedID = id
    }

    func mutateSelected(_ body: (inout PlaceholderConfiguration) -> Void) {
        guard let selectedID, let index = placeholders.firstIndex(where: { $0.id == selectedID }) else { return }
        body(&placeholders[index])
    }

    @discardableResult
    func remap(id: String, primarySourceId: String?) -> PlaceholderConfiguration? {
        guard let index = placeholders.firstIndex(where: { $0.id == id }) else { return nil }
        placeholders[index] = PlaceholderMatrix.remap(placeholders[index], primarySourceId: primarySourceId)
        usingFailover.remove(id)
        return placeholders[index]
    }

    @discardableResult
    func route(id: String, layerIndex: Int?) -> PlaceholderConfiguration? {
        guard let index = placeholders.firstIndex(where: { $0.id == id }) else { return nil }
        placeholders[index] = PlaceholderMatrix.route(to: placeholders[index], layerIndex: layerIndex)
        return placeholders[index]
    }

    @discardableResult
    func setState(id: String, _ state: PlaceholderState) -> PlaceholderMacroEvent? {
        guard let index = placeholders.firstIndex(where: { $0.id == id }) else { return nil }
        let result = PlaceholderMatrix.applyState(placeholders[index], state)
        placeholders[index] = result.0
        if let event = result.1, let macro = PlaceholderMatrix.macroID(for: result.0, event: event) {
            lastFiredMacros[event] = macro
        }
        return result.1
    }

    func noteFrame(id: String, hasSignal: Bool, now: Date = Date()) {
        if hasSignal {
            lastFrameAt[id] = now
        } else if lastFrameAt[id] == nil {
            lastFrameAt[id] = now
        }
    }

    @discardableResult
    func evaluateFailover(now: Date = Date()) -> [UUID] {
        var fired: [UUID] = []
        for placeholder in placeholders {
            let failed = usingFailover.contains(placeholder.id)
            if PlaceholderMatrix.shouldFailover(
                placeholder,
                lastFrameAt: lastFrameAt[placeholder.id],
                now: now,
                alreadyFailed: failed
            ) {
                usingFailover.insert(placeholder.id)
                if let macro = placeholder.onFailoverMacroId {
                    lastFiredMacros[.onFailover] = macro
                    fired.append(macro)
                }
            }
        }
        return fired
    }

    func simulateSignalDrop(id: String, now: Date = Date()) {
        guard let placeholder = placeholders.first(where: { $0.id == id }) else { return }
        lastFrameAt[id] = now.addingTimeInterval(-(placeholder.failoverTimeoutSeconds + 0.05))
    }

    func beginTest(entering: Bool) {
        testEntering = entering
        testElapsed = 0
        isTesting = true
    }

    func tickTest(delta: Double) -> PlaceholderTransitionFrame {
        guard isTesting, let selected else {
            return .identity
        }
        testElapsed += delta
        let style = testEntering ? selected.entranceTransition : selected.exitTransition
        let progress = PlaceholderTransitionEngine.easedProgress(
            elapsed: testElapsed,
            duration: selected.transitionDurationSec,
            style: style,
            damping: selected.springDampingRatio
        )
        if testElapsed >= selected.transitionDurationSec + 0.05 {
            isTesting = false
        }
        return PlaceholderTransitionEngine.frame(
            style: style,
            progress: progress,
            bounds: CGRect(x: 0, y: 0, width: 640, height: 360),
            entering: testEntering,
            damping: selected.springDampingRatio
        )
    }

    func routes(sourceNames: [String: String], layerNames: [Int: String]) -> [PlaceholderRoute] {
        placeholders.map { placeholder in
            let sourceID = usingFailover.contains(placeholder.id) ? placeholder.failoverSourceId : placeholder.primarySourceId
            return PlaceholderRoute(
                placeholderID: placeholder.id,
                sourceID: sourceID,
                sourceName: sourceID.flatMap { sourceNames[$0] } ?? "Unmapped",
                layerIndex: placeholder.targetMasterLayerIndex,
                layerName: placeholder.targetMasterLayerIndex.flatMap { layerNames[$0] } ?? "Unassigned",
                isLive: placeholder.state == .activeLive,
                usingFailover: usingFailover.contains(placeholder.id)
            )
        }
    }

    func install(_ items: [PlaceholderConfiguration]) {
        guard !items.isEmpty else { return }
        var next = items
        for index in next.indices where next[index].id == "Placeholder B" && next[index].label == "Keynote Deck" {
            next[index].label = "Screen Share"
        }
        for extra in PlaceholderConfiguration.catalog() where !next.contains(where: { $0.id == extra.id }) {
            next.append(extra)
        }
        placeholders = next
        if selectedID == nil || !next.contains(where: { $0.id == selectedID }) {
            selectedID = next.first?.id
        }
    }

    func installGraph(_ items: [MapGraphPlacement], links: [MapGraphLink] = [], backdrops: [MapBackdropGroup] = []) {
        graphPlacements = items
        let ids = Set(items.map(\.id))
        graphLinks = links.filter { ids.contains($0.fromPlacementID) && ids.contains($0.toPlacementID) }
        graphBackdrops = backdrops.map { group in
            var next = group
            next.childIDs = group.childIDs.filter { ids.contains($0) }
            return next
        }
    }

    func upsertGraphLink(from fromPlacementID: UUID, to toPlacementID: UUID) {
        guard fromPlacementID != toPlacementID else { return }
        graphLinks.removeAll { $0.toPlacementID == toPlacementID }
        graphLinks.append(MapGraphLink(fromPlacementID: fromPlacementID, toPlacementID: toPlacementID))
    }

    func removeGraphLinks(fromPort nodeID: UUID, isOutput: Bool) {
        if isOutput {
            graphLinks.removeAll { $0.fromPlacementID == nodeID }
        } else {
            graphLinks.removeAll { $0.toPlacementID == nodeID }
        }
    }

    func addGraphNode(
        kind: RoutingNodeKind,
        x: Double? = nil,
        y: Double? = nil,
        title: String? = nil,
        filterID: String? = nil,
        assignedSourceId: String? = nil,
        assignedPlaceholderID: String? = nil,
        assignedLayerIndex: Int? = nil,
        assignedSceneID: UUID? = nil
    ) -> MapGraphPlacement {
        let point = MapGraphLayout.nextPoint(kind: kind, existing: graphPlacements)
        let placement = MapGraphPlacement(
            kind: kind,
            x: x ?? point.0,
            y: y ?? point.1,
            assignedSourceId: assignedSourceId,
            assignedPlaceholderID: assignedPlaceholderID,
            assignedLayerIndex: assignedLayerIndex,
            assignedSceneID: assignedSceneID,
            fillIndex: point.2,
            title: title,
            filterID: filterID
        )
        graphPlacements.append(placement)
        selectGraphNodes([placement.id])
        return placement
    }

    func moveGraphNode(id: UUID, x: Double, y: Double) {
        guard let index = graphPlacements.firstIndex(where: { $0.id == id }) else { return }
        graphPlacements[index].x = x
        graphPlacements[index].y = y
    }

    func assignGraphSource(id: UUID, sourceId: String?) {
        guard let index = graphPlacements.firstIndex(where: { $0.id == id }) else { return }
        graphPlacements[index].assignedSourceId = sourceId
        selectGraphNodes([id])
    }

    func assignGraphPlaceholder(id: UUID, placeholderID: String?) {
        guard let index = graphPlacements.firstIndex(where: { $0.id == id }) else { return }
        graphPlacements[index].assignedPlaceholderID = placeholderID
        selectGraphNodes([id])
        if let placeholderID {
            selectedID = placeholderID
        }
    }

    func assignGraphLayer(id: UUID, layerIndex: Int?) {
        guard let index = graphPlacements.firstIndex(where: { $0.id == id }) else { return }
        graphPlacements[index].assignedLayerIndex = layerIndex
        selectGraphNodes([id])
    }

    func assignGraphScene(id: UUID, sceneID: UUID?) {
        guard let index = graphPlacements.firstIndex(where: { $0.id == id }) else { return }
        graphPlacements[index].assignedSceneID = sceneID
        selectGraphNodes([id])
    }

    func ensurePlaceholder(letter: String) -> String {
        let id = "Placeholder \(letter)"
        if !placeholders.contains(where: { $0.id == id }) {
            placeholders.append(PlaceholderConfiguration(id: id, label: letter == "I" ? "Utility" : letter))
        }
        return id
    }

    var selectedGraphNode: MapGraphPlacement? {
        guard let selectedGraphNodeID else { return nil }
        return graphPlacements.first { $0.id == selectedGraphNodeID }
    }

    func selectGraphNodes(_ ids: Set<UUID>) {
        selectedGraphNodeIDs = ids
        selectedGraphNodeID = ids.first
    }

    func removeGraphNodes(_ ids: Set<UUID>) {
        graphPlacements.removeAll { ids.contains($0.id) }
        graphLinks.removeAll { ids.contains($0.fromPlacementID) || ids.contains($0.toPlacementID) }
        graphBackdrops = graphBackdrops.compactMap { group in
            var next = group
            next.childIDs.removeAll { ids.contains($0) }
            return next.childIDs.isEmpty && ids.contains(group.id) ? nil : next
        }
        selectedGraphNodeIDs.subtract(ids)
        if selectedGraphNodeID.map(ids.contains) == true {
            selectedGraphNodeID = selectedGraphNodeIDs.first
        }
    }

    func mutateGraphNode(id: UUID, _ body: (inout MapGraphPlacement) -> Void) {
        guard let index = graphPlacements.firstIndex(where: { $0.id == id }) else { return }
        body(&graphPlacements[index])
    }

    func removeGraphLinks(ids: Set<UUID>) {
        graphLinks.removeAll { ids.contains($0.id) }
    }

    func removeGraphLinks(matching connectionIDs: Set<UUID>, snapshot: NodeRoutingSnapshot) {
        let doomed = snapshot.connections.filter { connectionIDs.contains($0.id) }
        graphLinks.removeAll { link in
            doomed.contains { connection in
                guard let from = snapshot.allNodes.first(where: { $0.id == link.fromPlacementID }),
                      let to = snapshot.allNodes.first(where: { $0.id == link.toPlacementID }),
                      let start = from.outputPorts.first?.id,
                      let end = to.inputPorts.first?.id
                else { return false }
                return connection.startPortId == start && connection.endPortId == end
            }
        }
    }
}
