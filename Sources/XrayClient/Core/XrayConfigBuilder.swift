import Foundation

/// Local listening ports for the Xray inbounds. The system proxy points here.
struct InboundPorts {
    var socks: Int = 10808
    var http: Int = 10809
    let listen: String = "127.0.0.1"
    /// Whether an HTTP inbound is opened next to the SOCKS one. Only the system
    /// proxy needs it; a bridge is reached over SOCKS alone, and every inbound
    /// nobody uses is a listening port for nothing.
    var serveHTTP = true
}

/// How traffic reaches the core.
///
/// macOS runs Xray as a subprocess and feeds it through local SOCKS/HTTP
/// inbounds (the system proxy or tun2socks points at them). iOS runs Xray
/// inside the NetworkExtension and hands it the utun descriptor directly, so
/// there the core uses its own layer-3 `tun` inbound and there is no local
/// proxy hop at all.
enum XrayInbound {
    case localProxy(InboundPorts)
    case tun(name: String, mtu: Int)
}

/// Builds an Xray-core JSON configuration from a `ProxyConfig`.
///
/// Produces the requested inbound plus one outbound for the selected server and
/// direct/block outbounds for routing rules.
enum XrayConfigBuilder {

    static func build(for cfg: ProxyConfig,
                      ports: InboundPorts = InboundPorts(),
                      rules: [RoutingRule] = [],
                      logLevel: String = "warning") -> [String: Any] {
        build(for: cfg, inbound: .localProxy(ports), rules: rules, logLevel: logLevel)
    }

    /// - Parameters:
    ///   - inbound: local SOCKS/HTTP proxy, or Xray's native layer-3 TUN.
    ///   - logFile: when set, the core appends its error log here instead of
    ///     stderr — the only way to read logs out of a NetworkExtension.
    ///   - dnsServers: when non-empty, an Xray `dns` section is emitted and all
    ///     port-53 traffic is answered by the core. Needed in TUN mode, where
    ///     the OS resolver's queries arrive as raw packets.
    ///   - stats: enables traffic counters on the proxy outbound.
    static func build(for cfg: ProxyConfig,
                      inbound: XrayInbound,
                      rules: [RoutingRule] = [],
                      logLevel: String = "warning",
                      logFile: String? = nil,
                      dnsServers: [String] = [],
                      stats: Bool = false) -> [String: Any] {
        let isBalancer = cfg.isBalancer
        let proxyOutbounds = outbounds(for: cfg)
        let balancerTags = isBalancer ? proxyOutbounds.compactMap { $0["tag"] as? String } : []

        var log: [String: Any] = ["loglevel": logLevel]
        // Xray's access log defaults to stdout: one line per connection, which
        // a browser turns into thousands per second. It goes nowhere unless the
        // user actually asked for debug output.
        log["access"] = logLevel == "debug" ? "" : "none"
        if let logFile, !logFile.isEmpty {
            log["error"] = logFile
            log["access"] = "none"
        }

        var auxOutbounds = [directOutbound(), blockOutbound()]
        if !dnsServers.isEmpty { auxOutbounds.append(dnsOutbound()) }

        var config: [String: Any] = [
            "log": log,
            "inbounds": inbounds(inbound),
            "outbounds": proxyOutbounds + auxOutbounds,
            "routing": routing(rules: rules,
                               isBalancer: isBalancer,
                               balancerTags: balancerTags,
                               hasDNS: !dnsServers.isEmpty)
        ]
        if !dnsServers.isEmpty {
            config["dns"] = ["servers": dnsServers, "queryStrategy": "UseIP"]
        }
        if stats {
            config["stats"] = [String: Any]()
            config["policy"] = [
                "system": [
                    "statsOutboundUplink": true,
                    "statsOutboundDownlink": true
                ]
            ]
        }
        return config
    }

    static func jsonData(for cfg: ProxyConfig,
                         ports: InboundPorts = InboundPorts(),
                         rules: [RoutingRule] = [],
                         logLevel: String = "warning") throws -> Data {
        let dict = build(for: cfg, ports: ports, rules: rules, logLevel: logLevel)
        return try JSONSerialization.data(withJSONObject: dict,
                                          options: [.prettyPrinted, .sortedKeys])
    }

