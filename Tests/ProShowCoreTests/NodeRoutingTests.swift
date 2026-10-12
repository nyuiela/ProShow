#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreGraphics
import Foundation
import Testing

@Suite
struct NodeRoutingTests {
    @Test
    func snap_selectsPortWithin24pt() {
        let target = UUID()
        let other = UUID()
        let hit = NodeRoutingGraph.findSnapTargetPort(
            near: CGPoint(x: 108, y: 102),
            portPositions: [
                target: CGPoint(x: 100, y: 100),
                other: CGPoint(x: 180, y: 100)
            ]
        )
        #expect(hit == target)
    }

    @Test
    func snap_ignoresPortsOutsideRadius() {
        let target = UUID()
        let hit = NodeRoutingGraph.findSnapTargetPort(
            near: CGPoint(x: 160, y: 100),
            portPositions: [target: CGPoint(x: 100, y: 100)]
        )
        #expect(hit == nil)
    }

    @Test
    func validate_inputOutputToPlaceholderInput() {
        let snapshot = sampleSnapshot()
        let sourceOut = snapshot.inputNodes[0].outputPorts[0].id
        let placeholderIn = snapshot.placeholderNodes[0].inputPorts[0].id
        let connection = NodeRoutingGraph.validateAndCreateConnection(
            fromPort: sourceOut,
            toPort: placeholderIn,
            nodes: snapshot.allNodes
        )
        #expect(connection != nil)
        #expect(NodeRoutingGraph.action(for: connection!, nodes: snapshot.allNodes) == .mapSource(sourceId: "cam-1", placeholderID: "Placeholder A"))
    }

    @Test
    func validate_placeholderToMasterLayer() {
        let snapshot = sampleSnapshot()
        let placeholderOut = snapshot.placeholderNodes[0].outputPorts[0].id
        let layerIn = snapshot.outputNodes[0].inputPorts[0].id
        let connection = NodeRoutingGraph.validateAndCreateConnection(
            fromPort: placeholderOut,
            toPort: layerIn,
            nodes: snapshot.allNodes
        )
        #expect(connection != nil)
        #expect(NodeRoutingGraph.action(for: connection!, nodes: snapshot.allNodes) == .mapLayer(placeholderID: "Placeholder A", layerIndex: 3))
    }

    @Test
    func validate_rejectsInputDirectlyToLayer() {
        let snapshot = sampleSnapshot()
        let sourceOut = snapshot.inputNodes[0].outputPorts[0].id
        let layerIn = snapshot.outputNodes[0].inputPorts[0].id
        #expect(NodeRoutingGraph.validateAndCreateConnection(fromPort: sourceOut, toPort: layerIn, nodes: snapshot.allNodes) == nil)
    }

    @Test
    func rebuild_emitsLiveAndStandbyCables() {
        var placeholders = PlaceholderConfiguration.catalog()
        placeholders[0].primarySourceId = "cam-1"
        placeholders[0].state = .activeLive
        placeholders[1].primarySourceId = "cam-1"
        placeholders[1].state = .inactiveStandby
        let snapshot = NodeRoutingGraph.build(
            sources: [PlaceholderSourceChoice(id: "cam-1", name: "Sony FX3")],
            videoSources: [StudioVideoSource(id: UUID(), label: "Sony FX3", kind: .camera)],
            placeholders: placeholders,
            usingFailover: [],
            layers: [MasterLayer(index: 3, title: "Main Layer 3")],
            scenes: []
        )
        #expect(snapshot.connections.contains(where: { $0.isLive }))
        #expect(snapshot.connections.contains(where: { !$0.isLive && !$0.isPreview }))
        #expect(snapshot.inputNodes.count == 1)
        #expect(snapshot.placeholderNodes.count == 9)
    }

    @Test
    func rebuild_failoverCableIsAmber() {
        var placeholders = PlaceholderConfiguration.catalog()
        placeholders[0].primarySourceId = "cam-1"
        placeholders[0].failoverSourceId = "cam-2"
        placeholders[0].state = .activeLive
        let snapshot = NodeRoutingGraph.build(
            sources: [
                PlaceholderSourceChoice(id: "cam-1", name: "Sony FX3"),
                PlaceholderSourceChoice(id: "cam-2", name: "Backup")
            ],
            videoSources: [],
            placeholders: placeholders,
            usingFailover: ["Placeholder A"],
            layers: [],
            scenes: []
        )
        let cable = snapshot.connections.first { $0.isFailoverActive }
        #expect(cable != nil)
        let backupOut = snapshot.inputNodes.first { $0.hardwareSourceId == "cam-2" }?.outputPorts.first?.id
        #expect(cable?.startPortId == backupOut)
    }

