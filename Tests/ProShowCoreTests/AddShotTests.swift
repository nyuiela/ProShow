#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

struct StubSourceEnumerator: SourceEnumerating {
    func videoDevices() -> [DiscoveredSourceItem] {
        [
            DiscoveredSourceItem(
                id: "cam-1",
                name: "Studio Camera",
                category: .videoCapture,
                groupName: "System Device",
                sourceType: .systemCamera,
                connectionString: "avf://studio"
            )
        ]
    }

    func audioDevices() -> [DiscoveredSourceItem] {
        [
            DiscoveredSourceItem(
                id: "mic-1",
                name: "Booth Mic",
                category: .audioCapture,
                groupName: "System Device",
                sourceType: .systemMicrophone,
                connectionString: "avf://mic"
            )
        ]
    }

    func screens() -> [DiscoveredSourceItem] { [] }
    func ndiSources() -> [DiscoveredSourceItem] { [] }
}

@Suite
struct AddShotTests {
    @Test
    func search_filtersAcrossNameAndGroup() {
        let item = DiscoveredSourceItem(
            id: "ndi-1",
            name: "KALEELS-MACBOOK-PRO.LOCAL",
            category: .network,
            groupName: "NDI™ Source",
            sourceType: .ndiSource
        )
        #expect(AddShotSearch.matches(item, query: "kaleel ndi"))
        #expect(!AddShotSearch.matches(item, query: "camera"))
    }

    @Test
    func screenShare_endpointsIdentifyDisplayAndWindow() {
        let display = ScreenShareCatalog.displayItem(id: 2, name: "Built-in Retina", width: 1920, height: 1080)
        #expect(display.sourceType == .systemDisplay)
        #expect(display.connectionString == "sck://display/2")
        #expect(display.groupName == "Displays")
        let window = ScreenShareCatalog.windowItem(id: 44, app: "Safari", title: "Inbox")
        #expect(window.sourceType == .systemWindow)
        #expect(window.connectionString == "sck://window/44")
        #expect(ScreenShareEndpoint.parse("sck://window/44")?.kind == .window)
        #expect(ScreenShareEndpoint.parse("sck://display/2")?.id == 2)
        #expect(ScreenShareEndpoint.parse("avf://cam") == nil)
    }

    @Test
    func screenCapture_keepsStartedAndIdleFrames() {
        #if canImport(ScreenCaptureKit)
        #expect(ScreenCaptureRouting.shouldPublishFrame(status: .complete, hasPixelBuffer: true))
        #expect(ScreenCaptureRouting.shouldPublishFrame(status: .started, hasPixelBuffer: true))
        #expect(ScreenCaptureRouting.shouldPublishFrame(status: .idle, hasPixelBuffer: true))
        #expect(!ScreenCaptureRouting.shouldPublishFrame(status: .blank, hasPixelBuffer: true))
        #expect(!ScreenCaptureRouting.shouldPublishFrame(status: nil, hasPixelBuffer: false))
        #expect(ScreenCaptureRouting.isFeedbackWindow(title: "ProShow Audience — House"))
        #expect(ScreenCaptureRouting.isFeedbackWindow(title: "ProShow Stage — Foldback"))
        #expect(ScreenCaptureRouting.isFeedbackWindow(title: "ProShow Stream"))
        #expect(ScreenCaptureRouting.isFeedbackWindow(title: "ProShow MultiViewer"))
        #expect(!ScreenCaptureRouting.isFeedbackWindow(title: "ProShow"))
        #endif
    }

    @Test @MainActor
    func refreshLiveHardware_asksAccessThenListsScreens() async {
        struct StubAccess: InputAccessRequesting {
            func requestCameraAccess() async -> Bool { true }
            func requestMicrophoneAccess() async -> Bool { true }
            func screenShareTargets() async -> [DiscoveredSourceItem] {
                [ScreenShareCatalog.displayItem(id: 7, name: "Studio LCD")]
            }
        }
        let enumerator = LiveSourceEnumerator()
        let manager = SourceDiscoveryManager(enumerator: enumerator, access: StubAccess())
        await manager.refreshLiveHardware()
        #expect(enumerator.includeExternalCameras)
        #expect(manager.groups(category: .screenCapture, query: "").flatMap(\.items).contains(where: { $0.connectionString == "sck://display/7" }))
        let first = enumerator.videoDevices()
        let second = enumerator.videoDevices()
        #expect(first.map(\.id) == second.map(\.id))
        enumerator.invalidateHardwareCache()
        _ = enumerator.videoDevices()
    }

