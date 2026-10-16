import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum EditorKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case presentation, stage, theme, ccli, props, masks, overlays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .presentation: "Presentation Editor"
        case .stage: "Stage Layout Editor"
        case .theme: "Theme Editor"
        case .ccli: "CCLI Layout Editor"
        case .props: "Props Editor"
        case .masks: "Masks Editor"
        case .overlays: "Overlay Editor"
        }
    }
}

enum EditorInspectorTab: String, CaseIterable, Identifiable, Codable, Sendable {
    case shape, text, build, slide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shape: "Shape"
        case .text: "Text"
        case .build: "Build"
        case .slide: "Slide"
        }
    }
}

enum ElementFillType: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, color, gradient, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .color: "Color Fill"
        case .gradient: "Gradient"
        case .image: "Image"
        }
    }
}

enum GradientKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case linear, radial, angular
    var id: String { rawValue }
}

enum ImageScaleMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fit, fill, crop, tile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .crop: "Crop"
        case .tile: "Tile"
        }
    }

    var cropsToFrame: Bool {
        self == .fill || self == .crop
    }
}

enum StrokeStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, solid, dashed, dotted
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum StrokePosition: String, CaseIterable, Identifiable, Codable, Sendable {
    case inside, center, outside
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum FontWeightToken: String, CaseIterable, Identifiable, Codable, Sendable {
    case thin, regular, medium, semibold, bold, black
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

#if canImport(AppKit)
enum CanvasTypeface {
    private static let fontCache: NSCache<NSString, NSFont> = { let c = NSCache<NSString, NSFont>(); c.countLimit = 2000; return c }()

    /// Cached: building an NSFont through NSFontManager every frame made CoreText re-run shaping-glyph
    /// setup for each new font instance (a background thread pegged at ~75% CPU while idle).
    static func nsFont(family: String, size: CGFloat, weight: FontWeightToken, bold: Bool, italic: Bool) -> NSFont {
        let key = "\(family)|\(size)|\(weight.rawValue)|\(bold)|\(italic)" as NSString
        if let hit = fontCache.object(forKey: key) { return hit }
        let font = makeNSFont(family: family, size: size, weight: weight, bold: bold, italic: italic)
        fontCache.setObject(font, forKey: key)
        return font
    }

    private static func makeNSFont(family: String, size: CGFloat, weight: FontWeightToken, bold: Bool, italic: Bool) -> NSFont {
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            let fallback = NSFont.systemFont(ofSize: size, weight: nsSystemWeight(weight, bold: bold))
            return italic ? NSFontManager.shared.convert(fallback, toHaveTrait: .italicFontMask) : fallback
        }
        let familyName = name
        var traits: NSFontTraitMask = []
        if italic { traits.insert(.italicFontMask) }
        if bold || weight == .bold || weight == .black { traits.insert(.boldFontMask) }
        let numericWeight = nsNumericWeight(weight, bold: bold)
        if let font = NSFontManager.shared.font(withFamily: familyName, traits: traits, weight: numericWeight, size: size) {
            return font
        }
        if let members = NSFontManager.shared.availableMembers(ofFontFamily: familyName),
           let postscript = members.first?.first as? String,
           let named = NSFont(name: postscript, size: size) {
            var font = named
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if bold || weight == .bold || weight == .black {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            return font
        }
        let fallback = NSFont.systemFont(ofSize: size, weight: nsSystemWeight(weight, bold: bold))
        return italic ? NSFontManager.shared.convert(fallback, toHaveTrait: .italicFontMask) : fallback
    }

    static func fittedSize(
        text: String,
        font: NSFont,
        box: CGSize,
        autoFit: TextAutoFitMode,
        minScale: CGFloat = 0.2
    ) -> CGFloat {
        guard autoFit == .shrink, box.width > 1, box.height > 1 else { return font.pointSize }
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let widthScale = measured.width > 0 ? box.width / measured.width : 1
        let heightScale = measured.height > 0 ? box.height / measured.height : 1
        return font.pointSize * max(minScale, min(1, widthScale, heightScale))
    }

    private static func nsNumericWeight(_ weight: FontWeightToken, bold: Bool) -> Int {
        if bold, weight == .regular { return 9 }
        switch weight {
        case .thin: return 2
        case .regular: return 5
        case .medium: return 6
        case .semibold: return 8
        case .bold: return 9
        case .black: return 11
        }
    }

    private static func nsSystemWeight(_ weight: FontWeightToken, bold: Bool) -> NSFont.Weight {
        if bold, weight == .regular { return .bold }
        switch weight {
        case .thin: return .thin
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .black: return .black
        }
    }
}
#endif

enum TextTransformToken: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, uppercase, lowercase, capitalize, smallCaps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .uppercase: "UPPERCASE"
        case .lowercase: "lowercase"
        case .capitalize: "Title Case"
        case .smallCaps: "Small Caps"
        }
    }
}

enum TextHorizontalAlign: String, CaseIterable, Identifiable, Codable, Sendable {
    case left, center, right, justify, justifyAll, justifyLeft
    var id: String { rawValue }
}

enum TextVerticalAlign: String, CaseIterable, Identifiable, Codable, Sendable {
    case top, middle, bottom, baseline
    var id: String { rawValue }
}

enum TextListType: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, bullet, number, roman
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .bullet: "Bullets"
        case .number: "Numbers"
        case .roman: "Roman Numerals"
        }
    }
}

enum TextAutoFitMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, shrink, expand
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .shrink: "Shrink to Fit"
        case .expand: "Expand Box"
        }
    }
}

enum TextLoopDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case left, right, up, down
    var id: String { rawValue }
    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }
    var isVertical: Bool { self == .up || self == .down }

    /// Scroll axis + direction — shared by canvas, audience SwiftUI, and program compositor.
    var marqueeScroll: TextLoopMarqueeScroll {
        TextLoopMarqueeScroll(
            isVertical: isVertical,
            scrollForward: self == .left || self == .up,
            anchorToTrailing: self == .right,
            anchorToBottom: self == .down
        )
    }
}

