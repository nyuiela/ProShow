import Foundation
import Observation
#if canImport(CoreVideo)
import CoreVideo
#endif

/// Independent 8-layer compositor. Cues mutate only the layers they name.
struct RenderTextureDescriptor: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: String
    var usage: String

    static func program(width: Int, height: Int) -> RenderTextureDescriptor {
        RenderTextureDescriptor(
            width: width,
            height: height,
            pixelFormat: "bgra8Unorm",
            usage: "shaderRead+renderTarget"
        )
    }
}

@MainActor
@Observable
final class CompositorEngine {
    private(set) var stack = RenderStack.idle
    private(set) var propCanvases: [PropCanvas] = []
    private(set) var lastCue: OutputCue?
    private(set) var macros: [MacroScript] = CompositorEngine.sampleMacros
    private(set) var outputWidth: Int = 3840
    private(set) var outputHeight: Int = 2160
    private(set) var targetFrameRate: TargetFrameRate = .fps60
    private(set) var metalTextureDescriptor = RenderTextureDescriptor.program(width: 3840, height: 2160)
    @ObservationIgnored private(set) var lastFrame: ProgramFrame?
    @ObservationIgnored private(set) var lastRaster: ProgramRaster?
    let programOutput = ProgramOutputStore()
    private(set) var lastVideoFrame: VideoIngestFrame?
    @ObservationIgnored private(set) var frameIndex: Int = 0
    private(set) var mediaTransitionSeconds: TimeInterval = 0.5
    private(set) var mediaRevision: Int = 0
    private(set) var slideRevision: Int = 0
    private(set) var layerLocks = LayerLockController()
    private(set) var programTransition: ProgramTransitionState?
    /// Page for the current minute when the picture is the screen. Nil while the picture is the camera.
    var rundownPageURL: String?
    private var pendingOutgoingStack: RenderStack?

    var frameInterval: TimeInterval { targetFrameRate.frameInterval }

    #if canImport(CoreVideo)
    var masterProgramOutputBuffer: CVPixelBuffer? { programOutput.current() }
    #endif

    func publishProgramOutput(_ buffer: CVPixelBuffer?, coveredLayers: [Int]) {
        #if canImport(CoreVideo)
        programOutput.set(buffer, coveredLayers: coveredLayers)
        #endif
    }

    func captureOutgoingForTransition() {
        pendingOutgoingStack = stack
    }

    func beginProgramTransition(preset: TransitionPreset, duration: TimeInterval, now: Date = Date()) {
        let span = TransitionCatalog.preset(id: preset.id).id == "cut" ? 0 : max(0, duration)
        defer { pendingOutgoingStack = nil }
        guard span > 0.02 else {
            programTransition = nil
            return
        }
        programTransition = ProgramTransitionState(
            preset: TransitionCatalog.preset(id: preset.id),
            duration: span,
            startedAt: now,
            outgoing: pendingOutgoingStack ?? stack,
            progress: 0
        )
    }

    func tickTransition(now: Date = Date()) {
        guard var active = programTransition else { return }
        active.tick(now: now)
        if active.progress >= 1 {
            programTransition = nil
        } else {
            programTransition = active
        }
    }

    func cancelProgramTransition() {
        programTransition = nil
        pendingOutgoingStack = nil
    }

    func applyProjectSettings(_ settings: ProjectSettings) {
        outputWidth = settings.resolution.width
        outputHeight = settings.resolution.height
        targetFrameRate = settings.frameRate
        metalTextureDescriptor = .program(width: outputWidth, height: outputHeight)
    }

    func triggerCue(_ cue: OutputCue) {
        lastCue = cue
        if let macros = cue.layers.macroAction {
            executeMacros(macros)
        }
        if let look = cue.layers.lookAction {
            setAudienceLook(look)
        }
        if let media = cue.layers.mediaAction {
            if media.clearsLayer {
                clearProgramMedia()
                clear(.media)
            } else {
                transitionLayer(.media, to: media, transitionDuration: mediaTransitionSeconds)
            }
        }
        if let input = cue.layers.videoInputAction {
            stack.videoInput = input
            restore(.videoInput)
        }
        if let text = cue.layers.slideText {
            stack.slideElements = text
            stack.slideCanvas = cue.layers.slideCanvas ?? []
            stack.slideCanvasWidth = cue.layers.canvasWidth ?? Double(outputWidth)
            stack.slideCanvasHeight = cue.layers.canvasHeight ?? Double(outputHeight)
            stack.slideBackgroundEnabled = cue.layers.slideBackgroundEnabled ?? true
            stack.slideBackgroundHex = cue.layers.slideBackgroundHex ?? "#000000"
            restore(.slide)
        }
        if let audio = cue.layers.audioAction {
            stack.audio = audio
        }
    }

