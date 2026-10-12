import Foundation

/// A subscription response body, recognised rather than flattened.
///
/// Veil used to run every response through the share-link parser, so a panel
/// that answered with a full `XRAY_JSON` template lost its routing, balancers,
/// observatory and DNS on the way in. The body is now classified first and kept
/// verbatim, so nothing is thrown away before the config model can use it.
struct SubscriptionPayload: Equatable {

    enum Format: String, Codable, Equatable {
        /// A complete Xray-core config document.
        case xrayJSON
        /// A complete Xray-core config document, base64-wrapped.
        case xrayBase64
        /// A complete sing-box config document.
        case singbox
        /// A Mihomo / Clash YAML profile.
        case mihomoYAML
        /// Newline-separated share links.
        case links
        /// Newline-separated share links, base64-wrapped.
        case base64Links
        /// Nothing we recognise.
        case unknown

        /// What to call this format in the interface.
        var label: String {
            switch self {
            case .xrayJSON:    return "Xray config"
            case .xrayBase64:  return "Xray config (base64)"
            case .singbox:     return "sing-box config"
            case .mihomoYAML:  return "Mihomo YAML"
            case .links:       return "Share links"
            case .base64Links: return "Share links (base64)"
            case .unknown:     return "Unrecognised"
            }
        }

        /// True when the body is a whole core config rather than a node list.
        var isFullConfig: Bool {
            self == .xrayJSON || self == .xrayBase64 || self == .singbox || self == .mihomoYAML
        }
    }

    /// Exactly what the server sent, byte for byte.
    var raw: String
    var format: Format
    /// Nodes Veil can connect to today.
    var servers: [ProxyConfig]
    /// The config document, decoded out of any base64 wrapper — the routing,
    /// balancers and DNS the node list cannot carry.
    var configJSON: String?
    /// The groups the panel declared, over `servers`.
    ///
    /// A panel that balances between nodes says so in its config: sing-box with
    /// a `urltest` or `selector` outbound, Xray with a `routing.balancers`
    /// entry. That is the grouping the provider intended, and it is kept as
    /// given. Share links carry no such thing, which is the one case where
    /// `BalancerGrouper` has to guess from the node names.
    var groups: [ServerGroup] = []

    /// What the body contained that did not become a server, and why. Parsing
    /// drops whatever it cannot use, and a node missing from the list for that
    /// reason is otherwise indistinguishable from one that was never offered.
    var skipped: [SkipNote] = []

    /// One reason, and how many entries it accounted for.
    struct SkipNote: Codable, Equatable {
        /// What was skipped: an outbound type, a link scheme, or a format.
        var label: String
        var count: Int
    }

    static func == (lhs: SubscriptionPayload, rhs: SubscriptionPayload) -> Bool {
        lhs.raw == rhs.raw && lhs.format == rhs.format
            && lhs.servers == rhs.servers && lhs.configJSON == rhs.configJSON
            && lhs.groups == rhs.groups
    }
}

/// Classifies and decodes a subscription body.
enum SubscriptionPayloadParser {

    static func parse(_ body: String) -> SubscriptionPayload {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SubscriptionPayload(raw: body, format: .unknown, servers: [], configJSON: nil)
        }

        if let json = jsonObject(from: trimmed) {
            return fromJSON(json, raw: body, text: trimmed, wasBase64: false)
        }

        // A base64 wrapper can hide either a link list or a whole config.
        if let data = LinkParser.decodeBase64(trimmed),
           let decoded = String(data: data, encoding: .utf8) {
            let inner = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = jsonObject(from: inner) {
                return fromJSON(json, raw: body, text: inner, wasBase64: true)
            }
            if inner.contains("://") {
                let read = readLinks(inner)
                return SubscriptionPayload(raw: body, format: .base64Links,
                                           servers: read.servers,
                                           configJSON: nil,
                                           skipped: read.skipped)
            }
        }

