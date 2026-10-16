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
        // Canvas objects live in the fixed design space (3840x2160), not the output resolution.
        // Building at a 1920x1080 project size put every template in the top-left quarter at half-size type.
        let slides = BroadcastTemplatePack.slides(width: CanvasConfig.width, height: CanvasConfig.height)
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

// MARK: - Agent templates (catalog + instantiate, Stream 16:9 and Phone 9:16)

/// Starting points for the design agent. Every template is editable canvas objects;
/// the agent fills slots, restyles, removes or adds elements, then stages through validate/apply_preview.
#if canImport(AppKit)
import AppKit
#endif

/// Installed font families for the agent, with coarse categories.
enum AgentFonts {
    static func families() -> [String] { NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") } }

    static func resolve(_ family: String) -> String {
        let all = families()
        if all.contains(family) { return family }
        if let ci = all.first(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) { return ci }
        return all.contains("Inter") ? "Inter" : "Helvetica Neue"
    }

    static func category(_ family: String) -> String {
        let lower = family.lowercased()
        guard let font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return "unknown" }
        let traits = font.fontDescriptor.symbolicTraits
        if traits.contains(.monoSpace) || lower.contains("mono") || lower.contains("courier") || lower.contains("code") { return "mono" }
        if traits.contains(.condensed) || lower.contains("condensed") || lower.contains("narrow") || lower.contains("compressed") { return "condensed" }
        let cls = traits.rawValue & 0xF000_0000 // NSFontFamilyClassMask
        switch cls >> 28 {
        case 1, 2, 3, 4, 5, 7: return "serif"
        case 8: return "sans"
        case 9: return "display"
        case 10: return "script"
        case 12: return "symbol"
        default: break
        }
        if ["display", "black", "poster", "impact", "rounded", "stencil", "headline"].contains(where: lower.contains) { return "display" }
        if ["serif", "times", "georgia", "garamond", "baskerville", "didot", "bodoni", "caslon", "palatino", "charter", "new york", "rockwell", "cochin", "hoefler"].contains(where: lower.contains) && !lower.contains("sans") { return "serif" }
        return "sans"
    }

    static func catalog() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for f in families() { out[category(f), default: []].append(f) }
        out.removeValue(forKey: "symbol")
        return out.mapValues { $0.sorted() }
    }
}

enum AgentTemplateCatalog {
    struct Template {
        var id: String
        var name: String
        var description: String
        var regions: [String]
        var bestFor: String
    }

    static let all: [Template] = [
        .init(id: "title_card", name: "Title Card / Cold Open", description: "Header strip (show name + LIVE tag), accent rule, big headline, subline, host nameplate, footer ticker.", regions: ["header 0-7%", "headline 40-60%", "nameplate 75-85%", "ticker 93-100%"], bestFor: "cold open, episode title, section opener"),
        .init(id: "next_up", name: "Next Up / Agenda", description: "Header + footer, NEXT UP label, headline, 3 numbered agenda rows with accent markers and plates.", regions: ["header", "label+headline 12-26%", "rows 32-86%", "ticker"], bestFor: "agenda, run of show, next-up bar"),
        .init(id: "stat_cards", name: "Stat Cards", description: "Header + footer, headline, 3 stat cards (accent top rule, big value, label, note).", regions: ["header", "headline 12-21%", "cards 29-84%", "ticker"], bestFor: "problem/market numbers, KPIs, comparisons"),
        .init(id: "process_steps", name: "Process Steps", description: "Header + footer, headline, 4 bordered step cards joined by accent arrows.", regions: ["header", "headline", "steps 42-74%", "ticker"], bestFor: "product flow, how it works, timeline"),
        .init(id: "rollup", name: "Rollup Lower Third", description: "Full-frame camera, LIVE FROM strip, logo block + NEXT label + headline + white subtitle bar, PARTNERS ticker.", regions: ["cam full", "live-from strip top-left", "lower third 72-89%", "ticker 93-100%"], bestFor: "live interview, conference broadcast"),
        .init(id: "bloomberg", name: "Bloomberg Nameplate", description: "Full-frame camera, red LIVE tag + location, caption pill, bordered nameplate (name + role), full-width yellow headline banner.", regions: ["cam full", "live tag top-left", "nameplate 69-80%", "banner 82-92%"], bestFor: "news desk, guest intro, breaking headline"),
        .init(id: "guest_mosaic_2", name: "Guests 2-Up", description: "Patterned background, top logos, 2 bordered camera panes with handle plates.", regions: ["logos top", "2 panes"], bestFor: "interview, debate"),
        .init(id: "guest_mosaic_3", name: "Guests 3-Up", description: "Patterned background, top logos, 3 camera panes with handles.", regions: ["logos top", "3 panes"], bestFor: "panel"),
        .init(id: "guest_mosaic_5", name: "Guests 5-Up", description: "Patterned background, top logos, 2 large + 3 small camera panes with handles.", regions: ["logos top", "2+3 panes"], bestFor: "big panel, spaces-style"),
        .init(id: "cam_slide", name: "Cam + Slide", description: "1/3 camera + 2/3 slide/screen split with speaker nameplate.", regions: ["cam left 33%", "slide right 67%", "nameplate bottom-left"], bestFor: "talk with deck, demo"),
        .init(id: "milk_road", name: "Milk Road 3 Column", description: "Three full-height guest columns with yellow name bar and white title bar each.", regions: ["3 columns", "name bars 79-89%"], bestFor: "three-guest show"),
        .init(id: "blank", name: "Blank Board", description: "Background only on both canvases. Build everything with addElements.", regions: ["free"], bestFor: "fully custom layouts"),
    ]

