import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreVideo
#endif

enum IsoCodec: String, Hashable, Codable, Sendable {
    case prores, h264, hevc

    var fileExtension: String {
        switch self {
        case .prores: "mov"
        case .h264, .hevc: "mp4"
        }
    }
}

/// Default folder for audience / program captures (Movies/stream, with Application Support fallback).
enum StreamRecordingPaths {
    static func cappedForRecording(width: Int, height: Int, maxLongEdge: Int = 1920) -> (width: Int, height: Int) {
        let w = max(16, width)
        let h = max(16, height)
        let long = max(w, h)
        guard long > maxLongEdge else { return (w, h) }
        let scale = Double(maxLongEdge) / Double(long)
        return (
            max(16, Int((Double(w) * scale).rounded())),
            max(16, Int((Double(h) * scale).rounded()))
        )
    }

    @discardableResult
    static func ensureWritableDirectory(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".proshow_write_probe")
            try Data([0xAB]).write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    static func writeAccessError(for directory: URL) -> String {
        "ProShow cannot write to \(directory.path). Allow Movies folder access in System Settings → Privacy & Security → Files and Folders, or reinstall with updated entitlements."
    }

    static var moviesStreamDirectory: URL {
        let fileManager = FileManager.default
        if let movies = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first {
            let stream = movies.appendingPathComponent("stream", isDirectory: true)
            if (try? fileManager.createDirectory(at: stream, withIntermediateDirectories: true)) != nil {
                return stream
            }
        }
        let fallback = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProShow/Recordings", isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent("ProShowRecordings", isDirectory: true)
        try? fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func filename(projectName: String, startedAt: Date, codec: IsoCodec = .h264) -> String {
        let safe = sanitizeFilenameComponent(projectName)
        let stamp = filenameDateFormatter.string(from: startedAt)
        return "\(safe)_\(stamp).\(codec.fileExtension)"
    }

    static func sanitizeFilenameComponent(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "ProShow" : trimmed
        let illegal = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let cleaned = fallback.unicodeScalars.map { illegal.contains($0) ? "_" : Character($0) }
        let collapsed = String(cleaned)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return collapsed.isEmpty ? "ProShow" : String(collapsed.prefix(120))
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}

struct IsoTake: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var label: String
    var relativePath: String
    var codec: IsoCodec
    var width: Int
    var height: Int
    var fps: Int
    var isolated: Bool
}

#if canImport(AVFoundation)
/// Active program `.mov` writer receiving stream-mix PCM while local recording is on.
enum ProgramRecordingAudioBridge {
    nonisolated(unsafe) static var activeProgramRecorder: ProgramVideoFileRecorder?
}

enum ProgramRecordingAudioPump {
    private static var timer: DispatchSourceTimer?
    private static var retainedRecorder: ProgramVideoFileRecorder?

    /// Stops the record-only timer without detaching a live passthrough writer.
    static func suspendLocalPump() {
        timer?.cancel()
        timer = nil
        retainedRecorder = nil
    }

    static func start(recorder: ProgramVideoFileRecorder) {
        suspendLocalPump()
        retainedRecorder = recorder
        ProgramRecordingAudioBridge.activeProgramRecorder = recorder
        let source = DispatchSource.makeTimerSource(queue: ProShowQueues.diskIOQueue)
        source.schedule(deadline: .now() + ProgramStreamAudioClock.pumpTimerInterval, repeating: ProgramStreamAudioClock.pumpTimerInterval)
        source.setEventHandler {
            guard let recorder = retainedRecorder else { return }
            ProgramEncoderAudioPump.noteTick()
            // With a host anchor (passthrough file after the stream stops) stay on host time.
            let due = MediaClockAnchor.shared.isActive ? MediaClockAnchor.shared.dueAudioBlockCount() : 1
            for _ in 0..<due {
                _ = ProgramAACEncoder.nextAccessUnit(recording: recorder)
            }
        }
        source.resume()
        timer = source
    }

    static func stop() {
        suspendLocalPump()
        ProgramRecordingAudioBridge.activeProgramRecorder = nil
    }
}

enum ProgramRecordingSetupFailure: Error, LocalizedError {
    case writerInit(String)

    var errorDescription: String? {
        switch self {
        case let .writerInit(message): message
        }
    }
}

/// Thread-safe program file writer; append may run on the program clock queue.
final class ProgramVideoFileRecorder {
    let url: URL
    let width: Int
    let height: Int
    let fps: Int
    private let queue = DispatchQueue(label: "com.proshow.program.file-writer")
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingOrigin: TimeInterval?
    private var lastVideoPTS: CMTime = .invalid
    private var audioSampleCursor: Int64 = 0
    private(set) var framesWritten: Int64 = 0
    private(set) var audioFramesWritten: Int64 = 0
    let isPassthrough: Bool
    private var passthroughReady = false
    private var sessionStarted = false
    private var pendingAudio: [(data: Data, pts: CMTime)] = []
    private var audioFormat: CMFormatDescription?
    // Passthrough timeline. A stream stop/start resets the source clock to zero; the file keeps going.
    private var videoOffset: CMTime = .zero
    private var lastVideoOut: CMTime = .invalid
    private var audioOffset: CMTime = .zero
    private var lastAudioOut: CMTime = .invalid
    private(set) var timelineRebases = 0
    private(set) var skippedLeadingFrames = 0
    private var sessionStartPTS: CMTime = .invalid
    private var sessionStartHost: Double = 0
    private(set) var rejectedAppends = 0
    private(set) var failureMessage: String?
    /// 9:16 sibling file. It gets the same audio this file gets, on its own queue.
    private let siblingLock = NSLock()
    private var sibling: PhoneRecordingFileWriter?
    fileprivate static let audioSampleRate = 48_000
    fileprivate static let stereoPCMFormat: CMFormatDescription? = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return format
    }()

