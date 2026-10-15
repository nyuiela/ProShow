import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

@main
struct ProShowApp: App {
    @State private var session: AppSession
    #if os(macOS)
    @NSApplicationDelegateAdaptor(ProShowAppDelegate.self) private var appDelegate
    @StateObject private var audienceWindow = AudienceWindowController()
    @StateObject private var stageWindow = StageWindowController()
    #endif
    @State private var showAudienceSheet = false
    @State private var controlAPI = ControlAPIServer()
    @State private var remoteControl = RemoteControlRuntime()

    init() {
        #if os(macOS)
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        #else
        let shiftHeld = false
        #endif
        _session = State(initialValue: AppSession(shiftHeld: shiftHeld))
    }

    private var editObjectsLocked: Bool {
        !session.controller.isCanvasEditorPresented
            || session.controller.editors.isEditingText
            || session.controller.editors.selectedObjectIDs.isEmpty
    }

    private var editSelectionLocked: Bool {
        !session.controller.isCanvasEditorPresented
            || session.controller.editors.selectedObjectIDs.isEmpty
    }

    var body: some Scene {
        WindowGroup("ProShow") {
            Group {
                if session.phase == .startMenu {
                    StartMenuView(
                        preferences: session.preferences,
                        isLaunching: session.isLaunching,
                        launchError: session.launchError,
                        onCreate: { name, url in session.createProjectFromMenu(name: name, at: url) },
                        onOpen: { url in session.openProjectFromMenu(at: url) },
                        onSelectTheme: { theme in
                            session.preferences.selectedTheme = theme
                            try? session.preferenceStore.save(session.preferences)
                        }
                    )
                } else {
                    RootView(
                        controller: session.controller,
                        onOpenAudienceWindow: {
                            #if os(macOS)
                            audienceWindow.open(controller: session.controller)
                            #else
                            showAudienceSheet = true
                            #endif
                        },
                        onOpenStageWindow: {
                            #if os(macOS)
                            stageWindow.open(controller: session.controller)
                            #endif
                        }
                    )
                }
            }
            .lockFlickerFreeBackground()
            .onReceive(NotificationCenter.default.publisher(for: .proShowControlOpenProject)) { note in
                guard let path = note.object as? String, !path.isEmpty else { return }
                session.openProjectFromMenu(at: URL(fileURLWithPath: path))
            }
            .onReceive(NotificationCenter.default.publisher(for: .proShowControlCloseProject)) { _ in
                session.closeToStartMenu()
            }
            #if os(macOS)
            .background {
                DeskWindowTitle(
                    title: session.phase == .desk ? session.controller.projectDisplayName : "ProShow",
                    isDocumentEdited: session.phase == .desk && session.controller.projectHasUnsavedChanges
                )
                DeskTitlebarMergeGuard()
            }
            #endif
            .onAppear {
                #if os(macOS)
                appDelegate.sessionProvider = { session }
                SpaceOcclusionMonitor.startIfNeeded()
                #endif
                restartRemoteSurfaces()
            }
            .onChange(of: RemoteSurfaceSignature(session.controller.deviceSettings.document)) { _, _ in
                restartRemoteSurfaces()
            }
            .onDisappear {
                session.flushToDiskOnQuit()
                controlAPI.stop()
                remoteControl.stop()
            }
            .sheet(isPresented: projectSettingsBinding) {
                SettingsWindowView(controller: session.controller, store: session.controller.deviceSettings)
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showAudienceSheet) {
                iOSAudienceCover(controller: session.controller, isPresented: $showAudienceSheet)
            }
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: DeskLayout.windowWidth, height: DeskLayout.windowHeight)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { session.controller.presentProjectSettings() }
                    .keyboardShortcut(",", modifiers: [.command])
                    .disabled(session.phase != .desk)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { createFromMenu() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Open Project…") { openFromMenu() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("Open Program Rundown…") { openProgramRundown(session: session) }
                Divider()
                Button("Save Project") { _ = session.saveProject() }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(session.phase != .desk || !session.projectHasUnsavedChanges)
                Button("Close Project") { session.closeToStartMenu() }
                    .disabled(session.phase != .desk)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { session.controller.editors.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!session.controller.editors.canUndo)
                Button("Redo") { session.controller.editors.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!session.controller.editors.canRedo)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Cut Object") { session.controller.editors.cutSelectedObjects() }
                    .disabled(editObjectsLocked)
                Button("Copy Object") { session.controller.editors.copySelectedObjects() }
                    .disabled(editObjectsLocked)
                Button("Paste Object") { session.controller.editors.pasteObjects() }
                    .disabled(!session.controller.isCanvasEditorPresented || session.controller.editors.isEditingText || !session.controller.editors.canPasteObjects)
                Button("Duplicate Object") { session.controller.editors.duplicateSelected() }
                    .disabled(editObjectsLocked)
                Button("Delete Object") { session.controller.editors.deleteSelected() }
                    .disabled(editObjectsLocked)
                Button("Select All Objects") { session.controller.editors.selectAllObjects() }
                    .disabled(!session.controller.isCanvasEditorPresented || session.controller.editors.isEditingText)
                Divider()
                Menu("Nudge") {
                    Button("Left") { session.controller.editors.nudgeSelected(dx: -1, dy: 0) }
                    Button("Right") { session.controller.editors.nudgeSelected(dx: 1, dy: 0) }
                    Button("Up") { session.controller.editors.nudgeSelected(dx: 0, dy: -1) }
                    Button("Down") { session.controller.editors.nudgeSelected(dx: 0, dy: 1) }
                }
                .disabled(editSelectionLocked)
                Menu("Align") {
                    Button("Left") { session.controller.editors.alignSelected(.left) }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                    Button("Center") { session.controller.editors.alignSelected(.centerX) }
                        .keyboardShortcut("c", modifiers: [.command, .option])
                    Button("Right") { session.controller.editors.alignSelected(.right) }
                        .keyboardShortcut("r", modifiers: [.command, .option])
                }
                .disabled(editSelectionLocked)
                Menu("Arrange") {
                    Button("Bring Forward") { session.controller.editors.bringForward() }
                        .keyboardShortcut("]", modifiers: [.command])
                    Button("Send Backward") { session.controller.editors.sendBackward() }
                        .keyboardShortcut("[", modifiers: [.command])
                    Divider()
                    Button("Bring to Front") { session.controller.editors.bringToFront() }
                        .keyboardShortcut("]", modifiers: [.command, .shift])
                    Button("Send to Back") { session.controller.editors.sendToBack() }
                        .keyboardShortcut("[", modifiers: [.command, .shift])
                }
                .disabled(editSelectionLocked)
                Divider()
                Menu("Group") {
                    Button("Group") { session.controller.editors.groupSelected() }
                        .keyboardShortcut("g", modifiers: [.command])
                        .disabled(!session.controller.editors.canGroup)
                    Button("Ungroup") { session.controller.editors.ungroupSelected() }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(!session.controller.editors.canUngroup)
                }
                .disabled(!session.controller.isCanvasEditorPresented)
                Menu("Combine") {
                    Button("Auto Layout") { session.controller.editors.applyAutoLayout() }
                        .keyboardShortcut("a", modifiers: [.shift])
                        .disabled(session.controller.editors.selectedObjectIDs.count < 2)
                    Divider()
                    Button("Union") { session.controller.editors.applyBoolean(.union) }
                        .keyboardShortcut("u", modifiers: [.command, .option])
                        .disabled(session.controller.editors.selectedObjectIDs.count < 2)
                    Button("Subtract") { session.controller.editors.applyBoolean(.subtract) }
                        .keyboardShortcut("s", modifiers: [.command, .option])
                        .disabled(session.controller.editors.selectedObjectIDs.count < 2)
                    Button("Intersect") { session.controller.editors.applyBoolean(.intersect) }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .disabled(session.controller.editors.selectedObjectIDs.count < 2)
                    Button("Exclude") { session.controller.editors.applyBoolean(.exclude) }
                        .keyboardShortcut("x", modifiers: [.command, .option])
                        .disabled(session.controller.editors.selectedObjectIDs.count < 2)
                    Button("Flatten") { session.controller.editors.flattenBoolean() }
                        .keyboardShortcut("e", modifiers: [.command])
                    Divider()
                    Button("Join Paths") { session.controller.editors.joinSelectedPaths() }
                        .keyboardShortcut("j", modifiers: [.command])
                    Button("Convert Text to Outlines") { session.controller.editors.convertSelectedTextToOutlines() }
                }
                .disabled(!session.controller.isCanvasEditorPresented)
                Menu("Tools") {
                    Button("Move (V)") { session.controller.editors.setTool(.pointer) }
                    Button("Direct Select (A)") { session.controller.editors.setTool(.direct) }
                    Button("Text (T)") { session.controller.editors.setTool(.text) }
                    Divider()
                    Button("Rectangle (R)") { session.controller.editors.setTool(.rectangle) }
                    Button("Ellipse (O)") { session.controller.editors.setTool(.ellipse) }
                    Button("Circle (C)") { session.controller.editors.setTool(.ellipse) }
                    Button("Placeholder (P)") { session.controller.editors.setTool(.placeholder) }
                    Divider()
                    Button("Pen (⇧P)") { session.controller.editors.setTool(.pen) }
                    Button("Bend (⇧B)") { session.controller.editors.setTool(.bend) }
                    Button("Scissors (⇧C)") { session.controller.editors.setTool(.scissors) }
                    Divider()
                    Button("Hand (H)") { session.controller.editors.setTool(.hand) }
                    Button("Zoom (Z)") { session.controller.editors.setTool(.zoom) }
                }
                .disabled(!session.controller.isCanvasEditorPresented || session.controller.editors.isEditingText)
                Divider()
                Menu("Zoom") {
                    Button("Zoom In") { session.controller.editors.zoom = session.controller.editors.clampZoom(session.controller.editors.zoom * 1.15) }
                        .keyboardShortcut("=", modifiers: [.command])
                    Button("Zoom Out") { session.controller.editors.zoom = session.controller.editors.clampZoom(session.controller.editors.zoom / 1.15) }
                        .keyboardShortcut("-", modifiers: [.command])
                    Divider()
                    Button("Fit Canvas") { session.controller.editors.fitCurrentDocument() }
                        .keyboardShortcut("0", modifiers: [.command])
                    Button("100%") { session.controller.editors.zoomToActualPixels() }
                        .keyboardShortcut("1", modifiers: [.command, .shift])
                    Button("Zoom to Selection") { session.controller.editors.zoomToSelection() }
                        .keyboardShortcut("2", modifiers: [.command, .shift])
                }
                .disabled(!session.controller.isCanvasEditorPresented)
            }
            CommandMenu("Workspace") {
                Button("Show Workspace") { session.controller.setMode(.show) }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Edit Workspace") { session.controller.setMode(.edit) }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Rundown Studio") { session.controller.setMode(.rundown) }
                    .keyboardShortcut("3", modifiers: [.command])
                Button("Map Workspace") { session.controller.setMode(.map) }
                    .keyboardShortcut("4", modifiers: [.command])
                Button("Props Editor") { session.controller.openEditor(.props) }
                    .keyboardShortcut("5", modifiers: [.command])
                Divider()
                Button("Reflow Workspace") { session.controller.setMode(.reflow) }
                Button("Widgets Workspace") { session.controller.setMode(.widgets) }
            }
            CommandMenu("Rundown") {
                Button("Stop Show") { session.controller.rundownClock.stopShow() }
                    .disabled(!session.controller.rundownClock.isShowRunning)
                Button("Next Block") { session.controller.advanceRundownBlock() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!session.controller.rundownClock.isShowRunning || session.controller.operatorMode != .rundown)
            }
            CommandMenu("Show") {
                Button("Go Live") { session.controller.requestGoLive() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Next Slide") { session.controller.advance() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(session.controller.isCanvasEditorPresented)
                Button("Previous Slide") { session.controller.goPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(session.controller.isCanvasEditorPresented)
                Button(session.controller.isAudienceCleared ? "Restore Audience" : "Clear Audience") {
                    if session.controller.isAudienceCleared {
                        session.controller.restoreAudience()
                    } else {
                        session.controller.clearAudience()
                    }
                }
                .keyboardShortcut("b", modifiers: [])
                Divider()
                Button("Camera") { session.controller.triggerSceneHotkey("1") }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Presenter + 4K Deck") { session.controller.triggerSceneHotkey("2") }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Interview / Split-Screen") { session.controller.triggerSceneHotkey("3") }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Button("Screen Share + Mic") { session.controller.triggerSceneHotkey("4") }
                    .keyboardShortcut("4", modifiers: [.command, .option])
                Divider()
                Button("Clear Layer 1") { session.controller.hideLayer(.screenColor) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!)), modifiers: [])
                Button("Clear Layer 2") { session.controller.hideLayer(.videoInput) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: [])
                Button("Clear Layer 3") { session.controller.hideLayer(.media) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!)), modifiers: [])
                Button("Clear Layer 4") { session.controller.hideLayer(.slide) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF4FunctionKey)!)), modifiers: [])
                Button("Clear Layer 5") { session.controller.hideLayer(.announcements) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [])
                Button("Clear Layer 6") { session.controller.hideLayer(.props) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [])
                Button("Clear Layer 7") { session.controller.hideLayer(.messages) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: [])
                Button("Clear Layer 8") { session.controller.hideLayer(.mask) }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: [])
                Button("Emergency Clear All") {
                    session.controller.requestDeskDestructiveConfirm(.emergencyClearAll)
                }
                    .keyboardShortcut(.escape, modifiers: [.command])
                Divider()
                Button("Open Stream Window") {
                    session.controller.isStreamOutputOn = true
                    NotificationCenter.default.post(name: .proShowOpenStreamWindow, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Toggle Studio Window") {
                    NotificationCenter.default.post(name: .proShowOpenMultiViewerWindow, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Zoom Studio Window") {
                    NotificationCenter.default.post(name: .proShowStudioToggleFullScreen, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command, .shift])
                Button("Minimize Studio Window") {
                    NotificationCenter.default.post(name: .proShowStudioMiniaturize, object: nil)
                }
                .keyboardShortcut("m", modifiers: [.control, .command])
                Button("Dock or Expand Studio") {
                    NotificationCenter.default.post(name: .proShowStudioToggleEdgeDock, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Open Audience Window") {
                    audienceWindow.open(controller: session.controller)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Open Stage Window") {
                    stageWindow.open(controller: session.controller)
                }
                Divider()
                Button("Pre-Flight…") { session.controller.openPreFlight() }
                Button(session.controller.streaming.isLive ? "Stop Capture" : "Start Capture") {
                    if session.controller.streaming.isLive {
                        session.controller.stopBroadcast()
                    } else {
                        session.controller.openGoLiveSetup()
                    }
                }
            }
        }
        #endif

        #if os(macOS)
        Window("ProShow Stream", id: ProShowSceneID.stream) {
            StreamProgramView(controller: session.controller, showsChrome: true)
                .frame(minWidth: 640, minHeight: 360)
                .background(ProShowCapturePrivacyInstaller())
                .background(ProShowTheme.stageBlack)
                .onAppear {
                    session.controller.isStreamOutputOn = true
                    session.controller.tickProgram()
                }
                .onDisappear {
                    session.controller.isStreamOutputOn = false
                }
        }
        .defaultSize(width: 1280, height: 720)
        Window("ProShow Phone", id: ProShowSceneID.phone) {
            PhoneCanvasPicture(controller: session.controller, feed: session.controller.inspector.phonePreviewFeed)
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .frame(minWidth: 270, minHeight: 480)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ProShowTheme.stageBlack)
                .onAppear { session.controller.tickProgram() }
        }
        .defaultSize(width: 405, height: 720)
        Settings {
            SettingsWindowView(controller: session.controller, store: session.controller.deviceSettings)
        }
        #endif
    }

    private var projectSettingsBinding: Binding<Bool> {
        Binding(
            get: { session.phase == .desk && session.controller.isProjectSettingsOpen },
            set: { session.controller.isProjectSettingsOpen = $0 }
        )
    }

    private func restartRemoteSurfaces() {
        let settings = session.controller.deviceSettings.document
        controlAPI.stop()
        remoteControl.stop()
        if settings.controlAPIEnabled {
            let port = settings.controlAPIPort > 0
                ? UInt16(clamping: settings.controlAPIPort)
                : ControlAPIServer.defaultPort
            controlAPI.start(
                port: port,
                webSocketEnabled: settings.webSocketEnabled,
                telemetry: { [session] in
                    await MainActor.run {
                        ControlJSON.encode(RemoteControlBridge.telemetryJSON(session.controller))
                    }
                },
                backstageWebSocketHandler: { path, text in
                    await MainActor.run {
                        session.controller.backstageSignalingResponse(forWebSocketText: text, path: path)
                    }
                }
            ) { [session] method, path, body in
                await MainActor.run {
                    session.controller.handleControl(method: method, path: path, body: body)
                }
            }
        }
        if settings.oscEnabled || settings.midiEnabled {
            let oscPort = settings.oscPort > 0 ? UInt16(clamping: settings.oscPort) : 8000
            remoteControl.start(
                oscPort: oscPort,
                oscEnabled: settings.oscEnabled,
                midiEnabled: settings.midiEnabled
            ) { [session] command in
                Task { @MainActor in
                    _ = RemoteControlBridge.apply(command, to: session.controller)
                }
            }
        }
    }

    #if os(macOS)
    private func createFromMenu() {
        if let url = ProjectFilePanel.save(name: "Untitled") {
            session.createProjectFromMenu(name: url.deletingPathExtension().lastPathComponent, at: url)
        }
    }

    private func openFromMenu() {
        if let url = ProjectFilePanel.open() {
            session.openProjectFromMenu(at: url)
        }
    }

    private func openProgramRundown(session: AppSession) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.proShowProgram]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.controller.loadProgramDocument(from: url)
            session.controller.setMode(.rundown)
        } catch {
            session.controller.mediaAlert = error.localizedDescription
        }
    }
    #endif
}

