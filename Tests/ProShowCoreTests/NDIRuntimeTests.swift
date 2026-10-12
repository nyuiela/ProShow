#if canImport(ProShowCore)
@testable import ProShowCore
#else
@testable import ProShow
#endif
import CoreVideo
import Foundation
import Testing

@Suite
struct NDIRuntimeTests {
    @Test
    func activate_withoutLiveIO_staysUnsupported() {
        NDIRuntime.resetForTests()
        let ndi = VideoInputSource(id: UUID(), label: "NDI 1", kind: .ndi, endpoint: "ndi://studio")
        if case .unsupported = VideoInputRuntime.activate(ndi) {
            #expect(true)
        } else {
            Issue.record("NDI must stay unsupported until live I/O loads the C-SDK")
        }
    }

    @Test
    func load_withoutSDK_returnsFalse() {
        NDIRuntime.resetForTests()
        if NDIRuntime.libraryURL() == nil {
            #expect(!NDIRuntime.load())
            #expect(NDIRuntime.findSources().isEmpty)
            #expect(NDIRuntime.version() == nil)
        } else {
            #expect(NDIRuntime.isAvailable)
        }
    }

    @Test @MainActor
    func ingest_doesNotOpenNDIUntilHardwareEnabled() {
        NDIRuntime.resetForTests()
        let engine = VideoIngestEngine()
        let source = StudioVideoSource(label: "Studio", kind: .ndi, endpoint: "ndi://studio")
        if case .unsupported = engine.start(source) {
            #expect(engine.lastFrame == nil)
        } else if NDIRuntime.isAvailable {
            Issue.record("NDI started without hardwareEnabled")
        }
        #expect(!NDIRuntime.hardwareEnabled)
    }

    @Test
    func videoFrameLayoutMatchesNDIABI() {
        #expect(MemoryLayout<NDIVideoFrameV2>.size == 72)
        #expect(MemoryLayout<NDIRecvCreateV3>.size == 40)
        #expect(MemoryLayout<NDISendCreate>.size == 24)
    }

    @Test
    func pixelCopy_keepsBGRABytes() {
        var bytes: [UInt8] = [10, 20, 30, 255, 1, 2, 3, 255]
        let buffer = bytes.withUnsafeMutableBytes { raw -> CVPixelBuffer? in
            guard let base = raw.baseAddress else { return nil }
            return NDIPixelCopy.pixelBuffer(
                fourCC: NDIFourCC.bgra,
                width: 2,
                height: 1,
                data: base,
                stride: 8
            )
        }
        #expect(buffer != nil)
        guard let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pixel = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        #expect(pixel[0] == 10)
        #expect(pixel[1] == 20)
        #expect(pixel[2] == 30)
        #expect(pixel[3] == 255)
    }

    @Test
    func programSender_staysClosedWhenDisabled() {
        NDIRuntime.resetForTests()
        NDIProgramSender.shared.sync(enabled: false, name: "PROSHOW-MAIN-OUT")
        #expect(!NDIRuntime.hardwareEnabled)
    }
}
