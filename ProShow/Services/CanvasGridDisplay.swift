import SwiftUI

/// Figma-style square grid: 8 pt base unit, 64 pt major lines, zoom-adaptive stride on screen.
enum CanvasGridDisplay {
    static let majorSpacingDocument: CGFloat = 64

    struct Metrics: Equatable {
        let unit: CGFloat
        let stride: Int
        var screenStep: CGFloat { unit * CGFloat(stride) }
    }

    /// Collapse subdivisions when zoomed out so lines stay ≥ ~8 pt on screen.
    static func metrics(unit: CGFloat, scale: CGFloat) -> Metrics {
        let base = max(1, unit)
        var stride = 1
        while base * CGFloat(stride) * max(scale, 0.0001) < 8, stride < 32 {
            stride *= 2
        }
        return Metrics(unit: base, stride: stride)
    }

    static func isMajor(documentPosition: CGFloat) -> Bool {
        let spacing = majorSpacingDocument
        guard spacing > 0 else { return false }
        let remainder = documentPosition.truncatingRemainder(dividingBy: spacing)
        return remainder < 0.05 || remainder > spacing - 0.05
    }

    /// Screen-space size of one layout grid unit (matches checkerboard cells on transparent slides).
    static func screenUnit(documentUnit: CGFloat, scale: CGFloat) -> CGFloat {
        max(1, documentUnit * max(scale, 0.0001))
    }

    /// Checkerboard square size in canvas points: stays aligned to the layout grid but never smaller than ~16 pt on screen.
    static func checkerboardCellSize(
        documentUnit: CGFloat,
        scale: CGFloat,
        minimumScreenPoints: CGFloat = 16
    ) -> CGFloat {
        let base = max(1, documentUnit)
        let safeScale = max(scale, 0.0001)
        var stride = 1
        while base * CGFloat(stride) * safeScale < minimumScreenPoints, stride < 64 {
            stride *= 2
        }
        return base * CGFloat(stride) * safeScale
    }

    static func strokeColor(isMajor: Bool) -> Color {
        Color.white.opacity(isMajor ? 0.22 : 0.09)
    }

    static func lineWidth(isMajor: Bool) -> CGFloat {
        isMajor ? 1 : 0.5
    }

    /// Grid clipped to the artboard in canvas space (0…width × 0…height document).
    static func drawArtboardGrid(
        context: inout GraphicsContext,
        documentWidth: CGFloat,
        documentHeight: CGFloat,
        scale: CGFloat,
        unit: CGFloat,
        pixelWidth: CGFloat? = nil,
        pixelHeight: CGFloat? = nil
    ) {
        guard documentWidth > 0, documentHeight > 0 else { return }
        let metrics = metrics(unit: unit, scale: scale)
        let base = metrics.unit
        let stride = metrics.stride
        let strideDoc = base * CGFloat(stride)
        let width = pixelWidth ?? documentWidth * scale
        let height = pixelHeight ?? documentHeight * scale
        let drawWidth = max(width, documentWidth * scale) + 1
        let drawHeight = max(height, documentHeight * scale) + 1

        var docX: CGFloat = 0
        while docX <= documentWidth + 0.001 {
            strokeArtboardVertical(context: &context, docX: docX, height: drawHeight, scale: scale)
            docX += strideDoc
        }
        if documentWidth > 0 {
            strokeArtboardVertical(context: &context, docX: documentWidth, height: drawHeight, scale: scale)
        }

        var docY: CGFloat = 0
        while docY <= documentHeight + 0.001 {
            strokeArtboardHorizontal(context: &context, docY: docY, width: drawWidth, scale: scale)
            docY += strideDoc
        }
        if documentHeight > 0 {
            strokeArtboardHorizontal(context: &context, docY: documentHeight, width: drawWidth, scale: scale)
        }
    }

