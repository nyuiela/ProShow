import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// CoreText drawing for program encode / RTMP (parity with SwiftUI + `TextAttributeConverter`).
enum CoreTextRasterizer {
    /// Matches `CanvasTextBoxLayout.frameAlignment` / `canvasTextFrameAlignment` on program + encode.
    static func verticalAlignmentForProgramText(for object: CanvasObject) -> TextVerticalAlign {
        CanvasTextBoxLayout.coreTextVerticalAlignment(for: object)
    }

    static func drawCanvasAttributed(
        object: CanvasObject,
        attributed: NSAttributedString,
        in elementBounds: CGRect,
        layoutScale: CGFloat,
        context: CGContext
    ) {
        guard attributed.length > 0, elementBounds.width > 0, elementBounds.height > 0 else { return }
        let style = SlideTextAttributes.from(object: object, text: " ", scale: layoutScale)
        let textRect = textLayoutRect(for: object, style: style, bounds: elementBounds, scale: layoutScale)
        if let fill = style.backgroundColor {
            context.saveGState()
            context.setFillColor(fill.cgColor)
            context.fill(textRect)
            context.restoreGState()
        }
        drawAttributedString(
            attributed,
            in: textRect,
            verticalAlign: verticalAlignmentForProgramText(for: object),
            context: context
        )
    }

    static func drawCanvasAttributed(
        object: CanvasObject,
        attributed: NSAttributedString,
        in bounds: CGRect,
        context: CGContext
    ) {
        let layoutScale = uniformScale(for: object, in: bounds)
        drawCanvasAttributed(
            object: object,
            attributed: attributed,
            in: bounds,
            layoutScale: layoutScale,
            context: context
        )
    }

    static func displayAttributedString(
        object: CanvasObject,
        text: String,
        layoutScale: CGFloat,
        textRect: CGRect
    ) -> NSAttributedString {
        var style = SlideTextAttributes.from(object: object, text: text, scale: layoutScale)
        style.text = text
        if object.textLayout.autoFitMode == .shrink {
            style.font = fittedFont(for: object, style: style, in: textRect, scale: layoutScale)
        }
        var attributed = TextAttributeConverter.makeAttributedString(from: style)
        if object.typography.isSuperscript || object.typography.isSubscript {
            let mutable = NSMutableAttributedString(attributedString: attributed)
            let offset = object.typography.isSuperscript
                ? object.typography.fontSize * layoutScale * 0.35
                : -object.typography.fontSize * layoutScale * 0.25
            if mutable.length > 0 {
                mutable.addAttribute(.baselineOffset, value: offset, range: NSRange(location: 0, length: mutable.length))
            }
            attributed = mutable
        }
        return attributed
    }

    static func textLayoutRectForDisplay(
        object: CanvasObject,
        elementBounds: CGRect,
        layoutScale: CGFloat
    ) -> CGRect {
        let style = SlideTextAttributes.from(object: object, text: " ", scale: layoutScale)
        return textLayoutRect(for: object, style: style, bounds: elementBounds, scale: layoutScale)
    }

    /// Top-left origin of the laid-out text block inside `textRect` (matches `drawAttributedString`).
    static func alignedTextBlockOrigin(
        attributed: NSAttributedString,
        in textRect: CGRect,
        verticalAlign: TextVerticalAlign
    ) -> CGPoint {
        guard attributed.length > 0, textRect.width > 0, textRect.height > 0 else {
            return textRect.origin
        }
        let layoutHeight = measuredLayoutHeight(for: attributed, width: textRect.width)
        let pathHeight = layoutHeight + 2
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: textRect.width, height: pathHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        return CGPoint(x: textRect.minX, y: alignedLayoutTop(frame: frame, pathHeight: pathHeight, attributed: attributed, in: textRect, align: verticalAlign))
    }

