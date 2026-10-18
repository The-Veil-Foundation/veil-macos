import XCTest
@testable import XrayClient

/// The iOS build runs the whole outbound graph on Xray alone. These pin down
/// what that graph looks like — a node per outbound, a balancer per "fastest"
/// group, rules that reach the node they name — and that the real core accepts
/// it, since a config Xray refuses is a tunnel that never comes up.
final class XrayProfileTests: XCTestCase {

    // MARK: - Fixtures

    private func vless(_ name: String, _ address: String = "1.2.3.4") -> ProxyConfig {
        var cfg = ProxyConfig(name: name, proto: .vless, address: address, port: 443)
        cfg.uuid = "11111111-2222-3333-4444-555555555555"
        cfg.flow = "xtls-rprx-vision"
        cfg.security = .reality
        cfg.sni = "www.microsoft.com"
        cfg.fingerprint = "chrome"
        cfg.publicKey = "xr0PXbLQvB0qCLLm7d5MO_9y2Bqk5DoMHKcVAKTZ1UA"
        cfg.shortId = "0123abcd"
        return cfg
    }

    private func wireguard(_ name: String) -> ProxyConfig {
        var wg = ProxyConfig(name: name, proto: .wireguard, address: "9.9.9.9", port: 51820)
        wg.privateKey = "cGl2YXRlLWtleS1ieXRlcy0wMTIzNDU2Nzg5YWJjZGU="
        wg.peerPublicKey = "cHVibGljLWtleS1ieXRlcy0wMTIzNDU2Nzg5YWJjZGU="
        wg.localAddresses = ["10.0.0.2/32"]
        wg.allowedIPs = ["172.16.4.0/24"]
        return wg
    }

    private func hysteria(_ name: String) -> ProxyConfig {
        var cfg = ProxyConfig(name: name, proto: .hysteria2, address: "5.5.5.5", port: 443)
        cfg.password = "secret"
        return cfg
    }

    private func outbounds(_ config: [String: Any]) -> [[String: Any]] {
        config["outbounds"] as? [[String: Any]] ?? []
    }

    private func outboundTags(_ config: [String: Any]) -> [String] {
        outbounds(config).compactMap { $0["tag"] as? String }
    }

    private func routing(_ config: [String: Any]) -> [String: Any] {
        config["routing"] as? [String: Any] ?? [:]
    }

    private func rules(_ config: [String: Any]) -> [[String: Any]] {
        routing(config)["rules"] as? [[String: Any]] ?? []
    }

    // MARK: - Selection

    func testASingleServerIsTheFinalRoute() throws {
        let node = vless("NL")
        var profile = XrayProfile()
        profile.servers = [node]
        profile.activeID = node.id
        let config = try XrayProfileBuilder.build(profile)

        XCTAssertEqual(outboundTags(config).first, ProfileTags.server(node.id))
        XCTAssertEqual(rules(config).last?["outboundTag"] as? String, ProfileTags.server(node.id))
    }

    func testNothingSelectedIsAnError() {
        var profile = XrayProfile()
        profile.servers = [vless("NL")]
        XCTAssertThrowsError(try XrayProfileBuilder.build(profile)) { error in
            XCTAssertEqual(error as? XrayProfileBuilder.BuildError, .nothingSelected)
        }
    }

    func testASingBoxOnlySelectionIsRefusedByName() {
        let node = hysteria("HY")
        var profile = XrayProfile()
        profile.servers = [node]
        profile.activeID = node.id
        XCTAssertThrowsError(try XrayProfileBuilder.build(profile)) { error in
            XCTAssertEqual(error as? XrayProfileBuilder.BuildError, .unsupported("HY"))
        }
    }

