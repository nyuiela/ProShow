import Foundation
import CoreGraphics

public struct CableConnection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var startPortId: UUID
    public var endPortId: UUID
    public var isLive: Bool
    public var isPreview: Bool
    public var isFailoverActive: Bool

    public init(
        id: UUID = UUID(),
        startPortId: UUID,
        endPortId: UUID,
        isLive: Bool = false,
        isPreview: Bool = false,
        isFailoverActive: Bool = false
    ) {
        self.id = id
        self.startPortId = startPortId
        self.endPortId = endPortId
        self.isLive = isLive
        self.isPreview = isPreview
        self.isFailoverActive = isFailoverActive
    }
}

public enum RoutingNodeKind: String, Codable, Sendable {
    case inputSource
    case placeholder
    case masterLayer
    case scene
    case processFilter
    case passThrough
    case stickyNote
}

public struct RoutingPort: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var isOutput: Bool
    public var isConnected: Bool

    public init(id: UUID, isOutput: Bool, isConnected: Bool = false) {
        self.id = id
        self.isOutput = isOutput
        self.isConnected = isConnected
    }
}

public struct RoutingNode: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: RoutingNodeKind
    public var title: String
    public var subtitle: String
    public var detail: String
    public var hardwareSourceId: String?
    public var placeholderID: String?
    public var targetLayerIndex: Int?
    public var sceneID: UUID?
    public var isLive: Bool
    public var isPreview: Bool
    public var isFailoverActive: Bool
    public var inputPorts: [RoutingPort]
    public var outputPorts: [RoutingPort]
    public var symbolName: String
    public var canvasX: Double
    public var canvasY: Double
    public var fillIndex: Int
    public var isUnassigned: Bool
    public var filterID: String?
    public var isBypassed: Bool
    public var isMuted: Bool
    public var isLiveLocked: Bool

    public init(
        id: UUID,
        kind: RoutingNodeKind,
        title: String,
        subtitle: String,
        detail: String = "",
        hardwareSourceId: String? = nil,
        placeholderID: String? = nil,
        targetLayerIndex: Int? = nil,
        sceneID: UUID? = nil,
        isLive: Bool = false,
        isPreview: Bool = false,
        isFailoverActive: Bool = false,
        inputPorts: [RoutingPort] = [],
        outputPorts: [RoutingPort] = [],
        symbolName: String,
        canvasX: Double = 0,
        canvasY: Double = 0,
        fillIndex: Int = 0,
        isUnassigned: Bool = false,
        filterID: String? = nil,
        isBypassed: Bool = false,
        isMuted: Bool = false,
        isLiveLocked: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.hardwareSourceId = hardwareSourceId
        self.placeholderID = placeholderID
        self.targetLayerIndex = targetLayerIndex
        self.sceneID = sceneID
        self.isLive = isLive
        self.isPreview = isPreview
        self.isFailoverActive = isFailoverActive
        self.inputPorts = inputPorts
        self.outputPorts = outputPorts
        self.symbolName = symbolName
        self.canvasX = canvasX
        self.canvasY = canvasY
        self.fillIndex = fillIndex
        self.isUnassigned = isUnassigned
        self.filterID = filterID
        self.isBypassed = isBypassed
        self.isMuted = isMuted
        self.isLiveLocked = isLiveLocked
    }

    public var allPorts: [RoutingPort] { inputPorts + outputPorts }
}

public enum NodeRoutingAction: Equatable, Sendable {
    case mapSource(sourceId: String, placeholderID: String)
    case mapLayer(placeholderID: String, layerIndex: Int)
    case mapScene(placeholderID: String, sceneID: UUID)
    case unmapSource(placeholderID: String)
    case unmapLayer(placeholderID: String)
}

public struct NodeRoutingSnapshot: Equatable, Sendable {
    public var inputNodes: [RoutingNode]
    public var placeholderNodes: [RoutingNode]
    public var outputNodes: [RoutingNode]
    public var utilityNodes: [RoutingNode]
    public var connections: [CableConnection]

    public var allNodes: [RoutingNode] { inputNodes + placeholderNodes + outputNodes + utilityNodes }

    public init(
        inputNodes: [RoutingNode] = [],
        placeholderNodes: [RoutingNode] = [],
        outputNodes: [RoutingNode] = [],
        utilityNodes: [RoutingNode] = [],
        connections: [CableConnection] = []
    ) {
        self.inputNodes = inputNodes
        self.placeholderNodes = placeholderNodes
        self.outputNodes = outputNodes
        self.utilityNodes = utilityNodes
        self.connections = connections
    }
}