    static func jsonString(for cfg: ProxyConfig,
                           inbound: XrayInbound,
                           rules: [RoutingRule] = [],
                           logLevel: String = "warning",
                           logFile: String? = nil,
                           dnsServers: [String] = [],
                           stats: Bool = false) throws -> String {
        let dict = build(for: cfg, inbound: inbound, rules: rules, logLevel: logLevel,
                         logFile: logFile, dnsServers: dnsServers, stats: stats)
        let data = try JSONSerialization.data(withJSONObject: dict,
                                              options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Inbounds

    private static func inbounds(_ inbound: XrayInbound) -> [[String: Any]] {
        switch inbound {
        case .localProxy(let p):  return proxyInbounds(p)
        case .tun(let name, let mtu): return [tunInbound(name: name, mtu: mtu)]
        }
    }

    private static func proxyInbounds(_ p: InboundPorts) -> [[String: Any]] {
        let all: [[String: Any]] = [
            [
                "tag": "socks-in",
                "listen": p.listen,
                "port": p.socks,
                "protocol": "socks",
                "settings": ["udp": true, "auth": "noauth"],
                "sniffing": ["enabled": true, "destOverride": ["http", "tls", "quic"]]
            ],
            [
                "tag": "http-in",
                "listen": p.listen,
                "port": p.http,
                "protocol": "http",
                "sniffing": ["enabled": true, "destOverride": ["http", "tls"]]
            ]
        ]
        return p.serveHTTP ? all : [all[0]]
    }

    /// Xray's own layer-3 inbound. It ignores `listen`/`port` and instead reads
    /// raw IP packets from the interface — on iOS from the descriptor published
    /// through the `xray.tun.fd` environment flag by the tunnel provider.
    /// Sniffing is what lets domain-based routing rules still work when all the
    /// core sees is IP packets.
    private static func tunInbound(name: String, mtu: Int) -> [String: Any] {
        [
            "tag": "tun-in",
            "port": 0,
            "protocol": "tun",
            "settings": ["name": name, "MTU": mtu],
            "sniffing": [
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": false
            ]
        ]
    }

    // MARK: - Outbound dispatch

    /// One server as an Xray outbound under the given tag. Exposed so a
    /// profile with many outbounds, and the node inspector, render a node
    /// exactly the way a single-server config does.
    static func outbound(_ cfg: ProxyConfig, tag: String) -> [String: Any] {
        var out: [String: Any]
        switch cfg.proto {
        case .vless:        out = vlessOutbound(cfg)
        case .vmess:        out = vmessOutbound(cfg)
        case .trojan:       out = trojanOutbound(cfg)
        case .shadowsocks:  out = shadowsocksOutbound(cfg)
        case .wireguard:    out = wireguardOutbound(cfg)
        case .hysteria2, .tuic, .anytls:
            // Handled by the sing-box core, never here. ConnectionManager routes
            // them to SingBoxConfigBuilder; this is only reachable if called
            // directly, so emit a harmless freedom outbound.
            out = ["protocol": "freedom", "settings": [:]]
        }
        out["tag"] = tag
        return out
    }

    /// Returns the proxy outbounds for a server. For a normal server this is a
    /// single outbound tagged "proxy"; for a balancer group it emits one
    /// outbound per node (`proxy-0`, `proxy-1`, …) so the routing balancer can
    /// distribute traffic across them.
    private static func outbounds(for cfg: ProxyConfig) -> [[String: Any]] {
        guard cfg.isBalancer else { return [outbound(cfg, tag: "proxy")] }
        let nodes = [cfg] + (cfg.alternates ?? [])
        return nodes.enumerated().map { outbound($1, tag: "proxy-\($0)") }
    }

    // No `mux` block is emitted, and that is deliberate.
    //
    // Xray's mux.cool needs the *server* to accept it, and the panels these
    // subscriptions come from leave it off. When the server does not speak it
    // the outbound still dials — the handshake succeeds and the request is
    // wrapped for `v1.mux.cool:9527` — and then every stream dies with
    // "failed to read metadata", which reaches the user as a connected tunnel
    // that carries nothing. XHTTP is worse again: it already multiplexes over
    // xmux, so a second layer buys nothing and breaks the first. Xray's own
    // default is off; matching it is what makes these nodes work.

    private static func vlessOutbound(_ cfg: ProxyConfig) -> [String: Any] {
        var user: [String: Any] = [
            "id": cfg.uuid ?? "",
            "encryption": cfg.encryption ?? "none"
        ]
        if let flow = cfg.flow, !flow.isEmpty { user["flow"] = flow }
        return [
            "protocol": "vless",
            "settings": [
                "vnext": [[
                    "address": cfg.address,
                    "port": cfg.port,
                    "users": [user]
                ]]
            ],
            "streamSettings": streamSettings(cfg)
        ]
    }

    private static func vmessOutbound(_ cfg: ProxyConfig) -> [String: Any] {
        let user: [String: Any] = [
            "id": cfg.uuid ?? "",
            "alterId": cfg.alterId ?? 0,
            "security": "auto"
        ]
        return [
            "protocol": "vmess",
            "settings": [
                "vnext": [[
                    "address": cfg.address,
                    "port": cfg.port,
                    "users": [user]
                ]]
            ],
            "streamSettings": streamSettings(cfg)
        ]
    }

    private static func trojanOutbound(_ cfg: ProxyConfig) -> [String: Any] {
        [
            "protocol": "trojan",
            "settings": [
                "servers": [[
                    "address": cfg.address,
                    "port": cfg.port,
                    "password": cfg.password ?? ""
                ]]
            ],
            "streamSettings": streamSettings(cfg)
        ]
    }

    private static func shadowsocksOutbound(_ cfg: ProxyConfig) -> [String: Any] {
        [
            "protocol": "shadowsocks",
            "settings": [
                "servers": [[
                    "address": cfg.address,
                    "port": cfg.port,
                    "method": cfg.method ?? "aes-256-gcm",
                    "password": cfg.password ?? ""
                ]]
            ],
            "streamSettings": streamSettings(cfg)
        ]
    }

    /// Xray's native WireGuard outbound. Used by the iOS build, where Xray is
    /// the only core; macOS routes WireGuard through sing-box instead.
    private static func wireguardOutbound(_ cfg: ProxyConfig) -> [String: Any] {
        var peer: [String: Any] = [
            // An IPv6 literal has to be bracketed or the port is misread.
            "endpoint": cfg.address.contains(":")
                ? "[\(cfg.address)]:\(cfg.port)" : "\(cfg.address):\(cfg.port)",
            "publicKey": cfg.peerPublicKey ?? "",
            "allowedIPs": cfg.effectiveAllowedIPs,
            "keepAlive": 25
        ]
        if let psk = cfg.presharedKey, !psk.isEmpty { peer["preSharedKey"] = psk }

        var settings: [String: Any] = [
            "secretKey": cfg.privateKey ?? "",
            "address": cfg.localAddresses ?? ["10.0.0.2/32"],
            "peers": [peer]
        ]
        if let mtu = cfg.mtu, mtu > 0 { settings["mtu"] = mtu }
        if let reserved = cfg.reserved, !reserved.isEmpty { settings["reserved"] = reserved }

        return ["protocol": "wireguard", "settings": settings]
    }

    // MARK: - Stream settings (transport + security)

    private static func streamSettings(_ cfg: ProxyConfig) -> [String: Any] {
        var settings: [String: Any] = [
            "network": cfg.network.rawValue,
            "sockopt": [
                // Disable Nagle's algorithm — lower latency for interactive traffic.
                "tcpNoDelay": true,
                // Enable TCP keepalive on the link to the server so idle
                // connections don't get silently dropped from NAT/firewall
                // translation tables (the usual cause of long-idle disconnects).
                "tcpKeepAliveIdle": 30,
                "tcpKeepAliveInterval": 15
            ]
        ]

        // Security layer
        switch cfg.security {
        case .tls:
            settings["security"] = "tls"
            settings["tlsSettings"] = tlsSettings(cfg)
        case .reality:
            settings["security"] = "reality"
            settings["realitySettings"] = realitySettings(cfg)
        case .none:
            settings["security"] = "none"
        }

        // Transport layer
        switch cfg.network {
        case .ws:
            var ws: [String: Any] = ["path": cfg.path ?? "/"]
            if let host = cfg.host, !host.isEmpty {
                ws["headers"] = ["Host": host]
            }
            settings["wsSettings"] = ws
        case .grpc:
            settings["grpcSettings"] = [
                "serviceName": cfg.serviceName ?? cfg.path ?? ""
            ]
        case .http:
            var h: [String: Any] = ["path": cfg.path ?? "/"]
            if let host = cfg.host, !host.isEmpty {
                h["host"] = [host]
            }
            settings["httpSettings"] = h
        case .xhttp:
            var x: [String: Any] = ["path": cfg.path ?? "/"]
            if let host = cfg.host, !host.isEmpty { x["host"] = host }
            if let mode = cfg.xhttpMode, !mode.isEmpty { x["mode"] = mode }
            var extra: [String: Any] = [:]
            if let pad = cfg.xPaddingBytes, !pad.isEmpty {
                extra["xPaddingBytes"] = pad
            }
            if let extraRaw = cfg.xhttpExtra,
               let data = extraRaw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (k, v) in parsed { extra[k] = v }
            }
            if !extra.isEmpty { x["extra"] = extra }
            settings["xhttpSettings"] = x
        case .tcp, .kcp, .quic:
            break
        }

        return settings
    }

    private static func tlsSettings(_ cfg: ProxyConfig) -> [String: Any] {
        var tls: [String: Any] = [
            "allowInsecure": cfg.allowInsecure
        ]
        if let sni = cfg.sni, !sni.isEmpty { tls["serverName"] = sni }
        if let alpn = cfg.alpn, !alpn.isEmpty { tls["alpn"] = alpn }
        if let fp = cfg.fingerprint, !fp.isEmpty { tls["fingerprint"] = fp }
        return tls
    }

    private static func realitySettings(_ cfg: ProxyConfig) -> [String: Any] {
        var reality: [String: Any] = [:]
        if let sni = cfg.sni { reality["serverName"] = sni }
        if let fp = cfg.fingerprint { reality["fingerprint"] = fp }
        if let pbk = cfg.publicKey { reality["publicKey"] = pbk }
        if let sid = cfg.shortId { reality["shortId"] = sid }
        if let spx = cfg.spiderX { reality["spiderX"] = spx }
        return reality
    }

    // MARK: - Auxiliary outbounds + routing

    private static func directOutbound() -> [String: Any] {
        ["tag": "direct", "protocol": "freedom", "settings": [:]]
    }

    private static func blockOutbound() -> [String: Any] {
        ["tag": "block", "protocol": "blackhole", "settings": [:]]
    }

    /// Answers DNS queries from the core's own `dns` section instead of letting
    /// them travel as opaque UDP. Only emitted alongside a `dns` config.
    private static func dnsOutbound() -> [String: Any] {
        ["tag": "dns-out", "protocol": "dns", "settings": [:]]
    }

    /// Builds the routing section from an ordered rule list. The first matching
    /// rule wins. For a balancer group the final catch-all rule uses an Xray
    /// `balancerTag` so traffic is distributed across all nodes.
    private static func routing(rules: [RoutingRule],
                                isBalancer: Bool,
                                balancerTags: [String] = [],
                                hasDNS: Bool = false) -> [String: Any] {
        var ruleList: [[String: Any]] = []
        // DNS first: in TUN mode the resolver's queries arrive as plain UDP
        // packets, and we want the core to answer them (and to fetch the answer
        // through the tunnel) rather than forwarding them verbatim.
        if hasDNS {
            ruleList.append([
                "type": "field",
                "port": "53",
                "outboundTag": "dns-out"
            ])
        }
        ruleList += rules.compactMap { $0.xrayRule(useBalancerForProxy: isBalancer) }
        let finalRule: [String: Any] = [
            "type": "field",
            "network": "tcp,udp",
            isBalancer ? "balancerTag" : "outboundTag": "proxy"
        ]
        ruleList.append(finalRule)

        var routing: [String: Any] = [
            "domainStrategy": "IPIfNonMatch",
            "rules": ruleList
        ]
        if isBalancer && !balancerTags.isEmpty {
            routing["balancers"] = [[
                "tag": "proxy",
                "selector": balancerTags,
                "strategy": ["type": "random"]
            ]]
        }
        return routing
    }
}