    /// Only what something names is built: a list of two hundred nodes must
    /// not become two hundred outbounds inside a 50 MB extension.
    func testUnreferencedServersAreNotBuilt() throws {
        let used = vless("NL")
        let idle = vless("DE", "2.2.2.2")
        var profile = XrayProfile()
        profile.servers = [used, idle]
        profile.activeID = used.id
        let tags = outboundTags(try XrayProfileBuilder.build(profile))
        XCTAssertFalse(tags.contains(ProfileTags.server(idle.id)))
    }

    // MARK: - Groups

    func testAFastestGroupIsALeastPingBalancerWithAnObservatory() throws {
        let a = vless("NL-1", "1.1.1.2"), b = vless("NL-2", "1.1.1.3")
        var group = ServerGroup(name: "NL", kind: .urltest, memberIDs: [a.id, b.id])
        group.testURL = "https://cp.cloudflare.com"
        group.interval = "2m"
        var profile = XrayProfile()
        profile.servers = [a, b]
        profile.groups = [group]
        profile.activeID = group.id
        let config = try XrayProfileBuilder.build(profile)

        let balancers = routing(config)["balancers"] as? [[String: Any]] ?? []
        XCTAssertEqual(balancers.count, 1)
        XCTAssertEqual(balancers[0]["tag"] as? String, ProfileTags.group(group.id))
        XCTAssertEqual(balancers[0]["selector"] as? [String],
                       [ProfileTags.server(a.id), ProfileTags.server(b.id)])
        XCTAssertEqual((balancers[0]["strategy"] as? [String: Any])?["type"] as? String, "leastPing")
        XCTAssertEqual(balancers[0]["fallbackTag"] as? String, ProfileTags.server(a.id))
        XCTAssertEqual(rules(config).last?["balancerTag"] as? String, ProfileTags.group(group.id))

        let observatory = config["observatory"] as? [String: Any]
        XCTAssertEqual(observatory?["probeURL"] as? String, "https://cp.cloudflare.com")
        XCTAssertEqual(observatory?["probeInterval"] as? String, "2m")
        XCTAssertEqual(observatory?["subjectSelector"] as? [String],
                       [ProfileTags.server(a.id), ProfileTags.server(b.id)])
    }

    /// Xray has no runtime selector, so a manual group is the member it points
    /// at.
    func testAManualGroupRoutesToItsPickedMember() throws {
        let a = vless("A"), b = vless("B", "2.2.2.2")
        var group = ServerGroup(name: "Pick", kind: .selector, memberIDs: [a.id, b.id])
        group.selectedID = b.id
        var profile = XrayProfile()
        profile.servers = [a, b]
        profile.groups = [group]
        profile.activeID = group.id
        let config = try XrayProfileBuilder.build(profile)

        XCTAssertNil(routing(config)["balancers"])
        XCTAssertEqual(rules(config).last?["outboundTag"] as? String, ProfileTags.server(b.id))
        XCTAssertFalse(outboundTags(config).contains(ProfileTags.server(a.id)))
    }

    func testAGroupSkipsMembersXrayCannotRun() throws {
        let a = vless("A"), hy = hysteria("HY")
        let group = ServerGroup(name: "Mixed", kind: .urltest, memberIDs: [hy.id, a.id])
        var profile = XrayProfile()
        profile.servers = [a, hy]
        profile.groups = [group]
        profile.activeID = group.id
        let config = try XrayProfileBuilder.build(profile)

        // One runnable member left: a plain outbound, no balancer.
        XCTAssertNil(routing(config)["balancers"])
        XCTAssertEqual(rules(config).last?["outboundTag"] as? String, ProfileTags.server(a.id))
    }

    /// A subscription's balancer arrives as one entry with alternates; picking
    /// it means picking the group over all of them.
    func testAPanelBalancerEntryBecomesABalancer() throws {
        var main = vless("NL")
        main.alternates = [vless("NL-2", "1.1.1.9")]
        var profile = XrayProfile()
        profile.servers = [main]
        profile.activeID = main.id
        let config = try XrayProfileBuilder.build(profile)

        let balancers = routing(config)["balancers"] as? [[String: Any]] ?? []
        XCTAssertEqual(balancers.first?["tag"] as? String, ProfileTags.group(main.id))
        XCTAssertEqual((balancers.first?["selector"] as? [String])?.count, 2)
    }

