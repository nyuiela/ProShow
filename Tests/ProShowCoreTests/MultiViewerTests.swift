#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreGraphics
import Foundation
import Testing

@Suite
struct MultiViewerTests {
    @Test
    func studioDefault_placesProgramPreviewAndMeters() {
        let camera = StudioVideoSource(label: "Host Cam", kind: .camera)
        let display = StudioVideoSource(label: "MacBook Screen", kind: .screenShare)
        let layout = MultiViewerLayout.studioDefault(sources: [camera, display])
        #expect(layout.grid == .programPreviewTop)
        #expect(layout.tiles.first?.type == .program)
        #expect(layout.tiles.dropFirst().first?.type == .preview)
        #expect(layout.tiles.contains { $0.type == .audioMeterBridge })
        #expect(layout.tiles.contains { $0.type == .cameraInput && $0.sourceId == camera.id.uuidString })
        #expect(layout.tiles.contains { $0.type == .displayShare && $0.sourceId == display.id.uuidString })
        #expect(layout.tiles.contains { $0.type == .stageMonitor })
    }

    @Test
    func studioDefault_respectsGridCapacity() {
        let sources = (0..<20).map { StudioVideoSource(label: "Cam \($0)", kind: .camera) }
        let layout = MultiViewerLayout.studioDefault(sources: sources, grid: .fourByFour)
        #expect(layout.grid == .fourByFour)
        #expect(layout.tiles.count <= MultiViewerGrid.fourByFour.capacity)
        #expect(layout.tiles.count == 16)
    }

    @Test
    func deviceDocument_decodesMissingMultiViewerAsEmpty() throws {
        var object = try JSONSerialization.jsonObject(with: try ProjectJSON.encoder.encode(DeviceSettingsDocument.default)) as? [String: Any] ?? [:]
        object.removeValue(forKey: "multiViewer")
        let decoded = try ProjectJSON.decoder.decode(
            DeviceSettingsDocument.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.multiViewer.tiles.isEmpty)
        #expect(decoded.multiViewer.grid == .programPreviewTop)
    }

    @Test
    func screensSettings_matchMultiViewerKeyword() {
        #expect(SettingsCategory.screens.matches("multiviewer"))
        #expect(ScreenTargetType.multiViewer.title.contains("MultiViewer"))
    }

    @Test
    func gridEngine_uniformTilesShareSizeAndStaySixteenByNine() {
        let frames = MultiViewerGridEngine.calculateGridFrames(
            containerSize: CGSize(width: 1600, height: 900),
            preset: .threeByThree
        )
        #expect(frames.count == 9)
        let first = frames[0].rect
        #expect(abs((first.width / first.height) - (16.0 / 9.0)) < 0.02)
        #expect(frames.allSatisfy { $0.rect.width == first.width && $0.rect.height == first.height })
        #expect(frames.allSatisfy { $0.rect.minX >= 0 && $0.rect.minY >= 0 })
        let last = frames[8].rect
        #expect(last.maxX <= 1600)
        #expect(last.maxY <= 900)
    }

    @Test
    func gridEngine_programPreviewHasTwoLargeAndSixSmall() {
        let frames = MultiViewerGridEngine.calculateGridFrames(
            containerSize: CGSize(width: 1600, height: 900),
            preset: .programPreviewTop
        )
        #expect(frames.count == 8)
        #expect(frames[0].isLargeTopTile)
        #expect(frames[1].isLargeTopTile)
        #expect(frames[0].rect.width > frames[2].rect.width)
        #expect(abs((frames[0].rect.width / frames[0].rect.height) - (16.0 / 9.0)) < 0.02)
        #expect(abs((frames[2].rect.width / frames[2].rect.height) - (16.0 / 9.0)) < 0.02)
    }

