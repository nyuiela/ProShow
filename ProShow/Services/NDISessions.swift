import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(Darwin)
import Darwin
#endif

enum NDIFourCC {
    static let bgra: Int32 = 0x41524742
    static let bgrx: Int32 = 0x58524742
    static let rgba: Int32 = 0x41424752
    static let rgbx: Int32 = 0x58424752
    static let uyvy: Int32 = 0x59565955
}

struct NDIRecvCreateV3 {
    var sourceName: UnsafePointer<CChar>?
    var sourceURL: UnsafePointer<CChar>?
    var colorFormat: Int32
    var bandwidth: Int32
    var allowVideoFields: Bool
    var recvName: UnsafePointer<CChar>?
}

struct NDIVideoFrameV2 {
    var xres: Int32 = 0
    var yres: Int32 = 0
    var fourCC: Int32 = 0
    var frameRateN: Int32 = 0
    var frameRateD: Int32 = 0
    var pictureAspectRatio: Float = 0
    var frameFormatType: Int32 = 0
    var timecode: Int64 = 0
    var data: UnsafeMutablePointer<UInt8>?
    var lineStride: Int32 = 0
    var metadata: UnsafePointer<CChar>?
    var timestamp: Int64 = 0
}

struct NDISendCreate {
    var name: UnsafePointer<CChar>?
    var groups: UnsafePointer<CChar>?
    var clockVideo: Bool
    var clockAudio: Bool
}

enum NDIPixelCopy {
    #if canImport(CoreVideo)
    static func pixelBuffer(
        fourCC: Int32,
        width: Int,
        height: Int,
        data: UnsafeRawPointer,
        stride: Int
    ) -> CVPixelBuffer? {
        guard width > 0, height > 0, stride > 0 else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destStride = CVPixelBufferGetBytesPerRow(buffer)
        let dest = destination.assumingMemoryBound(to: UInt8.self)
        let source = data.assumingMemoryBound(to: UInt8.self)
        switch fourCC {
        case NDIFourCC.bgra, NDIFourCC.bgrx:
            copyRows(from: source, sourceStride: stride, to: dest, destStride: destStride, width: width, height: height, bytesPerPixel: 4)
        case NDIFourCC.rgba, NDIFourCC.rgbx:
            swapRGBA(from: source, sourceStride: stride, to: dest, destStride: destStride, width: width, height: height)
        case NDIFourCC.uyvy:
            expandUYVY(from: source, sourceStride: stride, to: dest, destStride: destStride, width: width, height: height)
        default:
            return nil
        }
        return buffer
    }

    private static func copyRows(
        from source: UnsafePointer<UInt8>,
        sourceStride: Int,
        to dest: UnsafeMutablePointer<UInt8>,
        destStride: Int,
        width: Int,
        height: Int,
        bytesPerPixel: Int
    ) {
        let rowBytes = width * bytesPerPixel
        for row in 0..<height {
            memcpy(dest + row * destStride, source + row * sourceStride, rowBytes)
        }
    }

    private static func swapRGBA(
        from source: UnsafePointer<UInt8>,
        sourceStride: Int,
        to dest: UnsafeMutablePointer<UInt8>,
        destStride: Int,
        width: Int,
        height: Int
    ) {
        for row in 0..<height {
            let src = source + row * sourceStride
            let dst = dest + row * destStride
            for column in 0..<width {
                let s = column * 4
                dst[s] = src[s + 2]
                dst[s + 1] = src[s + 1]
                dst[s + 2] = src[s]
                dst[s + 3] = src[s + 3]
            }
        }
    }

    private static func expandUYVY(
        from source: UnsafePointer<UInt8>,
        sourceStride: Int,
        to dest: UnsafeMutablePointer<UInt8>,
        destStride: Int,
        width: Int,
        height: Int
    ) {
        for row in 0..<height {
            let src = source + row * sourceStride
            let dst = dest + row * destStride
            var column = 0
            while column + 1 < width {
                let pair = (column / 2) * 4
                let u = Int(src[pair]) - 128
                let y0 = Int(src[pair + 1])
                let v = Int(src[pair + 2]) - 128
                let y1 = Int(src[pair + 3])
                writeYUV(y: y0, u: u, v: v, into: dst + column * 4)
                writeYUV(y: y1, u: u, v: v, into: dst + (column + 1) * 4)
                column += 2
            }
        }
    }

