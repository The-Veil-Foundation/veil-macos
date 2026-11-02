import XCTest
@testable import XrayClient

/// Covers the layer-3 config the iOS build feeds to Xray inside the
/// NetworkExtension. The desktop app never uses this shape, so without these
/// tests a change to the builder could silently break the phone.
final class TunConfigTests: XCTestCase {

    private func realityServer() -> ProxyConfig {
        var cfg = ProxyConfig(name: "NL", proto: .vless, address: "1.2.3.4", port: 443)
        cfg.uuid = "11111111-2222-3333-4444-555555555555"
        cfg.flow = "xtls-rprx-vision"
        cfg.security = .reality
        cfg.sni = "www.microsoft.com"
        cfg.fingerprint = "chrome"
        cfg.publicKey = "xr0PXbLQvB0qCLLm7d5MO_9y2Bqk5DoMHKcVAKTZ1UA"
        cfg.shortId = "0123abcd"
        return cfg
    }

    private func tunConfig(_ cfg: ProxyConfig,
                           rules: [RoutingRule] = [],
                           dns: [String] = ["1.1.1.1"],
                           stats: Bool = true) -> [String: Any] {
        XrayConfigBuilder.build(for: cfg,
                                inbound: .tun(name: "utun9", mtu: 1500),
                                rules: rules,
                                logLevel: "warning",
                                logFile: "/tmp/xray.log",
                                dnsServers: dns,
                                stats: stats)
    }

    // MARK: - Inbound

    func testTunInboundReplacesLocalProxies() {
        let config = tunConfig(realityServer())
        let inbounds = config["inbounds"] as! [[String: Any]]

        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["protocol"] as? String, "tun")
        XCTAssertEqual(inbounds[0]["tag"] as? String, "tun-in")

