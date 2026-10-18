import XCTest
@testable import XrayClient

/// Covers the sing-box profile: the outbound graph, per-process rules, the
/// rule-sets that replaced `geosite:`/`geoip:`, and the resolver.
///
/// Where the bundled `sing-box` binary is available the rendered JSON is also
/// handed to `sing-box check`, because a config that "looks right" and a config
/// the core will actually load are two different things — the previous builder
/// silently emitted fields that 1.12 had already removed.
final class SingBoxProfileTests: XCTestCase {

    // MARK: - Fixtures

    private func reality(_ name: String) -> ProxyConfig {
        var cfg = ProxyConfig(name: name, proto: .vless, address: "1.2.3.4", port: 443)
        cfg.uuid = "11111111-2222-3333-4444-555555555555"
        cfg.flow = "xtls-rprx-vision"
        cfg.security = .reality
        cfg.sni = "www.microsoft.com"
        cfg.fingerprint = "chrome"
        cfg.publicKey = "xr0PXbLQvB0qCLLm7d5MO_9y2Bqk5DoMHKcVAKTZ1UA"
        cfg.shortId = "0123abcd"
        return cfg
    }

    private func hysteria(_ name: String) -> ProxyConfig {
        var cfg = ProxyConfig(name: name, proto: .hysteria2, address: "5.6.7.8", port: 8443)
        cfg.password = "secret"
        cfg.sni = "example.org"
        return cfg
    }

    private func xhttp(_ name: String) -> ProxyConfig {
        var cfg = ProxyConfig(name: name, proto: .vless, address: "9.9.9.9", port: 443)
        cfg.uuid = "22222222-3333-4444-5555-666666666666"
        cfg.network = .xhttp
        cfg.security = .tls
        cfg.sni = "cdn.example.com"
        return cfg
    }

    // MARK: - Outbound graph

    func testEachReferencedServerBecomesItsOwnOutbound() {
        let de = reality("DE")
        let jp = hysteria("JP")
        var profile = SingBoxProfile()
        profile.servers = [de, jp]
        profile.defaultTarget = .server(de.id)
        profile.rules = [
            RoutingRule(name: "Torrent via JP", target: .server(jp.id),
                        processNames: ["Transmission"])
        ]

        let config = SingBoxProfileBuilder.build(profile)
        let tags = (config["outbounds"] as! [[String: Any]]).map { $0["tag"] as! String }

        XCTAssertTrue(tags.contains(ProfileTags.server(de.id)))
        XCTAssertTrue(tags.contains(ProfileTags.server(jp.id)))
        XCTAssertTrue(tags.contains(ProfileTags.defaultSelector))
        XCTAssertTrue(tags.contains(ProfileTags.direct))
        XCTAssertTrue(tags.contains(ProfileTags.block))
    }

    func testUnreferencedServersAreDropped() {
        let used = reality("Used")
        let unused = reality("Unused")
        var profile = SingBoxProfile()
        profile.servers = [used, unused]
        profile.defaultTarget = .server(used.id)

        let tags = (SingBoxProfileBuilder.build(profile)["outbounds"] as! [[String: Any]])
            .map { $0["tag"] as! String }
        XCTAssertTrue(tags.contains(ProfileTags.server(used.id)))
        XCTAssertFalse(tags.contains(ProfileTags.server(unused.id)))
    }

    func testDefaultSelectorPointsAtThePickedServer() {
        let de = reality("DE")
        var profile = SingBoxProfile()
        profile.servers = [de]
        profile.defaultTarget = .server(de.id)

        let outbounds = SingBoxProfileBuilder.build(profile)["outbounds"] as! [[String: Any]]
        let selector = outbounds.first { $0["tag"] as? String == ProfileTags.defaultSelector }
        XCTAssertEqual(selector?["default"] as? String, ProfileTags.server(de.id))
    }

