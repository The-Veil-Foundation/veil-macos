import Foundation

/// Everything the Xray profile is built from. The iOS app fills it from the
/// store; the tests fill it by hand.
struct XrayProfile {
    /// Every server the user has, balancers included. Only the ones something
    /// names end up in the config.
    var servers: [ProxyConfig] = []
    /// The user's groups and the panels' groups, already merged.
    var groups: [ServerGroup] = []
    /// The server or group the user picked — what the `proxy` target means.
    var activeID: UUID?
    var rules: [RoutingRule] = []
    var dns = DNSSettings()
    var inbound: XrayInbound = .tun(name: "utun9", mtu: 1500)
    var logLevel = "warning"
    var logFile: String?
    var stats = true
    /// With IPv6 off inside the tunnel, asking the resolver for AAAA records
    /// only produces addresses nothing can reach.
    var ipv6 = true
    /// Whether geoip.dat / geosite.dat are on disk. Xray refuses to start on a
    /// `geosite:` matcher it cannot load, so without them those matchers are
    /// left out rather than taking the whole tunnel down.
    var hasGeoAssets = true
}

/// Renders the whole outbound graph — every server and group a rule, a DNS
/// resolver or the user's pick names — as one Xray configuration.
///
/// This is what the iOS build runs: Xray is the only core there, so what the
/// Mac does with sing-box selectors and url-tests is done here with Xray's own
/// pieces. A server is an outbound tagged by its id; a "fastest" group is a
/// `leastPing` balancer fed by the observatory; a manual group is simply the
/// member it currently points at, since Xray has no runtime selector.
enum XrayProfileBuilder {