    /// Accent colors used by the pack; `accent` overrides remap all of them.
    static let accentHexes: Set<String> = ["#C6FF3D", "#F5C518", "#FFD60A", "#6B9FE0"]
    static let k = 2160.0 / 3840.0

    static func template(_ id: String) -> Template? { all.first { $0.id == id } }

    // MARK: Stream build (3840x2160 design px)

    static func streamObjects(_ id: String) -> [CanvasObject]? {
        var b = BroadcastTemplatePack.Builder(sx: 1, sy: 1)
        switch id {
        case "rollup": b.rollup()
        case "bloomberg": b.bloomberg()
        case "guest_mosaic_2": b.mosaic(count: 2)
        case "guest_mosaic_3": b.mosaic(count: 3)
        case "guest_mosaic_5": b.mosaic(count: 5)
        case "cam_slide": b.camSlide()
        case "milk_road": b.milkRoad()
        case "title_card": b.titleCard()
        case "next_up": b.nextUp()
        case "stat_cards": b.statCards()
        case "process_steps": b.processSteps()
        case "blank": b.rect("Background", 0, 0, 3840, 2160, fill: "#121214")
        default: return nil
        }
        return b.objects
    }

    // MARK: Phone build (2160x3840 design px)

    static func phoneObjects(_ id: String, stream: [CanvasObject]) -> [CanvasObject] {
        var b = BroadcastTemplatePack.Builder(sx: 1, sy: 1)
        switch id {
        case "cam_slide":
            b.rect("Background", 0, 0, 2160, 3840, fill: "#121214")
            b.float("Camera", 0, 0, 2160, 1600)
            b.float("Slide", 0, 1640, 2160, 1215)
            b.rect("Name Plate", 80, 1420, 1300, 140, fill: "#121214")
            b.text("Name", "Speaker Name", 120, 1420, 1240, 140, size: 64)
            return carryText(from: stream, into: b.objects)
        case "milk_road":
            b.rect("Background", 0, 0, 2160, 3840, fill: "#121214")
            let h = 3840.0 / 3
            for i in 0..<3 {
                let y = Double(i) * h
                b.float("Guest \(i + 1)", 0, y, 2160, h)
                b.rect("Name Bar \(i + 1)", 80, y + h - 330, 1500, 130, fill: "#FFD60A")
                b.text("Name \(i + 1)", "Guest Name", 120, y + h - 330, 1440, 130, size: 66, color: "#121214", weight: .black)
                b.rect("Title Bar \(i + 1)", 80, y + h - 200, 1500, 110, fill: "#FFFFFF")
                b.text("Title \(i + 1)", "Title, Company", 120, y + h - 200, 1440, 110, size: 50, color: "#121214", weight: .semibold)
            }
            return carryText(from: stream, into: b.objects)
        case "title_card", "next_up", "stat_cards", "process_steps":
            b.phoneHeader()
            switch id {
            case "title_card":
                b.rect("Accent Rule", 120, 1300, 300, 12, fill: "#6B9FE0")
                b.text("Headline", "Stablecoin Rails for Africa", 120, 1340, 1920, 600, size: 150, weight: .black)
                b.text("Subline", "Morapay Live, Episode 1", 120, 1960, 1920, 140, size: 70, color: "#9AA3B2", weight: .semibold)
                b.rect("Nameplate", 120, 2700, 1920, 260, fill: "#1B1B1F", border: "#6B9FE0", borderWidth: 6)
                b.text("Host Name", "Kaleel", 180, 2715, 1800, 130, size: 80)
                b.text("Host Role", "Founder, Morapay", 180, 2840, 1800, 100, size: 54, color: "#6B9FE0", weight: .semibold)
            case "next_up":
                b.text("Section Label", "NEXT UP", 120, 320, 1500, 110, size: 60, color: "#6B9FE0", weight: .black)
                b.text("Headline", "On today's show", 120, 430, 1920, 320, size: 110, weight: .black)
                for i in 0..<3 {
                    let y = 900.0 + Double(i) * 700
                    b.rect("Item Marker \(i + 1)", 120, y, 260, 560, fill: "#6B9FE0")
                    b.text("Item Number \(i + 1)", "\(i + 1)", 120, y, 260, 560, size: 160, color: "#121214", weight: .black, align: .center)
                    b.rect("Item Plate \(i + 1)", 400, y, 1640, 560, fill: "#1B1B1F")
                    b.text("Item \(i + 1)", "Agenda item \(i + 1)", 460, y, 1540, 560, size: 88)
                }
            case "stat_cards":
                b.rect("Accent Rule", 120, 320, 300, 12, fill: "#6B9FE0")
                b.text("Headline", "Cross-border payments still take days", 120, 350, 1920, 380, size: 104, weight: .black)
                for i in 0..<3 {
                    let y = 820.0 + Double(i) * 880
                    b.rect("Card \(i + 1)", 120, y, 1920, 820, fill: "#1B1B1F", radius: 24, border: "#25252A", borderWidth: 4)
                    b.rect("Card Rule \(i + 1)", 120, y, 1920, 14, fill: "#6B9FE0")
                    b.text("Stat Value \(i + 1)", "TBD", 200, y + 60, 1760, 320, size: 220, color: "#6B9FE0", weight: .black)
                    b.text("Stat Label \(i + 1)", "Metric \(i + 1)", 200, y + 400, 1760, 160, size: 80)
                    b.text("Stat Note \(i + 1)", "Source / context", 200, y + 580, 1760, 180, size: 50, color: "#9AA3B2", weight: .medium)
                }
            default:
                b.rect("Accent Rule", 120, 320, 300, 12, fill: "#6B9FE0")
                b.text("Headline", "How Morapay works", 120, 350, 1920, 380, size: 104, weight: .black)
                for i in 0..<4 {
                    let y = 820.0 + Double(i) * 680
                    b.rect("Step Card \(i + 1)", 120, y, 1920, 600, fill: "#1B1B1F", radius: 24, border: "#6B9FE0", borderWidth: 6)
                    b.text("Step Number \(i + 1)", "0\(i + 1)", 200, y + 40, 600, 160, size: 96, color: "#6B9FE0", weight: .black)
                    b.text("Step \(i + 1)", ["Send", "Convert", "Settle", "Receive"][i], 200, y + 200, 1700, 180, size: 100)
                    b.text("Step Note \(i + 1)", "Short detail", 200, y + 390, 1700, 160, size: 50, color: "#9AA3B2", weight: .medium)
                    if i < 3 { b.text("Arrow \(i + 1)", "↓", 980, y + 590, 200, 100, size: 72, color: "#6B9FE0", align: .center) }
                }
            }
            b.phoneFooter()
            return carryText(from: stream, into: b.objects)
        case "guest_mosaic_2", "guest_mosaic_3", "guest_mosaic_5":
            let count = id == "guest_mosaic_2" ? 2 : (id == "guest_mosaic_3" ? 3 : 5)
            b.rect("Background", 0, 0, 2160, 3840, fill: "#121214")
            for i in 0..<9 { b.rect("Pattern \(i + 1)", Double(i) * 260 - 120, 0, 60, 3840, fill: "#1A1C22") }
            b.text("Logo Left", "MORAPAY", 100, 120, 1000, 140, size: 72, weight: .black)
            b.text("Logo Right", "PROSHOW LIVE", 1060, 120, 1000, 140, size: 56, weight: .black, align: .right)
            let top = 360.0, margin = 80.0, gap = 40.0, avail = 3840 - top - 240
            var panes: [(Double, Double, Double, Double)] = []
            if count <= 3 {
                let h = min(1125, (avail - gap * Double(count - 1)) / Double(count)), w = min(2000, h * 16 / 9)
                for i in 0..<count { panes.append(((2160 - w) / 2, top + Double(i) * (h + gap), w, h)) }
            } else {
                let w = (2160 - margin * 2 - gap) / 2, h = w * 9 / 16 * 1.4
                for i in 0..<count {
                    let col = Double(i % 2), row = Double(i / 2)
                    let x = i == 4 ? (2160 - w) / 2 : margin + col * (w + gap)
                    panes.append((x, top + row * (h + gap), w, h))
                }
            }
            for (i, p) in panes.enumerated() {
                b.float("Guest \(i + 1)", p.0, p.1, p.2, p.3, border: "#6B9FE0", width: 4)
                b.rect("Handle Plate \(i + 1)", p.0 + 20, p.1 + p.3 - 100, 520, 76, fill: "#121214", radius: 12)
                b.text("Handle \(i + 1)", "@guest\(i + 1)", p.0 + 40, p.1 + p.3 - 100, 480, 76, size: 42)
            }
            return carryText(from: stream, into: b.objects)
        default:
            return stream.map(mapToPhone)
        }
    }

