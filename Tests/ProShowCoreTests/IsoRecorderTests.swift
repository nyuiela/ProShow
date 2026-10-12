#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import Foundation
import Testing

@Suite
struct IsoRecorderTests {
    @Test @MainActor
    func programAndISO_recordAt4K60() {
        let recorder = IsoRecorder()
        let takes = recorder.start(
            program: true,
            isolatedSourceIDs: [StudioSeedID.camera, StudioSeedID.cameraB],
            codec: .prores,
            width: 3840,
            height: 2160,
            fps: 60
        )
        #expect(recorder.isRecording)
        #expect(takes.count == 3)
        #expect(recorder.programTake?.width == 3840)
        #expect(recorder.programTake?.fps == 60)
        #expect(recorder.isolatedTakes.count == 2)
        recorder.stop()
        #expect(!recorder.isRecording)
    }

    @Test
    func streamRecording_filenameUsesProjectAndTimestamp() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = StreamRecordingPaths.filename(projectName: "Sunday AM", startedAt: date)
        #expect(name.hasPrefix("Sunday AM_"))
        #expect(name.hasSuffix(".mp4"))
        let bad = StreamRecordingPaths.filename(projectName: "Live: Test/Show", startedAt: date)
        #expect(!bad.contains(":"))
        #expect(!bad.contains("/"))
    }

    @Test @MainActor
    func programTake_writesRealRecordingFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let recorder = IsoRecorder()
        recorder.outputDirectory = folder
        _ = recorder.start(program: true, isolatedSourceIDs: [], codec: .h264, width: 160, height: 90, fps: 30)
        #if canImport(CoreVideo)
        if let frame = ZeroCopyMetalPipeline.makeCompatiblePixelBuffer(width: 160, height: 90) {
            recorder.appendProgramFrame(frame, presentationTime: 0)
            recorder.appendProgramFrame(frame, presentationTime: 1.0 / 30.0)
        }
        #endif
        recorder.stop()
        let url = try #require(recorder.programFileURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect((size?.intValue ?? 0) > 32)
    }

    @Test @MainActor
    func virtualCamera_waitsForCoreMediaIOExtension() {
        let cam = VirtualCameraSink()
        cam.start()
        let latency = cam.publishFrame(compositedAt: 1.000, deliveredAt: 1.012)
        #expect(!cam.isPublished)
        #expect(cam.needsExtension)
        #expect(cam.blockedReason != nil)
        #expect(cam.framesPublished == 0)
        #expect(latency < StudioPerformance.maxVirtualCamLatencyMs)
        #expect(cam.width == 3840)
        #expect(cam.fps == 60)
        cam.installExtensionForTests()
        #expect(cam.isPublished)
        _ = cam.publishFrame(compositedAt: 2.000, deliveredAt: 2.008)
        #expect(cam.framesPublished == 1)
    }
}