    func testGroupBecomesSelectorOverItsMembers() {
        let a = reality("A")
        let b = reality("B")
        let group = ServerGroup(name: "EU", kind: .urltest, memberIDs: [a.id, b.id])
        var profile = SingBoxProfile()
        profile.servers = [a, b]
        profile.groups = [group]
        profile.defaultTarget = .group(group.id)

        let outbounds = SingBoxProfileBuilder.build(profile)["outbounds"] as! [[String: Any]]
        let rendered = outbounds.first { $0["tag"] as? String == group.tag }
        XCTAssertEqual(rendered?["type"] as? String, "urltest")
        XCTAssertEqual(rendered?["outbounds"] as? [String],
                       [ProfileTags.server(a.id), ProfileTags.server(b.id)])
    }

    // MARK: - Xray bridge

    func testXhttpNodeIsFrontedByALocalSocksHop() {
        let node = xhttp("XHTTP")
        XCTAssertTrue(SingBoxOutbound.needsXrayBridge(node))

        var profile = SingBoxProfile()
        profile.servers = [node]
        profile.defaultTarget = .server(node.id)
        profile.bridgePorts = [node.id: 11800]

        let outbounds = SingBoxProfileBuilder.build(profile)["outbounds"] as! [[String: Any]]
        let bridged = outbounds.first { $0["tag"] as? String == ProfileTags.server(node.id) }
        XCTAssertEqual(bridged?["type"] as? String, "socks")
        XCTAssertEqual(bridged?["server_port"] as? Int, 11800)
    }

    func testPostQuantumVlessNeedsTheBridge() {
        var cfg = reality("PQ")
        cfg.encryption = "mlkem768x25519plus.native.0rtt.abcdef"
        XCTAssertTrue(SingBoxOutbound.needsXrayBridge(cfg))
    }

    func testPlainVlessDoesNotNeedTheBridge() {
        var cfg = reality("Plain")
        cfg.encryption = "none"
        XCTAssertFalse(SingBoxOutbound.needsXrayBridge(cfg))
    }

    // MARK: - Rules

    func testProcessRuleRendersProcessName() {
        let rule = RoutingRule(name: "Telegram", target: .direct,
                               processNames: ["Telegram"])
        let rendered = SingBoxProfileBuilder.routeRule(rule)
        XCTAssertEqual(rendered?["process_name"] as? [String], ["Telegram"])
        XCTAssertEqual(rendered?["outbound"] as? String, ProfileTags.direct)
    }

    func testGeositeBecomesARuleSetInsteadOfBeingDropped() {
        let rule = RoutingRule(name: "CN", target: .direct, domains: ["geosite:cn"])
        let rendered = SingBoxProfileBuilder.routeRule(rule)
        XCTAssertEqual(rendered?["rule_set"] as? [String], ["geosite-cn"])

        let sets = RuleSetCatalog.derive(from: [rule])
        XCTAssertEqual(sets.count, 1)
        XCTAssertEqual(sets[0].tag, "geosite-cn")
        XCTAssertTrue((sets[0].url).hasSuffix("geosite-cn.srs"))
    }

    func testGeoipPrivateUsesTheNativeMatcher() {
        let rule = RoutingRule(name: "LAN", target: .direct, ips: ["geoip:private"])
        let rendered = SingBoxProfileBuilder.routeRule(rule)
        XCTAssertEqual(rendered?["ip_is_private"] as? Bool, true)
        XCTAssertTrue(RuleSetCatalog.derive(from: [rule]).isEmpty)
    }

    func testBareDomainMatchesTheApexAndItsSubdomains() {
        let rule = RoutingRule(name: "X", target: .proxy, domains: ["example.com"])
        let rendered = SingBoxProfileBuilder.routeRule(rule)
        XCTAssertEqual(rendered?["domain"] as? [String], ["example.com"])
        XCTAssertEqual(rendered?["domain_suffix"] as? [String], [".example.com"])
    }