public enum RoutingIdentity {
    public static let snapRadius: CGFloat = 24

    public static func uuid(_ seed: String) -> UUID {
        var hash = [UInt8](repeating: 0, count: 16)
        var h0: UInt64 = 0xcbf29ce484222325
        var h1: UInt64 = 0x84222325cbf29ce4
        for byte in seed.utf8 {
            h0 ^= UInt64(byte)
            h0 &*= 0x100000001b3
            h1 ^= UInt64(byte) &+ 17
            h1 &*= 0x100000001b3
        }
        withUnsafeBytes(of: h0.bigEndian) { hash.replaceSubrange(0..<8, with: $0) }
        withUnsafeBytes(of: h1.bigEndian) { hash.replaceSubrange(8..<16, with: $0) }
        hash[6] = (hash[6] & 0x0F) | 0x40
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }

    public static func port(_ role: String, _ key: String) -> UUID {
        uuid("port:\(role):\(key)")
    }

    public static func node(_ role: String, _ key: String) -> UUID {
        uuid("node:\(role):\(key)")
    }

    public static func cable(_ start: UUID, _ end: UUID) -> UUID {
        uuid("cable:\(start.uuidString):\(end.uuidString)")
    }
}

public struct MapGraphPlacement: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: RoutingNodeKind
    public var x: Double
    public var y: Double
    public var assignedSourceId: String?
    public var assignedPlaceholderID: String?
    public var assignedLayerIndex: Int?
    public var assignedSceneID: UUID?
    public var fillIndex: Int
    public var title: String?
    public var filterID: String?
    public var isBypassed: Bool
    public var isMuted: Bool
    public var isLiveLocked: Bool
    public var note: String?
    public var colorHex: String?

    public init(
        id: UUID = UUID(),
        kind: RoutingNodeKind,
        x: Double,
        y: Double,
        assignedSourceId: String? = nil,
        assignedPlaceholderID: String? = nil,
        assignedLayerIndex: Int? = nil,
        assignedSceneID: UUID? = nil,
        fillIndex: Int = 0,
        title: String? = nil,
        filterID: String? = nil,
        isBypassed: Bool = false,
        isMuted: Bool = false,
        isLiveLocked: Bool = false,
        note: String? = nil,
        colorHex: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.assignedSourceId = assignedSourceId
        self.assignedPlaceholderID = assignedPlaceholderID
        self.assignedLayerIndex = assignedLayerIndex
        self.assignedSceneID = assignedSceneID
        self.fillIndex = fillIndex
        self.title = title
        self.filterID = filterID
        self.isBypassed = isBypassed
        self.isMuted = isMuted
        self.isLiveLocked = isLiveLocked
        self.note = note
        self.colorHex = colorHex
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, x, y, assignedSourceId, assignedPlaceholderID, assignedLayerIndex, assignedSceneID, fillIndex
        case title, filterID, isBypassed, isMuted, isLiveLocked, note, colorHex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(RoutingNodeKind.self, forKey: .kind)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        assignedSourceId = try container.decodeIfPresent(String.self, forKey: .assignedSourceId)
        assignedPlaceholderID = try container.decodeIfPresent(String.self, forKey: .assignedPlaceholderID)
        assignedLayerIndex = try container.decodeIfPresent(Int.self, forKey: .assignedLayerIndex)
        assignedSceneID = try container.decodeIfPresent(UUID.self, forKey: .assignedSceneID)
        fillIndex = try container.decodeIfPresent(Int.self, forKey: .fillIndex) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title)
        filterID = try container.decodeIfPresent(String.self, forKey: .filterID)
        isBypassed = try container.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isLiveLocked = try container.decodeIfPresent(Bool.self, forKey: .isLiveLocked) ?? false
        note = try container.decodeIfPresent(String.self, forKey: .note)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex)
    }
}