private struct RemoteSurfaceSignature: Equatable {
    var controlAPIEnabled: Bool
    var controlAPIPort: Int
    var webSocketEnabled: Bool
    var oscEnabled: Bool
    var oscPort: Int
    var midiEnabled: Bool

    init(_ document: DeviceSettingsDocument) {
        controlAPIEnabled = document.controlAPIEnabled
        controlAPIPort = document.controlAPIPort
        webSocketEnabled = document.webSocketEnabled
        oscEnabled = document.oscEnabled
        oscPort = document.oscPort
        midiEnabled = document.midiEnabled
    }
}

enum ProShowSceneID {
    static let stream = "proshow-stream"
    static let phone = "proshow-phone"
    static let multiviewer = "proshow-multiviewer"
}

extension Notification.Name {
    static let proShowOpenStreamWindow = Notification.Name("proshow.open-stream-window")
    static let proShowOpenPhoneWindow = Notification.Name("proshow.open-phone-window")
    static let proShowOpenMultiViewerWindow = Notification.Name("proshow.open-multiviewer-window")
    static let proShowStudioToggleFullScreen = Notification.Name("proshow.studio-toggle-fullscreen")
    static let proShowStudioMiniaturize = Notification.Name("proshow.studio-miniaturize")
    static let proShowStudioToggleEdgeDock = Notification.Name("proshow.studio-toggle-edge-dock")
}

