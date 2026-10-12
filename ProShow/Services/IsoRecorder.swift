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
            _ = ProgramAACEncoder.nextAccessUnit(recording: recorder)
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
    private static let audioSampleRate = 48_000
    private static let stereoPCMFormat: CMFormatDescription? = {
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
        assetWriter.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        assetWriter.shouldOptimizeForNetworkUse = true
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
            } else if pendingAudio.count < 64 {
                pendingAudio.append((aac, presentationTime))
            }
        }
    }

    func flushPending() {
        queue.sync {}
    }

    func appendAudioPCM(_ interleavedStereo: [Float]) {
        guard !isPassthrough else { return }
        queue.async { [self] in
            appendAudioPCMOnQueue(interleavedStereo)
        }
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
        if !passthroughReady {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            guard openPassthroughWriter(videoFormat: format) else { return }
        }
        guard let input = writerInput, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            let start = pendingAudio.map(\.pts).reduce(pts) { partial, audioPTS in
                CMTimeCompare(audioPTS, partial) < 0 ? audioPTS : partial
            }
            writer?.startSession(atSourceTime: start)
            sessionStarted = true
            let queued = pendingAudio
            pendingAudio.removeAll(keepingCapacity: false)
            for item in queued {
                appendEncodedAudioOnQueue(item.data, presentationTime: item.pts)
            }
        }
        if input.append(sampleBuffer) {
            framesWritten += 1
        }
    }

    private func appendEncodedAudioOnQueue(_ aac: Data, presentationTime: CMTime) {
        guard sessionStarted, let audioInput = audioWriterInput, audioInput.isReadyForMoreMediaData else { return }
        guard let sample = Self.makeAACSampleBuffer(aac: aac, presentationTime: presentationTime, format: audioFormat) else { return }
        if audioInput.append(sample) {
            audioFramesWritten += 1
        }
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

    private static func makeAACFormatDescription() -> CMFormatDescription? {
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

    private static func makeAACSampleBuffer(
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
            sampleCount: 1024,
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

    private static func makePCMSampleBuffer(
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
    #endif

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
            waiter.wait()
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
