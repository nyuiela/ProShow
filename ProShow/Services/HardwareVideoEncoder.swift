import Foundation
#if canImport(CoreMedia)
import CoreMedia
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(VideoToolbox)
import VideoToolbox
#endif

enum EncodedVideoPacket: Sendable, Equatable {
    case sequenceHeader(Data)
    case accessUnit(timestampMs: UInt32, keyframe: Bool, avcc: Data)
}

#if canImport(CoreMedia)
/// Discrete CFR PTS for VideoToolbox + FLV (frame index × 1/fps, no host-clock drift).
enum StreamVideoCFRClock {
    static func presentationTime(frameIndex: Int64, fps: Int32) -> CMTime {
        CMTime(value: frameIndex, timescale: CMTimeScale(max(1, fps)))
    }

    static func frameDuration(fps: Int32) -> CMTime {
        CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
    }

    static func timestampMs(frameIndex: Int64, fps: Int32) -> UInt32 {
        let safeFps = max(1, Int64(fps))
        let ms = (frameIndex * 1_000) / safeFps
        return UInt32(min(Int64(UInt32.max), max(0, ms)))
    }
}
#endif

final class HardwareVideoEncoder: @unchecked Sendable {
    private(set) var isPrepared = false
    private(set) var usesHardwareAcceleratedEncoder = false
    private(set) var encodedFrameCount = 0
    private(set) var encodeFailureCount = 0
    private(set) var lastEncodeStatus: OSStatus = noErr
    private(set) var width: Int32 = 0
    private(set) var height: Int32 = 0
    var onEncoded: (@Sendable (EncodedVideoPacket) -> Void)?
    var onEncodedSample: (@Sendable (CMSampleBuffer) -> Void)?
    var onAccessUnitBytes: (@Sendable (Int) -> Void)?

    #if canImport(VideoToolbox)
    private var compressionSession: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var targetFps: Int32 = 30
    #endif
    private var sentSequenceHeader = false

    func setupSession(width: Int32, height: Int32, fps: Int, bitrateKbps: Int) {
        var config = StreamEncoderConfig.preset720p30Saver()
        config.width = Int(max(16, width))
        config.height = Int(max(16, height))
        config.frameRate = max(1, fps)
        config.targetBitrateBps = max(250, bitrateKbps) * 1000
        config.maxBitrateCeilingBps = Int(Double(config.targetBitrateBps) * 1.2)
        setupStream(config: config)
    }