public struct MapGraphLink: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var fromPlacementID: UUID
    public var toPlacementID: UUID
    public var pins: [MapReroutePin]

    public init(id: UUID = UUID(), fromPlacementID: UUID, toPlacementID: UUID, pins: [MapReroutePin] = []) {
        self.id = id
        self.fromPlacementID = fromPlacementID
        self.toPlacementID = toPlacementID
        self.pins = pins
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        fromPlacementID = try container.decode(UUID.self, forKey: .fromPlacementID)
        toPlacementID = try container.decode(UUID.self, forKey: .toPlacementID)
        pins = try container.decodeIfPresent([MapReroutePin].self, forKey: .pins) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, fromPlacementID, toPlacementID, pins
    }
}

public struct MapReroutePin: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

public struct MapBackdropGroup: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var colorHex: String
    public var isCollapsed: Bool
    public var childIDs: [UUID]

    public init(
        id: UUID = UUID(),
        title: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        colorHex: String = "#5B3A8C",
        isCollapsed: Bool = false,
        childIDs: [UUID] = []
    ) {
        self.id = id
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.colorHex = colorHex
        self.isCollapsed = isCollapsed
        self.childIDs = childIDs
    }

    public var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public enum NodeFilterCatalog: String, CaseIterable, Sendable {
    case chroma
    case crop
    case lut
    case shader
    case audioDelay

    public var title: String {
        switch self {
        case .chroma: "Chroma Key"
        case .crop: "Crop & Transform"
        case .lut: "Color Grade / LUT"
        case .shader: "Metal Shader"
        case .audioDelay: "Audio Delay"
        }
    }

    public var subtitle: String {
        switch self {
        case .chroma: "Green screen key + spill suppression"
        case .crop: "Aspect, corner pin, rotation"
        case .lut: "Cube LUT, gamma, exposure"
        case .shader: "Whip pan, glitch, blur"
        case .audioDelay: "Channel remap and DSP delay"
        }
    }

    public var symbolName: String {
        switch self {
        case .chroma: "person.crop.rectangle"
        case .crop: "crop"
        case .lut: "circle.lefthalf.filled"
        case .shader: "sparkles"
        case .audioDelay: "waveform"
        }
    }
}

enum MapGraphMetrics {
    static let nodeWidth: Double = 228
    static let nodeHeight: Double = 136
    static let columnGap: Double = 300
    static let rowGap: Double = 160
    static let originX: Double = 48
    static let originY: Double = 48
}

enum MapGraphLayout {
    static func seed(
        sources: [PlaceholderSourceChoice],
        placeholders: [PlaceholderConfiguration],
        layers: [MasterLayer],
        scenes: [ProShowScene]
    ) -> [MapGraphPlacement] {
        var items: [MapGraphPlacement] = []
        let mappedIDs = Set(placeholders.compactMap(\.primarySourceId))
        var sourceList = sources.filter { mappedIDs.contains($0.id) }
        for extra in sources where !mappedIDs.contains(extra.id) && sourceList.count < 4 {
            sourceList.append(extra)
        }
        if sourceList.isEmpty {
            items.append(
                MapGraphPlacement(
                    id: RoutingIdentity.node("place-input", "blank"),
                    kind: .inputSource,
                    x: MapGraphMetrics.originX,
                    y: MapGraphMetrics.originY,
                    fillIndex: 0
                )
            )
        } else {
            for (index, source) in sourceList.enumerated() {
                items.append(
                    MapGraphPlacement(
                        id: RoutingIdentity.node("place-input", source.id),
                        kind: .inputSource,
                        x: MapGraphMetrics.originX,
                        y: MapGraphMetrics.originY + Double(index) * MapGraphMetrics.rowGap,
                        assignedSourceId: source.id,
                        fillIndex: index
                    )
                )
            }
        }
        for (index, placeholder) in placeholders.enumerated() {
            items.append(
                MapGraphPlacement(
                    id: RoutingIdentity.node("place-ph", placeholder.id),
                    kind: .placeholder,
                    x: MapGraphMetrics.originX + MapGraphMetrics.columnGap,
                    y: MapGraphMetrics.originY + Double(index) * MapGraphMetrics.rowGap,
                    assignedPlaceholderID: placeholder.id,
                    fillIndex: index + 1
                )
            )
        }
        for (index, layer) in layers.enumerated() {
            items.append(
                MapGraphPlacement(
                    id: RoutingIdentity.node("place-layer", "\(layer.index)"),
                    kind: .masterLayer,
                    x: MapGraphMetrics.originX + MapGraphMetrics.columnGap * 2,
                    y: MapGraphMetrics.originY + Double(index) * MapGraphMetrics.rowGap,
                    assignedLayerIndex: layer.index,
                    fillIndex: index + 2
                )
            )
        }
        for (index, scene) in scenes.prefix(3).enumerated() {
            items.append(
                MapGraphPlacement(
                    id: RoutingIdentity.node("place-scene", scene.id.uuidString),
                    kind: .scene,
                    x: MapGraphMetrics.originX + MapGraphMetrics.columnGap * 2,
                    y: MapGraphMetrics.originY + Double(layers.count + index) * MapGraphMetrics.rowGap,
                    assignedSceneID: scene.id,
                    fillIndex: index + 4
                )
            )
        }
        return items
    }

