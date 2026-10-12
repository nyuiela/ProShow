import Foundation
#if canImport(Metal)
import Metal
#endif

/// GPU + CPU interpolator for Texture A → Texture B over progress T.
final class TransitionShaderEngine: @unchecked Sendable {
    var lastBackend: String = "cpu"

    #if canImport(Metal)
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipelines: [String: MTLRenderPipelineState] = [:]
    private var attemptedLibrary = false
    #endif

    func composite(
        effect: TransitionShaderEffect,
        from: TransitionImage,
        to: TransitionImage,
        uniforms: TransitionUniforms
    ) -> TransitionImage {
        if uniforms.progress <= 0 {
            lastBackend = "cpu"
            return from
        }
        if uniforms.progress >= 1 {
            lastBackend = "cpu"
            return to
        }
        if let gpu = renderOnGPU(effect: effect, from: from, to: to, uniforms: uniforms) {
            lastBackend = "metal"
            return gpu
        }
        lastBackend = "cpu"
        return renderOnCPU(effect: effect, from: from, to: to, uniforms: uniforms)
    }

    func renderOnCPU(
        effect: TransitionShaderEffect,
        from: TransitionImage,
        to: TransitionImage,
        uniforms: TransitionUniforms
    ) -> TransitionImage {
        let width = min(from.width, to.width)
        let height = min(from.height, to.height)
        var pixels = Array(repeating: RGBA8(r: 0, g: 0, b: 0, a: 1), count: width * height)
        let p = Double(uniforms.progress)
        let intensity = Double(uniforms.intensity)
        for y in 0..<height {
            for x in 0..<width {
                let u = width == 1 ? 0.0 : Double(x) / Double(width - 1)
                let v = height == 1 ? 0.0 : Double(y) / Double(height - 1)
                pixels[y * width + x] = sample(effect: effect, from: from, to: to, u: u, v: v, progress: p, intensity: intensity)
            }
        }
        return TransitionImage(width: width, height: height, pixels: pixels)
    }

    private func sample(
        effect: TransitionShaderEffect,
        from: TransitionImage,
        to: TransitionImage,
        u: Double,
        v: Double,
        progress: Double,
        intensity: Double
    ) -> RGBA8 {
        switch effect {
        case .whipPan:
            let blur = sin(progress * .pi) * intensity
            let colA = from.sample(u: u - progress * blur, v: v)
            let colB = to.sample(u: u + (1 - progress) * blur, v: v)
            return u >= (1 - progress) ? colB : colA
        case .liquidRipple:
            let dx = u - 0.5
            let dy = v - 0.5
            let dist = (dx * dx + dy * dy).squareRoot()
            let wave = sin(dist * 18 - progress * 12) * (1 - progress) * 0.035 * intensity
            let inv = max(0.0001, dist)
            let uu = u + (dx / inv) * wave
            let vv = v + (dy / inv) * wave
            return mix(from.sample(u: uu, v: vv), to.sample(u: uu, v: vv), smooth(progress, 0.15, 0.85))
        case .glitch:
            let slice = (v * 24 + progress * 7).truncatingRemainder(dividingBy: 1) > 0.92 ? 1.0 : 0.0
            let shift = (slice * 0.04 + 0.02) * intensity * sin(progress * 18)
            let aR = from.sample(u: u + shift, v: v)
            let aG = from.sample(u: u, v: v)
            let aB = from.sample(u: u - shift, v: v)
            let colA = RGBA8(r: aR.r, g: aG.g, b: aB.b, a: 1)
            return mix(colA, to.sample(u: u, v: v), smooth(progress, 0.2, 0.8))
        case .crossZoom:
            let bounce = 1 + sin(progress * .pi) * 0.18 * intensity
            let zoomA = ((u - 0.5) / bounce + 0.5, (v - 0.5) / bounce + 0.5)
            let zoomB = ((u - 0.5) * (2 - bounce) + 0.5, (v - 0.5) * (2 - bounce) + 0.5)
            return mix(from.sample(u: zoomA.0, v: zoomA.1), to.sample(u: zoomB.0, v: zoomB.1), smooth(progress, 0.25, 0.75))
        case .lightLeak:
            let burn = sin(progress * .pi) * intensity
            let mixed = mix(from.sample(u: u, v: v), to.sample(u: u, v: v), smooth(progress, 0.2, 0.8))
            let flare = max(0, 1 - ((u - 0.7) * (u - 0.7) + (v - 0.25) * (v - 0.25)).squareRoot()) * burn * 0.35
            return RGBA8(r: min(1, mixed.r + flare), g: min(1, mixed.g + flare * 0.82), b: min(1, mixed.b + flare * 0.55), a: 1)
        }
    }

