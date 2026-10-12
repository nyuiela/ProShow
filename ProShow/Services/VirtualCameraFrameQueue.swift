import Foundation
import Network
#if canImport(CoreVideo)
import CoreVideo
#endif

/// Localhost frame fan-out for the CoreMediaIO DAL extension (`ProShow Virtual Camera`).
/// Protocol: 32-byte header + BGRA payload (little-endian fields).
enum VirtualCameraFrameQueue {
    static let magic: UInt32 = 0x4356_5350 // "PSVC"
    static let defaultPort: UInt16 = 39217

    struct Header: Sendable {
        var width: Int
        var height: Int
        var presentationTime: TimeInterval
        var byteCount: Int
    }

    static func encodeHeader(_ header: Header) -> Data {
        var data = Data(count: 32)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            base[0] = magic.littleEndian
            base[1] = UInt32(header.width).littleEndian
            base[2] = UInt32(header.height).littleEndian
            base[3] = UInt32(header.byteCount).littleEndian
            let pts = header.presentationTime.bitPattern.littleEndian
            withUnsafeBytes(of: pts) { ptsBytes in
                memcpy(base.advanced(by: 4), ptsBytes.baseAddress!, 8)
            }
        }
        return data
    }

    static func decodeHeader(_ data: Data) -> Header? {
        guard data.count >= 32 else { return nil }
        let words = data.prefix(32).withUnsafeBytes { raw -> [UInt32] in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            return (0..<8).map { UInt32(littleEndian: base[$0]) }
        }
        guard words[0] == magic else { return nil }
        let width = Int(words[1])
        let height = Int(words[2])
        let byteCount = Int(words[3])
        let ptsBits = data.subdata(in: 16..<24).withUnsafeBytes { $0.load(as: UInt64.self) }
        let pts = TimeInterval(bitPattern: ptsBits.littleEndian)
        guard width > 0, height > 0, byteCount == width * height * 4 else { return nil }
        return Header(width: width, height: height, presentationTime: pts, byteCount: byteCount)
    }
}

/// Host-side listener: CMIO extension connects and reads the latest program frame.
final class VirtualCameraFramePublisher: @unchecked Sendable, CMIOVirtualCameraTransport {
    static let shared = VirtualCameraFramePublisher()

    private let queue = DispatchQueue(label: "com.kaleel.proshow.virtual-camera-ipc")
    private var loopback: LoopbackListener?
    private var clients: [NWConnection] = []
    private var latestPayload: Data?
    private var latestHeader: VirtualCameraFrameQueue.Header?
    private var onExtensionConnected: (@Sendable (Bool) -> Void)?

    var extensionConnected: Bool { !clients.isEmpty }

    func setExtensionConnectionHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        queue.async {
            self.onExtensionConnected = handler
            handler?(self.extensionConnected)
        }
    }

    func start(port: UInt16 = VirtualCameraFrameQueue.defaultPort) {
        queue.async {
            guard self.loopback == nil else { return }
            let box = LoopbackListener(
                queue: self.queue,
                portFileName: "virtual-camera-port",
                onConnection: { [weak self] connection in
                    self?.accept(connection)
                },
                onReady: { _ in }
            )
            self.loopback = box
            box.start(preferredPort: port)
        }
    }

    func stop() {
        queue.async {
            self.loopback?.cancel()
            self.loopback = nil
            self.clients.forEach { $0.cancel() }
            self.clients.removeAll()
            self.notifyConnection(false)
        }
    }

    #if canImport(CoreVideo)
    @discardableResult
    func publish(pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval) -> Bool {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let byteCount = width * height * 4
        var packed = Data(count: byteCount)
        packed.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            let srcBase = base.assumingMemoryBound(to: UInt8.self)
            if bytesPerRow == width * 4 {
                memcpy(dstBase, srcBase, byteCount)
            } else {
                for row in 0..<height {
                    memcpy(
                        dstBase.advanced(by: row * width * 4),
                        srcBase.advanced(by: row * bytesPerRow),
                        width * 4
                    )
                }
            }
        }
        let header = VirtualCameraFrameQueue.Header(
            width: width,
            height: height,
            presentationTime: presentationTime,
            byteCount: byteCount
        )
        queue.async {
            self.latestHeader = header
            self.latestPayload = packed
            self.flushToClients(header: header, payload: packed)
        }
        return true
    }
    #else
    @discardableResult
    func publish(pixelBuffer: CVPixelBuffer, presentationTime: TimeInterval) -> Bool { false }
    #endif

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        clients.append(connection)
        notifyConnection(true)
        if let header = latestHeader, let payload = latestPayload {
            sendFrame(connection, header: header, payload: payload)
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.drop(connection)
            }
            if case .cancelled = state {
                self?.drop(connection)
            }
        }
    }

    private func drop(_ connection: NWConnection) {
        clients.removeAll { $0 === connection }
        connection.cancel()
        notifyConnection(!clients.isEmpty)
    }

    private func notifyConnection(_ connected: Bool) {
        onExtensionConnected?(connected)
    }

    private func flushToClients(header: VirtualCameraFrameQueue.Header, payload: Data) {
        for client in clients {
            sendFrame(client, header: header, payload: payload)
        }
    }

    private func sendFrame(_ connection: NWConnection, header: VirtualCameraFrameQueue.Header, payload: Data) {
        var packet = VirtualCameraFrameQueue.encodeHeader(header)
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }
}
