import Foundation
import CoreGraphics
import SwiftUI
#if os(macOS)
import AppKit
import CoreText
#endif

#if os(macOS)
/// Canvas text styling bundle for CoreText / `CATextLayer` (parity with `styledText` / `programText`).
struct SlideTextAttributes: Equatable {
    var text: String
    var font: NSFont
    var textColor: NSColor
    var strokeColor: NSColor?
    var strokeWidth: CGFloat
    var shadowColor: NSColor?
    var shadowRadius: CGFloat
    var shadowOffset: CGSize
    var kerning: CGFloat
    var underline: Bool
    var strikethrough: Bool
    var backgroundColor: NSColor?
    var lineHeightMultiple: Double = 1.2
    var wordSpacing: CGFloat = 0
    var paragraphSpacingBefore: CGFloat = 0
    var paragraphSpacingAfter: CGFloat = 0
    var firstLineIndent: CGFloat = 0
    var horizontalAlign: TextHorizontalAlign = .left

    static func from(object: CanvasObject, text: String, scale: CGFloat) -> SlideTextAttributes {
        let font = CanvasTypeface.nsFont(
            family: object.typography.fontFamily,
            size: max(1, object.typography.fontSize * scale),
            weight: object.typography.fontWeight,
            bold: object.typography.isBold,
            italic: object.typography.isItalic
        )
        let textColor = (Color(hex: object.typography.color).map { NSColor($0) }) ?? .white

        let outlineEnabled = object.textOutline.enabled
        let strokeWidth = outlineEnabled
            ? max(0.2, CGFloat(object.textOutline.width * scale))
            : 0
        let strokeColor: NSColor? = outlineEnabled
            ? (Color(hex: object.textOutline.color).map { NSColor($0) } ?? .black)
            : nil

        let shadowEnabled = object.textShadow.enabled
        let shadowRadius = shadowEnabled ? max(0, CGFloat(object.textShadow.blur * scale)) : 0
        let shadowOffset: CGSize = shadowEnabled
            ? CGSize(
                width: cos(object.textShadow.angle * .pi / 180) * object.textShadow.offset * scale,
                height: sin(object.textShadow.angle * .pi / 180) * object.textShadow.offset * scale
            )
            : .zero
        let shadowColor: NSColor? = shadowEnabled
            ? (Color(hex: object.textShadow.color).map { NSColor($0) } ?? NSColor.black.withAlphaComponent(0.8))
            : nil

        var backgroundColor: NSColor?
        if object.fill.type == .color, object.isTextLike {
            backgroundColor = Color(hex: object.fill.color).map { NSColor($0) }
        }

        return SlideTextAttributes(
            text: text,
            font: font,
            textColor: textColor,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth,
            shadowColor: shadowColor,
            shadowRadius: shadowRadius,
            shadowOffset: shadowOffset,
            kerning: object.textLayout.characterSpacing * scale,
            underline: object.typography.isUnderline,
            strikethrough: object.typography.isStrikethrough,
            backgroundColor: backgroundColor,
            lineHeightMultiple: object.textLayout.lineHeight,
            wordSpacing: CGFloat(object.textLayout.wordSpacing * scale),
            paragraphSpacingBefore: CGFloat(object.textLayout.paragraphSpacingBefore * scale),
            paragraphSpacingAfter: CGFloat(object.textLayout.paragraphSpacingAfter * scale),
            firstLineIndent: CGFloat((object.textLayout.firstLineIndent ?? 0) * scale),
            horizontalAlign: object.textLayout.horizontalAlign
        )
    }

    var decorationPadding: CGFloat {
        var pad: CGFloat = 0
        if strokeWidth > 0 { pad += strokeWidth * 2 }
        if shadowColor != nil {
            pad += shadowRadius + max(abs(shadowOffset.width), abs(shadowOffset.height))
        }
        return pad
    }
}

enum TextAttributeConverter {
    static func makeAttributedString(from style: SlideTextAttributes) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsTextAlignment(for: style.horizontalAlign)
        paragraph.lineHeightMultiple = max(0.5, style.lineHeightMultiple)
        paragraph.paragraphSpacingBefore = style.paragraphSpacingBefore
        paragraph.paragraphSpacing = style.paragraphSpacingAfter
        if style.firstLineIndent > 0 {
            paragraph.firstLineHeadIndent = style.firstLineIndent
            paragraph.headIndent = style.firstLineIndent
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: style.font,
            .foregroundColor: style.textColor,
            .kern: style.kerning,
            .paragraphStyle: paragraph,
        ]

        if let strokeColor = style.strokeColor, style.strokeWidth > 0 {
            attributes[.strokeColor] = strokeColor
            attributes[.strokeWidth] = -abs(style.strokeWidth)
        }

        if let shadowColor = style.shadowColor,
           style.shadowRadius > 0 || style.shadowOffset != .zero
        {
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor
            shadow.shadowBlurRadius = style.shadowRadius
            shadow.shadowOffset = style.shadowOffset
            attributes[.shadow] = shadow
        }

        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let backgroundColor = style.backgroundColor {
            attributes[.backgroundColor] = backgroundColor
        }