    /// Generic Stream→Phone reflow: scale to phone width; top band pins to the top safe area,
    /// bottom band (lower thirds, tickers) pins to the bottom, middle stays centered. Full-frame stays full-frame.
    static func mapToPhone(_ source: CanvasObject) -> CanvasObject {
        var o = source
        let t = source.transform
        let full = t.width >= 3800 && t.height >= 2100
        if full {
            o.transform.x = 0; o.transform.y = 0; o.transform.width = 2160; o.transform.height = 3840
            return o
        }
        o.transform.x = t.width >= 3800 ? 0 : t.x * k
        o.transform.width = t.width >= 3800 ? 2160 : t.width * k
        o.transform.height = t.height * k
        let cy = t.y + t.height / 2
        if cy < 2160 * 0.36 {
            o.transform.y = 220 + t.y * k
        } else if cy > 2160 * 0.64 {
            o.transform.y = 3840 - 260 - (2160 - t.y) * k
        } else {
            o.transform.y = 1920 + (t.y - 1080) * k
        }
        if t.width >= 3800, t.y <= 1, t.height < 400 { o.transform.y = 0 } // header strips hug the top
        if t.width >= 3800, t.y + t.height >= 2155 { o.transform.y = 3840 - o.transform.height } // footers hug bottom
        o.typography.fontSize = source.typography.fontSize * k * 1.15
        o.stroke.width = source.stroke.width * k
        o.stroke.cornerRadius = source.stroke.cornerRadius * k
        return o
    }

