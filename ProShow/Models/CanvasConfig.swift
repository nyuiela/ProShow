import Foundation

/// Per-project canvas metrics. Static 4K defaults remain for seed data and legacy tests.
struct CanvasConfig: Hashable, Sendable {
    var width: Double
    var height: Double
    var majorTick: Double
    var minorTick: Double
    var gridStep: Double
    var lyricFontSize: Double
    var sermonHeaderSize: Double
    var sermonBodySize: Double

    static let width: Double = 3840
    static let height: Double = 2160
    static let majorTick: Double = 500
    static let minorTick: Double = 100
    static let gridStep: Double = 100
    static let lyricFontSize: Double = 96
    static let sermonHeaderSize: Double = 120
    static let sermonBodySize: Double = 80

    static let native4K = CanvasConfig(
        width: 3840,
        height: 2160,
        majorTick: 500,
        minorTick: 100,
        gridStep: 100,
        lyricFontSize: 96,
        sermonHeaderSize: 120,
        sermonBodySize: 80
    )

    static var size: (width: Double, height: Double) { (width, height) }

    static func outputScale(displayWidth: Double) -> Double {
        displayWidth / width
    }

    static var scale1080: Double { 1920 / width }

    static func canvasX(_ normalized: Double) -> Double { normalized * width }
    static func canvasY(_ normalized: Double) -> Double { normalized * height }

    static func metrics(for resolution: DisplayResolution) -> CanvasConfig {
        metrics(width: Double(resolution.width), height: Double(resolution.height))
    }

    static func metrics(width: Double, height: Double) -> CanvasConfig {
        let ticks = ticks(width: width, height: height)
        let scale = width / 3840
        return CanvasConfig(
            width: width,
            height: height,
            majorTick: ticks.major,
            minorTick: ticks.minor,
            gridStep: ticks.grid,
            lyricFontSize: 96 * max(scale, 0.35),
            sermonHeaderSize: 120 * max(scale, 0.35),
            sermonBodySize: 80 * max(scale, 0.35)
        )
    }

    static func ticks(width: Double, height: Double) -> (major: Double, minor: Double, grid: Double) {
        if width >= 3200 || height >= 3200 {
            return (500, 100, 100)
        }
        if width >= 1600 || height >= 1600 {
            return (200, 50, 50)
        }
        return (100, 25, 25)
    }

    static func scaleFactor(from old: DisplayResolution, to new: DisplayResolution) -> Double {
        Double(new.width) / Double(max(old.width, 1))
    }
}

enum CanvasRescaleEngine {
    static func rescale(_ object: CanvasObject, by scale: Double) -> CanvasObject {
        guard scale != 1 else { return object }
        var next = object
        next.bounds = CanvasBounds(
            x: object.bounds.x * scale,
            y: object.bounds.y * scale,
            width: object.bounds.width * scale,
            height: object.bounds.height * scale
        )
        next.typography.fontSize = object.typography.fontSize * scale
        next.stroke.width = object.stroke.width * scale
        next.textOutline.width = object.textOutline.width * scale
        return next
    }

    static func rescale(_ objects: [CanvasObject], by scale: Double) -> [CanvasObject] {
        objects.map { rescale($0, by: scale) }
    }

    static func rescale(_ rect: CanvasRect, by scale: Double) -> CanvasRect {
        CanvasRect(x: rect.x * scale, y: rect.y * scale, width: rect.width * scale, height: rect.height * scale)
    }

    static func rescale(_ show: Show, by scale: Double) -> Show {
        guard scale != 1 else { return show }
        var next = show
        next.groups = show.groups.map { group in
            var group = group
            group.slides = group.slides.map { slide in
                var slide = slide
                slide.canvas = rescale(slide.canvas, by: scale)
                return slide
            }
            return group
        }
        return next
    }
}
