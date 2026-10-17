import Foundation

/// Builds a fresh `.proshow` bundle (Stream + Phone boards, lettered placeholders, timers, outline)
/// from a JSON slide spec. Used to stand up event projects that a designer's spec can be re-run into.
/// Spec: { title, notes, camera: {id,label,endpoint}, placeholderLabels: {A: ...}, timers: [{key,name,seconds}],
///         slides: [{group,title,notes,stream:[el],phone:[el]}], blocks: [{title,type,start "HH:MM",minutes}], date "YYYY-MM-DD" }
enum SpecProjectBuilder {
    static func build(specURL: URL, root: URL, programURL: URL?) throws -> Int {
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf: specURL)) as! [String: Any]
                var timersByKey: [String: InspectorTimer] = [:]
        for t in (spec["timers"] as? [[String: Any]]) ?? [] {
            timersByKey[t["key"] as? String ?? ""] = InspectorTimer(name: t["name"] as? String ?? "Timer", durationSeconds: (t["seconds"] as? NSNumber)?.intValue ?? 60, overrunThresholdSeconds: 30)
        }
        func d(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        func obj(_ e: [String: Any], z: Int) -> CanvasObject {
            let b = CanvasBounds(x: d(e["x"]), y: d(e["y"]), width: d(e["w"]), height: d(e["h"]))
            let name = e["name"] as? String ?? "Element"
            switch e["t"] as? String {
            case "rect":
                let radius = d(e["radius"])
                var o = CanvasObject(name: name, kind: radius > 0 ? .roundedRectangle : .rectangle, bounds: b, zIndex: z, fillHex: e["fill"] as? String ?? "#000000")
                o.stroke.cornerRadius = radius
                if let border = e["border"] as? String { o.stroke.style = .solid; o.stroke.color = border; o.stroke.width = d(e["bw"]); o.stroke.position = .inside }
                return o
            case "image":
                var o = CanvasObject(name: name, kind: .image, bounds: b, zIndex: z)
                o.fill.type = .image; o.fill.imageURI = e["path"] as? String ?? ""
                return o
            case "ph":
                let letter = e["letter"] as? String ?? "A"
                var o = CanvasObject(name: name, kind: .videoInput, bounds: b, zIndex: z)
                o.token = letter
                o.assignedSource = AssignedMediaSource(sourceID: "placeholder-\(letter)", name: "Placeholder \(letter)", sourceType: .placeholderSlot, category: .placeholders, connectionString: letter, placeholderLetter: letter)
                o.fill.type = .none
                if let border = e["border"] as? String { o.stroke.style = .solid; o.stroke.color = border; o.stroke.width = d(e["bw"]); o.stroke.position = .inside }
                return o
            case "timer":
                var o = CanvasObject(name: name, kind: .timerCountdown, bounds: b, zIndex: z, fontFamily: e["font"] as? String ?? "DM Sans", fontSize: d(e["size"]), fontColor: e["color"] as? String ?? "#FFFFFF",
                                     timerID: timersByKey[e["timer"] as? String ?? ""]?.id)
                o.fill.type = .none; o.countdownStartOn = .onSlideEnter
                o.typography.isBold = true; o.typography.fontWeight = .bold
                o.textLayout.horizontalAlign = .center; o.textLayout.verticalAlign = .middle
                return o
            default:
                var o = CanvasObject(name: name, kind: .text, bounds: b, zIndex: z, text: e["text"] as? String ?? "", fillHex: "#000000",
                                     fontFamily: e["font"] as? String ?? "Avenir Next", fontSize: d(e["size"]), fontColor: e["color"] as? String ?? "#FFFFFF")
                o.fill.type = .none
                let bold = (e["bold"] as? Bool) ?? true
                o.typography.isBold = bold
                let w = (e["weight"] as? NSNumber)?.intValue ?? (bold ? 700 : 400)
                o.typography.fontWeight = w >= 800 ? .black : w >= 700 ? .bold : w >= 600 ? .semibold : w >= 500 ? .medium : .regular
                o.textLayout.horizontalAlign = TextHorizontalAlign(rawValue: e["align"] as? String ?? "left") ?? .left
                o.textLayout.verticalAlign = .middle
                o.textLayout.margins = TextBoxMargins(top: 0, bottom: 0, left: 0, right: 0)
                return o
            }
        }
        let bg = spec["background"] as? String ?? "#000000"
        var groups: [SlideGroup] = []
        let colors = ["#F8C701", "#46000B", "#7A1A0C", "#C6FF3D", "#6B9FE0", "#E5322D", "#FFE888", "#137A08"]
        for raw in spec["slides"] as! [[String: Any]] {
            let gname = raw["group"] as! String
            let stream = (raw["stream"] as! [[String: Any]]).enumerated().map { obj($1, z: $0) }
            let phone = (raw["phone"] as! [[String: Any]]).enumerated().map { obj($1, z: $0) }
            var slide = Slide(title: raw["title"] as! String, notes: raw["notes"] as? String ?? "", canvas: stream,
                              themeApplication: .native, label: spec["label"] as? String ?? "", backgroundEnabled: true, backgroundHex: bg)
            slide.editorCanvases = [
                EditorCanvasFrame(id: UUID(), name: "Stream", width: 3840, height: 2160, originX: 0, originY: 0, isPrimary: true, backgroundHex: bg),
                EditorCanvasFrame(id: UUID(), name: "Phone", width: 2160, height: 3840, originX: 4320, originY: 0, isPrimary: false, backgroundHex: bg, objects: phone),
            ]
            if let i = groups.firstIndex(where: { $0.name == gname }) { groups[i].slides.append(slide) }
            else { groups.append(SlideGroup(name: gname, colorHex: colors[groups.count % colors.count], slides: [slide])) }
        }
        let show = Show(name: (spec["title"] as? String ?? root.deletingPathExtension().lastPathComponent), groups: groups, notes: spec["notes"] as? String ?? "")
        let playlist = Playlist(name: show.name, items: [PlaylistItem(kind: .show, title: show.name, showID: show.id, detail: spec["date"] as? String ?? "")])
        try? FileManager.default.removeItem(at: root)
        var bundle = try ProjectBundle.create(at: root, name: root.deletingPathExtension().lastPathComponent, seed: show, playlist: playlist)
        // Studio: one real camera row (MacBook), placeholders A..I with A mapped, timers.
        let cam = spec["camera"] as? [String: String] ?? [:]
        let camID = UUID(uuidString: cam["id"] ?? "") ?? UUID()
        if let endpoint = cam["endpoint"], !endpoint.isEmpty {
            bundle.manifest.studio.videoSources = [StudioVideoSource(id: camID, label: cam["label"] ?? "Camera", kind: .camera, endpoint: endpoint)]
        }
        var phs = PlaceholderConfiguration.catalog()
        let labels = spec["placeholderLabels"] as? [String: String] ?? [:]
        for i in phs.indices {
            if let l = labels[phs[i].letter] { phs[i].label = l }
            if phs[i].letter == "A", !bundle.manifest.studio.videoSources.isEmpty { phs[i].primarySourceId = camID.uuidString }
        }
        bundle.manifest.studio.placeholderMatrix = phs
        var inspector = ActionInspectorCatalog.empty
        inspector.timers = Array(timersByKey.values).sorted { $0.name < $1.name }
        bundle.manifest.studio.inspector = inspector
        try bundle.writeManifest()
        // Outline
        var doc = ProgramDocumentModel()
        doc.showTitle = (spec["title"] as? String ?? root.deletingPathExtension().lastPathComponent)
        let cal = { () -> Calendar in var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
        func at(_ hm: String) -> Date {
            let p = hm.split(separator: ":").map { Int($0)! }
            let ymd = (spec["date"] as? String ?? "2026-01-01").split(separator: "-").compactMap { Int($0) }
            return cal.date(from: DateComponents(year: ymd.first, month: ymd.dropFirst().first, day: ymd.last, hour: p[0], minute: p[1]))!
        }
        doc.scheduledDate = at("12:00"); doc.hardStartTime = at("12:00"); doc.targetDurationSeconds = ((spec["blocks"] as? [[String: Any]]) ?? []).reduce(0) { $0 + d($1["minutes"]) * 60 }
        var blocks: [RundownBlock] = []
        for (i, b) in (spec["blocks"] as! [[String: Any]]).enumerated() {
            let type: SegmentType = ["opener": .opener, "panel": .panel, "keynote": .keynote, "closer": .closer][b["type"] as! String] ?? .keynote
            var block = RundownBlock(itemNumber: "\(i + 1)", title: b["title"] as! String, segmentType: type, plannedDurationSeconds: d(b["minutes"]) * 60)
            block.hardStartTime = at(b["start"] as! String)
            block.isHardTimeLocked = true
            block.referenceNotes = "Starts \(b["start"]!) GMT, \(b["minutes"]!)m. Group: \(groups.indices.contains(i) ? groups[i].name : "")"
            blocks.append(block)
        }
        doc.rundownBlocks = blocks
        try ProgramDocumentStore.save(doc, to: root.appendingPathComponent("Program.program", isDirectory: true))
        if let programURL { try ProgramDocumentStore.save(doc, to: programURL) }
        return (spec["slides"] as! [Any]).count
    }
}
