// macOS-only: the routing core on the desktop.
#if os(macOS)
import Foundation

/// The TUN inbound sing-box brings up itself.
///
/// This replaces the old `tun2socks` + `route`/`ifconfig` dance. It is not a
/// cosmetic change: `tun2socks` hands the core a finished SOCKS stream, and the
/// PID behind the connection is lost at that boundary, so `process_name` rules
/// can never match. With sing-box owning the interface the process is still
/// known when routing happens.
struct TunInboundSettings: Equatable {
    var tag = "tun-in"
    /// Leave nil and sing-box picks a free utun device itself.
    var interfaceName: String?
    var address: [String] = ["172.19.0.1/30", "fdfe:dcba:9876::1/126"]
    var mtu: Int = 9000
    var autoRoute: Bool = true
    /// Strict route is the leak-proof setting but fights other VPNs; off by
    /// default because a second tunnel on the machine is common.
    var strictRoute: Bool = false
    /// Addresses kept off the tunnel (LAN, link-local, multicast).
    var routeExcludeAddress: [String] = [
        "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12",
        "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32",
        "fe80::/10", "ff00::/8"
    ]
    /// The stack is pinned rather than left to the core.
    ///
    /// sing-box 1.14 — the version `Scripts/cores.lock` pins — defaults to
    /// `mixed`, which is a gVisor UDP stack over a *system* TCP stack. On
    /// macOS that system half never answers a SYN: ICMP is replied to and UDP
    /// is forwarded, so the tunnel looks healthy and the core logs nothing,
    /// while every TCP connection hangs until it times out. gVisor handles
    /// both halves and works. Revisit when the pinned core reaches 1.15, where
    /// the field is deprecated and sing-tun picks the stack itself.
    var stack: String = "gvisor"
    var udpTimeout: String = "5m"
}

/// Local control API (the Clash-compatible one sing-box implements).
struct ClashAPISettings: Equatable {
    var enabled: Bool = true
    var listen: String = "127.0.0.1"
    var port: Int = 9090
    var secret: String = ""
    /// "rule" | "global" | "direct" — rules may branch on it via `clashMode`.
    var defaultMode: String = "rule"
}

/// Everything needed to render one complete sing-box configuration.
struct SingBoxProfile {
    /// Every server the profile may reference. Unreferenced ones are dropped so
    /// a 500-node subscription does not become a 500-outbound config.
    var servers: [ProxyConfig] = []
    var groups: [ServerGroup] = []
    /// What the `proxy` selector resolves to — the server or group the user
    /// picked in the list.
    var defaultTarget: RuleTarget = .direct
    var rules: [RoutingRule] = []
    var explicitRuleSets: [RuleSetRef] = []
    var dns = DNSSettings()
    /// Unicast DNS from the physical service, used for System DNS in TUN.
    var physicalDNS: String?
    var ports = InboundPorts()
    /// nil renders a proxy-only config (system-proxy mode); non-nil adds the
    /// TUN inbound and with it process-aware routing.
    var tun: TunInboundSettings?
    var logLevel: String = "warning"
    var clashAPI = ClashAPISettings()
    /// server id → local SOCKS port of the child Xray that fronts it.
    var bridgePorts: [UUID: Int] = [:]
    /// Where sing-box keeps selector choices and rule-set caches.
    var cacheFilePath: String = ""
    /// Process names that must never be routed through the tunnel, or the
    /// tunnel would carry its own traffic.
    var loopGuardProcesses: [String] = SingBoxProfileBuilder.defaultLoopGuard
}

/// Renders a `SingBoxProfile` into sing-box JSON.
///
/// Unlike the old single-server builder, the output is a *graph*: every
/// referenced server is its own outbound with a stable tag, groups are
/// selectors or urltests over those tags, and a routing rule may point at any
/// of them. That is what "this app through Germany, that app through Japan"
/// requires.
enum SingBoxProfileBuilder {

    /// Veil's own processes. Traffic they originate goes straight out: the app
    /// fetching a subscription, the cores talking to their servers, and the
    /// helper, must not re-enter the tunnel they are building.
    static let defaultLoopGuard = ["Veil", "XrayClient", "sing-box", "xray", "VeilHelper"]