struct RootView: View {
    @Bindable var controller: ShowController
    var onOpenAudienceWindow: () -> Void
    var onOpenStageWindow: (() -> Void)? = nil
    var onOpenStreamWindow: (() -> Void)? = nil
    var onOpenMultiViewerWindow: (() -> Void)? = nil
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    var body: some View {
        desk
    }

    @ViewBuilder
    private var desk: some View {
        #if os(iOS)
        NavigationStack {
            OperatorView(controller: controller, onOpenAudienceWindow: onOpenAudienceWindow)
                .deskDestructiveConfirmation(controller: controller)
                .navigationTitle("ProShow")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { controller.goPrevious() } label: {
                            Image(systemName: "backward.fill")
                                .frame(minWidth: DeskLayout.hitPhone, minHeight: DeskLayout.hitPhone)
                        }
                        .accessibilityLabel("Previous slide")
                        Button { controller.requestGoLive() } label: {
                            Label("Go Live", systemImage: "arrow.up.right.circle.fill")
                                .frame(minHeight: DeskLayout.hitPhone)
                        }
                        Button { controller.advance() } label: {
                            Image(systemName: "forward.fill")
                                .frame(minWidth: DeskLayout.hitPhone, minHeight: DeskLayout.hitPhone)
                        }
                        .accessibilityLabel("Next slide")
                        Spacer()
                        Button("Audience") { onOpenAudienceWindow() }
                    }
                }
        }
        #else
        OperatorView(
            controller: controller,
            onOpenAudienceWindow: onOpenAudienceWindow,
            onOpenStageWindow: onOpenStageWindow,
            onOpenStreamWindow: { presentStreamWindow() },
            onOpenMultiViewerWindow: { presentMultiViewer() }
        )
        .deskDestructiveConfirmation(controller: controller)
        .onAppear {
            #if os(macOS)
            KeyboardShortcutManager.shared.attach(controller)
            #endif
        }
        .onDisappear {
            #if os(macOS)
            KeyboardShortcutManager.shared.detach()
            #endif
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .proShowOpenStreamWindow)) { _ in
            presentStreamWindow(forceOpen: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .proShowOpenPhoneWindow)) { _ in
            presentPhoneWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .proShowOpenMultiViewerWindow)) { _ in
            presentMultiViewer(forceOpen: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .proShowStudioToggleFullScreen)) { _ in
            presentStudioForChromeAction { $0.toggleFullScreen() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .proShowStudioMiniaturize)) { _ in
            presentStudioForChromeAction { $0.miniaturizeWindow() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .proShowStudioToggleEdgeDock)) { _ in
            controller.tickProgram()
            let studio = StudioGlassController.shared
            studio.attach(controller)
            let screen = MultiViewerWindowController.preferredScreen(from: controller.deviceSettings.document)
            studio.toggleEdgeDock(on: screen)
        }
        #endif
        #endif
    }

    #if os(macOS)
    private func presentStreamWindow(forceOpen: Bool = false) {
        controller.tickProgram()
        if !forceOpen, controller.isStreamOutputOn {
            dismissWindow(id: ProShowSceneID.stream)
            return
        }
        controller.isStreamOutputOn = true
        openWindow(id: ProShowSceneID.stream)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "ProShow Stream" })?.orderFrontRegardless()
        }
    }

    private func presentPhoneWindow() {
        controller.tickProgram()
        openWindow(id: ProShowSceneID.phone)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "ProShow Phone" })?.orderFrontRegardless()
        }
    }

    private func presentMultiViewer(forceOpen: Bool = false) {
        controller.tickProgram()
        let studio = StudioGlassController.shared
        studio.attach(controller)
        let screen = MultiViewerWindowController.preferredScreen(from: controller.deviceSettings.document)
        if !forceOpen {
            if studio.isEdgeDocked {
                studio.expandFromEdge(on: screen)
                return
            }
            if studio.isMainPanelShown {
                studio.close()
                return
            }
        }
        studio.open(on: screen)
    }

    private func presentStudioForChromeAction(_ action: (StudioGlassController) -> Void) {
        controller.tickProgram()
        let studio = StudioGlassController.shared
        studio.attach(controller)
        let screen = MultiViewerWindowController.preferredScreen(from: controller.deviceSettings.document)
        if studio.isEdgeDocked {
            studio.expandFromEdge(on: screen)
        } else if !studio.isMainPanelShown {
            studio.open(on: screen)
        }
        action(studio)
    }
    #endif
}