    private static func strokeArtboardVertical(
        context: inout GraphicsContext,
        docX: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) {
        let x = docX * scale
        let isMajor = isMajor(documentPosition: docX)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: height))
        context.stroke(
            path,
            with: .color(strokeColor(isMajor: isMajor)),
            lineWidth: lineWidth(isMajor: isMajor)
        )
    }

    private static func strokeArtboardHorizontal(
        context: inout GraphicsContext,
        docY: CGFloat,
        width: CGFloat,
        scale: CGFloat
    ) {
        let y = docY * scale
        let isMajor = isMajor(documentPosition: docY)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: width, y: y))
        context.stroke(
            path,
            with: .color(strokeColor(isMajor: isMajor)),
            lineWidth: lineWidth(isMajor: isMajor)
        )
    }

    static func drawGrid(
        context: inout GraphicsContext,
        clipSize: CGSize,
        documentWidth: CGFloat,
        documentHeight: CGFloat,
        scale: CGFloat,
        unit: CGFloat,
        viewportOrigin: CGPoint = .zero
    ) {
        let metrics = metrics(unit: unit, scale: scale)
        let base = metrics.unit
        let stride = metrics.stride
        let width = clipSize.width
        let height = clipSize.height

        let nXStart = Int(floor((0 - viewportOrigin.x) / max(scale, 0.0001) / base)) - 3
        let nXEnd = Int(ceil((width - viewportOrigin.x) / max(scale, 0.0001) / base)) + 3
        for n in nXStart...nXEnd where positiveMod(n, stride) == 0 {
            let docX = CGFloat(n) * base
            let x = viewportOrigin.x + docX * scale
            guard x >= -2, x <= width + 2 else { continue }
            let isMajor = isMajor(documentPosition: docX)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: height))
            context.stroke(
                path,
                with: .color(strokeColor(isMajor: isMajor)),
                lineWidth: lineWidth(isMajor: isMajor)
            )
        }

        let nYStart = Int(floor((0 - viewportOrigin.y) / max(scale, 0.0001) / base)) - 3
        let nYEnd = Int(ceil((height - viewportOrigin.y) / max(scale, 0.0001) / base)) + 3
        for n in nYStart...nYEnd where positiveMod(n, stride) == 0 {
            let docY = CGFloat(n) * base
            let y = viewportOrigin.y + docY * scale
            guard y >= -2, y <= height + 2 else { continue }
            let isMajor = isMajor(documentPosition: docY)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: width, y: y))
            context.stroke(
                path,
                with: .color(strokeColor(isMajor: isMajor)),
                lineWidth: lineWidth(isMajor: isMajor)
            )
        }

        if documentWidth > 0, documentHeight > 0 {
            let artboard = CGRect(
                x: viewportOrigin.x,
                y: viewportOrigin.y,
                width: documentWidth * scale,
                height: documentHeight * scale
            )
            context.stroke(
                Path(artboard),
                with: .color(Color.white.opacity(0.18)),
                lineWidth: 1
            )
        }
    }

    private static func positiveMod(_ value: Int, _ divisor: Int) -> Int {
        guard divisor > 0 else { return value }
        let remainder = value % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }
}

/// Grid drawn on the artboard (above backdrop, under objects).
struct CanvasArtboardGridView: View {
    var gridConfig: CanvasGridConfig
    var canvasWidth: Double
    var canvasHeight: Double
    var scale: CGFloat

    var body: some View {
        let width = CGFloat(canvasWidth) * scale
        let height = CGFloat(canvasHeight) * scale
        GeometryReader { proxy in
            Canvas(rendersAsynchronously: false) { context, size in
                let pixelWidth = max(size.width, proxy.size.width)
                let pixelHeight = max(size.height, proxy.size.height)
                var drawContext = context
                CanvasGridDisplay.drawArtboardGrid(
                    context: &drawContext,
                    documentWidth: CGFloat(canvasWidth),
                    documentHeight: CGFloat(canvasHeight),
                    scale: scale,
                    unit: gridConfig.gridSizePoints,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight
                )
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
