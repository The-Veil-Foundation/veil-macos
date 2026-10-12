import Foundation

/// Where a matched rule sends its traffic.
///
/// The first three cases are the classic ones every client has. `.server` and
/// `.group` are what make per-process routing useful: a rule can name a
/// specific node or a specific selector instead of "the proxy", so two
/// applications can leave the machine through two different servers at once.
///
/// Only sing-box can honour `.server` / `.group` — the Xray path still runs one
/// outbound at a time and folds them back onto `proxy`.
enum RuleTarget: Codable, Equatable, Hashable {
    case proxy            // the default selector (whatever the user picked)
    case direct
    case block
    case server(UUID)     // one specific node
    case group(UUID)      // one specific selector / urltest group

    /// The sing-box outbound tag this target renders to.
    var tag: String {
        switch self {
        case .proxy:            return ProfileTags.defaultSelector
        case .direct:           return ProfileTags.direct
        case .block:            return ProfileTags.block
        case .server(let id):   return ProfileTags.server(id)
        case .group(let id):    return ProfileTags.group(id)
        }
    }

    /// Whether this target names something only the full profile can build.
    var needsProfile: Bool {
        switch self {
        case .server, .group: return true
        case .proxy, .direct, .block: return false
        }
    }

    /// Xray has a single proxy outbound, so node- and group-specific targets
    /// collapse onto it there.
    var xrayTag: String {
        switch self {
        case .direct: return "direct"
        case .block:  return "block"
        default:      return "proxy"
        }
    }

    // MARK: Codable

    /// Encoded as a flat string so an old `store.json` — which stored
    /// `"proxy"` / `"direct"` / `"block"` under the key `outbound` — decodes
    /// without a migration step.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RuleTarget(rawValue: raw) ?? .proxy
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .proxy:          return "proxy"
        case .direct:         return "direct"
        case .block:          return "block"
        case .server(let id): return "server:\(id.uuidString)"
        case .group(let id):  return "group:\(id.uuidString)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "proxy":  self = .proxy
        case "direct": self = .direct
        case "block":  self = .block
        default:
            let parts = rawValue.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else {
                return nil
            }
            switch parts[0] {
            case "server": self = .server(id)
            case "group":  self = .group(id)
            default:       return nil
            }
        }
    }

    /// Title for targets that do not need to look a name up.
    var builtInTitle: String? {
        switch self {
        case .proxy:  return "Proxy"
        case .direct: return "Direct"
        case .block:  return "Block"
        default:      return nil
        }
    }
}

/// Which side of a connection a rule's address matchers apply to.
enum RuleDirection: String, Codable, CaseIterable, Identifiable {
    case destination
    case source

    var id: String { rawValue }
    var title: String {
        switch self {
        case .destination: return "Destination"
        case .source:      return "Source"
        }
    }
}

/// One ordered routing rule.
///
/// A rule matches when *every* populated matcher group matches, and a group
/// matches when *any* of its entries does — the same AND-of-ORs shape sing-box
/// itself uses. `invert` flips the whole result.
///
/// `domains` and `ips` keep Xray's prefix syntax (`domain:`, `keyword:`,
/// `regexp:`, `geosite:`, `geoip:`) because that is what share links, panels
/// and every other client speak. `MatcherSyntax` splits them back apart for
/// sing-box, and `geosite:` / `geoip:` entries become rule-sets rather than
/// being dropped.
struct RoutingRule: Codable, Equatable, Identifiable {

    /// Whether any of these rules names a specific node or group, which only
    /// the full sing-box profile can build. A rule that cannot be honoured
    /// must not look configured, so the editor asks this and says so.
    static func needsProfile(_ rules: [RoutingRule]) -> Bool {
        rules.contains { $0.enabled && $0.target.needsProfile }
    }

    var id = UUID()
    var name: String = ""
    var target: RuleTarget = .proxy
    var enabled: Bool = true

    // Address matchers
    var domains: [String] = []
    var ips: [String] = []
    var port: String = ""          // "443", "1000-2000", or a comma list
    var direction: RuleDirection = .destination

    // Process matchers — these only work when sing-box owns the TUN inbound.
    var processNames: [String] = []
    var processPaths: [String] = []

    // Extra sing-box matchers
    var network: String = ""       // "" | "tcp" | "udp"
    var protocols: [String] = []   // sniffed: http, tls, quic, dns, bittorrent…
    var ruleSets: [String] = []    // explicit rule-set tags
    var clashMode: String = ""     // "" | "Rule" | "Global" | "Direct"
    var invert: Bool = false

    init(id: UUID = UUID(),
         name: String = "",
         target: RuleTarget = .proxy,
         domains: [String] = [],
         ips: [String] = [],
         port: String = "",
         processNames: [String] = [],
         processPaths: [String] = [],
         enabled: Bool = true) {
        self.id = id
        self.name = name
        self.target = target
        self.domains = domains
        self.ips = ips
        self.port = port
        self.processNames = processNames
        self.processPaths = processPaths
        self.enabled = enabled
    }

