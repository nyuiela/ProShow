import CoreGraphics
import Foundation

/// Locked dimensions for compositor, VideoToolbox, and program `.mov`.
struct ProgramRenderContract: Equatable, Sendable, Codable {
    var width: Int
    var height: Int
    var frameRate: Int
    var colorSpace: String

    var aspectRatio: CGFloat {
        guard height > 0 else { return 16.0 / 9.0 }
        return CGFloat(width) / CGFloat(height)
    }

    static let hd1080p30 = ProgramRenderContract(width: 1920, height: 1080, frameRate: 30, colorSpace: "Rec709")
    static let hd720p30 = ProgramRenderContract(width: 1280, height: 720, frameRate: 30, colorSpace: "Rec709")

    func clamped(maxLongEdge: Int = 3840) -> ProgramRenderContract {
        let capped = StreamRecordingPaths.cappedForRecording(width: width, height: height, maxLongEdge: maxLongEdge)
        return ProgramRenderContract(
            width: max(16, capped.width),
            height: max(16, capped.height),
            frameRate: frameRate,
            colorSpace: colorSpace
        )
    }

    /// Scales composite dimensions for operator-desk preview (even sizes for encoders).
    func scaledForLocalPreview(percent: Double) -> ProgramRenderContract {
        let clamped = min(100, max(25, percent.rounded()))
        let factor = clamped / 100
        let scaledW = max(16, Int((Double(width) * factor).rounded()))
        let scaledH = max(16, Int((Double(height) * factor).rounded()))
        return ProgramRenderContract(
            width: scaledW - scaledW % 2,
            height: scaledH - scaledH % 2,
            frameRate: frameRate,
            colorSpace: colorSpace
        )
    }
}
