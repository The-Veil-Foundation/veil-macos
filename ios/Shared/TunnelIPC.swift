import Foundation

/// Wire format for `NETunnelProviderSession.sendProviderMessage`.
///
/// The app never talks to Xray directly — the core only ever runs inside the
/// extension. Everything the UI shows (state, traffic counters, core log) comes
/// back through these messages.
enum TunnelCommand: String, Codable {
    /// Current core state + counters (+ the log tail when asked for).
    case status
    /// Re-read the config file and restart the core without dropping the
    /// tunnel. This is how switching servers stays sub-second: the utun stays
    /// up, iOS never shows a reconnect, only Xray restarts.
    case reload
    /// Truncate the core log.
    case clearLog
    /// Run `config` past the core's own parser without starting it. Only the
    /// extension links Xray, so this is the one place a node can be checked
    /// by the core that will run it.
    case check
}

struct TunnelRequest: Codable {
    var command: TunnelCommand
    /// Ship the log tail back. Off for the once-a-second status poll: the
    /// log is only worth its XPC payload while the log screen is open.
    var includeLog: Bool = false
    /// The configuration to check, for `.check`.
    var config: String?

    init(_ command: TunnelCommand, includeLog: Bool = false, config: String? = nil) {
        self.command = command
        self.includeLog = includeLog
        self.config = config
    }

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> TunnelRequest? {
        try? JSONDecoder().decode(TunnelRequest.self, from: data)
    }
}

/// What the observatory last measured for one outbound.
struct ObservedOutbound: Codable, Equatable {
    var tag: String
    var alive: Bool
    var delay: Int64
}

struct TunnelStatus: Codable {
    var running: Bool = false
    var coreVersion: String = ""
    var serverName: String = ""
    var uplinkBytes: Int64 = 0
    var downlinkBytes: Int64 = 0
    var startedAt: Date?
    var lastError: String?
    /// Tail of the core log, capped so provider messages stay small. Empty
    /// unless the request asked for it.
    var log: String = ""
    /// Probe results for the members of every "fastest" group.
    var observation: [ObservedOutbound] = []
    /// For `.check`: nil when the core accepted the config, its complaint
    /// otherwise.
    var checkError: String?

    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    static func decode(_ data: Data) -> TunnelStatus? {
        try? JSONDecoder().decode(TunnelStatus.self, from: data)
    }
}

/// Everything the provider needs that isn't in the Xray config itself. Written
/// next to the config by the app, read by the extension on start and on reload.
struct TunnelSession: Codable {
    var serverName: String = ""
    /// Only used to populate `tunnelRemoteAddress`; routing is Xray's job.
    var serverAddress: String = "127.0.0.1"
    var mtu: Int = 1500
    /// Advertise IPv6 inside the tunnel. On by default: if we only claim IPv4,
    /// IPv6-capable apps route around the tunnel and leak.
    var ipv6Enabled: Bool = true
    var dnsServers: [String] = ["1.1.1.1", "8.8.8.8"]
    /// Hard cap on the Go heap. NetworkExtension processes get a small memory
    /// budget and are killed outright when they exceed it.
    var maxMemoryMB: Int = 48
    /// Server addresses kept off the tunnel. A probe the app sends to a node
    /// would otherwise be answered by the tunnel's own TCP stack the moment it
    /// left, and every ping would read as a millisecond.
    var excludedAddresses: [String] = []
    /// Private ranges (CIDR, v4 and v6) kept off the tunnel when the routing
    /// preset bypasses the LAN. Excluded at the OS, they never reach the
    /// extension, so the printer and the NAS cost it no memory or CPU.
    var excludedRanges: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        serverName = get(.serverName, "")
        serverAddress = get(.serverAddress, "127.0.0.1")
        mtu = get(.mtu, 1500)
        ipv6Enabled = get(.ipv6Enabled, true)
        dnsServers = get(.dnsServers, ["1.1.1.1", "8.8.8.8"])
        maxMemoryMB = get(.maxMemoryMB, 48)
        excludedAddresses = get(.excludedAddresses, [])
        excludedRanges = get(.excludedRanges, [])
    }

    /// Whether two sessions need different network settings. The server's
    /// name and address are cosmetic there, so a plain switch never re-applies.
    func sameNetwork(as other: TunnelSession) -> Bool {
        mtu == other.mtu && ipv6Enabled == other.ipv6Enabled
            && dnsServers == other.dnsServers
            && excludedAddresses == other.excludedAddresses
            && excludedRanges == other.excludedRanges
    }

    func write() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: AppGroup.sessionURL, options: .atomic)
    }

    static func load() -> TunnelSession {
        guard let data = try? Data(contentsOf: AppGroup.sessionURL),
              let session = try? JSONDecoder().decode(TunnelSession.self, from: data) else {
            return TunnelSession()
        }
        return session
    }
}