    func testPortsAndRangesAreSplit() {
        var rule = RoutingRule(name: "P", target: .block)
        rule.port = "443, 1000-2000, 80"
        let rendered = SingBoxProfileBuilder.routeRule(rule)
        XCTAssertEqual(rendered?["port"] as? [Int], [443, 80])
        // sing-box 1.14 only takes "a:b" ranges; "1000-2000" fails `check`.
        XCTAssertEqual(rendered?["port_range"] as? [String], ["1000:2000"])
    }

    func testPortRangesAcceptBothSeparatorsAndOpenEnds() {
        let parsed = MatcherSyntax.ports("1000-2000, 3000:4000, :1024, 50000:")
        XCTAssertEqual(parsed.ports, [])
        XCTAssertEqual(parsed.ranges, ["1000:2000", "3000:4000", ":1024", "50000:"])
    }

    func testInvalidPortEntriesAreDropped() {
        let parsed = MatcherSyntax.ports("0, 443, 70000, http, 2000-1000, 10-99999, -, :, 5-x, 8080")
        XCTAssertEqual(parsed.ports, [443, 8080])
        XCTAssertEqual(parsed.ranges, [])
    }

    func testRuleWithNoMatcherIsDropped() {
        let rule = RoutingRule(name: "empty", target: .block)
        XCTAssertNil(SingBoxProfileBuilder.routeRule(rule))
    }

    func testProcessRuleIsNotEmittedForXray() {
        // Xray cannot match a process; widening the rule to "everything" would
        // be worse than dropping it.
        let rule = RoutingRule(name: "Telegram", target: .direct,
                               processNames: ["Telegram"])
        XCTAssertNil(rule.xrayRule())
    }

    // MARK: - TUN + loop guard

    func testTunInboundIsAddedWithLoopGuardAndDnsHijack() {
        let de = reality("DE")
        var profile = SingBoxProfile()
        profile.servers = [de]
        profile.defaultTarget = .server(de.id)
        profile.tun = TunInboundSettings()

        let config = SingBoxProfileBuilder.build(profile)
        let inbounds = config["inbounds"] as! [[String: Any]]
        XCTAssertTrue(inbounds.contains { $0["type"] as? String == "tun" })

        let route = config["route"] as! [String: Any]
        let rules = route["rules"] as! [[String: Any]]
        XCTAssertTrue(rules.contains { $0["action"] as? String == "hijack-dns" })
        let guardRule = rules.first { $0["process_name"] != nil }
        XCTAssertEqual(guardRule?["outbound"] as? String, ProfileTags.direct)
        XCTAssertTrue((guardRule?["process_name"] as? [String] ?? []).contains("Veil"))
    }

    /// The pinned core defaults to `mixed`, whose system TCP half drops every
    /// SYN on macOS, so the tunnel has to name its stack.
    func testTunInboundPinsTheGvisorStack() {
        let de = reality("DE")
        var profile = SingBoxProfile()
        profile.servers = [de]
        profile.defaultTarget = .server(de.id)
        profile.tun = TunInboundSettings()

        let config = SingBoxProfileBuilder.build(profile)
        let inbounds = config["inbounds"] as! [[String: Any]]
        let tun = inbounds.first { $0["type"] as? String == "tun" }
        XCTAssertEqual(tun?["stack"] as? String, "gvisor")
    }

    /// "Automatic" in Settings is the empty string and must not reach the core
    /// as one, or the default above is lost the moment a profile is assembled.
    func testAutomaticStackAssemblesAsGvisorAndAChoiceSurvives() {
        let de = reality("DE")
        var input = ProfileAssembler.Input()
        input.servers = [de]
        input.activeServerID = de.id
        input.includeTun = true

        input.settings.tunStack = ""
        XCTAssertEqual(ProfileAssembler.profile(input).tun?.stack, "gvisor")

        input.settings.tunStack = "system"
        XCTAssertEqual(ProfileAssembler.profile(input).tun?.stack, "system")
    }

