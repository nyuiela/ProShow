import Foundation
import Network

enum ControlHTTP {
    static func parse(_ raw: String) -> (method: String, path: String, body: Data?) {
        let parts = raw.split(separator: "\r\n\r\n", maxSplits: 1, omittingEmptySubsequences: false)
        let header = String(parts.first ?? "")
        let start = header.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let tokens = start.split(separator: " ")
        let method = tokens.first.map(String.init)?.uppercased() ?? "GET"
        var path = tokens.dropFirst().first.map(String.init) ?? "/"
        if let query = path.firstIndex(of: "?") {
            path = String(path[..<query])
        }
        var body: Data?
        if parts.count > 1 {
            let remainder = String(parts[1])
            if let length = contentLength(in: header) {
                let bytes = Array(remainder.utf8.prefix(length))
                body = Data(bytes)
            } else if !remainder.isEmpty {
                body = Data(remainder.utf8)
            }
        }
        return (method, path, body)
    }

    static func contentLength(in header: String) -> Int? {
        header.split(separator: "\r\n").compactMap { line -> Int? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { return nil }
            return Int(pair[1].trimmingCharacters(in: .whitespaces))
        }.first
    }

    static func headerValue(_ name: String, in request: String) -> String? {
        let headerBlock = request.split(separator: "\r\n\r\n", maxSplits: 1).first.map(String.init) ?? request
        let needle = name.lowercased()
        for line in headerBlock.split(separator: "\r\n").dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == needle
            else { continue }
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func isWebSocketUpgrade(_ request: String) -> Bool {
        headerValue("Upgrade", in: request)?.lowercased() == "websocket"
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Error"
        }
    }

    static func allowedMethod(for path: String, method: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.last == "start" || parts.last == "stop" {
            return method == "POST"
        }
        if parts.contains("scenes"), parts.last == "trigger" {
            return method == "POST" || method == "GET"
        }
        if parts.contains("soundboard"), parts.last == "play" {
            return method == "POST"
        }
        if parts == ["v1", "chat", "overlay"]
            || parts == ["v1", "slides", "trigger"]
            || parts == ["v1", "slide", "next"]
            || parts == ["v1", "slides", "next"]
            || parts == ["v1", "slide", "prev"]
            || parts == ["v1", "slides", "prev"]
            || parts == ["v1", "audio", "mute"]
            || parts == ["v1", "layers", "mute"]
            || parts == ["v1", "layers", "mic"]
            || parts == ["v1", "layers", "program-mute"]
            || parts == ["v1", "camera", "switch"]
            || parts == ["v1", "market", "ticker"]
            || parts == ["v1", "project", "open"]
            || parts == ["v1", "project", "close"]
            || parts == ["v1", "backstage", "connect"]
            || parts == ["v1", "backstage", "disconnect"] {
            return method == "POST"
        }
        if parts == ["v1", "preflight"] || parts == ["v1", "telemetry"] || parts == ["v1", "ws"] {
            return method == "GET" || method == "POST"
        }
        if parts.count == 4, parts[0] == "v1", parts[1] == "backstage", parts[3] == "signal" {
            return method == "POST" || method == "GET"
        }
        if parts.count == 4, parts[0] == "v1", parts[1] == "chat", parts[2] == "ingest" {
            return method == "POST"
        }
        if method == "GET" { return true }
        return false
    }

    static func contentType(for path: String) -> String {
        if path == "/docs" || path == "/docs/" {
            return "text/html; charset=utf-8"
        }
        return "application/json"
    }

    static func jsonObject(_ data: Data?) -> [String: String] {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object.reduce(into: [:]) { result, pair in
            result[pair.key] = String(describing: pair.value)
        }
    }
}

