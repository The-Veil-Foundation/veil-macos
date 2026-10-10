// macOS-only.
#if os(macOS)
import Foundation

/// Runs a child Xray process for each node sing-box cannot speak.
///
/// sing-box is the routing core because it is the only one that can match a
/// process, but a few transports are Xray's alone — XHTTP, mKCP, VLESS
/// post-quantum encryption. Rather than exclude those servers from routing
/// entirely, each one gets a local Xray listening on a SOCKS port, and the
/// profile reaches it as an ordinary outbound. The node keeps its tag, so
/// rules can point at it like any other.
///
/// The bridges run as the user even when the routing core runs as root: they
/// only ever talk to the loopback, and the profile's loop guard keeps their
/// own traffic out of the tunnel.
@MainActor
final class BridgeManager {

    /// A running bridge.
    struct Bridge {
        var serverID: UUID
        var name: String
        var port: Int
    }

    private var processes: [UUID: XrayProcess] = [:]
    private var assigned: [UUID: Int] = [:]

    /// Called with each line a bridge logs, prefixed with the node's name.
    var onLog: ((String) -> Void)?

    var activeBridges: [Bridge] {
        assigned.compactMap { id, port in
            guard processes[id] != nil else { return nil }
            return Bridge(serverID: id, name: names[id] ?? "", port: port)
        }
    }

    private var names: [UUID: String] = [:]

    /// Brings the set of bridges in line with `servers`, starting what is
    /// missing and stopping what is no longer wanted.
    ///
    /// Returns the port each bridged server is reachable on, which is exactly
    /// what `SingBoxProfile.bridgePorts` wants. Servers that failed to start
    /// are absent from the result, and the profile builder then renders them
    /// as a plain outbound — which sing-box will reject rather than silently
    /// route somewhere unexpected.
    @discardableResult
    func sync(servers: [ProxyConfig], basePort: Int, logLevel: String) -> [UUID: Int] {
        let wanted = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })

        for id in processes.keys where wanted[id] == nil {
            stop(id)
        }

        guard !wanted.isEmpty else { return [:] }
        guard let binary = CoreBinary.locate(.xray) else {
            onLog?("[error] xray binary not found — nodes needing it cannot be routed\n")
            return [:]
        }

        var taken = Set(assigned.values)
        for (id, server) in wanted where processes[id] == nil {
            // One port: the profile reaches a bridge over SOCKS only.
            let ports = PortAllocator.free(count: 1, from: basePort, avoiding: taken)
            guard let port = ports.first else {
                onLog?("[error] no free port for \(server.name)\n")
                continue
            }
            taken.insert(port)
            if start(server, binary: binary, socks: port, logLevel: logLevel) {
                assigned[id] = port
                names[id] = server.name
            }
        }
        return assigned.filter { processes[$0.key] != nil }
    }

    func stopAll() {
        for id in Array(processes.keys) { stop(id) }
        assigned.removeAll()
        names.removeAll()
    }

    // MARK: - Internals

    private func start(_ server: ProxyConfig, binary: URL,
                       socks: Int, logLevel: String) -> Bool {
        var ports = InboundPorts()
        ports.socks = socks
        ports.serveHTTP = false

        let process = XrayProcess()
        let name = server.name
        process.onLog = { [weak self] line in
            Task { @MainActor in self?.onLog?("[\(name)] \(line)") }
        }
        process.onExit = { [weak self] code in
            Task { @MainActor in
                self?.onLog?("[warn] bridge for \(name) exited (code \(code))\n")
            }
        }
        do {
            // The bridge carries no routing of its own: the profile decides
            // what reaches it, and everything that does belongs to this node.
            let data = try XrayConfigBuilder.jsonData(for: server, ports: ports,
                                                      rules: [], logLevel: logLevel)
            try process.start(configData: data, binary: binary)
        } catch {
            onLog?("[error] bridge for \(name) failed: \(error.localizedDescription)\n")
            return false
        }
        processes[server.id] = process
        return true
    }

    private func stop(_ id: UUID) {
        // No waiting: a replacement bridge is given a port nothing holds, so
        // nothing needs this one gone first — and waiting up to half a second
        // per bridge, on the main thread, is what made disconnecting stall.
        processes[id]?.stop(wait: false)
        processes.removeValue(forKey: id)
        assigned.removeValue(forKey: id)
        names.removeValue(forKey: id)
    }
}

private extension CoreBinary {
    static func locate(_ engine: CoreEngine) -> URL? { locate(for: engine) }
}
#endif
