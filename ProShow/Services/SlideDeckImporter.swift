#if os(macOS)
import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Import slides v1: rasterize a PowerPoint, Keynote, or PDF deck to full-frame PNGs
/// at the project resolution. PPT, PPTX, and Keynote go through Keynote's exporter;
/// PDF renders in-process with PDFKit.
enum SlideDeckImporter {
    enum ImportError: LocalizedError {
        case keynoteMissing
        case exportFailed(String)
        case noSlides

        var errorDescription: String? {
            switch self {
            case .keynoteMissing: "Import needs Keynote or LibreOffice for PowerPoint. Or export the deck as PDF."
            case .exportFailed(let detail): "Slide import failed. \(detail)"
            case .noSlides: "No slides found in that file."
            }
        }
    }

    static let allowedTypes: [UTType] = {
        var types: [UTType] = [.pdf]
        for ext in ["pptx", "ppt", "key"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    /// Rasterizes `source` into `destinationDir`, returning ordered PNG URLs sized to `width`x`height`.
    static func rasterize(source: URL, into destinationDir: URL, width: Int, height: Int) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let ext = source.pathExtension.lowercased()
        if ext == "pdf" {
            return try rasterizePDF(source, into: destinationDir, width: width, height: height)
        }
        if ext != "key", let soffice = libreOfficeBinary() {
            let pdfDir = fm.temporaryDirectory.appendingPathComponent("proshow-pdf-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: pdfDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: pdfDir) }
            if let pdf = try? convertWithLibreOffice(soffice, source: source, outDir: pdfDir) {
                return try rasterizePDF(pdf, into: destinationDir, width: width, height: height)
            }
        }
        let staging = fm.temporaryDirectory.appendingPathComponent("proshow-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try exportWithKeynote(source, to: staging)
        let exported = (try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
            .filter { ["png", "jpg", "jpeg", "tiff"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !exported.isEmpty else { throw ImportError.noSlides }
        var out: [URL] = []
        for (index, url) in exported.enumerated() {
            guard let image = NSImage(contentsOf: url),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let dest = destinationDir.appendingPathComponent(String(format: "slide-%02d.png", index + 1))
            try writePNG(fitting: cg, width: width, height: height, to: dest)
            out.append(dest)
        }
        guard !out.isEmpty else { throw ImportError.noSlides }
        return out
    }

    private static func libreOfficeBinary() -> URL? {
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func convertWithLibreOffice(_ soffice: URL, source: URL, outDir: URL) throws -> URL {
        let process = Process()
        process.executableURL = soffice
        process.arguments = ["--headless", "--convert-to", "pdf", "--outdir", outDir.path, source.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let pdf = outDir.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: pdf.path) else {
            throw ImportError.exportFailed("LibreOffice could not convert the deck.")
        }
        return pdf
    }

    private static func exportWithKeynote(_ source: URL, to folder: URL) throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Keynote") != nil else {
            throw ImportError.keynoteMissing
        }
        let src = source.path.replacingOccurrences(of: "\"", with: "\\\"")
        let dst = folder.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application id "com.apple.Keynote"
            set theDoc to open POSIX file "\(src)"
            delay 1
            export theDoc to POSIX file "\(dst)" as slide images with properties {image format:PNG, skipped slides:false}
            close theDoc saving no
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ImportError.exportFailed(msg.isEmpty ? "Keynote could not open the file." : msg)
        }
    }

    private static func rasterizePDF(_ source: URL, into dir: URL, width: Int, height: Int) throws -> [URL] {
        guard let doc = PDFDocument(url: source), doc.pageCount > 0 else { throw ImportError.noSlides }
        var out: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            guard let ctx = makeContext(width: width, height: height) else { continue }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let rect = fitRect(source: box.size, width: width, height: height)
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.minY)
            ctx.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            page.draw(with: .mediaBox, to: ctx)
            ctx.restoreGState()
            guard let cg = ctx.makeImage() else { continue }
            let dest = dir.appendingPathComponent(String(format: "slide-%02d.png", i + 1))
            try save(cg, to: dest)
            out.append(dest)
        }
        guard !out.isEmpty else { throw ImportError.noSlides }
        return out
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func fitRect(source: CGSize, width: Int, height: Int) -> CGRect {
        let scale = min(Double(width) / max(source.width, 1), Double(height) / max(source.height, 1))
        let w = source.width * scale, h = source.height * scale
        return CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h)
    }

    private static func writePNG(fitting image: CGImage, width: Int, height: Int, to url: URL) throws {
        guard let ctx = makeContext(width: width, height: height) else { throw ImportError.exportFailed("No graphics context.") }
        ctx.interpolationQuality = .high
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: fitRect(source: CGSize(width: image.width, height: image.height), width: width, height: height))
        guard let out = ctx.makeImage() else { throw ImportError.exportFailed("Render failed.") }
        try save(out, to: url)
    }

    private static func save(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ImportError.exportFailed("PNG encode failed.") }
        try data.write(to: url, options: .atomic)
    }
}

extension ShowController {
    /// File > Import Slides… Picks a deck, rasterizes it, and appends a new slide group of full-frame canvas images.
    func presentImportSlides() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SlideDeckImporter.allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a PowerPoint, Keynote, or PDF deck"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSlideDeck(from: url)
    }

    func importSlideDeck(from url: URL) {
        let width = projectSettings.resolution.width
        let height = projectSettings.resolution.height
        let deckName = url.deletingPathExtension().lastPathComponent
        let safe = deckName.replacingOccurrences(of: "/", with: "-")
        let root = mediaProjectRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ProShow", isDirectory: true)
        let dir = root.appendingPathComponent("Assets/Images/Imported/\(safe)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        Task.detached(priority: .userInitiated) {
            do {
                let pngs = try SlideDeckImporter.rasterize(source: url, into: dir, width: width, height: height)
                await MainActor.run {
                    self.appendImportedDeck(name: deckName, images: pngs, width: Double(width), height: Double(height))
                }
            } catch {
                await MainActor.run { self.mediaAlert = error.localizedDescription }
            }
        }
    }

    func appendImportedDeck(name: String, images: [URL], width: Double, height: Double) {
        rehydrateFromEditor(persist: false)
        let slides: [Slide] = images.enumerated().map { index, url in
            var object = CanvasObject(
                name: "\(name) \(String(format: "%02d", index + 1))",
                kind: .image,
                bounds: CanvasBounds(x: 0, y: 0, width: width, height: height),
                zIndex: 0
            )
            object.fill.type = .image
            object.fill.imageURI = url.path
            object.fill.imageScaleMode = .fill
            object.transform.lockAspectRatio = true
            return Slide(
                title: "\(name) \(index + 1)",
                canvas: [object],
                themeApplication: .native,
                backgroundEnabled: false
            )
        }
        guard !slides.isEmpty else { return }
        var groupName = name
        var n = 2
        while show.groups.contains(where: { $0.name == groupName }) {
            groupName = "\(name) \(n)"
            n += 1
        }
        appendSlides(slides, toGroupNamed: groupName, colorHex: "#6B9FE0")
        selectedSlideID = slides.first?.id
        editors.syncPresentation(from: show, selectedSlideID: selectedSlideID)
        rebuildSearchIndex()
    }
}
#endif