    @Test
    func hardwareIdentity_isStablePerEndpoint() {
        let display = HardwareSourceIdentity.uuid(for: "sck://display/7")
        #expect(display == HardwareSourceIdentity.uuid(for: "sck://display/7"))
        #expect(display != HardwareSourceIdentity.uuid(for: "sck://window/7"))
        #expect(SourceType.systemDisplay.showsDevicePreview)
        #expect(SourceType.systemCamera.showsDevicePreview)
        #expect(!SourceType.solidColor.showsDevicePreview)
    }

    @Test @MainActor
    func addShot_displayGoesLiveOnVideoLayer() {
        let controller = TestSupport.sampleController()
        let item = ScreenShareCatalog.displayItem(id: 7, name: "Studio LCD")
        _ = controller.addShot(item, asCopy: false, layerIndex: 0)
        #expect(controller.compositor.stack.videoInput?.kind == .screenShare)
        #expect(controller.compositor.stack.videoInput?.endpoint == "sck://display/7")
        #expect(controller.compositor.stack.videoInput?.id == HardwareSourceIdentity.uuid(for: "sck://display/7"))
        #expect(controller.videoInputs.lastFrame?.backend == "screenCaptureKit")
    }

    @Test
    func modal_staysWithinCardBounds() {
        #expect(AddShotModalView.modalWidth <= AddShotModalView.modalMaxWidth)
        #expect(AddShotModalView.modalHeight <= AddShotModalView.modalMaxHeight)
        #expect(AddShotModalView.modalMaxWidth <= 880)
        #expect(AddShotModalView.modalMaxHeight <= 680)
    }

    @Test @MainActor
    func discovery_refreshUsesEnumeratorAndCategories() {
        let manager = SourceDiscoveryManager(enumerator: StubSourceEnumerator())
        #expect(manager.items.isEmpty)
        manager.refresh()
        #expect(manager.items.contains(where: { $0.id == "cam-1" }))
        #expect(manager.items.contains(where: { $0.id == "mic-1" }))
        let video = manager.groups(category: .videoCapture, query: "")
        #expect(video.contains(where: { $0.groupName == "System Device" }))
        #expect(video.allSatisfy { group in group.items.allSatisfy { $0.category == .videoCapture } })
        manager.toggleFavorite(id: "cam-1")
        let favorites = manager.groups(category: .favorites, query: "")
        #expect(favorites.flatMap(\.items).map(\.id) == ["cam-1"])
        let found = manager.groups(category: .all, query: "booth")
        #expect(found.flatMap(\.items).map(\.id) == ["mic-1"])
    }

    @Test @MainActor
    func addShot_insertsCopyOnTargetLayer() {
        let controller = TestSupport.sampleController()
        #expect(controller.masterLayers.count == 5)
        let source = DiscoveredSourceItem(
            id: "cam-1",
            name: "Studio Camera",
            category: .videoCapture,
            groupName: "System Device",
            sourceType: .systemCamera
        )
        let added = controller.addShot(source, asCopy: false, layerIndex: 2)
        #expect(controller.masterLayers[2].shots.map(\.id) == [added.id])
        let copy = controller.addShot(source, asCopy: true, layerIndex: 2)
        #expect(copy.isCopy)
        #expect(copy.name.contains("Copy"))
        #expect(controller.masterLayers[2].shots.count == 2)
        #expect(copy.source.id != source.id)
    }

    @Test
    func masterLayers_defaultTitles() {
        let layers = MasterLayer.defaults
        #expect(layers.map(\.title) == ["Main Layer 1", "Main Layer 2", "Main Layer 3", "Main Layer 4", "Main Layer 5"])
    }

