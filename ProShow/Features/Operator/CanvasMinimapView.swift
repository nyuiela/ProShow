import SwiftUI

/// Floating navigator showing canvas objects and the visible viewport lens.
struct CanvasMinimapView: View {
    var canvasSize: CGSize
    var objects: [CanvasObject]
    var currentZoom: CGFloat
    var viewportOriginCanvas: CGPoint
    var paneSize: CGSize
    var onNavigate: (CGPoint) -> Void

    private let mapWidth: CGFloat = 160

    private var mapScale: CGFloat {
        guard canvasSize.width > 0 else { return 1 }
        return mapWidth / canvasSize.width
    }

    private var mapHeight: CGFloat {
        canvasSize.height * mapScale
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DeskRadius.card, style: .continuous)
                .fill(ProShowTheme.well)
                .overlay {
                    RoundedRectangle(cornerRadius: DeskRadius.card, style: .continuous)
                        .strokeBorder(ProShowTheme.hairline, lineWidth: 1)
                }

            ForEach(objects) { object in
                Rectangle()
                    .fill(ProShowTheme.accent.opacity(0.45))
                    .frame(
                        width: max(2, CGFloat(object.bounds.width) * mapScale),
                        height: max(2, CGFloat(object.bounds.height) * mapScale)
                    )
                    .position(
                        x: CGFloat(object.bounds.x + object.bounds.width / 2) * mapScale,
                        y: CGFloat(object.bounds.y + object.bounds.height / 2) * mapScale
                    )
            }

            viewportLens
        }
        .frame(width: mapWidth, height: mapHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let canvasPoint = CGPoint(
                        x: value.location.x / mapScale,
                        y: value.location.y / mapScale
                    )
                    onNavigate(canvasPoint)
                }
        )
        .accessibilityLabel("Canvas minimap")
        .accessibilityHint("Drag to pan the canvas viewport")
    }

    private var viewportLens: some View {
        let zoom = max(currentZoom, 0.0001)
        let visibleW = paneSize.width / zoom
        let visibleH = paneSize.height / zoom
        let lensW = min(mapWidth, visibleW * mapScale)
        let lensH = min(mapHeight, visibleH * mapScale)
        let maxX = max(0, mapWidth - lensW)
        let maxY = max(0, mapHeight - lensH)
        let offsetX = min(max(0, viewportOriginCanvas.x * mapScale), maxX)
        let offsetY = min(max(0, viewportOriginCanvas.y * mapScale), maxY)

        return Rectangle()
            .stroke(ProShowTheme.accent, lineWidth: 1.5)
            .background(ProShowTheme.accent.opacity(0.15))
            .frame(width: lensW, height: lensH)
            .offset(x: offsetX, y: offsetY)
            .allowsHitTesting(false)
    }
}