    /// Keep slot text edits made on Stream when Phone uses its own layout.
    private static func carryText(from stream: [CanvasObject], into phone: [CanvasObject]) -> [CanvasObject] {
        let texts = Dictionary(stream.filter { $0.kind == .text }.map { ($0.name, $0.text) }, uniquingKeysWith: { a, _ in a })
        return phone.map { o in
            var c = o
            if c.kind == .text, let v = texts[c.name] { c.text = v }
            return c
        }
    }

    static func slots(_ id: String) -> [[String: String]] {
        (streamObjects(id) ?? []).filter { $0.kind == .text }.map { ["slot": $0.name, "default": $0.text] }
    }

    static var compactSummary: String {
        all.map { "\($0.id): \($0.bestFor)" }.joined(separator: "; ")
    }

    // MARK: Instantiate

    enum InstantiateError: Error { case unknownTemplate(String) }

    /// addElements in any shape models send: array of objects, a JSON string of one, or common aliases.
    static func addElementList(_ args: [String: Any]) -> [[String: Any]] {
        for key in ["addElements", "add_elements", "elements", "add", "addElement"] {
            guard let value = args[key] else { continue }
            if let list = value as? [[String: Any]] { return list }
            if let one = value as? [String: Any] { return [one] }
            if let list = value as? [Any] { return list.compactMap { item in
                if let d = item as? [String: Any] { return d }
                if let s = item as? String, let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { return d }
                return nil
            } }
            if let s = value as? String, let parsed = try? JSONSerialization.jsonObject(with: Data(s.utf8)) {
                if let list = parsed as? [[String: Any]] { return list }
                if let one = parsed as? [String: Any] { return [one] }
            }
        }
        return []
    }

