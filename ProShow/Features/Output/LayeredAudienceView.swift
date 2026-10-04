import SwiftUI
import AVFoundation
import AVKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Canonical SwiftUI program stack (Audience, Stage, multiviewer). RTMP/ISO encodes the
/// matching composite via `ProgramOutputComposer` into `ProgramOutputComposer.previewEndpoint`.
struct ProgramSurfaceView: View {
    @Bindable var controller: ShowController
    var outputEnabled: Bool
    var onStage: Bool = false
    var showsChrome: Bool = false
    var lookOverride: AudienceLookConfig? = nil
    var isRenderingPaused: Bool = false

    var body: some View {
        let _ = controller.inspector.timers.map { "\($0.id)-\($0.displaySeconds)-\($0.isRunning)" }
        let _ = controller.liveQuotePresentationStamp
        LayeredAudienceView(
            compositor: controller.compositor,
            playback: controller.playback,
            videoInputs: controller.videoInputs,
            outputEnabled: outputEnabled,
            onStage: onStage,
            showsChrome: showsChrome,
            lookOverride: lookOverride,
            isRenderingPaused: isRenderingPaused
        )
        .environment(\.proShowPlayback, controller.playback)
        .environment(\.proShowVideoInputs, controller.videoInputs)
        .environment(\.mirrorsProgramPlayer, true)
        .environment(\.resolvePlaceholderSource) { letter in
            controller.resolvedAssignedSource(forPlaceholder: letter)
        }
        .environment(\.dynamicText, controller.canonicalProgramDynamicText())
        .environment(\.liveQuoteEngine, controller.liveQuotes)
        .environment(\.buildClock, controller.liveBuildClock())
        .environment(\.animationEvaluationMode, .liveClock)
        .onAppear { controller.evaluateProgramClockState() }
    }
}

/// Program surface: layers 1…8, independently visible / cleared.
struct LayeredAudienceView: View {
    @Bindable var compositor: CompositorEngine
    var playback: MediaPlaybackEngine? = nil
    var videoInputs: VideoInputEngine? = nil
    var outputEnabled: Bool
    var onStage: Bool = false
    var showsChrome: Bool = false
    var lookOverride: AudienceLookConfig? = nil
    var stackSource: RenderStack? = nil
    var fillsParent: Bool = true
    var isRenderingPaused: Bool = false
    @Environment(\.resolvePlaceholderSource) private var resolvePlaceholderSource
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var stack: RenderStack {
        var copy = stackSource ?? compositor.stack
        if let lookOverride {
            copy.look = lookOverride
        }
        return copy
    }

    private var liveTransition: ProgramTransitionState? {
        guard fillsParent, stackSource == nil, !reduceMotion else { return nil }
        return compositor.programTransition?.isActive == true ? compositor.programTransition : nil
    }