    enum BuildError: LocalizedError, Equatable {
        /// Nothing is selected, or the selection no longer exists.
        case nothingSelected
        /// The selection resolves to nothing Xray can run.
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .nothingSelected:
                return "Select a server first."
            case .unsupported(let name):
                return "\(name) needs a protocol this build cannot run. "
                     + "Use a VLESS, VMess, Trojan, Shadowsocks or WireGuard server."
            }
        }
    }

    /// Where a target ends up in Xray's routing: one outbound, or a balancer.
    enum Route: Equatable {
        case outbound(String)
        case balancer(String)

        /// The routing-rule key and value this route is written as.
        var ruleField: (key: String, value: String) {
            switch self {
            case .outbound(let tag): return ("outboundTag", tag)
            case .balancer(let tag): return ("balancerTag", tag)
            }
        }
    }

    static let tunInboundTag = "tun-in"
    static let dnsModuleTag = "dns-module"
    /// Outbounds that carry no user traffic, so the traffic counters skip them.
    static let auxiliaryTags: Set<String> = [ProfileTags.direct, ProfileTags.block,
                                             ProfileTags.dnsOut]

    // MARK: - Entry points

    static func build(_ profile: XrayProfile) throws -> [String: Any] {
        var graph = Graph(profile)
        return try graph.render()
    }

    static func jsonString(_ profile: XrayProfile) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: try build(profile),
                                              options: [.prettyPrinted, .sortedKeys,
                                                        .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The servers the profile would actually dial: the selection, its group's
    /// members, and whatever a rule or resolver names. The ping tester and the
    /// session summary both want this rather than the whole list.
    static func referencedServers(_ profile: XrayProfile) -> [ProxyConfig] {
        var graph = Graph(profile)
        _ = try? graph.render()
        return graph.emittedServers
    }

    // MARK: - Matchers

    /// Domain matchers in the form Xray reads.
    ///
    /// A bare `example.com` is a *substring* match to Xray, while every list
    /// this app writes — and the sing-box builder — means "this domain and its
    /// subdomains", so bare entries gain the `domain:` prefix. Database-backed
    /// entries are dropped when the database is missing.
    static func xrayDomains(_ entries: [String], hasGeoAssets: Bool) -> [String] {
        let known = ["domain:", "full:", "keyword:", "regexp:", "dotless:"]
        var out: [String] = []
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let lower = entry.lowercased()
            if lower.hasPrefix("geosite:") || lower.hasPrefix("ext:") {
                if hasGeoAssets { out.append(entry) }
            } else if known.contains(where: { lower.hasPrefix($0) }) {
                out.append(entry)
            } else {
                let host = entry.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if !host.isEmpty { out.append("domain:" + host) }
            }
        }
        return out
    }

    static func xrayIPs(_ entries: [String], hasGeoAssets: Bool) -> [String] {
        entries.compactMap { raw in
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { return nil }
            let lower = entry.lowercased()
            if lower.hasPrefix("geoip:") || lower.hasPrefix("ext:") {
                return hasGeoAssets ? entry : nil
            }
            return entry
        }
    }

    /// Sniffed protocols Xray can match on. sing-box knows more (`dns`, `stun`,
    /// …); a rule asking only for those cannot be expressed here.
    static let xrayProtocols: Set<String> = ["http", "tls", "quic", "bittorrent"]

    // MARK: - The graph

    /// One build. Resolving a target has a side effect — whatever it names is
    /// emitted — so the state lives in a value that exists for one render.
    private struct Graph {
        let profile: XrayProfile
        let servers: [ProxyConfig]
        let groups: [ServerGroup]
        let serverByID: [UUID: ProxyConfig]
        let groupByID: [UUID: ServerGroup]

        private(set) var emittedServers: [ProxyConfig] = []
        private var emittedServerIDs: Set<UUID> = []
        private var balancers: [[String: Any]] = []
        private var balancerTags: Set<String> = []
        private var observed: [String] = []
        private var probe: (url: String, interval: String)?

        init(_ profile: XrayProfile) {
            self.profile = profile
            let expanded = OutboundGraph.expand(profile.servers, groups: profile.groups)
            servers = expanded.servers
            groups = expanded.groups
            serverByID = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            groupByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        // MARK: Render

        mutating func render() throws -> [String: Any] {
            let defaultRoute = try resolveDefault()

            var ruleList: [[String: Any]] = []
            let dns = renderDNS(defaultRoute: defaultRoute)

            // The resolver's own queries are told apart by the tag they leave
            // the DNS module with, so they go before anything matching on
            // destinations.
            ruleList += dns.rules
            if dns.section != nil {
                // In TUN mode the system's lookups arrive as plain packets to
                // port 53. Answering them in the core is what makes the DNS
                // settings — and FakeIP — apply at all.
                ruleList.append(["type": "field",
                                 "inboundTag": [XrayProfileBuilder.tunInboundTag],
                                 "port": "53",
                                 "outboundTag": ProfileTags.dnsOut])
            }
            ruleList += refusedNameRules()
            for rule in profile.rules {
                if let rendered = renderRule(rule, fallback: defaultRoute) {
                    ruleList.append(rendered)
                }
            }
            var finalRule: [String: Any] = ["type": "field", "network": "tcp,udp"]
            let field = defaultRoute.ruleField
            finalRule[field.key] = field.value
            ruleList.append(finalRule)

            var routing: [String: Any] = [
                "domainStrategy": "IPIfNonMatch",
                "rules": ruleList
            ]
            if !balancers.isEmpty { routing["balancers"] = balancers }

            var outbounds = emittedServers.map {
                XrayConfigBuilder.outbound($0, tag: ProfileTags.server($0.id))
            }
            outbounds.append(["tag": ProfileTags.direct, "protocol": "freedom", "settings": [:]])
            outbounds.append(["tag": ProfileTags.block, "protocol": "blackhole", "settings": [:]])
            if dns.section != nil {
                outbounds.append(["tag": ProfileTags.dnsOut, "protocol": "dns", "settings": [:]])
            }

            var config: [String: Any] = [
                "log": log(),
                "inbounds": inbounds(fakeDNS: dns.fakeDNS != nil),
                "outbounds": outbounds,
                "routing": routing
            ]
            if let section = dns.section { config["dns"] = section }
            if let fake = dns.fakeDNS { config["fakedns"] = fake }
            if !observed.isEmpty, let probe {
                config["observatory"] = [
                    "subjectSelector": observed,
                    "probeURL": probe.url,
                    "probeInterval": probe.interval,
                    // Sequential on purpose: a "fastest of everything" group
                    // over fifty nodes would otherwise open fifty TLS sessions
                    // at once inside an extension with a 50 MB budget.
                    "enableConcurrency": false
                ]
            }
            if profile.stats {
                config["stats"] = [String: Any]()
                config["policy"] = ["system": ["statsOutboundUplink": true,
                                               "statsOutboundDownlink": true]]
            }
            return config
        }

        private func log() -> [String: Any] {
            var log: [String: Any] = ["loglevel": profile.logLevel]
            // The access log is one line per connection; only debug wants it.
            log["access"] = profile.logLevel == "debug" ? "" : "none"
            if let file = profile.logFile, !file.isEmpty {
                log["error"] = file
                log["access"] = "none"
            }
            return log
        }

        private func inbounds(fakeDNS: Bool) -> [[String: Any]] {
            var sniff = ["http", "tls", "quic"]
            if fakeDNS { sniff.append("fakedns") }
            switch profile.inbound {
            case .tun(let name, let mtu):
                return [[
                    "tag": XrayProfileBuilder.tunInboundTag,
                    "port": 0,
                    "protocol": "tun",
                    "settings": ["name": name, "MTU": mtu],
                    "sniffing": ["enabled": true, "destOverride": sniff, "routeOnly": false]
                ]]
            case .localProxy(let ports):
                var list: [[String: Any]] = [[
                    "tag": "socks-in", "listen": ports.listen, "port": ports.socks,
                    "protocol": "socks", "settings": ["udp": true, "auth": "noauth"],
                    "sniffing": ["enabled": true, "destOverride": sniff]
                ]]
                if ports.serveHTTP {
                    list.append(["tag": "http-in", "listen": ports.listen, "port": ports.http,
                                 "protocol": "http",
                                 "sniffing": ["enabled": true, "destOverride": ["http", "tls"]]])
                }
                return list
            }
        }

        // MARK: Targets

        private mutating func resolveDefault() throws -> Route {
            guard let id = profile.activeID else { throw BuildError.nothingSelected }
            let target = OutboundGraph.target(for: id, groups: groups, servers: servers)
            guard target != .direct else { throw BuildError.nothingSelected }
            guard let route = resolve(target, default: nil) else {
                let name = groupByID[id]?.name ?? serverByID[id]?.name ?? ""
                throw BuildError.unsupported(name)
            }
            return route
        }

        /// The route a target takes, emitting whatever it needs. Nil when the
        /// target names nothing this core can run; the caller then falls back
        /// to the default, which is what a rule pointed at a vanished server
        /// asked for in the first place.
        mutating func resolve(_ target: RuleTarget, default fallback: Route?) -> Route? {
            switch target {
            case .proxy:  return fallback
            case .direct: return .outbound(ProfileTags.direct)
            case .block:  return .outbound(ProfileTags.block)
            case .server(let id):
                guard let server = serverByID[id], server.xraySupported else {
                    // A balancer's own id names its derived group.
                    if groupByID[id] != nil { return resolve(.group(id), default: fallback) }
                    return nil
                }
                emit(server)
                return .outbound(ProfileTags.server(id))
            case .group(let id):
                guard let group = groupByID[id] else { return nil }
                let members = runnableMembers(of: group)
                guard let first = members.first else { return nil }
                switch group.kind {
                case .selector:
                    let picked = members.first { $0.id == group.selectedID } ?? first
                    emit(picked)
                    return .outbound(ProfileTags.server(picked.id))
                case .urltest:
                    guard members.count > 1 else {
                        emit(first)
                        return .outbound(ProfileTags.server(first.id))
                    }
                    let tag = ProfileTags.group(id)
                    if !balancerTags.contains(tag) {
                        members.forEach { emit($0) }
                        let memberTags = members.map { ProfileTags.server($0.id) }
                        balancers.append([
                            "tag": tag,
                            "selector": memberTags,
                            "strategy": ["type": "leastPing"],
                            // Until the observatory has measured anything the
                            // balancer has no answer, and traffic would stall.
                            "fallbackTag": memberTags[0]
                        ])
                        balancerTags.insert(tag)
                        for memberTag in memberTags where !observed.contains(memberTag) {
                            observed.append(memberTag)
                        }
                        // One observatory serves every balancer, so the first
                        // group's probe wins and the shortest interval is kept.
                        if probe == nil {
                            probe = (group.testURL.isEmpty
                                        ? "https://www.gstatic.com/generate_204" : group.testURL,
                                     group.interval.isEmpty ? "3m" : group.interval)
                        }
                    }
                    return .balancer(tag)
                }
            }
        }

        /// Members Xray can actually dial, in the group's order. A member that
        /// is itself a group — a panel balancer added to a group of the
        /// user's — contributes its own members.
        private func runnableMembers(of group: ServerGroup,
                                     visiting: Set<UUID> = []) -> [ProxyConfig] {
            var result: [ProxyConfig] = []
            var seen = Set<UUID>()
            for id in group.memberIDs {
                if let server = serverByID[id] {
                    if server.xraySupported, seen.insert(server.id).inserted {
                        result.append(server)
                    }
                } else if let nested = groupByID[id], !visiting.contains(id), id != group.id {
                    for server in runnableMembers(of: nested,
                                                  visiting: visiting.union([group.id]))
                    where seen.insert(server.id).inserted {
                        result.append(server)
                    }
                }
            }
            return result
        }

        private mutating func emit(_ server: ProxyConfig) {
            guard emittedServerIDs.insert(server.id).inserted else { return }
            emittedServers.append(server)
        }

        // MARK: Rules

        /// One user or preset rule as an Xray field rule, or nil when Xray
        /// cannot express it. A rule is never widened: if a matcher it relies
        /// on cannot be rendered, the whole rule is left out rather than
        /// written with that matcher missing.
        mutating func renderRule(_ rule: RoutingRule, fallback: Route) -> [String: Any]? {
            guard rule.enabled, !rule.needsProcessMatching, !rule.invert,
                  rule.clashMode.isEmpty, rule.ruleSets.isEmpty else { return nil }

            var dict: [String: Any] = ["type": "field"]
            var matched = false

            if !rule.domains.isEmpty {
                let domains = XrayProfileBuilder.xrayDomains(rule.domains,
                                                             hasGeoAssets: profile.hasGeoAssets)
                guard !domains.isEmpty else { return nil }
                dict["domain"] = domains
                matched = true
            }
            if !rule.ips.isEmpty {
                let ips = XrayProfileBuilder.xrayIPs(rule.ips, hasGeoAssets: profile.hasGeoAssets)
                guard !ips.isEmpty else { return nil }
                dict[rule.direction == .source ? "source" : "ip"] = ips
                matched = true
            }
            let port = rule.port.trimmingCharacters(in: .whitespaces)
            if !port.isEmpty {
                dict["port"] = port.replacingOccurrences(of: " ", with: "")
                matched = true
            }
            if !rule.network.isEmpty {
                dict["network"] = rule.network
                matched = true
            }
            if !rule.protocols.isEmpty {
                let protocols = rule.protocols.map { $0.lowercased() }
                    .filter { XrayProfileBuilder.xrayProtocols.contains($0) }
                guard !protocols.isEmpty else { return nil }
                dict["protocol"] = protocols
                matched = true
            }
            guard matched else { return nil }

            let route = resolve(rule.target, default: fallback) ?? fallback
            let field = route.ruleField
            dict[field.key] = field.value
            if !rule.name.isEmpty { dict["ruleTag"] = rule.name }
            return dict
        }

        /// DNS rules that refuse a name. Xray's resolver cannot answer NXDOMAIN
        /// for a pattern, so the connection the name would have led to is
        /// dropped instead — the same outcome for the user.
        private func refusedNameRules() -> [[String: Any]] {
            guard profile.dns.enabled else { return [] }
            return profile.dns.rules.compactMap { rule in
                guard rule.enabled, rule.reject, !rule.invert, !rule.domains.isEmpty else {
                    return nil
                }
                let domains = XrayProfileBuilder.xrayDomains(rule.domains,
                                                             hasGeoAssets: profile.hasGeoAssets)
                guard !domains.isEmpty else { return nil }
                return ["type": "field", "domain": domains,
                        "outboundTag": ProfileTags.block]
            }
        }

        // MARK: DNS

        private struct RenderedDNS {
            var section: [String: Any]?
            var rules: [[String: Any]] = []
            var fakeDNS: [[String: Any]]?
        }

        /// Maps the resolver settings onto Xray's `dns` block.
        ///
        /// What sing-box expresses as a detour per server, Xray expresses as a
        /// tag per server plus a routing rule on that tag. The bootstrap
        /// resolver has no counterpart: Xray dials a node's hostname through
        /// the system resolver, not through this block.
        private mutating func renderDNS(defaultRoute: Route) -> RenderedDNS {
            let settings = profile.dns.sanitized()
            guard settings.enabled else { return RenderedDNS() }

            var out = RenderedDNS()

            // Which names each resolver answers, from the DNS rules.
            var domainsByTag: [String: [String]] = [:]
            for rule in settings.rules where rule.enabled && !rule.reject && !rule.invert {
                let domains = XrayProfileBuilder.xrayDomains(rule.domains,
                                                             hasGeoAssets: profile.hasGeoAssets)
                guard !domains.isEmpty else { continue }
                domainsByTag[rule.serverTag, default: []].append(contentsOf: domains)
            }

            var final: [[String: Any]] = []
            var scoped: [[String: Any]] = []
            var hasFakeIP = false

            for entry in settings.servers where entry.tag != DNSSettings.Builtin.bootstrap {
                guard var server = Self.xrayServer(entry) else { continue }
                if entry.kind == .fakeip {
                    hasFakeIP = true
                    // Only meaningful when the switch says so.
                    guard settings.fakeIPEnabled else { continue }
                }
                let tag = "dns-" + entry.tag
                if entry.kind != .fakeip && entry.kind != .local {
                    server["tag"] = tag
                    if let route = detourRoute(entry.detour, fallback: defaultRoute) {
                        let field = route.ruleField
                        out.rules.append(["type": "field", "inboundTag": [tag],
                                          field.key: field.value])
                    }
                }
                if let domains = domainsByTag[entry.tag], !domains.isEmpty {
                    var scopedServer = server
                    scopedServer["domains"] = domains
                    // A resolver named by a rule answers those names and only
                    // those, unless it is also the catch-all below.
                    scopedServer["skipFallback"] = entry.tag != settings.finalTag
                    scoped.append(scopedServer)
                    if entry.tag == settings.finalTag { final.insert(server, at: 0) }
                } else if entry.tag == settings.finalTag {
                    final.insert(server, at: 0)
                }
            }

            // FakeIP first when it is on: it is the answer for everything no
            // rule sent elsewhere.
            if settings.fakeIPEnabled {
                if !hasFakeIP { final.insert(["address": "fakedns"], at: 0) }
                else if let index = final.firstIndex(where: { ($0["address"] as? String) == "fakedns" }) {
                    final.insert(final.remove(at: index), at: 0)
                }
                var pools: [[String: Any]] = [["ipPool": settings.fakeIPv4Range, "poolSize": 65535]]
                if profile.ipv6 {
                    pools.append(["ipPool": settings.fakeIPv6Range, "poolSize": 65535])
                }
                out.fakeDNS = pools
            }

            var servers: [Any] = scoped + final
            if servers.isEmpty { servers = ["1.1.1.1"] }

            var section: [String: Any] = [
                "servers": servers,
                "tag": XrayProfileBuilder.dnsModuleTag,
                "queryStrategy": queryStrategy(settings.strategy),
                "disableCache": settings.disableCache,
                "serveStale": settings.optimistic
            ]
            if !settings.clientSubnet.isEmpty { section["clientIp"] = settings.clientSubnet }
            out.section = section
            return out
        }

        private mutating func detourRoute(_ detour: String, fallback: Route) -> Route? {
            guard !detour.isEmpty, let target = OutboundGraph.target(forTag: detour) else {
                return nil
            }
            return resolve(target, default: fallback) ?? fallback
        }

        private func queryStrategy(_ strategy: String) -> String {
            guard profile.ipv6 else { return "UseIPv4" }
            switch strategy {
            case "ipv4_only": return "UseIPv4"
            case "ipv6_only": return "UseIPv6"
            default:          return "UseIP"
            }
        }

        /// One resolver as an Xray server object, or nil when Xray has no
        /// such transport — it speaks no DNS-over-TLS, so those are skipped.
        static func xrayServer(_ entry: DNSServerEntry) -> [String: Any]? {
            let host = entry.server.trimmingCharacters(in: .whitespaces)
            let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            let local = entry.detour == ProfileTags.direct
            switch entry.kind {
            case .local:
                return ["address": "localhost"]
            case .fakeip:
                return ["address": "fakedns"]
            case .udp:
                guard !host.isEmpty else { return nil }
                var server: [String: Any] = ["address": host]
                if let port = entry.port, port != 53 { server["port"] = port }
                return server
            case .tcp:
                guard !host.isEmpty else { return nil }
                let scheme = local ? "tcp+local" : "tcp"
                return ["address": "\(scheme)://\(bracketed):\(entry.port ?? 53)"]
            case .https, .h3:
                // Xray has no DoH3; plain DoH to the same resolver is the
                // nearest thing and every public DoH3 resolver also serves it.
                guard !host.isEmpty else { return nil }
                let scheme = local ? "https+local" : "https"
                let port = entry.port.map { ":\($0)" } ?? ""
                let path = entry.path.isEmpty ? "/dns-query" : entry.path
                return ["address": "\(scheme)://\(bracketed)\(port)\(path.hasPrefix("/") ? path : "/" + path)"]
            case .quic:
                guard !host.isEmpty else { return nil }
                let port = entry.port.map { ":\($0)" } ?? ""
                return ["address": "quic+local://\(bracketed)\(port)"]
            case .tls:
                return nil
            }
        }
    }
}
