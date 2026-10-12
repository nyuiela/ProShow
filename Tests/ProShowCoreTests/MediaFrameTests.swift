#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct MediaFrameTests {
    @Test
    func imageCornerRadius_resolvesOnMediaObjects() {
        var image = CanvasObject(
            name: "Clip",
            kind: .image,
            bounds: CanvasBounds(x: 0, y: 0, width: 1280, height: 720)
        )
        #expect(image.resolvedCornerRadii.maxRadius == 0)
        image.stroke.cornerRadius = 48
        image.stroke.corners = .uniform(48)
        #expect(image.usesRoundedMediaFrame)
        #expect(image.isMediaLike)
        #expect(image.resolvedCornerRadii.topLeft == 48)

        let style = MediaFrameStyle.from(image, scale: 0.5)
        #expect(abs(style.cornerRadius - 24) < 0.001)
    }

    @Test
    func cropContentsRect_honorsZoomAndOffset() {
        let centered = MediaFrameStyle(
            cornerRadius: 0,
            continuous: true,
            scaleMode: .crop,
            opacity: 1,
            cropX: 0.5,
            cropY: 0.5,
            cropZoom: 2
        )
        let rect = MediaFrameEngine.contentsRect(for: centered)
        #expect(abs(rect.width - 0.5) < 0.001)
        #expect(abs(rect.origin.x - 0.25) < 0.001)

        let fit = MediaFrameStyle(
            cornerRadius: 12,
            continuous: true,
            scaleMode: .fit,
            opacity: 0.8,
            cropX: 0.2,
            cropY: 0.8,
            cropZoom: 3
        )
        let full = MediaFrameEngine.contentsRect(for: fit)
        #expect(full == CGRect(x: 0, y: 0, width: 1, height: 1))
        let fill = MediaFrameStyle.plain
        #expect(MediaFrameEngine.contentsRect(for: fill) == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(ImageScaleMode.crop.cropsToFrame)
        #expect(ImageScaleMode.fill.cropsToFrame)
        #expect(!ImageScaleMode.fit.cropsToFrame)
        #expect(MediaFrameStyle.plain.scaleMode == .fill)
    }

    @Test
    func assignedCamera_isMediaLikeForCropControls() {
        var shape = CanvasObject(
            name: "Cam Frame",
            kind: .rectangle,
            bounds: CanvasBounds(x: 0, y: 0, width: 640, height: 360)
        )
        shape.assignedSource = AssignedMediaSource(
            sourceID: "avf-video-mac",
            name: "MacBook Pro Camera",
            sourceType: .systemCamera,
            category: .videoCapture,
            connectionString: "avf://mac-cam"
        )
        #expect(shape.isMediaLike)
        shape.fill.imageScaleMode = .crop
        shape.fill.cropZoom = 2
        shape.fill.cropX = 0.25
        let style = MediaFrameStyle.from(shape, scale: 1)
        #expect(style.scaleMode == .crop)
        let rect = MediaFrameEngine.contentsRect(for: style)
        #expect(abs(rect.width - 0.5) < 0.001)
        #expect(rect.origin.x < 0.25)
    }

    @Test
    func slotDecodeBudget_capsConcurrentPlayersAtThree() {
        SlotDecodeBudget.resetForTests()
        defer { SlotDecodeBudget.endTestIsolation() }
        let objects = [NSObject(), NSObject(), NSObject(), NSObject()]
        let ids = objects.map(ObjectIdentifier.init)
        #expect(SlotDecodeBudget.acquire(ids[0], priority: 1, visible: true))
        #expect(SlotDecodeBudget.acquire(ids[1], priority: 2, visible: true))
        #expect(SlotDecodeBudget.acquire(ids[2], priority: 3, visible: true))
        #expect(!SlotDecodeBudget.acquire(ids[3], priority: 0, visible: true))
        #expect(SlotDecodeBudget.activeCount == 3)
        SlotDecodeBudget.release(ids[0])
        #expect(SlotDecodeBudget.acquire(ids[3], priority: 4, visible: true))
    }
}