    @Test
    func engine_snapAndDisconnect() {
        let engine = NodeRoutingEngine()
        var placeholders = PlaceholderConfiguration.catalog()
        placeholders[0].primarySourceId = "cam-1"
        engine.rebuild(
            sources: [PlaceholderSourceChoice(id: "cam-1", name: "Sony FX3")],
            videoSources: [],
            placeholders: placeholders,
            usingFailover: [],
            layers: [MasterLayer(index: 3, title: "Main Layer 3")],
            scenes: []
        )
        let placeholderIn = engine.placeholderNodes[0].inputPorts[0].id
        let sourceOut = engine.inputNodes[0].outputPorts[0].id
        let positions = [
            placeholderIn: CGPoint(x: 200, y: 80),
            sourceOut: CGPoint(x: 20, y: 80)
        ]
        let mapped = engine.attemptCableConnection(
            from: sourceOut,
            toLocation: CGPoint(x: 210, y: 85),
            portPositions: positions
        )
        #expect(mapped == .mapSource(sourceId: "cam-1", placeholderID: "Placeholder A"))

        let missed = engine.attemptCableConnection(
            from: placeholderIn,
            toLocation: CGPoint(x: 400, y: 400),
            portPositions: positions
        )
        #expect(missed == .unmapSource(placeholderID: "Placeholder A"))
    }

    @Test
    func catalog_includesPlaceholderI() {
        #expect(PlaceholderConfiguration.catalog().contains(where: { $0.letter == "I" }))
        #expect(PlaceholderLetter.allCases.contains(.I))
        #expect(PlaceholderLetter.A.tintIndex == 0)
        #expect(PlaceholderLetter.I.tintIndex == 8)
        #expect(StartHome.rowTint(-7) == StartHome.rowTint(5))
    }

    @Test
    func addGraphNode_startsUnassigned() {
        let engine = PlaceholderMatrixEngine()
        #expect(engine.graphPlacements.isEmpty)
        let source = engine.addGraphNode(kind: .inputSource)
        let placeholder = engine.addGraphNode(kind: .placeholder)
        #expect(source.assignedSourceId == nil)
        #expect(placeholder.assignedPlaceholderID == nil)
        #expect(engine.graphPlacements.count == 2)
    }

    @Test
    func persist_linkWithoutAssignments() {
        let engine = PlaceholderMatrixEngine()
        let source = engine.addGraphNode(kind: .inputSource)
        let placeholder = engine.addGraphNode(kind: .placeholder)
        engine.upsertGraphLink(from: source.id, to: placeholder.id)
        let snapshot = NodeRoutingGraph.build(
            sources: [],
            videoSources: [],
            placeholders: engine.placeholders,
            usingFailover: [],
            layers: [],
            scenes: [],
            placements: engine.graphPlacements,
            links: engine.graphLinks
        )
        #expect(engine.graphLinks.count == 1)
        #expect(snapshot.connections.count == 1)
        #expect(snapshot.connections[0].startPortId == snapshot.inputNodes[0].outputPorts[0].id)
        #expect(snapshot.connections[0].endPortId == snapshot.placeholderNodes[0].inputPorts[0].id)
    }

    @Test
    func persist_linkRoundTripsStudioManifest() throws {
        let engine = PlaceholderMatrixEngine()
        let source = engine.addGraphNode(kind: .inputSource)
        let placeholder = engine.addGraphNode(kind: .placeholder)
        engine.upsertGraphLink(from: source.id, to: placeholder.id)
        let manifest = StudioManifest(
            scenes: [],
            soundboard: [],
            videoSources: [],
            audioChannels: [],
            activeSceneID: nil,
            mapGraph: engine.graphPlacements,
            mapLinks: engine.graphLinks
        )
        let decoded = try JSONDecoder().decode(StudioManifest.self, from: try JSONEncoder().encode(manifest))
        #expect(decoded.mapLinks.count == 1)
        #expect(decoded.mapLinks[0].fromPlacementID == source.id)
        #expect(decoded.mapLinks[0].toPlacementID == placeholder.id)
        let restored = PlaceholderMatrixEngine()
        restored.installGraph(decoded.mapGraph, links: decoded.mapLinks)
        #expect(restored.graphLinks.count == 1)
        #expect(restored.graphLinks[0].fromPlacementID == source.id)
    }

    @Test @MainActor
    func controller_appliesCableToBinding() {
        let controller = TestSupport.sampleController()
        guard let camera = controller.videoInputs.sources.first else {
            #expect(Bool(false))
            return
        }
        controller.applyNodeRouting(.mapSource(sourceId: camera.id.uuidString, placeholderID: "Placeholder A"))
        controller.applyNodeRouting(.mapLayer(placeholderID: "Placeholder A", layerIndex: 3))
        #expect(controller.placeholderMatrix.placeholders.first(where: { $0.id == "Placeholder A" })?.primarySourceId == camera.id.uuidString)
        #expect(controller.placeholderMatrix.placeholders.first(where: { $0.id == "Placeholder A" })?.targetMasterLayerIndex == 3)
        #expect(controller.placeholderBindings["A"]?.targetID == camera.id.uuidString)
    }

    private func sampleSnapshot() -> NodeRoutingSnapshot {
        NodeRoutingGraph.build(
            sources: [PlaceholderSourceChoice(id: "cam-1", name: "Sony FX3")],
            videoSources: [],
            placeholders: PlaceholderConfiguration.catalog(),
            usingFailover: [],
            layers: [MasterLayer(index: 3, title: "Main Layer 3")],
            scenes: []
        )
    }
}