    func testNoTunMeansNoDnsHijack() {
        let de = reality("DE")
        var profile = SingBoxProfile()
        profile.servers = [de]
        profile.defaultTarget = .server(de.id)

        let route = SingBoxProfileBuilder.build(profile)["route"] as! [String: Any]
        let rules = route["rules"] as! [[String: Any]]
        XCTAssertFalse(rules.contains { $0["action"] as? String == "hijack-dns" })
    }

    // MARK: - DNS

    func testResolverEmitsTypedServersAndABootstrap() {
        let de = reality("DE")
        var profile = SingBoxProfile()
        profile.servers = [de]
        profile.defaultTarget = .server(de.id)

        let config = SingBoxProfileBuilder.build(profile)
        let dns = config["dns"] as! [String: Any]
        let servers = dns["servers"] as! [[String: Any]]
        // 1.12 replaced the "address" string with a typed object.
        XCTAssertTrue(servers.allSatisfy { $0["type"] != nil })
        XCTAssertNil(servers.first { $0["address"] != nil })

        let route = config["route"] as! [String: Any]
        XCTAssertEqual(route["default_domain_resolver"] as? String,
                       DNSSettings.Builtin.bootstrap)

        // A `direct` detour is dropped (sing-box 1.12+ rejects it against an
        // empty direct outbound); a proxy detour is kept.
        let byTag = Dictionary(uniqueKeysWithValues:
            servers.compactMap { ($0["tag"] as? String, $0) })
        XCTAssertNil(byTag[DNSSettings.Builtin.bootstrap]?["detour"])
        XCTAssertEqual(byTag[DNSSettings.Builtin.remote]?["detour"] as? String,
                       ProfileTags.defaultSelector)
    }

    // MARK: - Backward compatibility

    func testLegacyRuleWithOutboundKeyStillDecodes() throws {
        let json = """
        {"id":"33333333-3333-3333-3333-333333333333","name":"old",
         "outbound":"block","domains":["ads.example"],"ips":[],"port":"",
         "enabled":true}
        """.data(using: .utf8)!
        let rule = try JSONDecoder().decode(RoutingRule.self, from: json)
        XCTAssertEqual(rule.target, .block)
        XCTAssertEqual(rule.domains, ["ads.example"])
    }

    func testTargetRoundTripsThroughCoding() throws {
        let id = UUID()
        for target in [RuleTarget.proxy, .direct, .block, .server(id), .group(id)] {
            var rule = RoutingRule(name: "r", target: target, domains: ["a.example"])
            rule.processNames = ["App"]
            let data = try JSONEncoder().encode(rule)
            let decoded = try JSONDecoder().decode(RoutingRule.self, from: data)
            XCTAssertEqual(decoded.target, target)
            XCTAssertEqual(decoded.processNames, ["App"])
        }
    }

    // MARK: - The core has the final word

    func testGeneratedProfilePassesSingBoxCheck() throws {
        guard let binary = Self.singBoxBinary else {
            throw XCTSkip("sing-box binary not present — run Scripts/fetch-singbox.sh")
        }
        let de = reality("DE")
        let jp = hysteria("JP")
        let bridged = xhttp("XHTTP")
        let group = ServerGroup(name: "EU", kind: .urltest, memberIDs: [de.id, jp.id])

        var profile = SingBoxProfile()
        profile.servers = [de, jp, bridged]
        profile.groups = [group]
        profile.defaultTarget = .group(group.id)
        profile.bridgePorts = [bridged.id: 11800]
        profile.tun = TunInboundSettings()
        profile.rules = [
            RoutingRule(name: "Telegram via JP", target: .server(jp.id),
                        processNames: ["Telegram"]),
            RoutingRule(name: "Work via XHTTP", target: .server(bridged.id),
                        domains: ["corp.example.com"],
                        processPaths: ["/Applications/Slack.app/Contents/MacOS/Slack"]),
            RoutingRule(name: "CN direct", target: .direct,
                        domains: ["geosite:cn"], ips: ["geoip:cn", "geoip:private"]),
            RoutingRule(name: "Ads blocked", target: .block,
                        domains: ["geosite:category-ads-all"])
        ]
        profile.dns.fakeIPEnabled = false

        try assertCoreAccepts(profile, binary: binary)
    }

