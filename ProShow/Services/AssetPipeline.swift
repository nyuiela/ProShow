import Foundation
import CoreGraphics
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
#endif

enum AssetPreviewError: Error, LocalizedError {
    case writerFailed
    case posterFailed

    var errorDescription: String? {
        switch self {
        case .writerFailed: "Could not write the seed video file."
        case .posterFailed: "Could not write a poster frame."
        }
    }
}

enum AssetPreview {
    /// Poster frame at 10% of duration, per the media preview contract.
    static func posterTime(durationSeconds: Double) -> Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return durationSeconds * 0.10
    }

    static func waveformPeaks(samples: [Float], bucketCount: Int = 64) -> [Float] {
        guard !samples.isEmpty, bucketCount > 0 else { return [] }
        let size = max(1, samples.count / bucketCount)
        var peaks: [Float] = []
        peaks.reserveCapacity(bucketCount)
        var index = 0
        while peaks.count < bucketCount && index < samples.count {
            let end = min(index + size, samples.count)
            let slice = samples[index..<end]
            let peak = slice.map(abs).max() ?? 0
            peaks.append(peak)
            index = end
        }
        return peaks
    }

    static func writeThumbnail(from imageURL: URL, to destination: URL, maxPixel: Int = 320) throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(ImageIO)
        let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil)
        if let source {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let type = UTType.png.identifier as CFString
                if let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    if CGImageDestinationFinalize(dest) {
                        return destination
                    }
                }
            }
        }
        #endif
        try FileManager.default.copyItem(at: imageURL, to: destination)
        return destination
    }

    static func writeVideoPoster(from videoURL: URL, to destination: URL, maxPixel: Int = 320) throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        let seconds = CMTimeGetSeconds(asset.duration)
        let time = CMTime(seconds: posterTime(durationSeconds: seconds.isFinite ? seconds : 0), preferredTimescale: 600)
        if let image = try? generator.copyCGImage(at: seconds > 0 ? time : .zero, actualTime: nil) {
            try writePNG(image, to: destination)
            return destination
        }
        #endif
        throw AssetPreviewError.posterFailed
    }

    static func writeSolidVideo(
        to url: URL,
        width: Int = 320,
        height: Int = 180,
        seconds: Double = 2,
        fps: Int = 10,
        color: (r: UInt8, g: UInt8, b: UInt8) = (27, 58, 75)
    ) throws -> URL {
        #if canImport(AVFoundation)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw AssetPreviewError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AssetPreviewError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        let frameCount = max(1, Int((seconds * Double(fps)).rounded()))
        for index in 0..<frameCount {
            var spins = 0
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
                spins += 1
                if spins > 400 { throw AssetPreviewError.writerFailed }
            }
            let buffer = try makeSolidPixelBuffer(width: width, height: height, color: color, pool: adaptor.pixelBufferPool)
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw writer.error ?? AssetPreviewError.writerFailed
            }
        }
        input.markAsFinished()
        try waitForWriterFinish(writer)
        guard writer.status == .completed else { throw writer.error ?? AssetPreviewError.writerFailed }
        return url
        #else
        throw AssetPreviewError.writerFailed
        #endif
    }

    #if canImport(ImageIO)
    private static func writePNG(_ image: CGImage, to destination: URL) throws {
        let type = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw AssetPreviewError.posterFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw AssetPreviewError.posterFailed }
    }
    #endif

    #if canImport(AVFoundation)
    private static func waitForWriterFinish(_ writer: AVAssetWriter, timeout: TimeInterval = 8) throws {
        let lock = NSLock()
        var finished = false
        writer.finishWriting {
            lock.lock()
            finished = true
            lock.unlock()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = finished
            lock.unlock()
            if done { return }
            if Thread.isMainThread {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        lock.lock()
        let done = finished
        lock.unlock()
        if !done { throw AssetPreviewError.writerFailed }
    }

    private static func makeSolidPixelBuffer(
        width: Int,
        height: Int,
        color: (r: UInt8, g: UInt8, b: UInt8),
        pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                nil,
                &buffer
            )
            guard status == kCVReturnSuccess else { throw AssetPreviewError.writerFailed }
        }
        guard let pixel = buffer else { throw AssetPreviewError.writerFailed }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw AssetPreviewError.writerFailed }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixel)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let line = pixels.advanced(by: row * bytesPerRow)
            for column in 0..<width {
                let offset = column * 4
                line[offset] = color.b
                line[offset + 1] = color.g
                line[offset + 2] = color.r
                line[offset + 3] = 255
            }
        }
        return pixel
    }
    #endif

    static func waveformPeaks(fromAudioFile url: URL, bucketCount: Int = 64) throws -> [Float] {
        #if canImport(AVFoundation)
        let file = try AVAudioFile(forReading: url)
        let frames = Int(file.length)
        guard frames > 0 else { return Array(repeating: 0, count: bucketCount) }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AssetPreviewError.posterFailed
        }
        try file.read(into: buffer)
        let channelCount = Int(format.channelCount)
        var samples: [Float] = []
        if let pointer = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            samples.reserveCapacity(frameLength)
            for frame in 0..<frameLength {
                var mix: Float = 0
                for channel in 0..<max(channelCount, 1) {
                    mix += abs(pointer[channel][frame])
                }
                samples.append(mix / Float(max(channelCount, 1)))
            }
        } else if let ints = buffer.int16ChannelData {
            let frameLength = Int(buffer.frameLength)
            for frame in 0..<frameLength {
                var mix: Float = 0
                for channel in 0..<max(channelCount, 1) {
                    mix += abs(Float(ints[channel][frame]) / Float(Int16.max))
                }
                samples.append(mix / Float(max(channelCount, 1)))
            }
        }
        return waveformPeaks(samples: samples, bucketCount: bucketCount)
        #else
        throw AssetPreviewError.posterFailed
        #endif
    }

    static func writeMarkPNG(to url: URL, size: Int = 256) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let width = max(64, size)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: width,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AssetPreviewError.posterFailed
        }
        context.setFillColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        context.setFillColor(red: 0.18, green: 0.44, blue: 0.93, alpha: 1)
        let inset = CGFloat(width) * 0.12
        context.fillEllipse(in: CGRect(x: inset, y: inset, width: CGFloat(width) - inset * 2, height: CGFloat(width) - inset * 2))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        let barX = CGFloat(width) * 0.32
        let barY = CGFloat(width) * 0.28
        let barW = CGFloat(width) * 0.14
        let barH = CGFloat(width) * 0.44
        context.fill(CGRect(x: barX, y: barY, width: barW, height: barH))
        context.fill(CGRect(x: barX, y: barY + barH - CGFloat(width) * 0.14, width: CGFloat(width) * 0.34, height: CGFloat(width) * 0.14))
        context.fillEllipse(in: CGRect(x: barX + CGFloat(width) * 0.16, y: barY + CGFloat(width) * 0.10, width: CGFloat(width) * 0.22, height: CGFloat(width) * 0.22))
        guard let image = context.makeImage() else { throw AssetPreviewError.posterFailed }
        try writePNG(image, to: url)
    }

    static func writeWaveformJSON(peaks: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(peaks)
        try data.write(to: url, options: .atomic)
    }
}