    static func implicitPlacements(
        sources: [PlaceholderSourceChoice],
        placeholders: [PlaceholderConfiguration],
        layers: [MasterLayer],
        scenes: [ProShowScene]
    ) -> [MapGraphPlacement] {
        seed(sources: sources, placeholders: placeholders, layers: layers, scenes: scenes)
    }

    static func nextPoint(kind: RoutingNodeKind, existing: [MapGraphPlacement]) -> (Double, Double, Int) {
        let column: Double
        switch kind {
        case .inputSource: column = 0
        case .processFilter, .passThrough: column = 0.5
        case .placeholder: column = 1
        case .masterLayer, .scene: column = 2
        case .stickyNote: column = 1.4
        }
        let peers = existing.filter { placement in
            switch kind {
            case .inputSource: placement.kind == .inputSource
            case .processFilter, .passThrough: placement.kind == .processFilter || placement.kind == .passThrough
            case .placeholder: placement.kind == .placeholder
            case .masterLayer, .scene: placement.kind == .masterLayer || placement.kind == .scene
            case .stickyNote: placement.kind == .stickyNote
            }
        }
        return (
            MapGraphMetrics.originX + column * MapGraphMetrics.columnGap,
            MapGraphMetrics.originY + Double(peers.count) * MapGraphMetrics.rowGap,
            existing.count
        )
    }
}

enum NodeRoutingGraph {
    static func findSnapTargetPort(
        near location: CGPoint,
        portPositions: [UUID: CGPoint],
        excluding: UUID? = nil,
        allowed: Set<UUID>? = nil
    ) -> UUID? {
        var best: (UUID, CGFloat)?
        for (id, point) in portPositions {
            if id == excluding { continue }
            if let allowed, !allowed.contains(id) { continue }
            let distance = hypot(point.x - location.x, point.y - location.y)
            guard distance <= RoutingIdentity.snapRadius else { continue }
            if best == nil || distance < best!.1 {
                best = (id, distance)
            }
        }
        return best?.0
    }

    static func node(containing portId: UUID, in nodes: [RoutingNode]) -> RoutingNode? {
        nodes.first { node in node.allPorts.contains(where: { $0.id == portId }) }
    }

    static func port(_ portId: UUID, in nodes: [RoutingNode]) -> RoutingPort? {
        nodes.lazy.compactMap { node in node.allPorts.first(where: { $0.id == portId }) }.first
    }

    static func validateAndCreateConnection(fromPort: UUID, toPort: UUID, nodes: [RoutingNode]) -> CableConnection? {
        guard fromPort != toPort,
              let source = node(containing: fromPort, in: nodes),
              let target = node(containing: toPort, in: nodes),
              source.id != target.id,
              let startPort = port(fromPort, in: nodes),
              let endPort = port(toPort, in: nodes)
        else { return nil }

        let ordered: (RoutingNode, RoutingPort, RoutingNode, RoutingPort)?
        if startPort.isOutput && !endPort.isOutput {
            ordered = (source, startPort, target, endPort)
        } else if !startPort.isOutput && endPort.isOutput {
            ordered = (target, endPort, source, startPort)
        } else {
            return nil
        }

        guard let (fromNode, from, toNode, to) = ordered, isLegalHop(from: fromNode, to: toNode) else {
            return nil
        }
        return CableConnection(
            id: RoutingIdentity.cable(from.id, to.id),
            startPortId: from.id,
            endPortId: to.id
        )
    }

