#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct CanvasInteractionTests {
    @Test
    func shapeDefaults_areStrokeFree() {
        var rectangle = CanvasObject(name: "Rect", kind: .rectangle, bounds: CanvasBounds(x: 0, y: 0, width: 200, height: 100))
        ShapeDefaults.apply(&rectangle)
        #expect(rectangle.stroke.style == .none)
        #expect(rectangle.stroke.width == 0)
        #expect(rectangle.fill.color == ShapeDefaults.fillAccent)
        #expect(rectangle.shadow.enabled == false)
        #expect(rectangle.stroke.cornerRadius == 0)
        #expect(rectangle.transform.lockAspectRatio == false)

        var ellipse = CanvasObject(name: "Oval", kind: .ellipse, bounds: CanvasBounds(x: 0, y: 0, width: 200, height: 100))
        ShapeDefaults.apply(&ellipse)
        #expect(ellipse.stroke.style == .none)
        #expect(ellipse.stroke.width == 0)
        #expect(abs(ellipse.stroke.cornerRadius - 50) < 0.001)

        var text = CanvasObject(name: "Title", kind: .text, bounds: CanvasBounds(x: 0, y: 0, width: 400, height: 80))
        ShapeDefaults.apply(&text)
        #expect(text.stroke.style == .none)
        #expect(text.stroke.width == 0)
        #expect(text.typography.fontSize == 48)
        #expect(text.typography.color == "#FFFFFF")
        #expect(text.typography.fontWeight == .bold)
        #expect(text.textLayout.horizontalAlign == .center)
        #expect(text.textShadow.enabled)
        #expect(text.textShadow.offset == 2)
        #expect(text.textShadow.blur == 4)
        #expect(text.textShadow.color == "#80000000")
    }

    @Test
    func clipboard_rematerializesNewIDsAndOffsets() {
        let source = CanvasObject(name: "Box", kind: .rectangle, bounds: CanvasBounds(x: 40, y: 60, width: 100, height: 80))
        ClipboardController.write([source])
        #expect(ClipboardController.hasObjects)
        let pasted = ClipboardController.rematerialize(ClipboardController.read(), offset: ClipboardController.pasteOffset)
        #expect(pasted.count == 1)
        #expect(pasted[0].id != source.id)
        #expect(abs(pasted[0].transform.x - 60) < 0.001)
        #expect(abs(pasted[0].transform.y - 80) < 0.001)
        let duplicated = ClipboardController.rematerialize([source], offset: ClipboardController.duplicateOffset)
        #expect(abs(duplicated[0].transform.x - 50) < 0.001)
    }

    @Test
    func handles_midEdgesStaySingleAxis() {
        let box = CanvasBounds(x: 100, y: 80, width: 200, height: 100)
        let right = TransformHandleEngine.resize(box, handle: .right, deltaX: 40, deltaY: 80, lockAspect: true, fromCenter: false)
        #expect(abs(right.width - 240) < 0.001)
        #expect(abs(right.height - 100) < 0.001)
        #expect(abs(right.y - 80) < 0.001)
        #expect(abs(right.x - 100) < 0.001)

        let top = TransformHandleEngine.resize(box, handle: .top, deltaX: 50, deltaY: -20, lockAspect: true, fromCenter: false)
        #expect(abs(top.width - 200) < 0.001)
        #expect(abs(top.height - 120) < 0.001)
        #expect(abs(top.x - 100) < 0.001)
    }

    @Test
    func handles_cornersHonorShiftAndOption() {
        let box = CanvasBounds(x: 100, y: 80, width: 200, height: 100)
        let free = TransformHandleEngine.resize(box, handle: .bottomRight, deltaX: 40, deltaY: 10, lockAspect: false, fromCenter: false)
        #expect(abs(free.width - 240) < 0.001)
        #expect(abs(free.height - 110) < 0.001)

        let constrained = TransformHandleEngine.resize(box, handle: .bottomRight, deltaX: 40, deltaY: 0, lockAspect: true, fromCenter: false)
        #expect(abs(constrained.width / constrained.height - 2) < 0.01)
        #expect(abs(constrained.x - 100) < 0.001)
        #expect(abs(constrained.y - 80) < 0.001)

        let centered = TransformHandleEngine.resize(box, handle: .bottomRight, deltaX: 20, deltaY: 10, lockAspect: false, fromCenter: true)
        #expect(abs(centered.width - 240) < 0.001)
        #expect(abs(centered.height - 120) < 0.001)
        #expect(abs(centered.x + centered.width / 2 - 200) < 0.001)
        #expect(abs(centered.y + centered.height / 2 - 130) < 0.001)

        #expect(TransformHandleEngine.shouldLockAspect(handle: .right, elementLocked: true, shiftHeld: true) == false)
        #expect(TransformHandleEngine.shouldLockAspect(handle: .bottomRight, elementLocked: false, shiftHeld: true))
        #expect(TransformHandleEngine.shouldLockAspect(handle: .bottomRight, elementLocked: true, shiftHeld: false))
    }

    @Test
    func rotation_snapsFifteenDegrees() {
        let snapped = TransformHandleEngine.rotate(from: 0, to: 22, baseRotation: 0, snap15: true)
        #expect(abs(snapped - 15) < 0.001)
        let free = TransformHandleEngine.rotate(from: 0, to: 22, baseRotation: 10, snap15: false)
        #expect(abs(free - 32) < 0.001)
    }

    @Test
    func shortcuts_mapToolsClipboardAndBroadcast() {
        let editor = ShortcutContext(
            editorOpen: true,
            isEditingText: false,
            isTypingInField: false,
            hasObjectSelection: true,
            operatorMode: .edit
        )
        #expect(KeyboardShortcutResolver.resolve(Self.key("t"), context: editor) == .setTool(.text))
        #expect(KeyboardShortcutResolver.resolve(Self.key("r"), context: editor) == .setTool(.rectangle))
        #expect(KeyboardShortcutResolver.resolve(Self.key("c"), context: editor) == .setTool(.ellipse))
        #expect(KeyboardShortcutResolver.resolve(Self.key("p"), context: editor) == .setTool(.placeholder))
        #expect(KeyboardShortcutResolver.resolve(Self.key("v"), context: editor) == .setTool(.pointer))
        #expect(KeyboardShortcutResolver.resolve(Self.key("z"), context: editor) == .setTool(.zoom))
        #expect(KeyboardShortcutResolver.resolve(Self.command("c"), context: editor) == .copy)
        #expect(KeyboardShortcutResolver.resolve(Self.command("v"), context: editor) == .paste)
        #expect(KeyboardShortcutResolver.resolve(Self.command("d"), context: editor) == .duplicate)
        #expect(KeyboardShortcutResolver.resolve(Self.arrow(KeyboardShortcutResolver.leftArrow), context: editor) == .nudge(dx: -1, dy: 0))
        #expect(KeyboardShortcutResolver.resolve(Self.arrow(KeyboardShortcutResolver.leftArrow, shift: true), context: editor) == .nudge(dx: -10, dy: 0))
        #expect(KeyboardShortcutResolver.resolve(Self.command("]", shift: true), context: editor) == .bringToFront)
        #expect(KeyboardShortcutResolver.resolve(Self.command("l", option: true), context: editor) == .align(.left))
        #expect(KeyboardShortcutResolver.resolve(Self.command("1"), context: editor) == .workspace(.show))
        #expect(KeyboardShortcutResolver.resolve(Self.command("2"), context: editor) == .workspace(.edit))
        #expect(KeyboardShortcutResolver.resolve(Self.command("3"), context: editor) == .workspace(.rundown))
        #expect(KeyboardShortcutResolver.resolve(Self.command("4"), context: editor) == .workspace(.map))
        #expect(KeyboardShortcutResolver.resolve(Self.command("5"), context: editor) == .openEditor(.props))

        let typing = ShortcutContext(
            editorOpen: true,
            isEditingText: true,
            isTypingInField: true,
            hasObjectSelection: true,
            operatorMode: .edit
        )
        #expect(KeyboardShortcutResolver.resolve(Self.key("t"), context: typing) == nil)
        #expect(KeyboardShortcutResolver.resolve(Self.command("c"), context: typing) == nil)

        let show = ShortcutContext(
            editorOpen: false,
            isEditingText: false,
            isTypingInField: false,
            hasObjectSelection: false,
            operatorMode: .show
        )
        #expect(KeyboardShortcutResolver.resolve(Self.space(), context: show) == .advance)
        #expect(KeyboardShortcutResolver.resolve(Self.function(122), context: show) == .clearLayer(1))
        #expect(KeyboardShortcutResolver.resolve(Self.escape(command: true), context: show) == .emergencyClear)
    }

    @Test
    func shortcuts_mapGraphDoesNotStealEditorKeys() {
        let editor = ShortcutContext(
            editorOpen: true,
            isEditingText: false,
            isTypingInField: false,
            hasObjectSelection: true,
            operatorMode: .map
        )
        #expect(KeyboardShortcutResolver.resolve(Self.command("k"), context: editor) == nil)
        #expect(KeyboardShortcutResolver.resolve(Self.key("z"), context: editor) == .setTool(.zoom))
        #expect(KeyboardShortcutResolver.resolve(Self.command("d"), context: editor) == .duplicate)
        #expect(KeyboardShortcutResolver.resolve(Self.escape(command: false), context: editor) == .pointer)

        let map = ShortcutContext(
            editorOpen: false,
            isEditingText: false,
            isTypingInField: false,
            hasObjectSelection: false,
            operatorMode: .map
        )
        #expect(KeyboardShortcutResolver.resolve(Self.command("k"), context: map) == .map(.palette))
        #expect(KeyboardShortcutResolver.resolve(Self.key("z"), context: map) == .map(.zoomFit))
        #expect(KeyboardShortcutResolver.resolve(Self.command("d"), context: map) == .map(.duplicate))
        #expect(KeyboardShortcutResolver.resolve(Self.escape(command: false), context: map) == .map(.deselect))
        #expect(KeyboardShortcutResolver.resolve(Self.space(shift: true), context: map) == .map(.palette))
    }

    @Test @MainActor
    func editor_pasteUsesTwentyPixelOffset() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let added = engine.addObject(.rectangle)
        #expect(added.stroke.style == .none)
        #expect(added.stroke.width == 0)
        let originX = added.transform.x
        engine.copySelectedObjects()
        engine.pasteObjects()
        #expect(engine.selectedObjects.count == 1)
        #expect(engine.selectedObjects.first?.id != added.id)
        #expect(abs((engine.selectedObjects.first?.transform.x ?? 0) - (originX + 20)) < 0.001)
        engine.selectObject(added.id)
        engine.duplicateSelected()
        #expect(abs((engine.selectedObjects.first?.transform.x ?? 0) - (originX + 10)) < 0.001)
    }

    private static func key(_ letter: String, shift: Bool = false) -> ShortcutInput {
        ShortcutInput(characters: letter, keyCode: 0, command: false, shift: shift, option: false, control: false, isARepeat: false)
    }

    private static func command(_ letter: String, shift: Bool = false, option: Bool = false) -> ShortcutInput {
        ShortcutInput(characters: letter, keyCode: 0, command: true, shift: shift, option: option, control: false, isARepeat: false)
    }

    private static func arrow(_ code: UInt16, shift: Bool = false) -> ShortcutInput {
        ShortcutInput(characters: "", keyCode: code, command: false, shift: shift, option: false, control: false, isARepeat: false)
    }

    private static func space(shift: Bool = false) -> ShortcutInput {
        ShortcutInput(characters: " ", keyCode: KeyboardShortcutResolver.space, command: false, shift: shift, option: false, control: false, isARepeat: false)
    }

    private static func function(_ code: UInt16) -> ShortcutInput {
        ShortcutInput(characters: "", keyCode: code, command: false, shift: false, option: false, control: false, isARepeat: false)
    }

    private static func escape(command: Bool) -> ShortcutInput {
        ShortcutInput(characters: "\u{1b}", keyCode: KeyboardShortcutResolver.escape, command: command, shift: false, option: false, control: false, isARepeat: false)
    }
}
