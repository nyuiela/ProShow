#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct PlaceholderMatrixTests {
    @Test
    func inspectorTabs_useShortLabels() {
        let titles = MapInspectorTab.allCases.map(\.shortTitle)
        #expect(titles == ["Source", "Layout", "Motion", "Macros"])
        #expect(titles.allSatisfy { $0.count <= 8 })
        #expect(Set(titles).count == titles.count)
    }

    @Test
    func remap_updatesPrimarySource() {
        var placeholder = PlaceholderConfiguration.catalog()[0]
        placeholder = PlaceholderMatrix.remap(placeholder, primarySourceId: "cam-fx3")
        #expect(placeholder.primarySourceId == "cam-fx3")
    }

    @Test
    func failover_firesAfterTimeout() {
        var placeholder = PlaceholderConfiguration.catalog()[0]
        placeholder.autoFailoverEnabled = true
        placeholder.failoverSourceId = "backup"
        placeholder.failoverTimeoutSeconds = 2
        let lost = Date(timeIntervalSince1970: 10)
        #expect(PlaceholderMatrix.shouldFailover(placeholder, lastFrameAt: lost, now: Date(timeIntervalSince1970: 12.1), alreadyFailed: false))
        #expect(PlaceholderMatrix.shouldFailover(placeholder, lastFrameAt: lost, now: Date(timeIntervalSince1970: 11), alreadyFailed: false) == false)
        #expect(PlaceholderMatrix.shouldFailover(placeholder, lastFrameAt: lost, now: Date(timeIntervalSince1970: 14), alreadyFailed: true) == false)
    }

    @Test
    func stateChange_emitsMacroEvents() {
        var placeholder = PlaceholderConfiguration.catalog()[2]
        let liveMacro = UUID()
        let clearMacro = UUID()
        placeholder.state = .inactiveStandby
        placeholder.onLiveMacroId = liveMacro
        placeholder.onClearMacroId = clearMacro
        let live = PlaceholderMatrix.applyState(placeholder, .activeLive)
        #expect(live.1 == .onLive)
        #expect(PlaceholderMatrix.macroID(for: live.0, event: .onLive) == liveMacro)
        let cleared = PlaceholderMatrix.applyState(live.0, .inactiveStandby)
        #expect(cleared.1 == .onClear)
    }

    @Test
    func serializesInStudioManifest() throws {
        var placeholder = PlaceholderConfiguration.catalog()[0]
        placeholder.primarySourceId = "sony-fx3"
        placeholder.onFailoverMacroId = UUID()
        let manifest = StudioManifest(
            scenes: [],
            soundboard: [],
            videoSources: [],
            audioChannels: [],
            activeSceneID: nil,
            placeholderMatrix: [placeholder]
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(StudioManifest.self, from: data)
        #expect(decoded.placeholderMatrix.first?.primarySourceId == "sony-fx3")
        #expect(decoded.placeholderMatrix.first?.onFailoverMacroId == placeholder.onFailoverMacroId)
    }

    @Test @MainActor
    func mute_placeholderAndProgramLayer_silencesPlayback() {
        let controller = TestSupport.sampleController()
        let media = TestSupport.mediaAction(title: "Loop")
        controller.compositor.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: controller.show.id,
                slideIndex: 0,
                layers: CueLayers(mediaAction: media)
            )
        )
        controller.inspector.bindMedia(media)
        #expect(controller.playback.isMuted == false)

        controller.toggleProgramLayerAudio(.media)
        #expect(controller.isProgramLayerAudioMuted(.media))
        #expect(controller.isProgramMediaMuted)
        #expect(controller.playback.isMuted)

        controller.toggleProgramLayerAudio(.media)
        #expect(controller.isProgramLayerAudioMuted(.media) == false)

        let id = controller.placeholderMatrix.placeholders[0].id
        controller.updatePlaceholder(id) { $0.audioMuted = true }
        controller.compositor.triggerCue(
            OutputCue(
                id: UUID(),
                presentationId: controller.show.id,
                slideIndex: 0,
                layers: CueLayers(
                    mediaAction: MediaAction(
                        id: UUID(),
                        title: "Placeholder A",
                        tintHex: "#111111",
                        isImage: false,
                        placeholderLetter: controller.placeholderMatrix.placeholders[0].letter
                    )
                )
            )
        )
        #expect(controller.isPlaceholderAudioMuted(controller.placeholderMatrix.placeholders[0].letter))
        controller.applyProgramAudioMute()
        #expect(controller.playback.isMuted)
    }

    @Test
    func engine_remapAndFailoverMacros() {
        let engine = PlaceholderMatrixEngine()
        let macro = UUID()
        engine.mutateSelected { $0.failoverSourceId = "backup"; $0.onFailoverMacroId = macro; $0.autoFailoverEnabled = true }
        _ = engine.remap(id: engine.selectedID ?? "", primarySourceId: "primary")
        #expect(engine.selected?.primarySourceId == "primary")
        engine.simulateSignalDrop(id: engine.selectedID ?? "")
        let fired = engine.evaluateFailover()
        #expect(fired == [macro])
        #expect(engine.lastFiredMacros[.onFailover] == macro)
    }

    @Test
    func transition_springAndCut() {
        let cut = PlaceholderTransitionEngine.frame(
            style: .cut,
            progress: 0,
            bounds: CGRect(x: 0, y: 0, width: 100, height: 50),
            entering: true
        )
        #expect(cut.opacity == 0)
        let spring = PlaceholderTransitionEngine.easedProgress(
            elapsed: 0.45,
            duration: 0.45,
            style: .springBounce,
            damping: 0.7
        )
        #expect(spring > 0.7)
        let fly = PlaceholderTransitionEngine.frame(
            style: .pushLeft,
            progress: 0,
            bounds: CGRect(x: 0, y: 0, width: 200, height: 100),
            entering: true
        )
        #expect(fly.offsetX == -200)
    }

    @Test @MainActor
    func controller_reroutesMappedSource() {
        let controller = TestSupport.sampleController()
        let camera = controller.videoInputs.sources.first
        #expect(camera != nil)
        if let camera {
            controller.placeholderMatrix.remap(id: "Placeholder A", primarySourceId: camera.id.uuidString)
            controller.reroutePlaceholder("Placeholder A")
            #expect(controller.placeholderBindings["A"]?.use == .camera)
            #expect(controller.placeholderBindings["A"]?.targetID == camera.id.uuidString)
        }
        let snapshot = controller.studioSnapshot()
        #expect(snapshot.placeholderMatrix.contains(where: { $0.id == "Placeholder A" }))
    }

    @Test @MainActor
    func mappedPlaceholder_fillsActivePropSlot() {
        let controller = TestSupport.sampleController()
        let media = MediaBinItem(
            title: "Mapped Clip",
            kind: .video(duration: "0:08"),
            tintHex: "#1B3A4B",
            source: .resources,
            filePath: "/tmp/mapped-clip.mp4"
        )
        controller.addMediaToSelectedCollection(media)
        var slot = CanvasObject(
            name: "Host Slot",
            kind: .rectangle,
            bounds: CanvasBounds(x: 80, y: 80, width: 640, height: 360),
            zIndex: 1,
            token: "A"
        )
        slot.applyAssignedSource(
            AssignedMediaSource(
                sourceID: "placeholder-A",
                name: "A",
                sourceType: .placeholderSlot,
                category: .placeholders,
                connectionString: "placeholder://A",
                tintHex: "#D8F5D0",
                placeholderLetter: "A"
            )
        )
        guard let propID = controller.inspector.props.first?.id else {
            Issue.record("Expected a seed prop")
            return
        }
        controller.inspector.setPropElements(id: propID, elements: [slot])
        _ = controller.toggleInspectorProp(id: propID)
        controller.bindPlaceholder(letter: "A", use: .media, targetID: media.id.uuidString, targetName: media.title)
        let canvas = controller.compositor.propCanvases.first(where: { $0.id == propID })
        #expect(canvas?.objects.first?.assignedSource?.isMappedFill == true)
        #expect(canvas?.objects.first?.assignedSource?.mediaItemID == media.id || canvas?.objects.first?.fill.imageURI == media.filePath)
        #expect(controller.resolvedAssignedSource(forPlaceholder: "A")?.sourceType == .mediaFile)
    }

    @Test @MainActor
    func sourceChoices_includeTintedDevicesAndMedia() {
        let controller = TestSupport.sampleController()
        let choices = controller.placeholderSourceChoices
        #expect(!choices.isEmpty)
        #expect(choices.contains { $0.group == .media && $0.tintHex.isEmpty == false })
        if let first = choices.first {
            #expect(!first.symbolName.isEmpty)
            #expect(!first.subtitle.isEmpty)
        }
    }
}
