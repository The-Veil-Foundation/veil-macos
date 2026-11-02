// macOS-only: pairs with `PhysicalInterface`.
#if os(macOS)
import Foundation

/// Resolves a server's hostname off the tunnel.
///
/// With fake-IP DNS on, the system resolver answers every name with an
/// address out of 198.18.0.0/15 that only means something inside the core. A
/// latency probe needs the server's real address, so when that is what comes
/// back it asks a public resolver directly, over a socket pinned to the
/// physical interface.
enum DirectResolver {

    static let resolvers = ["1.1.1.1", "8.8.8.8"]

    /// Real IPv4 addresses for `host`. IP literals come back unchanged.
    static func resolve(_ host: String, interface: UInt32?) -> [String] {
        if isIPLiteral(host) { return [host] }
        let system = TunManager.resolveIPs(host: host)
        let real = system.filter { !isFakeIP($0) }
        if !real.isEmpty { return real }
        guard let interface else { return [] }
        for resolver in resolvers {
            let answers = query(host, resolver: resolver, interface: interface)
            if !answers.isEmpty { return answers }
        }
        return []
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// Inside the fake-IP range sing-box hands out (198.18.0.0/15).
    static func isFakeIP(_ ip: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return false }
        return (UInt32(bigEndian: addr.s_addr) & 0xFFFE_0000) == 0xC612_0000
    }

    /// One A query over UDP. Returns the addresses in the answer section.
    static func query(_ host: String, resolver: String, interface: UInt32,
                      timeout: TimeInterval = 2) -> [String] {
        let id = UInt16.random(in: 0...UInt16.max)
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00,
                               0, 1, 0, 0, 0, 0, 0, 0]
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count < 64 else { return [] }
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(contentsOf: [0, 0, 1, 0, 1])   // root, QTYPE A, QCLASS IN

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        PhysicalInterface.bind(fd, family: AF_INET, to: interface)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, resolver, &addr.sin_addr) == 1 else { return [] }
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return [] }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: 1500)
        let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard n > 12 else { return [] }
        return parseAnswers(Array(buf[0..<n]), id: id)
    }

    /// The A records in a DNS response with the given transaction id.
    static func parseAnswers(_ msg: [UInt8], id: UInt16) -> [String] {
        guard msg.count > 12, (UInt16(msg[0]) << 8 | UInt16(msg[1])) == id else { return [] }
        let qd = Int(msg[4]) << 8 | Int(msg[5])
        let an = Int(msg[6]) << 8 | Int(msg[7])
        var offset = 12

        func skipName() -> Bool {
            while offset < msg.count {
                let len = Int(msg[offset])
                if len == 0 { offset += 1; return true }
                if len & 0xC0 == 0xC0 { offset += 2; return true }
                offset += len + 1
            }
            return false
        }

        for _ in 0..<qd {
            guard skipName() else { return [] }
            offset += 4
        }
        var result: [String] = []
        for _ in 0..<an {
            guard skipName(), offset + 10 <= msg.count else { break }
            let type = Int(msg[offset]) << 8 | Int(msg[offset + 1])
            let length = Int(msg[offset + 8]) << 8 | Int(msg[offset + 9])
            offset += 10
            guard offset + length <= msg.count else { break }
            if type == 1, length == 4 {
                result.append(msg[offset..<offset + 4].map(String.init).joined(separator: "."))
            }
            offset += length
        }
        return result
    }
}
#endif