        if looksLikeMihomoYAML(trimmed) {
            // Recognised, and not read: saying so is the difference between a
            // subscription that is empty and one Veil cannot open.
            return SubscriptionPayload(raw: body, format: .mihomoYAML,
                                       servers: [], configJSON: nil,
                                       skipped: [SubscriptionPayload.SkipNote(label: "Mihomo YAML", count: 1)])
        }

        if trimmed.contains("://") {
            let read = readLinks(trimmed)
            return SubscriptionPayload(raw: body, format: .links,
                                       servers: read.servers,
                                       configJSON: nil,
                                       skipped: read.skipped)
        }

        return SubscriptionPayload(raw: body, format: .unknown, servers: [], configJSON: nil,
                                   skipped: [SubscriptionPayload.SkipNote(label: "Unrecognised", count: 1)])
    }

    /// Parses a list of share links, keeping a note of the lines that were not
    /// one. A line is named by its scheme, which is the part worth reporting.
    static func readLinks(_ text: String) -> (servers: [ProxyConfig], skipped: [SubscriptionPayload.SkipNote]) {
        var servers: [ProxyConfig] = []
        var skipped: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let server = try? LinkParser.parse(line) {
                servers.append(server)
            } else {
                let scheme = line.components(separatedBy: "://").first ?? line
                skipped[scheme.isEmpty ? "?" : String(scheme.prefix(24)), default: 0] += 1
            }
        }
        return (servers, notes(skipped))
    }


    /// Entries a body offered that did not become a server. Structural
    /// outbounds — `direct`, a selector, Xray's `freedom` — are not servers and
    /// are no surprise; anything else that produced nothing is worth naming,
    /// because from the list it is indistinguishable from a node the provider
    /// never sent.
    static func skipNotes(_ entries: [[String: Any]],
                          produced servers: [ProxyConfig],
                          typeKey: String = "type",
                          structural: Set<String>) -> [SubscriptionPayload.SkipNote] {
        let names = Set(servers.map(\.name))
        var counts: [String: Int] = [:]
        for entry in entries {
            guard let type = entry[typeKey] as? String, !structural.contains(type) else { continue }
            let tag = (entry["tag"] as? String) ?? type
            guard !names.contains(tag) else { continue }
            counts[type, default: 0] += 1
        }
        return notes(counts)
    }

    static func notes(_ counts: [String: Int]) -> [SubscriptionPayload.SkipNote] {
        counts.map { SubscriptionPayload.SkipNote(label: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count }
    }

    // MARK: - JSON bodies

    private static func fromJSON(_ json: [String: Any], raw: String,
                                 text: String, wasBase64: Bool) -> SubscriptionPayload {
        let outbounds = (json["outbounds"] as? [[String: Any]]) ?? []

        if isSingBox(json, outbounds: outbounds) {
            let endpoints = (json["endpoints"] as? [[String: Any]]) ?? []
            let all = outbounds + endpoints
            let servers = singBoxServers(all)
            return SubscriptionPayload(
                raw: raw, format: .singbox,
                servers: servers,
                configJSON: text,
                groups: singBoxGroups(outbounds, servers: servers),
                skipped: skipNotes(all, produced: servers,
                                   structural: ["direct", "block", "dns",
                                                "selector", "urltest"]))
        }

        let servers = xrayServers(outbounds)
        let xraySkips = skipNotes(outbounds, produced: servers, typeKey: "protocol",
                                  structural: ["freedom", "blackhole", "dns", "loopback"])
        return SubscriptionPayload(
            raw: raw, format: wasBase64 ? .xrayBase64 : .xrayJSON,
            servers: servers,
            configJSON: text,
            groups: xrayGroups(json, outbounds: outbounds, servers: servers),
            skipped: xraySkips)
    }

    /// sing-box and Xray configs both have `outbounds`. They are told apart by
    /// the route key (`route` vs `routing`) and by how an outbound names its
    /// protocol (`type` vs `protocol`).
    private static func isSingBox(_ json: [String: Any], outbounds: [[String: Any]]) -> Bool {
        if json["routing"] != nil { return false }
        if json["route"] != nil || json["endpoints"] != nil { return true }
        if outbounds.contains(where: { $0["protocol"] != nil }) { return false }
        return outbounds.contains { $0["type"] != nil }
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard text.hasPrefix("{"), let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A Clash/Mihomo profile is YAML with a `proxies:` block plus groups or
    /// rules. Checked line by line rather than by regex so a `proxies:` that
    /// appears inside a value cannot pass for a top-level key.
    private static func looksLikeMihomoYAML(_ text: String) -> Bool {
        var hasProxies = false
        var hasGroupsOrRules = false
        for rawLine in text.split(separator: "\n") {
            // Top level only: an indented `rules:` belongs to something else.
            guard let first = rawLine.first, first != " ", first != "\t" else { continue }
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("proxies:") { hasProxies = true }
            if line.hasPrefix("proxy-groups:") || line.hasPrefix("rules:") {
                hasGroupsOrRules = true
            }
        }
        return hasProxies && hasGroupsOrRules
    }

    // MARK: - Xray outbounds

    /// Maps the outbounds of an Xray config onto connectable nodes. Outbounds
    /// that are not servers (`freedom`, `blackhole`, `dns`) are skipped, and so
    /// is anything whose protocol Veil cannot run.
    static func xrayServers(_ outbounds: [[String: Any]]) -> [ProxyConfig] {
        var result: [ProxyConfig] = []
        for outbound in outbounds {
            guard let name = outbound["protocol"] as? String,
                  let proto = protocolNamed(name) else { continue }
            let tag = (outbound["tag"] as? String) ?? name
            let settings = (outbound["settings"] as? [String: Any]) ?? [:]
            let stream = (outbound["streamSettings"] as? [String: Any]) ?? [:]

            switch proto {
            case .vless, .vmess:
                for peer in settings["vnext"] as? [[String: Any]] ?? [] {
                    guard let address = peer["address"] as? String,
                          let port = intValue(peer["port"]) else { continue }
                    var config = ProxyConfig(name: tag, proto: proto,
                                             address: address, port: port)
                    if let user = (peer["users"] as? [[String: Any]])?.first {
                        config.uuid = user["id"] as? String
                        config.flow = nonEmpty(user["flow"] as? String)
                        config.encryption = nonEmpty(user["encryption"] as? String)
                        config.alterId = intValue(user["alterId"])
                    }
                    applyStream(stream, to: &config)
                    result.append(config)
                }
            case .trojan, .shadowsocks:
                for peer in settings["servers"] as? [[String: Any]] ?? [] {
                    guard let address = peer["address"] as? String,
                          let port = intValue(peer["port"]) else { continue }
                    var config = ProxyConfig(name: tag, proto: proto,
                                             address: address, port: port)
                    config.password = peer["password"] as? String
                    config.method = nonEmpty(peer["method"] as? String)
                    applyStream(stream, to: &config)
                    result.append(config)
                }
            case .wireguard:
                // Xray's own WireGuard outbound: the interface keys and
                // addresses at the top, one entry per peer.
                for peer in settings["peers"] as? [[String: Any]] ?? [] {
                    guard let endpoint = peer["endpoint"] as? String,
                          let (address, port) = splitEndpoint(endpoint) else { continue }
                    var config = ProxyConfig(name: tag, proto: .wireguard,
                                             address: address, port: port)
                    config.privateKey = nonEmpty(settings["secretKey"] as? String)
                    config.peerPublicKey = nonEmpty(peer["publicKey"] as? String)
                    config.presharedKey = nonEmpty(peer["preSharedKey"] as? String)
                    config.localAddresses = settings["address"] as? [String]
                    config.allowedIPs = peer["allowedIPs"] as? [String]
                    config.mtu = intValue(settings["mtu"])
                    config.reserved = (settings["reserved"] as? [Any])?.compactMap(intValue)
                    result.append(config)
                }
            case .hysteria2, .tuic, .anytls:
                // Not Xray protocols; a config claiming them is malformed.
                continue
            }
        }
        return result
    }

    private static func applyStream(_ stream: [String: Any], to config: inout ProxyConfig) {
        if let network = stream["network"] as? String,
           let parsed = TransportNetwork(rawValue: network.lowercased()) {
            config.network = parsed
        }
        if let security = stream["security"] as? String,
           let parsed = StreamSecurity(rawValue: security.lowercased()) {
            config.security = parsed
        }

        if let tls = stream["tlsSettings"] as? [String: Any] {
            config.sni = nonEmpty(tls["serverName"] as? String)
            config.alpn = tls["alpn"] as? [String]
            config.fingerprint = nonEmpty(tls["fingerprint"] as? String)
            config.allowInsecure = (tls["allowInsecure"] as? Bool) ?? false
        }
        if let reality = stream["realitySettings"] as? [String: Any] {
            config.security = .reality
            config.sni = nonEmpty(reality["serverName"] as? String) ?? config.sni
            config.fingerprint = nonEmpty(reality["fingerprint"] as? String) ?? config.fingerprint
            config.publicKey = nonEmpty(reality["publicKey"] as? String)
            config.shortId = nonEmpty(reality["shortId"] as? String)
            config.spiderX = nonEmpty(reality["spiderX"] as? String)
        }
        if let ws = stream["wsSettings"] as? [String: Any] {
            config.path = nonEmpty(ws["path"] as? String)
            config.host = nonEmpty((ws["headers"] as? [String: Any])?["Host"] as? String)
                ?? nonEmpty(ws["host"] as? String)
        }
        if let grpc = stream["grpcSettings"] as? [String: Any] {
            config.serviceName = nonEmpty(grpc["serviceName"] as? String)
        }
        if let http = stream["httpSettings"] as? [String: Any] {
            config.path = nonEmpty(http["path"] as? String) ?? config.path
            config.host = nonEmpty((http["host"] as? [String])?.first) ?? config.host
        }
        if let xhttp = stream["xhttpSettings"] as? [String: Any] {
            config.path = nonEmpty(xhttp["path"] as? String) ?? config.path
            config.host = nonEmpty(xhttp["host"] as? String) ?? config.host
            config.xhttpMode = nonEmpty(xhttp["mode"] as? String)
            if let extra = xhttp["extra"], let data = try? JSONSerialization.data(withJSONObject: extra) {
                config.xhttpExtra = String(data: data, encoding: .utf8)
            }
        }
    }

    // MARK: - sing-box outbounds

    /// Maps sing-box outbounds (and 1.11-style `endpoints`) onto nodes.
    /// Selectors, url-tests and the built-in direct/block outbounds are skipped.
    static func singBoxServers(_ outbounds: [[String: Any]]) -> [ProxyConfig] {
        var result: [ProxyConfig] = []
        for outbound in outbounds {
            guard let type = outbound["type"] as? String else { continue }
            guard let proto = protocolNamed(type) else { continue }
            // A WireGuard endpoint (sing-box 1.11+) states the remote in its
            // peer, not at the top level: `server`/`server_port` are absent and
            // `address` is the *local* interface. Reading it like any other
            // outbound dropped the node on the floor — which is what the node
            // editor's JSON pane was doing with its own output.
            let peer = (outbound["peers"] as? [[String: Any]])?.first
            let peerAddress = proto == .wireguard ? peer?["address"] as? String : nil
            guard let address = (outbound["server"] as? String)
                    ?? peerAddress
                    ?? firstLocalAddress(outbound),
                  !address.isEmpty else { continue }
            let port = intValue(outbound["server_port"])
                ?? (proto == .wireguard ? intValue(peer?["port"]) : nil)
                ?? defaultPort(proto)
            let tag = (outbound["tag"] as? String) ?? type

            var config = ProxyConfig(name: tag, proto: proto, address: address, port: port)
            config.uuid = nonEmpty(outbound["uuid"] as? String)
            config.password = nonEmpty(outbound["password"] as? String)
            config.method = nonEmpty(outbound["method"] as? String)
            config.flow = nonEmpty(outbound["flow"] as? String)
            config.alterId = intValue(outbound["alter_id"])
            config.congestionControl = nonEmpty(outbound["congestion_control"] as? String)
            config.udpRelayMode = nonEmpty(outbound["udp_relay_mode"] as? String)
            config.upMbps = intValue(outbound["up_mbps"])
            config.downMbps = intValue(outbound["down_mbps"])

            if let obfs = outbound["obfs"] as? [String: Any] {
                config.obfs = nonEmpty(obfs["type"] as? String)
                config.obfsPassword = nonEmpty(obfs["password"] as? String)
            }
            if proto == .wireguard {
                config.privateKey = nonEmpty(outbound["private_key"] as? String)
                config.localAddresses = outbound["address"] as? [String]
                    ?? outbound["local_address"] as? [String]
                config.mtu = intValue(outbound["mtu"])
                if let peer {
                    config.peerPublicKey = nonEmpty(peer["public_key"] as? String)
                    config.presharedKey = nonEmpty(peer["pre_shared_key"] as? String)
                    config.allowedIPs = peer["allowed_ips"] as? [String]
                    config.reserved = peer["reserved"] as? [Int]
                } else {
                    config.peerPublicKey = nonEmpty(outbound["peer_public_key"] as? String)
                    config.presharedKey = nonEmpty(outbound["pre_shared_key"] as? String)
                    config.allowedIPs = outbound["allowed_ips"] as? [String]
                    config.reserved = outbound["reserved"] as? [Int]
                }
            }

            applyTLS(outbound["tls"] as? [String: Any], to: &config)
            applyTransport(outbound["transport"] as? [String: Any], to: &config)
            result.append(config)
        }
        return result
    }

    private static func applyTLS(_ tls: [String: Any]?, to config: inout ProxyConfig) {
        guard let tls, (tls["enabled"] as? Bool) ?? false else { return }
        config.security = .tls
        config.sni = nonEmpty(tls["server_name"] as? String)
        config.alpn = tls["alpn"] as? [String]
        config.allowInsecure = (tls["insecure"] as? Bool) ?? false
        if let utls = tls["utls"] as? [String: Any] {
            config.fingerprint = nonEmpty(utls["fingerprint"] as? String)
        }
        if let reality = tls["reality"] as? [String: Any],
           (reality["enabled"] as? Bool) ?? false {
            config.security = .reality
            config.publicKey = nonEmpty(reality["public_key"] as? String)
            config.shortId = nonEmpty(reality["short_id"] as? String)
        }
    }

    private static func applyTransport(_ transport: [String: Any]?, to config: inout ProxyConfig) {
        guard let transport, let type = transport["type"] as? String else { return }
        if let network = TransportNetwork(rawValue: type.lowercased()) {
            config.network = network
        }
        config.path = nonEmpty(transport["path"] as? String)
        config.serviceName = nonEmpty(transport["service_name"] as? String)
        if let host = (transport["headers"] as? [String: Any])?["Host"] {
            config.host = nonEmpty(host as? String) ?? nonEmpty((host as? [String])?.first)
        } else if let hosts = transport["host"] as? [String] {
            config.host = nonEmpty(hosts.first)
        } else {
            config.host = nonEmpty(transport["host"] as? String) ?? config.host
        }
    }

    private static func firstLocalAddress(_ outbound: [String: Any]) -> String? {
        (outbound["local_address"] as? [String])?.first
    }

    private static func defaultPort(_ proto: ProxyProtocol) -> Int {
        proto == .wireguard ? 51820 : 443
    }

    // MARK: - Declared groups

    /// sing-box states its groups outright: a `urltest` or `selector` outbound
    /// naming its members by tag.
    static func singBoxGroups(_ outbounds: [[String: Any]],
                              servers: [ProxyConfig]) -> [ServerGroup] {
        let index = idsByTag(servers)
        var result: [ServerGroup] = []
        for outbound in outbounds {
            guard let type = outbound["type"] as? String,
                  type == "urltest" || type == "selector" else { continue }
            let members = (outbound["outbounds"] as? [String] ?? [])
                .flatMap { index[$0] ?? [] }
            // Groups routinely list `direct`, `block` or another group among
            // their members. Only the nodes survive, and a group with none of
            // them left is not a group.
            guard !members.isEmpty else { continue }

            var group = ServerGroup(name: (outbound["tag"] as? String) ?? type,
                                    kind: type == "urltest" ? .urltest : .selector,
                                    memberIDs: members)
            if let url = nonEmpty(outbound["url"] as? String) { group.testURL = url }
            if let interval = nonEmpty(outbound["interval"] as? String) {
                group.interval = interval
            }
            if let tolerance = intValue(outbound["tolerance"]) { group.tolerance = tolerance }
            if let picked = outbound["default"] as? String {
                group.selectedID = index[picked]?.first
            }
            group.interruptExistingConnections =
                (outbound["interrupt_exist_connections"] as? Bool) ?? false
            result.append(group)
        }
        return result
    }

    /// Xray names no members: a balancer is a list of tag prefixes matched
    /// against the outbound list, so the membership has to be resolved here the
    /// same way the core resolves it.
    ///
    /// Every strategy becomes a `urltest` group. Xray offers `random`,
    /// `roundRobin`, `leastPing` and `leastLoad`, and Veil has one automatic
    /// kind; what they share, and what the user cares about, is that the core
    /// picks rather than they do. The alternative — calling a random balancer a
    /// manual selector — would be wrong in the one way that matters.
    static func xrayGroups(_ json: [String: Any],
                           outbounds: [[String: Any]],
                           servers: [ProxyConfig]) -> [ServerGroup] {
        guard let routing = json["routing"] as? [String: Any],
              let balancers = routing["balancers"] as? [[String: Any]] else { return [] }
        let index = idsByTag(servers)
        let tags = outbounds.compactMap { $0["tag"] as? String }

        var result: [ServerGroup] = []
        for balancer in balancers {
            let selectors = (balancer["selector"] as? [String]) ?? []
            let members = tags
                .filter { tag in selectors.contains { tag.hasPrefix($0) } }
                .flatMap { index[$0] ?? [] }
            guard !members.isEmpty else { continue }
            result.append(ServerGroup(name: (balancer["tag"] as? String) ?? "balancer",
                                      kind: .urltest, memberIDs: members))
        }
        return result
    }

    /// Nodes by the tag they were built from. A list rather than a single id:
    /// one Xray outbound tag can carry several `vnext` addresses, and each of
    /// those became a node of its own.
    private static func idsByTag(_ servers: [ProxyConfig]) -> [String: [UUID]] {
        var index: [String: [UUID]] = [:]
        for server in servers { index[server.name, default: []].append(server.id) }
        return index
    }

    // MARK: - Small helpers

    /// Both cores spell Shadowsocks out in full; the share-link scheme (and so
    /// `ProxyProtocol`'s raw value) is `ss`.
    private static func protocolNamed(_ name: String) -> ProxyProtocol? {
        let normalized = name.lowercased()
        if normalized == "shadowsocks" { return .shadowsocks }
        return ProxyProtocol(rawValue: normalized)
    }

    /// `host:port`, with an IPv6 host in brackets.
    private static func splitEndpoint(_ endpoint: String) -> (String, Int)? {
        guard let colon = endpoint.lastIndex(of: ":"),
              let port = Int(endpoint[endpoint.index(after: colon)...]) else { return nil }
        let host = endpoint[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, port)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