    // MARK: - Entry points

    static func build(_ profile: SingBoxProfile) -> [String: Any] {
        var dict: [String: Any] = [
            "log": ["level": level(profile.logLevel), "timestamp": true]
        ]

        let referenced = referencedServers(in: profile)
        let bridged = Set(profile.bridgePorts.keys)

        var outbounds: [[String: Any]] = []
        var endpoints: [[String: Any]] = []
        var nodeTags: [String] = []

        for server in referenced {
            let tag = ProfileTags.server(server.id)
            nodeTags.append(tag)
            if SingBoxOutbound.isEndpoint(server) && !bridged.contains(server.id) {
                endpoints.append(SingBoxOutbound.endpoint(server, tag: tag))
            } else {
                outbounds.append(SingBoxOutbound.outbound(
                    server, tag: tag,
                    bridgePort: profile.bridgePorts[server.id],
                    listen: profile.ports.listen))
            }
        }

        let serverIDs = Set(referenced.map(\.id))
        for group in profile.groups where !group.memberIDs.isEmpty {
            let members = group.memberIDs
                .filter { serverIDs.contains($0) }
                .map { ProfileTags.server($0) }
            guard !members.isEmpty else { continue }
            outbounds.append(groupOutbound(group, members: members))
            nodeTags.append(group.tag)
        }

        outbounds.append(defaultSelector(profile, candidates: nodeTags))
        outbounds.append(["type": "direct", "tag": ProfileTags.direct])
        outbounds.append(["type": "block", "tag": ProfileTags.block])

        // Which outbounds this config actually declares. A rule naming a
        // group that produced nothing — an automatic group whose query matched
        // no node, a hand-picked one whose members are all gone — would
        // otherwise send traffic to a tag the core has never heard of, and the
        // core refuses to start.
        var emitted = Set(nodeTags)
        emitted.formUnion([ProfileTags.defaultSelector, ProfileTags.direct, ProfileTags.block])

        dict["inbounds"] = inbounds(profile)
        dict["outbounds"] = outbounds
        if !endpoints.isEmpty { dict["endpoints"] = endpoints }
        if profile.dns.enabled { dict["dns"] = dns(profile) }
        dict["route"] = route(profile, emitted: emitted)
        if let experimental = experimental(profile) { dict["experimental"] = experimental }
        return dict
    }

    static func jsonData(_ profile: SingBoxProfile) throws -> Data {
        try JSONSerialization.data(withJSONObject: build(profile),
                                   options: [.prettyPrinted, .sortedKeys])
    }

    /// Servers actually named by the default target, a group or a rule.
    static func referencedServers(in profile: SingBoxProfile) -> [ProxyConfig] {
        var wanted = Set<UUID>()

        func want(_ target: RuleTarget) {
            switch target {
            case .server(let id):
                wanted.insert(id)
            case .group(let id):
                if let group = profile.groups.first(where: { $0.id == id }) {
                    wanted.formUnion(group.memberIDs)
                }
            case .proxy, .direct, .block:
                break
            }
        }

        want(profile.defaultTarget)
        for rule in profile.rules where rule.enabled { want(rule.target) }
        // A group the user can switch to from the menu bar stays in the config
        // even when no rule names it, otherwise switching would need a restart.
        for group in profile.groups { wanted.formUnion(group.memberIDs) }

        return profile.servers.filter { wanted.contains($0.id) }
    }

    // MARK: - Inbounds

