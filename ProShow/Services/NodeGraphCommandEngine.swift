import CoreGraphics
import Foundation

extension Notification.Name {
    static let proShowMapViewport = Notification.Name("proShow.map.viewport")
}

enum NodeGraphCommand: Equatable, Sendable {
    case palette
    case selectAll
    case deselect
    case duplicate
    case delete
    case zoomFit
    case zoomOne
    case toggleMinimap
    case bypass
    case mute
    case liveLock
    case rename
    case group
    case ungroup
    case tidy
    case spacePan
}

enum NodeGraphHotkey {
    static let f2: UInt16 = 113
    static let zero: UInt16 = 29

    static func resolve(_ input: ShortcutInput) -> NodeGraphCommand? {
        if input.isARepeat { return nil }
        if input.keyCode == KeyboardShortcutResolver.escape, !input.command {
            return .deselect
        }
        if input.keyCode == KeyboardShortcutResolver.space, !input.command, !input.option, !input.control {
            return input.shift ? .palette : .spacePan
        }
        if input.keyCode == KeyboardShortcutResolver.delete || input.keyCode == KeyboardShortcutResolver.forwardDelete {
            return .delete
        }
        if input.keyCode == f2 {
            return .rename
        }
        if input.command {
            if input.letter == "k", !input.shift, !input.option { return .palette }
            if input.letter == "a", !input.shift, !input.option { return .selectAll }
            if input.letter == "d", !input.shift, !input.option { return .duplicate }
            if input.letter == "0" || input.keyCode == zero, !input.shift, !input.option { return .zoomOne }
            if input.letter == "g" { return input.shift ? .ungroup : .group }
            if input.letter == "l", input.option, !input.shift { return .tidy }
            return nil
        }
        if input.option || input.control { return nil }
        switch input.letter {
        case "z": return .zoomFit
        case "n": return .toggleMinimap
        case "d": return .bypass
        case "m": return .mute
        case "l": return .liveLock
        default: return nil
        }
    }
}

struct NodeCommandItem: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var symbolName: String
    var kind: Kind

    enum Kind: Hashable, Sendable {
        case source(id: String)
        case placeholder(letter: String)
        case filter(NodeFilterCatalog)
        case layer(index: Int)
        case scene(id: UUID)
        case backdrop
        case stickyNote
        case passThrough
    }
}

enum NodeCommandCatalog {
    static func items(
        sources: [PlaceholderSourceChoice],
        layers: [MasterLayer],
        scenes: [ProShowScene]
    ) -> [NodeCommandItem] {
        var items: [NodeCommandItem] = []
        for source in sources {
            items.append(
                NodeCommandItem(
                    id: "source:\(source.id)",
                    title: source.name,
                    subtitle: "Physical / network source",
                    symbolName: "video.fill",
                    kind: .source(id: source.id)
                )
            )
        }
        for letter in PlaceholderLetter.allCases {
            items.append(
                NodeCommandItem(
                    id: "ph:\(letter.rawValue)",
                    title: "Placeholder \(letter.rawValue)",
                    subtitle: "Dynamic target routing",
                    symbolName: "square.grid.2x2",
                    kind: .placeholder(letter: letter.rawValue)
                )
            )
        }
        for filter in NodeFilterCatalog.allCases {
            items.append(
                NodeCommandItem(
                    id: "filter:\(filter.rawValue)",
                    title: filter.title,
                    subtitle: filter.subtitle,
                    symbolName: filter.symbolName,
                    kind: .filter(filter)
                )
            )
        }
        for layer in layers {
            items.append(
                NodeCommandItem(
                    id: "layer:\(layer.index)",
                    title: layer.title,
                    subtitle: "Master layer \(layer.index)",
                    symbolName: "film",
                    kind: .layer(index: layer.index)
                )
            )
        }
        for scene in scenes {
            items.append(
                NodeCommandItem(
                    id: "scene:\(scene.id.uuidString)",
                    title: scene.name,
                    subtitle: "Scene output",
                    symbolName: "theatermasks",
                    kind: .scene(id: scene.id)
                )
            )
        }
        items.append(
            NodeCommandItem(
                id: "backdrop",
                title: "Backdrop group",
                subtitle: "Frame selected nodes",
                symbolName: "rectangle.dashed",
                kind: .backdrop
            )
        )
        items.append(
            NodeCommandItem(
                id: "note",
                title: "Sticky note",
                subtitle: "Operator comment",
                symbolName: "note.text",
                kind: .stickyNote
            )
        )
        items.append(
            NodeCommandItem(
                id: "pin",
                title: "Reroute pin",
                subtitle: "Pass-through routing dot",
                symbolName: "circle.fill",
                kind: .passThrough
            )
        )
        return items
    }