    // MARK: - Rules

    func testARuleNamingAServerBuildsAndReachesIt() throws {
        let active = vless("NL"), peer = wireguard("Home")
        var rule = RoutingRule(name: "Office", target: .server(peer.id), ips: ["172.16.4.10"])
        rule.enabled = true
        var profile = XrayProfile()
        profile.servers = [active, peer]
        profile.activeID = active.id
        profile.rules = [rule]
        let config = try XrayProfileBuilder.build(profile)

        XCTAssertTrue(outboundTags(config).contains(ProfileTags.server(peer.id)))
        let rendered = rules(config).first { ($0["ip"] as? [String]) == ["172.16.4.10"] }
        XCTAssertEqual(rendered?["outboundTag"] as? String, ProfileTags.server(peer.id))
    }

    func testARuleNamingAMissingServerFallsBackToTheDefault() throws {
        let active = vless("NL")
        let rule = RoutingRule(name: "Gone", target: .server(UUID()), domains: ["example.com"])
        var profile = XrayProfile()
        profile.servers = [active]
        profile.activeID = active.id
        profile.rules = [rule]
        let config = try XrayProfileBuilder.build(profile)

        let rendered = rules(config).first { ($0["domain"] as? [String]) != nil }
        XCTAssertEqual(rendered?["outboundTag"] as? String, ProfileTags.server(active.id))
    }

    func testBareDomainsMeanTheDomainAndItsSubdomains() {
        XCTAssertEqual(XrayProfileBuilder.xrayDomains(["example.com", ".ru", "full:a.b",
                                                       "keyword:google", "geosite:cn"],
                                                      hasGeoAssets: true),
                       ["domain:example.com", "domain:ru", "full:a.b",
                        "keyword:google", "geosite:cn"])
    }

    /// Without the database a `geosite:` rule cannot load, and the rule must
    /// go rather than turn into a rule about nothing — or about everything.
    func testGeoMatchersAreDroppedWithoutTheDatabase() throws {
        let active = vless("NL")
        let geo = RoutingRule(name: "CN", target: .direct, domains: ["geosite:cn"])
        var mixed = RoutingRule(name: "Mixed", target: .direct, ips: ["geoip:cn"])
        mixed.port = "443"
        var profile = XrayProfile()
        profile.servers = [active]
        profile.activeID = active.id
        profile.rules = [geo, mixed]
        profile.hasGeoAssets = false
        let config = try XrayProfileBuilder.build(profile)

        XCTAssertNil(rules(config).first { $0["ruleTag"] as? String == "CN" })
        XCTAssertNil(rules(config).first { $0["ruleTag"] as? String == "Mixed" },
                     "a rule that lost its address matcher must not survive as a port rule")
    }

    func testRulesXrayCannotExpressAreLeftOut() throws {
        let active = vless("NL")
        var app = RoutingRule(name: "App", target: .direct)
        app.processNames = ["Telegram"]
        var inverted = RoutingRule(name: "Inv", target: .direct, domains: ["a.com"])
        inverted.invert = true
        var dnsOnly = RoutingRule(name: "Sniff", target: .block)
        dnsOnly.protocols = ["dns"]
        var profile = XrayProfile()
        profile.servers = [active]
        profile.activeID = active.id
        profile.rules = [app, inverted, dnsOnly]
        let config = try XrayProfileBuilder.build(profile)
        let names = rules(config).compactMap { $0["ruleTag"] as? String }
        XCTAssertTrue(names.isEmpty, "unexpected rules: \(names)")
    }

    // MARK: - DNS