    static func make(
        url: URL,
        codec: IsoCodec,
        width: Int,
        height: Int,
        fps: Int
    ) -> Result<ProgramVideoFileRecorder, ProgramRecordingSetupFailure> {
        if let recorder = ProgramVideoFileRecorder(url: url, codec: codec, width: width, height: height, fps: fps) {
            return .success(recorder)
        }
        return .failure(
            .writerInit("Could not start AVAssetWriter for \(url.lastPathComponent) at \(width)×\(height).")
        )
    }

    static func makePassthrough(
        url: URL,
        width: Int,
        height: Int,
        fps: Int
    ) -> Result<ProgramVideoFileRecorder, ProgramRecordingSetupFailure> {
        if let recorder = ProgramVideoFileRecorder(passthroughAt: url, width: width, height: height, fps: fps) {
            return .success(recorder)
        }
        return .failure(
            .writerInit("Could not prepare passthrough recording for \(url.lastPathComponent).")
        )
    }

    init?(url: URL, codec: IsoCodec, width: Int, height: Int, fps: Int) {
        self.url = url
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        self.isPassthrough = false
        guard width > 0, height > 0, width * height <= 3840 * 2160 else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            return nil
        }
        let fileType: AVFileType = .mov
        guard let assetWriter = try? AVAssetWriter(outputURL: url, fileType: fileType) else { return nil }
        // Fragmented .mov: finishing is instant and a crash still leaves a playable file.
        // No shouldOptimizeForNetworkUse: that rewrites the whole movie on finish.
        assetWriter.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let settings: [String: Any]
        switch codec {
        case .h264:
            settings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 12_000_000,
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                ],
            ]
        case .hevc:
            settings = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 10_000_000,
                    AVVideoExpectedSourceFrameRateKey: fps,
                ],
            ]
        case .prores:
            settings = [
                AVVideoCodecKey: AVVideoCodecType.proRes422,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard assetWriter.canAdd(input) else { return nil }
        assetWriter.add(input)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.audioSampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(audioInput) else { return nil }
        assetWriter.add(audioInput)
        guard assetWriter.startWriting() else {
            _ = assetWriter.error?.localizedDescription
            return nil
        }
        assetWriter.startSession(atSourceTime: .zero)
        writer = assetWriter
        writerInput = input
        audioWriterInput = audioInput
        adaptor = pixelAdaptor
    }

    private init?(passthroughAt url: URL, width: Int, height: Int, fps: Int) {
        self.url = url
        self.width = max(16, width)
        self.height = max(16, height)
        self.fps = max(1, fps)
        self.isPassthrough = true
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            return nil
        }
    }

    func appendEncodedVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard isPassthrough else { return }
        queue.async { [self] in
            appendEncodedVideoOnQueue(sampleBuffer)
        }
    }

    func appendEncodedAudio(_ aac: Data, presentationTime: CMTime) {
        guard isPassthrough, !aac.isEmpty else { return }
        queue.async { [self] in
            if passthroughReady {
                appendEncodedAudioOnQueue(aac, presentationTime: presentationTime)
            } else {
                pendingAudio.append((aac, presentationTime))
                if pendingAudio.count > 150 { pendingAudio.removeFirst(pendingAudio.count - 150) }
            }
        }
        currentSibling()?.mirrorEncodedAudio(aac, presentationTime: presentationTime)
    }

    /// Attach or detach the 9:16 file. Never blocks this file's queue.
    func attachSibling(_ writer: PhoneRecordingFileWriter?) {
        siblingLock.lock()
        sibling = writer
        siblingLock.unlock()
    }

    private func currentSibling() -> PhoneRecordingFileWriter? {
        siblingLock.lock()
        defer { siblingLock.unlock() }
        return sibling
    }

    func flushPending() {
        queue.sync {}
    }

    func appendAudioPCM(_ interleavedStereo: [Float]) {
        guard !isPassthrough else { return }
        queue.async { [self] in
            appendAudioPCMOnQueue(interleavedStereo)
        }
        currentSibling()?.mirrorPCM(interleavedStereo)
    }

    func append(
        _ pixelBuffer: CVPixelBuffer,
        presentationTime: TimeInterval,
        onFramesWritten: (@Sendable (Int64) -> Void)? = nil
    ) {
        guard !isPassthrough else { return }
        queue.async { [self] in
            appendOnQueue(pixelBuffer, presentationTime: presentationTime)
            onFramesWritten?(framesWritten)
        }
    }

    func finish(completion: (@Sendable (AVAssetWriter.Status, Error?) -> Void)? = nil) {
        queue.async { [self] in
            let input = writerInput
            let audioInput = audioWriterInput
            let pending = writer
            writerInput = nil
            audioWriterInput = nil
            adaptor = nil
            writer = nil
            audioInput?.markAsFinished()
            input?.markAsFinished()
            guard let pending, pending.status == .writing else {
                completion?(pending?.status ?? .unknown, pending?.error)
                return
            }
            pending.finishWriting {
                completion?(pending.status, pending.error)
            }
        }
    }

    private func appendEncodedVideoOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        // A passthrough file must open on a sync sample. Starting mid-GOP made the writer
        // fail (-11800 / -12735) on its first fragment, leaving a few KB with no moov.
        if !sessionStarted, !Self.isSyncSample(sampleBuffer) {
            skippedLeadingFrames += 1
            return
        }
        if !passthroughReady {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            guard openPassthroughWriter(videoFormat: format) else { return }
        }
        if let writer, writer.status == .failed {
            noteWriterFailure(writer)
            return
        }
        guard let input = writerInput, input.isReadyForMoreMediaData else { return }
        let sourcePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourcePTS.isValid else { return }
        let pts = Self.rebased(
            sourcePTS,
            offset: &videoOffset,
            lastOut: lastVideoOut,
            step: CMTime(value: 1, timescale: CMTimeScale(fps)),
            wall: wallTimelinePosition(),
            rebases: &timelineRebases
        )
        let sample = Self.retimed(sampleBuffer, shift: CMTimeSubtract(pts, sourcePTS)) ?? sampleBuffer
        if !sessionStarted {
            // Start on the keyframe; queued audio from before it is dropped so both tracks begin together.
            writer?.startSession(atSourceTime: pts)
            sessionStarted = true
            sessionStartPTS = pts
            sessionStartHost = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            let queued = pendingAudio.filter { CMTimeCompare($0.pts, pts) >= 0 }
            pendingAudio.removeAll(keepingCapacity: false)
            for item in queued {
                appendEncodedAudioOnQueue(item.data, presentationTime: item.pts)
            }
        }
        if input.append(sample) {
            framesWritten += 1
            lastVideoOut = pts
        } else {
            rejectedAppends += 1
            if let writer { noteWriterFailure(writer) }
        }
    }

    private func appendEncodedAudioOnQueue(_ aac: Data, presentationTime: CMTime) {
        guard sessionStarted, let audioInput = audioWriterInput, audioInput.isReadyForMoreMediaData else { return }
        guard presentationTime.isValid else { return }
        let pts = Self.rebased(
            presentationTime,
            offset: &audioOffset,
            lastOut: lastAudioOut,
            step: CMTime(value: 1024, timescale: CMTimeScale(Self.audioSampleRate)),
            wall: wallTimelinePosition(),
            rebases: &timelineRebases
        )
        guard let sample = Self.makeAACSampleBuffer(aac: aac, presentationTime: pts, format: audioFormat) else { return }
        if audioInput.append(sample) {
            audioFramesWritten += 1
            lastAudioOut = pts
        } else {
            rejectedAppends += 1
        }
    }

    fileprivate static func isSyncSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    private func noteWriterFailure(_ writer: AVAssetWriter) {
        guard writer.status == .failed, failureMessage == nil else { return }
        failureMessage = writer.error?.localizedDescription ?? "Recording writer failed."
        NSLog("ProShow recording writer failed: %@", failureMessage ?? "")
    }

    /// File time that matches the wall clock since the session started.
    private func wallTimelinePosition() -> CMTime {
        guard sessionStartPTS.isValid else { return .invalid }
        let elapsed = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - sessionStartHost
        return CMTimeAdd(sessionStartPTS, CMTime(seconds: max(0, elapsed), preferredTimescale: 48_000))
    }

    /// Keeps each track monotonic. When the source clock jumps (a stream stop/start resets it to
    /// zero), the track re-anchors to wall time since the file started, so audio and video stay
    /// in sync with each other and a real pause stays a pause.
    fileprivate static func rebased(
        _ pts: CMTime,
        offset: inout CMTime,
        lastOut: CMTime,
        step: CMTime,
        wall: CMTime,
        rebases: inout Int
    ) -> CMTime {
        let out = CMTimeAdd(pts, offset)
        guard lastOut.isValid else { return out }
        let delta = CMTimeGetSeconds(CMTimeSubtract(out, lastOut))
        let drift = wall.isValid ? CMTimeGetSeconds(CMTimeSubtract(out, wall)) : 0
        guard delta <= 0 || delta > 2.0 || abs(drift) > 2.0 else { return out }
        var target = wall.isValid ? wall : CMTimeAdd(lastOut, step)
        if CMTimeCompare(target, lastOut) <= 0 {
            target = CMTimeAdd(lastOut, step)
        }
        offset = CMTimeSubtract(target, pts)
        rebases += 1
        return target
    }

    fileprivate static func retimed(_ sampleBuffer: CMSampleBuffer, shift: CMTime) -> CMSampleBuffer? {
        guard shift.isValid, CMTimeCompare(shift, .zero) != 0 else { return sampleBuffer }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, shift)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, shift)
            }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &out
        ) == noErr else { return nil }
        return out
    }

    private func openPassthroughWriter(videoFormat: CMFormatDescription) -> Bool {
        guard let assetWriter = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        assetWriter.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(video) else { return false }
        assetWriter.add(video)
        let audioFormat = Self.makeAACFormatDescription()
        self.audioFormat = audioFormat
        if let audioFormat {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            audio.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(audio) {
                assetWriter.add(audio)
                audioWriterInput = audio
            }
        }
        guard assetWriter.startWriting() else { return false }
        writer = assetWriter
        writerInput = video
        passthroughReady = true
        return true
    }

    fileprivate static func makeAACFormatDescription() -> CMFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var cookie: [UInt8] = [0x11, 0x90]
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: cookie.count,
            magicCookie: &cookie,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard status == noErr else { return nil }
        return format
    }

    fileprivate static func makeAACSampleBuffer(
        aac: Data,
        presentationTime: CMTime,
        format: CMFormatDescription?
    ) -> CMSampleBuffer? {
        guard let format, !aac.isEmpty else { return nil }
        let byteCount = aac.count
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = aac.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        var packet = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(byteCount)
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            // One compressed packet (1024 PCM frames). 1024 here made every create fail,
            // so passthrough files never got audio.
            sampleCount: 1,
            presentationTimeStamp: presentationTime,
            packetDescriptions: &packet,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    private func appendOnQueue(_ pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval) {
        guard let input = writerInput, let adaptor else { return }
        guard CVPixelBufferGetWidth(pixelBuffer) == width, CVPixelBufferGetHeight(pixelBuffer) == height else { return }
        guard input.isReadyForMoreMediaData else { return }
        if recordingOrigin == nil {
            recordingOrigin = presentationTime
        }
        let origin = recordingOrigin ?? presentationTime
        let relative = max(0, presentationTime - origin)
        let pts = CMTime(seconds: relative, preferredTimescale: 600)
        let minStep = CMTime(value: 1, timescale: CMTimeScale(fps))
        if lastVideoPTS.isValid {
            let delta = CMTimeSubtract(pts, lastVideoPTS)
            if CMTimeCompare(delta, minStep) < 0 {
                return
            }
        }
        if adaptor.append(pixelBuffer, withPresentationTime: pts) {
            lastVideoPTS = pts
            framesWritten += 1
        }
    }

    private func appendAudioPCMOnQueue(_ interleavedStereo: [Float]) {
        guard let audioInput = audioWriterInput, audioInput.isReadyForMoreMediaData else { return }
        guard interleavedStereo.count >= 2 else { return }
        let frameCount = interleavedStereo.count / 2
        guard let format = Self.stereoPCMFormat,
              let sampleBuffer = Self.makePCMSampleBuffer(
                samples: interleavedStereo,
                frameCount: frameCount,
                formatDescription: format,
                presentationTime: CMTime(value: audioSampleCursor, timescale: CMTimeScale(Self.audioSampleRate))
              )
        else { return }
        if audioInput.append(sampleBuffer) {
            audioSampleCursor += Int64(frameCount)
            audioFramesWritten += 1
        }
    }

    fileprivate static func makePCMSampleBuffer(
        samples: [Float],
        frameCount: Int,
        formatDescription: CMFormatDescription,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr,
            let blockBuffer
        else { return nil }
        let copyStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frameCount), timescale: CMTimeScale(audioSampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleSize = MemoryLayout<Float>.size * 2
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [sampleSize],
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}

/// One clock for the 9:16 lane and its file: the stream's media clock while it runs,
/// otherwise host time from a fixed origin (RTMP milliseconds stay small).
enum PhoneMediaClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var localOrigin: Double?

    static func hostSeconds() -> Double {
        CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    static func seconds(atHost host: Double) -> Double {
        let anchor = MediaClockAnchor.shared
        if anchor.isActive {
            let time = anchor.presentationTime(atHostTime: CMTime(seconds: host, preferredTimescale: 1_000_000_000))
            if time.isValid { return CMTimeGetSeconds(time) }
        }
        lock.lock()
        defer { lock.unlock() }
        if localOrigin == nil { localOrigin = host }
        return host - (localOrigin ?? host)
    }
}

/// The open 9:16 file, if any. The Phone encoder hands it every encoded frame.
enum PhoneRecordingBridge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: PhoneRecordingFileWriter?

    static var active: PhoneRecordingFileWriter? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    static var isActive: Bool { active != nil }

    static func set(_ writer: PhoneRecordingFileWriter?) {
        lock.lock()
        current = writer
        lock.unlock()
    }
}

