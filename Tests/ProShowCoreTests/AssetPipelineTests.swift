#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct AssetPipelineTests {
    @Test
    func posterTime_isTenPercent() {
        #expect(AssetPreview.posterTime(durationSeconds: 40) == 4)
        #expect(AssetPreview.posterTime(durationSeconds: 0) == 0)
    }

    @Test
    func waveformPeaks_bucketMax() {
        let peaks = AssetPreview.waveformPeaks(samples: [0.1, -0.5, 0.2, 0.05], bucketCount: 2)
        #expect(peaks.count == 2)
        #expect(peaks[0] == 0.5)
    }

    @Test
    func imageThumbnail_writesFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let png = try TestSupport.writePNGFixture(in: dir)
        let dest = dir.appendingPathComponent("thumb.png")
        let written = try AssetPreview.writeThumbnail(from: png, to: dest)
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test
    func videoPoster_writesFileFromSolidClip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let video = try AssetPreview.writeSolidVideo(
            to: dir.appendingPathComponent("clip.mp4"),
            width: 160,
            height: 90,
            seconds: 0.4,
            fps: 10
        )
        #expect(FileManager.default.fileExists(atPath: video.path))
        let dest = dir.appendingPathComponent("poster.png")
        let written = try AssetPreview.writeVideoPoster(from: video, to: dest)
        #expect(FileManager.default.fileExists(atPath: written.path))
    }

    @Test
    func markLogo_isLargerThanOnePixel() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-logo.png")
        try AssetPreview.writeMarkPNG(to: dest, size: 128)
        let data = try Data(contentsOf: dest)
        #expect(data.count > 200)
    }

    @Test
    func audioWaveform_readsRealPeaks() throws {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-tone.wav")
        try DefaultSeedData.writeToneWAV(to: dest)
        let peaks = try AssetPreview.waveformPeaks(fromAudioFile: dest, bucketCount: 16)
        #expect(peaks.count == 16)
        #expect(peaks.contains(where: { $0 > 0.05 }))
    }

    @Test
    func pptxImport_extractsSlideText() throws {
        let slideXML = """
        <?xml version="1.0"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree>
            <p:sp><p:txBody><a:p><a:r><a:t>Grace and peace</a:t></a:r></a:p></p:txBody></p:sp>
          </p:spTree></p:cSld>
        </p:sld>
        """
        let zip = StoredZip.pack([
            "[Content_Types].xml": Data("<Types/>".utf8),
            "ppt/slides/slide1.xml": Data(slideXML.utf8),
        ])
        let show = try PresentationImport.parsePPTX(zip)
        #expect(show.groups[0].slides[0].lines.contains("Grace and peace"))
    }

    @Test
    func storedZip_roundTrip() {
        let packed = StoredZip.pack(["hello.txt": Data("world".utf8)])
        #expect(StoredZip.unpack(packed)["hello.txt"] == Data("world".utf8))
    }
}