#if os(iOS)
private struct iOSAudienceCover: View {
    @Bindable var controller: ShowController
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LayeredAudienceView(
                compositor: controller.compositor,
                playback: controller.playback,
                videoInputs: controller.videoInputs,
                outputEnabled: controller.programOutputEnabled,
                showsChrome: true
            )
            .environment(\.proShowPlayback, controller.playback)
            .environment(\.mirrorsProgramPlayer, true)
            .environment(\.resolvePlaceholderSource) { letter in
                controller.resolvedAssignedSource(forPlaceholder: letter)
            }
            .background {
                let _ = controller.liveQuotePresentationStamp
                Color.clear
            }
            .environment(\.dynamicText, controller.dynamicTextContext())
            .environment(\.liveQuoteEngine, controller.liveQuotes)
            .environment(\.buildClock, controller.liveBuildClock())
                .ignoresSafeArea()

            Button("Done") { isPresented = false }
                .padding(DeskSpace.md)
                .frame(minHeight: DeskLayout.hitPhone)
                .buttonStyle(.borderedProminent)
                .tint(ProShowTheme.accent)
                .accessibilityLabel("Close audience")
        }
        .statusBarHidden(true)
    }
}
#endif

#if os(macOS)
private struct DeskWindowTitle: NSViewRepresentable {
    var title: String
    var isDocumentEdited: Bool

