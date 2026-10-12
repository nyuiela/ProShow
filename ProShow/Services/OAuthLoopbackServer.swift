import Foundation
import Network

/// Localhost callback for desktop OAuth. The registered redirect string is sent unchanged.
final class OAuthLoopbackServer: @unchecked Sendable {
    let redirect: URL
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.kaleel.proshow.oauth-loopback")
    private var continuation: CheckedContinuation<URL, Error>?

    init(redirect: URL) {
        self.redirect = redirect
    }

    var callbackURL: URL { redirect }

    func start() throws {
        stop()
        guard let port = StreamOAuthConfiguration.loopbackPort(in: redirect) else {
            throw StreamOAuthError.invalidCallback
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let endpointPort = NWEndpoint.Port(rawValue: port) ?? .any
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(loopback),
                port: endpointPort
            )
        }
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func waitUntilReady(timeoutNanoseconds: UInt64 = 2_000_000_000) async {
        let steps = max(1, Int(timeoutNanoseconds / 40_000_000))
        for _ in 0..<steps {
            if listener != nil { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    func waitForCallback(timeoutNanoseconds: UInt64 = 180_000_000_000) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    self.queue.sync {
                        self.continuation = continuation
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw StreamOAuthError.cancelled
            }
            guard let url = try await group.next() else {
                throw StreamOAuthError.invalidCallback
            }
            group.cancelAll()
            return url
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: StreamOAuthError.cancelled)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            switch Self.result(from: request, registered: self.redirect) {
            case .ignore:
                self.reply(connection, status: "404 Not Found", body: Data())
            case .accepted(let callback):
                let signedIn = (try? StreamPKCE.authorizationCode(from: callback)) != nil
                let message = signedIn
                    ? "Signed in. You can close this tab and return to ProShow."
                    : "Could not finish sign-in. You can close this tab and return to ProShow."
                let html = Data("<!doctype html><meta charset=\"utf-8\"><title>ProShow</title><p>\(message)</p>".utf8)
                self.reply(connection, status: "200 OK", body: html)
                if let continuation = self.continuation {
                    self.continuation = nil
                    continuation.resume(returning: callback)
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, status: String, body: Data) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var packet = Data(response.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func result(from request: String, registered: URL) -> OAuthLoopbackResult {
        let start = request.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let tokens = start.split(separator: " ")
        guard tokens.count >= 2 else { return .ignore }
        let method = String(tokens[0]).uppercased()
        if method == "HEAD" || method == "OPTIONS" { return .ignore }
        let target = String(tokens[1])
        guard var incoming = URLComponents(string: "http://127.0.0.1\(target)") else { return .ignore }
        if isIgnorablePath(incoming.path) { return .ignore }
        guard var outgoing = URLComponents(url: registered, resolvingAgainstBaseURL: false) else { return .ignore }
        outgoing.query = incoming.query
        let items = incoming.queryItems ?? []
        let hasCode = items.contains { $0.name == "code" && !($0.value ?? "").isEmpty }
        let hasError = items.contains { $0.name == "error" && !($0.value ?? "").isEmpty }
        if hasCode || hasError, let url = outgoing.url {
            return .accepted(url)
        }
        let incomingPath = normalizedPath(incoming.path)
        let registeredPath = normalizedPath(outgoing.path)
        if incomingPath == registeredPath, let url = outgoing.url {
            return .accepted(url)
        }
        return .ignore
    }

    static func callbackURL(from request: String, registered: URL) -> URL? {
        if case .accepted(let url) = result(from: request, registered: registered) {
            return url
        }
        return nil
    }

    static func callbackURL(from request: String) -> URL? {
        callbackURL(from: request, registered: StreamOAuthConfiguration.loopbackCallback())
    }

    private static func isIgnorablePath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "favicon.ico"
            || name == "robots.txt"
            || name.hasSuffix(".png")
            || name.hasSuffix(".ico")
            || name.hasSuffix(".svg")
    }

    private static func normalizedPath(_ path: String) -> String {
        if path.isEmpty { return "/" }
        if path.count > 1, path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }
}

enum OAuthLoopbackResult: Equatable {
    case ignore
    case accepted(URL)
}
