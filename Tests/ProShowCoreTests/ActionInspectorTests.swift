#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreGraphics
import Foundation
import Testing

@Suite
struct ActionInspectorTests {
    @Test @MainActor
    func programLayer_soloHidesOthersAndRestores() {
        let controller = TestSupport.sampleController()
        controller.goLive(slideID: controller.show.allSlides[0].id)
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        #expect(!controller.compositor.stack.isCleared(.slide))
        #expect(!controller.compositor.stack.isCleared(.media))
        controller.soloProgramLayer(.media)
        #expect(controller.soloedProgramLayer == .media)
        #expect(!controller.compositor.stack.isCleared(.media))
        #expect(controller.compositor.stack.isCleared(.slide))
        #expect(controller.compositor.stack.media != nil)
        controller.soloProgramLayer(.media)
        #expect(controller.soloedProgramLayer == nil)
        #expect(!controller.compositor.stack.isCleared(.slide))
        #expect(!controller.compositor.stack.isCleared(.media))
    }

    @Test @MainActor
    func programLayer_emptyRemovesContentKeepsVisibility() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        #expect(controller.compositor.stack.media != nil)
        #expect(RenderLayer.media.hasContent(in: controller.compositor.stack))
        controller.emptyProgramLayer(.media)
        #expect(controller.compositor.stack.media == nil)
        #expect(!controller.compositor.stack.isCleared(.media))
        #expect(!RenderLayer.media.hasContent(in: controller.compositor.stack))
    }

    @Test @MainActor
    func masterLayer_renameClearLiveAndRemoveShot() {
        let controller = TestSupport.sampleController()
        let source = DiscoveredSourceItem(
            id: "cam-layer",
            name: "Studio Camera",
            category: .videoCapture,
            groupName: "System Device",
            sourceType: .systemCamera,
            connectionString: "avf://studio"
        )
        let shot = controller.addShot(source, asCopy: false, layerIndex: 1)
        #expect(controller.masterLayers[1].liveShotID == shot.id)
        controller.renameMasterLayer(at: 1, to: "Cameras")
        #expect(controller.masterLayers[1].title == "Cameras")
        controller.clearLiveShot(layerIndex: 1)
        #expect(controller.masterLayers[1].liveShotID == nil)
        #expect(controller.masterLayers[1].shots.contains(where: { $0.id == shot.id }))
        controller.removeShot(shot.id, layerIndex: 1)
        #expect(!controller.masterLayers[1].shots.contains(where: { $0.id == shot.id }))
    }

    @Test
    func layersTab_isFirstBeforeAudio() {
        #expect(ActionInspectorTab.allCases.first == .layers)
        #expect(ActionInspectorTab.allCases.dropFirst().first == .audio)
        #expect(RenderLayer.allCases.count == 8)
        #expect(RenderLayer.screenColor.title == "Screen")
        #expect(MasterLayer.defaults.count == 5)
    }

    @Test
    func messageTokens_resolveDynamicValues() {
        let message = ProShowMessage(
            title: "Desk Call",
            templateText: "{Name} to the desk — {Custom Text}",
            dynamicValues: ["Number": "1", "Name": "Lee", "Custom Text": "stand by"]
        )
        #expect(message.resolvedText() == "Lee to the desk — stand by")
        let withTime = MessageTokenParser.resolve("Starts at {Time}", values: ["Time": "11:30 AM"])
        #expect(withTime == "Starts at 11:30 AM")
    }

    @Test @MainActor
    func propToggle_updatesLayer6() {
        let controller = TestSupport.sampleController()
        #expect(controller.toggleInspectorProp(id: ActionSeedID.logoProp))
        #expect(controller.compositor.stack.activeProps.contains("Logo Bug"))
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.logoProp && $0.isActive }))
        #expect(controller.inspector.selectedPropID == ActionSeedID.logoProp)
        #expect(!controller.compositor.stack.isCleared(.props))
        #expect(controller.toggleInspectorProp(id: ActionSeedID.logoProp))
        #expect(controller.compositor.stack.activeProps.isEmpty)
    }

    @Test @MainActor
    func messageShowHide_updatesLayer7() {
        let controller = TestSupport.sampleController()
        #expect(controller.showInspectorMessage(id: ActionSeedID.deskCallMessage))
        #expect(controller.compositor.stack.message?.contains("Operator") == true)
        #expect(!controller.compositor.stack.isCleared(.messages))
        controller.hideInspectorMessage(id: ActionSeedID.deskCallMessage)
        #expect(controller.compositor.stack.message == nil)
        #expect(controller.compositor.stack.isCleared(.messages))
    }

    @Test @MainActor
    func clearStrip_clearsIndependentLayers() {
        let controller = TestSupport.sampleController()
        controller.goLive(slideID: controller.show.allSlides[0].id)
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        _ = controller.toggleInspectorProp(id: ActionSeedID.logoProp)
        _ = controller.showInspectorMessage(id: ActionSeedID.deskCallMessage)
        #expect(controller.clearLayer(named: "media"))
        #expect(controller.compositor.stack.isCleared(.media))
        #expect(controller.compositor.stack.media != nil)
        #expect(controller.compositor.stack.message?.isEmpty == false)
        #expect(controller.compositor.stack.activeProps.contains("Logo Bug"))
        #expect(controller.clearLayer(named: "props"))
        #expect(controller.compositor.stack.activeProps.contains("Logo Bug"))
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.logoProp && $0.isActive }))
        #expect(controller.compositor.stack.isCleared(.props))
        #expect(controller.clearLayer(named: "messages"))
        #expect(controller.compositor.stack.message?.isEmpty == false)
        #expect(controller.inspector.messages.contains(where: { $0.isActive }))
        #expect(controller.compositor.stack.isCleared(.messages))
        #expect(controller.clearLayer(named: "slide"))
        #expect(controller.compositor.stack.isCleared(.slide))
        #expect(controller.compositor.stack.slideElements.isEmpty == false || controller.compositor.stack.slideCanvas.isEmpty == false)
        #expect(controller.clearLayer(named: "audio"))
        #expect(controller.compositor.stack.audioMuted)
        #expect(controller.audioIO.programMuted)
        #expect(controller.clearLayer(named: "media"))
        #expect(!controller.compositor.stack.isCleared(.media))
        #expect(controller.compositor.stack.media != nil)
    }

    @Test @MainActor
    func clearAll_clearsEightLayers() {
        let controller = TestSupport.sampleController()
        controller.goLive(slideID: controller.show.allSlides[0].id)
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        _ = controller.toggleInspectorProp(id: ActionSeedID.logoProp)
        #expect(controller.clearLayer(named: "all"))
        for layer in RenderLayer.allCases {
            #expect(controller.compositor.stack.isCleared(layer))
        }
        #expect(controller.compositor.stack.audioMuted)
        #expect(controller.compositor.stack.media != nil)
        #expect(controller.compositor.stack.activeProps.contains("Logo Bug"))
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.logoProp && $0.isActive }))
        #expect(controller.clearLayer(named: "all"))
        for layer in RenderLayer.allCases {
            #expect(!controller.compositor.stack.isCleared(layer))
        }
        #expect(!controller.compositor.stack.audioMuted)
        #expect(controller.compositor.stack.media != nil)
    }

    @Test @MainActor
    func props_canRenameDuplicateAndEdit() {
        let controller = TestSupport.sampleController()
        #expect(controller.inspector.renameProp(id: ActionSeedID.logoProp, to: "Corner Logo"))
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.logoProp && $0.name == "Corner Logo" }))
        let copy = controller.inspector.duplicateProp(id: ActionSeedID.logoProp)
        #expect(copy?.name == "Corner Logo Copy")
        #expect(controller.inspector.props.count == 3)
        controller.editProp(id: ActionSeedID.logoProp)
        #expect(controller.editors.kind == .props)
        #expect(controller.editors.selectedDocumentID == ActionSeedID.logoProp)
        #expect(controller.inspector.deleteProp(id: copy?.id ?? UUID()))
        #expect(controller.inspector.props.count == 2)
    }

    @Test @MainActor
    func sermonMacro_executesSequentialActions() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        let audienceLook = controller.compositor.stack.look.name
        #expect(controller.executeInspectorMacro(id: ActionSeedID.sermonMacro))
        #expect(controller.compositor.stack.isCleared(.media))
        #expect(controller.compositor.stack.stageLook == StageLayoutPreset.notesOnly.look)
        #expect(controller.compositor.stack.look.name == audienceLook)
        #expect(controller.compositor.stack.audio?.title == "Hold Bed")
    }

    @Test @MainActor
    func showStartMacro_enablesPropAndTimer() {
        let controller = TestSupport.sampleController()
        #expect(controller.executeInspectorMacro(id: ActionSeedID.showStartMacro))
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.logoProp && $0.isActive }))
        #expect(controller.inspector.timers.contains(where: { $0.id == ActionSeedID.serviceTimer && $0.isRunning }))
        #expect(controller.scenes.activeSceneID == StudioSeedID.solo)
        #expect(controller.compositor.stack.activeProps.contains("Logo Bug"))
    }

    @Test @MainActor
    func streamEndMacro_clearsAllAndStopsStream() {
        let controller = TestSupport.sampleController()
        controller.goLive(slideID: controller.show.allSlides[0].id)
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        #expect(controller.executeInspectorMacro(id: ActionSeedID.streamEndMacro))
        #expect(controller.compositor.stack.isCleared(.slide))
        #expect(controller.compositor.stack.isCleared(.media))
        #expect(controller.compositor.stack.audioMuted)
        #expect(controller.streaming.state == .idle)
    }

    @Test @MainActor
    func hideLayer_doesNotPauseMediaTransport() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        controller.inspector.seekTransport(to: 20)
        #expect(controller.inspector.transport.isPlaying)
        #expect(controller.playback.isPlaying)
        controller.hideLayer(.media)
        #expect(controller.compositor.stack.isCleared(.media))
        #expect(controller.compositor.stack.media != nil)
        #expect(controller.inspector.transport.isPlaying)
        #expect(controller.playback.isPlaying)
        #expect(controller.isProgramMediaMuted)
        controller.restoreLayer(.media)
        #expect(!controller.compositor.stack.isCleared(.media))
        #expect(controller.inspector.transport.isPlaying)
        #expect(controller.playback.isPlaying)
        #expect(!controller.compositor.stack.isCleared(.media))
    }

    @Test @MainActor
    func transport_skipLoopAndMarkers() {
        let controller = TestSupport.sampleController()
        controller.triggerMedia(DeskSampleData.mediaBin[0])
        #expect(controller.inspector.transport.duration == 300)
        controller.inspector.seekTransport(to: 20)
        controller.inspector.skipTransport(seconds: -15)
        #expect(abs(controller.inspector.transport.playhead - 5) < 0.01)
        controller.inspector.skipTransport(seconds: 15)
        #expect(abs(controller.inspector.transport.playhead - 20) < 0.01)
        controller.inspector.jumpToNextMarker()
        #expect(controller.inspector.transport.playhead == 150)
    }

    @Test @MainActor
    func timer_countdownOverrunAndReset() {
        let engine = ActionInspectorEngine()
        engine.install(nil)
        let id = ActionSeedID.serviceTimer
        engine.timers[0].remainingSeconds = 90
        engine.timers[0].overrunThresholdSeconds = 120
        #expect(engine.startTimer(id: id))
        let start = Date()
        engine.tick(now: start)
        engine.tick(now: start.addingTimeInterval(2))
        #expect(engine.timers[0].remainingSeconds == 88)
        #expect(engine.timers[0].isOverrun)
        #expect(engine.resetTimer(id: id))
        #expect(engine.timers[0].remainingSeconds == 900)
        #expect(engine.timers[0].isRunning == false)
        #expect(engine.setTimerDuration(id: id, seconds: 45))
        #expect(engine.timers[0].durationSeconds == 45)
        #expect(engine.timers[0].remainingSeconds == 45)
        #expect(engine.setTimerKind(id: id, kind: .elapsed))
        #expect(engine.timers[0].kind == .elapsed)
    }

    @Test @MainActor
    func timer_countsThroughHighFrequencyTicks() {
        let engine = ActionInspectorEngine()
        engine.install(nil)
        let id = ActionSeedID.serviceTimer
        engine.timers[0].remainingSeconds = 10
        #expect(engine.startTimer(id: id))
        let start = Date()
        for frame in 0..<45 {
            engine.tick(now: start.addingTimeInterval(Double(frame) / 30.0))
        }
        #expect(engine.timers[0].remainingSeconds == 9)
        #expect(engine.timers[0].isRunning)
        #expect(engine.setTimerDuration(id: id, seconds: 30))
        #expect(engine.timers[0].remainingSeconds == 30)
    }

    @Test @MainActor
    func stageLayout_doesNotChangeAudienceLook() {
        let controller = TestSupport.sampleController()
        let audience = controller.compositor.stack.look.name
        controller.applyStageLayout(id: ActionSeedID.layoutNotes)
        #expect(controller.compositor.stack.look.name == audience)
        #expect(controller.compositor.stack.stageLook.showNotes)
        #expect(controller.compositor.stack.stageLook.showCurrent == false)
    }

    @Test @MainActor
    func propTakeLive_playsBuildInIndependentOfSlideClock() {
        let controller = TestSupport.sampleController()
        let slideStart = Date(timeIntervalSince1970: 1_000)
        controller.goLive(slideID: controller.show.allSlides[0].id)
        controller.resetLiveBuildClock(at: slideStart)

        var logo = controller.inspector.props.first(where: { $0.id == ActionSeedID.logoProp })
        #expect(logo != nil)
        var badge = logo!.elements[0]
        badge.build = ElementBuildAnimation(inEffect: .none, outEffect: .none)
        badge.buildSteps = [
            ElementBuildStep(
                elementId: badge.id,
                phase: .buildIn,
                effect: .fade,
                trigger: .onSlideEnter,
                durationSeconds: 0.4,
                easing: .linear
            )
        ]
        controller.inspector.setPropElements(id: ActionSeedID.logoProp, elements: [badge])

        let take = Date(timeIntervalSince1970: 1_030)
        #expect(controller.toggleInspectorProp(id: ActionSeedID.logoProp, at: take))
        #expect(controller.propBuildStartedAt[ActionSeedID.logoProp] == take)
        #expect(abs(take.timeIntervalSince(slideStart) - 30) < 0.001)

        let canvas = controller.compositor.propCanvases.first(where: { $0.id == ActionSeedID.logoProp })
        #expect(canvas?.buildStartedAt == take)
        #expect(canvas?.buildPhases == [.buildIn, .action])

        let start = BuildAnimationEngine.evaluateState(
            elementId: badge.id,
            buildSteps: BuildAnimationEngine.filterSteps(badge.resolvedBuildSteps, including: [.buildIn, .action]),
            playback: canvas!.buildClock().playback(now: take),
            elementBounds: CGRect(x: 0, y: 0, width: 200, height: 80),
            textWidth: nil
        )
        let mid = BuildAnimationEngine.evaluateState(
            elementId: badge.id,
            buildSteps: BuildAnimationEngine.filterSteps(badge.resolvedBuildSteps, including: [.buildIn, .action]),
            playback: canvas!.buildClock().playback(now: take.addingTimeInterval(0.2)),
            elementBounds: CGRect(x: 0, y: 0, width: 200, height: 80),
            textWidth: nil
        )
        let done = BuildAnimationEngine.evaluateState(
            elementId: badge.id,
            buildSteps: BuildAnimationEngine.filterSteps(badge.resolvedBuildSteps, including: [.buildIn, .action]),
            playback: canvas!.buildClock().playback(now: take.addingTimeInterval(0.4)),
            elementBounds: CGRect(x: 0, y: 0, width: 200, height: 80),
            textWidth: nil
        )
        #expect(start.opacity == 0)
        #expect(abs(mid.opacity - 0.5) < 0.0001)
        #expect(abs(done.opacity - 1) < 0.0001)
        #expect(done.isVisible)
    }

    @Test @MainActor
    func propClear_playsAuthoredBuildOutThenRemoves() {
        let controller = TestSupport.sampleController()
        var logo = controller.inspector.props.first(where: { $0.id == ActionSeedID.logoProp })
        #expect(logo != nil)
        var badge = logo!.elements[0]
        badge.build = ElementBuildAnimation(inEffect: .none, outEffect: .none)
        badge.buildSteps = [
            ElementBuildStep(
                elementId: badge.id,
                phase: .buildIn,
                effect: .fade,
                trigger: .onSlideEnter,
                durationSeconds: 0.2,
                easing: .linear
            ),
            ElementBuildStep(
                elementId: badge.id,
                phase: .buildOut,
                effect: .fade,
                trigger: .afterPrevious,
                sequenceOrder: 2,
                durationSeconds: 0.5,
                easing: .linear
            )
        ]
        controller.inspector.setPropElements(id: ActionSeedID.logoProp, elements: [badge])

        let take = Date(timeIntervalSince1970: 2_000)
        #expect(controller.toggleInspectorProp(id: ActionSeedID.logoProp, at: take))
        let clear = take.addingTimeInterval(3)
        #expect(controller.toggleInspectorProp(id: ActionSeedID.logoProp, at: clear))
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.logoProp && !$0.isActive }))
        #expect(controller.compositor.stack.activeProps.contains("Logo Bug"))
        #expect(controller.propBuildClearStartedAt[ActionSeedID.logoProp] == clear)

        let canvas = controller.compositor.propCanvases.first(where: { $0.id == ActionSeedID.logoProp })
        #expect(canvas?.isClearing == true)
        let outgoing = BuildAnimationEngine.evaluateState(
            elementId: badge.id,
            buildSteps: BuildAnimationEngine.filterSteps(badge.resolvedBuildSteps, including: [.buildOut]),
            playback: canvas!.buildClock().playback(now: clear.addingTimeInterval(0.25)),
            elementBounds: CGRect(x: 0, y: 0, width: 200, height: 80),
            textWidth: nil
        )
        #expect(outgoing.isVisible)
        #expect(abs(outgoing.opacity - 0.5) < 0.0001)

        controller.tickPropBuildClears(now: clear.addingTimeInterval(0.5))
        #expect(controller.compositor.stack.activeProps.isEmpty)
        #expect(controller.propBuildClearStartedAt[ActionSeedID.logoProp] == nil)
    }

    @Test @MainActor
    func autoClear_onNextSlideDeactivatesProp() {
        let controller = TestSupport.sampleController()
        #expect(controller.toggleInspectorProp(id: ActionSeedID.alertProp))
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.alertProp && $0.isActive }))
        controller.goLive(slideID: controller.show.allSlides[0].id)
        #expect(controller.inspector.props.contains(where: { $0.id == ActionSeedID.alertProp && !$0.isActive }))
        #expect(!controller.compositor.stack.activeProps.contains("Emergency Alert Message"))
    }

    @Test @MainActor
    func propsEditor_mutationsUpdateSamePropInsteadOfCloning() {
        let controller = TestSupport.sampleController()
        let start = controller.inspector.props.count
        controller.openEditor(.props)
        let created = controller.editors.addDocument(named: "Lower Third")
        #expect(controller.inspector.props.contains(where: { $0.id == created.id }))
        #expect(controller.inspector.props.count == start + 1)
        _ = controller.editors.addObject(.text)
        _ = controller.editors.addObject(.roundedRectangle)
        _ = controller.editors.addObject(.systemClock)
        #expect(controller.inspector.props.count == start + 1)
        let stored = controller.inspector.props.first { $0.id == created.id }
        #expect(stored?.elements.count == 3)
        #expect(stored?.name == "Lower Third")
    }

    @Test @MainActor
    func propsEditor_collapsesBuildHistoryClones() {
        let controller = TestSupport.sampleController()
        let first = controller.addEditableProp(named: "WIP Card")
        for count in 1...6 {
            controller.inspector.props.append(
                ProShowProp(
                    name: "WIP Card",
                    elements: Array(
                        repeating: CanvasObject(
                            name: "Step \(count)",
                            kind: .text,
                            bounds: CanvasBounds(x: 80, y: 80, width: 400, height: 120)
                        ),
                        count: count
                    )
                )
            )
        }
        #expect(controller.inspector.props.filter { $0.name == "WIP Card" }.count == 7)
        controller.openEditor(.props)
        let remaining = controller.inspector.props.filter { $0.name == "WIP Card" }
        #expect(remaining.count == 1)
        #expect(remaining.first?.elements.count == 6)
        #expect(remaining.first?.id != first.id)
        #expect(controller.editors.documents.filter { $0.name == "WIP Card" }.count == 1)
    }

    @Test @MainActor
    func propsEditor_rehydratePersistsCatalogWithoutSlideChanges() {
        let controller = TestSupport.sampleController()
        controller.openEditor(.props)
        let created = controller.editors.addDocument(named: "Persistent Lower")
        _ = controller.editors.addObject(.text)
        let beforeShow = controller.show
        controller.rehydrateFromEditor(persist: true)
        #expect(controller.show.id == beforeShow.id)
        #expect(controller.inspector.props.contains(where: { $0.id == created.id && $0.elements.contains(where: { $0.kind == .text }) }))
        #expect(controller.studioSnapshot().inspector?.props.contains(where: { $0.id == created.id }) == true)
    }

    @Test @MainActor
    func countdown_startAndResetFollowBuildTriggers() {
        let controller = TestSupport.sampleController()
        let slideID = controller.show.allSlides[0].id
        controller.openInEditor(slideId: slideID)
        let countdown = controller.editors.addObject(.timerCountdown)
        controller.finishAddingLiveObject(countdown)
        controller.editors.mutateSelectedObjects {
            $0.countdownStartOn = .onSlideEnter
            $0.countdownResetOn = .onClick
            $0.buildSteps = [
                ElementBuildStep(elementId: countdown.id, phase: .buildIn, trigger: .onClick, sequenceOrder: 1)
            ]
        }
        controller.rehydrateFromEditor(persist: true, force: true)
        let timerID = controller.editors.selectedDocument?.objects.first(where: { $0.id == countdown.id })?.timerID
        #expect(timerID != nil)

        controller.goLive(slideID: slideID)
        #expect(controller.inspector.timer(id: timerID)?.isRunning == true)

        if let step = controller.nextPendingOnClickBuild() {
            controller.executeBuildStep(step)
        } else {
            controller.executeBuildStep(
                ElementBuildStep(elementId: countdown.id, phase: .buildIn, trigger: .onClick, sequenceOrder: 1)
            )
        }
        #expect(controller.inspector.timer(id: timerID)?.isRunning == false)
        #expect(controller.inspector.timer(id: timerID)?.elapsedSeconds == 0)
    }

    @Test @MainActor
    func countdown_followProgramMediaMirrorsPlaybackRemaining() {
        let controller = TestSupport.sampleController()
        let slideID = controller.show.allSlides[0].id
        controller.openInEditor(slideId: slideID)
        let countdown = controller.editors.addObject(.timerCountdown)
        controller.finishAddingLiveObject(countdown)
        controller.editors.mutateSelectedObjects {
            $0.countdownValueSource = .programMedia
        }
        controller.rehydrateFromEditor(persist: true, force: true)
        let timerID = controller.editors.selectedDocument?.objects.first(where: { $0.id == countdown.id })?.timerID
        #expect(timerID != nil)

        controller.goLive(slideID: slideID)
        controller.playback.title = "Talk Loop"
        controller.playback.duration = 120
        controller.playback.playhead = 37
        controller.syncMediaBackedCountdowns()
        #expect(controller.programMediaClock().remaining == 83)
        #expect(controller.inspector.timer(id: timerID)?.remainingSeconds == 83)
        #expect(controller.inspector.timer(id: timerID)?.durationSeconds == 120)
    }
}
