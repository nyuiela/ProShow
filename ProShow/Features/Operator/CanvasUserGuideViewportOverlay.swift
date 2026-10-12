import SwiftUI

/// User guidelines spanning the workspace (display only — create and edit from rulers).
struct CanvasUserGuideViewportOverlay: View {
    var viewportSize: CGSize
    var canvasOrigin: CGPoint
    var scale: CGFloat
    var userGuides: [UserGuideLine]
    var spawnPreview: UserGuideLine?

    private var userGuideStroke: Color {
        Color.cyan.opacity(0.85)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(userGuides) { guide in
                userGuideLine(guide)
            }
            if let spawnPreview {
                userGuideLine(spawnPreview)
                    .opacity(0.75)
            }
        }
        .frame(width: viewportSize.width, height: viewportSize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func userGuideLine(_ guide: UserGuideLine) -> some View {
        if guide.axis == .horizontal {
            let y = canvasOrigin.y + guide.position * scale
            Rectangle()
                .fill(userGuideStroke)
                .frame(width: viewportSize.width, height: 1)
                .position(x: viewportSize.width / 2, y: y)
        } else {
            let x = canvasOrigin.x + guide.position * scale
            Rectangle()
                .fill(userGuideStroke)
                .frame(width: 1, height: viewportSize.height)
                .position(x: x, y: viewportSize.height / 2)
        }
    }
}
