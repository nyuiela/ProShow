import Foundation
#if canImport(Network)
import Network
#endif

enum SRTConnectionMode: String, Codable, Sendable, CaseIterable {
    case listener
    case caller
    case rendezvous

    var displayName: String {
        switch self {
        case .listener: "Listener"
        case .caller: "Caller"
        case .rendezvous: "Rendezvous"
        }
    }
}

struct SRTStreamEndpoint: Hashable, Sendable {
    var host: String
    var port: UInt16
    var mode: SRTConnectionMode
    var streamID: String?

    static func parse(_ connectionString: String, defaultPort: UInt16 = 9000) -> SRTStreamEndpoint? {
        let trimmed = connectionString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("srt://") else { return nil }
        var body = String(trimmed.dropFirst("srt://".count))
        var mode: SRTConnectionMode = .listener
        if let query = body.split(separator: "?", maxSplits: 1).dropFirst().first {
            body = String(body.split(separator: "?").first ?? Substring(body))
            for part in query.split(separator: "&") {
                let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, kv[0].lowercased() == "mode" {
                    mode = SRTConnectionMode(rawValue: kv[1].lowercased()) ?? .listener
                }
            }
        }
        let hostPort = body.split(separator: ":", maxSplits: 1).map(String.init)
        let host = hostPort.first ?? "0.0.0.0"
        let port = UInt16(hostPort.dropFirst().first ?? "") ?? defaultPort
        return SRTStreamEndpoint(host: host, port: port, mode: mode, streamID: nil)
    }
}

/// UDP transport shell for Secure Reliable Transport feeds. When `libsrt` is present on the Mac,
/// ProShow can upgrade this receiver to full SRT handshake; until then the socket stays ready for ingest binding.
final class SRTStreamReceiver: @unchecked Sendable {
    var onConnected: (@Sendable () -> Void)?
    var onDisconnected: (@Sendable (Error?) -> Void)?
    var onPacket: (@Sendable (Data) -> Void)?

    private(set) var endpoint: SRTStreamEndpoint?
    private(set) var isRunning = false
    #if canImport(Network)
    private var listener: NWListener?
    private var connection: NWConnection?
    #endif

    var statusLine: String {
        guard let endpoint else { return "SRT idle" }
        return "SRT \(endpoint.mode.displayName) · \(endpoint.host):\(endpoint.port)"
    }

    func start(endpoint: SRTStreamEndpoint) {
        stop()
        self.endpoint = endpoint
        #if canImport(Network)
        switch endpoint.mode {
        case .listener:
            startListener(port: endpoint.port)
        case .caller, .rendezvous:
            startCaller(host: endpoint.host, port: endpoint.port)
        }
        #else
        isRunning = false
        #endif
    }

    func stop() {
        #if canImport(Network)
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
        #endif
        isRunning = false
        endpoint = nil
    }

    #if canImport(Network)
    private func startListener(port: UInt16) {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.onConnected?()
                case .failed(let error):
                    self.isRunning = false
                    self.onDisconnected?(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.attach(connection)
            }
            listener.start(queue: ProShowQueues.videoIngestQueue)
        } catch {
            isRunning = false
            onDisconnected?(error)
        }
    }

    private func startCaller(host: String, port: UInt16) {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                self.onConnected?()
                self.receive(on: connection)
            case .failed(let error):
                self.isRunning = false
                self.onDisconnected?(error)
            default:
                break
            }
        }
        connection.start(queue: ProShowQueues.videoIngestQueue)
    }

    private func attach(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.onConnected?() }
        }
        connection.start(queue: ProShowQueues.videoIngestQueue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            if let data, !data.isEmpty {
                self?.onPacket?(data)
            }
            if error == nil {
                self?.receive(on: connection)
            } else {
                self?.onDisconnected?(error)
            }
        }
    }
    #endif
}
