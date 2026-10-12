import CoreGraphics
import Foundation

/// Equal tiles for the studio window. A count that divides the grid gets identical
/// cells. A short last row stretches so the tiles still fill the window.
enum StudioGlassLayout {
    static let gap: CGFloat = 10
    static let inset: CGFloat = 10

    static func columnCount(for count: Int) -> Int {
        switch count {
        case ...1: return 1
        case 2, 3: return count
        default:
            return max(1, Int(ceil(sqrt(Double(count)))))
        }
    }

    static func frames(count: Int, in size: CGSize) -> [CGRect] {
        guard count > 0, size.width > 40, size.height > 40 else { return [] }
        let columns = columnCount(for: count)
        let rows = Int(ceil(Double(count) / Double(columns)))
        let innerWidth = size.width - inset * 2
        let innerHeight = size.height - inset * 2
        let rowGap = gap * CGFloat(max(0, rows - 1))
        let rowHeight = (innerHeight - rowGap) / CGFloat(rows)
        guard rowHeight > 1, innerWidth > 1 else { return [] }

        var frames: [CGRect] = []
        var index = 0
        for row in 0..<rows {
            let rowCount = min(columns, count - index)
            let columnGap = gap * CGFloat(max(0, rowCount - 1))
            let cellWidth = (innerWidth - columnGap) / CGFloat(rowCount)
            let y = inset + CGFloat(row) * (rowHeight + gap)
            for column in 0..<rowCount {
                let x = inset + CGFloat(column) * (cellWidth + gap)
                frames.append(CGRect(x: x, y: y, width: cellWidth, height: rowHeight))
                index += 1
            }
        }
        return frames
    }
}

/// Current and next slide pictures. Each video stays 16:9. Labels and the
/// side-by-side or stacked arrangement give up space so both pictures still fit.
struct StudioSlidePairLayout: Equatable, Sendable {
    var sideBySide: Bool
    var videoSize: CGSize

    static let videoAspect: CGFloat = 16.0 / 9.0
    static let horizontalInset: CGFloat = 16
    static let playlistChrome: CGFloat = 28
    static let cardChrome: CGFloat = 40
    static let pairGap: CGFloat = 8
    static let bottomInset: CGFloat = 10

    static func layout(in size: CGSize) -> StudioSlidePairLayout {
        let side = fitted(sideBySide: true, in: size)
        let stack = fitted(sideBySide: false, in: size)
        let sideArea = side.videoSize.width * side.videoSize.height
        let stackArea = stack.videoSize.width * stack.videoSize.height
        return sideArea >= stackArea ? side : stack
    }

    private static func fitted(sideBySide: Bool, in size: CGSize) -> StudioSlidePairLayout {
        let innerWidth = max(0, size.width - horizontalInset)
        let innerHeight = max(0, size.height)
        let chrome = playlistChrome + bottomInset + (sideBySide ? cardChrome : cardChrome * 2 + pairGap)
        let videoBudget = max(0, innerHeight - chrome)

        if sideBySide {
            let maxCellWidth = max(0, (innerWidth - pairGap) / 2)
            var videoWidth = min(maxCellWidth, videoBudget * videoAspect)
            var videoHeight = videoWidth / videoAspect
            if videoHeight > videoBudget {
                videoHeight = videoBudget
                videoWidth = videoHeight * videoAspect
            }
            return StudioSlidePairLayout(
                sideBySide: true,
                videoSize: CGSize(width: max(0, floor(videoWidth)), height: max(0, floor(videoHeight)))
            )
        }

        let maxWidth = innerWidth
        let slotHeight = max(0, (videoBudget - pairGap) / 2)
        var videoHeight = min(slotHeight, maxWidth / videoAspect)
        var videoWidth = videoHeight * videoAspect
        if videoWidth > maxWidth {
            videoWidth = maxWidth
            videoHeight = videoWidth / videoAspect
        }
        return StudioSlidePairLayout(
            sideBySide: false,
            videoSize: CGSize(width: max(0, floor(videoWidth)), height: max(0, floor(videoHeight)))
        )
    }
}

/// Live picture stays 16:9. Wide tiles put layers beside it. Tall tiles stack layers under it.
struct StudioLiveLayout: Equatable, Sendable {
    var sideBySide: Bool
    /// The 16:9 audience picture, not including the Audience label.
    var videoSize: CGSize
    /// Picture plus the Audience label.
    var previewHeight: CGFloat
    var layersWidth: CGFloat

    static let videoAspect: CGFloat = 16.0 / 9.0
    static let horizontalInset: CGFloat = 16
    static let labelChrome: CGFloat = 28
    static let layersColumnMin: CGFloat = 148
    static let layersStackedMin: CGFloat = 120
    static let gap: CGFloat = 8

    static func layout(in size: CGSize) -> StudioLiveLayout {
        let innerWidth = max(0, size.width - horizontalInset)
        let height = max(0, size.height)
        let pictureMaxHeight = max(0, height - labelChrome)
        let side = fittedSideBySide(innerWidth: innerWidth, pictureMaxHeight: pictureMaxHeight)
        let stack = fittedStack(innerWidth: innerWidth, height: height, pictureMaxHeight: pictureMaxHeight)
        let sideArea = side.videoSize.width * side.videoSize.height
        let stackArea = stack.videoSize.width * stack.videoSize.height
        let sideFits = side.layersWidth >= layersColumnMin
            && side.videoSize.width >= 96
            && side.videoSize.height >= 54
        if sideFits, sideArea >= stackArea * 0.9 {
            return side
        }
        return stack
    }

    /// Largest 16:9 picture that still leaves a layers column. Wide tiles keep the picture full height.
    private static func fittedSideBySide(innerWidth: CGFloat, pictureMaxHeight: CGFloat) -> StudioLiveLayout {
        let maxVideoWidth = max(0, innerWidth - layersColumnMin - gap)
        var videoHeight = pictureMaxHeight
        var videoWidth = floor(videoHeight * videoAspect)
        if videoWidth > maxVideoWidth {
            videoWidth = floor(maxVideoWidth)
            videoHeight = videoWidth / videoAspect
        }
        let layersWidth = max(0, floor(innerWidth - videoWidth - gap))
        return StudioLiveLayout(
            sideBySide: true,
            videoSize: CGSize(width: max(0, videoWidth), height: max(0, videoHeight)),
            previewHeight: videoHeight + labelChrome,
            layersWidth: layersWidth
        )
    }

    /// Largest 16:9 picture that still leaves a layers band under it. The band shrinks with the tile.
    private static func fittedStack(innerWidth: CGFloat, height: CGFloat, pictureMaxHeight: CGFloat) -> StudioLiveLayout {
        let band = min(layersStackedMin, max(44, height * 0.22))
        let heightBudget = max(0, height - labelChrome - band)
        let naturalHeight = innerWidth / videoAspect
        var videoHeight = min(naturalHeight, pictureMaxHeight, heightBudget)
        var videoWidth = videoHeight * videoAspect
        if videoWidth > innerWidth {
            videoWidth = innerWidth
            videoHeight = videoWidth / videoAspect
        }
        return StudioLiveLayout(
            sideBySide: false,
            videoSize: CGSize(width: max(0, floor(videoWidth)), height: max(0, videoHeight)),
            previewHeight: videoHeight + labelChrome,
            layersWidth: innerWidth
        )
    }
}
