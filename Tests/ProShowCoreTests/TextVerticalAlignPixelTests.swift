#if os(macOS)
import AppKit
import CoreText
import Testing
@testable import ProShowCore

/// Pixel test: rasterize through `CoreTextRasterizer.drawAttributedString` in a top-left
/// (flipped) context like the program composer / flipped canvas NSViews, at several font sizes.
@Suite
struct TextVerticalAlignPixelTests {
    static let W = 800, H = 400

    func attributed(size: CGFloat, text: String = "HHHH") -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.2
        return NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Helvetica", size: size)!, .foregroundColor: NSColor.white, .paragraphStyle: p,
        ])
    }

    /// Returns ink (top row, bottom row) in top-left pixel space.
    func ink(_ a: NSAttributedString, rect: CGRect, align: TextVerticalAlign) -> (CGFloat, CGFloat) {
        let c = CGContext(data: nil, width: Self.W, height: Self.H, bitsPerComponent: 8, bytesPerRow: Self.W * 4,
                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(Self.H)); c.scaleBy(x: 1, y: -1)
        CoreTextRasterizer.drawAttributedString(a, in: rect, verticalAlign: align, context: c)
        let px = c.data!.assumingMemoryBound(to: UInt8.self)
        var top = -1, bot = -1
        for r in 0..<Self.H {
            var any = false
            for x in 0..<Self.W where px[(r * Self.W + x) * 4 + 3] > 64 { any = true; break }
            if any { if top < 0 { top = r }; bot = r }
        }
        return (CGFloat(top), CGFloat(bot + 1))
    }

    @Test(arguments: [24.0, 48.0, 72.0])
    func alignsVisualBlock(size: Double) {
        let s = CGFloat(size)
        let font = NSFont(name: "Helvetica", size: s)!
        let a = attributed(size: s)
        let rect = CGRect(x: 10, y: 50, width: 700, height: 300)
        // "H" ink = cap height above baseline; visual block = ascender..descender.
        let capGapTop = font.ascender - font.capHeight
        let (t, _) = ink(a, rect: rect, align: .top)
        #expect(abs(t - (rect.minY + capGapTop)) <= 1.5, "top \(s): \(t)")
        let (_, b) = ink(a, rect: rect, align: .bottom)
        #expect(abs(b - (rect.maxY + font.descender)) <= 1.5, "bottom \(s): \(b)")
        let (mt, mb) = ink(a, rect: rect, align: .middle)
        let visualCenterOfInk = (mt + mb) / 2
        // Visual block centered => baseline at midY + (asc - desc)/2.
        let expectedBaseline = rect.midY + (font.ascender + font.descender) / 2
        #expect(abs(mb - expectedBaseline) <= 1.5, "middle \(s): ink \(mt)-\(mb) c=\(visualCenterOfInk)")
    }

    /// NSTextView (edit overlay) and CTFrame must put the first baseline at the same offset.
    @Test(arguments: [24.0, 48.0, 72.0])
    func editBaselineMatchesCoreText(size: Double) {
        let a = attributed(size: CGFloat(size), text: "Hello\nWorld")
        let storage = NSTextStorage(attributedString: a)
        let lm = NSLayoutManager(); storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0; lm.addTextContainer(tc); lm.ensureLayout(for: tc)
        func tkBaseline(_ g: Int) -> CGFloat { lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY + lm.location(forGlyphAt: g).y }
        let fs = CTFramesetterCreateWithAttributedString(a)
        let h: CGFloat = 1000
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: 700, height: h), transform: nil), nil)
        var o = [CGPoint](repeating: .zero, count: 2)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 2), &o)
        // Each path aligns its own visual block, so compare the *aligned* first baseline.
        let font = NSFont(name: "Helvetica", size: CGFloat(size))!
        let rect = CGRect(x: 0, y: 0, width: 700, height: 400)
        for align in [TextVerticalAlign.top, .middle, .bottom] {
            let tk = CoreTextRasterizer.visualAlignedLayoutTop(firstBaselineFromTop: tkBaseline(0), lastBaselineFromTop: tkBaseline(lm.numberOfGlyphs - 1), ascent: font.ascender, descent: -font.descender, in: rect, align: align) + tkBaseline(0)
            let ct = CoreTextRasterizer.visualAlignedLayoutTop(firstBaselineFromTop: h - o[0].y, lastBaselineFromTop: h - o[1].y, ascent: font.ascender, descent: -font.descender, in: rect, align: align) + (h - o[0].y)
            #expect(abs(tk - ct) <= 1.5, "edit vs display \(size) \(align): \(tk) vs \(ct)")
        }
    }
}
#endif