enum StoredZip {
    static func pack(_ entries: [String: Data]) -> Data {
        var locals = Data()
        var central = Data()
        var offset: UInt32 = 0
        for (name, payload) in entries.sorted(by: { $0.key < $1.key }) {
            let nameData = Data(name.utf8)
            var local = Data()
            local.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            local.append(contentsOf: u16(20))
            local.append(contentsOf: u16(0))
            local.append(contentsOf: u16(0))
            local.append(contentsOf: u16(0))
            local.append(contentsOf: u16(0))
            local.append(contentsOf: u32(crc32(payload)))
            local.append(contentsOf: u32(UInt32(payload.count)))
            local.append(contentsOf: u32(UInt32(payload.count)))
            local.append(contentsOf: u16(UInt16(nameData.count)))
            local.append(contentsOf: u16(0))
            local.append(nameData)
            local.append(payload)
            locals.append(local)

            var dir = Data()
            dir.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            dir.append(contentsOf: u16(20))
            dir.append(contentsOf: u16(20))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u32(crc32(payload)))
            dir.append(contentsOf: u32(UInt32(payload.count)))
            dir.append(contentsOf: u32(UInt32(payload.count)))
            dir.append(contentsOf: u16(UInt16(nameData.count)))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u16(0))
            dir.append(contentsOf: u32(0))
            dir.append(contentsOf: u32(offset))
            dir.append(nameData)
            central.append(dir)
            offset += UInt32(local.count)
        }
        var end = Data()
        end.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        end.append(contentsOf: u16(0))
        end.append(contentsOf: u16(0))
        end.append(contentsOf: u16(UInt16(entries.count)))
        end.append(contentsOf: u16(UInt16(entries.count)))
        end.append(contentsOf: u32(UInt32(central.count)))
        end.append(contentsOf: u32(offset))
        end.append(contentsOf: u16(0))
        var zip = locals
        zip.append(central)
        zip.append(end)
        return zip
    }

    static func unpack(_ data: Data) -> [String: Data] {
        var entries: [String: Data] = [:]
        var offset = 0
        while offset + 30 <= data.count {
            guard data[offset] == 0x50, data[offset + 1] == 0x4b, data[offset + 2] == 0x03, data[offset + 3] == 0x04
            else { break }
            let method = u16le(data, offset + 8)
            let compressed = Int(u32le(data, offset + 18))
            let nameLen = Int(u16le(data, offset + 26))
            let extra = Int(u16le(data, offset + 28))
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd + extra + compressed <= data.count else { break }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
            let payloadStart = nameEnd + extra
            let payload = data.subdata(in: payloadStart..<(payloadStart + compressed))
            if method == 0 {
                entries[name] = payload
            }
            offset = payloadStart + compressed
        }
        return entries
    }

    private static func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xff), UInt8(value >> 8)]
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
    }

    private static func u16le(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1
            }
        }
        return crc ^ 0xffffffff
    }
}

enum PPTXImport {
    static func parse(_ data: Data) throws -> Show {
        let files = StoredZip.unpack(data)
        let slides = files.keys
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted()
            .compactMap { files[$0] }
            .map { extractTexts(from: $0) }
            .filter { !$0.isEmpty }
            .map { Slide(lines: $0) }
        if slides.isEmpty {
            throw PresentationImportError.emptyPPTX
        }
        return Show(
            name: "Imported Presentation",
            groups: [SlideGroup(name: "Imported", colorHex: "#5B8DEF", slides: slides)],
            notes: "Imported from PowerPoint Open XML"
        )
    }

    static func extractTexts(from xml: Data) -> [String] {
        let collector = PPTXTextCollector()
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.parse()
        return collector.texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

enum PresentationImportError: Error {
    case emptyPPTX
}

private final class PPTXTextCollector: NSObject, XMLParserDelegate {
    var texts: [String] = []
    private var current = ""
    private var capturing = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        capturing = local == "t"
        if capturing { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { current += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if capturing {
            texts.append(current)
            capturing = false
        }
    }
}

extension PresentationImport {
    static func parsePPTX(_ data: Data) throws -> Show {
        try PPTXImport.parse(data)
    }
}