    private static func inbounds(_ profile: SingBoxProfile) -> [[String: Any]] {
        var list: [[String: Any]] = [
            [
                "type": "socks",
                "tag": "socks-in",
                "listen": profile.ports.listen,
                "listen_port": profile.ports.socks
            ],
            [
                "type": "http",
                "tag": "http-in",
                "listen": profile.ports.listen,
                "listen_port": profile.ports.http
            ]
        ]
        guard let tun = profile.tun else { return list }

        var inbound: [String: Any] = [
            "type": "tun",
            "tag": tun.tag,
            "address": tun.address,
            "mtu": tun.mtu,
            "auto_route": tun.autoRoute,
            "strict_route": tun.strictRoute,
            "udp_timeout": tun.udpTimeout
        ]
        if let name = tun.interfaceName, !name.isEmpty {
            inbound["interface_name"] = name
        }
        if !tun.routeExcludeAddress.isEmpty {
            inbound["route_exclude_address"] = tun.routeExcludeAddress
        }
        // Empty only if a caller cleared it on purpose, which hands the choice
        // back to the core.
        if !tun.stack.isEmpty { inbound["stack"] = tun.stack }
        list.append(inbound)
        return list
    }

    // MARK: - Outbound groups

    private static func groupOutbound(_ group: ServerGroup,
                                      members: [String]) -> [String: Any] {
        switch group.kind {
        case .selector:
            var out: [String: Any] = [
                "type": "selector",
                "tag": group.tag,
                "outbounds": members
            ]
            if let selected = group.selectedID {
                let tag = ProfileTags.server(selected)
                if members.contains(tag) { out["default"] = tag }
            }
            if group.interruptExistingConnections {
                out["interrupt_exist_connections"] = true
            }
            return out
        case .urltest:
            return [
                "type": "urltest",
                "tag": group.tag,
                "outbounds": members,
                "url": group.testURL,
                "interval": group.interval,
                "tolerance": group.tolerance
            ]
        }
    }

    /// The `proxy` selector every "send this through the proxy" rule lands on.
    ///
    /// It lists every node and group so a Clash dashboard — or Veil's own menu
    /// bar — can switch the active server without rewriting the config, and
    /// defaults to whatever the user picked.
    private static func defaultSelector(_ profile: SingBoxProfile,
                                        candidates: [String]) -> [String: Any] {
        var members = candidates
        members.append(ProfileTags.direct)
        var out: [String: Any] = [
            "type": "selector",
            "tag": ProfileTags.defaultSelector,
            "outbounds": members
        ]
        let preferred = profile.defaultTarget.tag
        if members.contains(preferred) { out["default"] = preferred }
        return out
    }

    // MARK: - Route

    private static func route(_ profile: SingBoxProfile,
                              emitted: Set<String>? = nil) -> [String: Any] {
        var rules: [[String: Any]] = []

        // Sniffing has been a rule action since 1.12; doing it first is what
        // makes domain rules work for connections that arrive as bare IPs.
        rules.append(["action": "sniff"])
        if profile.tun != nil {
            rules.append(["protocol": "dns", "action": "hijack-dns"])
        }

        // Loop guard: Veil's own traffic never re-enters the tunnel.
        if profile.tun != nil, !profile.loopGuardProcesses.isEmpty {
            rules.append([
                "process_name": profile.loopGuardProcesses,
                "outbound": ProfileTags.direct
            ])
        }

        for rule in profile.rules where rule.enabled {
            if let rendered = routeRule(rule, emitted: emitted) { rules.append(rendered) }
        }

        var route: [String: Any] = [
            "rules": rules,
            "final": ProfileTags.defaultSelector,
            "auto_detect_interface": true
        ]
        // DNS rules speak the same matcher dialect, so a `geosite:` there needs
        // the same rule-set declared — sing-box refuses to start when a rule
        // names a set the config never defined.
        let sets = RuleSetCatalog.derive(from: profile.rules,
                                         dnsRules: profile.dns.enabled ? profile.dns.rules : [],
                                         explicit: profile.explicitRuleSets)
            .compactMap { $0.json() }
        if !sets.isEmpty { route["rule_set"] = sets }
        // Since 1.12 an outbound whose server is a hostname needs to be told
        // which resolver to use; without this the core refuses to start.
        if profile.dns.enabled {
            route["default_domain_resolver"] = profile.dns.bootstrapTag
        }
        return route
    }