        let mutable = NSMutableAttributedString(string: style.text, attributes: attributes)
        applyWordSpacing(style.wordSpacing, to: mutable)
        return mutable
    }

    /// Widens gaps between words by adding kern on space characters.
    private static func applyWordSpacing(_ spacing: CGFloat, to string: NSMutableAttributedString) {
        guard abs(spacing) > 0.001 else { return }
        let body = string.string as NSString
        for index in 0..<body.length {
            let scalar = body.character(at: index)
            guard scalar == 0x20 || scalar == 0x00A0 else { continue }
            let range = NSRange(location: index, length: 1)
            let existing = string.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
            string.addAttribute(.kern, value: existing + spacing, range: range)
        }
    }

    static func makeAttributedString(object: CanvasObject, text: String, scale: CGFloat) -> NSAttributedString {
        let base = makeAttributedString(from: SlideTextAttributes.from(object: object, text: text, scale: scale))
        guard object.typography.isSuperscript || object.typography.isSubscript else { return base }
        let mutable = NSMutableAttributedString(attributedString: base)
        let offset = object.typography.isSuperscript
            ? object.typography.fontSize * scale * 0.35
            : -object.typography.fontSize * scale * 0.25
        if mutable.length > 0 {
            mutable.addAttribute(.baselineOffset, value: offset, range: NSRange(location: 0, length: mutable.length))
        }
        return mutable
    }

    private static func nsTextAlignment(for align: TextHorizontalAlign) -> NSTextAlignment {
        switch align {
        case .left, .justifyLeft: .left
        case .center: .center
        case .right: .right
        case .justify, .justifyAll: .justified
        }
    }

    /// Ink extent along the scroll axis (includes outline + shadow padding for seamless modulo spacing).
    static func measureCycleExtent(style: SlideTextAttributes, vertical: Bool) -> CGFloat {
        let attributed = makeAttributedString(from: style)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let typographic = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let ink = vertical ? (ascent + descent + leading) : typographic
        return max(1, ceil(ink + style.decorationPadding))
    }

    static func measureHorizontalCycleExtent(style: SlideTextAttributes) -> CGFloat {
        measureCycleExtent(style: style, vertical: false)
    }

    static func measureVerticalCycleExtent(style: SlideTextAttributes) -> CGFloat {
        measureCycleExtent(style: style, vertical: true)
    }

    /// Single styled run (e.g. ticker spans) using the same attributes as canvas text.
    static func attributedRun(
        text: String,
        baseStyle: SlideTextAttributes,
        font: NSFont? = nil,
        foregroundColor: NSColor? = nil
    ) -> NSAttributedString {
        var span = baseStyle
        span.text = text
        if let font { span.font = font }
        if let foregroundColor { span.textColor = foregroundColor }
        return makeAttributedString(from: span)
    }

    static func measureHorizontalCycleExtent(
        for attributed: NSAttributedString,
        decorationPadding: CGFloat = 0
    ) -> CGFloat {
        measureCycleExtent(for: attributed, vertical: false, decorationPadding: decorationPadding)
    }

    static func measureVerticalInkExtent(
        for attributed: NSAttributedString,
        decorationPadding: CGFloat = 0
    ) -> CGFloat {
        measureCycleExtent(for: attributed, vertical: true, decorationPadding: decorationPadding)
    }

    private static func measureCycleExtent(
        for attributed: NSAttributedString,
        vertical: Bool,
        decorationPadding: CGFloat
    ) -> CGFloat {
        guard attributed.length > 0 else { return max(1, ceil(decorationPadding)) }
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let typographic = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let ink = vertical ? (ascent + descent + leading) : typographic
        return max(1, ceil(ink + decorationPadding))
    }
}

/// Static canvas label with multi-color attributed runs (e.g. green/red `{change}`).
struct CanvasStaticAttributedTextView: NSViewRepresentable {
    var object: CanvasObject
    var attributed: NSAttributedString
    var scale: CGFloat

    func makeNSView(context: Context) -> CanvasStaticAttributedTextNSView {
        let view = CanvasStaticAttributedTextNSView()
        view.autoresizingMask = [.width, .height]
        view.object = object
        view.attributed = attributed
        view.scale = scale
        return view
    }

    func updateNSView(_ nsView: CanvasStaticAttributedTextNSView, context: Context) {
        nsView.object = object
        nsView.attributed = attributed
        nsView.scale = scale
        nsView.needsDisplay = true
    }
}

final class CanvasStaticAttributedTextNSView: NSView {
    var object: CanvasObject?
    var attributed: NSAttributedString = NSAttributedString()
    var scale: CGFloat = 1

    /// Match SwiftUI canvas layout + `CoreTextRasterizer` (top-left origin, same as encode flip).
    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let object,
              attributed.length > 0,
              bounds.width > 0,
              bounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext
        else { return }
        CoreTextRasterizer.drawCanvasAttributed(
            object: object,
            attributed: attributed,
            in: bounds,
            context: context
        )
    }
}

extension CanvasObject {
    /// Frame alignment for static / attributed canvas text (matches editor + program output).
    var canvasTextFrameAlignment: Alignment {
        CanvasTextBoxLayout.frameAlignment(for: self)
    }

    /// Marquee container alignment: scroll axis from loop direction, cross-axis from text layout.
    func loopMarqueeFrameAlignment(direction: TextLoopDirection) -> Alignment {
        switch direction {
        case .left, .right:
            return canvasTextFrameAlignment
        case .up:
            switch textLayout.horizontalAlign {
            case .right: return .topTrailing
            case .center: return .top
            default: return .topLeading
            }
        case .down:
            switch textLayout.horizontalAlign {
            case .right: return .bottomTrailing
            case .center: return .bottom
            default: return .bottomLeading
            }
        }
    }
}
#endif
