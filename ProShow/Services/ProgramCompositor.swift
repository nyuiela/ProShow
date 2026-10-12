import Foundation
#if canImport(Metal)
import Metal
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif

struct ProgramFrame: Hashable, Sendable {
    var index: Int
    var hostTime: TimeInterval
    var playhead: TimeInterval
    var outputWidth: Int
    var outputHeight: Int
    var visibleLayers: [Int]
    var mediaTitle: String?
    var textureAllocated: Bool
    var backend: String
    var leftMeter: Double
    var rightMeter: Double
}

struct ProgramRaster: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixels: [RGBA8]
    var coveredLayers: [Int]

    func pixel(x: Int, y: Int) -> RGBA8 {
        pixels[y * width + x]
    }
}

enum ProgramRasterizer {
    static func composite(
        stack: RenderStack,
        width: Int,
        height: Int,
        playhead: TimeInterval,
        filters: VideoFilterEngine? = nil,
        videoFrame: VideoIngestFrame? = nil
    ) -> ProgramRaster {
        let count = max(1, width * height)
        var pixels = Array(repeating: RGBA8(r: 0, g: 0, b: 0, a: 1), count: count)
        var covered: [Int] = []

        func fill(_ color: RGBA8) {
            if color.a >= 0.999 {
                pixels = Array(repeating: color, count: pixels.count)
                return
            }
            for index in pixels.indices {
                pixels[index] = blend(pixels[index], over: color)
            }
        }

        func fillBand(y0: Int, y1: Int, _ color: RGBA8) {
            let top = min(max(0, y0), height)
            let bottom = min(max(0, y1), height)
            guard top < bottom else { return }
            for y in top..<bottom {
                for x in 0..<width {
                    let index = y * width + x
                    pixels[index] = blend(pixels[index], over: color)
                }
            }
        }

        if stack.isVisible(.screenColor, onStage: false) {
            fill(RGBA8.from(hex: stack.screenColorHex))
            covered.append(RenderLayer.screenColor.rawValue)
        }
        if stack.isVisible(.videoInput, onStage: false), stack.videoInput != nil {
            var keyed = videoFrame?.sample ?? RGBA8(r: 0, g: 1, b: 0, a: 1)
            if let filters {
                keyed = filters.applyChroma(pixel: keyed)
            }
            fillBand(y0: 0, y1: height / 2, keyed)
            covered.append(RenderLayer.videoInput.rawValue)
        }
        if stack.drawsProgramMediaBackdrop(onStage: false), let media = stack.media {
            var tint = RGBA8.from(hex: media.tintHex)
            tint.a = 0.88
            fill(tint)
            covered.append(RenderLayer.media.rawValue)
            _ = playhead
        }
        if stack.isVisible(.slide, onStage: false), !stack.slideElements.isEmpty || !stack.slideCanvas.isEmpty {
            if stack.slideBackgroundEnabled {
                fill(RGBA8.from(hex: stack.slideBackgroundHex))
            }
            if !stack.slideElements.isEmpty {
                fillBand(y0: height / 3, y1: (height * 2) / 3, RGBA8(r: 1, g: 1, b: 1, a: 0.92))
            }
            covered.append(RenderLayer.slide.rawValue)
        }
        if stack.isVisible(.announcements, onStage: false), stack.announcement != nil {
            fillBand(y0: height - max(2, height / 8), y1: height, RGBA8(r: 0, g: 0, b: 0, a: 0.55))
            covered.append(RenderLayer.announcements.rawValue)
        }
        if stack.isVisible(.props, onStage: false), !stack.activeProps.isEmpty {
            fillBand(y0: 0, y1: max(2, height / 10), RGBA8(r: 1, g: 1, b: 1, a: 0.35))
            covered.append(RenderLayer.props.rawValue)
        }
        if stack.isVisible(.messages, onStage: false), stack.message != nil {
            fillBand(y0: 0, y1: max(2, height / 12), RGBA8(r: 0.9, g: 0.28, b: 0.28, a: 0.9))
            covered.append(RenderLayer.messages.rawValue)
        }
        if stack.isVisible(.mask, onStage: false), stack.maskEnabled {
            fill(RGBA8(r: 0, g: 0, b: 0, a: 0.2))
            covered.append(RenderLayer.mask.rawValue)
        }

        return ProgramRaster(width: width, height: height, pixels: pixels, coveredLayers: covered)
    }

