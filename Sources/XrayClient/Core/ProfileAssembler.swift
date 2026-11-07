// macOS-only.
#if os(macOS)
import Foundation

/// Turns what the app knows — the server list, the settings, the current
/// selection — into the `SingBoxProfile` the core actually runs.
///
/// Keeping this separate from the connection manager means the profile can be
/// rendered and validated without starting anything, which is what the config
/// preview, the diagnostics export and the tests all want.
enum ProfileAssembler {

    struct Input {
        var servers: [ProxyConfig] = []
        var settings = AppSettings()
        /// The server or group the user picked in the list.
        var activeServerID: UUID?
        var ports = InboundPorts()
        /// True for TUN mode: adds the TUN inbound, which is what makes
        /// process matching work for every application rather than only for
        /// the ones that honour the system proxy.
        var includeTun: Bool = false
        /// Ports of the child Xray processes fronting nodes sing-box cannot
        /// speak. Filled in by `BridgeManager`.
        var bridgePorts: [UUID: Int] = [:]
        /// Groups the subscriptions declared, as parsed from their bodies.
        /// Kept apart from `settings.serverGroups` because the two have
        /// different owners: these are replaced wholesale on every refresh,
        /// the user's own are not touched at all.
        var subscriptionGroups: [ServerGroup] = []
        var clashSecret: String = ""
        var cacheFilePath: String = ""
        /// The resolvers macOS is using right now. See `routedResolvers`.
        var systemResolvers: [String] = []
        /// The default gateways macOS is using right now. A resolver that is
        /// also the gateway is never routed into the tunnel; see
        /// `routedResolvers`.
        var systemGateways: [String] = []
    }

