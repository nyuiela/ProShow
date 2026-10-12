import Foundation
#if canImport(CoreImage)
import CoreImage
#endif

enum CoreImageTransitionEngine {
    static func composite(
        kind: CoreImageTransitionKind,
        from: TransitionImage,
        to: TransitionImage,
        uniforms: TransitionUniforms
    ) -> TransitionImage {
        if uniforms.progress <= 0 { return from }
        if uniforms.progress >= 1 { return to }
        #if canImport(CoreImage)
        if let rendered = renderCI(kind: kind, from: from, to: to, uniforms: uniforms) {
            return rendered
        }
        #endif
        return fallback(kind: kind, from: from, to: to, progress: Double(uniforms.progress), intensity: Double(uniforms.intensity))
    }

    private static func fallback(
        kind: CoreImageTransitionKind,
        from: TransitionImage,
        to: TransitionImage,
        progress: Double,
        intensity: Double
    ) -> TransitionImage {
        let width = min(from.width, to.width)
        let height = min(from.height, to.height)
        var pixels = Array(repeating: RGBA8(r: 0, g: 0, b: 0, a: 1), count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let u = width == 1 ? 0.0 : Double(x) / Double(width - 1)
                let v = height == 1 ? 0.0 : Double(y) / Double(height - 1)
                let index = y * width + x
                switch kind {
                case .pageCurl:
                    pixels[index] = u < progress ? to.pixel(at: index) : from.pixel(at: index)
                case .displace:
                    let shift = (0.5 - v) * 0.12 * intensity * sin(progress * .pi)
                    pixels[index] = mix(from.sample(u: u + shift, v: v), to.sample(u: u - shift, v: v), progress)
                case .ripple:
                    let dist = ((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)).squareRoot()
                    let wave = sin(dist * 22 - progress * 10) * 0.03 * intensity
                    pixels[index] = mix(from.sample(u: u + wave, v: v), to.sample(u: u - wave, v: v), progress)
                case .lensFlare:
                    let mixed = mix(from.pixel(at: index), to.pixel(at: index), progress)
                    let flare = max(0, 1 - ((u - 0.5) * (u - 0.5) + (v - 0.4) * (v - 0.4)).squareRoot() * 2) * sin(progress * .pi) * intensity
                    pixels[index] = RGBA8(r: min(1, mixed.r + flare), g: min(1, mixed.g + flare * 0.9), b: min(1, mixed.b + flare * 0.6), a: 1)
                }
            }
        }
        return TransitionImage(width: width, height: height, pixels: pixels)
    }

    private static func mix(_ a: RGBA8, _ b: RGBA8, _ t: Double) -> RGBA8 {
        RGBA8(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
    }

    #if canImport(CoreImage)
    private static func renderCI(
        kind: CoreImageTransitionKind,
        from: TransitionImage,
        to: TransitionImage,
        uniforms: TransitionUniforms
    ) -> TransitionImage? {
        let width = min(from.width, to.width)
        let height = min(from.height, to.height)
        guard width * height <= 64 * 64 else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let input = ciImage(from, context: context), let target = ciImage(to, context: context) else { return nil }
        let filterName: String
        switch kind {
        case .pageCurl: filterName = "CIPageCurlTransition"
        case .displace: filterName = "CICopyMachineTransition"
        case .ripple: filterName = "CIRippleTransition"
        case .lensFlare: filterName = "CIFlashTransition"
        }
        guard let filter = CIFilter(name: filterName) else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(target, forKey: kCIInputTargetImageKey)
        filter.setValue(Double(uniforms.progress), forKey: kCIInputTimeKey)
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let output = filter.outputImage,
              let cg = context.createCGImage(output, from: extent)
        else { return nil }
        return image(from: cg, width: width, height: height)
    }

    private static func ciImage(_ image: TransitionImage, context: CIContext) -> CIImage? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for (index, pixel) in image.pixels.enumerated() {
            let base = index * 4
            bytes[base] = UInt8(min(255, pixel.r * 255))
            bytes[base + 1] = UInt8(min(255, pixel.g * 255))
            bytes[base + 2] = UInt8(min(255, pixel.b * 255))
            bytes[base + 3] = UInt8(min(255, pixel.a * 255))
        }
        let data = Data(bytes)
        return CIImage(
            bitmapData: data,
            bytesPerRow: image.width * 4,
            size: CGSize(width: image.width, height: image.height),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    private static func image(from cg: CGImage, width: Int, height: Int) -> TransitionImage? {
        guard let provider = cg.dataProvider, let data = provider.data else { return nil }
        let pointer = CFDataGetBytePtr(data)
        let bytesPerPixel = max(cg.bitsPerPixel / 8, 4)
        var pixels: [RGBA8] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * cg.bytesPerRow) + (x * bytesPerPixel)
                pixels.append(RGBA8(
                    r: Double(pointer?[offset] ?? 0) / 255,
                    g: Double(pointer?[offset + 1] ?? 0) / 255,
                    b: Double(pointer?[offset + 2] ?? 0) / 255,
                    a: Double(pointer?[offset + 3] ?? 255) / 255
                ))
            }
        }
        return TransitionImage(width: width, height: height, pixels: pixels)
    }
    #endif
}
