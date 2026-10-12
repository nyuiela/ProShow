import Foundation

struct LottieWipeDocument: Hashable, Sendable {
    var width: Double
    var height: Double
    var inPoint: Double
    var outPoint: Double
    var frameRate: Double
    var fillColors: [RGBA8]

    var durationFrames: Double { max(outPoint - inPoint, 1) }

    static func parse(_ data: Data) throws -> LottieWipeDocument {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let width = (json["w"] as? NSNumber)?.doubleValue ?? 1920
        let height = (json["h"] as? NSNumber)?.doubleValue ?? 1080
        let inPoint = (json["ip"] as? NSNumber)?.doubleValue ?? 0
        let outPoint = (json["op"] as? NSNumber)?.doubleValue ?? 30
        let frameRate = (json["fr"] as? NSNumber)?.doubleValue ?? 30
        var fills: [RGBA8] = []
        if let layers = json["layers"] as? [[String: Any]] {
            for layer in layers {
                collectFills(in: layer["shapes"] as? [Any] ?? [], into: &fills)
            }
        }
        return LottieWipeDocument(
            width: width,
            height: height,
            inPoint: inPoint,
            outPoint: outPoint,
            frameRate: frameRate,
            fillColors: fills
        )
    }

    private static func collectFills(in nodes: [Any], into fills: inout [RGBA8]) {
        for node in nodes {
            guard let dict = node as? [String: Any] else { continue }
            if let children = dict["it"] as? [Any] {
                collectFills(in: children, into: &fills)
            }
            if (dict["ty"] as? String) == "fl", let color = dict["c"] as? [String: Any] {
                if let components = color["k"] as? [NSNumber], components.count >= 3 {
                    fills.append(RGBA8(
                        r: components[0].doubleValue,
                        g: components[1].doubleValue,
                        b: components[2].doubleValue,
                        a: components.count > 3 ? components[3].doubleValue : 1
                    ))
                }
            }
        }
    }
}

enum LottieTransitionEngine {
    static func themedFills(in document: LottieWipeDocument, theme: TransitionThemeColors) -> [RGBA8] {
        document.fillColors.enumerated().map { index, _ in
            index.isMultiple(of: 2) ? theme.primary : theme.accent
        }
    }

    static func alphaMatte(
        document: LottieWipeDocument,
        progress: Double,
        width: Int,
        height: Int
    ) -> [Double] {
        let t = min(1, max(0, progress))
        let edge = t * Double(max(width, 1))
        var matte = Array(repeating: 0.0, count: max(width, 1) * max(height, 1))
        for y in 0..<max(height, 1) {
            for x in 0..<max(width, 1) {
                matte[y * width + x] = Double(x) < edge ? 1 : 0
            }
        }
        return matte
    }

    static func composite(
        document: LottieWipeDocument,
        from: TransitionImage,
        to: TransitionImage,
        progress: Double,
        theme: TransitionThemeColors = .desk
    ) -> TransitionImage {
        if progress <= 0 { return from }
        if progress >= 1 { return to }
        let width = min(from.width, to.width)
        let height = min(from.height, to.height)
        let matte = alphaMatte(document: document, progress: progress, width: width, height: height)
        let wash = themedFills(in: document, theme: theme).first ?? theme.primary
        var pixels = Array(repeating: RGBA8(r: 0, g: 0, b: 0, a: 1), count: width * height)
        for index in 0..<(width * height) {
            let mask = matte[index]
            let incoming = to.pixel(at: index)
            let outgoing = from.pixel(at: index)
            let edged = mask > 0 && mask < 1
            if edged {
                pixels[index] = RGBA8(
                    r: wash.r * 0.35 + incoming.r * 0.65,
                    g: wash.g * 0.35 + incoming.g * 0.65,
                    b: wash.b * 0.35 + incoming.b * 0.65,
                    a: 1
                )
            } else {
                pixels[index] = mask >= 1 ? incoming : outgoing
            }
        }
        return TransitionImage(width: width, height: height, pixels: pixels)
    }
}