    /// True when the rule would match nothing at all — the builders skip these
    /// rather than emitting a rule that swallows every connection.
    var hasMatcher: Bool {
        !domains.isEmpty || !ips.isEmpty || !processNames.isEmpty
            || !processPaths.isEmpty || !ruleSets.isEmpty || !protocols.isEmpty
            || !network.isEmpty || !clashMode.isEmpty
            || !port.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when the rule can only be enforced by sing-box.
    var needsProcessMatching: Bool {
        !processNames.isEmpty || !processPaths.isEmpty
    }

    /// True when the rule names the destinations it is about — addresses or
    /// domains typed out rather than an application whose traffic happens to
    /// go wherever it goes.
    ///
    /// This is the difference that decides whether the preset's LAN bypass
    /// gets to outrank the rule. "Everything Slack sends" must not swallow
    /// Slack's LAN traffic, so the bypass wins there. "192.168.8.0/24 through
    /// this peer" *is* a statement about the LAN, and a bypass that outranked
    /// it would make the rule do nothing at all.
    var namesItsOwnDestinations: Bool {
        direction == .destination && (!domains.isEmpty || !ips.isEmpty)
    }

    /// The plain address blocks this rule matches on, written out — a
    /// `geoip:` or `ext:` entry names a database rather than a range, so it is
    /// left out.
    var destinationCIDRs: [String] {
        guard direction == .destination else { return [] }
        return ips.filter { !$0.hasPrefix("geoip:") && !$0.hasPrefix("ext:") }
    }

    /// Renders to an Xray routing "field" rule, or nil when Xray cannot express
    /// it. Process matchers have no Xray equivalent, so such rules are dropped
    /// there instead of being silently widened.
    ///
    /// When `useBalancerForProxy` is true a proxy-bound rule is emitted as
    /// `balancerTag` so traffic flows through the Xray balancer.
    func xrayRule(useBalancerForProxy: Bool = false) -> [String: Any]? {
        guard enabled, !needsProcessMatching else { return nil }
        var dict: [String: Any] = ["type": "field"]
        let tag = target.xrayTag
        if tag == "proxy" && useBalancerForProxy {
            dict["balancerTag"] = tag
        } else {
            dict["outboundTag"] = tag
        }
        var matched = false
        if !domains.isEmpty { dict["domain"] = domains; matched = true }
        if !ips.isEmpty {
            dict[direction == .source ? "source" : "ip"] = ips
            matched = true
        }
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        if !trimmedPort.isEmpty { dict["port"] = trimmedPort; matched = true }
        if !network.isEmpty { dict["network"] = network; matched = true }
        return matched ? dict : nil
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, target, enabled, domains, ips, port, direction
        case processNames, processPaths, network, protocols, ruleSets
        case clashMode, invert
        case outbound   // legacy: the pre-v2 three-way enum
    }

    /// Resilient decoding, matching `AppSettings`: every key falls back to its
    /// default so a `store.json` written by an older build still loads. The
    /// legacy `outbound` key is read when `target` is absent.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        id = get(.id, UUID())
        name = get(.name, "")
        if let decoded = try? c.decode(RuleTarget.self, forKey: .target) {
            target = decoded
        } else if let legacy = try? c.decode(String.self, forKey: .outbound) {
            target = RuleTarget(rawValue: legacy) ?? .proxy
        } else {
            target = .proxy
        }
        enabled = get(.enabled, true)
        domains = get(.domains, [])
        ips = get(.ips, [])
        port = get(.port, "")
        direction = get(.direction, .destination)
        processNames = get(.processNames, [])
        processPaths = get(.processPaths, [])
        network = get(.network, "")
        protocols = get(.protocols, [])
        ruleSets = get(.ruleSets, [])
        clashMode = get(.clashMode, "")
        invert = get(.invert, false)
    }

    /// Written without the legacy `outbound` key: a store this build wrote is
    /// only ever read back by this build or a newer one.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(target, forKey: .target)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(domains, forKey: .domains)
        try c.encode(ips, forKey: .ips)
        try c.encode(port, forKey: .port)
        try c.encode(direction, forKey: .direction)
        try c.encode(processNames, forKey: .processNames)
        try c.encode(processPaths, forKey: .processPaths)
        try c.encode(network, forKey: .network)
        try c.encode(protocols, forKey: .protocols)
        try c.encode(ruleSets, forKey: .ruleSets)
        try c.encode(clashMode, forKey: .clashMode)
        try c.encode(invert, forKey: .invert)
    }
}