    @Test
    func studioGlass_splitsEvenCountsIntoEqualCells() {
        let four = StudioGlassLayout.frames(count: 4, in: CGSize(width: 1000, height: 800))
        #expect(four.count == 4)
        #expect(four[0].width == four[1].width)
        #expect(four[0].height == four[2].height)
        #expect(abs(four[0].width - four[2].width) < 0.01)

        let two = StudioGlassLayout.frames(count: 2, in: CGSize(width: 1000, height: 600))
        #expect(two.count == 2)
        #expect(abs(two[0].width - two[1].width) < 0.01)
        #expect(abs(two[0].height - two[1].height) < 0.01)

        let six = StudioGlassLayout.frames(count: 6, in: CGSize(width: 1200, height: 800))
        #expect(six.count == 6)
        #expect(abs(six[0].width - six[5].width) < 0.01)
        #expect(abs(six[0].height - six[5].height) < 0.01)
    }

    @Test
    func studioGlass_fillsAShortLastRow() {
        let five = StudioGlassLayout.frames(count: 5, in: CGSize(width: 900, height: 600))
        #expect(five.count == 5)
        #expect(abs(five[0].width - five[1].width) < 0.01)
        #expect(abs(five[3].width - five[4].width) < 0.01)
        #expect(five[3].width > five[0].width)
        let right = five[4].maxX
        let left = five[3].minX
        #expect(right - left > five[0].width)
    }

    @Test
    func studioSlides_keepVideoSixteenByNine() {
        let wide = StudioSlidePairLayout.layout(in: CGSize(width: 800, height: 420))
        let tall = StudioSlidePairLayout.layout(in: CGSize(width: 280, height: 720))
        #expect(wide.sideBySide)
        #expect(tall.sideBySide == false)
        for layout in [wide, tall] {
            let ratio = layout.videoSize.width / layout.videoSize.height
            #expect(abs(ratio - (16.0 / 9.0)) < 0.02)
        }
        let widePair = wide.videoSize.width * 2 + StudioSlidePairLayout.pairGap + StudioSlidePairLayout.horizontalInset
        #expect(widePair <= 800.5)
        let tallChrome = StudioSlidePairLayout.playlistChrome
            + StudioSlidePairLayout.bottomInset
            + StudioSlidePairLayout.cardChrome * 2
            + StudioSlidePairLayout.pairGap
        #expect(tall.videoSize.height * 2 + tallChrome <= 720.5)
        #expect(abs(tall.videoSize.width - (280 - StudioSlidePairLayout.horizontalInset)) < 1)
    }

    @Test
    func studioLive_putsLayersBesideASixteenByNinePictureWhenWide() {
        let wide = StudioLiveLayout.layout(in: CGSize(width: 900, height: 400))
        #expect(wide.sideBySide)
        let ratio = wide.videoSize.width / wide.videoSize.height
        #expect(abs(ratio - (16.0 / 9.0)) < 0.02)
        let used = wide.videoSize.width + StudioLiveLayout.gap + wide.layersWidth
        #expect(used <= 900 - StudioLiveLayout.horizontalInset + 0.5)
        #expect(wide.previewHeight <= 400.5)

        let narrow = StudioLiveLayout.layout(in: CGSize(width: 320, height: 500))
        #expect(narrow.sideBySide == false)
        let narrowRatio = narrow.videoSize.width / narrow.videoSize.height
        #expect(abs(narrowRatio - (16.0 / 9.0)) < 0.02)
        #expect(narrow.videoSize.width <= 320 - StudioLiveLayout.horizontalInset + 0.5)

        let short = StudioLiveLayout.layout(in: CGSize(width: 360, height: 180))
        let shortRatio = short.videoSize.width / max(short.videoSize.height, 1)
        #expect(abs(shortRatio - (16.0 / 9.0)) < 0.02)
        #expect(short.videoSize.height > 90)
        #expect(short.videoSize.width <= 360 - StudioLiveLayout.horizontalInset + 0.5)
    }

    @Test
    func assignedDisplay_usesEnabledMultiViewerTarget() {
        var document = DeviceSettingsDocument.default
        document.screens = [
            OutputScreenConfig(displayIndex: 0, name: "Built-in", targetType: .audienceProgram),
            OutputScreenConfig(displayIndex: 2, name: "Control", targetType: .multiViewer, isEnabled: true),
        ]
        #expect(document.assignedMultiViewerDisplayIndex == 2)
    }
}
