import SwiftUI
#if os(macOS)
import AppKit
#endif

private struct PortPositionPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGPoint] = [:]

    static func reduce(value: inout [UUID: CGPoint], nextValue: () -> [UUID: CGPoint]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct WireDragActions {
    var began: (UUID, CGPoint) -> Void
    var moved: (CGPoint) -> Void
    var ended: (CGPoint) -> Void
}

private struct WireDragActionsKey: EnvironmentKey {
    static let defaultValue: WireDragActions? = nil
}

private extension EnvironmentValues {
    var wireDragActions: WireDragActions? {
        get { self[WireDragActionsKey.self] }
        set { self[WireDragActionsKey.self] = newValue }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private final class PortPositionStore {
    var positions: [UUID: CGPoint] = [:]
}

struct RoutingNodeGraphView: View {
    @Bindable var controller: ShowController
    var onSelectPlaceholder: (String) -> Void = { _ in }

    @State private var dragWireStartPort: (id: UUID, position: CGPoint)?
    @State private var dragWireCurrentLocation: CGPoint = .zero
    @State private var dragSnappedPortId: UUID?
    @State private var portStore = PortPositionStore()
    @State private var zoom: Double = 0.85
    @State private var pan: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var pinchStartZoom: Double?
    @State private var pickingNodeID: UUID?
    @State private var workspaceSize: CGSize = .zero
    @State private var isPanning = false
    @State private var laserStart: CGPoint?
    @State private var laserCurrent: CGPoint?
    @State private var paletteAnchor: CGPoint = .zero
    @State private var cursorStore = GraphCursorStore()
    @State private var cloneOrigins: [UUID: CGPoint] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var matrix: PlaceholderMatrixEngine { controller.placeholderMatrix }

    var body: some View {
        let snapshot = rebuiltSnapshot
        VStack(spacing: 0) {
            graphToolbar
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    GridPatternBackground()
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(canvasGesture)
                        .simultaneousGesture(canvasTap)
                    contentLayer(snapshot)
                        .scaleEffect(zoom, anchor: .topLeading)
                        .offset(pan)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .coordinateSpace(name: "RoutingCanvas")
                .overlayPreferenceValue(PortPositionPreferenceKey.self) { positions in
                    let _ = portStore.positions = positions
                    BezierWireCanvas(
                        connections: snapshot.connections,
                        portPositions: positions,
                        activeDragWire: dragPreview(in: snapshot, positions: positions),
                        laser: laserPreview,
                        disabledIDs: disabledCableIDs(in: snapshot),
                        reduceMotion: reduceMotion
                    )
                    .allowsHitTesting(false)
                }
                .clipped()
                .contentShape(Rectangle())
                .simultaneousGesture(pinchGesture)
                .background {
                    #if os(macOS)
                    MapGraphScrollCatcher(
                        store: cursorStore,
                        onScroll: { deltaY, deltaX, location, command in
                            if command {
                                applyZoom(zoom * (deltaY < 0 ? 1.08 : 0.92), focus: location)
                            } else {
                                pan = CGSize(width: pan.width + deltaX, height: pan.height + deltaY)
                                panStart = pan
                            }
                        }
                    )
                    #endif
                }
                .overlay(alignment: .topLeading) {
                    if matrix.isGraphPaletteOpen {
                        NodeCommandPaletteView(
                            items: NodeCommandCatalog.items(
                                sources: controller.placeholderSourceChoices,
                                layers: controller.masterLayers,
                                scenes: controller.scenes.scenes
                            ),
                            onChoose: { item in
                                controller.addMapCommandItem(item, at: canvasPoint(fromView: paletteAnchor))
                            },
                            onCancel: {
                                matrix.isGraphPaletteOpen = false
                            }
                        )
                        .offset(x: paletteX(in: geometry.size), y: paletteY(in: geometry.size))
                        .zIndex(20)
                        .transaction { $0.animation = nil }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if matrix.showsGraphMinimap {
                        mapMinimap(snapshot, in: geometry.size)
                    }
                }
                .overlay {
                    if snapshot.allNodes.isEmpty {
                        Text("Add a Source, Placeholder, or Layer")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.42))
                            .allowsHitTesting(false)
                    }
                }
                .onAppear {
                    if workspaceSize != geometry.size {
                        workspaceSize = geometry.size
                    }
                }
                .onChange(of: geometry.size) { _, size in
                    if workspaceSize != size {
                        workspaceSize = size
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .proShowMapViewport)) { note in
                    guard let command = note.object as? NodeGraphCommand else { return }
                    switch command {
                    case .zoomFit:
                        fit(rebuiltSnapshot, in: workspaceSize)
                    case .zoomOne:
                        applyZoom(1, focus: CGPoint(x: workspaceSize.width / 2, y: workspaceSize.height / 2))
                    case .toggleMinimap:
                        matrix.showsGraphMinimap.toggle()
                    case .palette:
                        matrix.isGraphPaletteOpen = true
                    default:
                        break
                    }
                }
                .onChange(of: matrix.isGraphPaletteOpen) { _, open in
                    if open {
                        freezePaletteAnchor()
                        highlightWireAtCursor()
                    }
                }
            }
            .environment(\.wireDragActions, WireDragActions(
                began: { portId, location in
                    dragWireStartPort = (portId, portStore.positions[portId] ?? location)
                    dragWireCurrentLocation = location
                    dragSnappedPortId = nil
                },
                moved: { location in
                    dragWireCurrentLocation = location
                    dragSnappedPortId = NodeRoutingGraph.findSnapTargetPort(
                        near: location,
                        portPositions: portStore.positions,
                        excluding: dragWireStartPort?.id,
                        allowed: dragWireStartPort.map {
                            NodeRoutingGraph.validTargetPortIDs(from: $0.id, nodes: rebuiltSnapshot.allNodes)
                        }
                    )
                },
                ended: { location in
                    if let start = dragWireStartPort {
                        #if os(macOS)
                        if NSEvent.modifierFlags.contains(.command), NSEvent.modifierFlags.contains(.option) {
                            controller.swapMapLink(at: start.position, portPositions: portStore.positions)
                            dragWireStartPort = nil
                            dragSnappedPortId = nil
                            return
                        }
                        #endif
                        controller.applyMapCable(
                            from: start.id,
                            toLocation: location,
                            snappedPortId: dragSnappedPortId,
                            portPositions: portStore.positions
                        )
                        dragWireStartPort = nil
                        dragSnappedPortId = nil
                    }
                }
            ))
            zoomBar
        }
    }

    private var graphToolbar: some View {
        HStack(spacing: 8) {
            addButton("Source", symbol: "video.fill") { controller.addMapGraphNode(kind: .inputSource) }
            addButton("Placeholder", symbol: "square.grid.2x2") { controller.addMapGraphNode(kind: .placeholder) }
            addButton("Layer", symbol: "film") { controller.addMapGraphNode(kind: .masterLayer) }
            addButton("Filter", symbol: "slider.horizontal.3") {
                _ = controller.placeholderMatrix.addGraphNode(kind: .processFilter, title: "Chroma Key", filterID: NodeFilterCatalog.chroma.rawValue)
                controller.persistStudio()
            }
            Button {
                freezePaletteAnchor(fallback: CGPoint(x: workspaceSize.width / 2, y: 80))
                matrix.isGraphPaletteOpen = true
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(DeskPressButtonStyle())
            .help("Add node (Shift+Space)")
            .accessibilityLabel("Open add-node palette")
            Spacer()
            Text("Drag blank to pan · ⌘ scroll zoom · Opt slice")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.42))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func addButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StartHome.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(StartHome.lemon, in: Capsule(style: .continuous))
        }
        .buttonStyle(DeskPressButtonStyle())
    }

    private func contentLayer(_ snapshot: NodeRoutingSnapshot) -> some View {
        let collapsed = Set(matrix.graphBackdrops.filter(\.isCollapsed).flatMap(\.childIDs))
        return ZStack(alignment: .topLeading) {
            ForEach(matrix.graphBackdrops) { group in
                NodeBackdropView(
                    group: group,
                    onMove: { x, y in controller.moveMapBackdrop(id: group.id, x: x, y: y) },
                    onToggleCollapse: { controller.toggleMapBackdropCollapsed(id: group.id) }
                )
            }
            ForEach(snapshot.allNodes.filter { !collapsed.contains($0.id) }) { node in
                let size = nodeSize(node)
                MapColorNodeCard(
                    node: node,
                    selected: matrix.selectedGraphNodeIDs.contains(node.id) || node.id == matrix.selectedGraphNodeID,
                    fill: StartHome.rowTint(node.fillIndex),
                    isPicking: pickingNodeID == node.id,
                    isRenaming: matrix.renamingGraphNodeID == node.id,
                    sources: controller.placeholderSourceChoices,
                    placeholders: controller.placeholderMatrix.placeholders,
                    layers: controller.masterLayers,
                    scenes: controller.scenes.scenes,
                    onPickSource: { controller.assignMapGraphSource(id: node.id, sourceId: $0) },
                    onImportSource: { url in
                        if let item = controller.importMedia(url: url) {
                            controller.assignMapGraphSource(id: node.id, sourceId: item.id.uuidString)
                        }
                    },
                    artworkURL: { controller.artworkURL(forSource: $0) },
                    onPickPlaceholder: { controller.assignMapGraphPlaceholder(id: node.id, letter: $0) },
                    onPickLayer: { controller.assignMapGraphLayer(id: node.id, layerIndex: $0) },
                    onPickScene: { controller.assignMapGraphScene(id: node.id, sceneID: $0) },
                    onTogglePick: { pickingNodeID = pickingNodeID == node.id ? nil : node.id },
                    onDismissPick: { pickingNodeID = nil },
                    onSelect: { select(node) },
                    onMove: { x, y in finishNodeMove(node, x: x, y: y) },
                    onRename: { controller.renameMapGraphNode(id: node.id, title: $0) }
                )
                .frame(width: size.width, height: size.height)
                .offset(x: node.canvasX, y: node.canvasY)
            }
        }
        .frame(
            width: max(bounds(of: snapshot).maxX + 80, 1),
            height: max(bounds(of: snapshot).maxY + 80, 1),
            alignment: .topLeading
        )
    }

    private func bounds(of snapshot: NodeRoutingSnapshot) -> CGRect {
        guard let first = snapshot.allNodes.first else {
            return CGRect(x: 0, y: 0, width: 900, height: 600)
        }
        var rect = CGRect(x: first.canvasX, y: first.canvasY, width: MapGraphMetrics.nodeWidth, height: MapGraphMetrics.nodeHeight)
        for node in snapshot.allNodes.dropFirst() {
            rect = rect.union(CGRect(x: node.canvasX, y: node.canvasY, width: MapGraphMetrics.nodeWidth, height: MapGraphMetrics.nodeHeight))
        }
        return rect
    }

    private var zoomBar: some View {
        HStack(spacing: 10) {
            Button { zoomAroundCenter(zoom / 1.15) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            Button { fit(rebuiltSnapshot, in: workspaceSize) } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 40)
            }
            .buttonStyle(.plain)
            .help("Fit to view")
            Button { zoomAroundCenter(zoom * 1.15) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            Slider(value: Binding(get: { zoom }, set: { zoomAroundCenter($0) }), in: 0.25...2.5)
                .frame(width: 110)
            Spacer()
        }
        .foregroundStyle(Color.white.opacity(0.7))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var canvasTap: some Gesture {
        SpatialTapGesture(coordinateSpace: .named("RoutingCanvas"))
            .onEnded { value in
                handleCanvasTap(value.location)
            }
    }

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("RoutingCanvas"))
            .onChanged { value in
                guard dragWireStartPort == nil else { return }
                #if os(macOS)
                if optionHeld, !matrix.graphSpaceHeld {
                    if laserStart == nil { laserStart = value.startLocation }
                    laserCurrent = value.location
                    return
                }
                #endif
                if !isPanning {
                    isPanning = true
                    panStart = pan
                }
                pan = CGSize(width: panStart.width + value.translation.width, height: panStart.height + value.translation.height)
            }
            .onEnded { _ in
                #if os(macOS)
                if let start = laserStart, let end = laserCurrent {
                    controller.sliceMapWires(from: start, to: end, portPositions: portStore.positions)
                    laserStart = nil
                    laserCurrent = nil
                    isPanning = false
                    return
                }
                #endif
                isPanning = false
                panStart = pan
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartZoom == nil { pinchStartZoom = zoom }
                applyZoom(
                    (pinchStartZoom ?? zoom) * Double(value.magnification),
                    focus: value.startLocation
                )
            }
            .onEnded { _ in
                pinchStartZoom = nil
            }
    }

    private func select(_ node: RoutingNode) {
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.shift) {
            var ids = matrix.selectedGraphNodeIDs
            if ids.contains(node.id) { ids.remove(node.id) } else { ids.insert(node.id) }
            matrix.selectGraphNodes(ids)
        } else {
            matrix.selectGraphNodes([node.id])
        }
        #else
        matrix.selectGraphNodes([node.id])
        #endif
        if let placeholderID = node.placeholderID {
            onSelectPlaceholder(placeholderID)
        }
    }

    private func zoomAroundCenter(_ next: Double) {
        applyZoom(
            next,
            focus: CGPoint(x: max(workspaceSize.width, 1) / 2, y: max(workspaceSize.height, 1) / 2)
        )
    }

    private func applyZoom(_ next: Double, focus: CGPoint) {
        let clamped = min(2.5, max(0.25, next))
        let previous = zoom
        guard abs(clamped - previous) > 0.0001, previous > 0 else {
            zoom = clamped
            return
        }
        let contentX = (focus.x - pan.width) / previous
        let contentY = (focus.y - pan.height) / previous
        zoom = clamped
        pan = CGSize(
            width: focus.x - contentX * clamped,
            height: focus.y - contentY * clamped
        )
        panStart = pan
    }

    private func fit(_ snapshot: NodeRoutingSnapshot, in size: CGSize) {
        let bounds = bounds(of: snapshot).insetBy(dx: -40, dy: -40)
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return }
        zoom = min(size.width / bounds.width, size.height / bounds.height, 1.1)
        pan = CGSize(
            width: (size.width - bounds.width * zoom) / 2 - bounds.minX * zoom,
            height: (size.height - bounds.height * zoom) / 2 - bounds.minY * zoom
        )
        panStart = pan
    }

    private var rebuiltSnapshot: NodeRoutingSnapshot {
        NodeRoutingGraph.build(
            sources: controller.placeholderSourceChoices,
            videoSources: controller.videoInputs.sources,
            placeholders: controller.placeholderMatrix.placeholders,
            usingFailover: controller.placeholderMatrix.usingFailover,
            layers: controller.masterLayers,
            scenes: controller.scenes.scenes,
            placements: controller.placeholderMatrix.graphPlacements,
            links: controller.placeholderMatrix.graphLinks
        )
    }

    private func dragPreview(in snapshot: NodeRoutingSnapshot, positions: [UUID: CGPoint]) -> (start: CGPoint, end: CGPoint)? {
        guard let start = dragWireStartPort else { return nil }
        let snapped = NodeRoutingGraph.findSnapTargetPort(
            near: dragWireCurrentLocation,
            portPositions: positions,
            excluding: start.id,
            allowed: NodeRoutingGraph.validTargetPortIDs(from: start.id, nodes: snapshot.allNodes)
        )
        let end = snapped.flatMap { positions[$0] } ?? dragWireCurrentLocation
        return (start.position, end)
    }

    private var optionHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }

    private var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }

    private var laserPreview: (start: CGPoint, end: CGPoint)? {
        guard let start = laserStart, let end = laserCurrent else { return nil }
        return (start, end)
    }

    private func nodeSize(_ node: RoutingNode) -> CGSize {
        switch node.kind {
        case .passThrough:
            return CGSize(width: 36, height: 36)
        case .stickyNote:
            return CGSize(width: 180, height: 110)
        default:
            return CGSize(width: MapGraphMetrics.nodeWidth, height: MapGraphMetrics.nodeHeight)
        }
    }

    private func canvasPoint(fromView point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - pan.width) / max(zoom, 0.01),
            y: (point.y - pan.height) / max(zoom, 0.01)
        )
    }

    private func handleCanvasTap(_ location: CGPoint) {
        cursorStore.viewPoint = location
        #if os(macOS)
        if NSEvent.modifierFlags.contains(.command), NSEvent.modifierFlags.contains(.option) {
            controller.swapMapLink(at: location, portPositions: portStore.positions)
            return
        }
        if optionHeld {
            controller.addMapReroutePin(
                at: location,
                canvasPoint: canvasPoint(fromView: location),
                portPositions: portStore.positions
            )
            return
        }
        #endif
        if !matrix.isGraphPaletteOpen {
            matrix.selectGraphNodes([])
        }
    }

    private func finishNodeMove(_ node: RoutingNode, x: Double, y: Double) {
        #if os(macOS)
        if optionHeld {
            if cloneOrigins[node.id] == nil {
                cloneOrigins[node.id] = CGPoint(x: node.canvasX, y: node.canvasY)
            }
            controller.duplicateSelectedMapNodes()
            if let origin = cloneOrigins[node.id] {
                controller.moveMapGraphNode(id: node.id, x: origin.x, y: origin.y)
            }
            cloneOrigins[node.id] = nil
            if let copy = matrix.selectedGraphNodeIDs.first(where: { $0 != node.id }) {
                controller.moveMapGraphNode(id: copy, x: x, y: y)
            }
            return
        }
        #endif
        controller.moveMapGraphNode(id: node.id, x: x, y: y)
        if shiftHeld {
            controller.spliceMapNodeIfNeeded(id: node.id)
        }
    }

    private func disabledCableIDs(in snapshot: NodeRoutingSnapshot) -> Set<UUID> {
        let muted = Set(snapshot.allNodes.filter { $0.isBypassed || $0.isMuted }.map(\.id))
        return Set(snapshot.connections.compactMap { connection in
            let from = snapshot.allNodes.first { node in node.outputPorts.contains { $0.id == connection.startPortId } }
            let to = snapshot.allNodes.first { node in node.inputPorts.contains { $0.id == connection.endPortId } }
            if from.map({ muted.contains($0.id) }) == true || to.map({ muted.contains($0.id) }) == true {
                return connection.id
            }
            return nil
        })
    }

    private func highlightWireAtCursor() {
        let snapshot = rebuiltSnapshot
        guard let wire = NodeGraphGeometry.hitWire(
            at: paletteAnchor,
            connections: snapshot.connections,
            portPositions: portStore.positions
        ),
              let from = snapshot.allNodes.first(where: { node in node.outputPorts.contains { $0.id == wire.startPortId } }),
              let to = snapshot.allNodes.first(where: { node in node.inputPorts.contains { $0.id == wire.endPortId } })
        else {
            matrix.highlightedGraphLinkID = nil
            return
        }
        matrix.highlightedGraphLinkID = matrix.graphLinks.first {
            $0.fromPlacementID == from.id && $0.toPlacementID == to.id
        }?.id
    }

    private func freezePaletteAnchor(fallback: CGPoint? = nil) {
        let live = cursorStore.viewPoint
        if live != .zero {
            paletteAnchor = live
        } else if let fallback {
            paletteAnchor = fallback
        } else {
            paletteAnchor = CGPoint(x: max(workspaceSize.width, 1) / 2, y: 80)
        }
    }

    private func paletteX(in size: CGSize) -> CGFloat {
        min(max(12, paletteAnchor.x - 40), max(size.width - 380, 12))
    }

    private func paletteY(in size: CGSize) -> CGFloat {
        min(max(12, paletteAnchor.y + 12), max(size.height - 220, 12))
    }

    private func mapMinimap(_ snapshot: NodeRoutingSnapshot, in size: CGSize) -> some View {
        let world = bounds(of: snapshot).insetBy(dx: -40, dy: -40)
        let width: CGFloat = 168
        let height: CGFloat = 104
        let scale = min(width / max(world.width, 1), height / max(world.height, 1))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.55))
            ForEach(snapshot.allNodes) { node in
                Circle()
                    .fill(StartHome.rowTint(node.fillIndex))
                    .frame(width: 6, height: 6)
                    .offset(
                        x: (node.canvasX - world.minX) * scale,
                        y: (node.canvasY - world.minY) * scale
                    )
            }
            let viewX = (-pan.width / zoom - world.minX) * scale
            let viewY = (-pan.height / zoom - world.minY) * scale
            Rectangle()
                .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                .frame(width: max(size.width / zoom * scale, 12), height: max(size.height / zoom * scale, 8))
                .offset(x: viewX, y: viewY)
        }
        .frame(width: width, height: height)
        .padding(10)
        .accessibilityLabel("Node graph overview")
    }
}