    /// One `RoutingRule` as a sing-box route rule, or nil when it matches
    /// nothing.
    /// `emitted` is the set of tags this config declares. Passing it makes a
    /// rule whose target was not built fall back to the default proxy rather
    /// than name a tag that does not exist: the rule asked for the traffic to
    /// be proxied, and the group it named is the part that is missing.
    static func routeRule(_ rule: RoutingRule,
                          emitted: Set<String>? = nil) -> [String: Any]? {
        guard rule.hasMatcher else { return nil }
        var tag = rule.target.tag
        if let emitted, !emitted.contains(tag) { tag = ProfileTags.defaultSelector }
        var r: [String: Any] = ["outbound": tag]
        var ruleSetTags = rule.ruleSets

        let domains = MatcherSyntax.domains(rule.domains)
        if !domains.exact.isEmpty { r["domain"] = domains.exact }
        if !domains.suffix.isEmpty { r["domain_suffix"] = domains.suffix }
        if !domains.keyword.isEmpty { r["domain_keyword"] = domains.keyword }
        if !domains.regex.isEmpty { r["domain_regex"] = domains.regex }
        ruleSetTags.append(contentsOf: domains.ruleSetTags)

        let ips = MatcherSyntax.ips(rule.ips)
        let sourceSide = rule.direction == .source
        if !ips.cidrs.isEmpty {
            r[sourceSide ? "source_ip_cidr" : "ip_cidr"] = ips.cidrs
        }
        if ips.isPrivate {
            r[sourceSide ? "source_ip_is_private" : "ip_is_private"] = true
        }
        ruleSetTags.append(contentsOf: ips.ruleSetTags)
        if !ips.ruleSetTags.isEmpty && sourceSide {
            r["rule_set_ip_cidr_match_source"] = true
        }

        let (ports, ranges) = MatcherSyntax.ports(rule.port)
        if !ports.isEmpty { r[sourceSide ? "source_port" : "port"] = ports }
        if !ranges.isEmpty {
            r[sourceSide ? "source_port_range" : "port_range"] = ranges
        }

        if !rule.processNames.isEmpty { r["process_name"] = rule.processNames }
        if !rule.processPaths.isEmpty { r["process_path"] = rule.processPaths }
        if !rule.network.isEmpty { r["network"] = rule.network }
        if !rule.protocols.isEmpty { r["protocol"] = rule.protocols }
        if !rule.clashMode.isEmpty { r["clash_mode"] = rule.clashMode }

        let uniqueSets = orderedUnique(ruleSetTags)
        if !uniqueSets.isEmpty { r["rule_set"] = uniqueSets }
        if rule.invert { r["invert"] = true }

        // Everything above could still have produced no matcher (a rule whose
        // only entries were `ext:` domains, say).
        let matcherKeys = r.keys.filter { $0 != "outbound" && $0 != "invert" }
        return matcherKeys.isEmpty ? nil : r
    }

    // MARK: - DNS

