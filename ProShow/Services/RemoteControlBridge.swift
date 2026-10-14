import Foundation

enum RemoteControlCommand: Hashable, Sendable {
    case nextSlide
    case previousSlide
    case triggerSlide(index: Int)
    case triggerMacro(UUID)
    case clearLayer(String)
    case muteAudio(channel: Int?, muted: Bool)
    case switchCamera(sourceID: String)
    case preflight
    case status
}

struct MIDIControlBinding: Hashable, Codable, Sendable {
    var status: UInt8
    var data1: UInt8
    var command: String
}

struct MIDIControlMap: Hashable, Codable, Sendable {
    var bindings: [MIDIControlBinding]

    static let `default` = MIDIControlMap(bindings: [
        MIDIControlBinding(status: 0x90, data1: 60, command: "slide.next"),
        MIDIControlBinding(status: 0x90, data1: 61, command: "slide.prev"),
        MIDIControlBinding(status: 0xB0, data1: 7, command: "audio.mute"),
    ])
}

/// Maps Stream Deck, Companion, OSC, MIDI, and REST aliases onto ShowController.
enum RemoteControlBridge {
    static func parseOSC(_ path: String, arguments: [String] = []) -> RemoteControlCommand? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "proshow" else { return nil }
        switch parts.dropFirst().joined(separator: "/") {
        case "slide/next":
            return .nextSlide
        case "slide/prev", "slide/previous":
            return .previousSlide
        case "macro/trigger":
            guard let raw = arguments.first, let id = UUID(uuidString: raw) else { return nil }
            return .triggerMacro(id)
        case "audio/mute":
            let muted = arguments.last.map { $0 == "1" || $0.lowercased() == "true" } ?? true
            let channel = arguments.first.flatMap(Int.init)
            return .muteAudio(channel: channel, muted: muted)
        case "camera/switch":
            guard let source = arguments.first, !source.isEmpty else { return nil }
            return .switchCamera(sourceID: source)
        case "preflight":
            return .preflight
        case "status":
            return .status
        default:
            break
        }
        if parts.count >= 4, parts[1] == "clear", parts[2] == "layer" {
            return .clearLayer(parts[3])
        }
        if parts.count >= 3, parts[1] == "slide", let index = Int(parts[2]) {
            return .triggerSlide(index: index)
        }
        return nil
    }

    static func parseMIDI(status: UInt8, data1: UInt8, data2: UInt8, map: MIDIControlMap = .default) -> RemoteControlCommand? {
        let masked = status & 0xF0
        guard let binding = map.bindings.first(where: { $0.status == masked && $0.data1 == data1 }) else {
            return nil
        }
        switch binding.command {
        case "slide.next":
            return data2 > 0 ? .nextSlide : nil
        case "slide.prev":
            return data2 > 0 ? .previousSlide : nil
        case "audio.mute":
            return .muteAudio(channel: nil, muted: data2 < 64)
        case "preflight":
            return data2 > 0 ? .preflight : nil
        default:
            return nil
        }
    }

    static func parseREST(method: String, path: String, body: [String: String]) -> RemoteControlCommand? {
        let parts = path.split(separator: "/").map(String.init)
        if method == "POST" || method == "GET" {
            if parts == ["v1", "slide", "next"] || parts == ["v1", "slides", "next"] {
                return .nextSlide
            }
            if parts == ["v1", "slide", "prev"] || parts == ["v1", "slides", "prev"] {
                return .previousSlide
            }
            if parts == ["v1", "preflight"] {
                return .preflight
            }
            if parts == ["v1", "telemetry"] || parts == ["v1", "ws"] {
                return .status
            }
        }
        if method == "POST", parts == ["v1", "audio", "mute"] {
            // JSON booleans arrive as "1"/"0" (NSNumber description), strings as "true"/"false".
            let raw = (body["muted"] ?? "true").lowercased()
            let muted = !["false", "0", "no", "off"].contains(raw)
            return .muteAudio(channel: body["channel"].flatMap(Int.init), muted: muted)
        }
        if method == "POST", parts == ["v1", "camera", "switch"] {
            if let source = body["source_id"] ?? body["source"], !source.isEmpty {
                return .switchCamera(sourceID: source)
            }
        }
        return nil
    }

    @MainActor
    static func apply(_ command: RemoteControlCommand, to controller: ShowController) -> (Int, String) {
        switch command {
        case .nextSlide:
            controller.advance()
            return (200, ControlJSON.encode(["ok": true, "action": "next", "index": controller.liveIndex as Any? ?? NSNull()]))
        case .previousSlide:
            controller.goPrevious()
            return (200, ControlJSON.encode(["ok": true, "action": "prev", "index": controller.liveIndex as Any? ?? NSNull()]))
        case .triggerSlide(let index):
            let ok = controller.triggerSlide(presentationID: nil, index: index)
            return (ok ? 200 : 404, ControlJSON.encode(["ok": ok, "action": "trigger_slide_index", "index": index]))
        case .triggerMacro(let id):
            let ok = controller.triggerMacro(id: id)
            return (ok ? 200 : 404, ControlJSON.encode(["ok": ok, "action": "macro_trigger"]))
        case .clearLayer(let name):
            let ok = controller.clearLayer(named: name)
            return (ok ? 200 : 404, ControlJSON.encode(["ok": ok, "layer": name]))
        case .muteAudio(let channel, let muted):
            let ok = controller.muteRemoteAudio(channel: channel, muted: muted)
            return (ok ? 200 : 404, ControlJSON.encode(["ok": ok, "action": "mute", "muted": muted]))
        case .switchCamera(let sourceID):
            let ok = controller.switchCameraInput(sourceID: sourceID)
            return (ok ? 200 : 404, ControlJSON.encode(["ok": ok, "action": "camera_switch", "source_id": sourceID]))
        case .preflight:
            let report = controller.runPreFlight(intent: .inspect, handshake: nil)
            return (200, ControlJSON.encode(report.jsonObject))
        case .status:
            return (200, ControlJSON.encode(telemetryJSON(controller)))
        }
    }

    @MainActor
    static func telemetryJSON(_ controller: ShowController) -> [String: Any] {
        [
            "ok": true,
            "is_streaming": controller.streaming.isLive,
            "is_recording": controller.isoRecorder.isRecording,
            "active_slide_index": controller.liveIndex as Any? ?? NSNull(),
            "live_slide_id": controller.liveSlideID?.uuidString ?? NSNull(),
            "show_id": controller.show.id.uuidString,
            "ndi_available": NDIRuntime.isAvailable,
            "preflight_ok": controller.lastPreFlight?.canProceed ?? NSNull(),
            "audience_on": controller.isAudienceOutputOn,
            "stage_on": controller.isStageOutputOn,
        ]
    }
}

