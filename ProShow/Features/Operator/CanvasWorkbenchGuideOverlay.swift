import SwiftUI

/// Grid on the pasteboard plus smart guides across the workspace.
struct CanvasWorkbenchGuideOverlay: View {
    var gridConfig: CanvasGridConfig
    var snapState: LayoutSnapState
    var canvasWidth: Double
    var canvasHeight: Double
    var scale: CGFloat
    var viewportSize: CGSize
    var canvasOrigin: CGPoint

    private var guideStroke: Color {
        Color(hex: SmartGuideEngine.guideColorHex) ?? Color(red: 1, green: 0, blue: 0.33)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if gridConfig.isGridVisible {
                gridLayer
            }
            smartGuideLayer
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var gridLayer: some View {
        Canvas { context, size in
            CanvasGridDisplay.drawGrid(
                context: &context,
                clipSize: size,
                documentWidth: CGFloat(canvasWidth),
                documentHeight: CGFloat(canvasHeight),
                scale: scale,
                unit: gridConfig.gridSizePoints,
                viewportOrigin: canvasOrigin
            )
        }
        .allowsHitTesting(false)
    }

    private var smartGuideLayer: some View {
        Canvas { context, size in
            for line in snapState.activeGuides {
                var path = Path()
                switch line.direction {
                case .vertical(let x):
                    let sx = canvasOrigin.x + CGFloat(x) * scale
                    path.move(to: CGPoint(x: sx, y: 0))
                    path.addLine(to: CGPoint(x: sx, y: size.height))
                case .horizontal(let y):
                    let sy = canvasOrigin.y + CGFloat(y) * scale
                    path.move(to: CGPoint(x: 0, y: sy))
                    path.addLine(to: CGPoint(x: size.width, y: sy))
                }
                context.stroke(path, with: .color(guideStroke), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