/// Loopback `NWListener` with `SO_REUSEADDR` (`allowLocalEndpointReuse`).
/// A port another process is still listening on cannot be reused, so the next try uses an ephemeral port.
/// The bound port is written to Application Support so clients can find it.
final class LoopbackListener: @unchecked Sendable {
    static func portFileURL(_ name: String) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return folder.appendingPathComponent("ProShow", isDirectory: true).appendingPathComponent(name)
    }

    private let queue: DispatchQueue
    private let udp: Bool
    private let portFileName: String
    private let onConnection: @Sendable (NWConnection) -> Void
    private let onReady: @Sendable (UInt16) -> Void
    private var listener: NWListener?
    private var generation = 0

    init(
        queue: DispatchQueue,
        udp: Bool = false,
        portFileName: String,
        onConnection: @escaping @Sendable (NWConnection) -> Void,
        onReady: @escaping @Sendable (UInt16) -> Void
    ) {
        self.queue = queue
        self.udp = udp
        self.portFileName = portFileName
        self.onConnection = onConnection
        self.onReady = onReady
    }

    func start(preferredPort: UInt16) {
        queue.async {
            self.generation += 1
            self.bind(port: preferredPort, token: self.generation, fallback: true)
        }
    }

    func cancel() {
        queue.async {
            self.generation += 1
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private func bind(port: UInt16, token: Int, fallback: Bool) {
        guard token == generation else { return }
        listener?.cancel()
        listener = nil
        let parameters = udp ? NWParameters.udp : NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = port == 0 ? NWEndpoint.Port.any : (NWEndpoint.Port(rawValue: port) ?? .any)
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(loopback), port: endpointPort)
        }
        guard let created = try? NWListener(using: parameters) else { return }
        created.newConnectionHandler = { [weak self] connection in
            self?.onConnection(connection)
        }
        created.stateUpdateHandler = { [weak self] state in
            guard let self, token == self.generation else { return }
            switch state {
            case .ready:
                let bound = created.port?.rawValue ?? port
                self.writePort(bound)
                self.onReady(bound)
            case .failed:
                created.cancel()
                if self.listener === created {
                    self.listener = nil
                }
                if fallback, port != 0 {
                    self.bind(port: 0, token: token, fallback: false)
                }
            default:
                break
            }
        }
        listener = created
        created.start(queue: queue)
    }

    private func writePort(_ port: UInt16) {
        let url = Self.portFileURL(portFileName)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(String(port).utf8).write(to: url, options: .atomic)
    }
}