/// The 9:16 recording. Video is the Phone lane's H.264, written as is. Audio is the same audio
/// the 16:9 file gets: identical AAC packets when the 16:9 file is passthrough, or the same PCM
/// encoded to AAC here when it is not. Everything runs on this writer's own queue; when it falls
/// behind it drops, and the 16:9 file never waits for it.
final class PhoneRecordingFileWriter: @unchecked Sendable {
    enum AudioMode: String { case aac, pcm }

    let url: URL
    let audioMode: AudioMode
    private let queue = DispatchQueue(label: "com.proshow.program.phone-file-writer", qos: .userInitiated)
    private static let frameRate: Int32 = 30
    private static let maxBacklog = 240
    private static let maxPending = 150

    // Guarded by gate.
    private let gate = NSLock()
    private var backlog = 0
    private var closed = false
    private var resyncVideo = false
    private var droppedVideoCount = 0
    private var droppedAudioCount = 0

    // Queue only.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMFormatDescription?
    private var opened = false
    private var sessionStarted = false
    private var waitingForSync = true
    private var sessionStartPTS: CMTime = .invalid
    private var sessionStartHost: Double = 0
    private var videoOffset: CMTime = .zero
    private var lastVideoOut: CMTime = .invalid
    private var audioOffset: CMTime = .zero
    private var lastAudioOut: CMTime = .invalid
    private var pendingAAC: [(data: Data, pts: CMTime)] = []
    private var pendingPCM: [(samples: [Float], pts: CMTime)] = []
    private var pcmOrigin: CMTime = .invalid
    private var pcmCursor: Int64 = 0
    private var framesWritten: Int64 = 0
    private var audioPacketsWritten: Int64 = 0
    private var timelineRebases = 0
    private var skippedLeadingFrames = 0
    private var rejectedAppends = 0
    private var failureMessage: String?

