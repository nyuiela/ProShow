import Foundation
import Testing
#if canImport(AppKit)
import AppKit
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

#if canImport(AppKit)
private enum ProgramOutputTestProbe {
    static func maxLuminance(in buffer: CVPixelBuffer, x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let xMin = max(0, min(x0, x1))
        let xMax = min(width - 1, max(x0, x1))
        let yMin = max(0, min(y0, y1))
        let yMax = min(height - 1, max(y0, y1))
        var peak = 0.0
        for y in yMin...yMax {
            let row = pixels.advanced(by: y * stride)
            for x in xMin...xMax {
                let o = x * 4
                let b = Double(row[o]) / 255
                let g = Double(row[o + 1]) / 255
                let r = Double(row[o + 2]) / 255
                peak = max(peak, 0.2126 * r + 0.7152 * g + 0.0722 * b)
            }
        }
        return peak
    }
}

@Suite
struct ProgramOutputTypographyTests {
    @Test
    func attributedString_includesStrokeAndShadowWhenEnabled() {
        var object = CanvasObject(
            name: "Title",
            kind: .text,
            bounds: .centered(width: 400, height: 120),
            text: "Live"
        )
        object.textOutline.enabled = true
        object.textOutline.width = 4
        object.textOutline.color = "#FF0000"
        object.textShadow.enabled = true
        object.textShadow.blur = 8
        object.textShadow.offset = 6
        object.textLayout.characterSpacing = 2

        let style = SlideTextAttributes.from(object: object, text: "Live", scale: 1)
        let attributed = TextAttributeConverter.makeAttributedString(from: style)

        let strokeWidth = attributed.attribute(.strokeWidth, at: 0, effectiveRange: nil) as? CGFloat
        #expect(strokeWidth != nil)
        #expect(abs(strokeWidth ?? 0) > 0)

        let shadow = attributed.attribute(.shadow, at: 0, effectiveRange: nil) as? NSShadow
        #expect(shadow != nil)

        let kern = attributed.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat
        #expect(abs((kern ?? 0) - 2) < 0.01)
    }

    @Test
    func programOutputComposer_rendersStyledCanvasText() {
        var object = CanvasObject(
            name: "Headline",
            kind: .text,
            bounds: CanvasRect(x: 100, y: 100, width: 600, height: 200),
            text: "Stream"
        )
        object.typography.fontSize = 72
        object.typography.color = "#FFFFFF"
        object.textOutline.enabled = true
        object.textOutline.width = 3
        object.visibleOnAudience = true

        var stack = RenderStack.idle
        stack.slideCanvas = [object]
        stack.slideCanvasWidth = CanvasConfig.width
        stack.slideCanvasHeight = CanvasConfig.height

        let result = ProgramOutputComposer.shared.render(
            stack: stack,
            width: 640,
            height: 360,
            video: nil,
            pip: nil,
            media: nil,
            videoFrame: nil,
            textContext: .empty,
            matchOnAirVisibility: true
        )
        #expect(result != nil)
        #expect(result?.covered.contains(RenderLayer.slide.rawValue) == true)
        #if canImport(CoreVideo)
        if let buffer = result?.buffer {
            let ink = ProgramOutputTestProbe.maxLuminance(in: buffer, x0: 120, y0: 80, x1: 520, y1: 280)
            #expect(ink > 0.35)
        }
        #endif
    }

    @Test
    func programOutputComposer_rendersLegacySlideElements() {
        var stack = RenderStack.idle
        stack.slideElements = [SlideElement(text: "Grace", alignment: "center")]
        stack.slideBackgroundEnabled = true
        stack.slideBackgroundHex = "#101010"

        let result = ProgramOutputComposer.shared.render(
            stack: stack,
            width: 640,
            height: 360,
            video: nil,
            pip: nil,
            media: nil,
            videoFrame: nil,
            textContext: .empty,
            matchOnAirVisibility: true
        )
        #expect(result != nil)
        #if canImport(CoreVideo)
        if let buffer = result?.buffer {
            let ink = ProgramOutputTestProbe.maxLuminance(in: buffer, x0: 80, y0: 100, x1: 560, y1: 260)
            #expect(ink > 0.25)
        }
        #endif
    }