    /// Builds a dual-canvas Slide (Stream objects on the slide, Phone objects on the phone board).
    @MainActor
    static func instantiate(_ id: String, args: [String: Any]) throws -> (Slide, [String]) {
        guard var stream = streamObjects(id) else { throw InstantiateError.unknownTemplate(id) }
        var notes: [String] = []
        let slots = (args["slots"] as? [String: Any]) ?? [:]
        let style = (args["style"] as? [String: Any]) ?? [:]
        let edits = (args["edits"] as? [String: [String: Any]]) ?? [:]
        let remove = Set(((args["remove"] as? [String]) ?? []).map { $0.lowercased() })
        let adds = addElementList(args)
        let streamOnly = (args["streamOnly"] as? Bool) == true

        func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "_", with: " ") }
        var matched = Set<String>()
        func applySlotsAndEdits(_ objects: inout [CanvasObject], phone: Bool) {
            objects.removeAll { remove.contains($0.name.lowercased()) }
            for i in objects.indices {
                let key = norm(objects[i].name)
                if objects[i].kind == .text, let (name, v) = slots.first(where: { norm($0.key) == key }) {
                    objects[i].text = "\(v)"; matched.insert(name)
                }
                if let (name, e) = edits.first(where: { norm($0.key) == key }) {
                    matched.insert(name)
                    if let v = e["text"] as? String { objects[i].text = v }
                    if let v = e["color"] as? String { objects[i].typography.color = v }
                    if let v = e["fill"] as? String { objects[i].fill.type = .color; objects[i].fill.color = v }
                    if let v = (e["fontSize"] as? NSNumber)?.doubleValue { objects[i].typography.fontSize = phone ? v * k * 1.15 : v }
                    if let v = (e["opacity"] as? NSNumber)?.doubleValue { objects[i].opacity = v }
                    if !phone, let f = e["frame"] as? [String: Any] {
                        let W = 3840.0, H = 2160.0
                        if let x = (f["x"] as? NSNumber)?.doubleValue { objects[i].transform.x = x * W }
                        if let y = (f["y"] as? NSNumber)?.doubleValue { objects[i].transform.y = y * H }
                        if let w = (f["w"] as? NSNumber)?.doubleValue { objects[i].transform.width = w * W }
                        if let h = (f["h"] as? NSNumber)?.doubleValue { objects[i].transform.height = h * H }
                    }
                }
            }
        }
        func restyle(_ objects: inout [CanvasObject]) {
            let accent = (style["accent"] as? String)?.uppercased()
            let bg = (style["background"] as? String)?.uppercased()
            let textColor = (style["text"] as? String)?.uppercased()
            func swap(_ hex: String) -> String {
                let u = hex.uppercased()
                if let accent, accentHexes.contains(u) { return accent }
                if let bg, u == "#121214" { return bg }
                return hex
            }
            for i in objects.indices {
                objects[i].fill.color = swap(objects[i].fill.color)
                objects[i].stroke.color = swap(objects[i].stroke.color)
                objects[i].typography.color = swap(objects[i].typography.color)
                if let textColor, objects[i].kind == .text, objects[i].typography.color.uppercased() == "#FFFFFF" {
                    objects[i].typography.color = textColor
                }
            }
        }
        // Free-form additions (fractions of the Stream board; Phone gets the reflowed copy unless `phone` frame given).
        var b = BroadcastTemplatePack.Builder(sx: 1, sy: 1)
        var phoneAdds: [CanvasObject] = []
        // Models often size type for a 1280/1920 board or in points (headline 48, body 32). The board is 3840x2160,
        // so when every given size in the call is small, scale the whole call up by 3.
        let givenSizes = adds.compactMap { a -> Double? in
            let v = a["fontSize"] ?? a["size"]
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s.trimmingCharacters(in: CharacterSet(charactersIn: " px"))) }
            return nil
        }
        let legacySizing = ScriptedAgentProvider.configured != nil && UserDefaults.standard.bool(forKey: "proshow.ai.mockLegacySizing")
        let sizeScale: Double = !legacySizing && (givenSizes.max() ?? 999) <= 100 ? 3 : 1
        if sizeScale != 1 { notes.append("font_scale_x3: fontSize values (max \(Int(givenSizes.max() ?? 0))) looked like 1280px/pt units; the board is 3840x2160 px, so they were tripled. Use headline 140-200, body 56-72, label 36-48.") }
        func roleSize(_ add: [String: Any]) -> Double {
            let key = ((add["role"] as? String ?? "") + " " + (add["name"] as? String ?? "") + " " + (add["kind"] as? String ?? "")).lowercased()
            if ["headline", "title", "hero", "big", "value", "stat"].contains(where: key.contains) { return 160 }
            if ["label", "tag", "kicker", "eyebrow", "handle", "date", "source", "small"].contains(where: key.contains) { return 40 }
            if ["caption", "subtitle", "footer", "channel"].contains(where: key.contains) { return 56 }
            return 64
        }
        for rawAdd in adds {
            // Accept a nested frame/bounds object as well as flat x,y,w,h.
            var add = rawAdd
            if let f = (add["frame"] ?? add["bounds"] ?? add["rect"]) as? [String: Any] { for (k, v) in f where add[k] == nil { add[k] = v } }
            if add["w"] == nil, let v = add["width"] { add["w"] = v }
            if add["h"] == nil, let v = add["height"] { add["h"] = v }
            func num(_ v: Any?) -> Double? {
                if let n = v as? NSNumber { return n.doubleValue }
                if let s = v as? String { return Double(s.trimmingCharacters(in: CharacterSet(charactersIn: " px%"))) }
                return nil
            }
            // Fractions 0-1; values > 1 are treated as pixels of the board (W x H).
            func frac(_ key: String, _ src: [String: Any], _ full: Double) -> Double {
                guard let v = num(src[key]) else { return 0 }
                return v > 1.0001 ? v / full : v
            }
            func d(_ key: String, _ src: [String: Any] = add) -> Double { num(src[key]) ?? 0 }
            let kind = (add["kind"] as? String ?? add["type"] as? String ?? "text").lowercased().replacingOccurrences(of: "-", with: "_")
            let name = add["name"] as? String ?? "Element \(b.objects.count + 1)"
            let x = frac("x", add, 3840) * 3840, y = frac("y", add, 2160) * 2160
            let w = max(0.01, frac("w", add, 3840)) * 3840, h = max(0.01, frac("h", add, 2160)) * 2160
            let fill = (add["fill"] ?? add["fillColor"] ?? add["background"]) as? String ?? "#1B1B1F"
            // No color given: pick white or near-black against whatever sits behind the text box.
            let color: String = ((add["color"] ?? add["textColor"]) as? String) ?? {
                let c = CGPoint(x: x + w / 2, y: y + h / 2)
                let behind = b.objects.last { $0.kind != .text && $0.fill.type != .none &&
                    CGRect(x: $0.transform.x, y: $0.transform.y, width: $0.transform.width, height: $0.transform.height).contains(c) }?.fill.color
                    ?? (style["background"] as? String) ?? "#121214"
                return (AgentDesignLint.luminance(behind) ?? 0) > 0.4 ? "#111114" : "#FFFFFF"
            }()
            // Given size (scaled if the call used small units) or a role default; never taller than its box.
            var size = (num(add["fontSize"] ?? add["size"]).map { $0 * sizeScale }) ?? roleSize(add)
            let lines = max(1, Double(("\(add["text"] ?? "")").components(separatedBy: "\n").count))
            if !legacySizing { size = max(40, min(size, h / lines * 0.85)) }
            let weight = FontWeightToken(rawValue: (add["weight"] as? String ?? "bold").lowercased()) ?? .bold
            let align = TextHorizontalAlign(rawValue: (add["align"] as? String ?? "left").lowercased()) ?? .left
            let radius = num(add["cornerRadius"] ?? add["radius"]) ?? 0
            var borderColor = (add["borderColor"] ?? add["strokeColor"]) as? String
            var borderWidth = num(add["borderWidth"] ?? add["strokeWidth"])
            if let border = add["border"] as? [String: Any] {
                borderColor = borderColor ?? (border["color"] as? String)
                borderWidth = borderWidth ?? num(border["width"])
            } else if let s = add["border"] as? String, borderColor == nil { borderColor = s }
            if borderColor == nil, borderWidth != nil { borderColor = "#FFFFFF" }
            let before = b.objects.count
            switch kind {
            case "rect", "rectangle", "shape", "plate", "rule", "card", "box", "bar", "strip", "panel", "line", "divider", "frosted_card", "glass":
                b.rect(name, x, y, w, h, fill: fill, radius: radius, border: borderColor, borderWidth: borderWidth ?? 6)
            case "video", "video_pane", "videopane", "video_input", "camera", "cam", "float", "screen", "pane":
                b.float(name, x, y, w, h, border: borderColor, width: borderWidth ?? 6)
                if radius > 0 { b.objects[b.objects.count - 1].stroke.cornerRadius = radius }
            case "image", "logo", "picture", "photo":
                // Image placeholder: a plate the operator swaps for media.
                b.rect(name, x, y, w, h, fill: add["fill"] as? String ?? "#2A2A2E", radius: radius, border: borderColor, borderWidth: borderWidth ?? 6)
            default:
                b.text(name, "\(add["text"] ?? add["content"] ?? "")", x, y, w, h, size: size, color: color, weight: weight, align: align)
                if let fillHex = add["fill"] as? String { b.objects[b.objects.count - 1].fill.type = .color; b.objects[b.objects.count - 1].fill.color = fillHex }
            }
            if b.objects.count > before {
                var o = b.objects[b.objects.count - 1]
                if var op = num(add["opacity"]) { if op > 1 { op /= 100 }; o.opacity = min(1, max(0, op)) }
                if let fo = num(add["fillOpacity"]) { o.opacity = min(1, max(0, fo > 1 ? fo / 100 : fo)) }
                b.objects[b.objects.count - 1] = o
            }
            if b.objects.count > before, let family = (add["font"] as? String)?.trimmingCharacters(in: .whitespaces), !family.isEmpty {
                let resolved = AgentFonts.resolve(family)
                if resolved != family { notes.append("font_missing:\(family)→\(resolved)") }
                b.objects[b.objects.count - 1].typography.fontFamily = resolved
            }
            if b.objects.count > before, let p = add["phone"] as? [String: Any] {
                var o = mapToPhone(b.objects[b.objects.count - 1])
                o.transform.x = d("x", p) * 2160; o.transform.y = d("y", p) * 3840
                o.transform.width = max(0.01, d("w", p)) * 2160; o.transform.height = max(0.01, d("h", p)) * 3840
                if let s = (p["size"] as? NSNumber)?.doubleValue { o.typography.fontSize = s }
                phoneAdds.append(o)
            } else if b.objects.count > before {
                phoneAdds.append(mapToPhone(b.objects[b.objects.count - 1]))
            }
        }
        applySlotsAndEdits(&stream, phone: false)
        var phone = phoneObjects(id, stream: stream)
        applySlotsAndEdits(&phone, phone: true)
        stream += b.objects
        phone += phoneAdds
        restyle(&stream); restyle(&phone)
        for i in stream.indices { stream[i].zIndex = i }
        for i in phone.indices { phone[i].zIndex = i; phone[i].id = UUID() }

        let unknown = Set(slots.keys).union(edits.keys).subtracting(matched)
        if !unknown.isEmpty { notes.append("unmatched_slots:\(unknown.sorted().joined(separator: ","))") }

        let title = (args["title"] as? String) ?? template(id)?.name ?? id
        let bgHex = ((style["background"] as? String) ?? "#121214").uppercased()
        var slide = Slide(title: title, canvas: stream, themeApplication: .native, label: "AI", backgroundEnabled: true)
        slide.backgroundHex = bgHex
        if let notesText = args["notes"] as? String { slide.notes = notesText }
        if streamOnly {
            ShowController.ensurePrimaryEditorCanvas(on: &slide, backgroundHex: bgHex)
        } else {
            ShowController.ensurePhoneEditorCanvas(on: &slide, backgroundHex: bgHex)
            if let idx = slide.editorCanvases.firstIndex(where: { $0.isPhoneArtboard }) {
                slide.editorCanvases[idx].objects = phone
            }
        }
        return (slide, notes)
    }
}

