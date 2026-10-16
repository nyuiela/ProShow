import Foundation

/// Broadcast / news template pack. Every recipe is built from editable canvas objects
/// (shapes, text, video input frames), never flat images, so operators and AI compose can restyle them.
/// Coordinates are authored at 3840x2160 and scaled to the project resolution.
enum BroadcastTemplatePack {
    static let groupName = "Broadcast Pack"

    enum Recipe: String, CaseIterable, Identifiable {
        case rollup, bloomberg, guestMosaic2, guestMosaic3, guestMosaic5, camSlide, milkRoad
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rollup: "Rollup Lower Third"
            case .bloomberg: "Bloomberg Nameplate"
            case .guestMosaic2: "Guests 2-Up"
            case .guestMosaic3: "Guests 3-Up"
            case .guestMosaic5: "Guests 5-Up"
            case .camSlide: "Cam + Slide"
            case .milkRoad: "Milk Road 3 Column"
            }
        }
    }

    static func slides(width: Double, height: Double) -> [Slide] {
        Recipe.allCases.map { slide(for: $0, width: width, height: height) }
    }

    static func slide(for recipe: Recipe, width: Double = 3840, height: Double = 2160) -> Slide {
        var b = Builder(sx: width / 3840, sy: height / 2160)
        switch recipe {
        case .rollup: b.rollup()
        case .bloomberg: b.bloomberg()
        case .guestMosaic2: b.mosaic(count: 2)
        case .guestMosaic3: b.mosaic(count: 3)
        case .guestMosaic5: b.mosaic(count: 5)
        case .camSlide: b.camSlide()
        case .milkRoad: b.milkRoad()
        }
        return Slide(
            title: recipe.title,
            canvas: b.objects,
            themeApplication: .native,
            label: "Template",
            backgroundEnabled: false
        )
    }

    struct Builder {
        let sx: Double
        let sy: Double
        var objects: [CanvasObject] = []

        private func bounds(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CanvasBounds {
            CanvasBounds(x: x * sx, y: y * sy, width: w * sx, height: h * sy)
        }

        mutating func rect(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                           fill: String, radius: Double = 0, border: String? = nil, borderWidth: Double = 6) {
            var o = CanvasObject(name: name, kind: radius > 0 ? .roundedRectangle : .rectangle,
                                 bounds: bounds(x, y, w, h), zIndex: objects.count, fillHex: fill)
            o.stroke.cornerRadius = radius * sx
            if let border {
                o.stroke.style = .solid
                o.stroke.color = border
                o.stroke.width = borderWidth * sx
                o.stroke.position = .inside
            }
            objects.append(o)
        }

        mutating func text(_ name: String, _ value: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                           size: Double, color: String = "#FFFFFF", weight: FontWeightToken = .bold,
                           align: TextHorizontalAlign = .left) {
            var o = CanvasObject(name: name, kind: .text, bounds: bounds(x, y, w, h), zIndex: objects.count,
                                 text: value, fillHex: "#000000", fontSize: size * sy, fontColor: color)
            o.fill.type = .none
            o.typography.fontWeight = weight
            o.typography.isBold = weight == .bold || weight == .black
            o.textLayout.horizontalAlign = align
            o.textLayout.verticalAlign = .middle
            o.textLayout.margins = TextBoxMargins(top: 0, bottom: 0, left: 0, right: 0)
            objects.append(o)
        }

        /// Transparent float: no plate behind the video, just an optional thin chrome border.
        mutating func float(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                            border: String? = nil, width bw: Double = 6) {
            var o = CanvasObject(name: name, kind: .videoInput, bounds: bounds(x, y, w, h), zIndex: objects.count)
            o.fill.type = .none
            if let border {
                o.stroke.style = .solid
                o.stroke.color = border
                o.stroke.width = bw * sx
                o.stroke.position = .inside
            }
            objects.append(o)
        }

        // 1) Rollup: LIVE FROM strip, logo + NEXT lower third, PARTNERS ticker.
        mutating func rollup() {
            float("Program Cam", 0, 0, 3840, 2160)
            rect("Live From Strip", 120, 110, 900, 110, fill: "#121214")
            rect("Live Dot", 150, 145, 40, 40, fill: "#C6FF3D", radius: 20)
            text("Live From", "LIVE FROM TOKEN2049", 215, 110, 800, 110, size: 52)
            rect("Lower Third Plate", 120, 1560, 2400, 280, fill: "#121214")
            rect("Logo Block", 120, 1560, 280, 280, fill: "#C6FF3D")
            text("Logo", "ROLLUP", 120, 1560, 280, 280, size: 60, color: "#121214", weight: .black, align: .center)
            text("Next Label", "NEXT", 450, 1585, 300, 90, size: 48, color: "#C6FF3D")
            text("Headline", "The state of onchain payments", 450, 1665, 2000, 110, size: 88)
            rect("Subtitle Bar", 400, 1840, 1500, 90, fill: "#FFFFFF")
            text("Subtitle", "With guests from Morapay and friends", 440, 1840, 1440, 90, size: 46, color: "#121214", weight: .semibold)
            rect("Ticker Bar", 0, 2010, 3840, 150, fill: "#FFFFFF")
            rect("Partners Tag", 0, 2010, 420, 150, fill: "#C6FF3D")
            text("Partners", "PARTNERS", 0, 2010, 420, 150, size: 52, color: "#121214", weight: .black, align: .center)
            text("Partner Names", "Morapay  ·  Base  ·  Coinbase  ·  Circle  ·  Solana", 480, 2010, 3300, 150, size: 56, color: "#121214", weight: .semibold)
        }

        // 2) Bloomberg: LIVE + location, caption pill, yellow nameplate, headline banner.
        mutating func bloomberg() {
            float("Program Cam", 0, 0, 3840, 2160)
            rect("Live Tag", 120, 120, 220, 100, fill: "#E5322D")
            text("Live", "LIVE", 120, 120, 220, 100, size: 56, align: .center)
            text("Location", "SINGAPORE", 370, 120, 900, 100, size: 56)
            rect("Caption Pill", 120, 1380, 900, 100, fill: "#121214", radius: 50)
            text("Caption", "Fintech Summit", 160, 1380, 820, 100, size: 48, align: .center)
            rect("Nameplate", 120, 1500, 2100, 220, fill: "#121214", border: "#F5C518", borderWidth: 10)
            text("Name", "Kaleel", 180, 1515, 2000, 110, size: 84)
            text("Role", "Founder, Morapay", 180, 1615, 2000, 90, size: 52, color: "#F5C518", weight: .semibold)
            rect("Headline Banner", 0, 1780, 3840, 200, fill: "#F5C518")
            text("Headline", "STABLECOIN RAILS GO MAINSTREAM IN AFRICA", 120, 1780, 3600, 200, size: 90, color: "#121214", weight: .black)
        }

        // 3) Multi-guest mosaic: patterned bg, top logos, panes with thin blue borders + handles.
        mutating func mosaic(count: Int) {
            rect("Background", 0, 0, 3840, 2160, fill: "#121214")
            for i in 0..<16 {
                rect("Pattern \(i + 1)", Double(i) * 260 - 200, 0, 60, 2160, fill: "#1A1C22")
            }
            text("Logo Left", "MORAPAY", 120, 60, 1000, 140, size: 64, weight: .black)
            text("Logo Right", "PROSHOW LIVE", 2720, 60, 1000, 140, size: 64, weight: .black, align: .right)
            let top = 260.0, margin = 120.0, gap = 40.0
            var panes: [(Double, Double, Double, Double)] = []
            switch count {
            case 2:
                let w = (3840 - margin * 2 - gap) / 2, h = w * 9 / 16
                for i in 0..<2 { panes.append((margin + Double(i) * (w + gap), top + 200, w, h)) }
            case 3:
                let w = (3840 - margin * 2 - gap * 2) / 3, h = w * 9 / 16
                for i in 0..<3 { panes.append((margin + Double(i) * (w + gap), top + 420, w, h)) }
            default:
                let bigW = (3840 - margin * 2 - gap) / 2, bigH = 900.0
                for i in 0..<2 { panes.append((margin + Double(i) * (bigW + gap), top, bigW, bigH)) }
                let w = (3840 - margin * 2 - gap * 2) / 3, h = 2160 - top - bigH - gap - 120
                for i in 0..<3 { panes.append((margin + Double(i) * (w + gap), top + bigH + gap, w, h)) }
            }
            for (i, p) in panes.enumerated() {
                float("Guest \(i + 1)", p.0, p.1, p.2, p.3, border: "#6B9FE0", width: 4)
                rect("Handle Plate \(i + 1)", p.0 + 24, p.1 + p.3 - 104, 560, 80, fill: "#121214", radius: 12)
                text("Handle \(i + 1)", "@guest\(i + 1)", p.0 + 48, p.1 + p.3 - 104, 520, 80, size: 44)
            }
        }

        // 4) Cam + slide: about 1/3 camera, 2/3 slide, clean cut.
        mutating func camSlide() {
            rect("Background", 0, 0, 3840, 2160, fill: "#121214")
            float("Camera", 0, 0, 1280, 2160)
            float("Slide", 1280, 0, 2560, 2160)
            rect("Name Plate", 60, 1880, 1000, 120, fill: "#121214")
            text("Name", "Speaker Name", 100, 1880, 940, 120, size: 56)
        }

        // 5) Milk Road: three equal columns, yellow name bar + white title bar.
        mutating func milkRoad() {
            rect("Background", 0, 0, 3840, 2160, fill: "#121214")
            let w = 3840.0 / 3
            for i in 0..<3 {
                let x = Double(i) * w
                float("Guest \(i + 1)", x, 0, w, 2160)
                rect("Name Bar \(i + 1)", x + 60, 1700, w - 120, 120, fill: "#FFD60A")
                text("Name \(i + 1)", "Guest Name", x + 90, 1700, w - 180, 120, size: 60, color: "#121214", weight: .black)
                rect("Title Bar \(i + 1)", x + 60, 1820, w - 120, 100, fill: "#FFFFFF")
                text("Title \(i + 1)", "Title, Company", x + 90, 1820, w - 180, 100, size: 46, color: "#121214", weight: .semibold)
            }
        }
    }
}

extension ShowController {
    /// Show > Add Broadcast Template Pack. Appends one slide per recipe as editable canvas objects.
    func addBroadcastTemplatePack() {
        rehydrateFromEditor(persist: false)
        let res = projectSettings.resolution
        let slides = BroadcastTemplatePack.slides(width: Double(res.width), height: Double(res.height))
        var name = BroadcastTemplatePack.groupName
        var n = 2
        while show.groups.contains(where: { $0.name == name }) {
            name = "\(BroadcastTemplatePack.groupName) \(n)"
            n += 1
        }
        appendSlides(slides, toGroupNamed: name, colorHex: "#6B9FE0")
        selectedSlideID = slides.first?.id
        editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
        rebuildSearchIndex()
    }
}