    private static func writeYUV(y: Int, u: Int, v: Int, into pixel: UnsafeMutablePointer<UInt8>) {
        let c = max(y - 16, 0)
        let r = (298 * c + 409 * v + 128) >> 8
        let g = (298 * c - 100 * u - 208 * v + 128) >> 8
        let b = (298 * c + 516 * u + 128) >> 8
        pixel[0] = UInt8(clamping: b)
        pixel[1] = UInt8(clamping: g)
        pixel[2] = UInt8(clamping: r)
        pixel[3] = 255
    }
    #endif
}

/// Pulls one NDI source into BGRA pixel buffers. All SDK calls stay on `queue`.
final class NDIReceiver: @unchecked Sendable {
    var onVideo: (@Sendable (CVPixelBuffer) -> Void)?

    private let queue = DispatchQueue(label: "proshow.ndi.recv")
    private let lock = NSLock()
    private var running = false
    private var recv: OpaquePointer?
    private let sourceName: String
    private let sourceURL: String

    init(sourceName: String, sourceURL: String) {
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }

    func start() {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func run() {
        #if canImport(Darwin) && canImport(CoreVideo)
        guard isRunning(), let recv = createReceiver() else { return }
        self.recv = recv
        defer { destroy(recv) }
        while isRunning() {
            var frame = NDIVideoFrameV2()
            let kind = capture(recv, &frame)
            if kind == 1, let data = frame.data, frame.xres > 0, frame.yres > 0 {
                if let buffer = NDIPixelCopy.pixelBuffer(
                    fourCC: frame.fourCC,
                    width: Int(frame.xres),
                    height: Int(frame.yres),
                    data: data,
                    stride: Int(frame.lineStride)
                ) {
                    onVideo?(buffer)
                }
            }
            if kind == 1 {
                freeVideo(recv, &frame)
            }
        }
        #endif
    }

    #if canImport(Darwin)
    private func createReceiver() -> OpaquePointer? {
        typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
        guard let symbol = NDIRuntime.resolvedSymbol("NDIlib_recv_create_v3") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateFn.self)
        return sourceName.withCString { name in
            sourceURL.withCString { url in
                let recvTitle = "ProShow"
                return recvTitle.withCString { title in
                    var settings = NDIRecvCreateV3(
                        sourceName: name,
                        sourceURL: sourceURL.isEmpty ? nil : url,
                        colorFormat: 0,
                        bandwidth: 100,
                        allowVideoFields: false,
                        recvName: title
                    )
                    return withUnsafePointer(to: &settings) { create(UnsafeRawPointer($0)) }
                }
            }
        }
    }

    private func capture(_ recv: OpaquePointer, _ frame: inout NDIVideoFrameV2) -> Int32 {
        typealias CaptureFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32
        guard let symbol = NDIRuntime.resolvedSymbol("NDIlib_recv_capture_v2") else { return 0 }
        let capture = unsafeBitCast(symbol, to: CaptureFn.self)
        return withUnsafeMutablePointer(to: &frame) { video in
            capture(recv, UnsafeMutableRawPointer(video), nil, nil, 40)
        }
    }

    private func freeVideo(_ recv: OpaquePointer, _ frame: inout NDIVideoFrameV2) {
        typealias FreeFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
        guard let symbol = NDIRuntime.resolvedSymbol("NDIlib_recv_free_video_v2") else { return }
        let free = unsafeBitCast(symbol, to: FreeFn.self)
        withUnsafeMutablePointer(to: &frame) { video in
            free(recv, UnsafeMutableRawPointer(video))
        }
    }

    private func destroy(_ recv: OpaquePointer) {
        typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
        guard let symbol = NDIRuntime.resolvedSymbol("NDIlib_recv_destroy") else { return }
        let destroy = unsafeBitCast(symbol, to: DestroyFn.self)
        destroy(recv)
        self.recv = nil
    }
    #endif
}