    private func mix(_ a: RGBA8, _ b: RGBA8, _ t: Double) -> RGBA8 {
        RGBA8(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
    }

    private func smooth(_ t: Double, _ edge0: Double, _ edge1: Double) -> Double {
        let x = min(1, max(0, (t - edge0) / max(0.0001, edge1 - edge0)))
        return x * x * (3 - 2 * x)
    }

    #if canImport(Metal)
    private func renderOnGPU(
        effect: TransitionShaderEffect,
        from: TransitionImage,
        to: TransitionImage,
        uniforms: TransitionUniforms
    ) -> TransitionImage? {
        prepareDevice()
        guard let device, let queue, let pipeline = pipelines[effect.metalFunction] else { return nil }
        guard let fromTex = makeTexture(from: from, device: device),
              let toTex = makeTexture(from: to, device: device)
        else { return nil }
        let width = min(from.width, to.width)
        let height = min(from.height, to.height)
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outDesc.usage = [.renderTarget, .shaderRead]
        guard let output = device.makeTexture(descriptor: outDesc),
              let command = queue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(fromTex, index: 0)
        encoder.setFragmentTexture(toTex, index: 1)
        var payload = uniforms
        encoder.setFragmentBytes(&payload, length: MemoryLayout<TransitionUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        return readback(output)
    }

    private func prepareDevice() {
        if device == nil {
            device = MTLCreateSystemDefaultDevice()
            queue = device?.makeCommandQueue()
        }
        guard let device, !attemptedLibrary else { return }
        attemptedLibrary = true
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "transition_vertex")
        else { return }
        for effect in TransitionShaderEffect.allCases {
            guard let fragment = library.makeFunction(name: effect.metalFunction) else { continue }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            if let state = try? device.makeRenderPipelineState(descriptor: descriptor) {
                pipelines[effect.metalFunction] = state
            }
        }
    }

    private func makeTexture(from image: TransitionImage, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: image.width,
            height: image.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for (index, pixel) in image.pixels.enumerated() {
            let base = index * 4
            bytes[base] = UInt8(min(255, max(0, pixel.b * 255)))
            bytes[base + 1] = UInt8(min(255, max(0, pixel.g * 255)))
            bytes[base + 2] = UInt8(min(255, max(0, pixel.r * 255)))
            bytes[base + 3] = UInt8(min(255, max(0, pixel.a * 255)))
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, image.width, image.height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: image.width * 4
        )
        return texture
    }

    private func readback(_ texture: MTLTexture) -> TransitionImage? {
        let width = texture.width
        let height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bytes,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        var pixels: [RGBA8] = []
        pixels.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let base = index * 4
            pixels.append(RGBA8(
                r: Double(bytes[base + 2]) / 255,
                g: Double(bytes[base + 1]) / 255,
                b: Double(bytes[base]) / 255,
                a: Double(bytes[base + 3]) / 255
            ))
        }
        return TransitionImage(width: width, height: height, pixels: pixels)
    }
    #else
    private func renderOnGPU(
        effect: TransitionShaderEffect,
        from: TransitionImage,
        to: TransitionImage,
        uniforms: TransitionUniforms
    ) -> TransitionImage? {
        nil
    }
    #endif
}
