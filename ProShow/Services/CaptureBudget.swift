import Foundation
#if canImport(VideoToolbox)
import VideoToolbox
#endif
#if canImport(CoreMedia)
import CoreMedia
#endif

/// Camera capture follows the show output. 4K output stays off unless the Mac has 16 GB or a hardware HEVC encoder.
enum CaptureBudget {
    static let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
    static let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024

    static func prefersCompactOutput(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory <= eightGB
    }

    static func allows4KOutput(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        hardwareHEVC: Bool = HardwareEncoderProbe.hevcEncodeAvailable
    ) -> Bool {
        physicalMemory >= sixteenGB || hardwareHEVC
    }

    /// New shows. 720p30 on an 8 GB Mac. 1080p30 otherwise. 4K is a choice, not the default.
    static func factoryResolution(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> DisplayResolution {
        prefersCompactOutput(physicalMemory: physicalMemory) ? .res720p : .res1080p
    }

    static func factoryFrameRate() -> TargetFrameRate { .fps30 }

    /// 4K is delivered only when this Mac can hold the buffers. Smaller sizes pass through.
    static func deliveryResolution(
        _ resolution: DisplayResolution,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        hardwareHEVC: Bool = HardwareEncoderProbe.hevcEncodeAvailable
    ) -> DisplayResolution {
        let longSide = max(resolution.width, resolution.height)
        guard longSide >= 3000, !allows4KOutput(physicalMemory: physicalMemory, hardwareHEVC: hardwareHEVC) else {
            return resolution
        }
        if resolution.height > resolution.width {
            return .resVertical1080
        }
        return .res1080p
    }

    /// Camera preset search, largest first. 4K is included only when the show is 4K, or when capture above the output size is on and that step reaches 4K.
    enum CapturePresetStep: Equatable {
        case uhd4k
        case hd1080
        case hd720
        case medium
    }

    static func capturePresetSteps(
        outputWidth: Int,
        outputHeight: Int,
        allowAboveOutput: Bool
    ) -> [CapturePresetStep] {
        let longSide = captureLongSide(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            allowAboveOutput: allowAboveOutput
        )
        if longSide >= 3000 {
            return [.uhd4k, .hd1080, .hd720, .medium]
        }
        if longSide >= 1600 {
            return [.hd1080, .hd720, .medium]
        }
        return [.hd720, .medium]
    }

    /// Long side of the camera format. Matches the output unless crop or zoom opts in, then one step up, capped at 4K.
    static func captureLongSide(outputWidth: Int, outputHeight: Int, allowAboveOutput: Bool) -> Int {
        let output = max(outputWidth, outputHeight, 1)
        guard allowAboveOutput else { return output }
        if output <= 1280 { return 1920 }
        if output <= 1920 { return 3840 }
        return output
    }
}

enum HardwareEncoderProbe {
    static let hevcEncodeAvailable: Bool = {
        #if canImport(VideoToolbox) && canImport(CoreMedia)
        var encoderID: CFString?
        var properties: CFDictionary?
        let specification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: kCFBooleanTrue as Any
        ] as CFDictionary
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: specification,
            encoderIDOut: &encoderID,
            supportedPropertiesOut: &properties
        )
        return status == noErr
        #else
        return false
        #endif
    }()
}
