import Foundation

struct RGBA8: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

struct LUT3D: Hashable, Sendable {
    var size: Int
    var values: [RGBA8]

    static func identity(size: Int = 2) -> LUT3D {
        var values: [RGBA8] = []
        let denom = Double(max(size - 1, 1))
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values.append(RGBA8(r: Double(r) / denom, g: Double(g) / denom, b: Double(b) / denom, a: 1))
                }
            }
        }
        return LUT3D(size: size, values: values)
    }

    static func parseCUBE(_ text: String) -> LUT3D? {
        var size = 0
        var values: [RGBA8] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.uppercased().hasPrefix("TITLE") { continue }
            if line.uppercased().hasPrefix("LUT_3D_SIZE") {
                size = line.split(separator: " ").compactMap { Int($0) }.last ?? 0
                continue
            }
            let parts = line.split(separator: " ").compactMap { Double($0) }
            if parts.count >= 3 {
                values.append(RGBA8(r: parts[0], g: parts[1], b: parts[2], a: parts.count > 3 ? parts[3] : 1))
            }
        }
        guard size > 0, values.count == size * size * size else { return nil }
        return LUT3D(size: size, values: values)
    }

    func sample(r: Double, g: Double, b: Double) -> RGBA8 {
        let clampedR = min(1, max(0, r))
        let clampedG = min(1, max(0, g))
        let clampedB = min(1, max(0, b))
        let last = Double(size - 1)
        let ir = Int((clampedR * last).rounded())
        let ig = Int((clampedG * last).rounded())
        let ib = Int((clampedB * last).rounded())
        return values[(ib * size * size) + (ig * size) + ir]
    }
}

/// CPU-testable chroma, LUT, and grade path that mirrors `ChromaKeyFilter.metal`.
final class VideoFilterEngine: @unchecked Sendable {
    var chroma: ChromaKeySettings = .green
    var grade = ColorGradeSettings()
    var lut: LUT3D = .identity()
    var bypassProcessing = false

    func chromaAlpha(pixel: RGBA8, settings: ChromaKeySettings? = nil) -> Double {
        let key = settings ?? chroma
        let dr = pixel.r - key.keyColor.r
        let dg = pixel.g - key.keyColor.g
        let db = pixel.b - key.keyColor.b
        let dist = (dr * dr + dg * dg + db * db).squareRoot()
        let start = key.edgeCutoff
        let end = key.edgeCutoff + max(key.smoothness, 0.0001)
        if dist <= start { return 0 }
        if dist >= end { return 1 }
        return (dist - start) / (end - start)
    }

    func applyChroma(pixel: RGBA8, settings: ChromaKeySettings? = nil) -> RGBA8 {
        if bypassProcessing { return pixel }
        let key = settings ?? chroma
        var next = pixel
        let spill = max(next.g - max(next.r, next.b), 0) * key.spillSuppression
        next.g = min(1, max(0, next.g - spill))
        next.a *= chromaAlpha(pixel: pixel, settings: key)
        return next
    }

    func applyGrade(pixel: RGBA8, grade: ColorGradeSettings? = nil, lut: LUT3D? = nil) -> RGBA8 {
        let settings = grade ?? self.grade
        var next = pixel
        let exposure = pow(2, settings.exposure)
        next.r = ((next.r - 0.5) * settings.contrast + 0.5) * exposure
        next.g = ((next.g - 0.5) * settings.contrast + 0.5) * exposure
        next.b = ((next.b - 0.5) * settings.contrast + 0.5) * exposure
        let luma = next.r * 0.2126 + next.g * 0.7152 + next.b * 0.0722
        next.r = luma + (next.r - luma) * settings.saturation
        next.g = luma + (next.g - luma) * settings.saturation
        next.b = luma + (next.b - luma) * settings.saturation
        next.r += settings.sharpness * 0.02
        next.g += settings.sharpness * 0.02
        next.b += settings.sharpness * 0.02
        if settings.backgroundBlur > 0 {
            next.r = next.r * (1 - settings.backgroundBlur * 0.15) + luma * settings.backgroundBlur * 0.15
            next.g = next.g * (1 - settings.backgroundBlur * 0.15) + luma * settings.backgroundBlur * 0.15
            next.b = next.b * (1 - settings.backgroundBlur * 0.15) + luma * settings.backgroundBlur * 0.15
        }
        let mapped = (lut ?? self.lut).sample(r: next.r, g: next.g, b: next.b)
        return RGBA8(
            r: min(1, max(0, mapped.r)),
            g: min(1, max(0, mapped.g)),
            b: min(1, max(0, mapped.b)),
            a: min(1, max(0, next.a))
        )
    }

    func process(pixel: RGBA8) -> RGBA8 {
        if bypassProcessing { return pixel }
        return applyGrade(pixel: applyChroma(pixel: pixel))
    }
}
