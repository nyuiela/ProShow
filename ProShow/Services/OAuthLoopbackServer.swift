import Foundation
import Darwin

/// Localhost callback for desktop OAuth. The registered redirect string is sent unchanged.
final class OAuthLoopbackServer: @unchecked Sendable {
    let redirect: URL
    /// BSD sockets on 127.0.0.1 and ::1 with SO_REUSEADDR. A loopback-specific bind
    /// takes the callback even when another app (n8n in Docker on 5678) holds the
    /// wildcard port; NWListener fails with EADDRINUSE there and the browser lands on
    /// that app instead. ::1 matters because browsers try it first for `localhost`.
    private var sources: [DispatchSourceRead] = []
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
        let v4 = Self.listenSocket(ipv6: false, port: port)
        let v6 = Self.listenSocket(ipv6: true, port: port)
        // The browser connects to the family the redirect host names. If that
        // bind failed, another listener (Docker, n8n) could receive the code.
        let need = Self.requiredFamilies(host: redirect.host ?? "")
        if (need.v4 && v4 == nil) || (need.v6 && v6 == nil) {
            [v4, v6].compactMap { $0 }.forEach { Darwin.close($0) }
            throw StreamOAuthError.providerRejected("Port \(port) is in use")
        }
        let sockets = [v4, v6].compactMap { $0 }
        guard !sockets.isEmpty else { throw StreamOAuthError.invalidCallback }
        for fd in sockets {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard let self else { Darwin.close(client); return }
                self.accept(client)
            }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    func waitUntilReady(timeoutNanoseconds: UInt64 = 2_000_000_000) async {
        let steps = max(1, Int(timeoutNanoseconds / 40_000_000))
        for _ in 0..<steps {
            if !sources.isEmpty { return }
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
        sources.forEach { $0.cancel() }
        sources = []
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: StreamOAuthError.cancelled)
        }
    }

    /// Listening socket bound to the loopback address only, or nil if the bind fails.
    /// 127.0.0.1 needs IPv4, [::1] needs IPv6, localhost needs both.
    static func requiredFamilies(host: String) -> (v4: Bool, v6: Bool) {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "::1" { return (false, true) }
        if h == "localhost" { return (true, true) }
        return (true, false)
    }

    static func listenSocket(ipv6: Bool, port: UInt16) -> Int32? {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, size)
        let bound: Int32
        if ipv6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, size)
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private func accept(_ client: Int32) {
        // Accepted sockets inherit O_NONBLOCK; read the request with a short timeout instead.
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let count = read(client, &buffer, buffer.count)
        guard count > 0, let request = String(bytes: buffer[0..<count], encoding: .utf8) else {
            Darwin.close(client)
            return
        }
        switch Self.result(from: request, registered: redirect) {
        case .ignore:
            reply(client, status: "404 Not Found", body: Data())
        case .accepted(let callback):
            let signedIn = (try? StreamPKCE.authorizationCode(from: callback)) != nil
            let message = signedIn
                ? "Signed in. You can close this tab and return to ProShow."
                : "Could not finish sign-in. You can close this tab and return to ProShow."
            let html = Data("<!doctype html><meta charset=\"utf-8\"><title>ProShow</title><p>\(message)</p>".utf8)
            reply(client, status: "200 OK", body: html)
            if let continuation {
                self.continuation = nil
                continuation.resume(returning: callback)
            }
        }
    }

    private func reply(_ client: Int32, status: String, body: Data) {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var packet = Data(response.utf8)
        packet.append(body)
        packet.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = write(client, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if sent <= 0 { break }
                offset += sent
            }
        }
        Darwin.close(client)
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
