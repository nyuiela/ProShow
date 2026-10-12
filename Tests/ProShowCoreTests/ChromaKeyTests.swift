#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct ChromaKeyTests {
    @Test
    func greenScreen_dropsKeyedPixelsAndKeepsTalent() {
        let engine = VideoFilterEngine()
        let keyed = engine.applyChroma(pixel: RGBA8(r: 0, g: 1, b: 0, a: 1), settings: .green)
        let talent = engine.applyChroma(pixel: RGBA8(r: 0.82, g: 0.42, b: 0.31, a: 1), settings: .green)
        #expect(keyed.a < 0.05)
        #expect(talent.a > 0.9)
        #expect(engine.chromaAlpha(pixel: RGBA8(r: 0, g: 0, b: 1, a: 1), settings: .blue) < 0.05)
    }

    @Test
    func cubeLUT_andGrade_adjustExposureContrastSaturation() throws {
        let engine = VideoFilterEngine()
        let cube = """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try #require(LUT3D.parseCUBE(cube))
        engine.lut = lut
        engine.grade = ColorGradeSettings(exposure: 1, contrast: 1.2, saturation: 1.1, sharpness: 0.4, backgroundBlur: 0.2)
        let lifted = engine.applyGrade(pixel: RGBA8(r: 0.4, g: 0.4, b: 0.4, a: 1))
        #expect(lifted.r > 0.4)
        let identity = LUT3D.identity()
        let mapped = identity.sample(r: 1, g: 0, b: 0)
        #expect(mapped.r == 1)
        #expect(mapped.g == 0)
    }
}
