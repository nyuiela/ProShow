import Foundation
import CoreGraphics
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(CoreText)
import CoreText
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(Metal)
import Metal
#endif
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(Accelerate)
import Accelerate
#endif
#if os(macOS)
import AppKit
#endif

enum StreamEncodeSource: String, Equatable, Sendable {
    case programComposite
    /// Last program frame duplicated while composite is in flight (strict CFR tags).
    case cfrHoldDuplicate
    /// SwiftUI `ProgramSurfaceView` raster (WYSIWYG with Audience).
    case audienceSurface
    case cleanFeed
}

/// Thread-safe last program frame for the encoder and ISO program take.
final class ProgramOutputStore: @unchecked Sendable {
    private let lock = NSLock()
    #if canImport(CoreVideo)
    private var buffer: CVPixelBuffer?
    #endif
    private(set) var lastCoveredLayers: [Int] = []

    #if canImport(CoreVideo)
    func set(_ next: CVPixelBuffer?, coveredLayers: [Int]) {
        lock.lock()
        buffer = next
        lastCoveredLayers = coveredLayers
        lock.unlock()
    }

    func current() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func invalidate() {
        lock.lock()
        buffer = nil
        lastCoveredLayers = []
        lock.unlock()
    }
    #endif
}

/// Off-screen composite for RTMP / ISO. Keep in parity with `LayeredAudienceView` / `ProgramSurfaceView`.
final class ProgramOutputComposer: @unchecked Sendable {
    static let shared = ProgramOutputComposer()
    static let previewEndpoint = "program.encode"

    static func needsLiveVideoPixel(for object: CanvasObject) -> Bool {
        if object.isUnfilledPlaceholder { return false }
        switch object.assignedSource?.sourceType {
        case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .rendezvousGuest, .srtStream:
            return true
        default:
            return object.kind == .videoInput
        }
    }

