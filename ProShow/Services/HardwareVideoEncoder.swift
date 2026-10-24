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

enum EncodeStatusLog {
    private static let path = "/tmp/proshow-vt.log"

    static func reset() {
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    static func append(_ status: OSStatus) {
        let text = "vt=\(status)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

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
    /// Blocks still waiting to enter VideoToolbox, and frames VideoToolbox has not returned.
    private let depthLock = NSLock()
    private var sessionBacklog = 0
    private var encoderHeld = 0
    var encodeOutcome: (failures: Int, status: OSStatus) {
        depthLock.lock()
        defer { depthLock.unlock() }
        return (encodeFailureCount, lastEncodeStatus)
    }

    private func recordEncodeStatus(_ status: OSStatus) {
        depthLock.lock()
        lastEncodeStatus = status
        if status != noErr {
            encodeFailureCount += 1
        }
        depthLock.unlock()
        EncodeStatusLog.append(status)
    }

    var queuedFrameDepth: (session: Int, encoder: Int) {
        depthLock.lock()
        defer { depthLock.unlock() }
        return (sessionBacklog, encoderHeld)
    }
    private(set) var width: Int32 = 0
    private(set) var height: Int32 = 0
    /// Stream stays on the shared encoder queue. A Phone lane sets its own queue so it cannot block Stream.
    var sessionQueue: DispatchQueue = ProShowQueues.encoderQueue
    var onEncoded: (@Sendable (EncodedVideoPacket) -> Void)?
    /// When set, FLV timestamps follow the VideoToolbox PTS and do not chase the host clock.
    var strictPresentationTimestamps = false
    var onEncodedSample: (@Sendable (CMSampleBuffer) -> Void)?
    var onAccessUnitBytes: (@Sendable (Int) -> Void)?

    #if canImport(VideoToolbox)
    private var compressionSession: VTCompressionSession?
    private var frameCount: Int64 = 0
    private var targetFps: Int32 = 30
    private var lastRTMPTimestampMs: UInt32 = 0
    #endif
    private var sentSequenceHeader = false
    /// Phone lane only: subtracted from the PTS before the FLV timestamp, so a lane that started
    /// on the local clock (9:16 recording) still sends stream-clock timestamps. Zero for Stream.
    private var rtmpTimestampShift: CMTime = .zero

    func setRTMPTimestampShift(_ shift: CMTime) {
        depthLock.lock()
        rtmpTimestampShift = shift
        depthLock.unlock()
    }

    private func currentRTMPTimestampShift() -> CMTime {
        depthLock.lock()
        defer { depthLock.unlock() }
        return rtmpTimestampShift
    }

    /// Changes the bitrate on the running session (no new session, no new keyframe).
    func updateBitrate(targetBps: Int, ceilingBps: Int) {
        #if canImport(VideoToolbox)
        sessionQueue.async { [self] in
            guard let session = compressionSession else { return }
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: max(400_000, targetBps) as CFNumber)
            let bytesPerSecond = max(1, max(targetBps, ceilingBps) / 8)
            let limits: [NSNumber] = [NSNumber(value: bytesPerSecond), NSNumber(value: 1)]
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        }
        #endif
    }

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
        EncodeStatusLog.reset()
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
            EncodeStatusLog.append(status)
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

    /// Advance CFR timeline when compositing skips a frame so video PTS does not lag audio.
    func advanceScheduledFrames(_ count: Int = 1) {
        guard count > 0 else { return }
        sessionQueue.async { [weak self] in
            self?.frameCount += Int64(count)
        }
    }

    func encodeOnMasterClock(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool) {
        #if canImport(VideoToolbox) && canImport(CoreVideo) && canImport(CoreMedia)
        let forceKey = forceKeyframe || !sentSequenceHeader
        depthLock.lock()
        sessionBacklog += 1
        depthLock.unlock()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.depthLock.lock()
            self.sessionBacklog = max(0, self.sessionBacklog - 1)
            self.depthLock.unlock()
            guard let session = self.compressionSession else { return }
            self.frameCount += 1
            let duration = StreamVideoCFRClock.frameDuration(fps: self.targetFps)
            var properties: CFDictionary?
            if forceKey {
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }
            var flags = VTEncodeInfoFlags()
            self.depthLock.lock()
            self.encoderHeld += 1
            self.depthLock.unlock()
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: duration,
                frameProperties: properties,
                infoFlagsOut: &flags,
                outputHandler: { [weak self] status, _, sample in
                    self?.depthLock.lock()
                    self?.encoderHeld = max(0, (self?.encoderHeld ?? 1) - 1)
                    self?.depthLock.unlock()
                    self?.recordEncodeStatus(status)
                    self?.handle(sample)
                }
            )
            if status != noErr {
                self.depthLock.lock()
                self.encoderHeld = max(0, self.encoderHeld - 1)
                self.depthLock.unlock()
                self.recordEncodeStatus(status)
            }
        }
        #endif
    }

    func encode(pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval, hostTime: CMTime = .invalid) {
        #if canImport(VideoToolbox) && canImport(CoreVideo) && canImport(CoreMedia)
        _ = presentationTime
        _ = hostTime
        let forceKey = !sentSequenceHeader
        sessionQueue.async { [weak self] in
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
                    self?.recordEncodeStatus(status)
                    self?.handle(sample)
                }
            )
            if status != noErr {
                self.recordEncodeStatus(status)
            }
        }
        #endif
    }

    func flushPendingEncodes() {
        sessionQueue.sync {
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
            lastRTMPTimestampMs = 0
            setRTMPTimestampShift(.zero)
        }
        if sessionQueue === ProShowQueues.encoderQueue, ProShowQueues.isOnEncoderQueue {
            work()
        } else {
            sessionQueue.sync(execute: work)
        }
    }

    /// Documented alongside `ExpectedFrameRate`; not always exported as a Swift symbol.
    private static let baseFrameRatePropertyKey = "BaseFrameRate" as CFString

    #if canImport(VideoToolbox)
    /// FLV timestamps follow the same host anchor as AAC; CFR index only drives VideoToolbox order.
    private func rtmpTimestampMs(for pts: CMTime) -> UInt32 {
        let frameStepMs = UInt32(max(1, 1_000 / max(1, targetFps)))
        let cfrMs: UInt32
        if pts.isValid, pts.timescale == CMTimeScale(targetFps), pts.value >= 0 {
            cfrMs = StreamVideoCFRClock.timestampMs(frameIndex: pts.value, fps: targetFps)
        } else {
            let seconds = CMTimeGetSeconds(pts)
            cfrMs = seconds.isFinite ? UInt32(max(0, min(Double(UInt32.max), seconds * 1000))) : 0
        }
        var candidate = cfrMs
        if !strictPresentationTimestamps, MediaClockAnchor.shared.isActive {
            let hostMs = MediaClockAnchor.shared.timestampMs(MediaClockAnchor.shared.currentPresentationTime())
            candidate = max(candidate, hostMs)
        }
        if candidate <= lastRTMPTimestampMs {
            candidate = lastRTMPTimestampMs &+ frameStepMs
        }
        lastRTMPTimestampMs = candidate
        return candidate
    }

    private func handle(_ sample: CMSampleBuffer?) {
        guard let sample, CMSampleBufferDataIsReady(sample) else { return }
        onEncodedSample?(sample)
        if !sentSequenceHeader, let record = Self.avcDecoderConfiguration(from: sample) {
            sentSequenceHeader = true
            onEncoded?(.sequenceHeader(record))
        }
        guard let avcc = Self.avccPayload(from: sample) else { return }
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sample)
        let shift = currentRTMPTimestampShift()
        let pts = CMTimeCompare(shift, .zero) == 0 ? samplePTS : CMTimeSubtract(samplePTS, shift)
        let timestampMs = rtmpTimestampMs(for: pts)
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