    @Test
    func broadcastEncode_revealsTextBlockedByPendingOnClickBuild() {
        var object = CanvasObject(
            name: "Lyrics",
            kind: .text,
            bounds: CanvasRect(x: 80, y: 80, width: 800, height: 160),
            text: ""
        )
        object.typography.fontSize = 48
        object.typography.color = "#FFFFFF"
        object.visibleOnAudience = true
        object.buildSteps = [
            ElementBuildStep(
                elementId: object.id,
                phase: .buildIn,
                effect: .fade,
                trigger: .onClick,
                sequenceOrder: 1,
                durationSeconds: 0.5
            ),
        ]

        var stack = RenderStack.idle
        stack.slideCanvas = [object]
        stack.slideCanvasWidth = CanvasConfig.width
        stack.slideCanvasHeight = CanvasConfig.height

        let livePlayback = BuildPlayback.live(elapsed: 12, unlockedClickOrder: 0, clickTimes: [:])
        let hidden = ProgramOutputComposer.shared.render(
            stack: stack,
            width: 640,
            height: 360,
            video: nil,
            pip: nil,
            media: nil,
            videoFrame: nil,
            textContext: .empty,
            buildPlayback: livePlayback,
            matchOnAirVisibility: false
        )
        #expect(hidden != nil)

        let encodePlayback = BuildAnimationEngine.broadcastPlayback(from: livePlayback, canvasObjects: [object])
        #expect(encodePlayback.autoplayClicks)

        let onAir = ProgramOutputComposer.shared.render(
            stack: stack,
            width: 640,
            height: 360,
            video: nil,
            pip: nil,
            media: nil,
            videoFrame: nil,
            textContext: .empty,
            buildPlayback: encodePlayback,
            matchOnAirVisibility: true
        )
        #expect(onAir != nil)
        #expect(onAir?.covered.contains(RenderLayer.slide.rawValue) == true)
        #if canImport(CoreVideo)
        if let buffer = onAir?.buffer {
            let ink = ProgramOutputTestProbe.maxLuminance(in: buffer, x0: 60, y0: 60, x1: 580, y1: 300)
            #expect(ink > 0.2)
        }
        #endif
    }

    @Test
    func programOutputComposer_rendersLoopingLiveQuoteDisplayTemplate() {
        var object = CanvasObject(
            name: "Quote",
            kind: .liveQuote,
            bounds: CanvasRect(x: 40, y: 120, width: 880, height: 100),
            text: "{symbol} {price} {change}",
            token: "crypto|BTC"
        )
        object.typography.fontSize = 36
        object.typography.color = "#FFFFFF"
        object.textLayout.scrolling = true
        object.visibleOnAudience = true

        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        let quotes: [String: LiveQuote] = [
            "BTC": LiveQuote(
                symbol: "BTC",
                name: "Bitcoin",
                price: 64_000,
                changePercent: 2.1,
                currency: "USD",
                kind: .crypto,
                updatedAt: noon
            ),
        ]
        var context = DynamicTextContext.empty
        context.now = noon
        context.quotes = quotes

        var stack = RenderStack.idle
        stack.slideCanvas = [object]
        stack.slideCanvasWidth = CanvasConfig.width
        stack.slideCanvasHeight = CanvasConfig.height

        let result = ProgramOutputComposer.shared.render(
            stack: stack,
            width: 640,
            height: 360,
            video: nil,
            pip: nil,
            media: nil,
            videoFrame: nil,
            textContext: context,
            matchOnAirVisibility: true
        )
        #expect(result != nil)
        #if canImport(CoreVideo)
        if let buffer = result?.buffer {
            let ink = ProgramOutputTestProbe.maxLuminance(in: buffer, x0: 80, y0: 100, x1: 560, y1: 260)
            #expect(ink > 0.2)
        }
        #endif
    }
}
#endif