    init?(url: URL, audioMode: AudioMode) {
        self.url = url
        self.audioMode = audioMode
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
    }

    /// `<16:9 name>_Phone.mov` in the same folder. A second 9:16 segment in one recording gets `_Phone-2.mov`.
    static func url(besides main: URL) -> URL {
        let folder = main.deletingLastPathComponent()
        let base = main.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(base)_Phone.mov")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)_Phone-\(index).mov")
            index += 1
        }
        return candidate
    }

    // MARK: Producers (any thread, never block)

    func appendEncodedVideoSample(_ sample: CMSampleBuffer) {
        enqueue(video: true) { [self] in appendVideoOnQueue(sample) }
    }

    /// Same AAC packet and time the 16:9 file got.
    func mirrorEncodedAudio(_ aac: Data, presentationTime: CMTime) {
        guard audioMode == .aac, !aac.isEmpty else { return }
        enqueue(video: false) { [self] in
            if sessionStarted {
                appendAACOnQueue(aac, presentationTime: presentationTime)
            } else {
                pendingAAC.append((aac, presentationTime))
                if pendingAAC.count > Self.maxPending { pendingAAC.removeFirst(pendingAAC.count - Self.maxPending) }
            }
        }
    }

    /// Same PCM block the 16:9 file got. Timed on the Phone clock so it lines up with the Phone frames.
    func mirrorPCM(_ interleavedStereo: [Float]) {
        guard audioMode == .pcm, interleavedStereo.count >= 2 else { return }
        let host = PhoneMediaClock.hostSeconds()
        enqueue(video: false) { [self] in
            if !pcmOrigin.isValid {
                pcmOrigin = CMTime(
                    value: Int64((PhoneMediaClock.seconds(atHost: host) * 48_000).rounded()),
                    timescale: 48_000
                )
            }
            let pts = CMTimeAdd(pcmOrigin, CMTime(value: pcmCursor, timescale: 48_000))
            pcmCursor += Int64(interleavedStereo.count / 2)
            if sessionStarted {
                appendPCMOnQueue(interleavedStereo, presentationTime: pts)
            } else {
                pendingPCM.append((interleavedStereo, pts))
                if pendingPCM.count > Self.maxPending { pendingPCM.removeFirst(pendingPCM.count - Self.maxPending) }
            }
        }
    }

    private func enqueue(video: Bool, _ work: @escaping () -> Void) {
        gate.lock()
        if closed {
            gate.unlock()
            return
        }
        if backlog >= Self.maxBacklog {
            if video {
                droppedVideoCount += 1
                resyncVideo = true
            } else {
                droppedAudioCount += 1
            }
            gate.unlock()
            return
        }
        backlog += 1
        gate.unlock()
        queue.async { [self] in
            work()
            gate.lock()
            backlog -= 1
            gate.unlock()
        }
    }

    // MARK: Queue

    private func appendVideoOnQueue(_ sample: CMSampleBuffer) {
        guard failureMessage == nil, CMSampleBufferDataIsReady(sample) else { return }
        gate.lock()
        if resyncVideo {
            resyncVideo = false
            waitingForSync = true
        }
        gate.unlock()
        let sync = ProgramVideoFileRecorder.isSyncSample(sample)
        if waitingForSync {
            guard sync else {
                skippedLeadingFrames += 1
                return
            }
            waitingForSync = false
        }
        if !opened {
            guard let format = CMSampleBufferGetFormatDescription(sample), open(videoFormat: format) else {
                waitingForSync = true
                return
            }
        }
        guard let writer, let input = videoInput else { return }
        if writer.status == .failed {
            noteFailure(writer)
            return
        }
        guard input.isReadyForMoreMediaData else {
            gate.lock()
            droppedVideoCount += 1
            gate.unlock()
            waitingForSync = true
            return
        }
        let source = CMSampleBufferGetPresentationTimeStamp(sample)
        guard source.isValid else { return }
        let pts = ProgramVideoFileRecorder.rebased(
            source,
            offset: &videoOffset,
            lastOut: lastVideoOut,
            step: CMTime(value: 1, timescale: Self.frameRate),
            wall: wallTimelinePosition(),
            rebases: &timelineRebases
        )
        guard let out = ProgramVideoFileRecorder.retimed(sample, shift: CMTimeSubtract(pts, source)) else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            sessionStartPTS = pts
            sessionStartHost = PhoneMediaClock.hostSeconds()
        }
        if input.append(out) {
            framesWritten += 1
            lastVideoOut = pts
        } else {
            rejectedAppends += 1
            noteFailure(writer)
            return
        }
        if !pendingAAC.isEmpty || !pendingPCM.isEmpty {
            flushPendingAudio(start: pts)
        }
    }

    private func flushPendingAudio(start: CMTime) {
        let aac = pendingAAC
        let pcm = pendingPCM
        pendingAAC.removeAll()
        pendingPCM.removeAll()
        for item in aac where CMTimeCompare(item.pts, start) >= 0 {
            appendAACOnQueue(item.data, presentationTime: item.pts)
        }
        for item in pcm {
            let end = CMTimeAdd(item.pts, CMTime(value: Int64(item.samples.count / 2), timescale: 48_000))
            guard CMTimeCompare(end, start) > 0 else { continue }
            appendPCMOnQueue(item.samples, presentationTime: item.pts)
        }
    }

    private func appendAACOnQueue(_ aac: Data, presentationTime: CMTime) {
        guard sessionStarted, presentationTime.isValid, let input = audioInput else { return }
        guard input.isReadyForMoreMediaData else {
            noteAudioDrop()
            return
        }
        let pts = ProgramVideoFileRecorder.rebased(
            presentationTime,
            offset: &audioOffset,
            lastOut: lastAudioOut,
            step: CMTime(value: 1024, timescale: 48_000),
            wall: wallTimelinePosition(),
            rebases: &timelineRebases
        )
        guard let sample = ProgramVideoFileRecorder.makeAACSampleBuffer(aac: aac, presentationTime: pts, format: audioFormat) else { return }
        if input.append(sample) {
            audioPacketsWritten += 1
            lastAudioOut = pts
        } else {
            rejectedAppends += 1
        }
    }

    private func appendPCMOnQueue(_ samples: [Float], presentationTime: CMTime) {
        guard sessionStarted, let input = audioInput else { return }
        guard input.isReadyForMoreMediaData else {
            noteAudioDrop()
            return
        }
        if lastAudioOut.isValid, CMTimeCompare(presentationTime, lastAudioOut) <= 0 { return }
        guard let format = ProgramVideoFileRecorder.stereoPCMFormat,
              let sample = ProgramVideoFileRecorder.makePCMSampleBuffer(
                samples: samples,
                frameCount: samples.count / 2,
                formatDescription: format,
                presentationTime: presentationTime
              ) else { return }
        if input.append(sample) {
            audioPacketsWritten += 1
            lastAudioOut = presentationTime
        } else {
            rejectedAppends += 1
        }
    }

    private func noteAudioDrop() {
        gate.lock()
        droppedAudioCount += 1
        gate.unlock()
    }

    private func open(videoFormat: CMFormatDescription) -> Bool {
        guard let assetWriter = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            failureMessage = "Could not open the 9:16 file."
            return false
        }
        assetWriter.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        guard assetWriter.canAdd(video) else {
            failureMessage = "The 9:16 file refused the video track."
            return false
        }
        assetWriter.add(video)
        let audio: AVAssetWriterInput
        switch audioMode {
        case .aac:
            let format = ProgramVideoFileRecorder.makeAACFormatDescription()
            audioFormat = format
            audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format)
        case .pcm:
            audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
        }
        audio.expectsMediaDataInRealTime = true
        if assetWriter.canAdd(audio) {
            assetWriter.add(audio)
            audioInput = audio
        }
        guard assetWriter.startWriting() else {
            failureMessage = assetWriter.error?.localizedDescription ?? "The 9:16 file could not start."
            return false
        }
        writer = assetWriter
        videoInput = video
        opened = true
        return true
    }

    private func noteFailure(_ writer: AVAssetWriter) {
        guard writer.status == .failed, failureMessage == nil else { return }
        failureMessage = writer.error?.localizedDescription ?? "The 9:16 writer failed."
        NSLog("ProShow 9:16 recording writer failed: %@", failureMessage ?? "")
    }

    private func wallTimelinePosition() -> CMTime {
        guard sessionStartPTS.isValid else { return .invalid }
        let elapsed = PhoneMediaClock.hostSeconds() - sessionStartHost
        return CMTimeAdd(sessionStartPTS, CMTime(seconds: max(0, elapsed), preferredTimescale: 48_000))
    }

    /// Stops taking data, then closes the file. Completion runs on the writer queue.
    func finish(completion: @escaping @Sendable (_ status: AVAssetWriter.Status, _ frames: Int64, _ error: String?) -> Void) {
        gate.lock()
        closed = true
        gate.unlock()
        queue.async { [self] in
            let pending = writer
            let frames = framesWritten
            audioInput?.markAsFinished()
            videoInput?.markAsFinished()
            writer = nil
            videoInput = nil
            audioInput = nil
            pendingAAC.removeAll()
            pendingPCM.removeAll()
            guard let pending, pending.status == .writing else {
                completion(pending?.status ?? .unknown, frames, failureMessage)
                return
            }
            pending.finishWriting {
                completion(pending.status, frames, pending.error?.localizedDescription)
            }
        }
    }

    var diagnostics: [String: Any] {
        let counts: (Int, Int, Int) = {
            gate.lock()
            defer { gate.unlock() }
            return (backlog, droppedVideoCount, droppedAudioCount)
        }()
        return queue.sync {
            [
                "path": url.lastPathComponent,
                "audioMode": audioMode.rawValue,
                "frames": framesWritten,
                "audioPackets": audioPacketsWritten,
                "sessionStarted": sessionStarted,
                "skippedLeading": skippedLeadingFrames,
                "rebases": timelineRebases,
                "rejected": rejectedAppends,
                "backlog": counts.0,
                "droppedVideo": counts.1,
                "droppedAudio": counts.2,
                "failure": failureMessage ?? "",
            ]
        }
    }
}
#endif

