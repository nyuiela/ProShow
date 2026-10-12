import SwiftUI

private typealias ViewStrokeStyle = SwiftUI.StrokeStyle

/// Broadcast safe areas, header/footer zones, and column layout grid (document-space, scales with zoom).
struct BroadcastFrameGuideView: View {
    var documentSize: CGSize
    var scale: CGFloat
    var showSafeAreas: Bool
    var showHeaderFooterGuides: Bool
    var showColumnGrid: Bool

    private let columnCount = 12
    private let columnGutter: CGFloat = 16
    private let columnMargin: CGFloat = 80

    private var metrics: CanvasConfig {
        CanvasConfig.metrics(width: Double(documentSize.width), height: Double(documentSize.height))
    }

    /// Document-space header band (matches sermon header typography zone).
    private var headerDocument: CGFloat {
        CGFloat(metrics.sermonHeaderSize)
    }

    /// Document-space footer band, scaled with canvas height like header metrics.
    private var footerDocument: CGFloat {
        let heightScale = documentSize.height / max(CanvasConfig.height, 1)
        return CGFloat(140 * max(heightScale, 0.35))
    }

    private var viewWidth: CGFloat { documentSize.width * scale }
    private var viewHeight: CGFloat { documentSize.height * scale }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showHeaderFooterGuides {
                headerFooterBands
                headerFooterLines
            }

            if showSafeAreas {
                safeAreaGuides
            }

            if showColumnGrid {
                columnGrid
                    .accessibilityLabel("Twelve column layout grid")
            }
        }
        .frame(width: viewWidth, height: viewHeight, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(!showSafeAreas && !showHeaderFooterGuides && !showColumnGrid)
    }

    private var headerFooterBands: some View {
        let headerY = headerDocument * scale
        let footerY = viewHeight - footerDocument * scale
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(red: 0.35, green: 0.55, blue: 0.95).opacity(0.07))
                .frame(width: viewWidth, height: max(0, headerY))
            Rectangle()
                .fill(Color(red: 0.72, green: 0.45, blue: 0.95).opacity(0.07))
                .frame(width: viewWidth, height: max(0, viewHeight - footerY))
                .offset(y: footerY)
        }
        .accessibilityHidden(true)
    }

    private var headerFooterLines: some View {
        let headerY = headerDocument * scale
        let footerY = viewHeight - footerDocument * scale
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: headerY))
                path.addLine(to: CGPoint(x: viewWidth, y: headerY))
            }
            .stroke(
                Color(red: 0.45, green: 0.72, blue: 1).opacity(0.72),
                style: ViewStrokeStyle(lineWidth: 1.5, dash: [10, 5])
            )

            Path { path in
                path.move(to: CGPoint(x: 0, y: footerY))
                path.addLine(to: CGPoint(x: viewWidth, y: footerY))
            }
            .stroke(
                Color(red: 0.78, green: 0.52, blue: 1).opacity(0.72),
                style: ViewStrokeStyle(lineWidth: 1.5, dash: [10, 5])
            )

            guideLabel("HEADER", at: CGPoint(x: 8, y: 6))
            guideLabel("FOOTER", at: CGPoint(x: 8, y: footerY + 6))
        }
        .accessibilityLabel("Header and footer safe zones")
    }

    private func guideLabel(_ text: String, at point: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.55))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.35), in: Capsule(style: .continuous))
            .offset(x: point.x, y: point.y)
    }

    private var safeAreaGuides: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(
                    Color.green.opacity(0.55),
                    style: ViewStrokeStyle(lineWidth: 1.25, dash: [5, 4])
                )
                .frame(width: viewWidth * 0.93, height: viewHeight * 0.93)
                .accessibilityLabel("Action safe 93 percent")

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(
                    Color(red: 1, green: 0.82, blue: 0.2).opacity(0.5),
                    style: ViewStrokeStyle(lineWidth: 1.25, dash: [7, 5])
                )
                .frame(width: viewWidth * 0.90, height: viewHeight * 0.90)
                .accessibilityLabel("Title safe 90 percent")

            Path { path in
                let midX = viewWidth / 2
                let midY = viewHeight / 2
                path.move(to: CGPoint(x: midX - 14, y: midY))
                path.addLine(to: CGPoint(x: midX + 14, y: midY))
                path.move(to: CGPoint(x: midX, y: midY - 14))
                path.addLine(to: CGPoint(x: midX, y: midY + 14))
            }
            .stroke(Color.cyan.opacity(0.45), lineWidth: 1)
        }
    }

    private var columnGrid: some View {
        GeometryReader { geo in
            let innerWidth = max(0, geo.size.width - columnMargin * scale * 2)
            let gutter = columnGutter * scale
            let margin = columnMargin * scale
            let columnWidth = max(
                0,
                (innerWidth - gutter * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            )
            HStack(spacing: gutter) {
                ForEach(0..<columnCount, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.red.opacity(0.05))
                        .overlay(Rectangle().stroke(Color.red.opacity(0.16), lineWidth: 0.5))
                        .frame(width: columnWidth)
                }
            }
            .padding(.horizontal, margin)
        }
    }
}