    func testProxyOnlyProfilePassesSingBoxCheck() throws {
        guard let binary = Self.singBoxBinary else {
            throw XCTSkip("sing-box binary not present — run Scripts/fetch-singbox.sh")
        }
        var profile = SingBoxProfile()
        let node = reality("DE")
        profile.servers = [node]
        profile.defaultTarget = .server(node.id)
        profile.rules = RoutingPreset.bypassLAN.builtInRules(blockAds: true)
        try assertCoreAccepts(profile, binary: binary)
    }

    func testProfileWithPortRangesPassesSingBoxCheck() throws {
        guard let binary = Self.singBoxBinary else {
            throw XCTSkip("sing-box binary not present — run Scripts/fetch-singbox.sh")
        }
        var profile = SingBoxProfile()
        let node = reality("DE")
        profile.servers = [node]
        profile.defaultTarget = .server(node.id)
        var destination = RoutingRule(name: "Games direct", target: .direct)
        destination.port = "443, 1000-2000, 3000:4000, :1024"
        var source = RoutingRule(name: "Local ports", target: .direct)
        source.direction = .source
        source.port = "50000-60000"
        profile.rules = [destination, source]
        try assertCoreAccepts(profile, binary: binary)
    }

    func testFakeIPProfilePassesSingBoxCheck() throws {
        guard let binary = Self.singBoxBinary else {
            throw XCTSkip("sing-box binary not present — run Scripts/fetch-singbox.sh")
        }
        var profile = SingBoxProfile()
        let node = reality("DE")
        profile.servers = [node]
        profile.defaultTarget = .server(node.id)
        profile.tun = TunInboundSettings()
        profile.dns.fakeIPEnabled = true
        try assertCoreAccepts(profile, binary: binary)
    }

    // MARK: - Helpers

    /// Path to the bundled core, found by walking up from this source file to
    /// the package root — the test bundle does not carry the binary.
    private static var singBoxBinary: String? {
        var dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // XrayClientTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // package root
        let candidate = dir.appendingPathComponent("Sources/XrayClient/Resources/sing-box")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate.path
        }
        dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fallback = dir.appendingPathComponent("Sources/XrayClient/Resources/sing-box")
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback.path : nil
    }

    private func assertCoreAccepts(_ profile: SingBoxProfile, binary: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws {
        let data = try SingBoxProfileBuilder.jsonData(profile)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("veil-profile-\(UUID().uuidString).json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["check", "-c", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: output, encoding: .utf8) ?? "(no output)"
            XCTFail("sing-box rejected the config: \(message)", file: file, line: line)
        }
    }
}

/// sing-box colours its log unconditionally, so the app strips the escapes on
/// the way into a window that cannot render them.
final class LogSanitizeTests: XCTestCase {

    func testColourCodesAreStripped() {
        let line = "+0400 2026-09-19 02:11:00 \u{1B}[31mERROR\u{1B}[0m inbound/http: EOF\n"
        XCTAssertEqual(ConnectionManager.withoutANSI(line),
                       "+0400 2026-09-19 02:11:00 ERROR inbound/http: EOF\n")
    }

    func testPlainTextIsUntouched() {
        let line = "[info] tunnel up\n"
        XCTAssertEqual(ConnectionManager.withoutANSI(line), line)
    }

    func testATruncatedEscapeDoesNotEatTheRestOfTheLine() {
        XCTAssertEqual(ConnectionManager.withoutANSI("done\u{1B}"), "done")
        XCTAssertEqual(ConnectionManager.withoutANSI("a\u{1B}b"), "ab")
    }
}

/// The DNS section is the part of the configuration a user can most easily
/// leave in a state the core refuses to start on, so it is repaired on the way
/// out rather than being handed over as typed.
final class DNSSanitizeTests: XCTestCase {

