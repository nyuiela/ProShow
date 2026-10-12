import CryptoKit
import Foundation

/// RFC 6455 framing for the localhost Control API telemetry socket.
enum ControlWebSocket {
    static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    static func acceptKey(_ key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    static func handshake(accept: String) -> Data {
        Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
    }

    static func encodeText(_ text: String) -> Data {
        encode(opcode: 0x1, payload: Data(text.utf8))
    }

    static func encodePong(_ payload: Data) -> Data {
        encode(opcode: 0xA, payload: payload)
    }

    static func encodeClose() -> Data {
        encode(opcode: 0x8, payload: Data())
    }

    struct Frame: Equatable {
        var opcode: UInt8
        var payload: Data
    }

    static func decode(_ data: Data) -> Frame? {
        guard data.count >= 2 else { return nil }
        let bytes = [UInt8](data)
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = 0
            for i in 0..<8 {
                length = (length << 8) | Int(bytes[2 + i])
            }
            offset = 10
        }
        var mask = [UInt8](repeating: 0, count: 4)
        if masked {
            guard bytes.count >= offset + 4 else { return nil }
            mask = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }
        guard bytes.count >= offset + length else { return nil }
        var payload = Array(bytes[offset..<(offset + length)])
        if masked {
            for i in payload.indices {
                payload[i] ^= mask[i % 4]
            }
        }
        return Frame(opcode: opcode, payload: Data(payload))
    }

    private static func encode(opcode: UInt8, payload: Data) -> Data {
        var out = Data()
        out.append(0x80 | opcode)
        let count = payload.count
        if count < 126 {
            out.append(UInt8(count))
        } else if count <= 65_535 {
            out.append(126)
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(127)
            var length = UInt64(count)
            var encoded = [UInt8](repeating: 0, count: 8)
            for i in (0..<8).reversed() {
                encoded[i] = UInt8(length & 0xFF)
                length >>= 8
            }
            out.append(contentsOf: encoded)
        }
        out.append(payload)
        return out
    }
}
