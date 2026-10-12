import Foundation
#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
#endif

struct IsoRecordChannelConfig: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var sourceId: String
    var channelName: String
    var isEnabled: Bool = true
    var codec: IsoVideoCodec = .h264Hardware
    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 60
    var destinationFolderURL: URL?

    enum IsoVideoCodec: String, Codable, CaseIterable, Sendable {
        case h264Hardware = "H.264 Hardware (Compact)"
        case hevcHardware = "HEVC / H.265 (High Efficiency)"
        case proRes422 = "Apple ProRes 422 (Post-Production)"

        var isoCodec: IsoCodec {
            switch self {
            case .h264Hardware: .h264
            case .hevcHardware: .hevc
            case .proRes422: .prores
            }
        }
    }
}

/// Parallel clean-feed writers — one AVAssetWriter per camera / screen lane.
final class IsoRecorderEngine: @unchecked Sendable {
    static let shared = IsoRecorderEngine()

    private let queue = DispatchQueue(label: "com.proshow.iso.recorder", qos: .userInitiated)
    #if canImport(AVFoundation)
    private var channelWriters: [String: ProgramVideoFileRecorder] = [:]
    #endif
    private var isRecording = false

    var activeChannelCount: Int {
        #if canImport(AVFoundation)
        queue.sync { channelWriters.count }
        #else
        0
        #endif
    }

    var isActive: Bool {
        queue.sync { isRecording }
    }

    func startIsoRecording(channels: [IsoRecordChannelConfig], outputDirectory: URL) {
        queue.async { [weak self] in
            guard let self, !self.isRecording else { return }
            let stamp = StreamRecordingPaths.filename(projectName: "ISO", startedAt: Date())
                .replacingOccurrences(of: "ISO_", with: "")
                .replacingOccurrences(of: ".mp4", with: "")
            let root = outputDirectory
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            #if canImport(AVFoundation)
            for config in channels where config.isEnabled {
                let safeName = StreamRecordingPaths.sanitizeFilenameComponent(config.channelName)
                let folder = config.destinationFolderURL ?? root
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let ext = config.codec.isoCodec.fileExtension
                let fileURL = folder.appendingPathComponent("\(safeName)_\(stamp).\(ext)")
                if let writer = ProgramVideoFileRecorder(
                    url: fileURL,
                    codec: config.codec.isoCodec,
                    width: config.width,
                    height: config.height,
                    fps: config.fps
                ) {
                    channelWriters[config.sourceId] = writer
                }
            }
            isRecording = !channelWriters.isEmpty
            #else
            isRecording = false
            #endif
        }
    }

    func appendRawPixelBuffer(sourceId: String, pixelBuffer: CVPixelBuffer) {
        #if canImport(AVFoundation)
        queue.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.channelWriters[sourceId]?.append(
                pixelBuffer,
                presentationTime: CACurrentMediaTime()
            )
        }
        #endif
    }

    func stopIsoRecording(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            #if canImport(AVFoundation)
            let writers = Array(channelWriters.values)
            let group = DispatchGroup()
            for writer in writers {
                group.enter()
                writer.finish { _, _ in group.leave() }
            }
            group.wait()
            channelWriters.removeAll()
            #endif
            isRecording = false
            if let completion {
                DispatchQueue.main.async { completion() }
            }
        }
    }
}