enum OSCPacketCodec {
    static func parse(_ data: Data) -> (address: String, arguments: [String])? {
        guard !data.isEmpty else { return nil }
        if data.starts(with: Array("#bundle".utf8)) {
            return parseBundle(data)
        }
        return parseMessage(data)
    }

    static func encode(address: String, arguments: [String] = []) -> Data {
        var data = paddedString(address)
        var tags = ","
        for _ in arguments { tags.append("s") }
        data.append(paddedString(tags))
        for argument in arguments {
            data.append(paddedString(argument))
        }
        return data
    }

    private static func parseBundle(_ data: Data) -> (address: String, arguments: [String])? {
        var offset = 0
        guard readPaddedString(data, offset: &offset) == "#bundle" else { return nil }
        offset += 8
        while offset + 4 <= data.count {
            let size = Int(int32(data, offset: offset))
            offset += 4
            guard size > 0, offset + size <= data.count else { break }
            if let message = parse(data.subdata(in: offset..<(offset + size))) {
                return message
            }
            offset += size
        }
        return nil
    }

    private static func parseMessage(_ data: Data) -> (address: String, arguments: [String])? {
        var offset = 0
        guard let address = readPaddedString(data, offset: &offset), address.hasPrefix("/") else {
            return nil
        }
        guard let tags = readPaddedString(data, offset: &offset), tags.hasPrefix(",") else {
            return (address, [])
        }
        var arguments: [String] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "s":
                if let value = readPaddedString(data, offset: &offset) {
                    arguments.append(value)
                }
            case "i":
                if offset + 4 <= data.count {
                    arguments.append(String(Int(int32(data, offset: offset))))
                    offset += 4
                }
            case "f":
                if offset + 4 <= data.count {
                    arguments.append(String(float32(data, offset: offset)))
                    offset += 4
                }
            case "T":
                arguments.append("true")
            case "F":
                arguments.append("false")
            default:
                break
            }
        }
        return (address, arguments)
    }

    private static func paddedString(_ value: String) -> Data {
        var bytes = Array(value.utf8)
        bytes.append(0)
        while bytes.count % 4 != 0 { bytes.append(0) }
        return Data(bytes)
    }

    private static func readPaddedString(_ data: Data, offset: inout Int) -> String? {
        guard offset < data.count else { return nil }
        var end = offset
        while end < data.count, data[end] != 0 { end += 1 }
        let text = String(data: data[offset..<end], encoding: .utf8)
        let length = end - offset + 1
        offset += (length + 3) & ~3
        return text
    }

    private static func int32(_ data: Data, offset: Int) -> Int32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return Int32(bigEndian: Int32(bitPattern: UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])))
    }

    private static func float32(_ data: Data, offset: Int) -> Float {
        Float(bitPattern: UInt32(bitPattern: int32(data, offset: offset)))
    }
}