    func testDNSDefaultsResolveThroughTheTunnel() throws {
        let active = vless("NL")
        var profile = XrayProfile()
        profile.servers = [active]
        profile.activeID = active.id
        let config = try XrayProfileBuilder.build(profile)

        let dns = config["dns"] as? [String: Any]
        let servers = dns?["servers"] as? [[String: Any]] ?? []
        let remote = servers.first { ($0["address"] as? String)?.hasPrefix("https://") == true }
        XCTAssertEqual(remote?["address"] as? String, "https://1.1.1.1/dns-query")
        // The remote resolver's queries ride the default route.
        let tag = remote?["tag"] as? String
        let detour = rules(config).first { ($0["inboundTag"] as? [String]) == [tag ?? ""] }
        XCTAssertEqual(detour?["outboundTag"] as? String, ProfileTags.server(active.id))
        // Port 53 is answered by the core.
        XCTAssertTrue(rules(config).contains { $0["outboundTag"] as? String == ProfileTags.dnsOut })
        XCTAssertTrue(outboundTags(config).contains(ProfileTags.dnsOut))
        // The bootstrap resolver has no place in Xray's block.
        XCTAssertFalse(servers.contains { ($0["tag"] as? String) == "dns-dns-bootstrap" })
    }

    func testDNSOffLeavesTheSystemQueriesAlone() throws {
        let active = vless("NL")
        var profile = XrayProfile()
        profile.servers = [active]
        profile.activeID = active.id
        profile.dns.enabled = false
        let config = try XrayProfileBuilder.build(profile)
        XCTAssertNil(config["dns"])
        XCTAssertFalse(outboundTags(config).contains(ProfileTags.dnsOut))
    }

    func testFakeIPAddsThePoolAndSniffing() throws {
        let active = vless("NL")
        var profile = XrayProfile()
        profile.servers = [active]
        profile.activeID = active.id
        profile.dns.fakeIPEnabled = true
        let config = try XrayProfileBuilder.build(profile)

        XCTAssertNotNil(config["fakedns"])
        let servers = (config["dns"] as? [String: Any])?["servers"] as? [[String: Any]] ?? []
        let firstUnscoped = servers.first { $0["domains"] == nil }
        XCTAssertEqual(firstUnscoped?["address"] as? String, "fakedns")
        let inbound = (config["inbounds"] as? [[String: Any]])?.first
        let sniff = (inbound?["sniffing"] as? [String: Any])?["destOverride"] as? [String]
        XCTAssertTrue(sniff?.contains("fakedns") == true)
    }

    // MARK: - The real core

    /// Every shape above, put together and handed to the Xray binary in the
    /// same fd mode the iOS extension uses.
    func testTheRealCoreAcceptsAFullProfile() throws {
        let binary = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/XrayClient/Resources/xray")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path),
                          "xray is not fetched in this checkout")

        let a = vless("A", "1.1.1.2"), b = vless("B", "1.1.1.3"), peer = wireguard("Home")
        let fastest = ServerGroup(name: "Fast", kind: .urltest, memberIDs: [a.id, b.id])
        var profile = XrayProfile()
        profile.servers = [a, b, peer]
        profile.groups = [fastest]
        profile.activeID = fastest.id
        profile.rules = [
            RoutingRule(name: "LAN", target: .direct, ips: RoutingPreset.privateCIDRs),
            RoutingRule(name: "Office", target: .server(peer.id), ips: ["172.16.4.0/24"]),
            RoutingRule(name: "Ads", target: .block, domains: ["doubleclick.net"]),
            RoutingRule(name: "Via B", target: .server(b.id), domains: ["example.org"])
        ]
        profile.dns.fakeIPEnabled = true
        profile.hasGeoAssets = false
        profile.logFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("veil-xray-test.log").path

        let json = try XrayProfileBuilder.jsonString(profile)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("veil-xray-profile-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-test", "-config", file.path]
        var environment = ProcessInfo.processInfo.environment
        environment["XRAY_TUN_FD"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, output)
    }
}