        let settings = inbounds[0]["settings"] as! [String: Any]
        XCTAssertEqual(settings["name"] as? String, "utun9")
        XCTAssertEqual(settings["MTU"] as? Int, 1500)
    }

    /// All the core sees is IP packets, so without sniffing no domain rule
    /// would ever match.
    func testTunInboundEnablesSniffing() {
        let inbounds = tunConfig(realityServer())["inbounds"] as! [[String: Any]]
        let sniffing = inbounds[0]["sniffing"] as! [String: Any]
        XCTAssertEqual(sniffing["enabled"] as? Bool, true)
        XCTAssertEqual(sniffing["destOverride"] as? [String], ["http", "tls", "quic"])
    }

    func testLocalProxyInboundsStillDefaultForDesktop() {
        let inbounds = XrayConfigBuilder.build(for: realityServer())["inbounds"] as! [[String: Any]]
        XCTAssertEqual(inbounds.map { $0["protocol"] as? String }, ["socks", "http"])
    }

    // MARK: - Outbound

    /// The TUN path must reuse the exact same outbound builder as the desktop
    /// path — Reality/XHTTP settings have to be byte-for-byte identical.
    func testOutboundMatchesDesktopBuild() {
        let server = realityServer()
        let tun = tunConfig(server)["outbounds"] as! [[String: Any]]
        let desktop = XrayConfigBuilder.build(for: server)["outbounds"] as! [[String: Any]]

        let tunProxy = tun.first { $0["tag"] as? String == "proxy" }!
        let desktopProxy = desktop.first { $0["tag"] as? String == "proxy" }!
        XCTAssertEqual(NSDictionary(dictionary: tunProxy),
                       NSDictionary(dictionary: desktopProxy))
    }

    func testWireGuardOutboundIsNativeXray() {
        var wg = ProxyConfig(name: "WG", proto: .wireguard, address: "9.9.9.9", port: 51820)
        wg.privateKey = "cHJpdmF0ZQ=="
        wg.peerPublicKey = "cHVibGlj"
        wg.presharedKey = "cHNr"
        wg.localAddresses = ["10.2.0.2/32"]
        wg.mtu = 1420

        let outbounds = tunConfig(wg)["outbounds"] as! [[String: Any]]
        let proxy = outbounds.first { $0["tag"] as? String == "proxy" }!
        XCTAssertEqual(proxy["protocol"] as? String, "wireguard")
        // WireGuard brings its own transport — mux must not be attached.
        XCTAssertNil(proxy["mux"])

        let settings = proxy["settings"] as! [String: Any]
        XCTAssertEqual(settings["secretKey"] as? String, "cHJpdmF0ZQ==")
        XCTAssertEqual(settings["address"] as? [String], ["10.2.0.2/32"])
        XCTAssertEqual(settings["mtu"] as? Int, 1420)

        let peer = (settings["peers"] as! [[String: Any]])[0]
        XCTAssertEqual(peer["endpoint"] as? String, "9.9.9.9:51820")
        XCTAssertEqual(peer["publicKey"] as? String, "cHVibGlj")
        XCTAssertEqual(peer["preSharedKey"] as? String, "cHNr")
    }

    // MARK: - DNS

    /// In TUN mode the resolver's queries arrive as raw UDP, so they have to be
    /// picked off by a port-53 rule and answered by the core's DNS outbound —
    /// otherwise they would leave the device unproxied.
    func testDNSSectionAndPort53RuleComeFirst() {
        let config = tunConfig(realityServer(),
                               rules: RoutingPreset.bypassLAN.builtInRules(blockAds: false))

        let dns = config["dns"] as! [String: Any]
        XCTAssertEqual(dns["servers"] as? [String], ["1.1.1.1"])

        let outbounds = config["outbounds"] as! [[String: Any]]
        XCTAssertTrue(outbounds.contains { $0["tag"] as? String == "dns-out" })

        let rules = (config["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(rules.first?["port"] as? String, "53")
        XCTAssertEqual(rules.first?["outboundTag"] as? String, "dns-out")
    }

    func testNoDNSSectionWhenNoServersGiven() {
        let config = tunConfig(realityServer(), dns: [])
        XCTAssertNil(config["dns"])
        let outbounds = config["outbounds"] as! [[String: Any]]
        XCTAssertFalse(outbounds.contains { $0["tag"] as? String == "dns-out" })
        let rules = (config["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertNotEqual(rules.first?["outboundTag"] as? String, "dns-out")
    }

    // MARK: - Log & stats

    /// A NetworkExtension has no stderr the app can read, so the core must be
    /// told to append to a file in the shared container instead.
    func testLogGoesToFile() {
        let log = tunConfig(realityServer())["log"] as! [String: Any]
        XCTAssertEqual(log["error"] as? String, "/tmp/xray.log")
        XCTAssertEqual(log["access"] as? String, "none")
        XCTAssertEqual(log["loglevel"] as? String, "warning")
    }

    func testStatsCountersEnabled() {
        let config = tunConfig(realityServer())
        XCTAssertNotNil(config["stats"])
        let system = (config["policy"] as! [String: Any])["system"] as! [String: Any]
        XCTAssertEqual(system["statsOutboundUplink"] as? Bool, true)
        XCTAssertEqual(system["statsOutboundDownlink"] as? Bool, true)
    }

    func testDesktopBuildStillHasNoStatsOrLogFile() {
        let config = XrayConfigBuilder.build(for: realityServer())
        XCTAssertNil(config["stats"])
        XCTAssertNil(config["dns"])
        XCTAssertNil((config["log"] as! [String: Any])["error"])
    }

    // MARK: - Protocol support

    func testProtocolsXrayCanRunAlone() {
        for proto in [ProxyProtocol.vless, .vmess, .trojan, .shadowsocks, .wireguard] {
            XCTAssertTrue(ProxyConfig(name: "x", proto: proto, address: "a", port: 1).xraySupported,
                          "\(proto) should be supported by the Xray-only iOS build")
        }
        for proto in [ProxyProtocol.hysteria2, .tuic, .anytls] {
            XCTAssertFalse(ProxyConfig(name: "x", proto: proto, address: "a", port: 1).xraySupported,
                           "\(proto) needs sing-box and cannot run on the iOS build")
        }
    }
    /// mux.cool needs server-side support the panels do not enable, and an
    /// XHTTP node fronted by a bridge dies on it with "failed to read
    /// metadata" — a tunnel that connects and carries nothing.
    func testNoOutboundEnablesMux() {
        var xhttp = ProxyConfig(name: "EU", proto: .vless, address: "a.example", port: 443)
        xhttp.uuid = "22222222-3333-4444-5555-666666666666"
        xhttp.network = .xhttp
        xhttp.security = .tls

        var vision = ProxyConfig(name: "DE", proto: .vless, address: "b.example", port: 443)
        vision.uuid = "11111111-2222-3333-4444-555555555555"
        vision.flow = "xtls-rprx-vision"
        vision.security = .reality

        for cfg in [xhttp, vision] {
            let json = try! XrayConfigBuilder.jsonData(for: cfg, ports: InboundPorts(),
                                                       rules: [], logLevel: "warning")
            let root = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
            let outbounds = root["outbounds"] as! [[String: Any]]
            for out in outbounds {
                XCTAssertNil(out["mux"], "\(cfg.name): \(out["tag"] ?? "?") must not enable mux")
            }
        }
    }

}

/// The router is usually the DNS server, and it sits in a range the tunnel
/// excludes — so system lookups bypassed `hijack-dns` entirely.
final class ResolverRoutingTests: XCTestCase {

    func testTheResolverIsCutOutOfItsExcludedRange() {
        let result = ProfileAssembler.routedResolvers(
            ["192.168.0.0/16", "10.0.0.0/8"], resolvers: ["192.168.1.1"])
        XCTAssertFalse(result.contains("192.168.0.0/16"))
        XCTAssertTrue(result.contains("10.0.0.0/8"))
        let ranges = result.compactMap(IPRange.init)
        let resolver = IPRange("192.168.1.1")!
        XCTAssertFalse(ranges.contains { $0.overlaps(resolver) }, "the resolver must be routed")
        for neighbour in ["192.168.1.0", "192.168.1.2", "192.168.0.1", "192.168.255.254"] {
            let address = IPRange(neighbour)!
            XCTAssertTrue(ranges.contains { $0.contains(address) }, "\(neighbour) stays off the tunnel")
        }
        XCTAssertEqual(result.count, 16 + 1)
    }

    func testPublicResolversLeaveTheExcludesAlone() {
        let excludes = ["192.168.0.0/16", "fe80::/10"]
        XCTAssertEqual(ProfileAssembler.routedResolvers(excludes, resolvers: ["1.1.1.1", "fe80::1"]),
                       excludes)
    }

    func testTheTunInboundRoutesTheResolver() {
        var input = ProfileAssembler.Input()
        input.includeTun = true
        input.systemResolvers = ["192.168.1.1"]
        let excludes = ProfileAssembler.profile(input).tun?.routeExcludeAddress ?? []
        XCTAssertFalse(excludes.contains("192.168.0.0/16"))
        XCTAssertFalse(excludes.compactMap(IPRange.init).contains { $0.overlaps(IPRange("192.168.1.1")!) })
    }
}