    func applyLiveSceneDelta(_ delta: LiveSceneDelta) {
        stack.slideElements = delta.slideText
        stack.slideCanvas = delta.canvas
        stack.slideCanvasWidth = delta.canvasWidth
        stack.slideCanvasHeight = delta.canvasHeight
        stack.slideBackgroundEnabled = delta.backgroundEnabled
        stack.slideBackgroundHex = delta.backgroundHex
        restore(.slide)
        slideRevision &+= 1
        UnifiedCacheRegistry.shared.invalidate(entityId: delta.slideID)
    }

    func setScreenColor(_ hex: String) {
        stack.screenColorHex = hex
        restore(.screenColor)
    }

    func setAudienceLook(_ look: AudienceLookConfig) {
        stack.look = look
    }

    func setStageLook(_ look: StageLookConfig) {
        stack.stageLook = look
    }

    func clear(_ layer: RenderLayer) {
        stack.cleared.insert(layer.rawValue)
    }

    func restore(_ layer: RenderLayer) {
        stack.cleared.remove(layer.rawValue)
    }

    func isLayerLocked(_ layer: RenderLayer) -> Bool {
        layerLocks.isLocked(layer)
    }

    func setLayerLocked(_ layer: RenderLayer, locked: Bool) {
        layerLocks.setLocked(layer, locked: locked)
    }

    func toggleLayerLock(_ layer: RenderLayer) {
        layerLocks.toggle(layer)
    }

    func toggle(_ layer: RenderLayer) {
        if stack.isCleared(layer) {
            restore(layer)
        } else {
            clear(layer)
        }
    }

    func clearDefaultLayers() {
        clear(.slide)
        clear(.media)
        clear(.videoInput)
    }

    func restoreDefaultLayers() {
        restore(.slide)
        restore(.media)
        restore(.videoInput)
    }

    func clearAudio() {
        stack.audioMuted = true
    }

    func restoreAudio() {
        stack.audioMuted = false
    }

    func transitionLayer(_ layer: RenderLayer, to media: MediaAction, transitionDuration: TimeInterval = 0.5) {
        mediaTransitionSeconds = transitionDuration
        guard layer == .media else { return }
        if stack.media != media {
            mediaRevision &+= 1
        }
        stack.media = media
        restore(.media)
    }

    func clearProgramMedia() {
        if stack.media != nil {
            mediaRevision &+= 1
        }
        stack.media = nil
    }

    /// The minute's page fills the program. The camera layer steps aside so the page is the picture.
    func presentRundownPage(_ url: String) {
        rundownPageURL = url
        let page = MediaAction(
            id: RundownPageMedia.id,
            title: url,
            tintHex: "#000000",
            isImage: true
        )
        if stack.media != page {
            mediaRevision &+= 1
        }
        stack.media = page
        restore(.media)
        clearProgramVideoInput()
        clear(.videoInput)
        clear(.slide)
    }

    /// Camera minutes drop the page so the video-input layer is the picture.
    func dismissRundownPage() {
        rundownPageURL = nil
        guard stack.media?.id == RundownPageMedia.id else { return }
        clearProgramMedia()
        clear(.media)
    }

    /// Layer 3 page raster for `.program` slides without clearing the slide canvas (text + browser shapes).
    func setProgramPageMediaBackdrop(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let page = MediaAction(
            id: RundownPageMedia.id,
            title: trimmed,
            tintHex: "#000000",
            isImage: true
        )
        if stack.media != page {
            mediaRevision &+= 1
        }
        stack.media = page
        restore(.media)
        clearProgramVideoInput()
    }

    func clearProgramVideoInput() {
        stack.videoInput = nil
    }

    func clearProgramSlide() {
        stack.slideElements = []
        stack.slideCanvas = []
        slideRevision &+= 1
    }