    static func action(for connection: CableConnection, nodes: [RoutingNode]) -> NodeRoutingAction? {
        guard let source = node(containing: connection.startPortId, in: nodes),
              let target = node(containing: connection.endPortId, in: nodes)
        else { return nil }
        if source.kind == .inputSource, target.kind == .placeholder, let sourceId = source.hardwareSourceId, let placeholderID = target.placeholderID {
            return .mapSource(sourceId: sourceId, placeholderID: placeholderID)
        }
        if source.kind == .placeholder, target.kind == .masterLayer, let placeholderID = source.placeholderID, let layerIndex = target.targetLayerIndex {
            return .mapLayer(placeholderID: placeholderID, layerIndex: layerIndex)
        }
        if source.kind == .placeholder, target.kind == .scene, let placeholderID = source.placeholderID, let sceneID = target.sceneID {
            return .mapScene(placeholderID: placeholderID, sceneID: sceneID)
        }
        return nil
    }

    static func action(for link: MapGraphLink, nodes: [RoutingNode]) -> NodeRoutingAction? {
        guard let source = nodes.first(where: { $0.id == link.fromPlacementID }),
              let target = nodes.first(where: { $0.id == link.toPlacementID }),
              let start = source.outputPorts.first,
              let end = target.inputPorts.first,
              let connection = validateAndCreateConnection(fromPort: start.id, toPort: end.id, nodes: nodes)
        else { return nil }
        return action(for: connection, nodes: nodes)
    }

    static func disconnectAction(fromPort startPortId: UUID, nodes: [RoutingNode]) -> NodeRoutingAction? {
        guard let node = node(containing: startPortId, in: nodes),
              let port = port(startPortId, in: nodes),
              port.isConnected,
              let placeholderID = node.placeholderID
        else { return nil }
        if !port.isOutput {
            return .unmapSource(placeholderID: placeholderID)
        }
        if node.kind == .placeholder {
            return .unmapLayer(placeholderID: placeholderID)
        }
        return nil
    }

    static func validTargetPortIDs(from startPortId: UUID, nodes: [RoutingNode]) -> Set<UUID> {
        Set(nodes.flatMap(\.allPorts).compactMap { port in
            validateAndCreateConnection(fromPort: startPortId, toPort: port.id, nodes: nodes) == nil ? nil : port.id
        })
    }

