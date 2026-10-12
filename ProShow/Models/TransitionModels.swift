import Foundation
import simd

enum TransitionEngineKind: String, Codable, CaseIterable, Sendable {
    case standard
    case gpuShader
    case coreImage
    case lottie
    case alphaStinger

    var title: String {
        switch self {
        case .standard: "Standard"
        case .gpuShader: "GPU Shaders"
        case .coreImage: "Core Image"
        case .lottie: "Vector Lottie"
        case .alphaStinger: "AE Stingers"
        }
    }
}

enum TransitionShaderEffect: String, Codable, CaseIterable, Sendable {
    case whipPan
    case liquidRipple
    case glitch
    case crossZoom
    case lightLeak

    var metalFunction: String {
        switch self {
        case .whipPan: "whipPanTransition"
        case .liquidRipple: "liquidRippleTransition"
        case .glitch: "glitchTransition"
        case .crossZoom: "crossZoomTransition"
        case .lightLeak: "lightLeakTransition"
        }
    }
}

enum CoreImageTransitionKind: String, Codable, CaseIterable, Sendable {
    case pageCurl
    case displace
    case ripple
    case lensFlare
}

struct TransitionUniforms: Hashable, Sendable {
    var progress: Float
    var duration: Float
    var resolution: SIMD2<Float>
    var intensity: Float

    static func make(progress: Double, duration: Double = 1, width: Int = 3840, height: Int = 2160, intensity: Double = 1) -> TransitionUniforms {
        TransitionUniforms(
            progress: Float(min(1, max(0, progress))),
            duration: Float(max(duration, 0.001)),
            resolution: SIMD2(Float(width), Float(height)),
            intensity: Float(intensity)
        )
    }
}

struct TransitionPreset: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var category: TransitionEngineKind
    var systemImage: String
    var shader: TransitionShaderEffect? = nil
    var coreImage: CoreImageTransitionKind? = nil
    var defaultDurationMs: Int
    var intensity: Double

    var title: String { name }
}

enum TransitionCatalog {
    static let all: [TransitionPreset] = standard + gpuShaders + coreImage + lottie + stingers

    static let standard: [TransitionPreset] = [
        TransitionPreset(id: "cut", name: "Cut", category: .standard, systemImage: "square.split.2x1", defaultDurationMs: 0, intensity: 1),
        TransitionPreset(id: "dissolve", name: "Dissolve", category: .standard, systemImage: "circle.lefthalf.filled", defaultDurationMs: 600, intensity: 1),
        TransitionPreset(id: "push", name: "Push", category: .standard, systemImage: "arrow.right.to.line", defaultDurationMs: 500, intensity: 1),
        TransitionPreset(id: "fade", name: "Fade", category: .standard, systemImage: "sun.min", defaultDurationMs: 700, intensity: 1),
        TransitionPreset(id: "wipe", name: "Wipe", category: .standard, systemImage: "rectangle.righthalf.inset.filled", defaultDurationMs: 500, intensity: 1),
    ]

    static let gpuShaders: [TransitionPreset] = [
        TransitionPreset(id: "whip_pan", name: "Whip Pan", category: .gpuShader, systemImage: "wind", shader: .whipPan, defaultDurationMs: 450, intensity: 1),
        TransitionPreset(id: "liquid", name: "Liquid Ripple", category: .gpuShader, systemImage: "water.waves", shader: .liquidRipple, defaultDurationMs: 800, intensity: 0.85),
        TransitionPreset(id: "glitch", name: "Glitch", category: .gpuShader, systemImage: "waveform.path.ecg", shader: .glitch, defaultDurationMs: 400, intensity: 1),
        TransitionPreset(id: "cross_zoom", name: "Cross Zoom", category: .gpuShader, systemImage: "arrow.up.left.and.arrow.down.right", shader: .crossZoom, defaultDurationMs: 650, intensity: 0.9),
        TransitionPreset(id: "light_leak", name: "Light Leak", category: .gpuShader, systemImage: "sun.max.fill", shader: .lightLeak, defaultDurationMs: 900, intensity: 0.75),
    ]

    static let coreImage: [TransitionPreset] = [
        TransitionPreset(id: "page_curl", name: "Page Curl", category: .coreImage, systemImage: "book", coreImage: .pageCurl, defaultDurationMs: 900, intensity: 1),
        TransitionPreset(id: "displace", name: "Displace", category: .coreImage, systemImage: "square.stack.3d.forward.dottedline", coreImage: .displace, defaultDurationMs: 700, intensity: 0.8),
        TransitionPreset(id: "ripple", name: "Ripple", category: .coreImage, systemImage: "drop", coreImage: .ripple, defaultDurationMs: 800, intensity: 0.7),
        TransitionPreset(id: "lens_flare", name: "Lens Flare", category: .coreImage, systemImage: "sparkle", coreImage: .lensFlare, defaultDurationMs: 750, intensity: 0.65),
    ]

    static let lottie: [TransitionPreset] = [
        TransitionPreset(id: "lottie_wipe", name: "Vector Wipe", category: .lottie, systemImage: "scribble.variable", defaultDurationMs: 700, intensity: 1),
    ]

    static let stingers: [TransitionPreset] = [
        TransitionPreset(id: "stinger_flame", name: "Flame Stinger", category: .alphaStinger, systemImage: "flame.fill", defaultDurationMs: 1000, intensity: 1),
    ]

    static func preset(id: String) -> TransitionPreset {
        let key = id.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        return all.first { $0.id == key || $0.name.compare(id, options: .caseInsensitive) == .orderedSame }
            ?? standard[0]
    }

    static func physicsStyle(forPresetID id: String) -> TransitionPhysicsStyle {
        switch preset(id: id).id {
        case "cut": .cut
        case "push": .pushLeft
        case "cross_zoom": .smoothZoomScale
        default: .dissolve
        }
    }
}

struct TransitionImage: Hashable, Sendable {
    var width: Int
    var height: Int
    var pixels: [RGBA8]

    init(width: Int, height: Int, pixels: [RGBA8]) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.pixels = pixels
    }

    static func solid(_ color: RGBA8, width: Int, height: Int) -> TransitionImage {
        TransitionImage(width: width, height: height, pixels: Array(repeating: color, count: width * height))
    }

    func sample(u: Double, v: Double) -> RGBA8 {
        let x = min(width - 1, max(0, Int((u * Double(width - 1)).rounded())))
        let y = min(height - 1, max(0, Int((v * Double(height - 1)).rounded())))
        return pixels[y * width + x]
    }

    func pixel(at index: Int) -> RGBA8 {
        pixels[min(pixels.count - 1, max(0, index))]
    }
}

struct TransitionThemeColors: Hashable, Sendable {
    var primary: RGBA8
    var accent: RGBA8

    static let desk = TransitionThemeColors(
        primary: RGBA8(r: 0.42, g: 0.624, b: 0.878, a: 1),
        accent: RGBA8(r: 0.788, g: 0.635, b: 0.29, a: 1)
    )
}

enum TransitionBindingWorkspace: String, Codable, Sendable {
    case slideInspector
    case sceneManager
    case mapMatrix
}

/// Live A→B program transition. Progress is written on the program clock.
struct ProgramTransitionState: Equatable, Sendable {
    var preset: TransitionPreset
    var duration: TimeInterval
    var startedAt: Date
    var outgoing: RenderStack
    var progress: Double

    var isActive: Bool { duration > 0.02 && progress < 1 }

    mutating func tick(now: Date = Date()) {
        progress = duration <= 0 ? 1 : min(1, max(0, now.timeIntervalSince(startedAt) / duration))
    }
}
