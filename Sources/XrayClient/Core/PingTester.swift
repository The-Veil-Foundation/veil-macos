import Foundation
import Network
import Observation
import os

/// Latency tester for the server list.
///
/// The direct modes time a connection to the server itself; the proxy modes
/// time a request sent through the node (see `PingMode`). While the tunnel is
/// up, every direct probe is pinned to the physical interface: one that
/// followed the default route into utun was answered by the tunnel's own TCP
/// stack on this machine and read 1–2 ms for every server.
@MainActor
@Observable
final class PingTester {
    /// Latency in milliseconds per server id. nil value = unreachable/timeout.
    private(set) var results: [UUID: Int?] = [:]
    /// Server ids currently being tested.
    private(set) var testing: Set<UUID> = []

    /// How servers are measured. The list keeps this in step with the setting.
    var mode: PingMode = .proxyGet
    /// What the proxy modes request.
    var probeURL = URL(string: PingMode.defaultURL)!

    /// Test a batch of servers concurrently (bounded), updating results live.
    /// `tunActive` pins the probes to the physical interface so they measure
    /// the real path rather than the tunnel.
    func test(_ servers: [ProxyConfig], tunActive: Bool = false, timeout: TimeInterval = 3.0) {
        for s in servers { testing.insert(s.id) }
        let mode = self.mode
        let url = probeURL

        #if os(macOS)
        let physical = tunActive ? PhysicalInterface.current() : nil
        if mode.usesProxy {
            let request = ProxyProbe.Request(url: url, method: mode.httpMethod,
                                             timeout: max(timeout, 5),
                                             interface: physical?.name)
            Task.detached(priority: .userInitiated) {
                await ProxyProbe.measure(servers, request: request) { batch in
                    await self.applyResults(batch)
                }
            }
            return
        }
        let boundIndex = physical?.index
        #else
        let boundIndex: UInt32? = nil
        #endif

        let targets = servers.map {
            ($0.id, $0.allAddresses, $0.port, $0.pingStrategy, $0.sni, $0.alpn)
        }

        Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: (UUID, Int?).self) { group in
                let maxConcurrent = 16
                var iterator = targets.makeIterator()

                func addNext(_ group: inout TaskGroup<(UUID, Int?)>) {
                    guard let (id, hosts, port, strategy, sni, alpn) = iterator.next() else { return }
                    let name = hosts.first ?? ""
                    group.addTask {
                        // Off the tunnel the name has to resolve off it too:
                        // with fake-IP DNS the system answer is an address
                        // that exists only inside the core.
                        var host = name
                        #if os(macOS)
                        if let boundIndex {
                            guard let ip = DirectResolver.resolve(name, interface: boundIndex).first else {
                                return (id, nil)
                            }
                            host = ip
                        }
                        #endif
                        let ms: Int?
                        switch mode == .icmp ? .icmp : strategy {
                        case .tcp:
                            ms = await PingTester.tcpLatency(host: host, port: port,
                                                             timeout: timeout,
                                                             interface: boundIndex)
                        case .quic:
                            // Hysteria2/TUIC speak QUIC — time a real QUIC+TLS
                            // handshake to the UDP port.
                            ms = await PingTester.quicLatency(host: host, port: port,
                                                              sni: sni ?? name, alpn: alpn,
                                                              timeout: timeout,
                                                              avoidTunnel: boundIndex != nil)
                        case .icmp:
                            // WireGuard: no TCP port, not QUIC — ICMP echo.
                            ms = await PingTester.icmpLatency(host: host, timeout: timeout,
                                                              interface: boundIndex)
                        }
                        return (id, ms)
                    }
                }

                for _ in 0..<maxConcurrent { addNext(&group) }

                // Batch results to reduce @Observable churn and keep scrolling smooth.
                var pending: [UUID: Int?] = [:]
                var lastFlush = DispatchTime.now()
                let flushIntervalNs: UInt64 = 150_000_000

                while let (id, ms) = await group.next() {
                    pending[id] = ms
                    addNext(&group)
                    let now = DispatchTime.now()
                    if now.uptimeNanoseconds - lastFlush.uptimeNanoseconds >= flushIntervalNs {
                        let snapshot = pending
                        pending.removeAll()
                        lastFlush = now
                        await self.applyResults(snapshot)
                    }
                }
                if !pending.isEmpty { await self.applyResults(pending) }
            }
        }
    }

    private func applyResults(_ batch: [UUID: Int?]) {
        results.merge(batch) { _, latest in latest }
        testing.subtract(batch.keys)
    }

    func latency(for id: UUID) -> Int?? {
        results[id]
    }

    func isTesting(_ id: UUID) -> Bool { testing.contains(id) }

    /// True once at least one server has been measured. The list filters read
    /// this to tell "nothing responded" apart from "nothing was measured".
    var hasResults: Bool { !results.isEmpty }

    /// True while a batch is in flight.
    var isBusy: Bool { !testing.isEmpty }

    func clear() {
        results.removeAll()
        testing.removeAll()
    }

    // MARK: - Low-level TCP connect timing

    /// Returns latency in ms, or nil on failure/timeout. Runs off the main actor.
    /// `interface` pins the socket to that interface index; nil follows the
    /// routing table, which is what the local readiness checks want.
    nonisolated static func tcpLatency(host: String, port: Int, timeout: TimeInterval,
                                       interface: UInt32? = nil) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ms = blockingTCPLatency(host: host, port: port, timeout: timeout,
                                            interface: interface)
                continuation.resume(returning: ms)
            }
        }
    }

    private nonisolated static func blockingTCPLatency(host: String, port: Int, timeout: TimeInterval,
                                                       interface: UInt32?) -> Int? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let addr = info else {
            return nil
        }
        defer { freeaddrinfo(info) }

        let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        #if os(macOS)
        if let interface {
            PhysicalInterface.bind(fd, family: addr.pointee.ai_family, to: interface)
        }
        #endif

        // Non-blocking connect with select() for a precise timeout.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        let res = connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen)
        if res == 0 {
            return elapsedMs(from: start)
        }
        if errno != EINPROGRESS { return nil }

        // Wait for the socket to become writable (connect completes) using
        // poll(). poll() — unlike select()/fd_set — has no FD_SETSIZE (1024)
        // limit, so it is safe when many sockets are open concurrently (the
        // select() path used to trap with a buffer overrun once a socket fd
        // climbed past 1023, e.g. during concurrent ping tests).
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(max(0, (timeout * 1000).rounded()))
        let sel = poll(&pfd, 1, timeoutMs)
        guard sel > 0 else { return nil } // timeout or error

        // Confirm the connection actually succeeded.
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        guard soError == 0 else { return nil }

        return elapsedMs(from: start)
    }

    private nonisolated static func elapsedMs(from start: DispatchTime) -> Int {
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        // Round to nearest ms, but never report 0 for a successful connect.
        return max(1, Int((Double(ns) / 1_000_000.0).rounded()))
    }

    // MARK: - QUIC handshake timing (Hysteria2 / TUIC)

    /// Returns the time to complete a real QUIC + TLS handshake to the server's
    /// UDP port, in ms, or nil on failure/timeout. This is the honest probe for
    /// QUIC protocols: it exercises the same UDP datagram path and TLS handshake
    /// the proxy itself uses, rather than guessing from an ICMP echo. Runs off
    /// the main actor.
    nonisolated static func quicLatency(host: String, port: Int,
                                        sni: String?, alpn: [String]?,
                                        timeout: TimeInterval,
                                        avoidTunnel: Bool = false) async -> Int? {
        guard #available(macOS 15.0, *) else {
            // QUIC NWParameters init isn't available pre-15 — fall back to ICMP
            // so these servers still get a reachability number.
            return await icmpLatency(host: host, timeout: timeout)
        }

        let quicOptions = NWProtocolQUIC.Options(alpn: alpn?.isEmpty == false ? alpn! : ["h3"])
        // Set the SNI when the link carried one, so the server selects the right
        // certificate / virtual host during the handshake.
        if let sni, !sni.isEmpty {
            sec_protocol_options_set_tls_server_name(quicOptions.securityProtocolOptions, sni)
        }
        // This is a reachability probe, not real traffic — accept whatever
        // certificate the server presents so the handshake can complete and be
        // timed even for self-signed / insecure setups.
        sec_protocol_options_set_verify_block(
            quicOptions.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue.global(qos: .userInitiated)
        )

        let params = NWParameters(quic: quicOptions)
        // utun devices are type `.other`; keeping off them keeps the
        // handshake off the tunnel.
        if avoidTunnel { params.prohibitedInterfaceTypes = [.other] }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "quic-ping-\(UUID().uuidString)")

        let start = DispatchTime.now()
        // The resumer guarantees the continuation fires exactly once — on
        // .ready (success), .failed/.cancelled (failure), or the timeout below.
        let result: Int? = await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let resumer = QUICProbeResumer(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:    resumer.finish(elapsedMs(from: start))
                case .failed, .cancelled: resumer.finish(nil)
                default:        break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { resumer.finish(nil) }
            connection.start(queue: queue)
        }
        return result
    }

    /// Resumes a QUIC-probe continuation exactly once and tears down the
    /// connection, regardless of which event (ready / failure / timeout) arrives
    /// first. `@unchecked Sendable` is safe: all mutable state is guarded by the
    /// internal lock.
    private final class QUICProbeResumer: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: false)
        private let connection: NWConnection
        private let continuation: CheckedContinuation<Int?, Never>

        init(connection: NWConnection, continuation: CheckedContinuation<Int?, Never>) {
            self.connection = connection
            self.continuation = continuation
        }

        func finish(_ value: Int?) {
            let already = lock.withLock { done -> Bool in
                if done { return true }
                done = true
                return false
            }
            if already { return }
            connection.cancel()
            continuation.resume(returning: value)
        }
    }

    // MARK: - ICMP echo timing (for QUIC/UDP protocols)

    /// Returns round-trip latency in ms via an ICMP echo, or nil on
    /// failure/timeout. Used for Hysteria2/TUIC/WireGuard, which expose no TCP
    /// port. Runs off the main actor.
    nonisolated static func icmpLatency(host: String, timeout: TimeInterval,
                                        interface: UInt32? = nil) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let ms = blockingICMPLatency(host: host, timeout: timeout, interface: interface)
                continuation.resume(returning: ms)
            }
        }
    }

    /// Sends a single ICMP echo request and waits for the matching reply.
    ///
    /// macOS grants unprivileged processes datagram-mode ICMP sockets
    /// (`SOCK_DGRAM` + `IPPROTO_ICMP`) — no root or setuid needed. The kernel
    /// fills in the identifier and validates replies, so we only match on the
    /// echo sequence number.
    private nonisolated static func blockingICMPLatency(host: String, timeout: TimeInterval,
                                                        interface: UInt32?) -> Int? {
        // Resolve to an IPv4 address. (Datagram ICMP here targets IPv4/ICMPv4.)
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_ICMP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let addr = info else {
            return nil
        }
        defer { freeaddrinfo(info) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        #if os(macOS)
        if let interface { PhysicalInterface.bind(fd, family: AF_INET, to: interface) }
        #endif

        // ICMP echo request header: type(8) code(0) checksum id seq.
        // In datagram mode the kernel overwrites id and the checksum, but a
        // correct checksum is harmless, so we leave it zero and let the OS fill.
        let seq = UInt16.random(in: 0...UInt16.max)
        var packet = [UInt8](repeating: 0, count: 8)
        packet[0] = 8                       // type = echo request
        packet[1] = 0                       // code
        packet[2] = 0; packet[3] = 0        // checksum (kernel computes)
        packet[4] = 0; packet[5] = 0        // identifier (kernel sets)
        packet[6] = UInt8(seq >> 8)         // sequence hi
        packet[7] = UInt8(seq & 0xff)       // sequence lo

        let start = DispatchTime.now()
        let sent = packet.withUnsafeBytes { raw -> Int in
            sendto(fd, raw.baseAddress, raw.count, 0,
                   addr.pointee.ai_addr, addr.pointee.ai_addrlen)
        }
        guard sent == packet.count else { return nil }

        // Wait for a reply, honouring the timeout via poll().
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let timeoutMs = Int32(max(0, (timeout * 1000).rounded()))
        let ready = poll(&pfd, 1, timeoutMs)
        guard ready > 0 else { return nil } // timeout or error

        var buf = [UInt8](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard n >= 8 else { return nil }

        // Datagram-mode replies start at the ICMP header (no IP header). Confirm
        // it's an echo reply (type 0) for our sequence number.
        guard buf[0] == 0 else { return nil }
        let replySeq = (UInt16(buf[6]) << 8) | UInt16(buf[7])
        guard replySeq == seq else { return nil }

        return elapsedMs(from: start)
    }
}
