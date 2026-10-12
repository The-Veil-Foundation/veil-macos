import Foundation

/// Turns what the store knows into what the tunnel runs.
extension ServerStore {

    /// The Xray profile for connecting to `activeID` — a server or a group.
    func xrayProfile(activeID: UUID?) -> XrayProfile {
        var profile = XrayProfile()
        profile.servers = allServers
        profile.groups = OutboundGraph.allGroups(own: settings.serverGroups,
                                                 declared: declaredGroups)
        profile.activeID = activeID
        profile.rules = settings.effectiveRoutingRules
        profile.dns = settings.dns
        profile.inbound = .tun(name: "utun9", mtu: settings.tunnelMTU)
        profile.logLevel = settings.logLevel.rawValue
        profile.logFile = AppGroup.logURL.path
        profile.stats = true
        profile.ipv6 = settings.ipv6Enabled
        profile.hasGeoAssets = GeoAssetManager.shared.hasAssets
        return profile
    }

    /// The sidecar the extension reads beside the config.
    func tunnelSession(for activeID: UUID?) -> TunnelSession {
        var session = TunnelSession()
        let picked = server(withID: activeID)
        session.serverName = picked?.name ?? ""
        session.serverAddress = picked?.address ?? "127.0.0.1"
        session.mtu = settings.tunnelMTU
        session.ipv6Enabled = settings.ipv6Enabled
        session.dnsServers = settings.effectiveDNSServers
        session.maxMemoryMB = 48
        session.excludedAddresses = Self.literalAddresses(of: allServers)
        if settings.routingPreset.bypassesLAN {
            // Loopback never leaves the device, so there is nothing to exclude.
            session.excludedRanges = RoutingPreset.privateCIDRs
                .filter { !$0.hasPrefix("127.") && $0 != "::1/128" }
        }
        return session
    }

    /// Whether anything that will be built names the geo databases.
    var routingNeedsGeoAssets: Bool {
        let rules = settings.customRules + settings.routingPreset.builtInRules(blockAds: settings.blockAds)
        let dnsDomains = settings.dns.rules.flatMap(\.domains)
        return rules.contains { rule in
            rule.domains.contains { $0.lowercased().hasPrefix("geosite:") }
                || rule.ips.contains { $0.lowercased().hasPrefix("geoip:") }
        } || dnsDomains.contains { $0.lowercased().hasPrefix("geosite:") }
    }

    /// The servers' own addresses, where they are literal IPs. Hostnames are
    /// left alone: resolving them here would cost a lookup per node on every
    /// connect, and the probe for a hostname node is no worse off than before.
    static func literalAddresses(of servers: [ProxyConfig], limit: Int = 256) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for server in servers {
            for address in server.allAddresses where IPRange(address) != nil {
                guard seen.insert(address).inserted else { continue }
                result.append(address)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

// MARK: - Groups as the list sees them

extension ServerStore {

    /// The group with this id, the user's or a panel's.
    func group(withID id: UUID?) -> ServerGroup? {
        guard let id else { return nil }
        return allGroups.first { $0.id == id }
    }

    /// Whether the group belongs to the user, rather than to a panel that
    /// would bring it straight back on the next refresh.
    func isOwnGroup(_ id: UUID) -> Bool {
        settings.serverGroups.contains { $0.id == id }
    }

    /// A group's members, in its own order, as servers.
    func members(of group: ServerGroup) -> [ProxyConfig] {
        let servers = allServers
        return group.memberIDs.compactMap { id in servers.first { $0.id == id } }
    }

    /// Whether picking this id gives Xray something to dial.
    func canRun(_ id: UUID?) -> Bool {
        guard let id else { return false }
        if let group = group(withID: id) {
            return members(of: group).contains(where: \.xraySupported)
        }
        return server(withID: id)?.xraySupported ?? false
    }
}

extension ServerStore {

    /// Points a manual group at one of its members, wherever the group lives.
    func setSelectedMember(_ memberID: UUID?, groupID: UUID) {
        if let index = settings.serverGroups.firstIndex(where: { $0.id == groupID }) {
            settings.serverGroups[index].selectedID = memberID
            save()
            return
        }
        guard let sub = subscriptions.first(where: { $0.declaredGroups.contains { $0.id == groupID } })
        else { return }
        mutateSubscription(id: sub.id) { sub in
            guard var groups = sub.groups,
                  let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[index].selectedID = memberID
            sub.groups = groups
        }
    }
}