/// Publishes BGRA program frames as an NDI source.
final class NDISender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "proshow.ndi.send")
    private let lock = NSLock()
    private var send: OpaquePointer?
    private var pending: CVPixelBuffer?
    private var draining = false
    let name: String

    init(name: String, instance: OpaquePointer) {
        self.name = name
        self.send = instance
    }

    func enqueue(_ buffer: CVPixelBuffer) {
        lock.lock()
        pending = buffer
        let start = !draining
        if start { draining = true }
        lock.unlock()
        guard start else { return }
        queue.async { [weak self] in
            self?.drain()
        }
    }

    func close() {
        queue.sync {
            lock.lock()
            let instance = send
            send = nil
            pending = nil
            draining = false
            lock.unlock()
            destroy(instance)
        }
    }

    private func drain() {
        while true {
            lock.lock()
            let buffer = pending
            pending = nil
            let instance = send
            if buffer == nil {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()
            if let buffer, let instance {
                submit(buffer, instance: instance)
            }
        }
    }

    private func submit(_ buffer: CVPixelBuffer, instance: OpaquePointer) {
        #if canImport(Darwin) && canImport(CoreVideo)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        typealias SendFn = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void
        guard let symbol = NDIRuntime.resolvedSymbol("NDIlib_send_send_video_v2") else { return }
        let sendVideo = unsafeBitCast(symbol, to: SendFn.self)
        var frame = NDIVideoFrameV2(
            xres: Int32(width),
            yres: Int32(height),
            fourCC: NDIFourCC.bgra,
            frameRateN: 30,
            frameRateD: 1,
            pictureAspectRatio: height > 0 ? Float(width) / Float(height) : 16 / 9,
            frameFormatType: 1,
            timecode: Int64.max,
            data: base.assumingMemoryBound(to: UInt8.self),
            lineStride: Int32(stride)
        )
        withUnsafePointer(to: &frame) { sendVideo(instance, UnsafeRawPointer($0)) }
        #else
        _ = buffer
        _ = instance
        #endif
    }

    private func destroy(_ instance: OpaquePointer?) {
        #if canImport(Darwin)
        typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
        guard let instance, let symbol = NDIRuntime.resolvedSymbol("NDIlib_send_destroy") else { return }
        let destroy = unsafeBitCast(symbol, to: DestroyFn.self)
        destroy(instance)
        #else
        _ = instance
        #endif
    }
}

enum NDISessionFactory {
    static func openReceiver(sourceName: String, sourceURL: String = "") -> NDIReceiver? {
        guard NDIRuntime.load() else { return nil }
        return NDIReceiver(sourceName: sourceName, sourceURL: sourceURL)
    }

    static func openSender(name: String) -> NDISender? {
        #if canImport(Darwin)
        guard NDIRuntime.load() else { return nil }
        typealias CreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
        guard let symbol = NDIRuntime.resolvedSymbol("NDIlib_send_create") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateFn.self)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let instance: OpaquePointer? = trimmed.withCString { cName in
            var settings = NDISendCreate(name: cName, groups: nil, clockVideo: false, clockAudio: false)
            return withUnsafePointer(to: &settings) { create(UnsafeRawPointer($0)) }
        }
        guard let instance else { return nil }
        return NDISender(name: trimmed, instance: instance)
        #else
        _ = name
        return nil
        #endif
    }
}

/// Sends the composited program when a screen or the stage layout asks for NDI.
final class NDIProgramSender {
    static let shared = NDIProgramSender()

    private let lock = NSLock()
    private var sender: NDISender?
    private var subscribed = false
    private let token = NSObject()

    private init() {}

    func sync(enabled: Bool, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !trimmed.isEmpty, NDIRuntime.isAvailable else {
            stop()
            return
        }
        NDIRuntime.hardwareEnabled = true
        lock.lock()
        if sender?.name == trimmed {
            lock.unlock()
            subscribe()
            return
        }
        let previous = sender
        sender = nil
        lock.unlock()
        previous?.close()
        let opened = NDISessionFactory.openSender(name: trimmed)
        lock.lock()
        sender = opened
        lock.unlock()
        if opened != nil {
            subscribe()
        }
    }

    func stop() {
        unsubscribe()
        lock.lock()
        let previous = sender
        sender = nil
        lock.unlock()
        previous?.close()
    }

    private func subscribe() {
        lock.lock()
        let already = subscribed
        subscribed = true
        lock.unlock()
        guard !already else { return }
        SharedTexturePublisher.shared.addConsumer(ObjectIdentifier(token)) { [weak self] in
            self?.forwardCurrentFrame()
        }
    }

    private func unsubscribe() {
        lock.lock()
        let was = subscribed
        subscribed = false
        lock.unlock()
        guard was else { return }
        SharedTexturePublisher.shared.removeConsumer(ObjectIdentifier(token))
    }

    private func forwardCurrentFrame() {
        #if canImport(CoreVideo)
        guard let buffer = SharedTexturePublisher.shared.currentPixelBuffer() else { return }
        lock.lock()
        let sender = sender
        lock.unlock()
        sender?.enqueue(buffer)
        #endif
    }
}