struct TextLoopMarqueeScroll: Equatable, Sendable {
    var isVertical: Bool
    var scrollForward: Bool
    var anchorToTrailing: Bool
    var anchorToBottom: Bool
}

enum TextLineTransform: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, flatten, keep
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .flatten: "Flatten"
        case .keep: "Keep Breaks"
        }
    }
}

enum BuildEffect: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, dissolve, push, wipe, fly, zoom, flip
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum BuildDirection: String, CaseIterable, Identifiable, Codable, Sendable {
    case left, right, top, bottom
    var id: String { rawValue }
    var title: String { "From \(rawValue.capitalized)" }
}

enum BuildEasing: String, CaseIterable, Identifiable, Codable, Sendable {
    case linear, easeIn, easeOut, easeInOut, bounce
    var id: String { rawValue }
    var title: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In/Out"
        case .bounce: "Bounce"
        }
    }
}

enum BuildTrigger: String, CaseIterable, Identifiable, Codable, Sendable {
    case withSlide, onClick, afterPrevious, onChange
    var id: String { rawValue }
    var title: String {
        switch self {
        case .withSlide: "With Slide"
        case .onClick: "On Click"
        case .afterPrevious: "After Previous"
        case .onChange: "On Change"
        }
    }
}

enum CanvasAlign: String, CaseIterable, Identifiable, Sendable {
    case left, right, top, bottom, centerX, centerY
    var id: String { rawValue }
}

enum CanvasDistribute: String, CaseIterable, Identifiable, Sendable {
    case horizontal, vertical
    var id: String { rawValue }
}

struct ElementTransform: Hashable, Codable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var width: Double = 100
    var height: Double = 100
    var rotation: Double = 0
    var lockAspectRatio: Bool = true
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false
    var originX: Double? = nil
    var originY: Double? = nil
    var shearX: Double? = nil
    var shearY: Double? = nil

    var resolvedOriginX: Double { originX ?? 0.5 }
    var resolvedOriginY: Double { originY ?? 0.5 }

    var bounds: CanvasBounds {
        get { CanvasBounds(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.x
            y = newValue.y
            width = newValue.width
            height = newValue.height
        }
    }
}

struct GradientStop: Hashable, Codable, Sendable {
    var offset: Double
    var color: String
}

struct ElementFill: Hashable, Codable, Sendable {
    var type: ElementFillType = .color
    var color: String = "#FFFFFF"
    var gradientType: GradientKind = .linear
    var gradientAngle: Double = 90
    var gradientStops: [GradientStop] = [
        GradientStop(offset: 0, color: "#000000"),
        GradientStop(offset: 1, color: "#FFFFFF"),
    ]
    var imageURI: String = ""
    var imageScaleMode: ImageScaleMode = .fill
    var opacity: Double = 1
    var midpoints: [GradientMidpoint]? = nil
    var cropX: Double? = nil
    var cropY: Double? = nil
    var cropZoom: Double? = nil

    var resolvedCropX: Double { min(1, max(0, cropX ?? 0.5)) }
    var resolvedCropY: Double { min(1, max(0, cropY ?? 0.5)) }
    var resolvedCropZoom: Double { min(8, max(1, cropZoom ?? 1)) }
}

struct ElementStroke: Hashable, Codable, Sendable {
    var style: StrokeStyle = .none
    var color: String = "#FFFFFF"
    var width: Double = 2
    var position: StrokePosition = .outside
    var cornerRadius: Double = 0
    var cap: StrokeCap? = nil
    var join: StrokeJoin? = nil
    var dashPattern: [Double]? = nil
    var startMarker: StrokeMarker? = nil
    var endMarker: StrokeMarker? = nil
    var markerScale: Double? = nil
    var unlinkedCorners: Bool? = nil
    var corners: CornerRadii? = nil
    var cornerSmoothing: Double? = nil
}

struct ElementShadow: Hashable, Codable, Sendable {
    var enabled: Bool = false
    var color: String = "#80000000"
    var angle: Double = 315
    var offset: Double = 5
    var blur: Double = 10
    var feather: Double = 0
}

struct TextTypography: Hashable, Codable, Sendable {
    var fontFamily: String = "Inter"
    var fontWeight: FontWeightToken = .bold
    var fontSize: Double = 48
    var color: String = "#FFFFFF"
    var isBold: Bool = true
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var isStrikethrough: Bool = false
    var isSuperscript: Bool = false
    var isSubscript: Bool = false
    var textTransform: TextTransformToken = .none
}

struct TextBoxMargins: Hashable, Codable, Sendable {
    var top: Double = 10
    var bottom: Double = 10
    var left: Double = 15
    var right: Double = 15
}

struct TextLayout: Hashable, Codable, Sendable {
    var horizontalAlign: TextHorizontalAlign = .left
    var verticalAlign: TextVerticalAlign = .top
    var lineHeight: Double = 1.2
    var characterSpacing: Double = 0
    /// Extra space between words (canvas points).
    var wordSpacing: Double = 0
    var paragraphSpacingBefore: Double = 0
    var paragraphSpacingAfter: Double = 0
    var margins: TextBoxMargins = TextBoxMargins()
    var listType: TextListType = .none
    var autoFitMode: TextAutoFitMode = .shrink
    var frameMode: TextFrameMode? = nil
    var firstLineIndent: Double? = nil
    var baselineShift: Double? = nil
    var lineTransform: TextLineTransform? = nil
    var linesOnly: Bool? = nil
    var scrolling: Bool? = nil
    var linkedText: Bool? = nil
    var loopDirection: TextLoopDirection? = nil
    var loopSpeedPxPerSec: Double? = nil
    var loopGapPx: Double? = nil
    /// When loop is on: scroll live prices with green/red deltas (uses `LiveQuoteEngine` data).
    var marketTickerStrip: Bool? = nil

