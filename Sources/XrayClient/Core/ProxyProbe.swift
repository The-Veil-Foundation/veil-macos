// macOS-only: spawns the bundled cores as subprocesses.
#if os(macOS)
import Foundation
import os

/// Measures the real delay of nodes: a request sent *through* each one.
///
/// A TCP connect says the server's port is open. It does not say the node
/// works — a wrong key, a blocked SNI or a dead upstream all connect fine and
/// carry nothing. So, like other clients' "real delay", this starts a
/// throwaway core with one local HTTP inbound per node, routes each inbound to
/// its node, and times a request to the test URL through it.
enum ProxyProbe {

    private static let log = Logger(subsystem: "com.veil.client", category: "ping")

    /// Nodes per throwaway core. Keeps a 500-node subscription from becoming
    /// one 500-inbound process that takes seconds to start.
    static let chunkSize = 48

    struct Request: Sendable {
        var url: URL
        var method: String
        var timeout: TimeInterval
        /// Interface the core's own traffic is pinned to — the physical one
        /// while the tunnel is up, so the probe does not loop through it.
        var interface: String?
    }

    /// Measures every server and reports each result as it arrives.
    static func measure(_ servers: [ProxyConfig],
                        request: Request,
                        concurrency: Int = 16,
                        report: @escaping @Sendable ([UUID: Int?]) async -> Void) async {
        let byEngine = Dictionary(grouping: servers) { $0.engine }
        for (engine, nodes) in byEngine {
            guard let binary = CoreBinary.locate(for: engine) else {
                await report(Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, nil) }))
                continue
            }
            var start = 0
            while start < nodes.count {
                let chunk = Array(nodes[start..<min(start + chunkSize, nodes.count)])
                start += chunkSize
                await measureChunk(chunk, engine: engine, binary: binary,
                                   request: request, concurrency: concurrency,
                                   report: report)
            }
        }
    }

    private static func measureChunk(_ nodes: [ProxyConfig], engine: CoreEngine,
                                     binary: URL, request: Request, concurrency: Int,
                                     report: @escaping @Sendable ([UUID: Int?]) async -> Void) async {
        let ports = freePorts(nodes.count)
        guard ports.count == nodes.count else {
            await report(Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, nil) }))
            return
        }
        let config: [String: Any] = engine == .xray
            ? xrayConfig(nodes, ports: ports, interface: request.interface)
            : singBoxConfig(nodes, ports: ports, interface: request.interface)

        guard let core = try? TestCore(config: config, binary: binary) else {
            await report(Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, nil) }))
            return
        }
        defer { core.stop() }

        // The core is ready once its last inbound accepts connections.
        guard await waitForListener(port: ports[ports.count - 1], timeout: 5) else {
            log.error("ping core did not come up (\(engine == .xray ? "xray" : "sing-box", privacy: .public))")
            await report(Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, nil) }))
            return
        }

        let pairs = Array(zip(nodes.map(\.id), ports))
        await withTaskGroup(of: (UUID, Int?).self) { group in
            var iterator = pairs.makeIterator()
            func addNext(_ group: inout TaskGroup<(UUID, Int?)>) {
                guard let (id, port) = iterator.next() else { return }
                group.addTask { (id, await timeRequest(through: port, request)) }
            }
            for _ in 0..<concurrency { addNext(&group) }
            while let (id, ms) = await group.next() {
                await report([id: ms])
                addNext(&group)
            }
        }
    }

    // MARK: - The request

    /// Times one request through the local HTTP inbound at `port`, in ms.
    ///
    /// Each request gets its own ephemeral session, so no connection to the
    /// test host is reused from an earlier node and no answer is cached.
    static func timeRequest(through port: Int, _ request: Request) async -> Int? {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = request.timeout
        config.timeoutIntervalForResource = request.timeout
        config.httpMaximumConnectionsPerHost = 1
        config.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout

        let start = DispatchTime.now()
        do {
            let (_, response) = try await session.data(for: urlRequest)
            // Any HTTP answer means the node carried the request; a proxy
            // that could not reach the target answers 5xx itself.
            if let http = response as? HTTPURLResponse, http.statusCode >= 500 { return nil }
            let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            return max(1, Int((Double(ns) / 1_000_000).rounded()))
        } catch {
            return nil
        }
    }

    // MARK: - Configs

    static func inboundTag(_ index: Int) -> String { "ping-in-\(index)" }
    static func outboundTag(_ index: Int) -> String { "ping-out-\(index)" }

    /// The node itself, or the first member of a balancer entry.
    private static func probed(_ node: ProxyConfig) -> ProxyConfig {
        var first = node
        first.alternates = nil
        return first
    }

    static func xrayConfig(_ nodes: [ProxyConfig], ports: [Int],
                           interface: String?) -> [String: Any] {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var rules: [[String: Any]] = []
        for (index, node) in nodes.enumerated() {
            inbounds.append([
                "tag": inboundTag(index), "listen": "127.0.0.1", "port": ports[index],
                "protocol": "http", "settings": [:] as [String: Any]
            ])
            var out = XrayConfigBuilder.outbound(probed(node), tag: outboundTag(index))
            if let interface {
                var stream = out["streamSettings"] as? [String: Any] ?? [:]
                var sockopt = stream["sockopt"] as? [String: Any] ?? [:]
                sockopt["interface"] = interface
                stream["sockopt"] = sockopt
                out["streamSettings"] = stream
            }
            outbounds.append(out)
            rules.append(["type": "field", "inboundTag": [inboundTag(index)],
                          "outboundTag": outboundTag(index)])
        }
        return [
            "log": ["loglevel": "none"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "AsIs", "rules": rules]
        ]
    }

    static func singBoxConfig(_ nodes: [ProxyConfig], ports: [Int],
                              interface: String?) -> [String: Any] {
        var inbounds: [[String: Any]] = []
        var outbounds: [[String: Any]] = []
        var endpoints: [[String: Any]] = []
        var rules: [[String: Any]] = []
        for (index, node) in nodes.enumerated() {
            let node = probed(node)
            inbounds.append([
                "type": "http", "tag": inboundTag(index),
                "listen": "127.0.0.1", "listen_port": ports[index]
            ])
            if SingBoxOutbound.isEndpoint(node) {
                endpoints.append(SingBoxOutbound.endpoint(node, tag: outboundTag(index)))
            } else {
                outbounds.append(SingBoxOutbound.outbound(node, tag: outboundTag(index)))
            }
            rules.append(["inbound": [inboundTag(index)], "outbound": outboundTag(index)])
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        var route: [String: Any] = [
            "rules": rules,
            "final": "direct",
            "default_domain_resolver": "local"
        ]
        if let interface { route["default_interface"] = interface }
        var config: [String: Any] = [
            "log": ["level": "panic"],
            "dns": ["servers": [["type": "local", "tag": "local"]]],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": route
        ]
        if !endpoints.isEmpty { config["endpoints"] = endpoints }
        return config
    }

    // MARK: - Plumbing

    /// Asks the kernel for `count` distinct free loopback ports. Every socket
    /// is held until all are picked, so the same port cannot come back twice.
    static func freePorts(_ count: Int) -> [Int] {
        var fds: [Int32] = []
        var ports: [Int] = []
        defer { fds.forEach { close($0) } }
        for _ in 0..<count {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            fds.append(fd)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { break }
            var out = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &out) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(fd, $0, &len)
                }
            }
            ports.append(Int(UInt16(bigEndian: out.sin_port)))
        }
        return ports
    }

    private static func waitForListener(port: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await PingTester.tcpLatency(host: "127.0.0.1", port: port, timeout: 0.25) != nil {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}

/// One throwaway core process and its config file, which holds node
/// credentials and so is owner-only and removed with the process.
private final class TestCore: @unchecked Sendable {
    private let process = Process()
    private let configURL: URL

    init(config: [String: Any], binary: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: config)
        configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("veil-ping-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: configURL.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        process.executableURL = binary
        process.arguments = ["run", "-c", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: configURL)
            throw error
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: configURL)
    }
}
#endif