/// Built-in routing presets, mirroring v2rayN/Nekoray. Each produces an ordered
/// rule list. Presets that reference `geosite:`/`geoip:` pull the matching
/// rule-set (sing-box) or the geo .dat files (Xray).
enum RoutingPreset: String, Codable, CaseIterable, Identifiable {
    case global         // everything via proxy
    case bypassLAN      // proxy all, LAN/private direct
    case bypassChina    // China sites + LAN direct, rest proxy
    case bypassRussia   // Russian/gov sites direct, rest proxy (anti-censorship)
    case custom         // user-defined rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .global:      return "Global"
        case .bypassLAN:   return "Bypass LAN"
        case .bypassChina: return "Bypass China"
        case .bypassRussia: return "Bypass Russia"
        case .custom:      return "Custom"
        }
    }

    var subtitle: String {
        switch self {
        case .global:      return "All traffic through the proxy."
        case .bypassLAN:   return "Proxy everything except local/LAN addresses."
        case .bypassChina: return "Mainland China sites & LAN go direct, rest via proxy."
        case .bypassRussia: return "Russian & .ru-gov sites go direct, rest via proxy."
        case .custom:      return "Your own ordered rule list."
        }
    }

    /// Does this preset reference geosite/geoip categories (needs .dat files on
    /// the Xray core, rule-sets on sing-box)?
    var needsGeoAssets: Bool {
        switch self {
        case .bypassChina, .bypassRussia: return true
        case .global, .bypassLAN, .custom: return false
        }
    }

    /// Whether the preset sends private ranges straight out. On iOS those
    /// ranges are then kept off the tunnel altogether, not just routed direct
    /// by the core once they are inside it.
    var bypassesLAN: Bool {
        switch self {
        case .bypassLAN, .bypassChina, .bypassRussia: return true
        case .global, .custom: return false
        }
    }

    static let privateCIDRs = [
        "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
        "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"
    ]

    /// Builds the ordered rule list for built-in presets. `custom` returns the
    /// user's stored rules instead (handled by the caller).
    func builtInRules(blockAds: Bool) -> [RoutingRule] {
        guardRules(blockAds: blockAds) + presetRules()
    }

    /// Rules that must stay ahead of anything the user writes.
    ///
    /// A user rule usually names an application, and an application talks to
    /// the LAN as well as to the internet. Letting such a rule outrank the
    /// private-range bypass would push the printer and the NAS through the
    /// tunnel, which is never what was meant.
    func guardRules(blockAds: Bool) -> [RoutingRule] {
        var rules: [RoutingRule] = []
        if blockAds {
            rules.append(RoutingRule(name: "Block ads",
                                     target: .block,
                                     domains: ["geosite:category-ads-all"]))
        }
        switch self {
        case .global, .custom:
            break
        case .bypassLAN:
            rules.append(RoutingRule(name: "LAN direct", target: .direct,
                                     ips: Self.privateCIDRs))
        case .bypassChina, .bypassRussia:
            rules.append(RoutingRule(name: "LAN direct", target: .direct,
                                     ips: Self.privateCIDRs + ["geoip:private"]))
        }
        return rules
    }

    /// The preset's own opinion about where traffic goes, applied after the
    /// user's rules have had their say.
    func presetRules() -> [RoutingRule] {
        switch self {
        case .global, .bypassLAN, .custom:
            return []
        case .bypassChina:
            return [
                RoutingRule(name: "China sites direct", target: .direct,
                            domains: ["geosite:cn"]),
                RoutingRule(name: "China IPs direct", target: .direct,
                            ips: ["geoip:cn"])
            ]
        case .bypassRussia:
            return [
                RoutingRule(name: "RU gov & category direct", target: .direct,
                            domains: ["geosite:category-gov-ru", "geosite:category-ru"]),
                RoutingRule(name: "RU IPs direct", target: .direct,
                            ips: ["geoip:ru"])
            ]
        }
    }
}

/// Source of the geoip.dat / geosite.dat rule databases (GitHub releases).
///
/// These feed the Xray core. sing-box stopped reading `.dat` files in 1.12 and
/// uses rule-sets instead — see `RuleSetRef`.
enum GeoAssetSource: String, Codable, CaseIterable, Identifiable {
    case loyalsoldier   // global + China, ad-blocking
    case runetfreedom   // Russia / anti-censorship
    case v2fly          // official upstream
    case custom         // user-supplied URLs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loyalsoldier: return "Loyalsoldier (global + CN)"
        case .runetfreedom: return "runetfreedom (RU)"
        case .v2fly:        return "v2fly (official)"
        case .custom:       return "Custom URLs"
        }
    }

    /// Download URL for geoip.dat. Uses GitHub release "latest" redirects.
    func geoipURL(custom: String) -> String {
        switch self {
        case .loyalsoldier:
            return "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        case .runetfreedom:
            return "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
        case .v2fly:
            return "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
        case .custom:
            return custom
        }
    }

    /// Download URL for geosite.dat.
    func geositeURL(custom: String) -> String {
        switch self {
        case .loyalsoldier:
            return "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
        case .runetfreedom:
            return "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"
        case .v2fly:
            return "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
        case .custom:
            return ""   // custom geosite entered separately
        }
    }
}