extension BroadcastTemplatePack.Builder {
    mutating func header(show: String = "MORAPAY LIVE") {
        rect("Background", 0, 0, 3840, 2160, fill: "#121214")
        rect("Header Strip", 0, 0, 3840, 150, fill: "#1B1B1F")
        rect("Header Rule", 0, 150, 3840, 6, fill: "#6B9FE0")
        text("Show Name", show, 160, 0, 2400, 150, size: 56, weight: .black)
        rect("Live Tag", 3480, 35, 220, 80, fill: "#E5322D", radius: 8)
        text("Live", "LIVE", 3480, 35, 220, 80, size: 46, weight: .black, align: .center)
    }

    mutating func phoneHeader(show: String = "MORAPAY LIVE") {
        rect("Background", 0, 0, 2160, 3840, fill: "#121214")
        rect("Header Strip", 0, 0, 2160, 200, fill: "#1B1B1F")
        rect("Header Rule", 0, 200, 2160, 6, fill: "#6B9FE0")
        text("Show Name", show, 100, 0, 1500, 200, size: 60, weight: .black)
        rect("Live Tag", 1840, 60, 220, 80, fill: "#E5322D", radius: 8)
        text("Live", "LIVE", 1840, 60, 220, 80, size: 46, weight: .black, align: .center)
    }

