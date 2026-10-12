#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct StudioGeometryTests {
    @Test
    func threeColumns_keepLibraryAndInspectorPinned() {
        let frames = DeskStudioGeometry.allocateThreeColumns(
            total: 1440,
            divider: 7,
            library: 240,
            inspector: 300
        )
        #expect(abs(frames.leftWidth - 240) < 0.001)
        #expect(abs(frames.rightWidth - 300) < 0.001)
        #expect(abs(frames.centerWidth - (1440 - 240 - 300 - 14)) < 0.001)
        #expect(abs(frames.leftOrigin) < 0.001)
        #expect(abs(frames.rightOrigin - (1440 - 300)) < 0.001)
        #expect(frames.leftOrigin < frames.centerOrigin)
        #expect(frames.centerOrigin < frames.rightOrigin)
    }

    @Test
    func threeColumns_windowGrowOnlyChangesCenter() {
        let narrow = DeskStudioGeometry.allocateThreeColumns(
            total: 1200,
            divider: 7,
            library: 240,
            inspector: 300
        )
        let wide = DeskStudioGeometry.allocateThreeColumns(
            total: 1600,
            divider: 7,
            library: 240,
            inspector: 300
        )
        #expect(abs(wide.leftWidth - narrow.leftWidth) < 0.001)
        #expect(abs(wide.rightWidth - narrow.rightWidth) < 0.001)
        #expect(wide.centerWidth - narrow.centerWidth == 400)
    }

    @Test
    func twoRows_keepMediaDrawerPinned() {
        let frames = DeskStudioGeometry.allocateTwoRows(
            total: 800,
            divider: 7,
            mediaDrawer: 248
        )
        #expect(abs(frames.bottomHeight - 248) < 0.001)
        #expect(abs(frames.topHeight - (800 - 7 - 248)) < 0.001)
        #expect(abs(frames.topOrigin) < 0.001)
        #expect(abs(frames.bottomOrigin - (800 - 248)) < 0.001)
    }
}