    static func build(
        sources: [PlaceholderSourceChoice],
        videoSources: [StudioVideoSource],
        placeholders: [PlaceholderConfiguration],
        usingFailover: Set<String>,
        layers: [MasterLayer],
        scenes: [ProShowScene],
        placements: [MapGraphPlacement]? = nil,
        links: [MapGraphLink]? = nil
    ) -> NodeRoutingSnapshot {
        let resolvedPlacements = placements ?? MapGraphLayout.implicitPlacements(
            sources: sources,
            placeholders: placeholders,
            layers: layers,
            scenes: scenes
        )
        let videoByID = Dictionary(uniqueKeysWithValues: videoSources.map { ($0.id.uuidString, $0) })
        let placeholderByID = Dictionary(uniqueKeysWithValues: placeholders.map { ($0.id, $0) })
        let inputNodes = resolvedPlacements.filter { $0.kind == .inputSource }.map { placement in
            makeInputNode(placement: placement, sources: sources, video: placement.assignedSourceId.flatMap { videoByID[$0] })
        }
        let placeholderNodes = resolvedPlacements.filter { $0.kind == .placeholder }.map { placement in
            makePlaceholderNode(
                placement: placement,
                placeholder: placement.assignedPlaceholderID.flatMap { placeholderByID[$0] },
                sources: sources,
                usingFailover: usingFailover
            )
        }
        let layerNodes = resolvedPlacements.filter { $0.kind == .masterLayer }.compactMap { placement -> RoutingNode? in
            guard let layer = layers.first(where: { $0.index == placement.assignedLayerIndex }) else {
                return makeUnassignedOutput(placement: placement, title: "Master layer", detail: "Click to assign")
            }
            return makeLayerNode(placement: placement, layer: layer)
        }
        let sceneNodes = resolvedPlacements.filter { $0.kind == .scene }.compactMap { placement -> RoutingNode? in
            guard let scene = scenes.first(where: { $0.id == placement.assignedSceneID }) else {
                return makeUnassignedOutput(placement: placement, title: "Scene", detail: "Click to assign")
            }
            return makeSceneNode(placement: placement, scene: scene)
        }
        let utilityNodes = resolvedPlacements.compactMap { placement -> RoutingNode? in
            switch placement.kind {
            case .processFilter, .passThrough, .stickyNote:
                return makeUtilityNode(placement: placement)
            default:
                return nil
            }
        }
        var connections: [CableConnection] = []

        for placeholder in placeholders {
            let failover = usingFailover.contains(placeholder.id)
            let sourceID = failover ? placeholder.failoverSourceId : placeholder.primarySourceId
            let placeholderNode = placeholderNodes.first(where: { $0.placeholderID == placeholder.id })
            if let sourceID,
               let sourceNode = inputNodes.first(where: { $0.hardwareSourceId == sourceID }),
               let start = sourceNode.outputPorts.first,
               let placeholderNode,
               let end = placeholderNode.inputPorts.first
            {
                connections.append(
                    CableConnection(
                        id: RoutingIdentity.cable(start.id, end.id),
                        startPortId: start.id,
                        endPortId: end.id,
                        isLive: placeholder.state == .activeLive,
                        isPreview: placeholder.state == .activePreview,
                        isFailoverActive: failover
                    )
                )
            }
            if let layerIndex = placeholder.targetMasterLayerIndex,
               let placeholderNode,
               let start = placeholderNode.outputPorts.first,
               let layerNode = layerNodes.first(where: { $0.targetLayerIndex == layerIndex }),
               let end = layerNode.inputPorts.first
            {
                connections.append(
                    CableConnection(
                        id: RoutingIdentity.cable(start.id, end.id),
                        startPortId: start.id,
                        endPortId: end.id,
                        isLive: placeholder.state == .activeLive,
                        isPreview: placeholder.state == .activePreview,
                        isFailoverActive: failover
                    )
                )
            }
            if let sourceID,
               let sourceUUID = UUID(uuidString: sourceID),
               let placeholderNode,
               let start = placeholderNode.outputPorts.first
            {
                for sceneNode in sceneNodes where scenes.first(where: { $0.id == sceneNode.sceneID })?.primarySourceID == sourceUUID {
                    if let end = sceneNode.inputPorts.first {
                        connections.append(
                            CableConnection(
                                id: RoutingIdentity.cable(start.id, end.id),
                                startPortId: start.id,
                                endPortId: end.id,
                                isLive: placeholder.state == .activeLive,
                                isPreview: placeholder.state == .activePreview,
                                isFailoverActive: failover
                            )
                        )
                    }
                }
            }
        }

        if let links {
            let allNodes = inputNodes + placeholderNodes + layerNodes + sceneNodes + utilityNodes
            for extra in cables(from: links, nodes: allNodes, placeholders: placeholders, usingFailover: usingFailover) {
                if !connections.contains(where: { $0.startPortId == extra.startPortId && $0.endPortId == extra.endPortId }) {
                    connections.append(extra)
                }
            }
        }

        return NodeRoutingSnapshot(
            inputNodes: markPorts(inputNodes, connections: connections),
            placeholderNodes: markPorts(placeholderNodes, connections: connections),
            outputNodes: markPorts(layerNodes + sceneNodes, connections: connections),
            utilityNodes: markPorts(utilityNodes, connections: connections),
            connections: connections
        )
    }

    private static func cables(
        from links: [MapGraphLink],
        nodes: [RoutingNode],
        placeholders: [PlaceholderConfiguration],
        usingFailover: Set<String>
    ) -> [CableConnection] {
        links.compactMap { link in
            guard let source = nodes.first(where: { $0.id == link.fromPlacementID }),
                  let target = nodes.first(where: { $0.id == link.toPlacementID }),
                  let startPort = source.outputPorts.first,
                  let endPort = target.inputPorts.first
            else { return nil }
            let placeholder = placeholders.first(where: { $0.id == source.placeholderID || $0.id == target.placeholderID })
            return CableConnection(
                id: RoutingIdentity.cable(startPort.id, endPort.id),
                startPortId: startPort.id,
                endPortId: endPort.id,
                isLive: placeholder?.state == .activeLive,
                isPreview: placeholder?.state == .activePreview,
                isFailoverActive: placeholder.map { usingFailover.contains($0.id) } ?? false
            )
        }
    }

    private static func markPorts(_ nodes: [RoutingNode], connections: [CableConnection]) -> [RoutingNode] {
        let connected = Set(connections.flatMap { [$0.startPortId, $0.endPortId] })
        return nodes.map { node in
            var next = node
            next.inputPorts = node.inputPorts.map { port in
                var copy = port
                copy.isConnected = connected.contains(port.id)
                return copy
            }
            next.outputPorts = node.outputPorts.map { port in
                var copy = port
                copy.isConnected = connected.contains(port.id)
                return copy
            }
            return next
        }
    }

