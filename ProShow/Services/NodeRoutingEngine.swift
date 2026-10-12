import Foundation
import CoreGraphics
import Observation

@Observable
final class NodeRoutingEngine {
    var inputNodes: [RoutingNode] = []
    var placeholderNodes: [RoutingNode] = []
    var outputNodes: [RoutingNode] = []
    var utilityNodes: [RoutingNode] = []
    var connections: [CableConnection] = []

    var snapshot: NodeRoutingSnapshot {
        NodeRoutingSnapshot(
            inputNodes: inputNodes,
            placeholderNodes: placeholderNodes,
            outputNodes: outputNodes,
            utilityNodes: utilityNodes,
            connections: connections
        )
    }

    var allNodes: [RoutingNode] { snapshot.allNodes }

    init() {}

    func rebuild(
        sources: [PlaceholderSourceChoice],
        videoSources: [StudioVideoSource],
        placeholders: [PlaceholderConfiguration],
        usingFailover: Set<String>,
        layers: [MasterLayer],
        scenes: [ProShowScene],
        placements: [MapGraphPlacement]? = nil,
        links: [MapGraphLink]? = nil
    ) {
        let next = NodeRoutingGraph.build(
            sources: sources,
            videoSources: videoSources,
            placeholders: placeholders,
            usingFailover: usingFailover,
            layers: layers,
            scenes: scenes,
            placements: placements,
            links: links
        )
        inputNodes = next.inputNodes
        placeholderNodes = next.placeholderNodes
        outputNodes = next.outputNodes
        utilityNodes = next.utilityNodes
        connections = next.connections
    }

    func findNodeContaining(portId: UUID) -> RoutingNode? {
        NodeRoutingGraph.node(containing: portId, in: allNodes)
    }

    func findSnapTargetPort(
        near location: CGPoint,
        portPositions: [UUID: CGPoint],
        excluding: UUID? = nil
    ) -> UUID? {
        let allowed = excluding.map { NodeRoutingGraph.validTargetPortIDs(from: $0, nodes: allNodes) }
        return NodeRoutingGraph.findSnapTargetPort(
            near: location,
            portPositions: portPositions,
            excluding: excluding,
            allowed: allowed
        )
    }

    func attemptCableConnection(
        from startPortId: UUID,
        toLocation location: CGPoint,
        portPositions: [UUID: CGPoint]
    ) -> NodeRoutingAction? {
        if let targetPortId = findSnapTargetPort(near: location, portPositions: portPositions, excluding: startPortId),
           let connection = NodeRoutingGraph.validateAndCreateConnection(fromPort: startPortId, toPort: targetPortId, nodes: allNodes),
           let action = NodeRoutingGraph.action(for: connection, nodes: allNodes)
        {
            return action
        }
        return NodeRoutingGraph.disconnectAction(fromPort: startPortId, nodes: allNodes)
    }
}