    /// Own a 32BGRA copy before the program clock draws. Capture pools reuse the
    /// original IOSurface, which otherwise composites as a blank camera or display.
    static func snapshot(_ source: CVPixelBuffer) -> CVPixelBuffer {
        let format = CVPixelBufferGetPixelFormatType(source)
        guard format == kCVPixelFormatType_32BGRA else { return source }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return source }
        guard let dest = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: width, height: height) else {
            return source
        }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return source }
        guard CVPixelBufferLockBaseAddress(dest, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            return source
        }
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dest, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dest) else { return source }
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(dest)
        let rowBytes = min(srcStride, dstStride, width * 4)
        guard rowBytes > 0 else { return source }
        for row in 0..<height {
            dstBase.advanced(by: row * dstStride).copyMemory(
                from: srcBase.advanced(by: row * srcStride),
                byteCount: rowBytes
            )
        }
        return dest
    }

    private let lock = NSLock()
    private let gate = TripleBufferManager.Gate()
    #if canImport(CoreImage)
    /// One Metal context for the whole process. Intermediates are not cached, so a frame cannot pile up in Core Image.
    private static let sharedCIContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ]
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        #endif
        return CIContext(options: options)
    }()
    private var ciContext: CIContext { Self.sharedCIContext }
    #endif
    #if canImport(CoreVideo)
    /// Static slide pixels. Rebuilt when the slide changes, then blended over the camera each frame.
    private var slideMidPlate: CVPixelBuffer?
    private var slideOverPlate: CVPixelBuffer?
    private var slidePlateSignature: Int?
    private var slidePlateWidth = 0
    private var slidePlateHeight = 0
    #endif
    #if canImport(VideoToolbox)
    private var scaleTransfer: VTPixelTransferSession?
    #endif

    private init() {}

    #if canImport(CoreVideo)
    /// One slide canvas, without the program video layer, at the destination frame size.
    func renderSlideBoard(
        objects: [CanvasObject],
        canvasWidth: Double,
        canvasHeight: Double,
        backgroundEnabled: Bool,
        backgroundHex: String,
        width: Int,
        height: Int,
        textContext: DynamicTextContext?,
        objectLivePixels: [UUID: CVPixelBuffer],
        buildPlayback: BuildPlayback = .rest,
        renderNow: Date,
        marketStreamItems: [MarketTickerItem] = [],
        tickerColorConfig: TickerColorConfig = TickerColorConfig(),
        propCanvases: [PropCanvas] = []
    ) -> CVPixelBuffer? {
        var stack = RenderStack.idle
        stack.screenColorHex = backgroundHex
        stack.slideElements = []
        stack.slideCanvas = objects
        stack.slideCanvasWidth = canvasWidth
        stack.slideCanvasHeight = canvasHeight
        stack.slideBackgroundEnabled = backgroundEnabled
        stack.slideBackgroundHex = backgroundHex
        stack.cleared = Set(RenderLayer.allCases.map(\.rawValue).filter {
            $0 != RenderLayer.slide.rawValue && !(propCanvases.isEmpty == false && $0 == RenderLayer.props.rawValue)
        })
        stack.activeProps = propCanvases.map(\.name)
        return render(
            stack: stack,
            width: width,
            height: height,
            video: nil,
            pip: nil,
            media: nil,
            videoFrame: nil,
            textContext: textContext,
            propCanvases: propCanvases,
            objectLivePixels: objectLivePixels,
            buildPlayback: buildPlayback,
            renderNow: renderNow,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColorConfig,
            matchOnAirVisibility: true
        )?.buffer
    }

    func render(
        stack: RenderStack,
        width: Int,
        height: Int,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        media: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?,
        textContext: DynamicTextContext? = nil,
        liveVideoForObject: ((CanvasObject) -> CVPixelBuffer?)? = nil,
        propCanvases: [PropCanvas] = [],
        objectLivePixels: [UUID: CVPixelBuffer] = [:],
        buildPlayback: BuildPlayback = .rest,
        buildPhaseFilter: Set<BuildPhase>? = nil,
        renderNow: Date = Date(),
        programTransition: ProgramTransitionState? = nil,
        propBuildPlayback: [UUID: BuildPlayback] = [:],
        marketStreamItems: [MarketTickerItem] = [],
        tickerColorConfig: TickerColorConfig = TickerColorConfig(),
        fallbackBuffer: CVPixelBuffer? = nil,
        matchOnAirVisibility: Bool = false,
        frameAdmissionMaxWait: TimeInterval = 0
    ) -> (buffer: CVPixelBuffer, covered: [Int])? {
        let outW = max(16, width)
        let outH = max(16, height)
        if let programTransition, programTransition.isActive {
            return renderProgramTransition(
                transition: programTransition,
                incoming: stack,
                width: outW,
                height: outH,
                video: video,
                pip: pip,
                media: media,
                videoFrame: videoFrame,
                textContext: textContext,
                liveVideoForObject: liveVideoForObject,
                propCanvases: propCanvases,
                objectLivePixels: objectLivePixels,
                buildPlayback: buildPlayback,
                buildPhaseFilter: buildPhaseFilter,
                renderNow: renderNow,
                propBuildPlayback: propBuildPlayback,
                marketStreamItems: marketStreamItems,
                tickerColorConfig: tickerColorConfig,
                fallbackBuffer: fallbackBuffer,
                matchOnAirVisibility: matchOnAirVisibility
            )
        }
        guard gate.beginFrame(maxWait: frameAdmissionMaxWait) != nil else {
            if let fallbackBuffer { return (fallbackBuffer, []) }
            return nil
        }
        defer { gate.endFrame() }
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: outW, height: outH) else {
            if let fallbackBuffer { return (fallbackBuffer, []) }
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        let covered = draw(
            stack: stack,
            target: target,
            video: video,
            pip: pip,
            media: media,
            videoFrame: videoFrame,
            textContext: textContext,
            liveVideoForObject: liveVideoForObject,
            propCanvases: propCanvases,
            objectLivePixels: objectLivePixels,
            buildPlayback: buildPlayback,
            buildPhaseFilter: buildPhaseFilter,
            renderNow: renderNow,
            propBuildPlayback: propBuildPlayback,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColorConfig,
            matchOnAirVisibility: matchOnAirVisibility
        )
        return (target, covered)
    }

    /// Uniform scale for RTMP / hub delivery (composite is always at program output resolution first).
    func scaledPixelBuffer(_ buffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        let targetW = max(16, width)
        let targetH = max(16, height)
        let sourceW = CVPixelBufferGetWidth(buffer)
        let sourceH = CVPixelBufferGetHeight(buffer)
        if sourceW == targetW, sourceH == targetH { return buffer }
        #if canImport(CoreImage)
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: targetW, height: targetH) else {
            return nil
        }
        let source = CIImage(cvPixelBuffer: buffer)
        let scaleX = CGFloat(targetW) / max(source.extent.width, 1)
        let scaleY = CGFloat(targetH) / max(source.extent.height, 1)
        ciContext.render(source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)), to: target)
        return target
        #else
        return nil
        #endif
    }

    /// Full-frame program video (typical screen share) without slide/props — cheap blit instead of full composite.
    static func eligibleForVideoOnlyStreamEncode(
        stack: RenderStack,
        propCanvases: [PropCanvas],
        programTransition: ProgramTransitionState?,
        suppressFastPath: Bool = false
    ) -> Bool {
        if suppressFastPath { return false }
        if programTransition?.isActive == true { return false }
        guard stack.isVisible(.videoInput, onStage: false) else { return false }
        if stack.drawsProgramMediaBackdrop(onStage: false) { return false }
        if stack.isVisible(.slide, onStage: false) {
            if !stack.slideCanvas.filter(\.visibleOnAudience).isEmpty || !stack.slideElements.isEmpty {
                return false
            }
        }
        if stack.isVisible(.props, onStage: false) {
            let hasAudienceProps = propCanvases.contains { canvas in
                stack.activeProps.contains(canvas.name)
                    && canvas.objects.contains(where: \.visibleOnAudience)
            }
            if hasAudienceProps { return false }
        }
        if stack.isVisible(.announcements, onStage: false),
           let announcement = stack.announcement, !announcement.isEmpty {
            return false
        }
        if stack.isVisible(.messages, onStage: false),
           let message = stack.message, !message.isEmpty {
            return false
        }
        if stack.isVisible(.mask, onStage: false), stack.maskEnabled {
            return false
        }
        return true
    }

    func renderVideoLayerProgramFrame(
        stack: RenderStack,
        width: Int,
        height: Int,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?
    ) -> (buffer: CVPixelBuffer, covered: [Int])? {
        guard stack.isVisible(.videoInput, onStage: false) else { return nil }
        let outW = max(16, width)
        let outH = max(16, height)
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: outW, height: outH) else {
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        let covered = drawVideoLayersOnly(
            stack: stack,
            target: target,
            video: video,
            pip: pip,
            videoFrame: videoFrame
        )
        return (target, covered)
    }

    /// Fresh pixels for RTMP while a full composite is still in flight (screen share stays live).
    func makeStreamHoldFrame(
        stack: RenderStack,
        width: Int,
        height: Int,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?,
        propCanvases: [PropCanvas],
        programTransition: ProgramTransitionState?,
        fallback: CVPixelBuffer?,
        suppressVideoOnlyBlit: Bool = false
    ) -> CVPixelBuffer? {
        if programTransition?.isActive == true {
            return fallback
        }
        if suppressVideoOnlyBlit {
            return fallback
        }
        guard Self.eligibleForVideoOnlyStreamEncode(
            stack: stack,
            propCanvases: propCanvases,
            programTransition: programTransition,
            suppressFastPath: suppressVideoOnlyBlit
        ), video != nil else {
            return fallback
        }
        let ownedVideo = video.map(Self.snapshot)
        let ownedPIP = pip.map(Self.snapshot)
        if let frame = renderVideoLayerProgramFrame(
            stack: stack,
            width: width,
            height: height,
            video: ownedVideo,
            pip: ownedPIP,
            videoFrame: videoFrame
        ) {
            return frame.buffer
        }
        return fallback
    }

    private func drawVideoLayersOnly(
        stack: RenderStack,
        target: CVPixelBuffer,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?
    ) -> [Int] {
        let width = CVPixelBufferGetWidth(target)
        let height = CVPixelBufferGetHeight(target)
        blitTarget = target
        defer { blitTarget = nil }
        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let data = CVPixelBufferGetBaseAddress(target) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(target)
        guard let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        var covered: [Int] = []
        let videoSpaceW = max(stack.slideCanvasWidth, Double(width), CanvasConfig.width, 1)
        let videoSpaceH = max(stack.slideCanvasHeight, Double(height), CanvasConfig.height, 1)

        // Pooled buffers keep old pixels; a transparent screen colour must not show the previous frame.
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        fill(ctx, color: stack.screenColorHex, rect: CGRect(x: 0, y: 0, width: width, height: height))
        if stack.isVisible(.screenColor, onStage: false) {
            covered.append(RenderLayer.screenColor.rawValue)
        }
        if stack.isVisible(.videoInput, onStage: false) {
            if let video {
                blit(video, into: ctx, rect: mapped(stack.primaryBounds, canvasW: videoSpaceW, canvasH: videoSpaceH, width: width, height: height))
                covered.append(RenderLayer.videoInput.rawValue)
            } else if let sample = videoFrame?.sample {
                fill(ctx, rgba: sample, rect: mapped(stack.primaryBounds, canvasW: videoSpaceW, canvasH: videoSpaceH, width: width, height: height))
                covered.append(RenderLayer.videoInput.rawValue)
            }
            if let pip {
                blit(pip, into: ctx, rect: mapped(stack.pipBounds, canvasW: videoSpaceW, canvasH: videoSpaceH, width: width, height: height))
            }
        }
        return covered
    }

    private func renderProgramTransition(
        transition: ProgramTransitionState,
        incoming: RenderStack,
        width: Int,
        height: Int,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        media: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?,
        textContext: DynamicTextContext?,
        liveVideoForObject: ((CanvasObject) -> CVPixelBuffer?)?,
        propCanvases: [PropCanvas],
        objectLivePixels: [UUID: CVPixelBuffer],
        buildPlayback: BuildPlayback,
        buildPhaseFilter: Set<BuildPhase>?,
        renderNow: Date,
        propBuildPlayback: [UUID: BuildPlayback],
        marketStreamItems: [MarketTickerItem],
        tickerColorConfig: TickerColorConfig,
        fallbackBuffer: CVPixelBuffer?,
        matchOnAirVisibility: Bool
    ) -> (buffer: CVPixelBuffer, covered: [Int])? {
        guard let outgoingFrame = render(
            stack: transition.outgoing,
            width: width,
            height: height,
            video: video,
            pip: pip,
            media: media,
            videoFrame: videoFrame,
            textContext: textContext,
            liveVideoForObject: liveVideoForObject,
            propCanvases: [],
            objectLivePixels: objectLivePixels,
            buildPlayback: buildPlayback,
            buildPhaseFilter: [.buildOut],
            renderNow: renderNow,
            programTransition: nil,
            propBuildPlayback: propBuildPlayback,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColorConfig,
            fallbackBuffer: fallbackBuffer,
            matchOnAirVisibility: matchOnAirVisibility
        ) else { return nil }
        guard let incomingFrame = render(
            stack: incoming,
            width: width,
            height: height,
            video: video,
            pip: pip,
            media: media,
            videoFrame: videoFrame,
            textContext: textContext,
            liveVideoForObject: liveVideoForObject,
            propCanvases: propCanvases,
            objectLivePixels: objectLivePixels,
            buildPlayback: buildPlayback,
            buildPhaseFilter: buildPhaseFilter,
            renderNow: renderNow,
            programTransition: nil,
            propBuildPlayback: propBuildPlayback,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColorConfig,
            fallbackBuffer: fallbackBuffer,
            matchOnAirVisibility: matchOnAirVisibility
        ) else { return outgoingFrame }
        guard let blended = ProgramTransitionCompositor.composite(
            from: outgoingFrame.buffer,
            to: incomingFrame.buffer,
            preset: transition.preset,
            progress: transition.progress,
            width: width,
            height: height,
            ciContext: ciContext
        ) else {
            return incomingFrame
        }
        return (blended, incomingFrame.covered)
    }

    func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let outW = max(16, width)
        let outH = max(16, height)
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: outW, height: outH) else {
            return nil
        }
        #if canImport(CoreImage)
        let source = CIImage(cgImage: image)
        let scaleX = CGFloat(outW) / max(source.extent.width, 1)
        let scaleY = CGFloat(outH) / max(source.extent.height, 1)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaled, to: target)
        return target
        #else
        return nil
        #endif
    }
    #endif

    #if canImport(CoreVideo)
    private func draw(
        stack: RenderStack,
        target: CVPixelBuffer,
        video: CVPixelBuffer?,
        pip: CVPixelBuffer?,
        media: CVPixelBuffer?,
        videoFrame: VideoIngestFrame?,
        textContext: DynamicTextContext?,
        liveVideoForObject: ((CanvasObject) -> CVPixelBuffer?)? = nil,
        propCanvases: [PropCanvas] = [],
        objectLivePixels: [UUID: CVPixelBuffer] = [:],
        buildPlayback: BuildPlayback = .rest,
        buildPhaseFilter: Set<BuildPhase>? = nil,
        renderNow: Date = Date(),
        propBuildPlayback: [UUID: BuildPlayback] = [:],
        marketStreamItems: [MarketTickerItem] = [],
        tickerColorConfig: TickerColorConfig = TickerColorConfig(),
        matchOnAirVisibility: Bool = false
    ) -> [Int] {
        let width = CVPixelBufferGetWidth(target)
        let height = CVPixelBufferGetHeight(target)
        blitTarget = target
        defer { blitTarget = nil }
        CVPixelBufferLockBaseAddress(target, [])
        defer { CVPixelBufferUnlockBaseAddress(target, []) }
        guard let data = CVPixelBufferGetBaseAddress(target) else { return [] }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(target)
        guard let ctx = CGContext(
            data: data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        var covered: [Int] = []
        // Video bounds use the same inflated space as `LayeredAudienceView.videoTile`.
        let videoSpaceW = max(stack.slideCanvasWidth, Double(width), CanvasConfig.width, 1)
        let videoSpaceH = max(stack.slideCanvasHeight, Double(height), CanvasConfig.height, 1)

        // Pooled buffers keep old pixels; a transparent screen colour must not show the previous frame.
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        fill(ctx, color: stack.screenColorHex, rect: CGRect(x: 0, y: 0, width: width, height: height))
        if stack.isVisible(.screenColor, onStage: false) {
            covered.append(RenderLayer.screenColor.rawValue)
        }

        if stack.isVisible(.videoInput, onStage: false) {
            if let video {
                blit(video, into: ctx, rect: mapped(stack.primaryBounds, canvasW: videoSpaceW, canvasH: videoSpaceH, width: width, height: height))
                covered.append(RenderLayer.videoInput.rawValue)
            } else if let sample = videoFrame?.sample {
                fill(ctx, rgba: sample, rect: mapped(stack.primaryBounds, canvasW: videoSpaceW, canvasH: videoSpaceH, width: width, height: height))
                covered.append(RenderLayer.videoInput.rawValue)
            }
            if let pip {
                blit(pip, into: ctx, rect: mapped(stack.pipBounds, canvasW: videoSpaceW, canvasH: videoSpaceH, width: width, height: height))
            }
        }

        if stack.drawsProgramMediaBackdrop(onStage: false) {
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            if let media {
                if stack.media?.id == RundownPageMedia.id, let image = Self.bgraImage(from: media) {
                    blitCanvasImage(image, into: ctx, rect: full, style: MediaFrameEngine.pageFitStyle)
                } else {
                    blit(media, into: ctx, rect: full)
                }
                covered.append(RenderLayer.media.rawValue)
            } else if let action = stack.media {
                if action.isImage, let image = programMediaStillImage(for: action) {
                    blit(image, into: ctx, rect: full)
                    covered.append(RenderLayer.media.rawValue)
                } else {
                    fill(ctx, color: action.tintHex, rect: full, alpha: 0.88)
                    covered.append(RenderLayer.media.rawValue)
                }
            }
        }

        if stack.isVisible(.slide, onStage: false), !stack.slideCanvas.isEmpty || !stack.slideElements.isEmpty {
            if stack.slideBackgroundEnabled {
                fill(ctx, color: stack.slideBackgroundHex, rect: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let slideW = max(stack.slideCanvasWidth, 1)
            let slideH = max(stack.slideCanvasHeight, 1)
            let canvasObjects = stack.slideCanvas.filter(\.visibleOnAudience).sorted { $0.zIndex < $1.zIndex }
            let slideSteps = canvasObjects.flatMap(\.resolvedBuildSteps)
            if !canvasObjects.isEmpty {
                let fitted = canvasContainFit(
                    canvasWidth: slideW,
                    canvasHeight: slideH,
                    frameWidth: width,
                    frameHeight: height
                )
                let usedPlate = drawCachedSlideLayers(
                    objects: canvasObjects,
                    canvasW: slideW,
                    canvasH: slideH,
                    fittedOrigin: fitted.origin,
                    fittedWidth: fitted.pixelWidth,
                    fittedHeight: fitted.pixelHeight,
                    frameWidth: width,
                    frameHeight: height,
                    ctx: ctx,
                    stack: stack,
                    video: video,
                    media: media,
                    textContext: textContext,
                    liveVideoForObject: liveVideoForObject,
                    objectLivePixels: objectLivePixels,
                    slideBuildSteps: slideSteps,
                    buildPlayback: buildPlayback,
                    buildPhaseFilter: buildPhaseFilter,
                    renderNow: renderNow,
                    marketStreamItems: marketStreamItems,
                    tickerColorConfig: tickerColorConfig,
                    matchOnAirVisibility: matchOnAirVisibility
                )
                if usedPlate == false {
                ctx.saveGState()
                ctx.translateBy(x: fitted.origin.x, y: fitted.origin.y)
                drawCanvasObjects(
                    canvasObjects,
                    canvasW: slideW,
                    canvasH: slideH,
                    width: fitted.pixelWidth,
                    height: fitted.pixelHeight,
                    ctx: ctx,
                    stack: stack,
                    video: video,
                    media: media,
                    textContext: textContext,
                    liveVideoForObject: liveVideoForObject,
                    objectLivePixels: objectLivePixels,
                    slideBuildSteps: slideSteps,
                    buildPlayback: buildPlayback,
                    buildPhaseFilter: buildPhaseFilter,
                    renderNow: renderNow,
                    marketStreamItems: marketStreamItems,
                    tickerColorConfig: tickerColorConfig,
                    matchOnAirVisibility: matchOnAirVisibility
                )
                ctx.restoreGState()
                }
            }
            let canvasHasText = canvasObjects.contains(where: \.isTextLike)
            if !canvasHasText, !stack.slideElements.isEmpty {
                drawSlideText(stack.slideElements, in: ctx, width: width, height: height)
            }
            covered.append(RenderLayer.slide.rawValue)
        }

        if stack.isVisible(.props, onStage: false), !stack.activeProps.isEmpty {
            for canvas in propCanvases where stack.activeProps.contains(canvas.name) && !canvas.objects.isEmpty {
                let propW = max(canvas.canvasWidth, 1)
                let propH = max(canvas.canvasHeight, 1)
                let objects = canvas.objects.filter(\.visibleOnAudience).sorted { $0.zIndex < $1.zIndex }
                let propSteps = objects.flatMap(\.resolvedBuildSteps)
                let propPlayback = propBuildPlayback[canvas.id]
                    ?? canvas.buildClock().playback(now: renderNow)
                let propPhases = canvas.buildPhases
                let fitted = canvasContainFit(
                    canvasWidth: propW,
                    canvasHeight: propH,
                    frameWidth: width,
                    frameHeight: height
                )
                ctx.saveGState()
                ctx.translateBy(x: fitted.origin.x, y: fitted.origin.y)
                drawCanvasObjects(
                    objects,
                    canvasW: propW,
                    canvasH: propH,
                    width: fitted.pixelWidth,
                    height: fitted.pixelHeight,
                    ctx: ctx,
                    stack: stack,
                    video: video,
                    media: media,
                    textContext: textContext,
                    liveVideoForObject: liveVideoForObject,
                    objectLivePixels: objectLivePixels,
                    slideBuildSteps: propSteps,
                    buildPlayback: propPlayback,
                    buildPhaseFilter: propPhases,
                    renderNow: renderNow,
                    marketStreamItems: marketStreamItems,
                    tickerColorConfig: tickerColorConfig,
                    matchOnAirVisibility: matchOnAirVisibility
                )
                ctx.restoreGState()
            }
            covered.append(RenderLayer.props.rawValue)
        }

        if stack.isVisible(.announcements, onStage: false), let announcement = stack.announcement, !announcement.isEmpty {
            fill(ctx, rgba: RGBA8(r: 0, g: 0, b: 0, a: 0.55), rect: CGRect(x: 0, y: Double(height) * 0.88, width: Double(width), height: Double(height) * 0.12))
            drawLine(announcement, in: ctx, rect: CGRect(x: 24, y: Double(height) * 0.90, width: Double(width) - 48, height: Double(height) * 0.08), size: 28)
            covered.append(RenderLayer.announcements.rawValue)
        }
        if stack.isVisible(.messages, onStage: false), let message = stack.message, !message.isEmpty {
            fill(ctx, rgba: RGBA8(r: 0.9, g: 0.28, b: 0.28, a: 0.88), rect: CGRect(x: 0, y: 0, width: Double(width), height: Double(height) * 0.07))
            drawLine(message, in: ctx, rect: CGRect(x: 20, y: 8, width: Double(width) - 40, height: Double(height) * 0.05), size: 22)
            covered.append(RenderLayer.messages.rawValue)
        }
        if let card = stack.chatOverlay, card.visible {
            drawChatOverlay(card, width: width, height: height, ctx: ctx)
        }
        if stack.isVisible(.mask, onStage: false), stack.maskEnabled {
            fill(ctx, rgba: RGBA8(r: 0, g: 0, b: 0, a: 0.2), rect: CGRect(x: 0, y: 0, width: width, height: height))
            covered.append(RenderLayer.mask.rawValue)
        }
        return covered
    }

    /// Rebuilds static slide layers when the slide changes, then draws only the camera on top of them.
    private func drawCachedSlideLayers(
        objects: [CanvasObject],
        canvasW: Double,
        canvasH: Double,
        fittedOrigin: CGPoint,
        fittedWidth: Int,
        fittedHeight: Int,
        frameWidth: Int,
        frameHeight: Int,
        ctx: CGContext,
        stack: RenderStack,
        video: CVPixelBuffer?,
        media: CVPixelBuffer?,
        textContext: DynamicTextContext?,
        liveVideoForObject: ((CanvasObject) -> CVPixelBuffer?)?,
        objectLivePixels: [UUID: CVPixelBuffer],
        slideBuildSteps: [ElementBuildStep],
        buildPlayback: BuildPlayback,
        buildPhaseFilter: Set<BuildPhase>?,
        renderNow: Date,
        marketStreamItems: [MarketTickerItem],
        tickerColorConfig: TickerColorConfig,
        matchOnAirVisibility: Bool
    ) -> Bool {
        #if canImport(CoreVideo) && canImport(Accelerate)
        guard matchOnAirVisibility else { return false }
        let liveFlags: [Bool] = objects.map { object in
            let pixel = objectLivePixels[object.id] ?? liveVideoForObject?(object)
            return shouldBlitLiveVideo(object) && pixel != nil
        }
        guard let first = liveFlags.firstIndex(of: true), let last = liveFlags.lastIndex(of: true) else { return false }
        if liveFlags[first...last].contains(false) { return false }
        let below = Array(objects[..<first])
        let lives = Array(objects[first...last])
        let above = Array(objects[(last + 1)...])
        if (below + above).contains(where: { $0.textLayout.isLooping || $0.text.contains("{quote") }) {
            return false
        }
        var hasher = Hasher()
        hasher.combine(frameWidth)
        hasher.combine(frameHeight)
        hasher.combine(fittedWidth)
        hasher.combine(fittedHeight)
        let ticking = textContext?.ticking(now: renderNow)
        for object in below + above {
            hasher.combine(object)
            if object.isTextLike, let ticking {
                hasher.combine(DynamicTextEngine.resolveProgramText(for: object, context: ticking))
            }
        }
        for object in lives {
            hasher.combine(object.id)
            hasher.combine(object.transform.x)
            hasher.combine(object.transform.y)
            hasher.combine(object.transform.width)
            hasher.combine(object.transform.height)
        }
        let signature = hasher.finalize()
        if slidePlateSignature != signature || slidePlateWidth != frameWidth || slidePlateHeight != frameHeight {
            slideMidPlate = below.isEmpty ? nil : renderObjectPlate(
                objects: below,
                canvasW: canvasW,
                canvasH: canvasH,
                fittedOrigin: fittedOrigin,
                fittedWidth: fittedWidth,
                fittedHeight: fittedHeight,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                stack: stack,
                video: video,
                media: media,
                textContext: textContext,
                liveVideoForObject: liveVideoForObject,
                objectLivePixels: objectLivePixels,
                slideBuildSteps: slideBuildSteps,
                buildPlayback: buildPlayback,
                buildPhaseFilter: buildPhaseFilter,
                renderNow: renderNow,
                marketStreamItems: marketStreamItems,
                tickerColorConfig: tickerColorConfig,
                matchOnAirVisibility: matchOnAirVisibility
            )
            slideOverPlate = above.isEmpty ? nil : renderObjectPlate(
                objects: above,
                canvasW: canvasW,
                canvasH: canvasH,
                fittedOrigin: fittedOrigin,
                fittedWidth: fittedWidth,
                fittedHeight: fittedHeight,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                stack: stack,
                video: video,
                media: media,
                textContext: textContext,
                liveVideoForObject: liveVideoForObject,
                objectLivePixels: objectLivePixels,
                slideBuildSteps: slideBuildSteps,
                buildPlayback: buildPlayback,
                buildPhaseFilter: buildPhaseFilter,
                renderNow: renderNow,
                marketStreamItems: marketStreamItems,
                tickerColorConfig: tickerColorConfig,
                matchOnAirVisibility: matchOnAirVisibility
            )
            if (below.isEmpty || slideMidPlate != nil), (above.isEmpty || slideOverPlate != nil) {
                slidePlateSignature = signature
                slidePlateWidth = frameWidth
                slidePlateHeight = frameHeight
            } else {
                slidePlateSignature = nil
                return false
            }
        }
        if let mid = slideMidPlate {
            blendPlate(mid)
        }
        ctx.saveGState()
        ctx.translateBy(x: fittedOrigin.x, y: fittedOrigin.y)
        drawCanvasObjects(
            lives,
            canvasW: canvasW,
            canvasH: canvasH,
            width: fittedWidth,
            height: fittedHeight,
            ctx: ctx,
            stack: stack,
            video: video,
            media: media,
            textContext: textContext,
            liveVideoForObject: liveVideoForObject,
            objectLivePixels: objectLivePixels,
            slideBuildSteps: slideBuildSteps,
            buildPlayback: buildPlayback,
            buildPhaseFilter: buildPhaseFilter,
            renderNow: renderNow,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColorConfig,
            matchOnAirVisibility: matchOnAirVisibility
        )
        ctx.restoreGState()
        if let over = slideOverPlate {
            blendPlate(over)
        }
        return true
        #else
        return false
        #endif
    }

    private func renderObjectPlate(
        objects: [CanvasObject],
        canvasW: Double,
        canvasH: Double,
        fittedOrigin: CGPoint,
        fittedWidth: Int,
        fittedHeight: Int,
        frameWidth: Int,
        frameHeight: Int,
        stack: RenderStack,
        video: CVPixelBuffer?,
        media: CVPixelBuffer?,
        textContext: DynamicTextContext?,
        liveVideoForObject: ((CanvasObject) -> CVPixelBuffer?)?,
        objectLivePixels: [UUID: CVPixelBuffer],
        slideBuildSteps: [ElementBuildStep],
        buildPlayback: BuildPlayback,
        buildPhaseFilter: Set<BuildPhase>?,
        renderNow: Date,
        marketStreamItems: [MarketTickerItem],
        tickerColorConfig: TickerColorConfig,
        matchOnAirVisibility: Bool
    ) -> CVPixelBuffer? {
        #if canImport(CoreVideo)
        guard let plate = makePlateBuffer(width: frameWidth, height: frameHeight) else { return nil }
        CVPixelBufferLockBaseAddress(plate, [])
        defer { CVPixelBufferUnlockBaseAddress(plate, []) }
        guard let data = CVPixelBufferGetBaseAddress(plate) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(plate)
        memset(data, 0, bytesPerRow * frameHeight)
        guard let plateCtx = CGContext(
            data: data,
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        plateCtx.interpolationQuality = .medium
        plateCtx.translateBy(x: 0, y: CGFloat(frameHeight))
        plateCtx.scaleBy(x: 1, y: -1)
        plateCtx.translateBy(x: fittedOrigin.x, y: fittedOrigin.y)
        let saved = blitTarget
        blitTarget = plate
        drawCanvasObjects(
            objects,
            canvasW: canvasW,
            canvasH: canvasH,
            width: fittedWidth,
            height: fittedHeight,
            ctx: plateCtx,
            stack: stack,
            video: video,
            media: media,
            textContext: textContext,
            liveVideoForObject: liveVideoForObject,
            objectLivePixels: objectLivePixels,
            slideBuildSteps: slideBuildSteps,
            buildPlayback: buildPlayback,
            buildPhaseFilter: buildPhaseFilter,
            renderNow: renderNow,
            marketStreamItems: marketStreamItems,
            tickerColorConfig: tickerColorConfig,
            matchOnAirVisibility: matchOnAirVisibility
        )
        blitTarget = saved
        return plate
        #else
        return nil
        #endif
    }

    private func makePlateBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        #if canImport(CoreVideo)
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
        #else
        return nil
        #endif
    }

    private func blendPlate(_ source: CVPixelBuffer) {
        #if canImport(CoreVideo) && canImport(Accelerate)
        guard let dest = blitTarget else { return }
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let srcBase = CVPixelBufferGetBaseAddress(source),
              let dstBase = CVPixelBufferGetBaseAddress(dest) else { return }
        var src = vImage_Buffer(
            data: srcBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)),
            rowBytes: CVPixelBufferGetBytesPerRow(source)
        )
        var dst = vImage_Buffer(
            data: dstBase,
            height: vImagePixelCount(CVPixelBufferGetHeight(dest)),
            width: vImagePixelCount(CVPixelBufferGetWidth(dest)),
            rowBytes: CVPixelBufferGetBytesPerRow(dest)
        )
        _ = vImagePremultipliedAlphaBlend_BGRA8888(&src, &dst, &dst, vImage_Flags(kvImageNoFlags))
        #endif
    }

    private func drawCanvasObjects(
        _ canvasObjects: [CanvasObject],
        canvasW: Double,
        canvasH: Double,
        width: Int,
        height: Int,
        ctx: CGContext,
        stack: RenderStack,
        video: CVPixelBuffer?,
        media: CVPixelBuffer?,
        textContext: DynamicTextContext?,
        liveVideoForObject: ((CanvasObject) -> CVPixelBuffer?)?,
        objectLivePixels: [UUID: CVPixelBuffer],
        slideBuildSteps: [ElementBuildStep],
        buildPlayback: BuildPlayback,
        buildPhaseFilter: Set<BuildPhase>?,
        renderNow: Date,
        marketStreamItems: [MarketTickerItem],
        tickerColorConfig: TickerColorConfig,
        matchOnAirVisibility: Bool = false
    ) {
        let layoutScale = CGFloat(width) / max(1, canvasW)
        for object in canvasObjects {
            let rect = mapped(
                CanvasRect(x: object.transform.x, y: object.transform.y, width: object.transform.width, height: object.transform.height),
                canvasW: canvasW,
                canvasH: canvasH,
                width: width,
                height: height
            )
            let hasBuildTimeline = !object.resolvedBuildSteps.isEmpty
            let settleOnAir = matchOnAirVisibility && (
                object.isTextLike
                    || object.hostsLayerBackedMedia
                    || object.kind.isBrowserLike
                    || object.assignedSource?.sourceType == .webPage
            )
            var buildState: TransformedRenderState
            if settleOnAir {
                // Stream/ISO: settled rest. A dissolve or click-build must not blank lyrics, cameras, or screen share.
                buildState = .rest
            } else {
                buildState = buildRenderState(
                    object: object,
                    canvasObjects: canvasObjects,
                    slideBuildSteps: slideBuildSteps,
                    buildPlayback: buildPlayback,
                    buildPhaseFilter: buildPhaseFilter,
                    renderNow: renderNow,
                    textContext: textContext,
                    tickerColorConfig: tickerColorConfig
                )
            }
            if hasBuildTimeline && !settleOnAir {
                let hideForBuild = !buildState.isVisible || buildState.opacity < 0.02
                if hideForBuild {
                    continue
                }
            }
            let radius = scaledCornerRadius(for: object, rect: rect)
            ctx.saveGState()
            applyBuildTransform(buildState, rect: rect, layoutScale: layoutScale, in: ctx)
            clip(ctx, rect: rect, object: object, radius: radius)
            var elementAlpha = CGFloat(max(0, min(1, object.opacity * (hasBuildTimeline ? buildState.opacity : 1))))
            if object.isTextLike && matchOnAirVisibility && elementAlpha < 0.05 {
                elementAlpha = CGFloat(max(0, min(1, object.opacity)))
            }
            ctx.setAlpha(elementAlpha)
            let liveVideo = objectLivePixels[object.id] ?? liveVideoForObject?(object)
            if shouldBlitLiveVideo(object), let liveVideo {
                blit(liveVideo, into: ctx, rect: rect)
            } else if (object.kind.isBrowserLike || object.assignedSource?.sourceType == .webPage),
                      let pageBuffer = objectLivePixels[object.id] {
                let mediaStyle = MediaFrameStyle.from(object, scale: layoutScale)
                blit(pageBuffer, into: ctx, rect: rect, style: mediaStyle)
            } else if shouldBlitProgramMedia(object, stack: stack, mediaBuffer: media), let media {
                blit(media, into: ctx, rect: rect)
            } else if shouldBlitProgramMedia(object, stack: stack, mediaBuffer: nil),
                      let action = stack.media,
                      let image = programMediaStillImage(for: action) {
                blit(image, into: ctx, rect: rect)
            } else if let still = canvasObjectStillImage(for: object, textContext: textContext) {
                let mediaStyle = MediaFrameStyle.from(object, scale: layoutScale)
                blitCanvasImage(still, into: ctx, rect: rect, style: mediaStyle)
            } else if object.isTextLike {
                drawTextBoxChrome(object: object, rect: rect, layoutScale: layoutScale, radius: radius, in: ctx)
            } else if object.fill.type != .none {
                fill(ctx, color: object.fillHex, rect: rect, alpha: 1)
            }
            if object.isTextLike {
                let resolved: String = {
                    guard let textContext else { return "" }
                    let liveContext = textContext.ticking(now: renderNow)
                    return DynamicTextEngine.resolveProgramText(for: object, context: liveContext)
                }()
                var textRect = rect
                if buildState.usesMarquee {
                    let offset = CGFloat(buildState.scrollOffsetPx) * layoutScale
                    if buildState.marqueeVertical {
                        textRect = textRect.offsetBy(dx: 0, dy: offset)
                    } else {
                        textRect = textRect.offsetBy(dx: offset, dy: 0)
                    }
                }
                #if os(macOS)
                let layoutScaleForText = min(
                    rect.width / max(1, CGFloat(object.transform.width)),
                    rect.height / max(1, CGFloat(object.transform.height))
                )
                let liveTextContext = textContext?.ticking(now: renderNow)
                let needsQuotes = !DynamicTextEngine.requiredLiveQuoteRequests(
                    for: object,
                    canvasObjects: canvasObjects
                ).isEmpty
                let deferLiveQuotes = !matchOnAirVisibility && (liveTextContext.map {
                    DynamicTextEngine.shouldDeferProgramLiveQuoteOutput(
                        object: object,
                        context: $0,
                        canvasObjects: canvasObjects
                    )
                } ?? false)
                if drawColoredMarketBannerIfNeeded(
                    object: object,
                    canvasObjects: canvasObjects,
                    rect: rect,
                    context: ctx,
                    textContext: liveTextContext,
                    streamItems: marketStreamItems,
                    colorConfig: tickerColorConfig,
                    renderNow: renderNow,
                    layoutScale: layoutScale
                ) {
                    // Colored `{quote:…}` strip — parity with LiveMarketMarqueeView / StaticColoredLiveQuoteView
                } else if deferLiveQuotes {
                    // Desk SwiftUI only — RTMP/ISO always fall through to placeholders or live values.
                } else if let liveTextContext,
                          LiveQuoteDisplayRouting.usesTokenDisplayTemplate(object),
                          let attributed = LiveQuoteTemplateRenderer.makeAttributedString(
                              object: object,
                              scale: layoutScaleForText,
                              context: liveTextContext,
                              colorConfig: tickerColorConfig
                          ),
                          attributed.length > 0 {
                    let inkStyle = SlideTextAttributes.from(object: object, text: " ", scale: layoutScaleForText)
                    if object.textLayout.isLooping {
                        drawScrollingMarketBanner(
                            banner: attributed,
                            object: object,
                            rect: rect,
                            scale: layoutScaleForText,
                            inkStyle: inkStyle,
                            renderNow: renderNow,
                            layoutScale: layoutScale,
                            context: ctx
                        )
                    } else {
                        CoreTextRasterizer.drawCanvasAttributed(
                            object: object,
                            attributed: attributed,
                            in: textRect,
                            context: ctx
                        )
                    }
                } else if !resolved.isEmpty {
                    let inkStyle = SlideTextAttributes.from(object: object, text: resolved, scale: layoutScaleForText)
                    if object.textLayout.isLooping {
                        let banner = TextAttributeConverter.makeAttributedString(
                            object: object,
                            text: resolved,
                            scale: layoutScaleForText
                        )
                        drawScrollingMarketBanner(
                            banner: banner,
                            object: object,
                            rect: rect,
                            scale: layoutScaleForText,
                            inkStyle: inkStyle,
                            renderNow: renderNow,
                            layoutScale: layoutScale,
                            context: ctx
                        )
                    } else {
                        CoreTextRasterizer.drawCanvasText(
                            object: object,
                            text: resolved,
                            in: textRect,
                            context: ctx
                        )
                    }
                } else if matchOnAirVisibility, needsQuotes, let liveTextContext,
                          let attributed = LiveQuoteTemplateRenderer.makeAttributedString(
                              object: object,
                              scale: layoutScaleForText,
                              context: liveTextContext,
                              colorConfig: tickerColorConfig
                          ),
                          attributed.length > 0 {
                    CoreTextRasterizer.drawCanvasAttributed(
                        object: object,
                        attributed: attributed,
                        in: textRect,
                        context: ctx
                    )
                }
                #else
                if !resolved.isEmpty {
                    drawLine(
                        resolved,
                        in: ctx,
                        rect: rect,
                        size: min(CGFloat(object.fontSize), rect.height * 0.8),
                        align: object.textLayout.horizontalAlign.rawValue,
                        color: object.fontColor
                    )
                }
                #endif
            }
            CanvasShimmerRasterizer.drawIfNeeded(object: object, in: rect, context: ctx)
            ctx.setAlpha(1)
            ctx.restoreGState()
        }
    }

    #if os(macOS)
    /// Loop scroll measurement for live-quote Display templates (`loopScrollText` is intentionally empty).
    private func programTextLoopState(
        object: CanvasObject,
        resolved: String,
        textContext: DynamicTextContext?,
        renderNow: Date,
        tickerColorConfig: TickerColorConfig
    ) -> TransformedRenderState {
        if LiveQuoteDisplayRouting.usesTokenDisplayTemplate(object),
           let textContext,
           let attributed = LiveQuoteTemplateRenderer.makeAttributedString(
               object: object,
               scale: 1,
               context: textContext,
               colorConfig: tickerColorConfig
           ),
           attributed.length > 0 {
            let direction = object.textLayout.resolvedLoopDirection
            let gap = object.textLayout.resolvedLoopGap
            let inkStyle = SlideTextAttributes.from(object: object, text: " ", scale: 1)
            let content = direction.isVertical
                ? Double(TextAttributeConverter.measureVerticalInkExtent(for: attributed, decorationPadding: inkStyle.decorationPadding))
                : Double(CryptoTickerFormatter.measureHorizontalCycleExtent(for: attributed, decorationPadding: inkStyle.decorationPadding))
            var state = TransformedRenderState.rest
            state.usesMarquee = true
            state.marqueeVertical = direction.isVertical
            state.marqueeGapPx = gap
            state.scrollOffsetPx = BuildAnimationEngine.marqueeOffset(
                elapsed: renderNow.timeIntervalSinceReferenceDate,
                contentWidth: max(1, content),
                gap: gap,
                speed: object.textLayout.resolvedLoopSpeed,
                left: direction == .left || direction == .up
            )
            return state
        }
        let scrollSource = DynamicTextEngine.loopScrollText(for: object, resolved: resolved)
        let measureText = scrollSource.isEmpty ? (resolved.isEmpty ? " " : resolved) : scrollSource
        return BuildAnimationEngine.textLoopState(
            object: object,
            text: measureText,
            now: renderNow,
            reduceMotion: false
        )
    }
    #else
    private func programTextLoopState(
        object: CanvasObject,
        resolved: String,
        textContext: DynamicTextContext?,
        renderNow: Date,
        tickerColorConfig: TickerColorConfig
    ) -> TransformedRenderState {
        let scrollSource = DynamicTextEngine.loopScrollText(for: object, resolved: resolved)
        let measureText = scrollSource.isEmpty ? (resolved.isEmpty ? " " : resolved) : scrollSource
        return BuildAnimationEngine.textLoopState(
            object: object,
            text: measureText,
            now: renderNow,
            reduceMotion: false
        )
    }
    #endif

    private func buildRenderState(
        object: CanvasObject,
        canvasObjects: [CanvasObject],
        slideBuildSteps: [ElementBuildStep],
        buildPlayback: BuildPlayback,
        buildPhaseFilter: Set<BuildPhase>?,
        renderNow: Date,
        textContext: DynamicTextContext?,
        tickerColorConfig: TickerColorConfig
    ) -> TransformedRenderState {
        let rawSteps = slideBuildSteps.isEmpty ? object.resolvedBuildSteps : slideBuildSteps
        let steps = BuildAnimationEngine.filterSteps(rawSteps, including: buildPhaseFilter)
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: max(1, object.transform.width),
            height: max(1, object.transform.height)
        )
        var state = BuildAnimationEngine.evaluateState(
            elementId: object.id,
            buildSteps: steps,
            playback: buildPlayback,
            elementBounds: bounds,
            textWidth: object.isTextLike ? BuildAnimationEngine.measuredTextWidth(for: object) : nil
        )
        if object.isTextLike, object.textLayout.isLooping {
            let resolved = textContext.map { DynamicTextEngine.resolve(object, context: $0) } ?? object.displayText
            let loop = programTextLoopState(
                object: object,
                resolved: resolved,
                textContext: textContext,
                renderNow: renderNow,
                tickerColorConfig: tickerColorConfig
            )
            if loop.usesMarquee {
                state.usesMarquee = true
                state.marqueeVertical = loop.marqueeVertical
                state.marqueeGapPx = loop.marqueeGapPx
                state.scrollOffsetPx = loop.scrollOffsetPx
            }
        }
        return state
    }

    private func applyBuildTransform(
        _ state: TransformedRenderState,
        rect: CGRect,
        layoutScale: CGFloat,
        in ctx: CGContext
    ) {
        guard !state.isIdentity else { return }
        let cx = rect.midX
        let cy = rect.midY
        ctx.translateBy(x: cx, y: cy)
        if abs(state.rotationDegrees) > 0.001 {
            ctx.rotate(by: CGFloat(state.rotationDegrees * .pi / 180))
        }
        let sx = max(0.05, state.scale.width)
        let sy = max(0.05, state.scale.height)
        if abs(sx - 1) > 0.001 || abs(sy - 1) > 0.001 {
            ctx.scaleBy(x: CGFloat(sx), y: CGFloat(sy))
        }
        ctx.translateBy(
            x: -cx + CGFloat(state.translation.x) * layoutScale,
            y: -cy + CGFloat(state.translation.y) * layoutScale
        )
    }

    #if os(macOS)
    private func drawChatOverlay(_ card: ChatOverlayCard, width: Int, height: Int, ctx: CGContext) {
        let padding: CGFloat = 24
        let boxWidth = min(CGFloat(width) * 0.42, 420)
        let author = card.message.author
        let platform = card.message.platform.displayTitle.uppercased()
        let body = card.message.text
        let header = "\(author)  \(platform)"
        let headerHeight = CGFloat(18)
        let bodyHeight = CGFloat(max(22, min(120, CGFloat(body.count) * 0.35 + 22)))
        let boxHeight = headerHeight + bodyHeight + 24
        let rect = CGRect(
            x: padding,
            y: CGFloat(height) - padding - boxHeight,
            width: boxWidth,
            height: boxHeight
        )
        fill(ctx, rgba: RGBA8(r: 0, g: 0, b: 0, a: 0.62), rect: rect)
        drawLine(header, in: ctx, rect: CGRect(x: rect.minX + 12, y: rect.minY + 10, width: boxWidth - 24, height: headerHeight), size: 13, align: "left", color: "#FFFFFF")
        drawLine(body, in: ctx, rect: CGRect(x: rect.minX + 12, y: rect.minY + 10 + headerHeight, width: boxWidth - 24, height: bodyHeight), size: 16, align: "left", color: "#FFFFFF")
    }
    #endif

    private func shouldBlitLiveVideo(_ object: CanvasObject) -> Bool {
        if object.isUnfilledPlaceholder { return false }
        switch object.assignedSource?.sourceType {
        case .systemCamera, .systemDisplay, .systemWindow, .ndiSource:
            return true
        default:
            return object.kind == .videoInput
        }
    }

    private func shouldBlitProgramMedia(_ object: CanvasObject, stack: RenderStack, mediaBuffer: CVPixelBuffer?) -> Bool {
        guard let programMedia = stack.media, !programMedia.clearsLayer else { return false }
        guard let slotAction = object.programMediaAction() else { return false }
        guard programMediaActionMatchesLayer(slotAction, programMedia: programMedia) else { return false }
        if programMedia.isImage {
            return programMediaStillImage(for: programMedia) != nil
        }
        return mediaBuffer != nil
    }

    private func programMediaActionMatchesLayer(_ slotAction: MediaAction, programMedia: MediaAction) -> Bool {
        if slotAction.id == programMedia.id { return true }
        let slotPath = slotAction.filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let layerPath = programMedia.filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !slotPath.isEmpty, !layerPath.isEmpty, slotPath == layerPath { return true }
        return false
    }

    private func canvasObjectStillImage(for object: CanvasObject, textContext: DynamicTextContext? = nil) -> CGImage? {
        if object.kind == .qrCode {
            let payload = QRCodeGenerator.payload(for: object, context: textContext)
            return QRCodeGenerator.cgImage(payload: payload, dimension: 768)
        }
        if object.isTextLike { return nil }
        if object.kind.isBrowserLike || object.assignedSource?.sourceType == .webPage { return nil }
        if let path = object.assignedSource?.connectionString,
           !path.isEmpty,
           !AssignedMediaSource.pathLooksLikeVideo(path),
           let image = cgImage(at: path) {
            return image
        }
        guard object.fill.type == .image else { return nil }
        let path = object.fill.imageURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !AssignedMediaSource.pathLooksLikeVideo(path) else { return nil }
        return cgImage(at: path)
    }

    private func cgImage(at path: String) -> CGImage? {
        #if os(macOS)
        let resolved = MediaPath.resolve(path)?.path ?? path
        // Decoded once and kept; this runs every program frame.
        return DecodedImageCache.shared.image(atPath: resolved, maxLongSide: nil)
        #else
        return nil
        #endif
    }

    private func programMediaStillImage(for action: MediaAction) -> CGImage? {
        guard action.isImage, let path = action.filePath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        #if os(macOS)
        let resolved = MediaPath.resolve(path)?.path ?? path
        guard let nsImage = NSImage(contentsOfFile: resolved) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }

    private func scaledCornerRadius(for object: CanvasObject, rect: CGRect) -> CGFloat {
        let source = max(object.transform.width, 1)
        let radius = object.resolvedCornerRadii.maxRadius
        return CGFloat(radius) * CGFloat(rect.width / source)
    }

    private func clip(_ ctx: CGContext, rect: CGRect, object: CanvasObject, radius: CGFloat) {
        addObjectShapePath(ctx, rect: rect, object: object, radius: radius)
        ctx.clip()
    }

    /// Box fill + stroke behind labels — parity with `CanvasObjectShapeLayer` under editor/audience text.
    private func drawTextBoxChrome(
        object: CanvasObject,
        rect: CGRect,
        layoutScale: CGFloat,
        radius: CGFloat,
        in ctx: CGContext
    ) {
        switch object.fill.type {
        case .none, .image:
            break
        case .color:
            fill(ctx, color: object.fill.color, rect: rect, alpha: CGFloat(object.fill.opacity))
        case .gradient:
            drawGradientFill(object: object, rect: rect, radius: radius, in: ctx)
        }
        drawObjectStroke(object: object, rect: rect, layoutScale: layoutScale, radius: radius, in: ctx)
    }

    private func addObjectShapePath(_ ctx: CGContext, rect: CGRect, object: CanvasObject, radius: CGFloat) {
        switch object.kind {
        case .ellipse, .cutout:
            ctx.addEllipse(in: rect)
        default:
            let curve = min(max(0, radius), min(rect.width, rect.height) / 2)
            if curve > 0.5 {
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: curve, cornerHeight: curve, transform: nil))
            } else {
                ctx.addRect(rect)
            }
        }
    }

    private func drawGradientFill(object: CanvasObject, rect: CGRect, radius: CGFloat, in ctx: CGContext) {
        let parsed: [(offset: CGFloat, rgba: RGBA8)] = object.fill.gradientStops.map { stop in
            (CGFloat(stop.offset), RGBA8.from(hex: stop.color))
        }
        guard parsed.count >= 2 else {
            fill(ctx, color: object.fill.color, rect: rect, alpha: CGFloat(object.fill.opacity))
            return
        }
        let colors: [CGColor] = parsed.map {
            CGColor(
                red: $0.rgba.r,
                green: $0.rgba.g,
                blue: $0.rgba.b,
                alpha: $0.rgba.a * object.fill.opacity
            )
        }
        let locations = parsed.map(\.offset)
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) else { return }

        let angle = object.fill.gradientAngle * .pi / 180
        let dx = cos(angle)
        let dy = sin(angle)
        let half = max(rect.width, rect.height)
        let start = CGPoint(x: rect.midX - dx * half, y: rect.midY - dy * half)
        let end = CGPoint(x: rect.midX + dx * half, y: rect.midY + dy * half)

        ctx.saveGState()
        addObjectShapePath(ctx, rect: rect, object: object, radius: radius)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
        ctx.restoreGState()
    }

    private func drawObjectStroke(
        object: CanvasObject,
        rect: CGRect,
        layoutScale: CGFloat,
        radius: CGFloat,
        in ctx: CGContext
    ) {
        guard object.stroke.style != .none else { return }
        let rgba = RGBA8.from(hex: object.stroke.color)
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a))
        ctx.setLineWidth(max(0.5, CGFloat(object.stroke.width) * layoutScale))
        switch object.stroke.cap ?? .butt {
        case .butt: ctx.setLineCap(.butt)
        case .round: ctx.setLineCap(.round)
        case .square: ctx.setLineCap(.square)
        }
        switch object.stroke.join ?? .miter {
        case .miter: ctx.setLineJoin(.miter)
        case .round: ctx.setLineJoin(.round)
        case .bevel: ctx.setLineJoin(.bevel)
        }
        if let dash = object.stroke.dashPattern, !dash.isEmpty {
            let scaled = dash.map { max(0, CGFloat($0) * layoutScale) }
            ctx.setLineDash(phase: 0, lengths: scaled)
        }
        addObjectShapePath(ctx, rect: rect, object: object, radius: radius)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func mapped(_ rect: CanvasRect, canvasW: Double, canvasH: Double, width: Int, height: Int) -> CGRect {
        CGRect(
            x: rect.x / canvasW * Double(width),
            y: rect.y / canvasH * Double(height),
            width: max(1, rect.width / canvasW * Double(width)),
            height: max(1, rect.height / canvasH * Double(height))
        )
    }

    /// Matches `ProgramSlideCanvas` contain-fit + centered placement in the program frame.
    private func canvasContainFit(
        canvasWidth: Double,
        canvasHeight: Double,
        frameWidth: Int,
        frameHeight: Int
    ) -> (origin: CGPoint, pixelWidth: Int, pixelHeight: Int) {
        let docW = max(canvasWidth, 1)
        let docH = max(canvasHeight, 1)
        let scale = min(CGFloat(frameWidth) / docW, CGFloat(frameHeight) / docH)
        let fittedW = max(1, floor(docW * scale))
        let fittedH = max(1, floor(docH * scale))
        let originX = (CGFloat(frameWidth) - fittedW) / 2
        let originY = (CGFloat(frameHeight) - fittedH) / 2
        return (CGPoint(x: originX, y: originY), Int(fittedW), Int(fittedH))
    }

    private func blit(_ buffer: CVPixelBuffer, into ctx: CGContext, rect: CGRect, style: MediaFrameStyle = .plain) {
        if gpuScaleFullFrame(buffer, into: ctx, rect: rect, style: style) {
            return
        }
        if let image = Self.bgraImage(from: buffer) ?? InputPreviewImaging.cgImage(from: buffer) {
            blitCanvasImage(image, into: ctx, rect: rect, style: style)
        }
    }

    /// Full-frame camera and screen pictures are scaled on the GPU. Core Graphics resampling of that frame was the composite thread.
    private func gpuScaleFullFrame(_ buffer: CVPixelBuffer, into ctx: CGContext, rect: CGRect, style: MediaFrameStyle) -> Bool {
        #if canImport(CoreImage) && canImport(CoreVideo)
        guard style.scaleMode == .fill || style == .plain else { return false }
        guard let target = blitTarget else { return false }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_32BGRA
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        else { return false }
        let device = ctx.convertToDeviceSpace(rect)
        let dstW = CGFloat(CVPixelBufferGetWidth(target))
        let dstH = CGFloat(CVPixelBufferGetHeight(target))
        guard dstW > 16, dstH > 16, device.width >= dstW * 0.9, device.height >= dstH * 0.9 else { return false }
        CVPixelBufferUnlockBaseAddress(target, [])
        let moved = transferFullFrame(buffer, to: target)
        CVPixelBufferLockBaseAddress(target, [])
        return moved
        #else
        return false
        #endif
    }

    /// One VideoToolbox pass scales and converts (420v or BGRA) into the program buffer.
    private func transferFullFrame(_ source: CVPixelBuffer, to target: CVPixelBuffer) -> Bool {
        #if canImport(VideoToolbox)
        if scaleTransfer == nil {
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr,
                  let session
            else { return false }
            scaleTransfer = session
        }
        guard let session = scaleTransfer else { return false }
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: target)
        if status != noErr {
            VTPixelTransferSessionInvalidate(session)
            scaleTransfer = nil
            return false
        }
        return true
        #else
        return false
        #endif
    }

    private var blitTarget: CVPixelBuffer?

    /// Camera and ScreenCaptureKit frames are 32BGRA. `CIContext.createCGImage` drops
    /// them when the buffer is not an IOSurface, which is what the program composite sees.
    private static func bgraImage(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let byteCount = bytesPerRow * height
        guard byteCount > 0 else { return nil }
        let owned = Data(bytes: base, count: byteCount)
        guard let provider = CGDataProvider(data: owned as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func blit(_ image: CGImage, into ctx: CGContext, rect: CGRect) {
        blitCanvasImage(image, into: ctx, rect: rect, style: .plain)
    }

    /// Parity with `CanvasObjectShapeLayer` image `.fit` / `.fill` / `.crop`.
    private func blitCanvasImage(_ image: CGImage, into ctx: CGContext, rect: CGRect, style: MediaFrameStyle) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        let local = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)

        let drawImage: CGImage
        if style.scaleMode == .crop {
            let norm = MediaFrameEngine.contentsRect(for: style)
            let sw = CGFloat(image.width)
            let sh = CGFloat(image.height)
            let src = CGRect(
                x: norm.origin.x * sw,
                y: norm.origin.y * sh,
                width: norm.width * sw,
                height: norm.height * sh
            ).integral
            drawImage = image.cropping(to: src) ?? image
        } else {
            drawImage = image
        }

        var dest: CGRect
        switch style.scaleMode {
        case .fit:
            dest = aspectFit(drawImage, in: local)
        case .fill, .crop, .tile:
            dest = aspectFill(drawImage, in: local)
        }
        if style.scaleMode == .crop {
            let off = MediaFrameEngine.imageOffset(style: style, width: rect.width, height: rect.height)
            dest = dest.offsetBy(dx: off.width, dy: off.height)
        }

        ctx.setAlpha(CGFloat(style.opacity))
        ctx.draw(drawImage, in: dest)
        ctx.restoreGState()
    }

    private func aspectFill(_ image: CGImage, in rect: CGRect) -> CGRect {
        let imageRatio = CGFloat(image.width) / max(1, CGFloat(image.height))
        let rectRatio = rect.width / max(1, rect.height)
        if imageRatio > rectRatio {
            let width = rect.height * imageRatio
            return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
        }
        let height = rect.width / imageRatio
        return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
    }

    private func aspectFit(_ image: CGImage, in rect: CGRect) -> CGRect {
        let imageRatio = CGFloat(image.width) / max(1, CGFloat(image.height))
        let rectRatio = rect.width / max(1, rect.height)
        if imageRatio > rectRatio {
            let height = rect.width / imageRatio
            return CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        }
        let width = rect.height * imageRatio
        return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
    }

    private func fill(_ ctx: CGContext, color: String, rect: CGRect, alpha: CGFloat = 1) {
        let rgba = RGBA8.from(hex: color)
        fill(ctx, rgba: RGBA8(r: rgba.r, g: rgba.g, b: rgba.b, a: rgba.a * Double(alpha)), rect: rect)
    }

    private func fill(_ ctx: CGContext, rgba: RGBA8, rect: CGRect) {
        let bounds = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        let safe = rect.intersection(bounds)
        guard safe.width > 0, safe.height > 0, safe.origin.x.isFinite, safe.origin.y.isFinite else { return }
        ctx.setFillColor(CGColor(
            red: rgba.r,
            green: rgba.g,
            blue: rgba.b,
            alpha: rgba.a
        ))
        ctx.fill(safe)
    }

    private func drawSlideText(_ elements: [SlideElement], in ctx: CGContext, width: Int, height: Int) {
        guard !elements.isEmpty else { return }
        let band = CGRect(
            x: Double(width) * 0.08,
            y: Double(height) * 0.34,
            width: Double(width) * 0.84,
            height: Double(height) * 0.32
        )
        let rowH = band.height / CGFloat(max(1, elements.count))
        for (index, element) in elements.enumerated() {
            let row = CGRect(x: band.minX, y: band.minY + CGFloat(index) * rowH, width: band.width, height: rowH)
            drawLine(element.text, in: ctx, rect: row, size: min(48, rowH * 0.55), align: element.alignment)
        }
    }

    #if os(macOS)
    private func drawColoredMarketBannerIfNeeded(
        object: CanvasObject,
        canvasObjects: [CanvasObject],
        rect: CGRect,
        context: CGContext,
        textContext: DynamicTextContext?,
        streamItems: [MarketTickerItem],
        colorConfig: TickerColorConfig,
        renderNow: Date,
        layoutScale: CGFloat
    ) -> Bool {
        guard MarketTickerRouting.usesColoredStrip(object)
            || MarketTickerRouting.usesStaticColoredLiveQuote(object)
        else { return false }
        let quotes = textContext?.quotes ?? [:]
        let scope = canvasObjects.isEmpty ? [object] : canvasObjects
        let items = MarketTickerRouting.resolvedTickerItems(
            object: object,
            canvasObjects: scope,
            streamItems: streamItems,
            liveQuotes: quotes
        )
        guard !items.isEmpty else { return false }
        let scale = min(
            rect.width / max(1, CGFloat(object.transform.width)),
            rect.height / max(1, CGFloat(object.transform.height))
        )
        let banner = CryptoTickerFormatter.makeTickerAttributedString(
            items: items,
            object: object,
            scale: scale,
            colorConfig: colorConfig
        )
        guard banner.length > 0 else { return false }
        let inkStyle = SlideTextAttributes.from(object: object, text: " ", scale: scale)
        if MarketTickerRouting.usesColoredStrip(object), object.textLayout.isLooping {
            drawScrollingMarketBanner(
                banner: banner,
                object: object,
                rect: rect,
                scale: scale,
                inkStyle: inkStyle,
                renderNow: renderNow,
                layoutScale: layoutScale,
                context: context
            )
        } else {
            CoreTextRasterizer.drawCanvasAttributed(
                object: object,
                attributed: banner,
                in: rect,
                context: context
            )
        }
        return true
    }

    private func drawScrollingMarketBanner(
        banner: NSAttributedString,
        object: CanvasObject,
        rect: CGRect,
        scale: CGFloat,
        inkStyle: SlideTextAttributes,
        renderNow: Date,
        layoutScale: CGFloat,
        context: CGContext
    ) {
        _ = layoutScale
        let loop = object.textLayout.resolvedLoopDirection.marqueeScroll
        let vertical = loop.isVertical
        let scrollForward = loop.scrollForward
        let anchorTrailing = loop.anchorToTrailing
        let anchorBottom = loop.anchorToBottom
        let speed = CGFloat(object.textLayout.resolvedLoopSpeed) * scale
        let gap = CGFloat(object.textLayout.resolvedLoopGap) * scale
        let cycleExtent: CGFloat = vertical
            ? TextAttributeConverter.measureVerticalInkExtent(for: banner, decorationPadding: inkStyle.decorationPadding)
            : CryptoTickerFormatter.measureHorizontalCycleExtent(for: banner, decorationPadding: inkStyle.decorationPadding)
        let contentExtent = max(1, cycleExtent)
        let unit = TickerEngine.unitDistance(contentExtent: contentExtent, gap: gap)
        let elapsed = renderNow.timeIntervalSinceReferenceDate
        let primary = TickerEngine.primaryOffset(
            elapsed: elapsed,
            speed: speed,
            unitDistance: unit,
            scrollForward: scrollForward
        )
        let pair = TickerEngine.pairedOffsets(primary: primary, unitDistance: unit)
        // Audience marquees use `object.textLayout.verticalAlign` (see `LiveMarketMarqueeRepresentable`).
        let verticalAlign = object.textLayout.verticalAlign
        let inkHeight = TextAttributeConverter.measureVerticalInkExtent(
            for: banner,
            decorationPadding: inkStyle.decorationPadding
        )
        let inkBandHeight = max(1, inkHeight)
        context.saveGState()
        context.clip(to: rect)
        for offset in [pair.0, pair.1] {
            if vertical {
                let copyHeight = max(contentExtent, inkBandHeight)
                let baseY = anchorBottom ? rect.maxY : rect.minY
                let y = anchorBottom ? baseY + offset - copyHeight : baseY + offset
                let drawRect = CGRect(x: rect.minX, y: y, width: rect.width, height: copyHeight)
                CoreTextRasterizer.drawAttributedString(
                    banner,
                    in: drawRect,
                    verticalAlign: verticalAlign,
                    context: context
                )
            } else {
                let copyWidth = contentExtent
                let inset = Self.tickerVerticalInset(
                    containerHeight: rect.height,
                    inkHeight: inkBandHeight,
                    align: verticalAlign
                )
                let baseX = anchorTrailing ? rect.maxX : rect.minX
                let x = anchorTrailing ? baseX + offset - copyWidth : baseX + offset
                let bandRect = CGRect(
                    x: x,
                    y: rect.minY + inset,
                    width: copyWidth,
                    height: inkBandHeight
                )
                CoreTextRasterizer.drawScrollingTickerCopy(
                    banner,
                    in: bandRect,
                    verticalAlign: verticalAlign,
                    context: context
                )
            }
        }
        context.restoreGState()
    }

    private static func tickerVerticalInset(
        containerHeight: CGFloat,
        inkHeight: CGFloat,
        align: TextVerticalAlign
    ) -> CGFloat {
        let extra = max(0, containerHeight - inkHeight)
        switch align {
        case .top: return 0
        case .middle: return extra / 2
        case .bottom, .baseline: return extra
        }
    }

    /// Layer visibility for encode metadata when using audience surface snapshots.
    static func coveredLayers(for stack: RenderStack, propCanvases: [PropCanvas]) -> [Int] {
        var covered: [Int] = []
        if stack.isVisible(.screenColor, onStage: false) {
            covered.append(RenderLayer.screenColor.rawValue)
        }
        if stack.isVisible(.videoInput, onStage: false) {
            covered.append(RenderLayer.videoInput.rawValue)
        }
        if stack.drawsProgramMediaBackdrop(onStage: false), stack.media != nil {
            covered.append(RenderLayer.media.rawValue)
        }
        if stack.isVisible(.slide, onStage: false),
           !stack.slideCanvas.isEmpty || !stack.slideElements.isEmpty
        {
            covered.append(RenderLayer.slide.rawValue)
        }
        if stack.isVisible(.props, onStage: false), !stack.activeProps.isEmpty {
            let hasObjects = propCanvases.contains { canvas in
                stack.activeProps.contains(canvas.name) && !canvas.objects.isEmpty
            }
            if hasObjects {
                covered.append(RenderLayer.props.rawValue)
            }
        }
        if stack.isVisible(.announcements, onStage: false),
           let announcement = stack.announcement, !announcement.isEmpty
        {
            covered.append(RenderLayer.announcements.rawValue)
        }
        if stack.isVisible(.messages, onStage: false),
           let message = stack.message, !message.isEmpty
        {
            covered.append(RenderLayer.messages.rawValue)
        }
        if stack.isVisible(.mask, onStage: false), stack.maskEnabled {
            covered.append(RenderLayer.mask.rawValue)
        }
        return covered
    }
    #endif

    private func drawLine(_ text: String, in ctx: CGContext, rect: CGRect, size: CGFloat, align: String = "center", color: String = "#FFFFFF") {
        #if canImport(CoreText)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let rgba = RGBA8.from(hex: color)
        let nsColor = NSColor(
            red: rgba.r,
            green: rgba.g,
            blue: rgba.b,
            alpha: max(rgba.a, 1)
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: nsColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let x: CGFloat
        switch align {
        case "left", "leading": x = rect.minX
        case "right", "trailing": x = rect.maxX - bounds.width
        default: x = rect.midX - bounds.width / 2
        }
        ctx.saveGState()
        ctx.translateBy(x: x, y: rect.midY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: 0, y: -bounds.height / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        #endif
    }
    #endif
}

#if os(macOS)
import SwiftUI
#endif

/// Off-screen `ProgramSurfaceView` raster for WYSIWYG live encode (not `CGWindowListCreateImage`).
enum ProgramSurfaceGrabber {
    /// Path C is retired for encode. Frames come from `ProgramOutputComposer` through `ProgramOutputBus`.
    static var useAudienceSurfaceForLiveStreamEncode = false

    #if os(macOS)
    @MainActor
    private static var capturesPausedUntil: Date = .distantPast

    @MainActor
    static var isCapturePaused: Bool {
        Date() < capturesPausedUntil
    }

    @MainActor
    static func pauseCapturesTemporarily(durationSeconds: TimeInterval = 0.5) {
        capturesPausedUntil = Date().addingTimeInterval(max(0.05, durationSeconds))
    }
    #endif

    @MainActor
    static func capture(width: Int, height: Int) -> CVPixelBuffer? {
        nil
    }

    #if os(macOS)
    @MainActor
    static func capture(controller: ShowController, width: Int, height: Int) -> CVPixelBuffer? {
        guard useAudienceSurfaceForLiveStreamEncode,
              controller.needsOffScreenProgramSurfaceCapture,
              !isCapturePaused
        else { return nil }
        return captureProgramEncodeSurface(controller: controller, width: width, height: height)
    }

    /// WYSIWYG encode for live-quote layers (matches Stream window / `ProgramSurfaceView`).
    @MainActor
    static func captureProgramEncodeSurface(
        controller: ShowController,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard !isCapturePaused else { return nil }
        let w = max(16, width)
        let h = max(16, height)
        let size = CGSize(width: CGFloat(w), height: CGFloat(h))
        let host = ensureHost(controller: controller, size: size)
        host.frame = CGRect(origin: .zero, size: size)
        hostWindow?.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return rasterize(host, width: w, height: h)
    }

    private static var hostWindow: NSWindow?
    private static var hostingView: NSHostingView<ProgramSurfaceView>?
    private static weak var boundController: ShowController?

    @MainActor
    private static func ensureHost(controller: ShowController, size: CGSize) -> NSHostingView<ProgramSurfaceView> {
        if let hostingView, boundController === controller {
            return hostingView
        }
        let host = NSHostingView(
            rootView: ProgramSurfaceView(controller: controller, outputEnabled: true)
        )
        host.frame = CGRect(origin: .zero, size: size)
        boundController = controller
        hostingView = host
        if hostWindow == nil {
            let window = NSWindow(
                contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = true
            window.backgroundColor = .black
            window.contentView = host
            window.orderBack(nil)
            hostWindow = window
        } else {
            hostWindow?.contentView = host
        }
        return host
    }

    @MainActor
    private static func rasterize(_ view: NSView, width: Int, height: Int) -> CVPixelBuffer? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cgImage = rep.cgImage else { return nil }
        // Core Image blit — same path as `pixelBuffer(from:)` (avoids upside-down CGContext Y flip).
        return ProgramOutputComposer.shared.pixelBuffer(from: cgImage, width: width, height: height)
    }
    #endif
}

#if os(macOS)
/// Reduces off-screen snapshot work during Space changes and when the app is occluded.
@MainActor
enum SpaceOcclusionMonitor {
    private static var started = false

    static func startIfNeeded() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            ProgramSurfaceGrabber.pauseCapturesTemporarily(durationSeconds: 0.6)
            LivePixelHub.shared.purgeUnusedBuffers()
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { _ in
            let visible = NSApplication.shared.windows.contains {
                $0.occlusionState.contains(.visible)
            }
            if !visible {
                ProgramSurfaceGrabber.pauseCapturesTemporarily(durationSeconds: 0.35)
                LivePixelHub.shared.purgeUnusedBuffers()
            }
        }
    }
}
#endif