    private static func isPassthrough(_ kind: RoutingNodeKind) -> Bool {
        kind == .processFilter || kind == .passThrough
    }

    static func isLegalHop(from: RoutingNode, to: RoutingNode) -> Bool {
        switch (from.kind, to.kind) {
        case (.inputSource, .placeholder),
             (.inputSource, .processFilter),
             (.inputSource, .passThrough):
            true
        case (.processFilter, .placeholder),
             (.processFilter, .processFilter),
             (.processFilter, .passThrough),
             (.processFilter, .masterLayer),
             (.processFilter, .scene):
            true
        case (.passThrough, .placeholder),
             (.passThrough, .processFilter),
             (.passThrough, .passThrough),
             (.passThrough, .masterLayer),
             (.passThrough, .scene):
            true
        case (.placeholder, .masterLayer),
             (.placeholder, .scene),
             (.placeholder, .processFilter),
             (.placeholder, .passThrough):
            true
        default:
            false
        }
    }

    private static func resolvedSourceName(
        _ placeholder: PlaceholderConfiguration,
        sources: [PlaceholderSourceChoice],
        usingFailover: Set<String>
    ) -> String {
        let sourceID = usingFailover.contains(placeholder.id) ? placeholder.failoverSourceId : placeholder.primarySourceId
        return sources.first(where: { $0.id == sourceID })?.name ?? "Unmapped"
    }

    private static func makeInputNode(
        placement: MapGraphPlacement,
        sources: [PlaceholderSourceChoice],
        video: StudioVideoSource?
    ) -> RoutingNode {
        let choice = sources.first(where: { $0.id == placement.assignedSourceId })
        let kind = video?.kind
        return RoutingNode(
            id: placement.id,
            kind: .inputSource,
            title: choice?.name ?? "Source",
            subtitle: choice == nil ? "Click to assign media" : signalLabel(kind),
            detail: kind?.rawValue ?? (choice == nil ? "Unassigned" : "media"),
            hardwareSourceId: placement.assignedSourceId,
            outputPorts: [RoutingPort(id: RoutingIdentity.port("out", placement.id.uuidString), isOutput: true)],
            symbolName: symbol(kind),
            canvasX: placement.x,
            canvasY: placement.y,
            fillIndex: placement.fillIndex,
            isUnassigned: choice == nil
        )
    }

    private static func makePlaceholderNode(
        placement: MapGraphPlacement,
        placeholder: PlaceholderConfiguration?,
        sources: [PlaceholderSourceChoice],
        usingFailover: Set<String>
    ) -> RoutingNode {
        guard let placeholder else {
            return RoutingNode(
                id: placement.id,
                kind: .placeholder,
                title: "Placeholder",
                subtitle: "Click to assign A–I",
                detail: "Unassigned",
                inputPorts: [RoutingPort(id: RoutingIdentity.port("in", placement.id.uuidString), isOutput: false)],
                outputPorts: [RoutingPort(id: RoutingIdentity.port("out", placement.id.uuidString), isOutput: true)],
                symbolName: "square.grid.2x2",
                canvasX: placement.x,
                canvasY: placement.y,
                fillIndex: placement.fillIndex,
                isUnassigned: true
            )
        }
        let failed = usingFailover.contains(placeholder.id)
        return RoutingNode(
            id: placement.id,
            kind: .placeholder,
            title: "Placeholder \(placeholder.letter)",
            subtitle: resolvedSourceName(placeholder, sources: sources, usingFailover: usingFailover),
            detail: failed ? "Failover" : placeholder.label,
            placeholderID: placeholder.id,
            isLive: placeholder.state == .activeLive,
            isPreview: placeholder.state == .activePreview,
            isFailoverActive: failed,
            inputPorts: [RoutingPort(id: RoutingIdentity.port("in", placement.id.uuidString), isOutput: false)],
            outputPorts: [RoutingPort(id: RoutingIdentity.port("out", placement.id.uuidString), isOutput: true)],
            symbolName: "square.grid.2x2",
            canvasX: placement.x,
            canvasY: placement.y,
            fillIndex: placement.fillIndex
        )
    }

