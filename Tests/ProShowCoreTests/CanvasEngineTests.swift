#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct CanvasEngineTests {
    @Test
    func resize_cornersAndCenterAndShiftConstraint() {
        let box = CanvasBounds(x: 100, y: 80, width: 200, height: 100)
        let free = CanvasTransformEngine.resize(box, handle: .bottomRight, deltaX: 40, deltaY: 10, lockAspect: false, fromCenter: false)
        #expect(abs(free.width - 240) < 0.001)
        #expect(abs(free.height - 110) < 0.001)

        let locked = CanvasTransformEngine.resize(box, handle: .bottomRight, deltaX: 40, deltaY: 0, lockAspect: true, fromCenter: false)
        #expect(abs(locked.width / locked.height - 2) < 0.01)

        let centered = CanvasTransformEngine.resize(box, handle: .right, deltaX: 20, deltaY: 0, lockAspect: false, fromCenter: true)
        #expect(abs(centered.width - 240) < 0.001)
        #expect(abs(centered.x - 80) < 0.001)
        #expect(abs(centered.height - 100) < 0.001)
        #expect(CanvasTransformEngine.constrainAspect(true, shiftHeld: true) == true)
        #expect(CanvasTransformEngine.constrainAspect(false, shiftHeld: true) == true)
        #expect(CanvasTransformEngine.constrainAspect(true, shiftHeld: false) == true)
        #expect(CanvasTransformEngine.defaultLockAspect(for: .image, locked: false))
    }

    @Test
    func rotate_snapsFifteenDegrees() {
        let next = CanvasTransformEngine.rotate(from: 0, to: 22, baseRotation: 0, snap15: true)
        #expect(abs(next - 15) < 0.001)
        let free = CanvasTransformEngine.rotate(from: 0, to: 22, baseRotation: 10, snap15: false)
        #expect(abs(free - 32) < 0.001)
    }

    @Test
    func corners_boolean_andPaths() {
        let box = CanvasBounds(x: 0, y: 0, width: 100, height: 40)
        #expect(CanvasTransformEngine.clampCornerRadius(80, bounds: box) == 20)
        let corners = CanvasTransformEngine.unlinkCorners(8)
        #expect(corners.topLeft == 8 && corners.bottomRight == 8)

        let a = CanvasBounds(x: 0, y: 0, width: 100, height: 100)
        let b = CanvasBounds(x: 50, y: 50, width: 100, height: 100)
        let union = CanvasTransformEngine.boolean(a, b, operation: .union)
        #expect(union.width == 150 && union.height == 150)
        let inter = CanvasTransformEngine.boolean(a, b, operation: .intersect)
        #expect(inter.width == 50 && inter.height == 50)

        var path = CanvasTransformEngine.rectanglePath(bounds: a)
        #expect(path.nodes.count == 4)
        let first = path.nodes[0]
        path = CanvasTransformEngine.moveNode(path, id: first.id, x: 10, y: 12)
        #expect(path.nodes[0].x == 10)
        path = CanvasTransformEngine.setNodeKind(path, id: first.id, kind: .smooth)
        #expect(path.nodes[0].kind == .smooth)
        path = CanvasTransformEngine.bendSegment(path, from: 0, deltaX: 8, deltaY: 4)
        #expect(path.nodes[0].outX != path.nodes[0].x)
        let joined = CanvasTransformEngine.join(path, CanvasTransformEngine.rectanglePath(bounds: b))
        #expect(joined.nodes.count == 8)
        #expect(CanvasTransformEngine.cut(path, at: 1).count == 2)
    }

    @Test
    func snap_distance_tidy_andAutoLayout() {
        let canvas = CanvasBounds(x: 0, y: 0, width: 1000, height: 1000)
        let snapped = CanvasTransformEngine.snap(
            x: 3,
            y: 4,
            width: 40,
            height: 20,
            others: [],
            canvas: canvas,
            bypass: false
        )
        #expect(snapped.x == 0)
        #expect(snapped.guides.contains { $0.canvasAligned })
        let bypassed = CanvasTransformEngine.snap(x: 3, y: 4, width: 40, height: 20, others: [], canvas: canvas, bypass: true)
        #expect(bypassed.x == 3)

        let a = CanvasBounds(x: 0, y: 0, width: 10, height: 10)
        let b = CanvasBounds(x: 30, y: 0, width: 10, height: 10)
        let gap = CanvasTransformEngine.distance(from: a, to: b)
        #expect(gap.gapX == 20)

        let tidy = CanvasTransformEngine.equalGaps([
            CanvasBounds(x: 0, y: 0, width: 10, height: 10),
            CanvasBounds(x: 20, y: 0, width: 10, height: 10),
            CanvasBounds(x: 80, y: 0, width: 10, height: 10),
        ], horizontal: true)
        #expect(abs((tidy[1].x - (tidy[0].x + tidy[0].width)) - (tidy[2].x - (tidy[1].x + tidy[1].width))) < 0.001)

        let laid = CanvasTransformEngine.autoLayout(
            children: [
                CanvasBounds(x: 0, y: 0, width: 20, height: 10),
                CanvasBounds(x: 0, y: 0, width: 30, height: 10),
            ],
            container: CanvasBounds(x: 0, y: 0, width: 400, height: 80),
            layout: .default
        )
        #expect(laid.children[1].x == laid.children[0].x + 20 + 12)
        #expect(laid.frame.width < 400)

        let hug = CanvasTransformEngine.fittedTextBounds(text: "Hi", fontSize: 40, mode: .autoWidth, current: CanvasBounds(x: 0, y: 0, width: 10, height: 10))
        #expect(hug.width > 10)
        #expect(CanvasTransformEngine.textOverflows(text: "Hello\nWorld\nAgain", fontSize: 48, bounds: CanvasBounds(x: 0, y: 0, width: 40, height: 20)))
    }

    @Test @MainActor
    func editor_handlesBooleanGroupAndTools() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let a = engine.addObject(.rectangle)
        engine.mutateSelectedObjects { $0.bounds = CanvasBounds(x: 0, y: 0, width: 100, height: 100) }
        let b = engine.addObject(.rectangle)
        engine.mutateSelectedObjects { $0.bounds = CanvasBounds(x: 50, y: 50, width: 100, height: 100) }
        engine.selectedObjectIDs = [a.id, b.id]
        engine.applyBoolean(.union)
        #expect(engine.selectedObjects.first?.booleanOp == .union)
        #expect(engine.selectedObjects.first?.bounds.width == 150)

        engine.selectedObjectIDs = [a.id, b.id]
        engine.groupSelected()
        #expect(engine.selectedObjects.allSatisfy { $0.groupID != nil })
        engine.applyAutoLayout()
        #expect(engine.selectedObjects.contains(where: { $0.autoLayout?.enabled == true }))
        engine.setTool(.pen)
        #expect(engine.activeTool == .pen)
        engine.zoomToActualPixels()
        #expect(engine.zoom == 1)
        #expect(engine.canUngroup)
        #expect(engine.showsCompoundChrome)

        engine.beginHandleDrag(id: a.id, handle: .bottomRight)
        engine.updateHandleDrag(translationX: 20, translationY: 20, shiftHeld: false, optionHeld: false)
        engine.endHandleDrag()
        #expect((engine.selectedDocument?.objects.first(where: { $0.id == a.id })?.bounds.width ?? 0) > 100)
    }

    @Test
    func vectorPath_hitTestAndBooleanCSG() {
        let a = CanvasTransformEngine.rectanglePath(bounds: CanvasBounds(x: 0, y: 0, width: 100, height: 100))
        let b = CanvasTransformEngine.rectanglePath(bounds: CanvasBounds(x: 50, y: 50, width: 100, height: 100))
        #expect(PathGeometryEngine.contains(a, x: 25, y: 25))
        #expect(!PathGeometryEngine.contains(a, x: 140, y: 140))
        #expect(PathGeometryEngine.hitTest(a, x: 0, y: 50, strokeWidth: 4))

        let intersect = PathGeometryEngine.booleanPath(a, b, operation: .intersect)
        #expect(PathGeometryEngine.contains(intersect, x: 75, y: 75))
        #expect(!PathGeometryEngine.contains(intersect, x: 20, y: 20))
        let box = PathGeometryEngine.bounds(of: intersect)
        #expect(abs(box.width - 50) < 8)
        #expect(abs(box.height - 50) < 8)

        let subtracted = PathGeometryEngine.booleanPath(a, b, operation: .subtract)
        #expect(PathGeometryEngine.contains(subtracted, x: 20, y: 20))
        #expect(!PathGeometryEngine.contains(subtracted, x: 80, y: 80))
    }

    @Test @MainActor
    func textOutlines_honorFontAndInlineEdit() {
        let outlines = CanvasTransformEngine.convertTextToPath(
            text: "H",
            bounds: CanvasBounds(x: 0, y: 0, width: 120, height: 80),
            fontFamily: "Helvetica",
            fontSize: 64
        )
        #expect(outlines.nodes.count > 4)

        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let text = engine.addObject(.text)
        engine.setTool(.text)
        #expect(engine.isEditingText == false)
        #expect(engine.inlineEditID == nil)
        engine.beginInlineEdit(id: text.id)
        engine.setInlineText("Grace", id: text.id)
        #expect(engine.isEditingText)
        #expect(engine.inlineEditID == text.id)
        #expect(engine.selectedObjects.first?.text == "Grace")
        engine.setTool(.pointer)
        #expect(engine.isEditingText == false)
        engine.beginInlineEdit(id: text.id)
        engine.setTool(.text)
        #expect(engine.isEditingText)
        #expect(engine.inlineEditID == text.id)
        engine.commitInlineText("Grace", id: text.id)
        #expect(engine.isEditingText == false)
        #expect(engine.inlineEditID == nil)
        engine.convertSelectedTextToOutlines()
        #expect(engine.selectedObjects.first?.kind == .pen)
        #expect((engine.selectedObjects.first?.vectorPath?.nodes.count ?? 0) > 4)
        if let path = engine.selectedObjects.first?.vectorPath {
            let box = PathGeometryEngine.bounds(of: path)
            #expect(engine.object(atX: box.x + box.width / 2, y: box.y + box.height / 2) != nil)
        } else {
            #expect(engine.object(atX: text.bounds.x + 8, y: text.bounds.y + 8) != nil)
        }
    }

    @Test
    func compoundBounds_andProportionalChildScale() {
        let a = CanvasBounds(x: 100, y: 100, width: 200, height: 150)
        let b = CanvasBounds(x: 250, y: 200, width: 300, height: 200)
        let compound = CanvasBounds.union([a, b])
        #expect(compound?.x == 100)
        #expect(compound?.y == 100)
        #expect(compound?.width == 450)
        #expect(compound?.height == 300)

        let scaled = TransformHandleEngine.scaleChild(
            a,
            from: compound!,
            to: CanvasBounds(x: 100, y: 100, width: 900, height: 300)
        )
        #expect(abs(scaled.x - 100) < 0.001)
        #expect(abs(scaled.width - 400) < 0.001)
        #expect(abs(scaled.height - 150) < 0.001)

        let shifted = TransformHandleEngine.scaleChild(
            b,
            from: compound!,
            to: CanvasBounds(x: 100, y: 100, width: 900, height: 300)
        )
        #expect(abs(shifted.x - 400) < 0.001)
        #expect(abs(shifted.width - 600) < 0.001)
    }

    @Test @MainActor
    func group_selectsAsUnit_andDoubleClickIsolates() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let a = engine.addObject(.rectangle)
        engine.mutateSelectedObjects { $0.bounds = CanvasBounds(x: 100, y: 100, width: 200, height: 150) }
        let b = engine.addObject(.rectangle)
        engine.mutateSelectedObjects { $0.bounds = CanvasBounds(x: 250, y: 200, width: 300, height: 200) }
        engine.selectedObjectIDs = [a.id, b.id]
        engine.groupSelected()
        #expect(engine.canUngroup)
        #expect(engine.selectedObjectIDs == [a.id, b.id])

        engine.clearObjectSelection()
        engine.selectObject(a.id)
        #expect(engine.selectedObjectIDs == [a.id, b.id])
        #expect(engine.showsCompoundChrome)

        engine.isolateObject(b.id)
        #expect(engine.isolatedObjectID == b.id)
        #expect(engine.selectedObjectIDs == [b.id])
        #expect(engine.showsCompoundChrome == false)
        #expect(engine.isolatedParentBounds?.width == 450)

        engine.exitIsolation()
        #expect(engine.isolatedObjectID == nil)
        #expect(engine.selectedObjectIDs == [a.id, b.id])

        engine.beginHandleDrag(id: a.id, handle: .right)
        engine.updateHandleDrag(translationX: 450, translationY: 0)
        engine.endHandleDrag()
        let scaledA = engine.selectedDocument?.objects.first(where: { $0.id == a.id })?.bounds
        let scaledB = engine.selectedDocument?.objects.first(where: { $0.id == b.id })?.bounds
        #expect(abs((scaledA?.width ?? 0) - 400) < 1)
        #expect(abs((scaledB?.x ?? 0) - 400) < 1)

        engine.ungroupSelected()
        #expect(engine.canUngroup == false)
        #expect(engine.selectedDocument?.objects.allSatisfy { $0.groupID == nil } == true)
    }

    @Test @MainActor
    func objectTree_foldersAndMultiSelect() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let a = engine.addObject(.rectangle)
        let b = engine.addObject(.rectangle)
        engine.selectedObjectIDs = [a.id, b.id]
        engine.groupSelected()
        let groupID = engine.selectedDocument?.objects.first(where: { $0.id == a.id })?.groupID
        #expect(groupID != nil)

        let expanded = engine.objectTreeRows
        #expect(expanded.contains { if case .group(let id, _, let children, let isExpanded) = $0 {
            return id == groupID && children.contains(a.id) && children.contains(b.id) && isExpanded
        } else { return false } })
        #expect(expanded.filter { if case .object(let object, let depth) = $0 {
            return depth == 1 && (object.id == a.id || object.id == b.id)
        } else { return false } }.count == 2)

        engine.toggleGroupExpanded(groupID!)
        #expect(engine.objectTreeRows.contains { if case .group(_, _, _, let isExpanded) = $0 { return !isExpanded } else { return false } })
        #expect(!engine.objectTreeRows.contains { if case .object(let object, _) = $0 {
            return object.id == a.id || object.id == b.id
        } else { return false } })

        engine.toggleGroupExpanded(groupID!)
        let c = engine.addObject(.ellipse)
        engine.selectObjectTreeRow(a.id)
        #expect(engine.selectedObjectIDs == [a.id])
        engine.selectObjectTreeRow(c.id, additive: true)
        #expect(engine.selectedObjectIDs == [a.id, c.id])

        engine.selectObjectTreeRow(groupID!)
        #expect(engine.selectedObjectIDs == [a.id, b.id])

        engine.selectObjectTreeRow(a.id)
        engine.selectObjectTreeRow(c.id, extending: true)
        #expect(engine.selectedObjectIDs.contains(a.id))
        #expect(engine.selectedObjectIDs.contains(c.id))
    }

    @Test @MainActor
    func canvas_shiftClickAddsToSelection_andMarqueeCoversHits() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let left = engine.addObject(.rectangle)
        engine.mutateSelectedObjects { $0.bounds = CanvasBounds(x: 40, y: 40, width: 120, height: 80) }
        let right = engine.addObject(.rectangle)
        engine.mutateSelectedObjects { $0.bounds = CanvasBounds(x: 400, y: 40, width: 120, height: 80) }
        engine.selectObject(left.id)
        engine.selectObject(right.id, additive: true)
        #expect(engine.selectedObjectIDs == [left.id, right.id])

        engine.clearObjectSelection()
        engine.selectObjects(intersecting: CanvasBounds(x: 30, y: 30, width: 160, height: 100))
        #expect(engine.selectedObjectIDs == [left.id])
        engine.selectObjects(intersecting: CanvasBounds(x: 0, y: 0, width: 600, height: 200), additive: true)
        #expect(engine.selectedObjectIDs == [left.id, right.id])
    }
}
