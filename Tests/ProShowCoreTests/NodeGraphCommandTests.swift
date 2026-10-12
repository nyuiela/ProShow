#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreGraphics
import Foundation
import Testing

@Suite
struct NodeGraphCommandTests {
    @Test
    func hotkeys_resolveMapMatrix() {
        #expect(NodeGraphHotkey.resolve(Self.key(" ", shift: true)) == .palette)
        #expect(NodeGraphHotkey.resolve(Self.command("k")) == .palette)
        #expect(NodeGraphHotkey.resolve(Self.command("a")) == .selectAll)
        #expect(NodeGraphHotkey.resolve(Self.command("d")) == .duplicate)
        #expect(NodeGraphHotkey.resolve(Self.key("z")) == .zoomFit)
        #expect(NodeGraphHotkey.resolve(Self.command("0")) == .zoomOne)
        #expect(NodeGraphHotkey.resolve(Self.key("n")) == .toggleMinimap)
        #expect(NodeGraphHotkey.resolve(Self.key("d")) == .bypass)
        #expect(NodeGraphHotkey.resolve(Self.key("m")) == .mute)
        #expect(NodeGraphHotkey.resolve(Self.key("l")) == .liveLock)
        #expect(NodeGraphHotkey.resolve(Self.command("g")) == .group)
        #expect(NodeGraphHotkey.resolve(Self.command("g", shift: true)) == .ungroup)
        #expect(NodeGraphHotkey.resolve(Self.command("l", option: true)) == .tidy)
        #expect(
            NodeGraphHotkey.resolve(
                ShortcutInput(characters: "", keyCode: KeyboardShortcutResolver.escape, command: false, shift: false, option: false, control: false, isARepeat: false)
            ) == .deselect
        )
        #expect(
            NodeGraphHotkey.resolve(
                ShortcutInput(characters: "", keyCode: NodeGraphHotkey.f2, command: false, shift: false, option: false, control: false, isARepeat: false)
            ) == .rename
        )
    }

    @Test
    func palette_filtersFuzzyTitles() {
        let items = NodeCommandCatalog.items(sources: [PlaceholderSourceChoice(id: "cam", name: "Sony FX3")], layers: [], scenes: [])
        let chroma = NodeCommandCatalog.filter(items, query: "chroma")
        #expect(chroma.contains(where: { $0.title.contains("Chroma") }))
        let notes = NodeCommandCatalog.filter(items, query: "sticky")
        #expect(notes.contains(where: { $0.kind == .stickyNote }))
    }

    @Test
    func laser_cutsIntersectingBezier() {
        let start = UUID()
        let end = UUID()
        let connection = CableConnection(startPortId: start, endPortId: end, isLive: true)
        let cut = NodeGraphGeometry.laserCuts(
            from: CGPoint(x: 120, y: 0),
            to: CGPoint(x: 160, y: 80),
            connections: [connection],
            portPositions: [start: CGPoint(x: 40, y: 40), end: CGPoint(x: 240, y: 40)]
        )
        #expect(cut == [connection.id])
        let miss = NodeGraphGeometry.laserCuts(
            from: CGPoint(x: 140, y: 200),
            to: CGPoint(x: 180, y: 240),
            connections: [connection],
            portPositions: [start: CGPoint(x: 40, y: 40), end: CGPoint(x: 240, y: 40)]
        )
        #expect(miss.isEmpty)
    }

    @Test
    func splice_insertsNodeOnCable() {
        let source = UUID()
        let dest = UUID()
        let filter = UUID()
        let link = MapGraphLink(fromPlacementID: source, toPlacementID: dest)
        let next = NodeGraphGeometry.splice(nodeID: filter, onto: link, links: [link])
        #expect(next.count == 2)
        #expect(next.contains { $0.fromPlacementID == source && $0.toPlacementID == filter })
        #expect(next.contains { $0.fromPlacementID == filter && $0.toPlacementID == dest })
    }

    @Test
    func tidy_andGroup_alignHierarchy() {
        let a = MapGraphPlacement(kind: .inputSource, x: 400, y: 20)
        let b = MapGraphPlacement(kind: .placeholder, x: 10, y: 300)
        let tidied = NodeGraphGeometry.tidy([a, b])
        #expect(tidied.first { $0.id == a.id }?.x == MapGraphMetrics.originX)
        #expect(tidied.first { $0.id == b.id }?.x == MapGraphMetrics.originX + 1.1 * MapGraphMetrics.columnGap)
        let backdrop = NodeGraphGeometry.groupBackdrop(around: [a, b])
        #expect(backdrop?.childIDs.count == 2)
        #expect((backdrop?.width ?? 0) > MapGraphMetrics.nodeWidth)
    }

    @Test
    func bypass_passesTextureThrough() {
        let engine = VideoFilterEngine()
        let green = RGBA8(r: 0, g: 1, b: 0, a: 1)
        let keyed = engine.applyChroma(pixel: green, settings: .green)
        #expect(keyed.a < 0.05)
        engine.bypassProcessing = true
        let passthrough = engine.applyChroma(pixel: green, settings: .green)
        #expect(passthrough.a == 1)
        #expect(engine.process(pixel: green).g == 1)
    }

    @Test
    func engine_duplicatesAndRemovesNodes() {
        let matrix = PlaceholderMatrixEngine()
        let first = matrix.addGraphNode(kind: .processFilter, title: "Chroma Key", filterID: NodeFilterCatalog.chroma.rawValue)
        let second = matrix.addGraphNode(kind: .placeholder)
        matrix.upsertGraphLink(from: first.id, to: second.id)
        matrix.selectGraphNodes([first.id])
        let copy = NodeGraphGeometry.duplicate(matrix.graphPlacements, ids: [first.id])
        #expect(copy.items.count == 1)
        #expect(copy.items[0].id != first.id)
        #expect(copy.items[0].filterID == NodeFilterCatalog.chroma.rawValue)
        matrix.removeGraphNodes([first.id])
        #expect(matrix.graphPlacements.contains { $0.id == second.id })
        #expect(matrix.graphLinks.isEmpty)
    }

    private static func key(_ letter: String, shift: Bool = false) -> ShortcutInput {
        ShortcutInput(
            characters: letter,
            keyCode: letter == " " ? KeyboardShortcutResolver.space : 0,
            command: false,
            shift: shift,
            option: false,
            control: false,
            isARepeat: false
        )
    }

    private static func command(_ letter: String, shift: Bool = false, option: Bool = false) -> ShortcutInput {
        ShortcutInput(characters: letter, keyCode: 0, command: true, shift: shift, option: option, control: false, isARepeat: false)
    }
}