    func setupStream(config: StreamEncoderConfig) {
        teardown()
        width = Int32(max(16, config.width))
        height = Int32(max(16, config.height))
        sentSequenceHeader = false
        #if canImport(VideoToolbox)
        frameCount = 0
        targetFps = Int32(max(1, config.frameRate))
        let encoderSpecification: CFDictionary? = config.useHardwareEncoder
            ? [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
            : nil
        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            lastEncodeStatus = status
            return
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: 1))
        let profile = config.usesHighProfile ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: targetFps as CFNumber)
        VTSessionSetProperty(session, key: Self.baseFrameRatePropertyKey, value: targetFps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: max(400_000, config.targetBitrateBps) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: config.keyframeIntervalSeconds as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: max(1, config.frameRate * Int(config.keyframeIntervalSeconds)) as CFNumber)
        let bytesPerSecond = max(1, config.maxBitrateCeilingBps / 8)
        let dataRateLimits: [NSNumber] = [NSNumber(value: bytesPerSecond), NSNumber(value: 1)]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: dataRateLimits as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
        var hardware: CFTypeRef?
        if VTSessionCopyProperty(
            session,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil,
            valueOut: &hardware
        ) == noErr, let hardware {
            usesHardwareAcceleratedEncoder = (hardware as? Bool) ?? CFEqual(hardware, kCFBooleanTrue)
        } else {
            usesHardwareAcceleratedEncoder = true
        }
        compressionSession = session
        isPrepared = true
        #endif
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval, hostTime: CMTime = .invalid) {
        #if canImport(VideoToolbox) && canImport(CoreVideo) && canImport(CoreMedia)
        _ = presentationTime
        _ = hostTime
        let forceKey = !sentSequenceHeader
        ProShowQueues.encoderQueue.async { [weak self] in
            guard let self, let session = self.compressionSession else { return }
            let index = self.frameCount
            self.frameCount += 1
            let pts = StreamVideoCFRClock.presentationTime(frameIndex: index, fps: self.targetFps)
            let duration = StreamVideoCFRClock.frameDuration(fps: self.targetFps)
            var properties: CFDictionary?
            if forceKey {
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }
            var flags = VTEncodeInfoFlags()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: pts,
                duration: duration,
                frameProperties: properties,
                infoFlagsOut: &flags,
                outputHandler: { [weak self] status, _, sample in
                    if status != noErr {
                        self?.encodeFailureCount += 1
                        self?.lastEncodeStatus = status
                    }
                    self?.handle(sample)
                }
            )
            if status != noErr {
                encodeFailureCount += 1
                lastEncodeStatus = status
            }
        }
        #endif
    }

    func flushPendingEncodes() {
        ProShowQueues.encoderQueue.sync {
            #if canImport(VideoToolbox)
            if let session = compressionSession {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            }
            #endif
        }
    }

    func teardown() {
        let work = { [self] in
            #if canImport(VideoToolbox)
            if let session = compressionSession {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            compressionSession = nil
            #endif
            isPrepared = false
            usesHardwareAcceleratedEncoder = false
            encodedFrameCount = 0
            encodeFailureCount = 0
            lastEncodeStatus = noErr
            sentSequenceHeader = false
            frameCount = 0
            targetFps = 30
        }
        if ProShowQueues.isOnEncoderQueue {
            work()
        } else {
            ProShowQueues.encoderQueue.sync(execute: work)
        }
    }

    /// Documented alongside `ExpectedFrameRate`; not always exported as a Swift symbol.
    private static let baseFrameRatePropertyKey = "BaseFrameRate" as CFString

    #if canImport(VideoToolbox)
    private func handle(_ sample: CMSampleBuffer?) {
        guard let sample, CMSampleBufferDataIsReady(sample) else { return }
        onEncodedSample?(sample)
        if !sentSequenceHeader, let record = Self.avcDecoderConfiguration(from: sample) {
            sentSequenceHeader = true
            onEncoded?(.sequenceHeader(record))
        }
        guard let avcc = Self.avccPayload(from: sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let timestampMs: UInt32
        if pts.isValid, pts.timescale == CMTimeScale(targetFps), pts.value >= 0 {
            timestampMs = StreamVideoCFRClock.timestampMs(frameIndex: pts.value, fps: targetFps)
        } else {
            let seconds = CMTimeGetSeconds(pts)
            timestampMs = seconds.isFinite ? UInt32(max(0, min(Double(UInt32.max), seconds * 1000))) : 0
        }
        encodedFrameCount += 1
        onAccessUnitBytes?(avcc.count)
        onEncoded?(.accessUnit(timestampMs: timestampMs, keyframe: Self.isKeyframe(sample), avcc: avcc))
    }

    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first
        else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    static func avccPayload(from sample: CMSampleBuffer) -> Data? {
        guard let buffer = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(buffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length > 0
        else { return nil }
        return Data(bytes: pointer, count: length)
    }

    static func avcDecoderConfiguration(from sample: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        ) == noErr, count >= 2 else { return nil }
        var sets: [Data] = []
        for index in 0..<count {
            var size = 0
            var bytes: UnsafePointer<UInt8>?
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &bytes,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let bytes, size > 0
            else { continue }
            sets.append(Data(bytes: bytes, count: size))
        }
        guard let sps = sets.first, let pps = sets.dropFirst().first, sps.count >= 4 else { return nil }
        var record = Data([1, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        record.append(UInt8((sps.count >> 8) & 0xFF))
        record.append(UInt8(sps.count & 0xFF))
        record.append(sps)
        record.append(1)
        record.append(UInt8((pps.count >> 8) & 0xFF))
        record.append(UInt8(pps.count & 0xFF))
        record.append(pps)
        return record
    }
    #endif
}