    private static func dns(_ profile: SingBoxProfile) -> [String: Any] {
        let settings = profile.dns
        let localTags = Set(settings.servers.filter { $0.kind == .local }.map(\.tag))
        let replaceLocal = profile.tun != nil && !localTags.isEmpty
        var mdnsTag = "veil-mdns"
        let tags = Set(settings.servers.map(\.tag))
        while tags.contains(mdnsTag) { mdnsTag += "-" }
        var servers = settings.servers.compactMap { server -> [String: Any]? in
            if replaceLocal, server.kind == .local {
                // Asking macOS for its default DNS here can select our own
                // TUN DNS. With no physical resolver, answer from hosts only.
                var entry: [String: Any] = ["tag": server.tag, "type": "hosts"]
                if let address = profile.physicalDNS {
                    entry["type"] = "udp"
                    entry["server"] = address
                }
                if !server.strategy.isEmpty { entry["strategy"] = server.strategy }
                return entry
            }
            return server.json(fakeIPv4: settings.fakeIPv4Range, fakeIPv6: settings.fakeIPv6Range)
        }
        if replaceLocal { servers.append(["type": "mdns", "tag": mdnsTag]) }
        if settings.fakeIPEnabled,
           !settings.servers.contains(where: { $0.kind == .fakeip }) {
            servers.append([
                "type": "fakeip",
                "tag": DNSSettings.Builtin.fakeIP,
                "inet4_range": settings.fakeIPv4Range,
                "inet6_range": settings.fakeIPv6Range
            ])
        }

        var rules: [[String: Any]] = []
        for rule in settings.rules where rule.enabled && rule.hasMatcher {
            guard let rendered = dnsRule(rule) else { continue }
            // Keep mDNS where the original System rule would have matched.
            if replaceLocal, localTags.contains(rule.serverTag), !rule.reject {
                var matcher = rendered
                matcher.removeValue(forKey: "server")
                rules.append(["type": "logical", "mode": "and",
                              "rules": [matcher, ["preferred_by": [mdnsTag]]],
                              "server": mdnsTag])
            }
            rules.append(rendered)
        }
        if replaceLocal, localTags.contains(settings.finalTag) {
            rules.append(["preferred_by": [mdnsTag], "server": mdnsTag])
        }

        var dict: [String: Any] = [
            "servers": servers,
            "rules": rules,
            "strategy": settings.strategy,
            "disable_cache": settings.disableCache,
            "cache_capacity": settings.cacheCapacity,
            "reverse_mapping": settings.reverseMapping
        ]
        if !settings.finalTag.isEmpty { dict["final"] = settings.finalTag }
        if !settings.timeout.isEmpty { dict["timeout"] = settings.timeout }
        if settings.optimistic && !settings.disableCache { dict["optimistic"] = true }
        if !settings.clientSubnet.isEmpty { dict["client_subnet"] = settings.clientSubnet }
        // No `dns.fakeip` block: the legacy options were deprecated in 1.12 and
        // removed in 1.14. FakeIP is a server type now, added above.
        return dict
    }

    private static func dnsRule(_ rule: DNSRule) -> [String: Any]? {
        var r: [String: Any] = [:]
        var ruleSetTags = rule.ruleSets

        let domains = MatcherSyntax.domains(rule.domains)
        if !domains.exact.isEmpty { r["domain"] = domains.exact }
        if !domains.suffix.isEmpty { r["domain_suffix"] = domains.suffix }
        if !domains.keyword.isEmpty { r["domain_keyword"] = domains.keyword }
        if !domains.regex.isEmpty { r["domain_regex"] = domains.regex }
        ruleSetTags.append(contentsOf: domains.ruleSetTags)

        if !rule.processNames.isEmpty { r["process_name"] = rule.processNames }
        let uniqueSets = orderedUnique(ruleSetTags)
        if !uniqueSets.isEmpty { r["rule_set"] = uniqueSets }
        guard !r.isEmpty else { return nil }

        if rule.invert { r["invert"] = true }
        if rule.reject {
            r["action"] = "reject"
        } else {
            guard !rule.serverTag.isEmpty else { return nil }
            r["server"] = rule.serverTag
        }
        return r
    }

    // MARK: - Experimental (control API + cache)

    private static func experimental(_ profile: SingBoxProfile) -> [String: Any]? {
        var dict: [String: Any] = [:]
        if profile.clashAPI.enabled {
            var api: [String: Any] = [
                "external_controller": "\(profile.clashAPI.listen):\(profile.clashAPI.port)",
                "default_mode": profile.clashAPI.defaultMode
            ]
            if !profile.clashAPI.secret.isEmpty { api["secret"] = profile.clashAPI.secret }
            dict["clash_api"] = api
        }
        if !profile.cacheFilePath.isEmpty {
            dict["cache_file"] = [
                "enabled": true,
                "path": profile.cacheFilePath,
                "store_fakeip": profile.dns.fakeIPEnabled
            ]
        }
        return dict.isEmpty ? nil : dict
    }

    // MARK: - Helpers

    /// Xray uses debug/info/warning/error/none; sing-box uses
    /// trace/debug/info/warn/error/fatal/panic. Map onto the nearest level.
    static func level(_ xrayLevel: String) -> String {
        switch xrayLevel {
        case "debug":   return "debug"
        case "info":    return "info"
        case "warning": return "warn"
        case "error":   return "error"
        case "none":    return "fatal"
        default:        return "warn"
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
#endif
