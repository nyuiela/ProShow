import CoreGraphics
import Foundation

struct TileFrameBounds: Identifiable, Equatable, Sendable {
    var id: Int
    var rect: CGRect
    var isLargeTopTile: Bool
}

/// Integer 16:9 frames for the MultiViewer window. Gutters stay even; leftover
/// space is a single letterbox around the whole grid, not gaps between tiles.
enum MultiViewerGridEngine {
    static let gutter: CGFloat = 6
    static let margin: CGFloat = 4
    static let aspect = DeskLayout.programAspect

    static func calculateGridFrames(
        containerSize: CGSize,
        preset: MultiViewerGrid,
        gutterPx: CGFloat = gutter,
        marginPx: CGFloat = margin
    ) -> [TileFrameBounds] {
        let available = CGSize(
            width: containerSize.width - marginPx * 2,
            height: containerSize.height - marginPx * 2
        )
        guard available.width > 80, available.height > 80 else { return [] }
        switch preset {
        case .twoByTwo:
            return uniformGrid(rows: 2, columns: 2, available: available, margin: marginPx, gutter: gutterPx)
        case .threeByThree:
            return uniformGrid(rows: 3, columns: 3, available: available, margin: marginPx, gutter: gutterPx)
        case .fourByFour:
            return uniformGrid(rows: 4, columns: 4, available: available, margin: marginPx, gutter: gutterPx)
        case .programPreviewTop:
            return programPreviewTop(available: available, margin: marginPx, gutter: gutterPx)
        }
    }

    private static func uniformGrid(
        rows: Int,
        columns: Int,
        available: CGSize,
        margin: CGFloat,
        gutter: CGFloat
    ) -> [TileFrameBounds] {
        let cellW = floor((available.width - gutter * CGFloat(columns - 1)) / CGFloat(columns))
        let cellH = floor((available.height - gutter * CGFloat(rows - 1)) / CGFloat(rows))
        let tile = fitSixteenByNine(maxWidth: cellW, maxHeight: cellH)
        let gridW = CGFloat(columns) * tile.width + gutter * CGFloat(columns - 1)
        let gridH = CGFloat(rows) * tile.height + gutter * CGFloat(rows - 1)
        let originX = margin + floor((available.width - gridW) / 2)
        let originY = margin + floor((available.height - gridH) / 2)
        var frames: [TileFrameBounds] = []
        var index = 0
        for row in 0..<rows {
            for column in 0..<columns {
                let rect = CGRect(
                    x: originX + CGFloat(column) * (tile.width + gutter),
                    y: originY + CGFloat(row) * (tile.height + gutter),
                    width: tile.width,
                    height: tile.height
                )
                frames.append(TileFrameBounds(id: index, rect: rect, isLargeTopTile: false))
                index += 1
            }
        }
        return frames
    }

    private static func programPreviewTop(
        available: CGSize,
        margin: CGFloat,
        gutter: CGFloat
    ) -> [TileFrameBounds] {
        let bottomCount = 6
        let bottomW = floor((available.width - gutter * CGFloat(bottomCount - 1)) / CGFloat(bottomCount))
        let bottom = fitSixteenByNine(maxWidth: bottomW, maxHeight: available.height * 0.42)
        let topBudgetH = floor(available.height - bottom.height - gutter)
        let topCellW = floor((available.width - gutter) / 2)
        let top = fitSixteenByNine(maxWidth: topCellW, maxHeight: topBudgetH)
        let topRowW = top.width * 2 + gutter
        let bottomRowW = bottom.width * CGFloat(bottomCount) + gutter * CGFloat(bottomCount - 1)
        let blockH = top.height + gutter + bottom.height
        let originY = margin + floor((available.height - blockH) / 2)
        let topOriginX = margin + floor((available.width - topRowW) / 2)
        let bottomOriginX = margin + floor((available.width - bottomRowW) / 2)
        var frames: [TileFrameBounds] = [
            TileFrameBounds(
                id: 0,
                rect: CGRect(x: topOriginX, y: originY, width: top.width, height: top.height),
                isLargeTopTile: true
            ),
            TileFrameBounds(
                id: 1,
                rect: CGRect(x: topOriginX + top.width + gutter, y: originY, width: top.width, height: top.height),
                isLargeTopTile: true
            ),
        ]
        let bottomY = originY + top.height + gutter
        for column in 0..<bottomCount {
            frames.append(
                TileFrameBounds(
                    id: column + 2,
                    rect: CGRect(
                        x: bottomOriginX + CGFloat(column) * (bottom.width + gutter),
                        y: bottomY,
                        width: bottom.width,
                        height: bottom.height
                    ),
                    isLargeTopTile: false
                )
            )
        }
        return frames
    }

    private static func fitSixteenByNine(maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        let width = floor(maxWidth)
        let height = floor(maxHeight)
        guard width > 1, height > 1 else { return .zero }
        if width / height > aspect {
            let fittedWidth = floor(height * aspect)
            return CGSize(width: fittedWidth, height: height)
        }
        let fittedHeight = floor(width / aspect)
        return CGSize(width: width, height: fittedHeight)
    }
}
