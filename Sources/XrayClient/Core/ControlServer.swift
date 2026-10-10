// macOS-only.
#if os(macOS)
import Foundation
import Network

/// Parses just enough HTTP to serve the control API.
///
/// A dependency-free listener beats adding a web framework for fourteen
/// endpoints, but it does mean being explicit about the limits: one request at
/// a time, a bounded header block, a bounded body, and no keep-alive.
enum ControlHTTP {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 4 * 1024 * 1024

    enum ParseResult {
        case incomplete
        case request(ControlRequest)
        case failure(String)
    }

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = range(of: Data("\r\n\r\n".utf8), in: buffer) else {
            return buffer.count > maxHeaderBytes
                ? .failure("header block too large")
                : .incomplete
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .failure("headers are not text")
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .failure("empty request") }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .failure("bad request line") }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared <= maxBodyBytes else { return .failure("body too large") }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= declared else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + declared)]

        var path = target
        var query: [String: String] = [:]
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark])
            for pair in target[target.index(after: mark)...].split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let value = parts.count > 1
                    ? (String(parts[1]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? String(parts[1]))
                    : ""
                query[key] = value
            }
        }

        var token: String?
        if let authorization = headers["authorization"],
           authorization.lowercased().hasPrefix("bearer ") {
            token = String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }

        return .request(ControlRequest(method: method, path: path, query: query,
                                       body: Data(body), token: token,
                                       origin: headers["origin"]))
    }

    static func response(_ response: ControlResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        // The API is for a local caller with a token, never for a web page.
        head += "Access-Control-Allow-Origin: null\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "Status"
        }
    }

    /// Where `needle` first occurs, as offsets from the start of `haystack`.
    /// The buffer is re-parsed after every chunk, so this must not copy it.
    private static func range(of needle: Data, in haystack: Data) -> Range<Int>? {
        guard let found = haystack.range(of: needle) else { return nil }
        let base = haystack.startIndex
        return (found.lowerBound - base)..<(found.upperBound - base)
    }
}

/// Serves the control API on the loopback.
///
/// Bound to 127.0.0.1 and gated on a bearer token that lives in the keychain,
/// because anything that can reach this port can change where the machine's
/// traffic goes.
@MainActor
@Observable
final class ControlServer {

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var port: Int = 0

    var onLog: ((String) -> Void)?

    private var listener: NWListener?
    private var router: ControlRouter?

    /// The token callers present. Created once and kept in the keychain so an
    /// assistant configured yesterday still works today.
    static func token() -> String {
        if let existing = Keychain.get(account: KeychainAccount.apiToken),
           !existing.isEmpty {
            return existing
        }
        let fresh = (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        _ = Keychain.set(fresh, account: KeychainAccount.apiToken)
        return fresh
    }

    /// Forgets the current token and issues a new one, which revokes every
    /// caller configured with the old one.
    @discardableResult
    static func rotateToken() -> String {
        _ = Keychain.remove(account: KeychainAccount.apiToken)
        return token()
    }

    func start(port: Int, backend: ControlBackend, token: String = ControlServer.token()) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            lastError = "port \(port) is out of range"
            return
        }
        let parameters = NWParameters.tcp
        // Loopback only: nothing off this machine may reach the API, whatever
        // the firewall happens to allow. The interface requirement alone still
        // bound the wildcard address — the socket showed up as `*:port` — so the
        // listener is pinned to 127.0.0.1 itself.
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters)
            self.router = ControlRouter(backend: backend, token: token)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                    case .failed(let error):
                        self?.isRunning = false
                        self?.lastError = error.localizedDescription
                        self?.onLog?("[control] listener failed: \(error.localizedDescription)\n")
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            self.port = port
        } catch {
            lastError = error.localizedDescription
            onLog?("[control] could not listen on \(port): \(error.localizedDescription)\n")
        }
    }

    /// Brings the listener in line with the settings — started on the right
    /// port when the API is on, stopped when it is off.
    func sync(settings: AppSettings, store: ServerStore, connection: ConnectionManager) {
        guard settings.veilAPIEnabled else {
            stop()
            return
        }
        if isRunning && port == settings.veilAPIPort { return }
        start(port: settings.veilAPIPort,
              backend: AppControlBackend(store: store, connection: connection))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        router = nil
        isRunning = false
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback
        case .name(let name, _): return name == "localhost"
        @unknown default: return false
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        // Belt and braces: the listener is already bound to the loopback, but
        // a peer that is not on it has no business here either way.
        guard ControlServer.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                if error != nil { connection.cancel(); return }
                var buffer = buffer
                if let chunk { buffer.append(chunk) }

                switch ControlHTTP.parse(buffer) {
                case .incomplete:
                    if isComplete { connection.cancel(); return }
                    self.receive(connection, buffer: buffer)
                case .failure(let message):
                    self.send(.error(message, status: 400), on: connection)
                case .request(let request):
                    guard let router = self.router else {
                        self.send(.error("control api is off", status: 403), on: connection)
                        return
                    }
                    self.send(router.handle(request), on: connection)
                }
            }
        }
    }

    private func send(_ response: ControlResponse, on connection: NWConnection) {
        connection.send(content: ControlHTTP.response(response),
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