/// CPU parity for live program transitions (Audience SwiftUI uses the same preset ids).
enum ProgramTransitionCompositor {
    #if canImport(CoreVideo) && canImport(CoreImage)
    static func composite(
        from: CVPixelBuffer,
        to: CVPixelBuffer,
        preset: TransitionPreset,
        progress: Double,
        width: Int,
        height: Int,
        ciContext: CIContext
    ) -> CVPixelBuffer? {
        let t = min(1, max(0, progress))
        if t <= 0 { return from }
        if t >= 1 { return to }
        if let kind = preset.coreImage {
            return coreImageComposite(kind: kind, from: from, to: to, progress: t, width: width, height: height, intensity: preset.intensity, ciContext: ciContext)
        }
        if preset.category == .lottie || preset.id == "lottie_wipe" {
            return wipeComposite(from: from, to: to, progress: t, width: width, height: height, ciContext: ciContext)
        }
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: width, height: height) else {
            return to
        }
        let fromImage = CIImage(cvPixelBuffer: from)
        let toImage = CIImage(cvPixelBuffer: to)
        let blended = blend(preset: preset, from: fromImage, to: toImage, progress: t, width: width, height: height)
        ciContext.render(blended, to: target)
        return target
    }

    private static func blend(
        preset: TransitionPreset,
        from: CIImage,
        to: CIImage,
        progress: Double,
        width: Int,
        height: Int
    ) -> CIImage {
        let t = CGFloat(progress)
        switch preset.id {
        case "push", "whip_pan":
            let shift = CGFloat(width) * t
            let outgoing = from.transformed(by: CGAffineTransform(translationX: -shift, y: 0))
            let incoming = to.transformed(by: CGAffineTransform(translationX: CGFloat(width) * (1 - t), y: 0))
            return incoming.composited(over: outgoing)
        case "wipe", "page_curl":
            return wipeCompositeCI(from: from, to: to, progress: progress, width: width, height: height)
        case "fade":
            let outA = max(0, 1 - progress * 2)
            let inA = max(0, progress * 2 - 1)
            let outgoing = from.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(outA)),
            ])
            let incoming = to.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(inA)),
            ])
            return incoming.composited(over: outgoing)
        case "cross_zoom":
            let outScale = 1 + 0.28 * t
            let inScale = 0.72 + 0.28 * t
            let outgoing = from.transformed(by: CGAffineTransform(scaleX: outScale, y: outScale))
            let incoming = to.transformed(by: CGAffineTransform(scaleX: inScale, y: inScale))
            return crossfade(outgoing, incoming, progress: progress)
        case "stinger_flame":
            return progress < 0.5 ? from : to
        case "glitch":
            let jitter = CGFloat(sin(progress * 42) * (1 - progress) * 10)
            let outgoing = from.transformed(by: CGAffineTransform(translationX: jitter, y: 0))
            return crossfade(outgoing, to, progress: progress)
        case "light_leak", "lens_flare":
            let leak = CGFloat(sin(progress * .pi) * 0.55)
            let wash = CIImage(color: CIColor(red: 1, green: 0.65, blue: 0.2, alpha: leak))
                .cropped(to: from.extent)
            return crossfade(from, to, progress: progress).composited(over: wash)
        default:
            return crossfade(from, to, progress: progress)
        }
    }

    private static func crossfade(_ from: CIImage, _ to: CIImage, progress: Double) -> CIImage {
        let t = CGFloat(min(1, max(0, progress)))
        let fadedOut = from.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - t),
        ])
        let fadedIn = to.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: t),
        ])
        return fadedIn.composited(over: fadedOut)
    }

    private static func wipeCompositeCI(from: CIImage, to: CIImage, progress: Double, width: Int, height: Int) -> CIImage {
        let edge = CGFloat(progress) * CGFloat(width)
        let mask = CIImage(color: .white)
            .cropped(to: CGRect(x: 0, y: 0, width: edge, height: CGFloat(height)))
        return to.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: from,
            kCIInputMaskImageKey: mask,
        ])
    }

    private static func wipeComposite(
        from: CVPixelBuffer,
        to: CVPixelBuffer,
        progress: Double,
        width: Int,
        height: Int,
        ciContext: CIContext
    ) -> CVPixelBuffer? {
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: width, height: height) else { return to }
        let blended = wipeCompositeCI(
            from: CIImage(cvPixelBuffer: from),
            to: CIImage(cvPixelBuffer: to),
            progress: progress,
            width: width,
            height: height
        )
        ciContext.render(blended, to: target)
        return target
    }

    private static func coreImageComposite(
        kind: CoreImageTransitionKind,
        from: CVPixelBuffer,
        to: CVPixelBuffer,
        progress: Double,
        width: Int,
        height: Int,
        intensity: Double,
        ciContext: CIContext
    ) -> CVPixelBuffer? {
        let sampleW = min(640, width)
        let sampleH = min(360, height)
        guard let fromThumb = downscale(from, width: sampleW, height: sampleH, ciContext: ciContext),
              let toThumb = downscale(to, width: sampleW, height: sampleH, ciContext: ciContext),
              let fromImage = transitionImage(fromThumb, width: sampleW, height: sampleH),
              let toImage = transitionImage(toThumb, width: sampleW, height: sampleH)
        else {
            return wipeComposite(from: from, to: to, progress: progress, width: width, height: height, ciContext: ciContext)
        }
        let uniforms = TransitionUniforms.make(progress: progress, width: sampleW, height: sampleH, intensity: intensity)
        let mixed = CoreImageTransitionEngine.composite(kind: kind, from: fromImage, to: toImage, uniforms: uniforms)
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: width, height: height) else { return to }
        guard let cg = cgImage(from: mixed) else { return to }
        let full = CIImage(cgImage: cg).transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / CGFloat(sampleW),
            y: CGFloat(height) / CGFloat(sampleH)
        ))
        ciContext.render(full, to: target)
        return target
    }

    private static func downscale(_ buffer: CVPixelBuffer, width: Int, height: Int, ciContext: CIContext) -> CVPixelBuffer? {
        guard let target = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: width, height: height) else { return nil }
        let source = CIImage(cvPixelBuffer: buffer)
        let scaleX = CGFloat(width) / max(source.extent.width, 1)
        let scaleY = CGFloat(height) / max(source.extent.height, 1)
        ciContext.render(source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)), to: target)
        return target
    }

    private static func transitionImage(_ buffer: CVPixelBuffer, width: Int, height: Int) -> TransitionImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let count = width * height
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var pixels = [RGBA8]()
        pixels.reserveCapacity(count)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                pixels.append(RGBA8(
                    r: Double(bytes[offset + 2]) / 255,
                    g: Double(bytes[offset + 1]) / 255,
                    b: Double(bytes[offset]) / 255,
                    a: Double(bytes[offset + 3]) / 255
                ))
            }
        }
        return TransitionImage(width: width, height: height, pixels: pixels)
    }

    private static func cgImage(from image: TransitionImage) -> CGImage? {
        let data = Data(image.pixels.flatMap { p -> [UInt8] in
            [UInt8(p.b * 255), UInt8(p.g * 255), UInt8(p.r * 255), UInt8(p.a * 255)]
        })
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
    #else
    static func composite(
        from: CVPixelBuffer,
        to: CVPixelBuffer,
        preset: TransitionPreset,
        progress: Double,
        width: Int,
        height: Int,
        ciContext: CIContext
    ) -> CVPixelBuffer? {
        _ = from
        _ = preset
        _ = progress
        _ = width
        _ = height
        _ = ciContext
        return to
    }
    #endif
}