    func testBootstrapWithNoAddressIsRepairedRatherThanDropped() {
        var dns = DNSSettings()
        // What the editor leaves behind when the bootstrap row is half-filled:
        // a transport that needs an address, no address, and a detour through
        // the very tunnel this resolver is supposed to help build.
        dns.servers = [
            DNSServerEntry(tag: DNSSettings.Builtin.remote, kind: .https,
                           server: "1.1.1.1", path: "/dns-query",
                           detour: ProfileTags.defaultSelector),
            DNSServerEntry(tag: DNSSettings.Builtin.bootstrap, kind: .tcp,
                           server: "", detour: "srv-abc")
        ]

        let fixed = dns.sanitized()
        let bootstrap = fixed.servers.first { $0.tag == DNSSettings.Builtin.bootstrap }
        XCTAssertNotNil(bootstrap)
        XCTAssertFalse(bootstrap!.server.isEmpty)
        XCTAssertEqual(bootstrap!.detour, ProfileTags.direct)
    }

    func testAResolverWithNoAddressIsDropped() {
        var dns = DNSSettings()
        dns.servers.append(DNSServerEntry(tag: "half-typed", kind: .tls, server: ""))
        XCTAssertFalse(dns.sanitized().servers.contains { $0.tag == "half-typed" })
    }

    func testRulesPointingAtAMissingServerAreDropped() {
        var dns = DNSSettings()
        dns.rules = [DNSRule(name: "gone", serverTag: "no-such-server",
                             domains: ["example.com"])]
        XCTAssertTrue(dns.sanitized().rules.isEmpty)
    }

    func testTheBootstrapResolverIsNeverTheFinalOne() {
        var dns = DNSSettings()
        // Picking the bootstrap entry as the catch-all is the one choice the
        // editor used to allow that quietly sends every lookup around the
        // tunnel: that resolver is pinned to `direct`.
        dns.finalTag = DNSSettings.Builtin.bootstrap

        let fixed = dns.sanitized()
        XCTAssertNotEqual(fixed.finalTag, DNSSettings.Builtin.bootstrap)
        XCTAssertEqual(fixed.finalTag, DNSSettings.Builtin.remote)
    }

    func testAnEmptyFinalTagIsNotLeftPointingAtTheBootstrapResolver() {
        var dns = DNSSettings()
        // Empty means "the first server", so ordering alone can put the
        // bootstrap resolver in the catch-all seat.
        dns.servers = [
            DNSServerEntry(tag: DNSSettings.Builtin.bootstrap, kind: .udp,
                           server: "1.1.1.1", detour: ProfileTags.direct),
            DNSServerEntry(tag: DNSSettings.Builtin.remote, kind: .https,
                           server: "1.1.1.1", path: "/dns-query",
                           detour: ProfileTags.defaultSelector)
        ]
        dns.finalTag = ""

        XCTAssertEqual(dns.sanitized().finalTag, DNSSettings.Builtin.remote)
    }

    func testTheRenderedResolverSendsUnmatchedQueriesThroughTheProxy() {
        var profile = SingBoxProfile()
        var dns = DNSSettings()
        dns.finalTag = DNSSettings.Builtin.bootstrap
        profile.dns = dns.sanitized()

        let config = SingBoxProfileBuilder.build(profile)
        let rendered = config["dns"] as! [String: Any]
        let servers = rendered["servers"] as! [[String: Any]]
        let final = rendered["final"] as! String
        let catchAll = servers.first { $0["tag"] as? String == final }

        XCTAssertNotNil(catchAll)
        XCTAssertEqual(catchAll?["detour"] as? String, ProfileTags.defaultSelector)
    }

    func testTheBootstrapTagAlwaysResolvesAfterSanitizing() {
        var dns = DNSSettings()
        dns.servers.removeAll { $0.tag == DNSSettings.Builtin.bootstrap }
        let fixed = dns.sanitized()
        XCTAssertTrue(fixed.servers.contains { $0.tag == fixed.bootstrapTag })
    }
}