/// Program + isolated camera recording. Program writes a real AVAssetWriter file.
@MainActor
@Observable
final class IsoRecorder {
    var isRecording = false
    var takes: [IsoTake] = []
    var programTakeID: UUID?
    var width: Int = 3840
    var height: Int = 2160
    var fps: Int = 60
    var outputDirectory: URL?
    private(set) var programFileURL: URL?
    private(set) var isIsoMultiChannelRecording = false
    private(set) var programFramesRecorded: Int64 = 0
    private(set) var lastRecordingError: String?

    #if canImport(AVFoundation)
    @ObservationIgnored nonisolated(unsafe) private(set) var programFileWriter: ProgramVideoFileRecorder?
    @ObservationIgnored private(set) var phoneFileWriter: PhoneRecordingFileWriter?
    #endif
    /// True while a 9:16 file is being written beside the 16:9 file.
    private(set) var isRecordingPhone = false
    private(set) var phoneFileURL: URL?
    var lastPhoneRecordingNote: String?

    var recordingFormatsLabel: String {
        isRecordingPhone ? "Recording 16:9 + 9:16" : "Recording 16:9"
    }

    /// Opens `<name>_Phone.mov` beside the 16:9 file and mirrors its audio into it.
    @discardableResult
    func startPhoneFile() -> Bool {
        #if canImport(AVFoundation)
        guard isRecording, phoneFileWriter == nil, let main = programFileWriter else { return phoneFileWriter != nil }
        let url = PhoneRecordingFileWriter.url(besides: main.url)
        guard let writer = PhoneRecordingFileWriter(url: url, audioMode: main.isPassthrough ? .aac : .pcm) else {
            lastPhoneRecordingNote = "Could not create \(url.lastPathComponent)."
            return false
        }
        phoneFileWriter = writer
        phoneFileURL = url
        isRecordingPhone = true
        lastPhoneRecordingNote = nil
        PhoneRecordingBridge.set(writer)
        main.attachSibling(writer)
        return true
        #else
        return false
        #endif
    }