    @Test @MainActor
    func discovery_includesPlaceholdersColorsLibraryAndShots() {
        let manager = SourceDiscoveryManager(enumerator: StubSourceEnumerator())
        let media = MediaBinItem(title: "Loop Bed", kind: .video(duration: "1:00.00"), tintHex: "#112233", source: .playlists)
        let collection = MediaCollection(name: "Program Media", source: .playlists, items: [media])
        let show = SampleContent.starterProgram().show
        let playlistItem = LibraryShowItem(title: "Hold", subtitle: "Hold Screens", isActive: true, showID: show.id)
        let existing = LayerShot(
            name: "Booth",
            source: DiscoveredSourceItem(
                id: "cam-1",
                name: "Studio Camera",
                category: .videoCapture,
                groupName: "System Device",
                sourceType: .systemCamera
            )
        )
        manager.refresh(
            mediaCollections: [collection],
            libraryShows: [show],
            playlistItems: [playlistItem],
            customColors: [SolidColorSwatch(id: "color-custom-1", name: "House Blue", hex: "#2244AA")],
            existingShots: [existing]
        )
        let letters = manager.groups(category: .placeholders, query: "").flatMap(\.items).map(\.name)
        #expect(letters == PlaceholderLetter.allCases.map(\.rawValue))
        let colors = manager.groups(category: .backgrounds, query: "").flatMap(\.items)
        #expect(colors.contains(where: { $0.name == "Stage Black" && $0.sourceType == .solidColor }))
        #expect(colors.contains(where: { $0.id == "color-custom-1" }))
        let mediaRows = manager.groups(category: .mediaFiles, query: "").flatMap(\.items)
        #expect(mediaRows.contains(where: { $0.name == "Loop Bed" && $0.groupName.contains("Program Media") }))
        #expect(mediaRows.contains(where: { $0.name == show.name && $0.sourceType == .libraryShow }))
        #expect(mediaRows.contains(where: { $0.name == "Hold" }))
        #expect(manager.groups(category: .shots, query: "").flatMap(\.items).map(\.name) == ["Studio Camera"])
    }

    @Test @MainActor
    func addShot_placeholderGoesLiveOnLayer() {
        let controller = TestSupport.sampleController()
        let source = DiscoveredSourceItem(
            id: "placeholder-A",
            name: "A",
            category: .placeholders,
            groupName: "Placeholders",
            sourceType: .placeholderSlot,
            connectionString: "placeholder://A",
            tintHex: "#D8F5D0"
        )
        let added = controller.addShot(source, asCopy: false, layerIndex: 0)
        #expect(controller.masterLayers[0].shots.map(\.id) == [added.id])
        #expect(controller.masterLayers[0].liveShotID == added.id)
        #expect(controller.compositor.stack.media?.placeholderLetter == "A")
        #expect(controller.allMediaItems.contains(where: { $0.title == "A" && $0.kind == .placeholder }))
    }

    @Test @MainActor
    func addShot_solidColorSetsBackground() {
        let controller = TestSupport.sampleController()
        let swatch = controller.addSolidColor(name: "House Blue", hex: "2244aa")
        #expect(swatch.hex == "#2244AA")
        #expect(controller.customSolidColors.map(\.name) == ["House Blue"])
        let source = DiscoveredSourceItem(
            id: swatch.id,
            name: swatch.name,
            category: .backgrounds,
            groupName: "Solid Colors",
            sourceType: .solidColor,
            connectionString: swatch.hex,
            tintHex: swatch.hex
        )
        _ = controller.addShot(source, asCopy: false, layerIndex: 1)
        #expect(controller.masterLayers[1].shots.count == 1)
        #expect(controller.compositor.stack.screenColorHex == "#2244AA")
    }

