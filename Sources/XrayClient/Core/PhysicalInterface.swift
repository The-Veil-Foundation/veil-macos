// macOS-only: the iOS tunnel runs inside the NetworkExtension, where probes
// are not routed through the device's own utun.
#if os(macOS)
import Foundation
import SystemConfiguration

/// The network interface traffic leaves through when it is not in the tunnel.
///
/// With TUN up, the default route points at a utun device, and a probe that
/// follows it is answered by the tunnel's own TCP stack on this machine — a
/// "connect" that completes in a millisecond whatever the server's distance.
/// Binding the probe socket to the physical interface keeps it off the tunnel
/// without any route changes, and so without root.
enum PhysicalInterface {

    struct Info: Sendable {
        var name: String
        var index: UInt32
    }

    /// The primary interface macOS reports, unless that is a tunnel.
    ///
    /// The tunnel only installs routes; it does not become the primary
    /// service, so `State:/Network/Global/IPv4` keeps naming Wi-Fi or Ethernet.
    static func current() -> Info? {
        if let name = primaryFromDynamicStore(), let info = info(for: name) {
            return info
        }
        return firstPhysicalWithIPv4()
    }

    private static func primaryFromDynamicStore() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Veil" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
              let name = value["PrimaryInterface"] as? String,
              !isTunnel(name) else { return nil }
        return name
    }

    private static func info(for name: String) -> Info? {
        let index = if_nametoindex(name)
        return index == 0 ? nil : Info(name: name, index: index)
    }

    /// Fallback: the first `en*` interface that holds a routable IPv4 address.
    private static func firstPhysicalWithIPv4() -> Info? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return nil }
        defer { freeifaddrs(addresses) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"),
                  let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let isLinkLocal = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                (UInt32(bigEndian: $0.pointee.sin_addr.s_addr) >> 16) == 0xA9FE
            }
            if !isLinkLocal, let info = info(for: name) { return info }
        }
        return nil
    }

    /// The DNS servers macOS resolves through, as configured for the network.
    static func systemResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Veil" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString)
                as? [String: Any],
              let servers = value["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    /// Read the physical service's DNS, since Global/DNS can name Veil's utun.
    static func physicalResolvers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Veil" as CFString, nil, nil) else { return [] }
        var services = Set<String>()
        return ["IPv4", "IPv6"].flatMap { family -> [String] in
            guard let primary = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString)
                    as? [String: Any],
                  let interface = primary["PrimaryInterface"] as? String, !isTunnel(interface),
                  let id = primary["PrimaryService"] as? String, services.insert(id).inserted
            else { return [] }
            return ["Setup", "State"].flatMap { source -> [String] in
                let key = "\(source):/Network/Service/\(id)/DNS" as CFString
                let dns = SCDynamicStoreCopyValue(store, key) as? [String: Any]
                return dns?["ServerAddresses"] as? [String] ?? []
            }
        }
    }

    /// The default gateways macOS routes through, IPv4 and IPv6, as the
    /// primary service reports them. Read before the tunnel installs its own
    /// routes, which do not change these keys.
    static func systemGateways() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Veil" as CFString, nil, nil) else { return [] }
        return ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].compactMap { key in
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let router = value["Router"] as? String, !router.isEmpty else { return nil }
            return router
        }
    }

    static func isTunnel(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
    }

    /// Pins `fd` to the interface, for the address family it was opened with.
    @discardableResult
    static func bind(_ fd: Int32, family: Int32, to index: UInt32) -> Bool {
        var value = index
        let size = socklen_t(MemoryLayout<UInt32>.size)
        if family == AF_INET6 {
            return setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &value, size) == 0
        }
        return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &value, size) == 0
    }
}
#endif
