import Foundation
import Observation
#if canImport(CoreVideo)
import CoreVideo
#endif

/// Describes formats exposed by the CoreMediaIO DAL extension (`ProShow Virtual Camera`).
enum VirtualCameraFormat: String, CaseIterable, Sendable {
    case hd1080p60 = "1920x1080@60"
    case hd1080p30 = "1920x1080@30"
    case hd720p60 = "1280x720@60"

    var width: Int {
        switch self {
        case .hd1080p60, .hd1080p30: 1920
        case .hd720p60: 1280
        }
    }

    var height: Int {
        switch self {
        case .hd1080p60, .hd1080p30: 1080
        case .hd720p60: 720
        }
    }

    var fps: Int {
        switch self {
        case .hd1080p60, .hd720p60: 60
        case .hd1080p30: 30
        }
    }

    var pixelFormat: UInt32 { kCVPixelFormatType_32BGRA }
}

/// Transport surface for a future CMIOExtension process. The app target enqueues compositor frames here.
protocol CMIOVirtualCameraTransport: AnyObject, Sendable {
    func publish(pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval) -> Bool
}

/// Bridges `CompositorEngine` program frames into `VirtualCameraSink` and (when installed) the DAL extension.
@MainActor
@Observable
final class VirtualCameraOutputService {
    /// Read from the output bus. When this is false the bus must not retain the program frame for a later hop.
    nonisolated(unsafe) static var acceptsProgramFrames = false
    let deviceName = "ProShow Virtual Camera"
    var activeFormat: VirtualCameraFormat = .hd1080p60
    var transport: CMIOVirtualCameraTransport?
    private let sink: VirtualCameraSink

    init(sink: VirtualCameraSink) {
        self.sink = sink
    }

    func syncProjectOutput(width: Int, height: Int, fps: Int) {
        sink.width = width
        sink.height = height
        sink.fps = fps
        activeFormat = Self.format(matchingWidth: width, height: height, fps: fps)
    }

    func setPublishing(_ enabled: Bool) {
        Self.acceptsProgramFrames = enabled
        if enabled {
            sink.start(width: activeFormat.width, height: activeFormat.height, fps: activeFormat.fps)
        } else {
            sink.stop()
        }
    }

    #if canImport(CoreVideo)
    @discardableResult
    func enqueueProgramFrame(_ buffer: CVPixelBuffer, compositedAt: TimeInterval, deliveredAt: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Double {
        let latency = sink.publishFrame(compositedAt: compositedAt, deliveredAt: deliveredAt)
        guard sink.isPublished else { return latency }
        _ = transport?.publish(pixelBuffer: buffer, presentationTime: deliveredAt)
        return latency
    }
    #endif

    var extensionInstalled: Bool { sink.extensionAvailable }
    var needsExtension: Bool { sink.needsExtension }
    var blockedReason: String? { sink.blockedReason }

    private static func format(matchingWidth width: Int, height: Int, fps: Int) -> VirtualCameraFormat {
        if width >= 1920, height >= 1080, fps >= 55 { return .hd1080p60 }
        if width >= 1920, height >= 1080 { return .hd1080p30 }
        return .hd720p60
    }
}