    func makeNSView(context: Context) -> DeskWindowTitleView {
        let view = DeskWindowTitleView()
        view.title = title
        view.isDocumentEdited = isDocumentEdited
        return view
    }

    func updateNSView(_ view: DeskWindowTitleView, context: Context) {
        view.title = title
        view.isDocumentEdited = isDocumentEdited
        view.apply()
    }
}

private final class DeskWindowTitleView: NSView {
    var title = "ProShow"
    var isDocumentEdited = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        guard let window, window.sheetParent == nil else { return }
        DeskMergedTitlebar.titleVisibility = .hidden
        DeskMergedTitlebar.restore(window)
        window.backgroundColor = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 20 / 255, alpha: 1)
        if window.title != title {
            window.title = title
        }
        window.isDocumentEdited = isDocumentEdited
        if ProShowStreamCapturePrivacy.deskConcealmentActive,
           !ProShowStreamCapturePrivacy.isSuspendingConcealment {
            window.sharingType = .none
        }
    }
}

final class ProShowAppDelegate: NSObject, NSApplicationDelegate {
    var sessionProvider: (() -> AppSession?)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep the bundle AppIcon in the Dock. Overriding it at runtime with
        // ProShowLogo swapped the look (inverted colors, larger mark) right after launch.
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionProvider?()?.flushToDiskOnQuit()
    }
}
#endif