    private static func blend(_ under: RGBA8, over: RGBA8) -> RGBA8 {
        let a = over.a
        let inv = 1 - a
        return RGBA8(
            r: over.r * a + under.r * inv,
            g: over.g * a + under.g * inv,
            b: over.b * a + under.b * inv,
            a: min(1, over.a + under.a * inv)
        )
    }
}

extension RGBA8 {
    static func from(hex: String) -> RGBA8 {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6 || cleaned.count == 8, let value = UInt64(cleaned, radix: 16) else {
            return RGBA8(r: 0, g: 0, b: 0, a: 1)
        }
        if cleaned.count == 8 {
            return RGBA8(
                r: Double((value >> 16) & 0xFF) / 255,
                g: Double((value >> 8) & 0xFF) / 255,
                b: Double(value & 0xFF) / 255,
                a: Double((value >> 24) & 0xFF) / 255
            )
        }
        return RGBA8(
            r: Double((value >> 16) & 0xFF) / 255,
            g: Double((value >> 8) & 0xFF) / 255,
            b: Double(value & 0xFF) / 255,
            a: 1
        )
    }
}

/// Allocates program MTLTextures and runs chroma via Metal when the shader is compiled in.
@MainActor
final class ProgramTextureRenderer {
    private(set) var backend: String = "cpu"
    private(set) var textureWidth: Int = 0
    private(set) var textureHeight: Int = 0
    private(set) var textureAllocated: Bool = false
    private var attemptedLibrary = false
    private let zeroCopy = ZeroCopyMetalPipeline()
    private let tripleBuffer = TripleBufferManager.Gate()

    #if canImport(Metal)
    private var device: MTLDevice?
    private var texture: MTLTexture?
    private var textures: [MTLTexture?] = [nil, nil, nil]
    private var pipeline: MTLComputePipelineState?
    #endif

    func ensureTextures(width: Int, height: Int) {
        textureWidth = width
        textureHeight = height
        #if canImport(Metal)
        if device == nil {
            device = MTLCreateSystemDefaultDevice()
        }
        guard let device else {
            backend = "cpu"
            textureAllocated = false
            return
        }
        if texture == nil || texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: max(1, width),
                height: max(1, height),
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            texture = device.makeTexture(descriptor: descriptor)
        }
        textureAllocated = texture != nil
        if pipeline == nil, !attemptedLibrary {
            attemptedLibrary = true
            if let library = device.makeDefaultLibrary(),
               let function = library.makeFunction(name: "chroma_key") {
                pipeline = try? device.makeComputePipelineState(function: function)
            }
        }
        backend = pipeline != nil ? "metal" : (textureAllocated ? "cpu+texture" : "cpu")
        #else
        backend = "cpu"
        textureAllocated = false
        #endif
    }

    func ingest(pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else { return }
        guard let index = tripleBuffer.tryBeginFrame() else { return }
        defer { tripleBuffer.endFrame() }
        #if canImport(Metal)
        if let mapped = zeroCopy.createTexture(from: pixelBuffer) {
            textures[index] = mapped
            texture = mapped
            textureAllocated = true
            backend = "metal-zerocopy"
        }
        #endif
    }

    func matches(_ descriptor: RenderTextureDescriptor) -> Bool {
        textureWidth == descriptor.width && textureHeight == descriptor.height
    }

    func applyChroma(_ pixel: RGBA8, filters: VideoFilterEngine) -> RGBA8 {
        filters.applyChroma(pixel: pixel)
    }
}