    static func filter(_ items: [NodeCommandItem], query: String) -> [NodeCommandItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            item.title.lowercased().contains(needle)
                || item.subtitle.lowercased().contains(needle)
                || item.id.lowercased().contains(needle)
        }
    }
}

enum NodeGraphGeometry {
    static func sampleBezier(from start: CGPoint, to end: CGPoint, steps: Int = 24) -> [CGPoint] {
        let deltaX = abs(end.x - start.x) * 0.5
        let c1 = CGPoint(x: start.x + max(deltaX, 40), y: start.y)
        let c2 = CGPoint(x: end.x - max(deltaX, 40), y: end.y)
        return (0...steps).map { index in
            let t = CGFloat(index) / CGFloat(steps)
            return cubic(start, c1, c2, end, t)
        }
    }

    static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(
            x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
            y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
        )
    }

    static func segmentsIntersect(_ a1: CGPoint, _ a2: CGPoint, _ b1: CGPoint, _ b2: CGPoint) -> Bool {
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func onSegment(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> Bool {
            min(p.x, r.x) <= q.x && q.x <= max(p.x, r.x)
                && min(p.y, r.y) <= q.y && q.y <= max(p.y, r.y)
        }
        let d1 = cross(b1, b2, a1)
        let d2 = cross(b1, b2, a2)
        let d3 = cross(a1, a2, b1)
        let d4 = cross(a1, a2, b2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        if d1 == 0 && onSegment(b1, a1, b2) { return true }
        if d2 == 0 && onSegment(b1, a2, b2) { return true }
        if d3 == 0 && onSegment(a1, b1, a2) { return true }
        if d4 == 0 && onSegment(a1, b2, a2) { return true }
        return false
    }

    static func laserCuts(
        from: CGPoint,
        to: CGPoint,
        connections: [CableConnection],
        portPositions: [UUID: CGPoint]
    ) -> [UUID] {
        connections.compactMap { connection in
            guard let start = portPositions[connection.startPortId],
                  let end = portPositions[connection.endPortId]
            else { return nil }
            let samples = sampleBezier(from: start, to: end)
            for index in 1..<samples.count where segmentsIntersect(from, to, samples[index - 1], samples[index]) {
                return connection.id
            }
            return nil
        }
    }

    static func distanceToBezier(point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let samples = sampleBezier(from: start, to: end, steps: 20)
        var best = CGFloat.greatestFiniteMagnitude
        for sample in samples {
            best = min(best, hypot(sample.x - point.x, sample.y - point.y))
        }
        return best
    }

    static func hitWire(
        at point: CGPoint,
        connections: [CableConnection],
        portPositions: [UUID: CGPoint],
        threshold: CGFloat = 10
    ) -> CableConnection? {
        var best: (CableConnection, CGFloat)?
        for connection in connections {
            guard let start = portPositions[connection.startPortId],
                  let end = portPositions[connection.endPortId]
            else { continue }
            let distance = distanceToBezier(point: point, start: start, end: end)
            if distance <= threshold, best == nil || distance < best!.1 {
                best = (connection, distance)
            }
        }
        return best?.0
    }

    static func overlappingLink(
        nodeFrame: CGRect,
        links: [MapGraphLink],
        nodes: [RoutingNode]
    ) -> MapGraphLink? {
        let center = CGPoint(x: nodeFrame.midX, y: nodeFrame.midY)
        for link in links {
            guard let from = nodes.first(where: { $0.id == link.fromPlacementID }),
                  let to = nodes.first(where: { $0.id == link.toPlacementID })
            else { continue }
            let start = CGPoint(x: from.canvasX + MapGraphMetrics.nodeWidth, y: from.canvasY + 28)
            let end = CGPoint(x: to.canvasX, y: to.canvasY + 28)
            if distanceToBezier(point: center, start: start, end: end) < 28 {
                return link
            }
        }
        return nil
    }

    static func splice(nodeID: UUID, onto link: MapGraphLink, links: [MapGraphLink]) -> [MapGraphLink] {
        guard link.fromPlacementID != nodeID, link.toPlacementID != nodeID else { return links }
        var next = links.filter { $0.id != link.id }
        next.append(MapGraphLink(fromPlacementID: link.fromPlacementID, toPlacementID: nodeID, pins: link.pins))
        next.append(MapGraphLink(fromPlacementID: nodeID, toPlacementID: link.toPlacementID))
        return next
    }

    static func swap(_ link: MapGraphLink) -> MapGraphLink {
        MapGraphLink(id: link.id, fromPlacementID: link.toPlacementID, toPlacementID: link.fromPlacementID, pins: link.pins.reversed())
    }

    static func containedIDs(in backdrop: MapBackdropGroup, placements: [MapGraphPlacement]) -> [UUID] {
        placements.compactMap { placement in
            let frame = CGRect(
                x: placement.x,
                y: placement.y,
                width: MapGraphMetrics.nodeWidth,
                height: MapGraphMetrics.nodeHeight
            )
            return backdrop.frame.intersects(frame) ? placement.id : nil
        }
    }

    static func translate(placements: [MapGraphPlacement], ids: Set<UUID>, dx: Double, dy: Double) -> [MapGraphPlacement] {
        placements.map { placement in
            guard ids.contains(placement.id) else { return placement }
            var next = placement
            next.x += dx
            next.y += dy
            return next
        }
    }

    static func tidy(_ placements: [MapGraphPlacement]) -> [MapGraphPlacement] {
        var buckets: [RoutingNodeKind: [MapGraphPlacement]] = [:]
        for placement in placements {
            buckets[placement.kind, default: []].append(placement)
        }
        var next: [MapGraphPlacement] = []
        for kind in [RoutingNodeKind.inputSource, .processFilter, .passThrough, .placeholder, .masterLayer, .scene, .stickyNote] {
            let column: Double
            switch kind {
            case .inputSource: column = 0
            case .processFilter, .passThrough: column = 0.55
            case .placeholder: column = 1.1
            case .masterLayer, .scene: column = 2.2
            case .stickyNote: column = 1.6
            }
            for (index, var placement) in (buckets[kind] ?? []).enumerated() {
                placement.x = MapGraphMetrics.originX + column * MapGraphMetrics.columnGap
                placement.y = MapGraphMetrics.originY + Double(index) * MapGraphMetrics.rowGap
                next.append(placement)
            }
        }
        return next
    }

    static func duplicate(_ placements: [MapGraphPlacement], ids: Set<UUID>, offset: Double = 36) -> (items: [MapGraphPlacement], map: [UUID: UUID]) {
        var remap: [UUID: UUID] = [:]
        var copies: [MapGraphPlacement] = []
        for placement in placements where ids.contains(placement.id) {
            var copy = placement
            let newID = UUID()
            remap[placement.id] = newID
            copy.id = newID
            copy.x += offset
            copy.y += offset
            copies.append(copy)
        }
        return (copies, remap)
    }

    static func groupBackdrop(around placements: [MapGraphPlacement], title: String = "Backdrop") -> MapBackdropGroup? {
        guard let first = placements.first else { return nil }
        var frame = CGRect(x: first.x, y: first.y, width: MapGraphMetrics.nodeWidth, height: MapGraphMetrics.nodeHeight)
        for placement in placements.dropFirst() {
            frame = frame.union(
                CGRect(x: placement.x, y: placement.y, width: MapGraphMetrics.nodeWidth, height: MapGraphMetrics.nodeHeight)
            )
        }
        frame = frame.insetBy(dx: -28, dy: -36)
        return MapBackdropGroup(
            title: title,
            x: frame.minX,
            y: frame.minY,
            width: frame.width,
            height: frame.height,
            childIDs: placements.map(\.id)
        )
    }
}