    var isLooping: Bool { scrolling == true }
    var resolvedMarketTickerStrip: Bool { marketTickerStrip == true }
    var resolvedLoopDirection: TextLoopDirection { loopDirection ?? .left }
    var resolvedLoopSpeed: Double { min(600, max(8, loopSpeedPxPerSec ?? 80)) }
    var resolvedLoopGap: Double { min(800, max(0, loopGapPx ?? 80)) }
}

struct TextOutline: Hashable, Codable, Sendable {
    var enabled: Bool = false
    var color: String = "#000000"
    var width: Double = 1.5
}

struct TextDropShadow: Hashable, Codable, Sendable {
    var enabled: Bool = false
    var color: String = "#CC000000"
    var angle: Double = 315
    var offset: Double = 4
    var blur: Double = 4
}

struct ElementBuildAnimation: Hashable, Codable, Sendable {
    var inEffect: BuildEffect = .dissolve
    var inDurationSec: Double = 0.5
    var inDirection: BuildDirection = .left
    var inEasing: BuildEasing = .easeInOut
    var outEffect: BuildEffect = .dissolve
    var outDurationSec: Double = 0.3
    var outDelaySec: Double = 0
    var trigger: BuildTrigger = .withSlide
    var sequenceOrder: Int = 1
}

struct EditorSnapshot: Hashable, Codable, Sendable {
    var documents: [EditorDocument]
    var selectedDocumentID: UUID?
    var selectedObjectIDs: Set<UUID>
    var inspectorTab: EditorInspectorTab
}

enum CanvasObjectKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case text, rectangle, roundedRectangle, ellipse, line, polygon, pen
    case image, videoInput, webView, browser
    case currentSlide, nextSlide, systemClock, systemDate, stageNotes, timerCountdown
    case liveQuote, textField
    case title, subtitle
    case copyrightToken
    case prop
    case maskShape, bezier, edgeBlend, cutout
    case qrCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text Box"
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .polygon: "Polygon"
        case .pen: "Pen Path"
        case .image: "Image"
        case .videoInput: "Video Input"
        case .webView: "Web View"
        case .browser: "Browser"
        case .currentSlide: "Current Slide Text"
        case .nextSlide: "Next Slide Text"
        case .systemClock: "Time"
        case .systemDate: "Date"
        case .stageNotes: "Stage Notes"
        case .timerCountdown: "Countdown"
        case .liveQuote: "Live Quote"
        case .textField: "Text Field"
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .copyrightToken: "Copyright"
        case .prop: "Prop"
        case .maskShape: "Mask Shape"
        case .bezier: "Bezier"
        case .edgeBlend: "Edge Blend"
        case .cutout: "Cutout"
        case .qrCode: "QR Code"
        }
    }

    var defaultName: String { title }

    var isTextLike: Bool {
        switch self {
        case .text, .title, .subtitle, .currentSlide, .nextSlide, .stageNotes, .copyrightToken,
             .systemClock, .systemDate, .timerCountdown, .liveQuote, .textField:
            true
        default:
            false
        }
    }

    var isBrowserLike: Bool {
        self == .webView || self == .browser
    }
}

struct CanvasBounds: Hashable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let canvas = CanvasBounds(x: 0, y: 0, width: CanvasConfig.width, height: CanvasConfig.height)

    static func centered(width: Double, height: Double, canvasWidth: Double = CanvasConfig.width, canvasHeight: Double = CanvasConfig.height) -> CanvasBounds {
        CanvasBounds(
            x: (canvasWidth - width) / 2,
            y: (canvasHeight - height) / 2,
            width: width,
            height: height
        )
    }

    var unionDescription: (x: Double, y: Double, width: Double, height: Double) {
        (x, y, width, height)
    }

    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func overlapsX(_ other: CanvasBounds) -> Bool {
        minX < other.maxX && maxX > other.minX
    }

    func overlapsY(_ other: CanvasBounds) -> Bool {
        minY < other.maxY && maxY > other.minY
    }

    func overlapMidX(with other: CanvasBounds) -> Double {
        guard overlapsX(other) else { return midX }
        return (max(minX, other.minX) + min(maxX, other.maxX)) / 2
    }

    func overlapMidY(with other: CanvasBounds) -> Double {
        guard overlapsY(other) else { return midY }
        return (max(minY, other.minY) + min(maxY, other.maxY)) / 2
    }
}

struct TimerColorThreshold: Hashable, Codable, Sendable {
    var timeRemainingSec: Int
    var colorHex: String
}

