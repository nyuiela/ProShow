import SwiftUI

/// Grid dots, smart guide vectors, and equal-spacing pills on the canvas editor.
struct CanvasGuideOverlayView: View {
    var gridConfig: CanvasGridConfig
    var snapState: LayoutSnapState
    var canvasWidth: Double
    var canvasHeight: Double
    var scale: CGFloat
    var userGuides: [UserGuideLine] = []
    var spawnPreview: UserGuideLine?
    var onMoveUserGuide: (UUID, CGFloat) -> Void = { _, _ in }
    var onEndUserGuide: (UUID, CGFloat, GuideAxis) -> Void = { _, _, _ in }

    private var guideStroke: Color {
        Color(hex: SmartGuideEngine.guideColorHex) ?? Color(red: 1, green: 0, blue: 0.33)
    }

    private var userGuideStroke: Color {
        Color.cyan.opacity(0.85)
    }

    /// When true, grid and guides render on `CanvasWorkbenchGuideOverlay` instead of here.
    var workbenchGuidesEnabled: Bool = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !workbenchGuidesEnabled {
                legacyCanvasBoundGuides
            }
            badgeLayer
                .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var legacyCanvasBoundGuides: some View {
        if gridConfig.isGridVisible {
            gridLayer
        }
        userGuideLayer
        guideLayer
            .allowsHitTesting(false)
    }

    private var gridLayer: some View {
        Canvas { context, size in
            let step = max(1, gridConfig.gridSizePoints * scale)
            var x: CGFloat = 0
            while x <= size.width {
                var y: CGFloat = 0
                while y <= size.height {
                    let rect = CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.1)))
                    y += step
                }
                x += step
            }
        }
    }

    private var userGuideLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(displayUserGuides) { guide in
                userGuideLineView(guide, interactive: true)
            }
        }
    }

    private var displayUserGuides: [UserGuideLine] {
        var guides = userGuides
        if let spawnPreview {
            guides.append(spawnPreview)
        }
        return guides
    }

    @ViewBuilder
    private func userGuideLineView(_ guide: UserGuideLine, interactive: Bool) -> some View {
        let width = canvasWidth * scale
        let height = canvasHeight * scale
        Group {
            if guide.axis == .horizontal {
                Rectangle()
                    .fill(userGuideStroke)
                    .frame(width: width, height: 1)
                    .position(x: width / 2, y: guide.position * scale)
            } else {
                Rectangle()
                    .fill(userGuideStroke)
                    .frame(width: 1, height: height)
                    .position(x: guide.position * scale, y: height / 2)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .allowsHitTesting(interactive)
    }

    private var guideLayer: some View {
        Canvas { context, _ in
            for line in snapState.activeGuides {
                var path = Path()
                path.move(to: scaled(line.startPoint))
                path.addLine(to: scaled(line.endPoint))
                context.stroke(path, with: .color(guideStroke), lineWidth: 1)
            }
        }
    }

    private var badgeLayer: some View {
        ForEach(snapState.spacingBadges) { badge in
            Text("\(Int(badge.gapPx.rounded())) px")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(guideStroke.opacity(0.92), in: Capsule(style: .continuous))
                .offset(
                    x: badge.bounds.midX * scale,
                    y: badge.bounds.midY * scale
                )
        }
    }

    private func scaled(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale, y: point.y * scale)
    }
}