private struct MapColorNodeCard: View {
    let node: RoutingNode
    var selected: Bool
    var fill: Color
    var isPicking: Bool
    var isRenaming: Bool
    var sources: [PlaceholderSourceChoice]
    var placeholders: [PlaceholderConfiguration]
    var layers: [MasterLayer]
    var scenes: [ProShowScene]
    var onPickSource: (String?) -> Void
    var onImportSource: (URL) -> Void
    var artworkURL: (PlaceholderSourceChoice) -> URL?
    var onPickPlaceholder: (String?) -> Void
    var onPickLayer: (Int?) -> Void
    var onPickScene: (UUID?) -> Void
    var onTogglePick: () -> Void
    var onDismissPick: () -> Void
    var onSelect: () -> Void
    var onMove: (Double, Double) -> Void
    var onRename: (String) -> Void

    @State private var draftTitle = ""

    @State private var liveDrag: CGSize = .zero

    var body: some View {
        cardBody
            .gesture(moveGesture)
            .overlay(alignment: .topLeading) {
                if let input = node.inputPorts.first {
                    NodePortView(portId: input.id, isOutput: false, isConnected: input.isConnected, portColor: .white)
                        .padding(10)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let output = node.outputPorts.first {
                    NodePortView(portId: output.id, isOutput: true, isConnected: output.isConnected, portColor: .white)
                        .padding(10)
                }
            }
            .offset(liveDrag)
        .popover(isPresented: Binding(get: { isPicking }, set: { presented in
            if !presented { onDismissPick() }
        })) {
            assignmentMenu
                .frame(minWidth: 320)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 18, height: 18)
                Image(systemName: node.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StartHome.ink.opacity(0.82))
                Spacer(minLength: 0)
                Circle()
                    .fill(node.isLive ? Color.red : (node.isPreview ? Color.green : StartHome.ink.opacity(0.22)))
                    .frame(width: 8, height: 8)
                Color.clear.frame(width: 18, height: 18)
            }
            if isRenaming {
                TextField("Node name", text: $draftTitle, onCommit: { onRename(draftTitle) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartHome.ink)
                    .onAppear { draftTitle = node.title }
                    .accessibilityLabel("Rename node")
            } else {
                Button {
                    onSelect()
                    onTogglePick()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(node.title)
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundStyle(StartHome.ink)
                            .lineLimit(1)
                        if node.kind != .passThrough {
                            Text(node.isUnassigned ? assignHint : node.subtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(StartHome.ink.opacity(0.58))
                                .lineLimit(1)
                            Text(node.detail)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(StartHome.ink.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DeskPressButtonStyle())
            }
        }
        .padding(node.kind == .passThrough ? 6 : 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(fill.opacity(node.isBypassed || node.isMuted ? 0.45 : 1), in: RoundedRectangle(cornerRadius: node.kind == .passThrough ? 18 : 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(selected ? Color.white : (node.isLiveLocked ? Color.red.opacity(0.8) : Color.clear), lineWidth: 2)
        }
        .overlay(alignment: .bottomTrailing) {
            if node.isBypassed || node.isMuted {
                Text(node.isMuted ? "M" : "BYP")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .padding(8)
                    .accessibilityLabel(node.isMuted ? "Muted" : "Bypassed")
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
    }

    private var assignHint: String {
        switch node.kind {
        case .inputSource: "Click to choose media"
        case .placeholder: "Click to choose A–I"
        case .masterLayer: "Click to choose a layer"
        case .scene: "Click to choose a scene"
        case .processFilter: "GPU filter"
        case .passThrough: "Reroute pin"
        case .stickyNote: "Operator note"
        }
    }

    @ViewBuilder
    private var assignmentMenu: some View {
        switch node.kind {
        case .inputSource:
            MapSourcePickerView(
                sources: sources,
                selectedID: node.hardwareSourceId,
                artworkURL: artworkURL,
                onPick: onPickSource,
                onImport: onImportSource
            )
        case .placeholder:
            VStack(alignment: .leading, spacing: 8) {
                Text("Placeholder").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    ForEach(PlaceholderLetter.allCases, id: \.self) { letter in
                        Button(letter.rawValue) { onPickPlaceholder(letter.rawValue) }
                            .buttonStyle(.borderedProminent)
                            .tint(StartHome.rowTint(letter.tintIndex))
                    }
                }
            }
        case .masterLayer:
            VStack(alignment: .leading, spacing: 6) {
                Text("Master layer").font(.headline)
                ForEach(layers) { layer in
                    Button(layer.title) { onPickLayer(layer.index) }
                }
            }
        case .scene:
            VStack(alignment: .leading, spacing: 6) {
                Text("Scene").font(.headline)
                ForEach(scenes) { scene in
                    Button(scene.name) { onPickScene(scene.id) }
                }
            }
        case .processFilter:
            VStack(alignment: .leading, spacing: 6) {
                Text("GPU filter").font(.headline)
                ForEach(NodeFilterCatalog.allCases, id: \.self) { filter in
                    Text(filter.title)
                }
            }
        case .passThrough, .stickyNote:
            Text(node.kind == .stickyNote ? "Sticky note" : "Reroute pin")
                .font(.headline)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                liveDrag = value.translation
            }
            .onEnded { value in
                onMove(node.canvasX + value.translation.width, node.canvasY + value.translation.height)
                liveDrag = .zero
            }
    }
}

public struct NodePortView: View {
    public let portId: UUID
    public let isOutput: Bool
    public let isConnected: Bool
    public let portColor: Color

    @Environment(\.wireDragActions) private var wireDrag
    @State private var isDragging = false

    public var body: some View {
        Circle()
            .fill(isConnected ? StartHome.ink : StartHome.ink.opacity(0.28))
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(portColor, lineWidth: 2))
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: PortPositionPreferenceKey.self,
                        value: [portId: geo.frame(in: .named("RoutingCanvas")).center]
                    )
                }
            )
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("RoutingCanvas"))
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            wireDrag?.began(portId, value.startLocation)
                        }
                        wireDrag?.moved(value.location)
                    }
                    .onEnded { value in
                        isDragging = false
                        wireDrag?.ended(value.location)
                    }
            )
            .allowsHitTesting(true)
            .help(isOutput ? "Drag this port to connect" : "Drop a cable on this port")
    }
}

private final class GraphCursorStore {
    var viewPoint: CGPoint = .zero
}

#if os(macOS)
private struct MapGraphScrollCatcher: NSViewRepresentable {
    var store: GraphCursorStore
    var onScroll: (CGFloat, CGFloat, CGPoint, Bool) -> Void

    func makeNSView(context: Context) -> MapGraphScrollView {
        let view = MapGraphScrollView()
        view.store = store
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MapGraphScrollView, context: Context) {
        nsView.store = store
        nsView.onScroll = onScroll
    }
}

private final class MapGraphScrollView: NSView {
    var store: GraphCursorStore?
    var onScroll: ((CGFloat, CGFloat, CGPoint, Bool) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let command = event.modifierFlags.contains(.command)
        if command {
            onScroll?(event.scrollingDeltaY, event.scrollingDeltaX, location, true)
            return
        }
        onScroll?(event.scrollingDeltaY, event.scrollingDeltaX, location, false)
    }

    override func mouseMoved(with event: NSEvent) {
        store?.viewPoint = convert(event.locationInWindow, from: nil)
        super.mouseMoved(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        store?.viewPoint = convert(event.locationInWindow, from: nil)
        super.mouseDragged(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }
}
#endif