    var body: some View {
        if fillsParent {
            GeometryReader { proxy in
                let canvasW = CGFloat(max(compositor.outputWidth, 1))
                let canvasH = CGFloat(max(compositor.outputHeight, 1))
                let scale = min(proxy.size.width / canvasW, proxy.size.height / canvasH)
                let fitted = CGSize(width: canvasW * scale, height: canvasH * scale)
                ZStack {
                    if let transition = liveTransition {
                        LayeredAudienceView(
                            compositor: compositor,
                            playback: playback,
                            videoInputs: videoInputs,
                            outputEnabled: outputEnabled,
                            onStage: onStage,
                            showsChrome: false,
                            lookOverride: lookOverride,
                            stackSource: transition.outgoing,
                            fillsParent: false,
                            isRenderingPaused: isRenderingPaused
                        )
                        .frame(width: fitted.width, height: fitted.height)
                        .programTransitionRole(.outgoing, preset: transition.preset, progress: transition.progress)
                        LayeredAudienceView(
                            compositor: compositor,
                            playback: playback,
                            videoInputs: videoInputs,
                            outputEnabled: outputEnabled,
                            onStage: onStage,
                            showsChrome: false,
                            lookOverride: lookOverride,
                            stackSource: stack,
                            fillsParent: false,
                            isRenderingPaused: isRenderingPaused
                        )
                        .frame(width: fitted.width, height: fitted.height)
                        .programTransitionRole(.incoming, preset: transition.preset, progress: transition.progress)
                        ProgramTransitionOverlay(preset: transition.preset, progress: transition.progress)
                        if showsChrome { chrome }
                    } else {
                        programLayers
                        if showsChrome { chrome }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .clipped()
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .background(ProShowTheme.stageBlack)
            .lockFlickerFreeBackground()
            .clipped()
            .environment(\.proShowVideoInputs, videoInputs)
            .environment(\.proShowPlayback, playback)
            .environment(\.programRenderPaused, isRenderingPaused)
            .environment(\.proShowProgramVideoInput, stack.videoInput)
            .environment(\.proShowShowsProgramVideoLayer, stack.isVisible(.videoInput, onStage: onStage))
            #if os(macOS)
            .environment(\.mirrorsProgramPlayer, true)
            #endif
            .transaction { $0.animation = nil }
        } else {
            programLayers
                .environment(\.proShowVideoInputs, videoInputs)
                .environment(\.proShowPlayback, playback)
                .environment(\.programRenderPaused, isRenderingPaused)
                .environment(\.proShowProgramVideoInput, stack.videoInput)
                .environment(\.proShowShowsProgramVideoLayer, stack.isVisible(.videoInput, onStage: onStage))
                #if os(macOS)
                .environment(\.mirrorsProgramPlayer, true)
                #endif
        }
    }

    @ViewBuilder
    private var programLayers: some View {
        ZStack {
            layer1ScreenColor
            if outputEnabled {
                layer2VideoInput
                layer3Media
                layer4Slide
                layer5Announcements
                layer6Props
                layer7Messages
                layer8Mask
                chatOverlay
            }
        }
    }

    private func isLayerAudioMuted(_ layer: RenderLayer) -> Bool {
        stack.audioMuted || stack.isAudioMuted(layer)
    }

    @ViewBuilder
    private var layer1ScreenColor: some View {
        if outputEnabled, stack.isVisible(.screenColor, onStage: onStage) {
            Color(hex: stack.screenColorHex) ?? ProShowTheme.stageBlack
        } else {
            ProShowTheme.stageBlack
        }
    }

    @ViewBuilder
    private var layer2VideoInput: some View {
        if stack.videoInput != nil || stack.pipInput != nil {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if let input = stack.videoInput {
                        videoTile(input, in: proxy.size, bounds: stack.primaryBounds)
                    }
                    if let pip = stack.pipInput {
                        videoTile(pip, in: proxy.size, bounds: stack.pipBounds)
                    }
                }
            }
            .hiddenKeepingAlive(!stack.isVisible(.videoInput, onStage: onStage))
            .allowsHitTesting(false)
        }
    }

    private func videoTile(_ input: VideoInputSource, in size: CGSize, bounds: CanvasRect) -> some View {
        let spaceW = max(stack.slideCanvasWidth, Double(compositor.outputWidth), CanvasConfig.width, 1)
        let spaceH = max(stack.slideCanvasHeight, Double(compositor.outputHeight), CanvasConfig.height, 1)
        let scale = min(size.width / spaceW, size.height / spaceH)
        return ZStack {
            Color.black
            liveVideoFill(input)
        }
        .frame(width: bounds.width * scale, height: bounds.height * scale)
        .offset(x: bounds.x * scale, y: bounds.y * scale)
        .clipped()
        .accessibilityLabel(input.label)
    }

    @ViewBuilder
    private func liveVideoFill(_ input: VideoInputSource) -> some View {
        ZStack {
            videoFallback(input)
            LivePixelPreview(
                endpoint: input.endpoint,
                sourceID: input.id.uuidString,
                isPaused: isRenderingPaused
            )
        }
    }

    private func videoFallback(_ input: VideoInputSource) -> some View {
        VStack(spacing: 8) {
            Image(systemName: input.kind == .screenShare ? "rectangle.dashed" : "video.fill")
                .font(.largeTitle)
            Text(input.label)
                .font(.headline)
        }
        .foregroundStyle(.white.opacity(0.85))
    }

    @ViewBuilder
    private var layer3Media: some View {
        if let media = stack.media {
            Group {
                if let letter = media.placeholderLetter, let mapped = resolvePlaceholderSource?(letter) {
                    AssignedSourcePreview(
                        source: mapped,
                        playsVideo: true,
                        mutesVideo: isLayerAudioMuted(.media)
                            || mapped.audioMuted == true
                            || !stack.isVisible(.media, onStage: onStage),
                        preferSharedProgramClock: true
                    )
                } else if let letter = media.placeholderLetter {
                    PlaceholderLetterCard(letter: letter, tintHex: media.tintHex, cornerRadius: 28)
                        .padding(8)
                } else {
                    ZStack {
                        (Color(hex: media.tintHex) ?? Color(red: 0.12, green: 0.18, blue: 0.22))
                            .opacity(0.88)
                        MediaBackdropView(media: media, playback: playback)
                            .clipped()
                    }
                }
            }
            .hiddenKeepingAlive(!stack.drawsProgramMediaBackdrop(onStage: onStage))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var layer4Slide: some View {
        if !stack.slideCanvas.isEmpty || !stack.slideElements.isEmpty {
            ZStack {
                if stack.slideBackgroundEnabled {
                    Color(hex: stack.slideBackgroundHex) ?? ProShowTheme.stageBlack
                }
                if !stack.slideCanvas.isEmpty {
                    ProgramSlideCanvas(
                        objects: stack.slideCanvas,
                        canvasWidth: stack.slideCanvasWidth,
                        canvasHeight: stack.slideCanvasHeight,
                        playsAssignedVideo: true,
                        muteAssignedVideo: isLayerAudioMuted(.slide)
                    )
                    .id(compositor.slideRevision)
                } else if !stack.slideElements.isEmpty {
                    GeometryReader { proxy in
                        VStack(spacing: max(8, proxy.size.height * 0.03)) {
                            ForEach(Array(stack.slideElements.enumerated()), id: \.offset) { _, element in
                                Text(element.text)
                                    .font(.system(size: max(10, proxy.size.height * 0.08), weight: .semibold, design: .serif))
                                    .multilineTextAlignment(element.alignment == "left" ? .leading : (element.alignment == "right" ? .trailing : .center))
                                    .foregroundStyle(ProShowTheme.lyricWhite)
                                    .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
                                    .minimumScaleFactor(0.2)
                                    .lineLimit(8)
                                    .frame(
                                        maxWidth: proxy.size.width * 0.86,
                                        alignment: element.alignment == "left" ? .leading : (element.alignment == "right" ? .trailing : .center)
                                    )
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    .clipped()
                }
            }
            .hiddenKeepingAlive(!stack.isVisible(.slide, onStage: onStage))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var layer5Announcements: some View {
        if stack.isVisible(.announcements, onStage: onStage), let text = stack.announcement {
            VStack {
                Spacer()
                Text(text)
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
            }
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private var layer6Props: some View {
        if !stack.activeProps.isEmpty {
            ZStack {
                ForEach(compositor.propCanvases) { canvas in
                    if stack.activeProps.contains(canvas.name), !canvas.objects.isEmpty {
                        ProgramSlideCanvas(
                            objects: canvas.objects,
                            canvasWidth: canvas.canvasWidth,
                            canvasHeight: canvas.canvasHeight,
                            playsAssignedVideo: true,
                            muteAssignedVideo: isLayerAudioMuted(.props),
                            evaluationMode: .liveClock,
                            buildClockOverride: canvas.buildClock(),
                            includedPhases: canvas.buildPhases
                        )
                    }
                }
                if compositor.propCanvases.allSatisfy(\.objects.isEmpty) {
                    VStack {
                        HStack {
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                ForEach(stack.activeProps, id: \.self) { name in
                                    Text(name)
                                        .font(.caption.weight(.bold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.black.opacity(0.5))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(16)
                }
            }
            .hiddenKeepingAlive(!stack.isVisible(.props, onStage: onStage))
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var layer7Messages: some View {
        if stack.isVisible(.messages, onStage: onStage), let text = stack.message {
            VStack {
                HStack {
                    Text(text)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ProShowTheme.liveRed.opacity(0.9))
                        .foregroundStyle(.white)
                    Spacer()
                }
                Spacer()
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var layer8Mask: some View {
        if stack.isVisible(.mask, onStage: onStage), stack.maskEnabled {
            RadialGradient(
                colors: [.clear, .black.opacity(0.55)],
                center: .center,
                startRadius: 80,
                endRadius: 520
            )
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var chatOverlay: some View {
        if let card = stack.chatOverlay, card.visible {
            VStack {
                Spacer()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(card.message.author)
                                .font(.caption.weight(.bold))
                            Text(card.message.platform.displayTitle.uppercased())
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ProShowTheme.liveRed.opacity(0.85))
                        }
                        Text(card.message.text)
                            .font(.callout)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Spacer()
                }
                .padding(24)
            }
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Text("PROGRAM")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(ProShowTheme.liveRed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45))
                Spacer()
            }
            .padding(16)
            Spacer()
        }
    }
}

private enum ProgramTransitionRole {
    case outgoing
    case incoming
}

private struct ProgramTransitionRoleModifier: ViewModifier {
    var role: ProgramTransitionRole
    var preset: TransitionPreset
    var progress: Double

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let t = min(1, max(0, progress))
            let width = proxy.size.width
            let height = proxy.size.height
            content
                .frame(width: width, height: height)
                .opacity(opacity(t))
                .offset(x: offsetX(t, width: width), y: offsetY(t, height: height))
                .scaleEffect(scale(t))
                .mask(alignment: .leading) { wipeMask(t, width: width, height: height) }
        }
        .allowsHitTesting(false)
    }

    private func opacity(_ t: Double) -> Double {
        switch (preset.id, role) {
        case ("fade", .outgoing): max(0, 1 - t * 2)
        case ("fade", .incoming): max(0, t * 2 - 1)
        case (_, .outgoing) where isCrossfade:
            1 - t
        case (_, .incoming) where isCrossfade:
            t
        case ("stinger_flame", .outgoing): t < 0.5 ? 1 : 0
        case ("stinger_flame", .incoming): t >= 0.5 ? 1 : 0
        case (_, .outgoing) where isWipeLike:
            1
        case (_, .incoming) where isWipeLike:
            1
        default:
            role == .incoming ? 1 : (1 - t)
        }
    }

    private func offsetX(_ t: Double, width: CGFloat) -> CGFloat {
        switch (preset.id, role) {
        case ("push", .outgoing), ("whip_pan", .outgoing):
            -width * t
        case ("push", .incoming), ("whip_pan", .incoming):
            width * (1 - t)
        case ("glitch", .incoming):
            CGFloat(sin(t * 42) * (1 - t) * 10)
        default:
            0
        }
    }

    private func offsetY(_ t: Double, height: CGFloat) -> CGFloat {
        switch (preset.id, role) {
        case ("glitch", .outgoing):
            CGFloat(cos(t * 36) * (1 - t) * 6)
        default:
            0
        }
    }

    private func scale(_ t: Double) -> CGFloat {
        switch (preset.id, role) {
        case ("cross_zoom", .outgoing):
            1 + 0.28 * t
        case ("cross_zoom", .incoming):
            0.72 + 0.28 * t
        case ("liquid", .incoming):
            0.94 + 0.06 * t
        default:
            1
        }
    }

    @ViewBuilder
    private func wipeMask(_ t: Double, width: CGFloat, height: CGFloat) -> some View {
        if isWipeLike, role == .incoming {
            Rectangle()
                .frame(width: max(1, width * t), height: height)
        } else if isWipeLike, role == .outgoing {
            Rectangle().frame(width: width, height: height)
        } else {
            Rectangle().frame(width: width, height: height)
        }
    }

    private var isCrossfade: Bool {
        ["dissolve", "liquid", "light_leak", "lens_flare", "ripple", "displace"].contains(preset.id)
    }

    private var isWipeLike: Bool {
        ["wipe", "lottie_wipe", "page_curl"].contains(preset.id)
    }
}

private struct ProgramTransitionOverlay: View {
    var preset: TransitionPreset
    var progress: Double

    var body: some View {
        let t = min(1, max(0, progress))
        ZStack {
            if preset.id == "light_leak" || preset.id == "lens_flare" {
                LinearGradient(
                    colors: [
                        Color.orange.opacity(0.55 * sin(t * .pi)),
                        Color.yellow.opacity(0.2 * sin(t * .pi)),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            if preset.id == "stinger_flame" {
                LinearGradient(
                    colors: [
                        Color.red.opacity(t < 0.55 ? 0.85 : 0),
                        Color.orange.opacity(t < 0.7 ? 0.7 : 0),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .offset(x: CGFloat((t - 0.5) * 2) * 40)
            }
            if preset.id == "glitch" {
                Rectangle()
                    .fill(Color.cyan.opacity(0.12 * (1 - t)))
                    .blendMode(.screen)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private extension View {
    func programTransitionRole(_ role: ProgramTransitionRole, preset: TransitionPreset, progress: Double) -> some View {
        modifier(ProgramTransitionRoleModifier(role: role, preset: preset, progress: progress))
    }
}

/// Live stage surface rendered from the Stage editor document.
struct StageDisplayView: View {
    @Bindable var controller: ShowController

    var body: some View {
        LiveStageView(controller: controller)
    }
}

struct LiveStageView: View {
    @Bindable var controller: ShowController

    @ViewBuilder
    private func rundownStageOverlay(scale: CGFloat) -> some View {
        if controller.rundownClock.isShowRunning {
            VStack(spacing: 8 * scale) {
                if let title = controller.rundownStageSegmentTitle {
                    Text(title)
                        .font(.system(size: 28 * scale, weight: .semibold))
                        .foregroundStyle(ProShowTheme.lyricWhite)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if controller.stageDisplayLayout.showCountdown,
                   let countdown = controller.rundownStageCountdownText {
                    Text(countdown)
                        .font(.system(size: 56 * scale, weight: .bold).monospacedDigit())
                        .foregroundStyle(ProShowTheme.accent)
                }
                if let next = controller.rundownStageNextCue {
                    Text(next)
                        .font(.system(size: 20 * scale, weight: .medium))
                        .foregroundStyle(ProShowTheme.statusOn)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12 * scale)
                }
            }
            .padding(.top, 24 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let document = controller.liveStageDocument
            let payload = StagePayload.make(controller: controller)
            let clock = StageLiveBinder.clockString(from: context.date)
            let timerText = controller.inspector.timers.first.map { ProgramTimecode.format(TimeInterval($0.displaySeconds)) }
            let liveContext = controller.dynamicTextContext(now: context.date)
            GeometryReader { proxy in
                let scale = min(
                    proxy.size.width / max(document.canvasWidth, 1),
                    proxy.size.height / max(document.canvasHeight, 1)
                )
                ZStack(alignment: .topLeading) {
                    (Color(hex: document.backgroundHex) ?? ProShowTheme.stageBlack)
                    if controller.stageDisplayLayout.showAlertBanner, !controller.stageAlertBanner.isEmpty {
                        Text(controller.stageAlertBanner)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(ProShowTheme.lyricWhite)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(ProShowTheme.liveRed)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Stage alert \(controller.stageAlertBanner)")
                    }
                    rundownStageOverlay(scale: scale)
                    ForEach(document.objects.sorted(by: { $0.zIndex < $1.zIndex })) { object in
                        let text = StageLiveBinder.resolvedText(
                            for: object,
                            payload: payload,
                            clock: clock,
                            timerText: timerText,
                            context: liveContext
                        )
                        Text(text)
                            .font(.custom(
                                object.typography.fontFamily.isEmpty ? "Helvetica" : object.typography.fontFamily,
                                size: max(1, object.fontSize * scale)
                            ).weight(.semibold))
                            .foregroundStyle(Color(hex: object.fontColor) ?? ProShowTheme.lyricWhite)
                            .multilineTextAlignment(.leading)
                            .minimumScaleFactor(0.2)
                            .lineLimit(8)
                            .frame(
                                width: max(1, object.bounds.width * scale),
                                height: max(1, object.bounds.height * scale),
                                alignment: .topLeading
                            )
                            .clipped()
                            .offset(x: object.bounds.x * scale, y: object.bounds.y * scale)
                    }
                }
                .frame(width: document.canvasWidth * scale, height: document.canvasHeight * scale)
                .clipped()
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .background(ProShowTheme.stageBlack)
        .clipped()
    }
}

private struct MediaBackdropView: View {
    let media: MediaAction
    var playback: MediaPlaybackEngine?

    var body: some View {
        let url = playback?.fileURL ?? media.resolvedFileURL(projectRoot: playback?.projectRoot)
        if media.isImage, let image = url.flatMap({ ResolvedCanvasMedia.image(atPath: $0.path) ?? ResolvedCanvasMedia.image(at: $0.path) })
            ?? media.filePath.flatMap({ ResolvedCanvasMedia.image(at: $0) }) {
            image
                .resizable()
                .scaledToFill()
        } else if !media.isImage, let playback, playback.canPresentVideo || (url.map { MediaLoader.hasVideoTrack(at: $0) } ?? false) {
            SharedProgramPlayerView(playback: playback)
        } else {
            MediaPreviewFrame(
                filePath: media.filePath,
                artworkURL: url,
                kind: media.isImage ? .image : .video(duration: media.duration ?? ""),
                tintHex: media.tintHex,
                cornerRadius: 0
            )
        }
    }
}

#if os(macOS)
private final class CapturePreviewNSView: ProShowLayerHostView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        DeskLiveLayer.pin(previewLayer, in: self)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        DeskLiveLayer.layout(previewLayer, in: bounds)
    }
}

private struct CapturePreviewLayerView: NSViewRepresentable {
    var session: AVCaptureSession

    func makeNSView(context: Context) -> CapturePreviewNSView {
        let view = CapturePreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ nsView: CapturePreviewNSView, context: Context) {
        nsView.previewLayer.session = session
        DeskLiveLayer.layout(nsView.previewLayer, in: nsView.bounds)
    }
}
#else
private final class CapturePreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

private struct CapturePreviewLayerView: UIViewRepresentable {
    var session: AVCaptureSession

    func makeUIView(context: Context) -> CapturePreviewUIView {
        let view = CapturePreviewUIView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: CapturePreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }
}
#endif

enum CanvasObjectDrawing {
    static func shapePath(for object: CanvasObject, size: CGSize, scale: CGFloat) -> Path {
        if let vector = object.vectorPath, vector.nodes.count >= 2 {
            return vectorPath(vector, object: object, scale: scale)
        }
        let rect = CGRect(origin: .zero, size: size)
        switch object.kind {
        case .ellipse, .cutout:
            return Path(ellipseIn: rect)
        case .line:
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            return path
        case .polygon:
            var path = Path()
            path.move(to: CGPoint(x: size.width / 2, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: size.height * 0.78))
            path.addLine(to: CGPoint(x: 0, y: size.height * 0.78))
            path.closeSubpath()
            return path
        default:
            return roundedRectPath(for: object, rect: rect, scale: scale)
        }
    }

    static func roundedRectPath(for object: CanvasObject, rect: CGRect, scale: CGFloat) -> Path {
        let radii = object.resolvedCornerRadii
        let style: RoundedCornerStyle = (object.stroke.cornerSmoothing ?? 0) > 0.01 ? .continuous : .circular
        return UnevenRoundedRectangle(
            topLeadingRadius: max(0, radii.topLeft) * scale,
            bottomLeadingRadius: max(0, radii.bottomLeft) * scale,
            bottomTrailingRadius: max(0, radii.bottomRight) * scale,
            topTrailingRadius: max(0, radii.topRight) * scale,
            style: style
        ).path(in: rect)
    }

    private static func vectorPath(_ vector: VectorPath, object: CanvasObject, scale: CGFloat) -> Path {
        var path = Path()
        guard let first = vector.nodes.first else { return path }
        let ox = object.bounds.x
        let oy = object.bounds.y
        path.move(to: CGPoint(x: (first.x - ox) * scale, y: (first.y - oy) * scale))
        for node in vector.nodes.dropFirst() {
            path.addLine(to: CGPoint(x: (node.x - ox) * scale, y: (node.y - oy) * scale))
        }
        if vector.closed {
            path.closeSubpath()
        }
        return path
    }
}

struct CanvasObjectShapeLayer: View {
    let object: CanvasObject
    var width: CGFloat
    var height: CGFloat
    var scale: CGFloat
    var playsAssignedVideo: Bool = false
    var muteAssignedVideo: Bool = true
    @Environment(\.resolvePlaceholderSource) private var resolvePlaceholderSource
    @Environment(\.proShowPlayback) private var playback
    @Environment(\.preferSharedProgramClock) private var lockToProgramClock
    @Environment(\.mirrorsProgramPlayer) private var mirrorsProgramPlayer
    @Environment(\.programRenderPaused) private var programRenderPaused

    var body: some View {
        let path = CanvasObjectDrawing.shapePath(for: object, size: CGSize(width: width, height: height), scale: scale)
        ZStack {
            filled(path)
            assignedOverlay(path)
            if object.stroke.style != .none {
                path.stroke(Color(hex: object.stroke.color) ?? .white, style: strokeStyle)
            }
        }
        .frame(width: width, height: height)
    }

    private var mediaStyle: MediaFrameStyle {
        MediaFrameStyle.from(object, scale: scale)
    }

    @ViewBuilder
    private func assignedOverlay(_ path: Path) -> some View {
        if let assigned = resolvedAssignedSource(), assigned.isMappedFill {
            AssignedSourcePreview(
                source: assigned,
                canvasObjectKind: object.kind,
                cornerRadius: mediaStyle.cornerRadius,
                playsVideo: playsAssignedVideo,
                mutesVideo: muteAssignedVideo || object.isAudioMuted || assigned.audioMuted == true,
                preferSharedProgramClock: lockToProgramClock
                    || playback?.sharesClock(with: object) == true
                    || playback?.sharesClock(with: assigned) == true
                    || (object.programMediaAction().map { playback?.sharesClock(with: $0) == true } ?? false),
                style: mediaStyle
            )
                .frame(width: width, height: height)
        } else if playsAssignedVideo, object.fill.type == .image, AssignedMediaSource.pathLooksLikeVideo(object.fill.imageURI) {
            Group {
                if let playback, lockToProgramClock || playback.sharesClock(with: object) || playback.sharesClock(withPath: object.fill.imageURI) {
                    SharedProgramPlayerView(
                        playback: playback,
                        presentation: mirrorsProgramPlayer ? .mirroredFrame : .playerLayer,
                        style: mediaStyle
                    )
                } else {
                    SlotVideoPlayerView(
                        path: object.fill.imageURI,
                        tintHex: object.fill.color,
                        isMuted: muteAssignedVideo || object.isAudioMuted,
                        startAt: playback?.playhead ?? 0,
                        style: mediaStyle,
                        decodePriority: object.zIndex,
                        isOnScreen: !programRenderPaused && object.visibleOnAudience
                    )
                }
            }
                .frame(width: width, height: height)
                .opacity(mediaStyle.opacity)
        } else if object.fill.type == .image, let image = ResolvedCanvasMedia.image(at: object.fill.imageURI) {
            let offset = MediaFrameEngine.imageOffset(style: mediaStyle, width: width, height: height)
            image
                .resizable()
                .aspectRatio(contentMode: object.fill.imageScaleMode == .fit ? .fit : .fill)
                .scaleEffect(object.fill.imageScaleMode == .crop ? mediaStyle.cropZoom : 1)
                .offset(x: offset.width, y: offset.height)
                .frame(width: width, height: height)
                .clipped()
                .mask(path)
                .opacity(mediaStyle.opacity)
        } else if let letter = object.assignedPlaceholderLetter, resolvedAssignedSource() == nil, ResolvedCanvasMedia.image(at: object.fill.imageURI) == nil {
            PlaceholderLetterCard(
                letter: letter,
                tintHex: object.assignedSource?.tintHex ?? object.fill.color,
                cornerRadius: mediaStyle.cornerRadius
            )
                .frame(width: width, height: height)
                .mask(path)
        }
    }

    private func resolvedAssignedSource() -> AssignedMediaSource? {
        if let assigned = object.assignedSource, assigned.isMappedFill {
            return assigned
        }
        if let letter = object.assignedPlaceholderLetter, let mapped = resolvePlaceholderSource?(letter) {
            return mapped
        }
        return object.assignedSource
    }

    @ViewBuilder
    private func filled(_ path: Path) -> some View {
        if object.fill.type == .none {
            path.fill(.clear)
        } else if object.fill.type == .image, ResolvedCanvasMedia.image(at: object.fill.imageURI) != nil {
            path.fill(.clear)
        } else if object.fill.type == .gradient {
            switch object.fill.gradientType {
            case .radial:
                path.fill(radialFill, style: FillStyle(eoFill: object.kind == .cutout))
            case .angular:
                path.fill(angularFill, style: FillStyle(eoFill: object.kind == .cutout))
            case .linear:
                path.fill(linearFill, style: FillStyle(eoFill: object.kind == .cutout))
            }
        } else {
            path.fill(solidFill, style: FillStyle(eoFill: object.kind == .cutout))
        }
    }

    private var solidFill: Color {
        (Color(hex: object.fill.color) ?? .white).opacity(object.fill.opacity)
    }

    private var linearFill: LinearGradient {
        let stops = object.fill.gradientStops.compactMap { Color(hex: $0.color) }
        let angle = object.fill.gradientAngle * .pi / 180
        return LinearGradient(
            colors: stops.isEmpty ? [solidFill, .black] : stops,
            startPoint: UnitPoint(x: 0.5 - cos(angle) / 2, y: 0.5 - sin(angle) / 2),
            endPoint: UnitPoint(x: 0.5 + cos(angle) / 2, y: 0.5 + sin(angle) / 2)
        )
    }

    private var radialFill: RadialGradient {
        let stops = object.fill.gradientStops.compactMap { Color(hex: $0.color) }
        return RadialGradient(
            colors: stops.isEmpty ? [solidFill, .black] : stops,
            center: .center,
            startRadius: 0,
            endRadius: max(width, height) / 2
        )
    }

    private var angularFill: AngularGradient {
        let stops = object.fill.gradientStops.compactMap { Color(hex: $0.color) }
        return AngularGradient(
            colors: stops.isEmpty ? [solidFill, .black] : stops,
            center: .center,
            angle: .degrees(object.fill.gradientAngle)
        )
    }

    private var strokeStyle: SwiftUI.StrokeStyle {
        let dash = object.stroke.dashPattern ?? (object.stroke.style == .dashed ? [8, 5] : (object.stroke.style == .dotted ? [2, 3] : []))
        let cap: CGLineCap
        switch object.stroke.cap ?? .butt {
        case .butt: cap = .butt
        case .round: cap = .round
        case .square: cap = .square
        }
        let join: CGLineJoin
        switch object.stroke.join ?? .miter {
        case .miter: join = .miter
        case .round: join = .round
        case .bevel: join = .bevel
        }
        return SwiftUI.StrokeStyle(
            lineWidth: max(0.5, object.stroke.width * scale),
            lineCap: cap,
            lineJoin: join,
            dash: dash.map { CGFloat($0) * scale }
        )
    }
}

/// Program / preview renderer. Document pixels (including 4K) are contain-fitted; they never size the UI.
struct ProgramSlideCanvas: View {
    var objects: [CanvasObject]
    var canvasWidth: Double
    var canvasHeight: Double
    var playsAssignedVideo: Bool = false
    var muteAssignedVideo: Bool = true
    var evaluationMode: AnimationEvaluationMode? = nil
    var buildClockOverride: BuildClock? = nil
    var includedPhases: Set<BuildPhase>? = nil

    @Environment(\.buildClock) private var buildClock
    @Environment(\.animationEvaluationMode) private var inheritedEvaluationMode

    private var resolvedEvaluationMode: AnimationEvaluationMode {
        evaluationMode ?? inheritedEvaluationMode
    }

    var body: some View {
        let rest = resolvedEvaluationMode.usesSettledRestState
        let clock = rest ? BuildClock.idle : (buildClockOverride ?? buildClock)
        PulsedBuildEnvironment(isActive: !rest, clock: { clock }) {
        GeometryReader { proxy in
            let scale = min(
                proxy.size.width / max(canvasWidth, 1),
                proxy.size.height / max(canvasHeight, 1)
            )
            let fitted = CGSize(width: canvasWidth * scale, height: canvasHeight * scale)
            ZStack(alignment: .topLeading) {
                ForEach(objects.sorted { $0.zIndex < $1.zIndex }) { object in
                    if object.visibleOnAudience {
                        ProgramCanvasObjectView(
                            object: object,
                            canvasObjects: objects,
                            slideSteps: objects.flatMap(\.resolvedBuildSteps),
                            scale: scale,
                            playsAssignedVideo: playsAssignedVideo,
                            muteAssignedVideo: muteAssignedVideo
                        )
                    }
                }
            }
            .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
            .clipped()
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        }
        .clipped()
        .environment(\.animationEvaluationMode, resolvedEvaluationMode)
        .environment(\.buildClock, clock)
        .environment(\.buildPhaseFilter, includedPhases)
    }
}

private struct ProgramCanvasObjectView: View {
    let object: CanvasObject
    var canvasObjects: [CanvasObject] = []
    var slideSteps: [ElementBuildStep] = []
    let scale: CGFloat
    var playsAssignedVideo: Bool = false
    var muteAssignedVideo: Bool = true
    @Environment(\.dynamicText) private var dynamicText
    @Environment(\.liveQuoteEngine) private var liveQuoteEngine
    @Environment(\.proShowPlayback) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { max(1, object.transform.width * scale) }
    private var height: CGFloat { max(1, object.transform.height * scale) }

    var body: some View {
        BuildAnimated(object: object, slideSteps: slideSteps, scale: scale) { state in
            programBody(state)
        }
    }

    @ViewBuilder
    private func programBody(_ state: TransformedRenderState) -> some View {
        let label = Group {
            if object.isTextLike {
                objectLabel(state)
                    .canvasTextBoxFrame(object: object, width: width, height: height, scale: scale)
            } else {
                objectLabel(state)
                    .frame(width: width, height: height, alignment: .topLeading)
            }
        }
        .canvasElementShimmer(object.resolvedShimmer, scale: scale)
        if object.hostsLayerBackedMedia {
            label
                .shadow(color: dropShadowColor, radius: dropShadowRadius, x: dropShadowX, y: dropShadowY)
                .rotationEffect(.degrees(object.transform.rotation))
                .scaleEffect(x: object.transform.flipHorizontal ? -1 : 1, y: object.transform.flipVertical ? -1 : 1)
                .blendMode(layerBlend)
                .opacity(object.opacity)
                .hiddenKeepingAlive(object.opacity < 0.02)
                .offset(x: object.transform.x * scale, y: object.transform.y * scale)
        } else {
            label
                .clipped()
                .opacity(object.opacity)
                .rotationEffect(.degrees(object.transform.rotation))
                .scaleEffect(x: object.transform.flipHorizontal ? -1 : 1, y: object.transform.flipVertical ? -1 : 1)
                .offset(x: object.transform.x * scale, y: object.transform.y * scale)
        }
    }

    @ViewBuilder
    private func objectLabel(_ state: TransformedRenderState) -> some View {
        if object.isTextLike {
            if let liveQuoteEngine {
                LiveQuoteRefreshScope(engine: liveQuoteEngine) {
                    objectLabelText(state)
                }
            } else {
                objectLabelText(state)
            }
        } else {
            CanvasObjectShapeLayer(
                object: object,
                width: width,
                height: height,
                scale: scale,
                playsAssignedVideo: playsAssignedVideo,
                muteAssignedVideo: muteAssignedVideo
            )
        }
    }

    @ViewBuilder
    private func objectLabelText(_ state: TransformedRenderState) -> some View {
        TimelineView(.periodic(from: .now, by: textTimelineInterval)) { timeline in
            let context = countdownContext(at: timeline.date)
            if DynamicTextEngine.shouldDeferProgramLiveQuoteOutput(
                object: object,
                context: context,
                canvasObjects: canvasObjects
            ) {
                Color.clear
            } else {
            let resolved = DynamicTextEngine.resolve(object, context: context)
            if object.textLayout.isLooping {
                MarqueeTextLoopView(
                    object: object,
                    text: DynamicTextEngine.loopScrollText(for: object, resolved: resolved),
                    scale: scale,
                    reduceMotion: reduceMotion,
                    canvasObjects: canvasObjects,
                    liveQuotes: context.quotes,
                    dynamicTextContext: context
                )
            } else if MarketTickerRouting.usesStaticColoredLiveQuote(object) {
                StaticColoredLiveQuoteView(
                    object: object,
                    canvasObjects: canvasObjects,
                    scale: scale,
                    liveQuotes: context.quotes
                )
            } else {
                marqueeText(resolved, context: context, state: state)
            }
            }
        }
    }

    private var textTimelineInterval: TimeInterval {
        if object.textLayout.isLooping { return object.kind.usesLiveText ? 1 : 60 }
        if object.resolvedCountdownValueSource == .programMedia { return 0.25 }
        if object.kind.usesLiveText { return 1 }
        if !DynamicTextEngine.requiredLiveQuoteRequests(for: object, canvasObjects: canvasObjects).isEmpty { return 1 }
        return 60
    }

    private func countdownContext(at date: Date) -> DynamicTextContext {
        var context = LiveQuoteEnvironment.mergedContext(
            base: dynamicText,
            engine: liveQuoteEngine,
            at: date
        )
        if object.resolvedCountdownValueSource == .programMedia, let playback, playback.duration > 0.05 {
            context.mediaRemainingSeconds = Int(playback.remaining.rounded(.towardZero))
        }
        if let liveQuoteEngine {
            context.liveQuotesInitialLoadPending = liveQuoteEngine.isAwaitingFirstQuotePayload
        }
        return context
    }

    @ViewBuilder
    private func marqueeText(_ value: String, context: DynamicTextContext, state: TransformedRenderState) -> some View {
        if state.usesMarquee {
            Group {
                if state.marqueeVertical {
                    VStack(spacing: max(0, state.marqueeGapPx * scale)) {
                        programText(value, context: context).fixedSize(horizontal: false, vertical: true)
                        programText(value, context: context).fixedSize(horizontal: false, vertical: true)
                    }
                    .offset(y: state.scrollOffsetPx * scale)
                } else {
                    HStack(spacing: max(0, state.marqueeGapPx * scale)) {
                        programText(value, context: context).fixedSize(horizontal: true, vertical: false)
                        programText(value, context: context).fixedSize(horizontal: true, vertical: false)
                    }
                    .offset(x: state.scrollOffsetPx * scale)
                }
            }
        } else {
            programText(value, context: context)
        }
    }

    private func programText(_ value: String, context: DynamicTextContext? = nil, expands: Bool = true) -> some View {
        Group {
            #if os(macOS)
            if LiveQuoteDisplayRouting.usesTokenDisplayTemplate(object),
               let context,
               let liveQuote = LiveQuoteTemplateRenderer.makeAttributedString(
                   object: object,
                   scale: scale,
                   context: context,
                   colorConfig: TickerConfigStore.shared.colorConfig
               ) {
                CanvasStaticAttributedTextView(object: object, attributed: liveQuote, scale: scale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: object.canvasTextFrameAlignment)
            } else {
            Text(AttributedString(TextAttributeConverter.makeAttributedString(
                object: object,
                text: value,
                scale: scale
            )))
            .multilineTextAlignment(textAlignment)
            }
            #else
            Text(value)
                .font(canvasFont)
                .italic(object.typography.isItalic)
                .underline(object.typography.isUnderline)
                .strikethrough(object.typography.isStrikethrough)
                .foregroundStyle(Color(hex: object.typography.color) ?? ProShowTheme.lyricWhite)
                .shadow(color: outlineColor, radius: 0, x: outlineWidth, y: 0)
                .shadow(color: outlineColor, radius: 0, x: -outlineWidth, y: 0)
                .shadow(color: outlineColor, radius: 0, x: 0, y: outlineWidth)
                .shadow(color: outlineColor, radius: 0, x: 0, y: -outlineWidth)
                .shadow(
                    color: textShadowColor,
                    radius: textShadowRadius,
                    x: object.textShadow.enabled ? cos(object.textShadow.angle * .pi / 180) * object.textShadow.offset * scale : 0,
                    y: object.textShadow.enabled ? sin(object.textShadow.angle * .pi / 180) * object.textShadow.offset * scale : 0
                )
                .multilineTextAlignment(textAlignment)
                .lineSpacing(max(0, (object.textLayout.lineHeight - 1) * object.typography.fontSize * scale))
                .kerning(object.textLayout.characterSpacing * scale)
            #endif
        }
        .modifier(LoopingTextFit(layout: object.textLayout, maxLines: CanvasTextBoxLayout.autoFitMaxLines))
        .frame(
            maxWidth: expands ? .infinity : nil,
            maxHeight: expands ? .infinity : nil,
            alignment: CanvasTextBoxLayout.frameAlignment(for: object)
        )
    }

    private var layerBlend: BlendMode {
        switch object.blendMode ?? .normal {
        case .multiply: .multiply
        case .screen: .screen
        case .overlay: .overlay
        case .darken: .darken
        case .lighten: .lighten
        case .colorBurn: .colorBurn
        case .colorDodge: .colorDodge
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        case .linearBurn: .plusDarker
        case .linearDodge: .plusLighter
        default: .normal
        }
    }

    private var dropShadowColor: Color {
        object.shadow.enabled ? (Color(hex: object.shadow.color) ?? .black).opacity(0.7) : .clear
    }

    private var dropShadowRadius: CGFloat {
        object.shadow.enabled ? max(0, object.shadow.blur * scale) : 0
    }

    private var dropShadowX: CGFloat {
        object.shadow.enabled ? cos(object.shadow.angle * .pi / 180) * object.shadow.offset * scale : 0
    }

    private var dropShadowY: CGFloat {
        object.shadow.enabled ? sin(object.shadow.angle * .pi / 180) * object.shadow.offset * scale : 0
    }

    private var canvasFont: Font {
        CanvasSwiftUIFont.resolve(
            family: object.typography.fontFamily,
            size: max(1, object.typography.fontSize * scale),
            weight: object.typography.fontWeight,
            bold: object.typography.isBold,
            italic: object.typography.isItalic
        )
    }

    private var outlineWidth: CGFloat {
        object.textOutline.enabled ? max(0.2, object.textOutline.width * scale) : 0
    }

    private var outlineColor: Color {
        object.textOutline.enabled ? (Color(hex: object.textOutline.color) ?? .black) : .clear
    }

    private var textShadowColor: Color {
        object.textShadow.enabled ? (Color(hex: object.textShadow.color) ?? .black) : .clear
    }

    private var textShadowRadius: CGFloat {
        object.textShadow.enabled ? max(0, object.textShadow.blur * scale) : 0
    }

    private var textAlignment: TextAlignment {
        switch object.textLayout.horizontalAlign {
        case .left, .justify, .justifyLeft, .justifyAll: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}