    func evictCanvasObject(id: UUID) {
        let before = stack.slideCanvas.count
        stack.slideCanvas.removeAll { $0.id == id }
        if stack.slideCanvas.count != before {
            slideRevision &+= 1
        }
    }

    func replaceVisibility(cleared: Set<Int>, audioMuted: Bool? = nil) {
        stack.cleared = cleared
        if let audioMuted {
            stack.audioMuted = audioMuted
        }
    }

    func toggleAudio() {
        if stack.audioMuted {
            restoreAudio()
        } else {
            clearAudio()
        }
    }

    func isLayerAudioMuted(_ layer: RenderLayer) -> Bool {
        stack.isAudioMuted(layer)
    }

    func toggleLayerAudio(_ layer: RenderLayer) {
        var layers = stack.mutedAudioLayers ?? []
        if layers.contains(layer.rawValue) {
            layers.remove(layer.rawValue)
        } else {
            layers.insert(layer.rawValue)
        }
        stack.mutedAudioLayers = layers.isEmpty ? nil : layers
    }

    func setLayerAudioMuted(_ layer: RenderLayer, muted: Bool) {
        var layers = stack.mutedAudioLayers ?? []
        if muted {
            layers.insert(layer.rawValue)
        } else {
            layers.remove(layer.rawValue)
        }
        stack.mutedAudioLayers = layers.isEmpty ? nil : layers
    }

    func clearAllLayers() {
        for layer in RenderLayer.allCases {
            clear(layer)
        }
        clearAudio()
    }

    func restoreAllLayers() {
        for layer in RenderLayer.allCases {
            restore(layer)
        }
        restoreAudio()
    }

    func setActiveProps(_ names: [String], canvases: [PropCanvas] = []) {
        stack.activeProps = names
        propCanvases = canvases
        if names.isEmpty {
            clear(.props)
        } else {
            restore(.props)
        }
    }

    func toggleProp(_ name: String) {
        if let index = stack.activeProps.firstIndex(of: name) {
            stack.activeProps.remove(at: index)
        } else {
            stack.activeProps.append(name)
        }
        restore(.props)
    }

    func setMessage(_ text: String?) {
        stack.message = text
        if text == nil {
            clear(.messages)
        } else {
            restore(.messages)
        }
    }

    func setAnnouncement(_ text: String?) {
        stack.announcement = text
        if text == nil {
            clear(.announcements)
        } else {
            restore(.announcements)
        }
    }

    func setMaskEnabled(_ enabled: Bool) {
        stack.maskEnabled = enabled
        stack.mask.enabled = enabled
        if enabled { restore(.mask) } else { clear(.mask) }
    }

    func setMask(enabled: Bool, invert: Bool, kind: String) {
        stack.mask = MaskPath(enabled: enabled, kind: invert ? "invert" : kind)
        setMaskEnabled(enabled)
    }

    func setTimers(_ timers: [OutputTimer]) {
        stack.timers = timers
        restore(.messages)
    }

    func setMessages(_ messages: [OutputMessage]) {
        stack.messages = messages
        stack.message = messages.first?.text
        if messages.isEmpty {
            clear(.messages)
        } else {
            restore(.messages)
        }
    }

    func replaceOutputScreens(_ screens: [OutputScreen]) {
        guard !screens.isEmpty else { return }
        stack.outputScreens = screens
    }

    func assignThemeVariant(_ variantID: UUID?, toScreenID screenID: String) {
        if let index = stack.outputScreens.firstIndex(where: { $0.id == screenID }) {
            stack.outputScreens[index].themeVariantID = variantID
        }
    }

    func assignLook(_ look: AudienceLookConfig, toScreenID screenID: String) {
        if let index = stack.outputScreens.firstIndex(where: { $0.id == screenID }) {
            stack.outputScreens[index].lookName = look.name
        }
        if screenID == "screen-1" || screenID == stack.outputScreens.first?.id {
            setAudienceLook(look)
        }
    }

    func look(forScreenID screenID: String) -> AudienceLookConfig {
        let name = stack.outputScreens.first(where: { $0.id == screenID })?.lookName
        switch name {
        case AudienceLookConfig.alphaKey.name: return .alphaKey
        case AudienceLookConfig.slideAndMedia.name: return .slideAndMedia
        default: return .fullStack
        }
    }

    func executeMacros(_ scripts: [MacroScript]) {
        for script in scripts {
            executeMacro(id: script.id)
        }
    }