    mutating func phoneFooter() {
        rect("Ticker Bar", 0, 3640, 2160, 200, fill: "#FFFFFF")
        rect("Ticker Tag", 0, 3640, 500, 200, fill: "#6B9FE0")
        text("Ticker Label", "MORAPAY", 0, 3640, 500, 200, size: 50, color: "#121214", weight: .black, align: .center)
        text("Ticker", "Stablecoin rails  ·  Instant settlement  ·  Built for Africa", 540, 3640, 1580, 200, size: 44, color: "#121214", weight: .semibold)
    }

    mutating func footer() {
        rect("Ticker Bar", 0, 2010, 3840, 150, fill: "#FFFFFF")
        rect("Ticker Tag", 0, 2010, 460, 150, fill: "#6B9FE0")
        text("Ticker Label", "MORAPAY", 0, 2010, 460, 150, size: 52, color: "#121214", weight: .black, align: .center)
        text("Ticker", "Stablecoin rails  ·  Instant settlement  ·  Built for Africa", 520, 2010, 3260, 150, size: 52, color: "#121214", weight: .semibold)
    }

    mutating func titleCard() {
        header()
        rect("Accent Rule", 240, 860, 420, 14, fill: "#6B9FE0")
        text("Headline", "Stablecoin Rails for Africa", 240, 900, 3360, 360, size: 190, weight: .black)
        text("Subline", "Morapay Live, Episode 1", 240, 1270, 3000, 150, size: 80, color: "#9AA3B2", weight: .semibold)
        rect("Nameplate", 240, 1600, 1600, 230, fill: "#1B1B1F", border: "#6B9FE0", borderWidth: 6)
        text("Host Name", "Kaleel", 300, 1615, 1500, 110, size: 72)
        text("Host Role", "Founder, Morapay", 300, 1720, 1500, 90, size: 50, color: "#6B9FE0", weight: .semibold)
        footer()
    }