struct CanvasObject: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var kind: CanvasObjectKind
    var zIndex: Int
    var text: String
    var token: String
    var timerID: UUID?
    var warningThresholds: [TimerColorThreshold]
    var transform: ElementTransform
    var fill: ElementFill
    var stroke: ElementStroke
    var shadow: ElementShadow
    /// Optional for document backward compatibility.
    var shimmer: ElementShimmerEffect? = nil
    var typography: TextTypography
    var textLayout: TextLayout
    var textOutline: TextOutline
    var textShadow: TextDropShadow
    var build: ElementBuildAnimation
    var buildSteps: [ElementBuildStep]? = nil
    var opacity: Double
    var visibleOnAudience: Bool
    var visibleOnStage: Bool
    /// Prevents canvas selection and transform edits (layers panel lock).
    var isCanvasLocked: Bool = false
    var blendMode: LayerBlendMode? = nil
    var vectorPath: VectorPath? = nil
    var autoLayout: AutoLayoutFrame? = nil
    var booleanOp: BooleanOperation? = nil
    var clipToBelow: Bool? = nil
    var textRuns: [TextRun]? = nil
    var groupID: UUID? = nil
    var assignedSource: AssignedMediaSource? = nil
    var audioMuted: Bool? = nil
    var countdownStartOn: CountdownBuildLink? = nil
    var countdownResetOn: CountdownBuildLink? = nil
    var countdownValueSource: CountdownValueSource? = nil
    /// Theme blueprint slot; filled when object belongs to a theme variant layout.
    var themeSlot: ThemeSlotRole? = nil
    /// Order among equal slots when mapping by index.
    var themeSlotOrder: Int? = nil

    var resolvedCountdownStartOn: CountdownBuildLink { countdownStartOn ?? .none }
    var resolvedCountdownResetOn: CountdownBuildLink { countdownResetOn ?? .none }
    var resolvedCountdownValueSource: CountdownValueSource { countdownValueSource ?? .timer }

    init(
        id: UUID = UUID(),
        name: String,
        kind: CanvasObjectKind,
        bounds: CanvasBounds,
        zIndex: Int = 0,
        text: String = "",
        fillHex: String = "#FFFFFF",
        fontFamily: String = "Inter",
        fontSize: Double = 64,
        fontColor: String = "#FFFFFF",
        token: String = "",
        timerID: UUID? = nil,
        buildIn: String = "Dissolve",
        buildOut: String = "Dissolve",
        warningThresholds: [TimerColorThreshold] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.zIndex = zIndex
        self.text = text
        self.token = token
        self.timerID = timerID
        self.warningThresholds = warningThresholds
        self.transform = ElementTransform(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        self.fill = ElementFill(type: .color, color: fillHex)
        self.stroke = ElementStroke()
        self.shadow = ElementShadow()
        self.typography = TextTypography(fontFamily: fontFamily, fontSize: fontSize, color: fontColor)
        self.textLayout = TextLayout()
        self.textOutline = TextOutline()
        self.textShadow = TextDropShadow()
        self.build = ElementBuildAnimation(
            inEffect: BuildEffect(rawValue: buildIn.lowercased().replacingOccurrences(of: "-in", with: "")) ?? .dissolve,
            outEffect: BuildEffect(rawValue: buildOut.lowercased().replacingOccurrences(of: "-in", with: "")) ?? .dissolve
        )
        self.opacity = 1
        self.visibleOnAudience = true
        self.visibleOnStage = true
        self.isCanvasLocked = false
    }

    var bounds: CanvasBounds {
        get { transform.bounds }
        set { transform.bounds = newValue }
    }

    var fillHex: String {
        get { fill.color }
        set { fill.color = newValue }
    }

    var fontFamily: String {
        get { typography.fontFamily }
        set { typography.fontFamily = newValue }
    }

    var fontSize: Double {
        get { typography.fontSize }
        set { typography.fontSize = newValue }
    }

    var fontColor: String {
        get { typography.color }
        set { typography.color = newValue }
    }

    var buildIn: String {
        get { build.inEffect.title }
        set { build.inEffect = BuildEffect(rawValue: newValue.lowercased().replacingOccurrences(of: "-in", with: "")) ?? .dissolve }
    }

    var buildOut: String {
        get { build.outEffect.title }
        set { build.outEffect = BuildEffect(rawValue: newValue.lowercased().replacingOccurrences(of: "-in", with: "")) ?? .dissolve }
    }

    var isTextLike: Bool { kind.isTextLike }

    var resolvedBuildSteps: [ElementBuildStep] {
        if let buildSteps, !buildSteps.isEmpty { return buildSteps }
        return BuildAnimationEngine.synthesize(from: build, objectID: id)
    }

    func programMediaAction() -> MediaAction? {
        if let assigned = assignedSource, assigned.isMappedFill {
            let path = assigned.connectionString ?? fill.imageURI
            let video = assigned.looksLikeVideo || AssignedMediaSource.pathLooksLikeVideo(path)
            if video {
                return MediaAction(
                    id: assigned.mediaItemID ?? id,
                    title: assigned.name.isEmpty ? name : assigned.name,
                    tintHex: assigned.tintHex ?? fill.color,
                    isImage: false,
                    filePath: path.isEmpty ? nil : path,
                    placeholderLetter: assignedPlaceholderLetter ?? assigned.placeholderLetter
                )
            }
        }
        if AssignedMediaSource.pathLooksLikeVideo(fill.imageURI) {
            return MediaAction(
                id: id,
                title: name,
                tintHex: fill.color,
                isImage: false,
                filePath: fill.imageURI,
                placeholderLetter: assignedPlaceholderLetter
            )
        }
        return nil
    }

    func isFullBleedBackground(canvasWidth: Double, canvasHeight: Double) -> Bool {
        guard !isTextLike, visibleOnAudience else { return false }
        let width = max(canvasWidth, 1)
        let height = max(canvasHeight, 1)
        return bounds.x <= width * 0.02
            && bounds.y <= height * 0.02
            && bounds.width >= width * 0.96
            && bounds.height >= height * 0.96
    }

    var acceptsAssignedSource: Bool { !isTextLike }

    var assignedPlaceholderLetter: String? {
        if let letter = assignedSource?.placeholderLetter, let parsed = PlaceholderLetter.parse(letter) {
            return parsed.rawValue
        }
        if let connection = assignedSource?.connectionString, let parsed = PlaceholderLetter.parse(connection) {
            return parsed.rawValue
        }
        return PlaceholderLetter.parse(token)?.rawValue
    }

    var isAudioMuted: Bool { audioMuted == true }

    /// A lettered placeholder (A–I) that has no real source yet. It renders as an empty slot,
    /// never as whatever camera happens to be on the live-input layer.
    var isUnfilledPlaceholder: Bool {
        guard assignedPlaceholderLetter != nil else { return false }
        switch assignedSource?.sourceType {
        case nil, .placeholderSlot?: return true
        default: return false
        }
    }

    /// A video pane from before placeholders: no letter, no source. Slides with one still
    /// fall back to the preferred program camera.
    var isLegacyUnassignedVideoPane: Bool {
        kind == .videoInput && assignedSource == nil && assignedPlaceholderLetter == nil
    }

    /// Live capture assigned to a shape (program outline camera rows, etc.).
    var rendersLiveVideoInputOnCanvas: Bool {
        switch assignedSource?.sourceType {
        case .systemCamera, .systemDisplay, .systemWindow, .ndiSource, .rendezvousGuest, .srtStream:
            return true
        default:
            return false
        }
    }

    var hostsLayerBackedMedia: Bool {
        kind == .videoInput
            || assignedSource?.looksLikeVideo == true
            || assignedSource?.sourceType == .systemCamera
            || assignedSource?.sourceType == .ndiSource
            || assignedSource?.sourceType == .srtStream
            || assignedSource?.sourceType == .rendezvousGuest
            || assignedSource?.sourceType == .systemAudioCapture
            || assignedSource?.sourceType == .systemDisplay
            || assignedSource?.sourceType == .systemWindow
            || AssignedMediaSource.pathLooksLikeVideo(fill.imageURI)
    }

    var canCarryAudio: Bool {
        !isTextLike
            || assignedSource != nil
            || assignedPlaceholderLetter != nil
            || AssignedMediaSource.pathLooksLikeVideo(fill.imageURI)
    }

    var sourceSummary: String {
        if let assignedSource {
            return assignedSource.summary
        }
        if !fill.imageURI.isEmpty {
            return fill.imageURI
        }
        return "None"
    }

    mutating func applyAssignedSource(_ source: AssignedMediaSource) {
        let existingLetter = assignedPlaceholderLetter
        assignedSource = source
        if let hex = source.tintHex, !hex.isEmpty {
            fill.color = hex
        }
        switch source.sourceType {
        case .mediaFile, .libraryShow:
            if kind != .prop {
                kind = .image
            }
            let uri = source.connectionString ?? ""
            if uri.isEmpty {
                fill.type = .color
                fill.imageURI = source.mediaItemID?.uuidString ?? ""
            } else {
                fill.type = .image
                fill.imageURI = uri
            }
            if let existingLetter, token.isEmpty {
                token = existingLetter
            }
        case .placeholderSlot:
            if let letter = source.placeholderLetter {
                token = letter
                fill.type = .color
                fill.color = source.tintHex ?? fill.color
                fill.imageURI = ""
            } else if kind != .prop {
                token = source.name
            }
        case .solidColor:
            fill.type = .color
            fill.color = source.tintHex ?? source.connectionString ?? fill.color
            fill.imageURI = ""
        case .systemCamera, .ndiSource, .srtStream, .rendezvousGuest, .systemAudioCapture, .systemDisplay, .systemWindow:
            if kind != .prop {
                kind = .videoInput
            }
            token = source.connectionString ?? source.sourceID
            fill.type = .color
            fill.imageURI = ""
        case .webPage:
            if kind != .prop {
                kind = .browser
            }
            token = source.connectionString ?? token
            fill.imageURI = source.connectionString ?? fill.imageURI
        case .templateLayout, .systemMicrophone:
            token = source.connectionString ?? source.name
        }
        if source.sourceType != .placeholderSlot, assignedSource?.placeholderLetter == nil, let existingLetter {
            assignedSource?.placeholderLetter = existingLetter
            if token.isEmpty {
                token = existingLetter
            }
        }
    }

    mutating func clearAssignedSource() {
        assignedSource = nil
        if kind == .image || kind == .videoInput || kind.isBrowserLike || fill.type == .image {
            fill.imageURI = ""
            fill.type = .color
        }
    }

    /// Document-space corner radii used by editor, previews, and program.
    /// Rounded rectangles always resolve a visible radius when none is stored.
    var resolvedCornerRadii: CornerRadii {
        let stored = max(stroke.cornerRadius, stroke.corners?.maxRadius ?? 0)
        if let corners = stroke.corners, corners.maxRadius > 0 {
            return corners
        }
        var radius = stored
        if kind == .roundedRectangle, radius <= 0 {
            radius = defaultRoundedRadius
        }
        return .uniform(max(0, radius))
    }

    var defaultRoundedRadius: Double {
        max(24, min(bounds.width, bounds.height) * 0.12)
    }

    var usesRoundedMediaFrame: Bool {
        switch kind {
        case .ellipse, .cutout, .line, .polygon, .pen, .bezier:
            return false
        default:
            return !isTextLike
        }
    }

    var isMediaLike: Bool {
        kind == .image || kind == .videoInput || kind.isBrowserLike || kind == .prop || kind == .qrCode
            || fill.type == .image
            || assignedSource != nil
    }

    var displayText: String {
        var body = text.isEmpty ? name : text
        switch typography.textTransform {
        case .uppercase: body = body.uppercased()
        case .lowercase: body = body.lowercased()
        case .capitalize: body = body.localizedCapitalized
        case .smallCaps: body = body.uppercased()
        case .none: break
        }
        if textLayout.lineTransform == .flatten {
            body = body.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        switch textLayout.listType {
        case .none:
            return body
        case .bullet:
            return lines.map { "• \($0)" }.joined(separator: "\n")
        case .number:
            return lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .roman:
            return lines.enumerated().map { "\(Self.roman($0.offset + 1)). \($0.element)" }.joined(separator: "\n")
        }
    }

    private static func roman(_ value: Int) -> String {
        let pairs: [(Int, String)] = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = max(1, value)
        var result = ""
        for (amount, glyph) in pairs {
            while remaining >= amount {
                result += glyph
                remaining -= amount
            }
        }
        return result
    }

    func asSlideElement(canvasWidth: Double, canvasHeight: Double) -> SlideCanvasElement {
        SlideCanvasElement(
            id: id,
            text: text,
            alignment: textLayout.horizontalAlign.rawValue,
            x: (transform.x + transform.width / 2) / max(canvasWidth, 1),
            y: (transform.y + transform.height / 2) / max(canvasHeight, 1)
        )
    }
}

struct CopyrightInfo: Hashable, Codable, Sendable {
    var title: String = ""
    var artist: String = ""
    var author: String = ""
    var album: String = ""
    var publisher: String = ""
    var year: String = ""
    var ccliNumber: String = ""
    var artworkName: String = ""
    var showOnScreen: Bool = false

    func resolvedLine(template: String = "{Title} · {Artist} · {Publisher} © {Copyright Year} CCLI {License Number}") -> String {
        template
            .replacingOccurrences(of: "{Title}", with: title)
            .replacingOccurrences(of: "{Artist}", with: artist)
            .replacingOccurrences(of: "{Author}", with: author)
            .replacingOccurrences(of: "{Album}", with: album)
            .replacingOccurrences(of: "{Publisher}", with: publisher)
            .replacingOccurrences(of: "{Copyright Year}", with: year)
            .replacingOccurrences(of: "{License Number}", with: ccliNumber)
            .replacingOccurrences(of: " ·  · ", with: " · ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One artboard on a slide. The primary frame owns the slide's program objects.
/// Each frame keeps its own guides, background, and extra objects.
struct EditorCanvasFrame: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var width: Double
    var height: Double
    var originX: Double
    var originY: Double
    var isPrimary: Bool
    var backgroundEnabled: Bool
    var backgroundHex: String
    var showsCheckerboard: Bool
    var showsGrid: Bool
    var showsSafeAreas: Bool
    var showsHeaderFooter: Bool
    var showsColumnGrid: Bool
    /// Objects that belong to this frame. The primary frame's program objects stay on the document.
    var objects: [CanvasObject]

    static func primary(for document: EditorDocument, guides: CanvasGridConfig = CanvasGridConfig(), checkerboard: Bool = false) -> EditorCanvasFrame {
        let family = CanvasResolution.screenFamily(width: document.canvasWidth, height: document.canvasHeight)
        return EditorCanvasFrame(
            id: document.id,
            name: family.title,
            width: document.canvasWidth,
            height: document.canvasHeight,
            originX: 0,
            originY: 0,
            isPrimary: true,
            backgroundEnabled: document.backgroundEnabled,
            backgroundHex: document.backgroundHex,
            showsCheckerboard: checkerboard,
            showsGrid: guides.isGridVisible,
            showsSafeAreas: guides.showBroadcastSafeAreas,
            showsHeaderFooter: guides.showHeaderFooterGuides,
            showsColumnGrid: guides.showColumnLayoutGrid,
            objects: []
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, name, width, height, originX, originY, isPrimary
        case backgroundEnabled, backgroundHex, showsCheckerboard, showsGrid
        case showsSafeAreas, showsHeaderFooter, showsColumnGrid, objects
    }

    init(
        id: UUID,
        name: String,
        width: Double,
        height: Double,
        originX: Double,
        originY: Double,
        isPrimary: Bool,
        backgroundEnabled: Bool = true,
        backgroundHex: String = "#000000",
        showsCheckerboard: Bool = false,
        showsGrid: Bool = true,
        showsSafeAreas: Bool = false,
        showsHeaderFooter: Bool = false,
        showsColumnGrid: Bool = false,
        objects: [CanvasObject] = []
    ) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.isPrimary = isPrimary
        self.backgroundEnabled = backgroundEnabled
        self.backgroundHex = backgroundHex
        self.showsCheckerboard = showsCheckerboard
        self.showsGrid = showsGrid
        self.showsSafeAreas = showsSafeAreas
        self.showsHeaderFooter = showsHeaderFooter
        self.showsColumnGrid = showsColumnGrid
        self.objects = objects
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        originX = try container.decode(Double.self, forKey: .originX)
        originY = try container.decode(Double.self, forKey: .originY)
        isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
        backgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true
        backgroundHex = try container.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#000000"
        showsCheckerboard = try container.decodeIfPresent(Bool.self, forKey: .showsCheckerboard) ?? false
        showsGrid = try container.decodeIfPresent(Bool.self, forKey: .showsGrid) ?? true
        showsSafeAreas = try container.decodeIfPresent(Bool.self, forKey: .showsSafeAreas) ?? false
        showsHeaderFooter = try container.decodeIfPresent(Bool.self, forKey: .showsHeaderFooter) ?? false
        showsColumnGrid = try container.decodeIfPresent(Bool.self, forKey: .showsColumnGrid) ?? false
        objects = try container.decodeIfPresent([CanvasObject].self, forKey: .objects) ?? []
    }
}

struct EditorBackgroundFill: Hashable, Sendable {
    var isTransparent: Bool
    var hex: String
}

struct EditorDocument: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var kind: EditorKind
    var slideID: SlideID?
    var canvasWidth: Double
    var canvasHeight: Double
    var backgroundEnabled: Bool
    var backgroundHex: String
    var backgroundFill: EditorBackgroundFill {
        EditorBackgroundFill(isTransparent: !backgroundEnabled, hex: backgroundHex)
    }
    var objects: [CanvasObject]
    var collectionName: String
    var variantName: String
    var transition: String
    var transitionDuration: Double
    var notes: String
    var autoClear: String
    var invertMask: Bool
    var mediaActionTitle: String
    var groups: [CanvasGroupNode]?
    /// Layout guidelines created from the canvas rulers (document coordinates).
    var userGuides: [UserGuideLine]
    /// Extra screens on this slide, plus the primary frame once it has been moved or another frame exists.
    var boards: [EditorCanvasFrame]

    init(
        id: UUID = UUID(),
        name: String,
        kind: EditorKind,
        slideID: SlideID? = nil,
        canvasWidth: Double = CanvasConfig.width,
        canvasHeight: Double = CanvasConfig.height,
        backgroundEnabled: Bool = true,
        backgroundHex: String = "#000000",
        objects: [CanvasObject] = [],
        collectionName: String = "Default Collection",
        variantName: String = "",
        transition: String = "Cut",
        transitionDuration: Double = 0.8,
        notes: String = "",
        autoClear: String = "Never",
        invertMask: Bool = false,
        mediaActionTitle: String = "",
        groups: [CanvasGroupNode]? = nil,
        userGuides: [UserGuideLine] = [],
        boards: [EditorCanvasFrame] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.slideID = slideID
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.backgroundEnabled = backgroundEnabled
        self.backgroundHex = backgroundHex
        self.objects = objects
        self.collectionName = collectionName
        self.variantName = variantName
        self.transition = transition
        self.transitionDuration = transitionDuration
        self.notes = notes
        self.autoClear = autoClear
        self.invertMask = invertMask
        self.mediaActionTitle = mediaActionTitle
        self.groups = groups
        self.userGuides = userGuides
        self.boards = boards
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, slideID, canvasWidth, canvasHeight, backgroundEnabled, backgroundHex
        case objects, collectionName, variantName, transition, transitionDuration, notes
        case autoClear, invertMask, mediaActionTitle, groups, userGuides, boards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(EditorKind.self, forKey: .kind)
        slideID = try container.decodeIfPresent(SlideID.self, forKey: .slideID)
        canvasWidth = try container.decodeIfPresent(Double.self, forKey: .canvasWidth) ?? CanvasConfig.width
        canvasHeight = try container.decodeIfPresent(Double.self, forKey: .canvasHeight) ?? CanvasConfig.height
        backgroundEnabled = try container.decodeIfPresent(Bool.self, forKey: .backgroundEnabled) ?? true
        backgroundHex = try container.decodeIfPresent(String.self, forKey: .backgroundHex) ?? "#000000"
        objects = try container.decodeIfPresent([CanvasObject].self, forKey: .objects) ?? []
        collectionName = try container.decodeIfPresent(String.self, forKey: .collectionName) ?? "Default Collection"
        variantName = try container.decodeIfPresent(String.self, forKey: .variantName) ?? ""
        transition = try container.decodeIfPresent(String.self, forKey: .transition) ?? "Cut"
        transitionDuration = try container.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 0.8
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        autoClear = try container.decodeIfPresent(String.self, forKey: .autoClear) ?? "Never"
        invertMask = try container.decodeIfPresent(Bool.self, forKey: .invertMask) ?? false
        mediaActionTitle = try container.decodeIfPresent(String.self, forKey: .mediaActionTitle) ?? ""
        groups = try container.decodeIfPresent([CanvasGroupNode].self, forKey: .groups)
        userGuides = try container.decodeIfPresent([UserGuideLine].self, forKey: .userGuides) ?? []
        boards = try container.decodeIfPresent([EditorCanvasFrame].self, forKey: .boards) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(slideID, forKey: .slideID)
        try container.encode(canvasWidth, forKey: .canvasWidth)
        try container.encode(canvasHeight, forKey: .canvasHeight)
        try container.encode(backgroundEnabled, forKey: .backgroundEnabled)
        try container.encode(backgroundHex, forKey: .backgroundHex)
        try container.encode(objects, forKey: .objects)
        try container.encode(collectionName, forKey: .collectionName)
        try container.encode(variantName, forKey: .variantName)
        try container.encode(transition, forKey: .transition)
        try container.encode(transitionDuration, forKey: .transitionDuration)
        try container.encode(notes, forKey: .notes)
        try container.encode(autoClear, forKey: .autoClear)
        try container.encode(invertMask, forKey: .invertMask)
        try container.encode(mediaActionTitle, forKey: .mediaActionTitle)
        try container.encodeIfPresent(groups, forKey: .groups)
        try container.encode(userGuides, forKey: .userGuides)
        if !boards.isEmpty {
            try container.encode(boards, forKey: .boards)
        }
    }

    var sortedObjects: [CanvasObject] {
        objects.sorted { $0.zIndex > $1.zIndex }
    }

    func selectionBounds(ids: Set<UUID>) -> CanvasBounds? {
        let selected = objects.filter { ids.contains($0.id) }
        guard let first = selected.first else { return nil }
        var minX = first.bounds.x
        var minY = first.bounds.y
        var maxX = first.bounds.x + first.bounds.width
        var maxY = first.bounds.y + first.bounds.height
        for object in selected.dropFirst() {
            minX = min(minX, object.bounds.x)
            minY = min(minY, object.bounds.y)
            maxX = max(maxX, object.bounds.x + object.bounds.width)
            maxY = max(maxY, object.bounds.y + object.bounds.height)
        }
        return CanvasBounds(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func applyToSlide(_ slide: inout Slide) {
        slide.canvas = objects
        slide.notes = notes
        slide.backgroundEnabled = backgroundEnabled
        slide.backgroundHex = backgroundHex
        if !transition.isEmpty {
            slide.transition = transition
        }
        let textObjects = objects.filter(\.isTextLike).sorted { $0.transform.y < $1.transform.y }
        slide.elements = textObjects.map { $0.asSlideElement(canvasWidth: canvasWidth, canvasHeight: canvasHeight) }
        let lines = textObjects
            .flatMap { $0.displayText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        slide.lines = lines
        if lines.isEmpty && slide.canvas.isEmpty {
            slide.isBlank = slide.mediaAction == nil
            slide.themeApplication = .native
        } else if !lines.isEmpty {
            slide.isBlank = false
        }
        if let align = textObjects.first?.textLayout.horizontalAlign.rawValue {
            slide.alignment = align
        }
        slide.editorCanvases = boards
        if mediaActionTitle.isEmpty {
            if slide.mediaAction?.filePath == nil {
                slide.mediaAction = nil
            }
        } else if slide.mediaAction?.title != mediaActionTitle {
            slide.mediaAction = MediaAction(
                id: slide.mediaAction?.id ?? UUID(),
                title: mediaActionTitle,
                tintHex: slide.mediaAction?.tintHex ?? "#1B3A4B",
                duration: slide.mediaAction?.duration,
                isImage: slide.mediaAction?.isImage ?? false,
                filePath: slide.mediaAction?.filePath
            )
        }
    }
}

enum EditorLiveAction: Equatable, Sendable {
    case goLive(SlideID)
    case setStageLook(StageLookConfig)
    case applyTheme(String)
    case setMessage(String)
    case toggleProp(String)
    case setMask(enabled: Bool, invert: Bool, kind: String)
}

/// Video frame the editor is showing. The program encoder stays on the project canvas.
enum CanvasScreenFamily: String, Sendable {
    case phone
    case tablet
    case desktop
    case custom

    var title: String {
        switch self {
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .desktop: "Desktop"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .tablet: "ipad"
        case .desktop: "desktopcomputer"
        case .custom: "rectangle.dashed"
        }
    }
}

enum CanvasResolution: String, CaseIterable, Identifiable, Sendable {
    case phonePortrait = "1080 x 1920"
    case portraitFeed = "1080 x 1350"
    case square = "1080 x 1080"
    case iPadLandscape = "2048 x 1536"
    case hd1080 = "1920 x 1080"
    case hd720 = "1280 x 720"
    case uhd = "3840 x 2160"
    case xga = "1024 x 768"

    var id: String { rawValue }

    var size: (width: Double, height: Double) {
        switch self {
        case .phonePortrait: (1080, 1920)
        case .portraitFeed: (1080, 1350)
        case .square: (1080, 1080)
        case .iPadLandscape: (2048, 1536)
        case .hd1080: (1920, 1080)
        case .hd720: (1280, 720)
        case .uhd: (3840, 2160)
        case .xga: (1024, 768)
        }
    }

    var family: CanvasScreenFamily {
        switch self {
        case .phonePortrait, .portraitFeed, .square: .phone
        case .iPadLandscape: .tablet
        case .hd1080, .hd720, .uhd, .xga: .desktop
        }
    }

    /// Size shown in the canvas menu. iPad is named because 2048×1536 is that landscape frame.
    var menuTitle: String {
        let pixels = "\(Int(size.width)) × \(Int(size.height))"
        if self == .iPadLandscape { return "iPad landscape, \(pixels)" }
        return pixels
    }

    static let phonePresets: [CanvasResolution] = [.phonePortrait, .portraitFeed, .square]
    static let tabletPresets: [CanvasResolution] = [.iPadLandscape]
    static let desktopPresets: [CanvasResolution] = [.hd1080, .hd720, .uhd, .xga]

    static func exact(width: Double, height: Double) -> CanvasResolution? {
        allCases.first { abs($0.size.width - width) < 0.5 && abs($0.size.height - height) < 0.5 }
    }

    static func matching(width: Double, height: Double) -> CanvasResolution {
        exact(width: width, height: height) ?? .uhd
    }

    static func screenFamily(width: Double, height: Double) -> CanvasScreenFamily {
        exact(width: width, height: height)?.family ?? .custom
    }
}

extension EditorCanvasFrame {
    /// Portrait phone artboard: exact phone presets, 9:16 design (e.g. 2160x3840), or named Phone.
    var isPhoneArtboard: Bool {
        guard !isPrimary else { return false }
        if CanvasResolution.screenFamily(width: width, height: height) == .phone { return true }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "phone" { return true }
        return height > width * 1.15
    }
}


enum EditorCatalog {
    static let buildAnimations = ["Dissolve", "Push", "Wipe", "Fly-in"]
    static let autoClearRules = ["Never", "After Delay", "On Next Slide"]
    static let ccliTokens = ["{Title}", "{Artist}", "{Publisher}", "{Copyright Year}", "{License Number}"]
    static let themeVariants = ["Lyric Standard", "Lower Third", "Talk Point", "Title & Subtitle", "Scripture", "Picture Slide"]
    static let themeCollections = ["Black", "Default", "Lyrics"]
    static let shapes: [CanvasObjectKind] = [.rectangle, .roundedRectangle, .ellipse, .line, .polygon, .browser]
    static let liveObjects: [CanvasObjectKind] = [.systemClock, .systemDate, .timerCountdown, .liveQuote, .textField]

    static func toolbarItems(for kind: EditorKind?) -> [CanvasObjectKind] {
        switch kind {
        case .presentation, .props: [.text, .pen, .image, .videoInput, .browser]
        case .stage: [.currentSlide, .nextSlide, .stageNotes, .systemClock, .systemDate, .timerCountdown]
        case .theme: [.title, .subtitle, .rectangle]
        case .ccli: [.copyrightToken]
        case .masks: [.maskShape, .pen, .cutout]
        case .overlays: [.text, .title, .image]
        case nil: []
        }
    }

    static func showsShapeMenu(_ kind: EditorKind?) -> Bool {
        switch kind {
        case .presentation, .props, .overlays: true
        default: false
        }
    }

    static func showsLiveMenu(_ kind: EditorKind?) -> Bool {
        switch kind {
        case .presentation, .props, .overlays, .stage: true
        default: false
        }
    }

    static var fonts: [String] { SystemFontCatalog.families }
    static let transitionDurations = [0.3, 0.5, 0.8, 1.0]
}

enum SystemFontCatalog {
    static let fallbacks = ["Arial", "Helvetica Neue", "Helvetica", "Inter", "Georgia", "Times New Roman", "Avenir Next", "Cinzel"]

    static var families: [String] {
        var names = Set(installed)
        names.formUnion(fallbacks)
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func menu(including current: String?) -> [String] {
        var list = families
        if let current, !current.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            list.insert(current, at: 0)
        }
        return list
    }

    private static var installed: [String] {
        #if canImport(AppKit)
        return NSFontManager.shared.availableFontFamilies
        #elseif canImport(UIKit)
        return UIFont.familyNames
        #else
        return []
        #endif
    }
}