    @discardableResult
    func executeMacro(id: UUID, triggerSlide: ((Int) -> Void)? = nil) -> Bool {
        guard let script = macros.first(where: { $0.id == id }) else { return false }
        for command in script.commands {
            switch command.kind {
            case .clearLayer:
                if let layer = command.layer { clear(layer) }
            case .setLook:
                if command.lookName == AudienceLookConfig.alphaKey.name {
                    setAudienceLook(.alphaKey)
                } else if command.lookName == AudienceLookConfig.slideAndMedia.name {
                    setAudienceLook(.slideAndMedia)
                } else {
                    setAudienceLook(.fullStack)
                }
            case .triggerSlide:
                if let index = command.slideIndex {
                    triggerSlide?(index)
                }
            }
        }
        return true
    }

    func applySceneLayout(
        primary: VideoInputSource?,
        pip: VideoInputSource?,
        primaryBounds: CanvasRect,
        pipBounds: CanvasRect?
    ) {
        stack.videoInput = primary
        stack.primaryBounds = primaryBounds
        stack.pipInput = pip
        stack.pipBounds = pipBounds ?? .pipLowerRight
        if primary != nil {
            restore(.videoInput)
        }
    }

    /// Keep stack endpoints aligned with `VideoInputEngine` after hardware reconcile.
    func syncVideoInputs(from video: VideoInputEngine) {
        if let current = stack.videoInput {
            let live = video.resolvedInputSource(for: current)
            if stack.videoInput != live {
                stack.videoInput = live
            }
        }
        if let current = stack.pipInput {
            let live = video.resolvedInputSource(for: current)
            if stack.pipInput != live {
                stack.pipInput = live
            }
        }
    }

    func setChatOverlay(_ card: ChatOverlayCard?) {
        stack.chatOverlay = card
        if card != nil {
            restore(.messages)
        }
    }

    @discardableResult
    func advanceFrame(
        playhead: TimeInterval,
        now: Date = Date(),
        leftMeter: Double = 0,
        rightMeter: Double = 0,
        filters: VideoFilterEngine? = nil,
        renderer: ProgramTextureRenderer? = nil,
        videoFrame: VideoIngestFrame? = nil,
        pixelBuffer: CVPixelBuffer? = nil
    ) -> ProgramFrame {
        renderer?.ensureTextures(width: outputWidth, height: outputHeight)
        lastVideoFrame = videoFrame
        renderer?.ingest(pixelBuffer: pixelBuffer)
        #if canImport(CoreVideo)
        if let pixelBuffer {
            SharedTexturePublisher.shared.publish(pixelBuffer: pixelBuffer)
        }
        #endif
        let raster = ProgramRasterizer.composite(
            stack: stack,
            width: 192,
            height: 108,
            playhead: playhead,
            filters: filters,
            videoFrame: videoFrame
        )
        lastRaster = raster
        frameIndex += 1
        let visible = RenderLayer.allCases
            .filter { stack.isVisible($0, onStage: false) }
            .map(\.rawValue)
        let frame = ProgramFrame(
            index: frameIndex,
            hostTime: now.timeIntervalSinceReferenceDate,
            playhead: playhead,
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            visibleLayers: visible,
            mediaTitle: stack.media?.title,
            textureAllocated: renderer?.textureAllocated ?? false,
            backend: renderer?.backend ?? "cpu",
            leftMeter: leftMeter,
            rightMeter: rightMeter
        )
        lastFrame = frame
        return frame
    }

    func reset() {
        stack = .idle
        propCanvases = []
        lastCue = nil
        lastFrame = nil
        lastRaster = nil
        lastVideoFrame = nil
        frameIndex = 0
        mediaTransitionSeconds = 0.5
        programTransition = nil
        pendingOutgoingStack = nil
    }

    private static let sampleMacros: [MacroScript] = [
        MacroScript(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB1")!,
            name: "Clear Media",
            commands: [MacroCommand(kind: .clearLayer, layer: .media, slideIndex: nil, lookName: nil)]
        ),
        MacroScript(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBB2")!,
            name: "Worship Look",
            commands: [MacroCommand(kind: .setLook, layer: nil, slideIndex: nil, lookName: AudienceLookConfig.slideAndMedia.name)]
        ),
    ]
}