    static func drawCanvasText(
        object: CanvasObject,
        text: String,
        in elementBounds: CGRect,
        layoutScale: CGFloat,
        context: CGContext
    ) {
        guard !text.isEmpty, elementBounds.width > 0, elementBounds.height > 0 else { return }
        let textRect = textLayoutRectForDisplay(
            object: object,
            elementBounds: elementBounds,
            layoutScale: layoutScale
        )
        let attributed = displayAttributedString(
            object: object,
            text: text,
            layoutScale: layoutScale,
            textRect: textRect
        )
        let style = SlideTextAttributes.from(object: object, text: text, scale: layoutScale)
        if let fill = style.backgroundColor {
            context.saveGState()
            context.setFillColor(fill.cgColor)
            context.fill(textRect)
            context.restoreGState()
        }
        drawAttributedString(
            attributed,
            in: textRect,
            verticalAlign: verticalAlignmentForProgramText(for: object),
            context: context
        )
    }

    static func drawCanvasText(
        object: CanvasObject,
        text: String,
        in bounds: CGRect,
        context: CGContext
    ) {
        let layoutScale = uniformScale(for: object, in: bounds)
        drawCanvasText(object: object, text: text, in: bounds, layoutScale: layoutScale, context: context)
    }

    static func drawRichText(
        text: String,
        attributes style: SlideTextAttributes,
        in bounds: CGRect,
        verticalAlign: TextVerticalAlign = .middle,
        context: CGContext
    ) {
        guard !text.isEmpty, bounds.width > 0, bounds.height > 0 else { return }
        var copy = style
        copy.text = text
        let attributed = TextAttributeConverter.makeAttributedString(from: copy)
        drawAttributedString(attributed, in: bounds, verticalAlign: verticalAlign, context: context)
    }

    static func drawAttributedString(
        _ attributed: NSAttributedString,
        in bounds: CGRect,
        verticalAlign: TextVerticalAlign,
        context: CGContext
    ) {
        guard attributed.length > 0, bounds.width > 0, bounds.height > 0 else { return }

        let layoutHeight = measuredLayoutHeight(for: attributed, width: bounds.width)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        let pathHeight = layoutHeight + 2
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width, height: pathHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)
        let layoutTop = alignedLayoutTop(frame: frame, pathHeight: pathHeight, attributed: attributed, in: bounds, align: verticalAlign)

        context.saveGState()
        context.translateBy(x: bounds.minX, y: layoutTop + pathHeight)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// Visual text block = first baseline − font ascender … last baseline + font descender.
    /// Excludes the extra space `lineHeightMultiple` puts above each line (the cause of top/middle
    /// sitting low), and is font-size aware (pure font metrics, not string ink, so typing never jumps).
    /// Returns the y (top-left space) where the layout's top must go so the visual block is aligned.
    static func visualAlignedLayoutTop(
        firstBaselineFromTop: CGFloat,
        lastBaselineFromTop: CGFloat,
        ascent: CGFloat,
        descent: CGFloat,
        in rect: CGRect,
        align: TextVerticalAlign
    ) -> CGFloat {
        let visualTop = firstBaselineFromTop - ascent
        let visualHeight = (lastBaselineFromTop + descent) - visualTop
        let target: CGFloat
        switch align {
        case .top: target = rect.minY
        case .middle: target = rect.midY - visualHeight / 2
        case .bottom, .baseline: target = rect.maxY - visualHeight
        }
        return target - visualTop
    }

    static func fontMetrics(of attributed: NSAttributedString, at index: Int) -> (ascent: CGFloat, descent: CGFloat) {
        guard attributed.length > 0 else { return (0, 0) }
        let i = min(max(0, index), attributed.length - 1)
        let font = (attributed.attribute(.font, at: i, effectiveRange: nil) as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        return (font.ascender, -font.descender)
    }

    private static func alignedLayoutTop(
        frame: CTFrame,
        pathHeight: CGFloat,
        attributed: NSAttributedString,
        in rect: CGRect,
        align: TextVerticalAlign
    ) -> CGFloat {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return rect.minY }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let firstRange = CTLineGetStringRange(lines[0])
        let lastRange = CTLineGetStringRange(lines[lines.count - 1])
        let top = fontMetrics(of: attributed, at: firstRange.location)
        let bottom = fontMetrics(of: attributed, at: lastRange.location)
        return visualAlignedLayoutTop(
            firstBaselineFromTop: pathHeight - origins[0].y,
            lastBaselineFromTop: pathHeight - origins[lines.count - 1].y,
            ascent: top.ascent,
            descent: bottom.descent,
            in: rect,
            align: align
        )
    }

