import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

enum CanvasLayerStore {
    /// Top of list = highest z-index (front).
    static func layerItems(from objects: [CanvasObject]) -> [CanvasLayerItem] {
        objects
            .sorted { $0.zIndex > $1.zIndex }
            .map { layerItem(from: $0) }
    }

    static func layerItem(from object: CanvasObject) -> CanvasLayerItem {
        CanvasLayerItem(
            id: object.id,
            name: displayName(for: object),
            kind: LayerKind.from(kind: object.kind),
            kindDetail: kindDetail(for: object),
            isVisible: object.visibleOnAudience,
            isLocked: object.isCanvasLocked,
            zIndex: object.zIndex,
            parentGroupId: object.groupID,
            thumbnailImage: thumbnail(for: object)
        )
    }

    static func displayName(for object: CanvasObject) -> String {
        let trimmed = object.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if object.isTextLike {
            let snippet = object.displayText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            if !snippet.isEmpty { return String(snippet.prefix(48)) }
        }
        return object.kind.title
    }

    static func kindDetail(for object: CanvasObject) -> String {
        switch object.kind {
        case .videoInput:
            if let source = object.assignedSource?.name.nilIfEmpty { return source }
            return object.sourceSummary.nilIfEmpty ?? LayerKind.camera.rawValue
        case .image:
            if !object.fill.imageURI.isEmpty { return "Image asset" }
            return LayerKind.image.rawValue
        case .liveQuote:
            return "Live Quote"
        case .text, .title, .subtitle:
            return "Lyric Text"
        case .rectangle, .roundedRectangle, .ellipse, .qrCode:
            return "Graphic Shape"
        default:
            return object.kind.title
        }
    }

    #if os(macOS)
    static func thumbnail(for object: CanvasObject) -> NSImage? {
        if object.fill.type == .image, !object.fill.imageURI.isEmpty {
            if let image = loadImage(uri: object.fill.imageURI) { return image }
        }
        return swatchThumbnail(for: object)
    }

    static func thumbnailForFilePath(_ path: String) -> NSImage? {
        loadImage(uri: path)
    }

    private static func loadImage(uri: String) -> NSImage? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http"), let url = URL(string: trimmed) { return nil }
        let url = URL(fileURLWithPath: trimmed)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Layer rows ask for this on every redraw. Decode a file once per path and modification date.
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    private static func swatchThumbnail(for object: CanvasObject) -> NSImage? {
        let key = "swatch|\(object.fillHex)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        let image = drawSwatch(for: object)
        if let image { imageCache.setObject(image, forKey: key) }
        return image
    }

    private static func drawSwatch(for object: CanvasObject) -> NSImage? {
        let size = NSSize(width: 28, height: 28)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let fill = (Color(hex: object.fillHex).map { NSColor($0) }) ?? .darkGray
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 24, height: 24), xRadius: 2, yRadius: 2).fill()
        image.unlockFocus()
        return image
    }
    #endif
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