    private static func makeLayerNode(placement: MapGraphPlacement, layer: MasterLayer) -> RoutingNode {
        let live = layer.shots.first(where: { $0.id == layer.liveShotID })
        return RoutingNode(
            id: placement.id,
            kind: .masterLayer,
            title: layer.title,
            subtitle: live?.name ?? "No live shot",
            detail: "Master Layer \(layer.index)",
            targetLayerIndex: layer.index,
            isLive: layer.liveShotID != nil,
            inputPorts: [RoutingPort(id: RoutingIdentity.port("in", placement.id.uuidString), isOutput: false)],
            symbolName: "film",
            canvasX: placement.x,
            canvasY: placement.y,
            fillIndex: placement.fillIndex
        )
    }

    private static func makeSceneNode(placement: MapGraphPlacement, scene: ProShowScene) -> RoutingNode {
        RoutingNode(
            id: placement.id,
            kind: .scene,
            title: scene.name,
            subtitle: scene.layout.rawValue,
            detail: scene.hotKey.isEmpty ? "Scene" : "Hotkey \(scene.hotKey)",
            sceneID: scene.id,
            inputPorts: [RoutingPort(id: RoutingIdentity.port("in", placement.id.uuidString), isOutput: false)],
            symbolName: "theatermasks",
            canvasX: placement.x,
            canvasY: placement.y,
            fillIndex: placement.fillIndex
        )
    }

    private static func makeUtilityNode(placement: MapGraphPlacement) -> RoutingNode {
        let filter = placement.filterID.flatMap(NodeFilterCatalog.init(rawValue:))
        let title: String
        let subtitle: String
        let symbol: String
        switch placement.kind {
        case .passThrough:
            title = placement.title ?? "Reroute"
            subtitle = "Pin"
            symbol = "circle.fill"
        case .stickyNote:
            title = placement.title ?? "Note"
            subtitle = placement.note ?? "Operator note"
            symbol = "note.text"
        default:
            title = placement.title ?? filter?.title ?? "Filter"
            subtitle = placement.isBypassed ? "Bypassed" : (filter?.subtitle ?? "GPU")
            symbol = filter?.symbolName ?? "slider.horizontal.3"
        }
        return RoutingNode(
            id: placement.id,
            kind: placement.kind,
            title: title,
            subtitle: subtitle,
            detail: placement.isMuted ? "Muted" : (filter?.rawValue ?? placement.kind.rawValue),
            inputPorts: placement.kind == .stickyNote ? [] : [RoutingPort(id: RoutingIdentity.port("in", placement.id.uuidString), isOutput: false)],
            outputPorts: placement.kind == .stickyNote ? [] : [RoutingPort(id: RoutingIdentity.port("out", placement.id.uuidString), isOutput: true)],
            symbolName: symbol,
            canvasX: placement.x,
            canvasY: placement.y,
            fillIndex: placement.fillIndex,
            filterID: placement.filterID,
            isBypassed: placement.isBypassed,
            isMuted: placement.isMuted,
            isLiveLocked: placement.isLiveLocked
        )
    }

    private static func makeUnassignedOutput(placement: MapGraphPlacement, title: String, detail: String) -> RoutingNode {
        RoutingNode(
            id: placement.id,
            kind: placement.kind,
            title: title,
            subtitle: "Click to assign",
            detail: detail,
            targetLayerIndex: placement.assignedLayerIndex,
            sceneID: placement.assignedSceneID,
            inputPorts: [RoutingPort(id: RoutingIdentity.port("in", placement.id.uuidString), isOutput: false)],
            symbolName: placement.kind == .scene ? "theatermasks" : "film",
            canvasX: placement.x,
            canvasY: placement.y,
            fillIndex: placement.fillIndex,
            isUnassigned: true
        )
    }

    private static func signalLabel(_ kind: StudioVideoKind?) -> String {
        switch kind {
        case .camera, .continuity, .captureCard: "Signal: 4K60"
        case .screenShare: "Signal: 1080p60"
        case .ndi, .webrtc, .rtsp: "Signal: 1080p30"
        case .none: "Signal: File"
        }
    }

    private static func symbol(_ kind: StudioVideoKind?) -> String {
        switch kind {
        case .camera, .continuity: "video.fill"
        case .captureCard: "cable.connector"
        case .screenShare: "display"
        case .ndi, .webrtc, .rtsp: "dot.radiowaves.left.and.right"
        case .none: "photo"
        }
    }
}