/// Localhost OpenAPI-style control surface for agent automation.
final class ControlAPIServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 55076
    static let maxConnections = 8
    static let portFileName = "control-port"

    private var loopback: LoopbackListener?
    private let queue = DispatchQueue(label: "com.kaleel.proshow.control-api")
    private var handler: (@Sendable (String, String, Data?) async -> (Int, String))?
    private var telemetry: (@Sendable () async -> String)?
    private var webSocketEnabled = false
    private var backstageWebSocketHandler: (@Sendable (String, String) async -> String?)?
    private var sockets: [NWConnection] = []
    private var requestedPort: UInt16
    private(set) var boundPort: UInt16

    init(port: UInt16 = ControlAPIServer.defaultPort) {
        requestedPort = port
        boundPort = port
    }

    var port: UInt16 { boundPort }

    func start(
        port: UInt16? = nil,
        webSocketEnabled: Bool = false,
        telemetry: (@Sendable () async -> String)? = nil,
        backstageWebSocketHandler: (@Sendable (String, String) async -> String?)? = nil,
        handler: @escaping @Sendable (String, String, Data?) async -> (Int, String)
    ) {
        stop()
        if let port {
            requestedPort = port
            boundPort = port
        }
        self.webSocketEnabled = webSocketEnabled
        self.telemetry = telemetry
        self.backstageWebSocketHandler = backstageWebSocketHandler
        self.handler = handler
        boundPort = 0
        let box = LoopbackListener(
            queue: queue,
            portFileName: Self.portFileName,
            onConnection: { [weak self] connection in
                self?.acceptIncoming(connection)
            },
            onReady: { [weak self] port in
                self?.boundPort = port
            }
        )
        loopback = box
        box.start(preferredPort: requestedPort)
    }

    func stop() {
        loopback?.cancel()
        loopback = nil
        handler = nil
        telemetry = nil
        webSocketEnabled = false
        backstageWebSocketHandler = nil
        for socket in sockets {
            socket.cancel()
        }
        sockets.removeAll()
    }

    func waitUntilReady(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> UInt16 {
        let steps = max(1, Int(timeoutNanoseconds / 40_000_000))
        for _ in 0..<steps {
            if boundPort != 0 { return boundPort }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return boundPort
    }

    private func acceptIncoming(_ connection: NWConnection) {
        if sockets.count >= Self.maxConnections {
            connection.cancel()
            return
        }
        sockets.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.sockets.removeAll { $0 === connection }
            default:
                break
            }
        }
        accept(connection)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            if ControlHTTP.isWebSocketUpgrade(request) {
                self.handleWebSocketUpgrade(connection, request: request, parsed: ControlHTTP.parse(request))
                return
            }
            let parsed = ControlHTTP.parse(request)
            Task {
                let result: (Int, String)
                if !ControlHTTP.allowedMethod(for: parsed.path, method: parsed.method) {
                    result = (405, #"{"ok":false,"error":"method_not_allowed"}"#)
                } else {
                    result = await self.handler?(parsed.method, parsed.path, parsed.body)
                        ?? (404, "{\"error\":\"unbound\"}")
                }
                self.reply(connection, status: result.0, path: parsed.path, body: result.1)
            }
        }
    }

    private func handleWebSocketUpgrade(
        _ connection: NWConnection,
        request: String,
        parsed: (method: String, path: String, body: Data?)
    ) {
        let path = parsed.path
        let backstageSignal = path.split(separator: "/").map(String.init).count == 4
            && path.hasPrefix("/v1/backstage/")
            && path.hasSuffix("/signal")
        guard path == "/v1/telemetry" || path == "/v1/ws" || backstageSignal else {
            reply(connection, status: 404, path: path, body: #"{"ok":false,"error":"not_found"}"#)
            return
        }
        guard webSocketEnabled else {
            reply(connection, status: 403, path: path, body: #"{"ok":false,"error":"websocket_disabled"}"#)
            return
        }
        guard let key = ControlHTTP.headerValue("Sec-WebSocket-Key", in: request), !key.isEmpty else {
            reply(connection, status: 400, path: path, body: #"{"ok":false,"error":"missing_websocket_key"}"#)
            return
        }
        let accept = ControlWebSocket.acceptKey(key)
        if !sockets.contains(where: { $0 === connection }) {
            sockets.append(connection)
        }
        connection.send(content: ControlWebSocket.handshake(accept: accept), completion: .contentProcessed { [weak self] _ in
            self?.pumpWebSocket(connection, path: path)
        })
    }

    private func pumpWebSocket(_ connection: NWConnection, path: String) {
        Task { [weak self] in
            guard let self else { return }
            var last = ""
            if path == "/v1/telemetry" || path == "/v1/ws",
               let snapshot = await self.telemetry?(), !snapshot.isEmpty {
                last = snapshot
                self.sendWebSocket(connection, ControlWebSocket.encodeText(snapshot))
            }
            self.receiveWebSocket(connection, path: path)
            while self.sockets.contains(where: { $0 === connection }) {
                try? await Task.sleep(nanoseconds: 16_000_000)
                guard path == "/v1/telemetry" || path == "/v1/ws" else { continue }
                guard let snapshot = await self.telemetry?() else { continue }
                if snapshot != last {
                    last = snapshot
                    self.sendWebSocket(connection, ControlWebSocket.encodeText(snapshot))
                }
            }
        }
    }

    private func receiveWebSocket(_ connection: NWConnection, path: String) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 16_384) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data, let frame = ControlWebSocket.decode(data) {
                switch frame.opcode {
                case 0x8:
                    self.dropSocket(connection)
                    return
                case 0x9:
                    self.sendWebSocket(connection, ControlWebSocket.encodePong(frame.payload))
                case 0x1:
                    if let text = String(data: frame.payload, encoding: .utf8) {
                        Task {
                            if let response = await self.backstageWebSocketHandler?(path, text) {
                                self.sendWebSocket(connection, ControlWebSocket.encodeText(response))
                            }
                        }
                    }
                default:
                    break
                }
            }
            if isComplete {
                self.dropSocket(connection)
                return
            }
            self.receiveWebSocket(connection, path: path)
        }
    }

    private func sendWebSocket(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func dropSocket(_ connection: NWConnection) {
        sockets.removeAll { $0 === connection }
        connection.cancel()
    }

    private func reply(_ connection: NWConnection, status: Int, path: String, body: String) {
        let payload = body.data(using: .utf8) ?? Data()
        var response = "HTTP/1.1 \(status) \(ControlHTTP.reason(status))\r\n"
        response += "Content-Type: \(ControlHTTP.contentType(for: path))\r\n"
        response += "Content-Length: \(payload.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var packet = Data(response.utf8)
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