    @Test @MainActor
    func assignSource_mediaOntoSlideImage() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        let added = controller.editors.addObject(.image)
        let media = MediaBinItem(title: "Loop Bed", kind: .video(duration: "1:00.00"), tintHex: "#112233", source: .playlists)
        controller.addMediaToSelectedCollection(media)
        let source = DiscoveredSourceItem(
            id: "media-\(media.id.uuidString)",
            name: media.title,
            category: .mediaFiles,
            groupName: "Media Files",
            sourceType: .mediaFile,
            connectionString: media.filePath,
            tintHex: media.tintHex
        )
        controller.assignSourceToSelectedEditorObjects(source)
        let updated = controller.editors.selectedDocument?.objects.first(where: { $0.id == added.id })
        #expect(updated?.assignedSource?.name == "Loop Bed")
        #expect(updated?.name != "Loop Bed")
        #expect(updated?.text.isEmpty == true)
        #expect(updated?.assignedSource?.mediaItemID == media.id)
        #expect(updated?.fill.color == "#112233")
        #expect(controller.addShotPurpose == .addToLayer)
    }

    @Test @MainActor
    func assignSource_placeholderThenMedia_bindsSlot() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        _ = controller.editors.addObject(.image)
        let placeholder = DiscoveredSourceItem(
            id: "placeholder-A",
            name: "A",
            category: .placeholders,
            groupName: "Placeholders",
            sourceType: .placeholderSlot,
            connectionString: "placeholder://A",
            tintHex: "#D8F5D0"
        )
        controller.assignSourceToSelectedEditorObjects(placeholder)
        #expect(controller.editors.selectedObjects.first?.assignedPlaceholderLetter == "A")
        #expect(controller.editors.selectedObjects.first?.fill.color == "#D8F5D0")

        let media = MediaBinItem(title: "Wide Still", kind: .image, tintHex: "#445566", source: .resources)
        controller.addMediaToSelectedCollection(media)
        let file = DiscoveredSourceItem(
            id: "media-\(media.id.uuidString)",
            name: media.title,
            category: .mediaFiles,
            groupName: "Resources",
            sourceType: .mediaFile,
            tintHex: media.tintHex
        )
        controller.assignSourceToSelectedEditorObjects(file)
        #expect(controller.editors.selectedObjects.first?.assignedSource?.name == "Wide Still")
        #expect(controller.editors.selectedObjects.first?.assignedPlaceholderLetter == "A")
        #expect(controller.placeholderBindings["A"]?.use == .media)
        #expect(controller.placeholderBindings["A"]?.targetName == "Wide Still")
    }

    @Test @MainActor
    func assignSource_propKeepsKind() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.props)
        let added = controller.editors.addObject(.prop)
        let source = DiscoveredSourceItem(
            id: "media-logo",
            name: "Logo Bug",
            category: .mediaFiles,
            groupName: "Resources",
            sourceType: .mediaFile,
            tintHex: "#AABBCC"
        )
        controller.assignSourceToSelectedEditorObjects(source)
        let updated = controller.editors.selectedDocument?.objects.first(where: { $0.id == added.id })
        #expect(updated?.kind == .prop)
        #expect(updated?.assignedSource?.name == "Logo Bug")
        #expect(controller.inspector.props.contains(where: { prop in
            prop.elements.contains(where: { $0.assignedSource?.name == "Logo Bug" })
        }))
    }

    @Test @MainActor
    func assignCamera_addsShotOnMainLayer() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        _ = controller.editors.addObject(.image)
        controller.openAddShotToAssign()
        let before = controller.masterLayers[0].shots.count
        let camera = DiscoveredSourceItem(
            id: "avf-video-mac",
            name: "MacBook Camera",
            category: .videoCapture,
            groupName: "System Device",
            sourceType: .systemCamera,
            connectionString: "avf://mac-cam"
        )
        controller.completeAddShot(camera, asCopy: false)
        #expect(controller.masterLayers[0].shots.count == before + 1)
        #expect(controller.masterLayers[0].shots.contains(where: { $0.source.connectionString == "avf://mac-cam" }))
        #expect(controller.masterLayers[0].liveShotID != nil)
        #expect(controller.editors.selectedObjects.first?.assignedSource?.sourceType == .systemCamera)
        #expect(controller.compositor.stack.videoInput?.endpoint == "avf://mac-cam")
    }

    @Test @MainActor
    func takeShotLive_again_doesNotRestartHardware() {
        let controller = TestSupport.sampleController()
        controller.enableLiveIO()
        let camera = DiscoveredSourceItem(
            id: "avf-video-mac",
            name: "MacBook Camera",
            category: .videoCapture,
            groupName: "System Device",
            sourceType: .systemCamera,
            connectionString: "avf://mac-cam"
        )
        let shot = controller.addShot(camera, asCopy: false, layerIndex: 0)
        let starts = controller.videoInputs.ingest.hardwareStartCount
        controller.takeShotLive(shot, layerIndex: 0)
        controller.takeShotLive(shot, layerIndex: 0)
        #expect(controller.videoInputs.ingest.hardwareStartCount == starts)
        #expect(controller.masterLayers[0].liveShotID == shot.id)
    }

    @Test @MainActor
    func takeShotLive_sameCameraNewUniqueID_doesNotRestartHardware() {
        let controller = TestSupport.sampleController()
        controller.enableLiveIO()
        let first = DiscoveredSourceItem(
            id: "avf-video-legacy",
            name: "MacBook Pro Camera",
            category: .videoCapture,
            groupName: "System Device",
            sourceType: .systemCamera,
            connectionString: "avf://legacy-uuid"
        )
        let shot = controller.addShot(first, asCopy: false, layerIndex: 0)
        let starts = controller.videoInputs.ingest.hardwareStartCount
        let resent = DiscoveredSourceItem(
            id: "avf-video-new",
            name: "MacBook Pro Camera",
            category: .videoCapture,
            groupName: "System Device",
            sourceType: .systemCamera,
            connectionString: "avf://new-style-uuid"
        )
        let again = controller.addShot(resent, asCopy: false, layerIndex: 0)
        #expect(controller.videoInputs.ingest.hardwareStartCount == starts)
        #expect(controller.videoInputs.hasLiveCamera(
            endpoint: "avf://new-style-uuid",
            sourceID: resent.id,
            name: resent.name
        ))
        #expect(controller.masterLayers[0].shots.count == 1)
        #expect(controller.masterLayers[0].liveShotID == shot.id)
        #expect(again.id == shot.id)
        #expect(controller.masterLayers[0].shots[0].source.connectionString == "avf://new-style-uuid")
    }

    @Test @MainActor
    func addShot_sameCameraEndpoint_doesNotDuplicateRow() {
        let controller = TestSupport.sampleController()
        controller.enableLiveIO()
        let camera = DiscoveredSourceItem(
            id: "avf-video-a",
            name: "FaceTime HD Camera",
            category: .videoCapture,
            groupName: "System Device",
            sourceType: .systemCamera,
            connectionString: "avf://mac-cam"
        )
        _ = controller.addShot(camera, asCopy: false, layerIndex: 0)
        _ = controller.addShot(camera, asCopy: false, layerIndex: 0)
        #expect(controller.masterLayers[0].shots.count == 1)
    }

    @Test @MainActor
    func goLive_slideWithDisplayMedia_addsShotOnMainLayer() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        _ = controller.editors.addObject(.image)
        let display = DiscoveredSourceItem(
            id: "sck-display-1",
            name: "Entire Display — Built-in",
            category: .screenCapture,
            groupName: "Displays",
            sourceType: .systemDisplay,
            connectionString: "sck://display/1"
        )
        controller.assignSourceToSelectedEditorObjects(display)
        for shot in controller.masterLayers[0].shots {
            controller.removeShot(shot.id, layerIndex: 0)
        }
        #expect(controller.masterLayers[0].shots.isEmpty)
        let slideID = controller.editors.selectedDocument?.slideID ?? controller.selectedSlideID
        controller.goLive(slideID: slideID)
        #expect(controller.masterLayers[0].shots.contains(where: { $0.source.connectionString == "sck://display/1" }))
        #expect(controller.masterLayers[0].liveShotID != nil)
        #expect(controller.compositor.stack.videoInput?.endpoint == "sck://display/1")
    }

    @Test @MainActor
    func completeAddShot_assignModeDoesNotAddLayerShot() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        _ = controller.editors.addObject(.image)
        controller.openAddShotToAssign()
        #expect(controller.addShotPurpose == .assignToSelectedObjects)
        let before = controller.masterLayers[0].shots.count
        let source = DiscoveredSourceItem(
            id: "placeholder-B",
            name: "B",
            category: .placeholders,
            groupName: "Placeholders",
            sourceType: .placeholderSlot,
            connectionString: "placeholder://B",
            tintHex: "#FFD6E0"
        )
        controller.completeAddShot(source, asCopy: false)
        #expect(controller.masterLayers[0].shots.count == before)
        #expect(controller.isAddShotOpen == false)
        #expect(controller.addShotPurpose == .addToLayer)
        #expect(controller.editors.selectedObjects.first?.assignedPlaceholderLetter == "B")
    }

    @Test
    func assignedMediaSource_roundTripsOnCanvasObject() throws {
        var object = CanvasObject(name: "Image", kind: .image, bounds: .centered(width: 200, height: 100))
        object.applyAssignedSource(
            AssignedMediaSource(
                sourceID: "media-1",
                name: "Loop",
                sourceType: .mediaFile,
                category: .mediaFiles,
                connectionString: "/tmp/loop.mp4",
                tintHex: "#111111",
                mediaItemID: UUID()
            )
        )
        let data = try JSONEncoder().encode(object)
        let decoded = try JSONDecoder().decode(CanvasObject.self, from: data)
        #expect(decoded.assignedSource?.name == "Loop")
        #expect(decoded.fill.type == .image)
        #expect(decoded.fill.imageURI == "/tmp/loop.mp4")
    }

    @Test @MainActor
    func mapSource_replacesPlaceholderOnSlidesAndLayers() throws {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        _ = controller.editors.addObject(.image)
        let placeholder = DiscoveredSourceItem(
            id: "placeholder-A",
            name: "A",
            category: .placeholders,
            groupName: "Placeholders",
            sourceType: .placeholderSlot,
            connectionString: "placeholder://A",
            tintHex: "#D8F5D0"
        )
        controller.assignSourceToSelectedEditorObjects(placeholder)
        let objectID = controller.editors.selectedObjects.first?.id
        #expect(controller.editors.selectedObjects.first?.assignedPlaceholderLetter == "A")
        #expect(controller.editors.selectedObjects.first?.fill.type == .color)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = try TestSupport.writePNGFixture(in: folder, name: "wide.png")
        let media = MediaBinItem(title: "Wide Still", kind: .image, tintHex: "#445566", source: .resources, filePath: url.path)
        controller.addMediaToSelectedCollection(media)
        controller.applyNodeRouting(.mapSource(sourceId: media.id.uuidString, placeholderID: "Placeholder A"))
        let updated = controller.editors.selectedDocument?.objects.first(where: { $0.id == objectID })
        #expect(updated?.assignedSource?.name == "Wide Still")
        #expect(updated?.assignedPlaceholderLetter == "A")
        #expect(updated?.fill.type == .image)
        #expect(updated?.fill.imageURI == url.path)
        #expect(controller.placeholderBindings["A"]?.use == .media)
        #expect(controller.show.allSlides.contains(where: { slide in
            slide.canvas.contains(where: { $0.id == objectID && $0.fill.imageURI == url.path })
        }))

        let layerIndex = controller.masterLayers[0].index
        let mediaBefore = controller.compositor.stack.media?.title
        controller.applyNodeRouting(.mapLayer(placeholderID: "Placeholder A", layerIndex: layerIndex))
        #expect(controller.masterLayers[0].shots.contains(where: { $0.source.placeholderLetter == "A" }))
        #expect(controller.compositor.stack.media?.title == mediaBefore)
        #expect(controller.compositor.stack.media?.title != "Wide Still")
    }

    @Test @MainActor
    func mapSource_cameraFillsSlotWithoutTakingProgram() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        _ = controller.editors.addObject(.image)
        let placeholder = DiscoveredSourceItem(
            id: "placeholder-A",
            name: "A",
            category: .placeholders,
            groupName: "Placeholders",
            sourceType: .placeholderSlot,
            connectionString: "placeholder://A",
            tintHex: "#D8F5D0"
        )
        controller.assignSourceToSelectedEditorObjects(placeholder)
        let objectID = controller.editors.selectedObjects.first?.id
        guard let camera = controller.videoInputs.sources.first else {
            #expect(Bool(false))
            return
        }
        let mediaBefore = controller.compositor.stack.media?.title
        controller.applyNodeRouting(.mapSource(sourceId: camera.id.uuidString, placeholderID: "Placeholder A"))
        let updated = controller.editors.selectedDocument?.objects.first(where: { $0.id == objectID })
        #expect(updated?.assignedSource?.sourceType == .systemCamera || updated?.assignedSource?.sourceType == .ndiSource)
        #expect(updated?.assignedPlaceholderLetter == "A")
        #expect(updated?.kind == .videoInput)
        #expect(controller.placeholderBindings["A"]?.use == .camera)
        #expect(controller.compositor.stack.videoInput?.id != camera.id)
        #expect(controller.compositor.stack.media?.title == mediaBefore)
        #expect(controller.resolvedAssignedSource(forPlaceholder: "A")?.name == camera.label)
    }

    @Test @MainActor
    func mapSource_videoFileFillsSlotWithoutPlayingProgram() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.presentation)
        _ = controller.editors.addObject(.image)
        let placeholder = DiscoveredSourceItem(
            id: "placeholder-B",
            name: "B",
            category: .placeholders,
            groupName: "Placeholders",
            sourceType: .placeholderSlot,
            connectionString: "placeholder://B",
            tintHex: "#FFD6E0"
        )
        controller.assignSourceToSelectedEditorObjects(placeholder)
        let objectID = controller.editors.selectedObjects.first?.id
        let clip = MediaBinItem(
            title: "Talking Head",
            kind: .video(duration: "0:12"),
            tintHex: "#223344",
            source: .resources,
            filePath: "/tmp/talking-head.mp4"
        )
        controller.addMediaToSelectedCollection(clip)
        let mediaBefore = controller.compositor.stack.media?.title
        controller.applyNodeRouting(.mapSource(sourceId: clip.id.uuidString, placeholderID: "Placeholder B"))
        let updated = controller.editors.selectedDocument?.objects.first(where: { $0.id == objectID })
        #expect(updated?.assignedSource?.name == "Talking Head")
        #expect(updated?.assignedPlaceholderLetter == "B")
        #expect(updated?.fill.imageURI == "/tmp/talking-head.mp4")
        #expect(controller.compositor.stack.media?.title == mediaBefore)
        #expect(controller.compositor.stack.media?.title != "Talking Head")
        #expect(updated?.assignedSource?.looksLikeVideo == true)
        #expect(AssignedMediaSource.pathLooksLikeVideo("/tmp/talking-head.mp4"))
        #expect(AssignedMediaSource.pathLooksLikeVideo("/tmp/still.png") == false)
    }

    @Test @MainActor
    func placeholder_mappingOverridesLetterCard() {
        let controller = TestSupport.sampleController()
        controller.bindPlaceholder(letter: "A", use: .prop, targetName: "Logo Bug")
        let source = DiscoveredSourceItem(
            id: "placeholder-A",
            name: "A",
            category: .placeholders,
            groupName: "Placeholders",
            sourceType: .placeholderSlot,
            connectionString: "placeholder://A",
            tintHex: "#D8F5D0"
        )
        _ = controller.addShot(source, asCopy: false)
        #expect(controller.placeholderBindings["A"]?.use == .prop)
        #expect(controller.compositor.stack.activeProps.contains("Logo Bug"))
        #expect(controller.compositor.stack.media?.placeholderLetter == nil)
    }
}