    /// Where the core keeps its selector choices and downloaded rule-sets when
    /// it runs as the user. In TUN mode the helper substitutes its own path.
    static var userCachePath: String {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("XrayClient", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("core-cache.db").path
    }

    // MARK: - Assembly

    static func profile(_ input: Input) -> SingBoxProfile {
        let expansion = expand(input.servers, groups: allGroups(input))

        var profile = SingBoxProfile()
        profile.servers = expansion.servers
        profile.groups = expansion.groups
        profile.defaultTarget = target(for: input.activeServerID,
                                       groups: expansion.groups,
                                       servers: expansion.servers)
        profile.rules = input.settings.effectiveRoutingRules
        profile.explicitRuleSets = input.settings.ruleSets
        profile.dns = input.settings.dns.sanitized()
        profile.ports = input.ports
        profile.logLevel = input.settings.logLevel.rawValue
        profile.bridgePorts = input.bridgePorts
        profile.cacheFilePath = input.cacheFilePath.isEmpty
            ? userCachePath : input.cacheFilePath

        // A `clash_mode` rule reads the mode from the Clash server, so it stays
        // on for anyone whose rules use one, asked for or not.
        profile.clashAPI.enabled = input.settings.clashAPIEnabled
            || profile.rules.contains { $0.enabled && !$0.clashMode.isEmpty }
        profile.clashAPI.port = input.settings.controlAPIPort
        profile.clashAPI.secret = input.clashSecret

        if input.includeTun {
            var tun = TunInboundSettings()
            tun.mtu = input.settings.tunnelMTU > 0 ? input.settings.tunnelMTU : 9000
            tun.strictRoute = input.settings.tunStrictRoute
            // "Automatic" in Settings is an empty string, and it means the
            // stack this build knows to be good, not whatever the core would
            // pick. Only a stack the user chose by hand overrides it.
            if !input.settings.tunStack.isEmpty { tun.stack = input.settings.tunStack }
            if !input.settings.ipv6Enabled {
                tun.address = tun.address.filter { !$0.contains(":") }
            }
            tun.routeExcludeAddress = openedExcludes(tun.routeExcludeAddress,
                                                     for: profile.rules,
                                                     keeping: input.systemGateways)
            tun.routeExcludeAddress = routedResolvers(tun.routeExcludeAddress,
                                                      resolvers: input.systemResolvers,
                                                      gateways: input.systemGateways)
            profile.tun = tun
        }
        return profile
    }

    /// Drops the excluded ranges a rule wants routed.
    ///
    /// `route_exclude_address` keeps the LAN off the tunnel by installing
    /// routes around it, so a packet to a private address never reaches the
    /// core — and a rule saying "172.16.4.10 goes through the WireGuard peer"
    /// silently does nothing, because the core is never asked. Opening the
    /// whole covering block is what makes the rule work: the traffic enters
    /// the tunnel, the rule picks it up, and the preset's LAN bypass still
    /// sends the rest of that block straight back out.
    private static func openedExcludes(_ excludes: [String], for rules: [RoutingRule],
                                       keeping gateways: [String]) -> [String] {
        let claimed = rules
            .filter { $0.enabled && $0.target != .direct && $0.target != .block }
            .flatMap(\.destinationCIDRs)
            .compactMap(IPRange.init)
        guard !claimed.isEmpty else { return excludes }
        let retained = excludes.filter { entry in
            guard let range = IPRange(entry) else { return true }
            return !claimed.contains { range.overlaps($0) }
        }
        let originalRanges = excludes.compactMap(IPRange.init)
        let retainedRanges = retained.compactMap(IPRange.init)
        // Opening a LAN block for a rule must leave the physical next hop
        // reachable, even when it sits in the same block as the rule target.
        let gatewayExclusions = gateways.compactMap(IPRange.init).filter { gateway in
            gateway.prefix == 32
                && originalRanges.contains { $0.contains(gateway) }
                && !retainedRanges.contains { $0.contains(gateway) }
        }
        return retained + gatewayExclusions.map(\.cidr)
    }

    /// Cuts the system's own resolvers out of the excluded ranges.
    ///
    /// Most home networks hand out the router as the DNS server, and the
    /// router is on the LAN the tunnel keeps out. So every lookup an app made
    /// through the system went straight to the router and the provider behind
    /// it, never reaching `hijack-dns`: apps got the provider's answers —
    /// blocked or rewritten names included — while every indicator said the
    /// tunnel was up. Browsers with their own DNS-over-HTTPS were fine, which
    /// is why only "some apps" broke. With the resolver's own address routed
    /// into the tunnel, its queries are hijacked like any other; the rest of
    /// the LAN still stays off it.
    ///
    /// A resolver that is also the default gateway is left alone. DHCP very
    /// often hands out the router as both, and a host route sending the
    /// gateway into the utun takes the next hop away from every connection
    /// that leaves through the physical interface: the core's own outbound
    /// dials then fail with "network is unreachable" and nothing connects.
    static func routedResolvers(_ excludes: [String], resolvers: [String],
                                gateways: [String] = []) -> [String] {
        let kept = Set(gateways.compactMap { IPRange($0) }.filter { $0.prefix == 32 }.map(\.cidr))
        let holes = resolvers.compactMap { IPRange($0) }
            .filter { $0.prefix == 32 && !kept.contains($0.cidr) }
        guard !holes.isEmpty else { return excludes }
        return excludes.flatMap { entry -> [String] in
            guard let range = IPRange(entry) else { return [entry] }
            var pieces = [range]
            for hole in holes {
                pieces = pieces.flatMap { $0.subtracting(hole) }
            }
            return pieces == [range] ? [entry] : pieces.map(\.cidr)
        }
    }

    /// Servers in this profile that have to be fronted by a child Xray.
    static func bridgedServers(_ input: Input) -> [ProxyConfig] {
        var candidate = profile(input)
        candidate.bridgePorts = [:]
        return SingBoxProfileBuilder.referencedServers(in: candidate)
            .filter { SingBoxOutbound.needsXrayBridge($0) }
    }

    // MARK: - Internals

    /// Which outbound the `proxy` selector should resolve to. Shared with the
    /// iOS builder through `OutboundGraph`.
    static func target(for id: UUID?,
                       groups: [ServerGroup],
                       servers: [ProxyConfig]) -> RuleTarget {
        OutboundGraph.target(for: id, groups: groups, servers: servers)
    }

    /// The user's groups and the panels' groups as one list.
    static func allGroups(_ input: Input) -> [ServerGroup] {
        OutboundGraph.allGroups(own: input.settings.serverGroups,
                                declared: input.subscriptionGroups)
    }

    /// Flattens balancer entries into real nodes plus a group over them.
    static func expand(_ servers: [ProxyConfig],
                       groups: [ServerGroup]) -> (servers: [ProxyConfig], groups: [ServerGroup]) {
        OutboundGraph.expand(servers, groups: groups)
    }
}
#endif