    /// Closes the 9:16 file cleanly. The 16:9 file keeps going.
    func stopPhoneFile() {
        #if canImport(AVFoundation)
        guard let writer = phoneFileWriter else { return }
        programFileWriter?.attachSibling(nil)
        PhoneRecordingBridge.set(nil)
        phoneFileWriter = nil
        isRecordingPhone = false
        // Finishes on the writer's own queue. Never waits on the main thread (a take must not stall).
        writer.finish { [weak self] status, frames, error in
            Task { @MainActor in
                if status == .failed || frames == 0 {
                    self?.lastPhoneRecordingNote = error ?? "The 9:16 file has no frames."
                }
            }
        }
        #endif
    }

    var phoneRecordingDiagnostics: [String: Any] {
        #if canImport(AVFoundation)
        var info = phoneFileWriter?.diagnostics ?? ["file": "none"]
        info["note"] = lastPhoneRecordingNote ?? ""
        info["label"] = isRecording ? recordingFormatsLabel : ""
        return info
        #else
        return [:]
        #endif
    }

    func attachProgramWriter(_ writer: ProgramVideoFileRecorder, useLocalAudioPump: Bool = true) {
        #if canImport(AVFoundation)
        programFileWriter = writer
        programFileURL = writer.url
        lastRecordingError = nil
        programFramesRecorded = 0
        ProgramRecordingAudioBridge.activeProgramRecorder = writer
        if useLocalAudioPump {
            ProgramRecordingAudioPump.start(recorder: writer)
        }
        #endif
    }

