#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif

@Suite
struct EditorEngineTests {
    @Test @MainActor
    func openPresentation_seedsSlidesAndSelectsActive() {
        let controller = TestSupport.sampleController()
        let slide = controller.show.allSlides[0]
        controller.openEditor(.presentation)
        #expect(controller.editors.kind == .presentation)
        #expect(controller.editors.documents.count == controller.show.allSlides.count)
        #expect(controller.editors.selectedDocument?.slideID == slide.id)
        #expect(!controller.editors.selectedDocument!.objects.isEmpty)
    }

    @Test @MainActor
    func presentationSeed_programMediaCue_hasNoPlaceholderTextBox() {
        var slide = Slide(
            title: "Loop.mp4",
            lines: [],
            label: "Video",
            actions: ["Media: Loop.mp4"],
            backgroundEnabled: false,
            mediaAction: MediaAction(
                id: UUID(),
                title: "Loop.mp4",
                tintHex: "#112233",
                duration: "1:00",
                isImage: false,
                filePath: "/tmp/loop.mp4"
            )
        )
        #expect(slide.isProgramMediaCue)
        let objects = EditorEngine.objects(from: slide, number: 1)
        #expect(objects.isEmpty)
    }

    @Test @MainActor
    func addObject_andReorder_updatesZOrder() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let before = engine.selectedDocument?.objects.count ?? 0
        let added = engine.addObject(.text)
        #expect(engine.selectedObjectIDs.contains(added.id))
        #expect(engine.selectedDocument?.objects.count == before + 1)
        #expect(added.buildSteps?.count == 1)
        #expect(added.buildSteps?.first?.effect == .fade)
        #expect(added.buildSteps?.first?.trigger == .onSlideEnter)
        #expect(added.buildSteps?.first?.durationSeconds == 0.3)
        engine.addBuildStep(phase: .buildOut)
        let outs = engine.selectedDocument?.objects.first(where: { $0.id == added.id })?.buildSteps?.filter { $0.phase == .buildOut }
        #expect(outs?.count == 1)
        #expect(outs?.first?.trigger == .beforeSlideLeave)
        engine.reorderObjects(from: IndexSet(integer: 0), to: engine.selectedDocument!.sortedObjects.count)
        #expect(engine.selectedDocument?.sortedObjects.last?.id == added.id)
    }

    @Test @MainActor
    func copyrightTokens_resolveAgainstInfo() {
        let info = CopyrightInfo(
            title: "Stellar",
            artist: "Okai",
            publisher: "House",
            year: "2024",
            ccliNumber: "12345"
        )
        let line = info.resolvedLine()
        #expect(line.contains("Stellar"))
        #expect(line.contains("Okai"))
        #expect(line.contains("12345"))
        #expect(!line.contains("{Title}"))
    }

    @Test @MainActor
    func commitLive_coversEachEditorKind() {
        let show = SampleContent.sundayMorningService().show
        let engine = EditorEngine()

        engine.open(.presentation, show: show, selectedSlideID: show.allSlides[0].id)
        if case .goLive(let id) = engine.commitLive(selectedSlideID: show.allSlides[0].id) {
            #expect(id == show.allSlides[0].id)
        } else {
            Issue.record("expected goLive")
        }

        engine.open(.stage, show: show, selectedSlideID: nil)
        if case .setStageLook(let look) = engine.commitLive(selectedSlideID: nil) {
            #expect(look.showCurrent)
            #expect(look.showNext)
            #expect(look.showClock)
        } else {
            Issue.record("expected setStageLook")
        }

        engine.open(.theme, show: show, selectedSlideID: nil)
        #expect(engine.documents.map(\.variantName) == EditorCatalog.themeVariants)
        if case .applyTheme(let name) = engine.commitLive(selectedSlideID: nil) {
            #expect(name == "Lyric Standard")
        } else {
            Issue.record("expected applyTheme")
        }

        engine.open(.ccli, show: show, selectedSlideID: nil)
        engine.copyright = CopyrightInfo(title: "Song", artist: "Band", year: "2020", ccliNumber: "9")
        if case .setMessage(let text) = engine.commitLive(selectedSlideID: nil) {
            #expect(text.contains("Song"))
            #expect(engine.copyright.showOnScreen)
        } else {
            Issue.record("expected setMessage")
        }

        engine.open(.props, show: show, selectedSlideID: nil)
        if case .toggleProp(let name) = engine.commitLive(selectedSlideID: nil) {
            #expect(name == "Logo Bug")
        } else {
            Issue.record("expected toggleProp")
        }

        engine.open(.masks, show: show, selectedSlideID: nil)
        engine.mutateSelectedDocument { $0.invertMask = true }
        if case .setMask(let enabled, let invert, let kind) = engine.commitLive(selectedSlideID: nil) {
            #expect(enabled)
            #expect(invert)
            #expect(kind == "invert")
        } else {
            Issue.record("expected setMask")
        }
    }

    @Test @MainActor
    func controller_pushEditorLive_andAddSlide() {
        let controller = TestSupport.sampleController()
        let before = controller.show.allSlides.count
        controller.openEditor(.presentation)
        controller.addEditorSlide()
        #expect(controller.show.allSlides.count == before + 1)
        #expect(controller.editors.documents.count == before + 1)
        controller.pushEditorLive()
        #expect(controller.liveSlideID != nil)

        controller.openEditor(.ccli)
        controller.editors.copyright = CopyrightInfo(title: "Live Song", showOnScreen: false)
        controller.pushEditorLive()
        #expect(controller.compositor.stack.message?.contains("Live Song") == true)
    }

    @Test @MainActor
    func selectionBounds_unionsMultiSelect() {
        let engine = EditorEngine()
        engine.open(.masks, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let first = engine.selectedDocument!.objects[0]
        let second = engine.addObject(.cutout)
        engine.selectObject(first.id)
        engine.selectObject(second.id, additive: true)
        let bounds = engine.selectionBounds
        #expect(bounds != nil)
        #expect((bounds?.width ?? 0) >= first.bounds.width)
    }

    @Test @MainActor
    func inspector_bindsAndAlignsAndUndoes() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        #expect(engine.inspectorTab == .text)
        engine.mutateSelectedObjects { $0.transform.x = 240 }
        #expect(engine.commonValue(\.transform.x) == 240)
        engine.alignSelected(.left)
        #expect(engine.commonValue(\.transform.x) == 0)
        engine.setSelectedWidth(400)
        #expect((engine.selectedObjects.first?.transform.width ?? 0) == 400)
        engine.copySelectedTextStyle()
        engine.mutateSelectedObjects { $0.typography.fontSize = 12 }
        engine.pasteSelectedTextStyle()
        #expect(engine.commonValue(\.typography.fontSize) != 12 || engine.textStyleClipboard?.fontSize == 12)
        #expect(engine.canUndo)
        let afterPaste = engine.commonValue(\.typography.fontSize)
        engine.undo()
        #expect(engine.commonValue(\.typography.fontSize) != afterPaste || engine.canRedo)
        engine.clearObjectSelection()
        #expect(engine.inspectorTab == .slide)
        #expect(engine.selectedObjects.isEmpty)
    }

    @Test @MainActor
    func hideAndCornerRadius_rewriteObjectsArray() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        engine.addObject(.rectangle)
        engine.mutateSelectedObjects { object in
            object.stroke.cornerRadius = 48
            object.stroke.corners = .uniform(48)
            if object.kind == .rectangle { object.kind = .roundedRectangle }
        }
        #expect(engine.commonValue(\.stroke.cornerRadius) == 48)
        #expect(engine.selectedObjects.first?.stroke.corners?.topLeft == 48)
        #expect(engine.selectedObjects.first?.kind == .roundedRectangle)
        engine.toggleAudienceVisibility(id: engine.selectedObjectIDs.first!)
        #expect(engine.commonValue(\.visibleOnAudience) == false)
        engine.toggleAudienceVisibility(id: engine.selectedObjectIDs.first!)
        #expect(engine.commonValue(\.visibleOnAudience) == true)
        engine.toggleAudioMute(id: engine.selectedObjectIDs.first!)
        #expect(engine.selectedObjects.first?.isAudioMuted == true)
        engine.toggleAudioMute(id: engine.selectedObjectIDs.first!)
        #expect(engine.selectedObjects.first?.isAudioMuted == false)
    }

    @Test @MainActor
    func roundedRectangle_resolvesVisibleCorners() {
        let rounded = CanvasObject(
            name: "Round",
            kind: .roundedRectangle,
            bounds: CanvasBounds(x: 0, y: 0, width: 1280, height: 720)
        )
        #expect(rounded.resolvedCornerRadii.topLeft > 0)
        #expect(rounded.resolvedCornerRadii.topLeft == rounded.defaultRoundedRadius)

        var stored = rounded
        stored.stroke.cornerRadius = 48
        stored.stroke.corners = .uniform(48)
        #expect(stored.resolvedCornerRadii.topLeft == 48)
        #expect(stored.resolvedCornerRadii.bottomRight == 48)

        let sharp = CanvasObject(
            name: "Box",
            kind: .rectangle,
            bounds: CanvasBounds(x: 0, y: 0, width: 1280, height: 720)
        )
        #expect(sharp.resolvedCornerRadii.maxRadius == 0)

        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let added = engine.addObject(.roundedRectangle)
        #expect(added.kind == .roundedRectangle)
        #expect(added.stroke.cornerRadius > 0)
        #expect(added.stroke.corners?.maxRadius == added.stroke.cornerRadius)
    }

    @Test @MainActor
    func slideBackground_updatesWithoutObjectSelection() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        engine.clearObjectSelection()
        #expect(engine.selectedObjectIDs.isEmpty)
        engine.mutateSelectedDocument {
            $0.backgroundHex = "#2F6FED"
            $0.backgroundEnabled = true
        }
        #expect(engine.selectedDocument?.backgroundEnabled == true)
        #expect(engine.selectedDocument?.backgroundHex == "#2F6FED")
        engine.mutateSelectedDocument { $0.backgroundEnabled = false }
        #expect(engine.selectedDocument?.backgroundEnabled == false)
    }

    @Test @MainActor
    func slideBackground_rehydratesOntoShowAndCue() {
        let controller = TestSupport.sampleController()
        let slideID = controller.show.allSlides[0].id
        controller.setMode(.edit)
        controller.editors.mutateSelectedDocument {
            $0.backgroundEnabled = false
            $0.backgroundHex = "#00000000"
        }
        #expect(controller.show.slide(id: slideID)?.backgroundEnabled == false)
        controller.goLive(slideID: slideID)
        #expect(controller.compositor.stack.slideBackgroundEnabled == false)
        controller.setMode(.show)
        controller.setMode(.edit)
        #expect(controller.editors.selectedDocument?.backgroundEnabled == false)
    }

    @Test
    func canvasTypeface_matchesRequestedTraits() {
        let bold = CanvasTypeface.nsFont(family: "Helvetica", size: 32, weight: .bold, bold: true, italic: false)
        #expect(abs(bold.pointSize - 32) < 0.01)
        let traits = NSFontManager.shared.traits(of: bold)
        #expect(traits.contains(.boldFontMask))
        let italic = CanvasTypeface.nsFont(family: "Helvetica", size: 24, weight: .regular, bold: false, italic: true)
        #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
        let fitted = CanvasTypeface.fittedSize(
            text: "Hello",
            font: bold,
            box: CGSize(width: 2000, height: 2000),
            autoFit: .shrink
        )
        #expect(abs(fitted - 32) < 0.01)
    }

    @Test @MainActor
    func edits_surviveDeselect() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let id = engine.selectedObjectIDs.first
        engine.mutateSelectedObjects {
            $0.typography.fontFamily = "Georgia"
            $0.typography.fontSize = 72
            $0.textLayout.horizontalAlign = .right
            $0.stroke.cornerRadius = 24
        }
        engine.clearObjectSelection()
        #expect(engine.selectedObjects.isEmpty)
        let stored = engine.documents.first?.objects.first { $0.id == id }
        #expect(stored?.typography.fontFamily == "Georgia")
        #expect(stored?.typography.fontSize == 72)
        #expect(stored?.textLayout.horizontalAlign == .right)
        #expect(stored?.stroke.cornerRadius == 24)
        if let id {
            engine.selectObject(id)
        }
        #expect(engine.commonValue(\.typography.fontFamily) == "Georgia")
        #expect(engine.commonValue(\.typography.fontSize) == 72)
    }

    @Test @MainActor
    func inspector_mixedSelectionShowsNoCommonValue() {
        let engine = EditorEngine()
        engine.open(.masks, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let first = engine.selectedDocument!.objects[0]
        let second = engine.addObject(.cutout)
        engine.mutateSelectedObjects { $0.transform.x = first.transform.x + 120 }
        engine.selectObject(first.id, additive: true)
        #expect(engine.selectedObjects.count == 2)
        #expect(engine.commonValue(\.transform.x) == nil)
        let third = engine.addObject(.cutout)
        engine.mutateSelectedObjects { $0.transform.x = first.transform.x + 240 }
        engine.selectObject(first.id)
        engine.selectObject(second.id, additive: true)
        engine.selectObject(third.id, additive: true)
        engine.distributeSelected(.horizontal)
        #expect(engine.selectedObjects.count == 3)
    }

    @Test @MainActor
    func canvasLock_blocksDragAndNudge() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let added = engine.addObject(.text)
        let originX = added.transform.x
        engine.toggleCanvasLock(id: added.id)
        engine.selectObject(added.id)
        engine.beginDrag(id: added.id)
        #expect(engine.dragOrigins.isEmpty)
        engine.updateDrag(translationX: 80, translationY: 0)
        engine.endDrag()
        #expect(engine.selectedDocument?.objects.first(where: { $0.id == added.id })?.transform.x == originX)
        engine.nudgeSelected(dx: 20, dy: 0)
        #expect(engine.selectedDocument?.objects.first(where: { $0.id == added.id })?.transform.x == originX)
    }

    @Test @MainActor
    func drag_nudge_duplicate_and_delete() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        engine.snapToGrid = true
        let added = engine.addObject(.rectangle)
        #expect(added.fill.type == .color)
        #expect(added.fill.color == "#2F6FED")
        let originX = engine.commonValue(\.transform.x) ?? 0
        engine.beginDrag(id: added.id)
        engine.updateDrag(translationX: 47, translationY: 12)
        engine.endDrag()
        let grid = engine.gridConfig.gridSizePoints
        #expect(engine.commonValue(\.transform.x) == SnapToGridEngine.snap(originX + 47, gridSize: grid))
        engine.nudgeSelected(dx: 10, dy: 0)
        let afterNudge = engine.commonValue(\.transform.x) ?? 0
        #expect(afterNudge > originX)
        let before = engine.selectedDocument?.objects.count ?? 0
        engine.duplicateSelected()
        #expect(engine.selectedDocument?.objects.count == before + 1)
        engine.deleteSelected()
        #expect(engine.selectedDocument?.objects.count == before)
        #expect(engine.selectedObjectIDs.isEmpty)
    }

    @Test @MainActor
    func clipboard_selectAll_and_textEffects() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        let text = engine.addObject(.text)
        #expect(text.fill.type == .none)
        engine.mutateSelectedObjects {
            $0.text = "hello\nworld"
            $0.typography.textTransform = .uppercase
            $0.textLayout.listType = .bullet
            $0.fill.type = .color
            $0.fill.color = "#FF0000"
            $0.shadow.enabled = true
        }
        #expect(engine.selectedObjects.first?.displayText.contains("• HELLO") == true)
        engine.copySelectedObjects()
        #expect(engine.canPasteObjects)
        engine.pasteObjects()
        #expect(engine.selectedObjects.count == 1)
        #expect(engine.selectedObjects.first?.id != text.id)
        engine.selectAllObjects()
        #expect(engine.selectedObjectIDs.count == (engine.selectedDocument?.objects.count ?? 0))
        engine.cutSelectedObjects()
        #expect(engine.selectedDocument?.objects.isEmpty == true)
        engine.pasteObjects()
        #expect(!(engine.selectedDocument?.objects.isEmpty ?? true))
    }

    @Test @MainActor
    func viewport_fitZoomAndPan() {
        let engine = EditorEngine()
        engine.open(.presentation, show: SampleContent.sundayMorningService().show, selectedSlideID: nil)
        engine.fitToView(paneWidth: 1000, paneHeight: 600, canvasWidth: 1920, canvasHeight: 1080)
        #expect(engine.zoom > EditorEngine.minZoom)
        #expect(engine.zoom < 1)
        #expect(engine.canvasPanX == 0)
        #expect(engine.canvasPanY == 0)
        let fitted = engine.zoom
        engine.setZoom(
            fitted * 2,
            focusX: 500,
            focusY: 300,
            paneWidth: 1000,
            paneHeight: 600,
            canvasWidth: 1920,
            canvasHeight: 1080
        )
        #expect(abs(engine.zoom - fitted * 2) < 0.0001)
        engine.panCanvas(dx: 40, dy: -12)
        #expect(engine.canvasPanX != 0)
        engine.zoom = engine.clampZoom(80)
        #expect(engine.zoom == EditorEngine.maxZoom)
    }

    @Test @MainActor
    func editorCanvas_rehydratesShowAndLiveOutput() {
        let controller = TestSupport.sampleController()
        let slideID = controller.show.allSlides[0].id
        controller.goLive(slideID: slideID)
        controller.setMode(.edit)
        #expect(controller.editors.isOpen)
        controller.editors.mutateSelectedObjects { $0.text = "Live Rehydrated Lyric" }
        controller.editors.mutateSelectedDocument { $0.notes = "Cue the band" }
        controller.applySandboxChanges()
        #expect(controller.show.slide(id: slideID)?.lines.contains("Live Rehydrated Lyric") == true)
        #expect(controller.show.slide(id: slideID)?.notes == "Cue the band")
        #expect(controller.compositor.stack.slideElements.contains(where: { $0.text == "Live Rehydrated Lyric" }))

        controller.setMode(.show)
        #expect(controller.editors.isOpen)
        #expect(controller.editors.kind == .presentation)
        #expect(controller.show.slide(id: slideID)?.canvas.isEmpty == false)
        #expect(controller.operatorMode == .show)

        controller.goLive(slideID: slideID)
        #expect(controller.compositor.stack.slideElements.contains(where: { $0.text == "Live Rehydrated Lyric" }))

        controller.setMode(.edit)
        #expect(controller.editors.selectedDocument?.objects.contains(where: { $0.text == "Live Rehydrated Lyric" }) == true)
        #expect(controller.editors.selectedDocument?.notes == "Cue the band")
    }

    @Test @MainActor
    func setMode_keepsPresentationEditorMountedAndLazilyMountsMap() {
        let controller = TestSupport.sampleController()
        #expect(controller.hasMountedMapWorkspace == false)
        #expect(controller.isCanvasEditorPresented == false)
        controller.setMode(.edit)
        #expect(controller.isCanvasEditorPresented)
        controller.setMode(.show)
        #expect(controller.editors.kind == .presentation)
        #expect(controller.isCanvasEditorPresented == false)
        #expect(controller.hasMountedMapWorkspace == false)
        controller.setMode(.map)
        #expect(controller.hasMountedMapWorkspace)
        #expect(controller.isCanvasEditorPresented == false)
        controller.setMode(.show)
        #expect(controller.hasMountedMapWorkspace)
        #expect(controller.editors.kind == .presentation)
    }

    @Test @MainActor
    func workspaceToolbarSelection_isExclusiveForShowAndProps() {
        let controller = TestSupport.sampleController()
        controller.setMode(.show)
        #expect(controller.workspaceToolbarSelection == .show)
        controller.openEditor(.props)
        #expect(controller.workspaceToolbarSelection == .props)
        controller.setMode(.show)
        #expect(controller.workspaceToolbarSelection == .show)
        controller.setMode(.edit)
        #expect(controller.workspaceToolbarSelection == .edit)
        controller.isProjectSettingsOpen = true
        #expect(controller.workspaceToolbarSelection == .more)
    }

    @Test @MainActor
    func editorCanvas_rehydrateLeavesNonPresentationEditorsAlone() {
        let controller = TestSupport.sampleController()
        let before = controller.show.allSlides[0].lines
        controller.openEditor(.theme)
        controller.editors.mutateSelectedObjects { $0.text = "Theme Title Only" }
        controller.rehydrateFromEditor(persist: true)
        #expect(controller.show.allSlides[0].lines == before)
    }

    @Test @MainActor
    func propsEditor_addsTextShapesAndLive() {
        #expect(EditorCatalog.toolbarItems(for: .props).contains(.text))
        #expect(EditorCatalog.showsShapeMenu(.props))
        #expect(EditorCatalog.showsLiveMenu(.props))
        #expect(EditorCatalog.shapes.contains(.rectangle))
        #expect(EditorCatalog.liveObjects.contains(.systemClock))

        let controller = TestSupport.sampleController()
        controller.openEditor(.props)
        let before = controller.editors.selectedDocument?.objects.count ?? 0
        let text = controller.editors.addObject(.text)
        let shape = controller.editors.addObject(.roundedRectangle)
        let clock = controller.editors.addObject(.systemClock)
        let quote = controller.editors.addObject(.liveQuote)
        #expect(controller.editors.selectedDocument?.objects.count == before + 4)
        #expect(Set([text.kind, shape.kind, clock.kind, quote.kind]) == [.text, .roundedRectangle, .systemClock, .liveQuote])

        controller.rehydrateFromEditor(persist: false)
        let stored = controller.inspector.props.first { $0.id == controller.editors.selectedDocumentID }?.elements ?? []
        #expect(stored.contains(where: { $0.kind == .text }))
        #expect(stored.contains(where: { $0.kind == .roundedRectangle }))
        #expect(stored.contains(where: { $0.kind == .systemClock }))
        #expect(stored.contains(where: { $0.kind == .liveQuote }))
    }

    @Test
    func fontCatalog_listsInstalledFamilies() {
        let fonts = SystemFontCatalog.menu(including: "Custom Display")
        #expect(fonts.contains("Helvetica"))
        #expect(fonts.contains("Custom Display"))
        #expect(fonts.count > SystemFontCatalog.fallbacks.count)
    }

    @Test @MainActor
    func handleDrag_defersDocumentNotificationUntilEnd() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        let engine = controller.editors
        let media = engine.addObject(.videoInput)
        engine.selectObject(media.id)
        var notifyCount = 0
        engine.onDocumentsChanged = { notifyCount += 1 }

        engine.beginHandleDrag(id: media.id, handle: .bottomRight)
        engine.updateHandleDrag(translationX: 40, translationY: 20)
        engine.updateHandleDrag(translationX: 80, translationY: 40)
        #expect(notifyCount == 0)

        engine.endHandleDrag()
        #expect(notifyCount == 1)
    }
}