    mutating func nextUp() {
        header()
        text("Section Label", "NEXT UP", 240, 250, 1500, 110, size: 60, color: "#6B9FE0", weight: .black)
        text("Headline", "On today's show", 240, 350, 3360, 200, size: 120, weight: .black)
        for i in 0..<3 {
            let y = 680.0 + Double(i) * 410
            rect("Item Marker \(i + 1)", 240, y, 260, 330, fill: "#6B9FE0")
            text("Item Number \(i + 1)", "\(i + 1)", 240, y, 260, 330, size: 160, color: "#121214", weight: .black, align: .center)
            rect("Item Plate \(i + 1)", 520, y, 3080, 330, fill: "#1B1B1F")
            text("Item \(i + 1)", "Agenda item \(i + 1)", 600, y, 2900, 330, size: 96)
        }
        footer()
    }

    mutating func statCards() {
        header()
        rect("Accent Rule", 240, 250, 300, 12, fill: "#6B9FE0")
        text("Headline", "Cross-border payments still take days", 240, 280, 3360, 200, size: 116, weight: .black)
        let w = (3360.0 - 160) / 3
        for i in 0..<3 {
            let x = 240 + Double(i) * (w + 80)
            rect("Card \(i + 1)", x, 620, w, 1240, fill: "#1B1B1F", radius: 24, border: "#25252A", borderWidth: 4)
            rect("Card Rule \(i + 1)", x, 620, w, 14, fill: "#6B9FE0")
            text("Stat Value \(i + 1)", "TBD", x + 80, 760, w - 160, 380, size: 230, color: "#6B9FE0", weight: .black)
            text("Stat Label \(i + 1)", "Metric \(i + 1)", x + 80, 1170, w - 160, 200, size: 80)
            text("Stat Note \(i + 1)", "Source / context", x + 80, 1420, w - 160, 300, size: 52, color: "#9AA3B2", weight: .medium)
        }
        footer()
    }

    mutating func processSteps() {
        header()
        rect("Accent Rule", 240, 250, 300, 12, fill: "#6B9FE0")
        text("Headline", "How Morapay works", 240, 280, 3360, 200, size: 116, weight: .black)
        let gap = 120.0, w = (3360 - gap * 3) / 4
        for i in 0..<4 {
            let x = 240 + Double(i) * (w + gap)
            rect("Step Card \(i + 1)", x, 900, w, 700, fill: "#1B1B1F", radius: 24, border: "#6B9FE0", borderWidth: 6)
            text("Step Number \(i + 1)", "0\(i + 1)", x + 60, 940, w - 120, 160, size: 96, color: "#6B9FE0", weight: .black)
            text("Step \(i + 1)", ["Send", "Convert", "Settle", "Receive"][i], x + 60, 1120, w - 120, 200, size: 104)
            text("Step Note \(i + 1)", "Short detail", x + 60, 1330, w - 120, 220, size: 50, color: "#9AA3B2", weight: .medium)
            if i < 3 { text("Arrow \(i + 1)", "→", x + w, 1150, gap, 200, size: 120, color: "#6B9FE0", align: .center) }
        }
        footer()
    }
}