    func reportRecordingSetupFailure(_ message: String) {
        lastRecordingError = message
    }
    @ObservationIgnored private let isoEngine = IsoRecorderEngine.shared

    @discardableResult
    func start(
        program: Bool = true,
        isolatedSourceIDs: [UUID] = [],
        codec: IsoCodec = .h264,
        width: Int = 3840,
        height: Int = 2160,
        fps: Int = 60,
        programFilename: String? = nil
    ) -> [IsoTake] {
        isoEngine.stopIsoRecording()
        isIsoMultiChannelRecording = false
        takes.removeAll()
        programTakeID = nil
        self.width = width
        self.height = height
        self.fps = fps
        isRecording = true
        var created: [IsoTake] = []
        if program {
            let relative = programFilename ?? "Recordings/program.\(codec.fileExtension)"
            let take = IsoTake(
                id: UUID(),
                label: "Program",
                relativePath: relative,
                codec: codec,
                width: width,
                height: height,
                fps: fps,
                isolated: false
            )
            takes.append(take)
            programTakeID = take.id
            created.append(take)
            if programFileWriter == nil {
                beginProgramFile(take)
            } else {
                programFileURL = programFileWriter?.url
            }
            #if canImport(AVFoundation)
            if programFileWriter == nil {
                isRecording = takes.contains(where: { $0.isolated }) || isIsoMultiChannelRecording
            }
            #endif
        }
        for sourceID in isolatedSourceIDs {
            let take = IsoTake(
                id: UUID(),
                label: "ISO \(sourceID.uuidString.prefix(8))",
                relativePath: "Recordings/iso-\(sourceID.uuidString).\(codec.fileExtension)",
                codec: codec,
                width: width,
                height: height,
                fps: fps,
                isolated: true
            )
            takes.append(take)
            created.append(take)
        }
        return created
    }