    /// RTMP/ISO compositor flips the root context once; anchor with `midY` like `ProgramOutputComposer.drawLine`.
    private static func usesProgramEncodeCoordinates(_ context: CGContext) -> Bool {
        context.ctm.d < 0
    }

    private static func measuredLayoutHeight(for attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var fitRange = CFRange()
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            &fitRange
        )
        return max(1, ceil(measured.height))
    }

    /// Flipped canvas views (editor / audience `NSView`, top-left origin).
    private static func drawSingleLineInCanvasSpace(
        _ attributed: NSAttributedString,
        in bounds: CGRect,
        verticalAlign: TextVerticalAlign,
        context: CGContext
    ) {
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .useOpticalBounds])

        let paragraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let alignment = paragraph?.alignment ?? .natural
        var x = bounds.minX
        switch alignment {
        case .center:
            x = bounds.midX - glyphBounds.width / 2 - glyphBounds.minX
        case .right:
            x = bounds.maxX - glyphBounds.width - glyphBounds.minX
        default:
            x = bounds.minX - glyphBounds.minX
        }

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let yAnchor = visualAlignedLayoutTop(
            firstBaselineFromTop: ascent, lastBaselineFromTop: ascent,
            ascent: ascent, descent: descent, in: bounds, align: verticalAlign
        ) + ascent // baseline y in top-left space
        let textY: CGFloat = 0
        context.saveGState()
        context.translateBy(x: x, y: yAnchor)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func drawSingleLineInProgramSpace(
        _ attributed: NSAttributedString,
        in bounds: CGRect,
        verticalAlign: TextVerticalAlign,
        context: CGContext
    ) {
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .useOpticalBounds])

        let paragraph = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let alignment = paragraph?.alignment ?? .natural
        var x = bounds.minX
        switch alignment {
        case .center:
            x = bounds.midX - glyphBounds.width / 2 - glyphBounds.minX
        case .right:
            x = bounds.maxX - glyphBounds.width - glyphBounds.minX
        default:
            x = bounds.minX - glyphBounds.minX
        }

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let yAnchor = visualAlignedLayoutTop(
            firstBaselineFromTop: ascent, lastBaselineFromTop: ascent,
            ascent: ascent, descent: descent, in: bounds, align: verticalAlign
        ) + ascent // baseline y in top-left space
        let textY: CGFloat = 0
        context.saveGState()
        context.translateBy(x: x, y: yAnchor)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: textY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Cross-axis placement matches `MarqueeTickerView` (`textVerticalInset` + top-aligned `CATextLayer`).
    static func drawScrollingTickerCopy(
        _ attributed: NSAttributedString,
        in bounds: CGRect,
        verticalAlign: TextVerticalAlign = .middle,
        context: CGContext
    ) {
        guard attributed.length > 0, bounds.width > 0, bounds.height > 0 else { return }
        if usesProgramEncodeCoordinates(context) {
            drawSingleLineInProgramSpace(attributed, in: bounds, verticalAlign: verticalAlign, context: context)
            return
        }
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds, .useOpticalBounds])
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

        let x = bounds.minX - glyphBounds.minX
        context.saveGState()
        context.translateBy(x: x, y: bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    // MARK: - Private

    private static func uniformScale(for object: CanvasObject, in bounds: CGRect) -> CGFloat {
        let sx = bounds.width / max(1, CGFloat(object.transform.width))
        let sy = bounds.height / max(1, CGFloat(object.transform.height))
        return min(sx, sy)
    }

    private static func textLayoutRect(
        for object: CanvasObject,
        style: SlideTextAttributes,
        bounds: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let pad = style.decorationPadding
        let m = object.textLayout.margins
        let insetX = CGFloat(m.left + m.right) * scale + pad * 2
        let insetY = CGFloat(m.top + m.bottom) * scale + pad * 2
        return CGRect(
            x: bounds.minX + CGFloat(m.left) * scale + pad,
            y: bounds.minY + CGFloat(m.top) * scale + pad,
            width: max(1, bounds.width - insetX),
            height: max(1, bounds.height - insetY)
        )
    }

    private static func verticallyAlignedFrame(
        contentHeight: CGFloat,
        within bounds: CGRect,
        align: TextVerticalAlign
    ) -> CGRect {
        var frame = bounds
        // Allow overflow so an oversize line is still laid out (CTFrame drops lines that don't fit).
        frame.size.height = contentHeight
        switch align {
        case .top:
            frame.origin.y = bounds.minY
        case .middle:
            frame.origin.y = bounds.minY + (bounds.height - frame.height) / 2
        case .bottom, .baseline:
            frame.origin.y = bounds.maxY - frame.height
        }
        return frame
    }

    /// Parity with SwiftUI `LoopingTextFit.minimumScaleFactor(0.2)` on program text (not marquees).
    static func calculateFittedFontSize(
        object: CanvasObject,
        style: SlideTextAttributes,
        in textRect: CGRect,
        scale: CGFloat,
        minimumScaleFactor: CGFloat = 0.2
    ) -> CGFloat {
        guard textRect.width > 1, textRect.height > 1 else { return style.font.pointSize }
        let initial = max(1, object.typography.fontSize * scale)
        let minSize = max(8, initial * minimumScaleFactor)
        var low = minSize
        var high = initial
        var best = minSize
        let probe = style.text.isEmpty ? "Ag" : style.text
        let maxHeight = object.textLayout.linesOnly == true
            ? singleLineHeight(for: object, at: initial, scale: scale)
            : textRect.height

        for _ in 0..<10 {
            let mid = (low + high) / 2
            let size = mid
            let font = CanvasTypeface.nsFont(
                family: object.typography.fontFamily,
                size: size,
                weight: object.typography.fontWeight,
                bold: object.typography.isBold,
                italic: object.typography.isItalic
            )
            var trial = style
            trial.font = font
            trial.text = probe
            let measured = measuredAttributedSize(
                TextAttributeConverter.makeAttributedString(from: trial),
                width: textRect.width
            )
            if measured.height <= maxHeight + 0.5, measured.width <= textRect.width + 0.5 {
                best = mid
                low = mid + 0.25
            } else {
                high = mid - 0.25
            }
        }
        return best
    }

    private static func singleLineHeight(for object: CanvasObject, at size: CGFloat, scale: CGFloat) -> CGFloat {
        var style = SlideTextAttributes.from(object: object, text: "Ag", scale: scale)
        style.font = CanvasTypeface.nsFont(
            family: object.typography.fontFamily,
            size: size,
            weight: object.typography.fontWeight,
            bold: object.typography.isBold,
            italic: object.typography.isItalic
        )
        let attributed = TextAttributeConverter.makeAttributedString(from: style)
        return measuredAttributedSize(attributed, width: CGFloat.greatestFiniteMagnitude).height
    }

    private static func measuredAttributedSize(_ attributed: NSAttributedString, width: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var fitRange = CFRange()
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            nil,
            CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            &fitRange
        )
    }

    private static func fittedFont(
        for object: CanvasObject,
        style: SlideTextAttributes,
        in textRect: CGRect,
        scale: CGFloat
    ) -> NSFont {
        let size = calculateFittedFontSize(object: object, style: style, in: textRect, scale: scale)
        return CanvasTypeface.nsFont(
            family: object.typography.fontFamily,
            size: size,
            weight: object.typography.fontWeight,
            bold: object.typography.isBold,
            italic: object.typography.isItalic
        )
    }
}
#endif
