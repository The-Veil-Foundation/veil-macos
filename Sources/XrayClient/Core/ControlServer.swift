// macOS-only.
#if os(macOS)
import Foundation

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

        return .request(ControlRequest(method: method, path: path, query: query,
                                       body: Data(body),
                                       origin: headers["origin"]))
    }

    static func response(_ response: ControlResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        // The API is for a local process, never for a web page.
        head += "Access-Control-Allow-Origin: null\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
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


/// Where the app listens and `Veil mcp` connects.
///
/// A Unix socket in Veil's own `0700` support directory, so the file system
/// decides who may talk to it: the same user account, and nobody else. That
/// is the whole of the authentication — there is no token to copy, leak or
/// rotate, and no port a web page could reach.
enum ControlSocket {
    static var url: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("XrayClient/mcp.sock")
    }

    /// The `sockaddr_un` for `path`, or nil when it does not fit (104 bytes).
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}

/// Serves the control API on a Unix socket for the MCP bridge.
///
/// Anything that can reach this socket can change where the machine's traffic
/// goes, so it exists only while AI access is allowed, lives in a directory
/// only the user can enter, is itself `0600`, and still checks that every peer
/// runs as the same user.
@MainActor
@Observable
final class ControlServer {

    private(set) var isRunning = false
    private(set) var lastError: String?
    private(set) var path = ""

    var onLog: ((String) -> Void)?

    private var source: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var router: ControlRouter?

    func start(at path: String = ControlSocket.url.path, backend: ControlBackend) {
        stop()
        SecureFile.ensureDirectory(URL(fileURLWithPath: path).deletingLastPathComponent())
        guard var address = ControlSocket.address(path) else {
            lastError = "socket path is too long"
            return
        }
        // A socket file left by a crash refuses the bind until it is gone.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail("socket") }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            fail("listen")
            close(fd)
            unlink(path)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptPending() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()

        self.source = source
        self.listenFD = fd
        self.router = ControlRouter(backend: backend)
        self.path = path
        self.isRunning = true
        self.lastError = nil
    }

    /// Listens while AI access is allowed, and not at all under No AI.
    func sync(settings: AppSettings, store: ServerStore, connection: ConnectionManager) {
        guard !settings.noAI else {
            stop()
            // A quit does not run `stop`, so an earlier session may have left
            // its socket file behind. Under No AI there must be none at all.
            unlink(ControlSocket.url.path)
            return
        }
        if isRunning { return }
        start(backend: AppControlBackend(store: store, connection: connection))
    }

    func stop() {
        source?.cancel()
        source = nil
        listenFD = -1
        router = nil
        if !path.isEmpty { unlink(path) }
        isRunning = false
    }

    private func fail(_ call: String) {
        let message = "\(call): \(String(cString: strerror(errno)))"
        lastError = message
        onLog?("[control] \(message)\n")
    }

    // MARK: - Connections

    private func acceptPending() {
        while listenFD >= 0 {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // The directory already keeps other users out; this keeps them out
            // even if someone loosens its permissions.
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFL, 0)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parsed = ControlServer.readRequest(client)
            Task { @MainActor in
                let response: ControlResponse
                switch parsed {
                case .request(let request):
                    response = self?.router?.handle(request)
                        ?? .error("AI access is switched off in Veil", status: 403)
                case .failure(let message):
                    response = .error(message, status: 400)
                case .incomplete:
                    response = .error("incomplete request", status: 400)
                }
                let data = ControlHTTP.response(response)
                DispatchQueue.global(qos: .userInitiated).async {
                    ControlServer.writeAll(data, to: client)
                    close(client)
                }
            }
        }
    }

    /// Reads until `ControlHTTP` has a whole request, or the peer stops.
    nonisolated static func readRequest(_ fd: Int32) -> ControlHTTP.ParseResult {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let parsed = ControlHTTP.parse(buffer)
            if case .incomplete = parsed {} else { return parsed }
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return .incomplete }
            buffer.append(chunk, count: count)
        }
    }

    nonisolated static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let written = write(fd, pointer, left)
                guard written > 0 else { return }
                pointer += written
                left -= written
            }
        }
    }
}
#endif