    func stop() {
        isRecording = false
        isIsoMultiChannelRecording = false
        #if canImport(AVFoundation)
        ProgramRecordingAudioPump.stop()
        stopPhoneFile()
        let writer = programFileWriter
        let url = programFileURL
        programFileWriter = nil
        if let writer {
            writer.flushPending()
            let frames = writer.framesWritten
            let waiter = DispatchSemaphore(value: 0)
            writer.finish { [weak self] status, error in
                Task { @MainActor in
                    self?.noteProgramRecordingFinished(
                        url: url,
                        framesWritten: frames,
                        status: status,
                        error: error
                    )
                }
                waiter.signal()
            }
            if waiter.wait(timeout: .now() + 20) == .timedOut {
                NSLog("ProShow recording finish is taking longer than 20 s; continuing.")
            }
        }
        #endif
        isoEngine.stopIsoRecording()
    }

    private func noteProgramRecordingFinished(
        url: URL?,
        framesWritten: Int64,
        status: AVAssetWriter.Status,
        error: Error?
    ) {
        #if canImport(AVFoundation)
        if status == .failed {
            lastRecordingError = error?.localizedDescription ?? "Recording writer failed."
            return
        }
        if framesWritten == 0 {
            lastRecordingError = "No video frames were written. Keep the program output visible while recording."
            return
        }
        if let url {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            if size <= 32 {
                lastRecordingError = "Recording file is empty at \(url.path)."
            } else {
                lastRecordingError = nil
            }
        }
        #endif
    }

    func startIsolatedChannels(_ channels: [IsoRecordChannelConfig], outputDirectory: URL) {
        isIsoMultiChannelRecording = true
        isRecording = true
        isoEngine.startIsoRecording(channels: channels, outputDirectory: outputDirectory)
    }

    func stopIsolatedChannelsOnly() {
        isIsoMultiChannelRecording = false
        isoEngine.stopIsoRecording()
        if programFileWriter == nil {
            isRecording = false
        }
    }

    nonisolated func appendProgramFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval) {
        #if canImport(AVFoundation)
        guard let writer = programFileWriter else { return }
        let frameW = CVPixelBufferGetWidth(pixelBuffer)
        let frameH = CVPixelBufferGetHeight(pixelBuffer)
        let deliver: CVPixelBuffer
        if frameW == writer.width, frameH == writer.height {
            deliver = pixelBuffer
        } else if let scaled = ProgramOutputComposer.shared.scaledPixelBuffer(
            pixelBuffer,
            width: writer.width,
            height: writer.height
        ) {
            deliver = scaled
        } else {
            return
        }
        writer.append(deliver, presentationTime: presentationTime) { count in
            Task { @MainActor in
                self.programFramesRecorded = count
            }
        }
        #endif
    }

    var programTake: IsoTake? {
        takes.first(where: { $0.id == programTakeID })
    }

    var isolatedTakes: [IsoTake] {
        takes.filter(\.isolated)
    }

    private func beginProgramFile(_ take: IsoTake) {
        let root = outputDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("ProShowRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let leaf = take.relativePath.contains("/")
            ? take.relativePath.replacingOccurrences(of: "Recordings/", with: "")
            : take.relativePath
        let url = root.appendingPathComponent(leaf)
        programFileURL = url
        #if canImport(AVFoundation)
        switch ProgramVideoFileRecorder.make(
            url: url,
            codec: take.codec,
            width: take.width,
            height: take.height,
            fps: take.fps
        ) {
        case let .success(writer):
            programFileWriter = writer
            lastRecordingError = nil
            programFramesRecorded = 0
            ProgramRecordingAudioBridge.activeProgramRecorder = writer
            ProgramRecordingAudioPump.start(recorder: writer)
            return
        case let .failure(error):
            lastRecordingError = error.localizedDescription
        }
        #endif
        var payload = RTMPClient.flvHeader()
        payload.append(contentsOf: Array("proshow-iso".utf8))
        try? payload.write(to: url)
    }
}
