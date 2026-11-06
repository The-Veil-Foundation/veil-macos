import XCTest
@testable import XrayClient

/// The response-header contract panels speak, and the body formats they send.
final class RemnawaveHeaderTests: XCTestCase {

    func testHeaderNamesAreCaseInsensitive() {
        let meta = RemnawaveHeaders.parse(lowercased: [
            "profile-title": "My Panel",
            "subscription-userinfo": "upload=1; download=2; total=3; expire=1700000000",
        ])
        XCTAssertEqual(meta.profileTitle, "My Panel")
        XCTAssertEqual(meta.userinfo?.upload, 1)
        XCTAssertEqual(meta.userinfo?.total, 3)
    }

    func testMixedCaseHeadersFromURLResponse() {
        let meta = RemnawaveHeaders.parse(["Profile-Title": "Mixed", "X-HWID-Active": "true"])
        XCTAssertEqual(meta.profileTitle, "Mixed")
        XCTAssertEqual(meta.hwidStatus, .active)
    }

    func testBase64Titles() {
        let encoded = Data("Тариф Pro".utf8).base64EncodedString()
        let meta = RemnawaveHeaders.parse(lowercased: ["profile-title": "base64:" + encoded])
        XCTAssertEqual(meta.profileTitle, "Тариф Pro")
    }

    func testHWIDRefusalOutranksActive() {
        let meta = RemnawaveHeaders.parse(lowercased: [
            "x-hwid-active": "true",
            "x-hwid-max-devices-reached": "true",
        ])
        XCTAssertEqual(meta.hwidStatus, .maxDevicesReached)
        XCTAssertTrue(meta.needsUserAction)
    }

    func testHWIDNotSupported() {
        let meta = RemnawaveHeaders.parse(lowercased: ["x-hwid-not-supported": "1"])
        XCTAssertEqual(meta.hwidStatus, .notSupported)
    }

    func testExplicitlyFalseFlagIsNotSet() {
        let meta = RemnawaveHeaders.parse(lowercased: ["x-hwid-active": "false"])
        XCTAssertEqual(meta.hwidStatus, .unknown)
    }

    func testUpdateIntervalUnits() {
        XCTAssertEqual(RemnawaveHeaders.updateInterval("30m"), 30)
        XCTAssertEqual(RemnawaveHeaders.updateInterval("6h"), 360)
        XCTAssertEqual(RemnawaveHeaders.updateInterval("2d"), 2880)
        // A bare small number is days, the way Remnawave documents it.
        XCTAssertEqual(RemnawaveHeaders.updateInterval("1"), 1440)
        // A bare large number is already minutes.
        XCTAssertEqual(RemnawaveHeaders.updateInterval("720"), 720)
        XCTAssertNil(RemnawaveHeaders.updateInterval(""))
        XCTAssertNil(RemnawaveHeaders.updateInterval("soon"))
    }

    func testUpdateIntervalHoursRoundsUpAndClamps() {
        var meta = SubscriptionMetadata()
        meta.updateIntervalMinutes = 30
        XCTAssertEqual(meta.updateIntervalHours, 1)
        meta.updateIntervalMinutes = 90
        XCTAssertEqual(meta.updateIntervalHours, 2)
        meta.updateIntervalMinutes = 60 * 24 * 400
        XCTAssertEqual(meta.updateIntervalHours, 24 * 7)
    }

    func testRefillDateFormats() {
        XCTAssertNotNil(RemnawaveHeaders.date("2026-01-31"))
        XCTAssertNotNil(RemnawaveHeaders.date("2026-01-31T12:00:00Z"))
        XCTAssertEqual(RemnawaveHeaders.date("1700000000"),
                       Date(timeIntervalSince1970: 1_700_000_000))
        // Milliseconds, as some panels send them.
        XCTAssertEqual(RemnawaveHeaders.date("1700000000000"),
                       Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(RemnawaveHeaders.date(""))
    }

    func testSupportAndPageLinks() {
        let meta = RemnawaveHeaders.parse(lowercased: [
            "support-url": "https://t.me/support",
            "profile-web-page-url": "https://panel.example.com/app",
        ])
        XCTAssertEqual(meta.supportURL, "https://t.me/support")
        XCTAssertEqual(meta.webPageURL, "https://panel.example.com/app")
    }

    func testPanelIntervalWinsOverTheAppSetting() {
        var sub = Subscription(name: "s", url: "https://example.com/sub")
        var meta = SubscriptionMetadata()
        meta.updateIntervalMinutes = 60 * 6
        sub.apply(meta)
        XCTAssertEqual(sub.refreshInterval(defaultHours: 12), 6 * 3600)

        var untold = Subscription(name: "s", url: "https://example.com/sub")
        untold.apply(SubscriptionMetadata())
        XCTAssertEqual(untold.refreshInterval(defaultHours: 12), 12 * 3600)
    }
}

/// Format recognition: the body has to be classified before it is parsed, or a
/// full config gets flattened into a node list and loses everything else.
final class SubscriptionPayloadTests: XCTestCase {

    private let xrayJSON = """
    {
      "log": {"loglevel": "warning"},
      "outbounds": [
        {
          "tag": "DE-01",
          "protocol": "vless",
          "settings": {"vnext": [{
            "address": "1.2.3.4", "port": 443,
            "users": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                       "flow": "xtls-rprx-vision", "encryption": "none"}]
          }]},
          "streamSettings": {
            "network": "tcp", "security": "reality",
            "realitySettings": {"serverName": "www.example.com",
                                "publicKey": "PUBKEY", "shortId": "ab",
                                "fingerprint": "chrome"}
          }
        },
        {"tag": "direct", "protocol": "freedom"}
      ],
      "routing": {"balancers": [{"tag": "all", "selector": ["DE"]}]}
    }
    """

    private let singboxJSON = """
    {
      "outbounds": [
        {"type": "hysteria2", "tag": "FI-01", "server": "5.6.7.8",
         "server_port": 8443, "password": "pw",
         "obfs": {"type": "salamander", "password": "op"},
         "tls": {"enabled": true, "server_name": "a.example.com", "insecure": false}},
        {"type": "selector", "tag": "auto", "outbounds": ["FI-01"]}
      ],
      "route": {"rules": []}
    }
    """

    func testXrayJSONIsRecognisedAndKept() {
        let payload = SubscriptionPayloadParser.parse(xrayJSON)
        XCTAssertEqual(payload.format, .xrayJSON)
        XCTAssertTrue(payload.format.isFullConfig)
        // The whole document survives: routing and balancers are still in there.
        XCTAssertNotNil(payload.configJSON)
        XCTAssertTrue(payload.configJSON?.contains("balancers") ?? false)
    }

    func testXrayOutboundsBecomeServers() {
        let payload = SubscriptionPayloadParser.parse(xrayJSON)
        XCTAssertEqual(payload.servers.count, 1, "freedom is not a server")
        let server = payload.servers.first
        XCTAssertEqual(server?.name, "DE-01")
        XCTAssertEqual(server?.proto, .vless)
        XCTAssertEqual(server?.address, "1.2.3.4")
        XCTAssertEqual(server?.port, 443)
        XCTAssertEqual(server?.security, .reality)
        XCTAssertEqual(server?.publicKey, "PUBKEY")
        XCTAssertEqual(server?.shortId, "ab")
        XCTAssertEqual(server?.sni, "www.example.com")
        XCTAssertEqual(server?.flow, "xtls-rprx-vision")
    }

    func testSingBoxIsToldApartFromXray() {
        let payload = SubscriptionPayloadParser.parse(singboxJSON)
        XCTAssertEqual(payload.format, .singbox)
        XCTAssertEqual(payload.servers.count, 1, "a selector is not a server")
        let server = payload.servers.first
        XCTAssertEqual(server?.proto, .hysteria2)
        XCTAssertEqual(server?.address, "5.6.7.8")
        XCTAssertEqual(server?.port, 8443)
        XCTAssertEqual(server?.obfs, "salamander")
        XCTAssertEqual(server?.obfsPassword, "op")
        XCTAssertEqual(server?.security, .tls)
        XCTAssertEqual(server?.sni, "a.example.com")
    }

    func testBase64WrappedConfigIsStillAConfig() {
        let wrapped = Data(xrayJSON.utf8).base64EncodedString()
        let payload = SubscriptionPayloadParser.parse(wrapped)
        XCTAssertEqual(payload.format, .xrayBase64)
        XCTAssertEqual(payload.servers.count, 1)
        XCTAssertNotNil(payload.configJSON)
    }

    func testMihomoYAMLIsRecognisedRatherThanMisparsed() {
        let yaml = """
        proxies:
          - {name: DE, type: vless, server: 1.2.3.4, port: 443}
        proxy-groups:
          - {name: auto, type: url-test, proxies: [DE]}
        rules:
          - MATCH,auto
        """
        let payload = SubscriptionPayloadParser.parse(yaml)
        XCTAssertEqual(payload.format, .mihomoYAML)
        XCTAssertTrue(payload.servers.isEmpty)
    }

    func testPlainAndBase64LinkLists() {
        let links = "vless://3F2504E0-4F89-11D3-9A0C-0305E82C3301@1.2.3.4:443?type=tcp#DE-01"
        XCTAssertEqual(SubscriptionPayloadParser.parse(links).format, .links)

        let wrapped = Data(links.utf8).base64EncodedString()
        XCTAssertEqual(SubscriptionPayloadParser.parse(wrapped).format, .base64Links)
    }

    func testRawBodyIsAlwaysPreserved() {
        let payload = SubscriptionPayloadParser.parse(xrayJSON)
        XCTAssertEqual(payload.raw, xrayJSON)
    }

    func testEmptyBody() {
        let payload = SubscriptionPayloadParser.parse("   \n ")
        XCTAssertEqual(payload.format, .unknown)
        XCTAssertTrue(payload.servers.isEmpty)
    }
}

/// The auto-update interval is chosen from a list rather than nudged one hour
/// at a time, so the list has to cover whatever is already stored.
final class AutoUpdateIntervalTests: XCTestCase {

    func testOffersUsefulIntervalsInOrder() {
        let choices = AppSettings.autoUpdateIntervalChoices(including: 12)
        XCTAssertEqual(choices, [1, 3, 6, 12, 24, 48, 168])
    }

    func testAStoredValueOffTheListIsKept() {
        // An interval set by an older build's stepper must not silently jump
        // to a neighbouring preset the moment Settings is opened.
        let choices = AppSettings.autoUpdateIntervalChoices(including: 7)
        XCTAssertTrue(choices.contains(7), "7 h was dropped: \(choices)")
        XCTAssertEqual(choices, choices.sorted())
        XCTAssertEqual(choices.count, Set(choices).count, "duplicated entry")
    }

    func testAStoredValueOnTheListIsNotDuplicated() {
        let choices = AppSettings.autoUpdateIntervalChoices(including: 24)
        XCTAssertEqual(choices.filter { $0 == 24 }.count, 1)
    }
}

/// Panels that answer with a whole core config declare their balancers in it.
/// Veil used to drop that and re-guess the grouping from node names, which is
/// only ever a fallback for share links — those carry no grouping at all.
final class SubscriptionGroupTests: XCTestCase {

    private func parse(_ body: String) -> SubscriptionPayload {
        SubscriptionPayloadParser.parse(body)
    }

    private func node(_ tag: String, _ address: String) -> String {
        """
        {"type": "vless", "tag": "\(tag)", "server": "\(address)",
         "server_port": 443, "uuid": "11111111-2222-3333-4444-555555555555"}
        """
    }

    func testSingBoxUrltestBecomesAGroupOverItsMembers() {
        let body = """
        {"outbounds": [
          \(node("nl-1", "1.1.1.1")),
          \(node("nl-2", "2.2.2.2")),
          {"type": "urltest", "tag": "NL", "outbounds": ["nl-1", "nl-2"],
           "interval": "2m", "tolerance": 100}
        ], "route": {"final": "NL"}}
        """
        let payload = parse(body)
        XCTAssertEqual(payload.format, .singbox)
        XCTAssertEqual(payload.servers.count, 2, "the urltest itself is not a node")

        XCTAssertEqual(payload.groups.count, 1)
        let group = payload.groups.first
        XCTAssertEqual(group?.name, "NL")
        XCTAssertEqual(group?.kind, .urltest)
        XCTAssertEqual(group?.interval, "2m")
        XCTAssertEqual(group?.tolerance, 100)
        XCTAssertEqual(group?.memberIDs, payload.servers.map(\.id),
                       "members resolve to the nodes named by their tags, in order")
    }

    func testSingBoxSelectorCarriesItsDefaultMember() {
        let body = """
        {"outbounds": [
          \(node("a", "1.1.1.1")),
          \(node("b", "2.2.2.2")),
          {"type": "selector", "tag": "Pick", "outbounds": ["a", "b"], "default": "b"}
        ], "route": {}}
        """
        let payload = parse(body)
        let group = payload.groups.first
        XCTAssertEqual(group?.kind, .selector)
        XCTAssertEqual(group?.selectedID, payload.servers.last?.id)
    }

    func testMembersThatAreNotNodesAreDropped() {
        // `direct` is a real sing-box outbound and a perfectly normal member of
        // a selector, but it is not something Veil can connect to.
        let body = """
        {"outbounds": [
          \(node("a", "1.1.1.1")),
          {"type": "direct", "tag": "direct"},
          {"type": "selector", "tag": "Pick", "outbounds": ["a", "direct"]}
        ], "route": {}}
        """
        let payload = parse(body)
        XCTAssertEqual(payload.groups.first?.memberIDs.count, 1)
    }

    func testEmptyGroupIsNotKept() {
        let body = """
        {"outbounds": [
          {"type": "direct", "tag": "direct"},
          {"type": "selector", "tag": "Pick", "outbounds": ["direct"]}
        ], "route": {}}
        """
        XCTAssertTrue(parse(body).groups.isEmpty,
                      "a group with nothing connectable in it is not a group")
    }

    func testXrayBalancerGroupsTheTagsItsSelectorMatches() {
        let body = """
        {"outbounds": [
          {"protocol": "vless", "tag": "de-1",
           "settings": {"vnext": [{"address": "1.1.1.1", "port": 443,
             "users": [{"id": "11111111-2222-3333-4444-555555555555"}]}]}},
          {"protocol": "vless", "tag": "de-2",
           "settings": {"vnext": [{"address": "2.2.2.2", "port": 443,
             "users": [{"id": "11111111-2222-3333-4444-555555555555"}]}]}},
          {"protocol": "freedom", "tag": "direct"}
        ],
        "routing": {"balancers": [{"tag": "DE", "selector": ["de-"]}]}}
        """
        let payload = parse(body)
        XCTAssertEqual(payload.format, .xrayJSON)
        XCTAssertEqual(payload.groups.count, 1)
        XCTAssertEqual(payload.groups.first?.name, "DE")
        XCTAssertEqual(payload.groups.first?.memberIDs.count, 2,
                       "`direct` does not match the `de-` prefix")
    }

    func testShareLinksDeclareNoGroups() {
        let body = "vless://11111111-2222-3333-4444-555555555555@1.1.1.1:443?type=tcp#NL-01"
        let payload = parse(body)
        XCTAssertEqual(payload.format, .links)
        XCTAssertTrue(payload.groups.isEmpty)
    }
}

/// `store.json` is read with a single `try?`: one key a decoder insists on and
/// cannot find empties every subscription the user had.
final class SubscriptionStoreCompatibilityTests: XCTestCase {

    func testAStoreWrittenBeforeGroupsExistedStillDecodes() throws {
        let json = """
        {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "name": "Panel",
         "servers": [], "autoUpdate": true, "isCollapsed": false}
        """
        let sub = try JSONDecoder().decode(Subscription.self,
                                           from: Data(json.utf8))
        XCTAssertEqual(sub.name, "Panel")
        XCTAssertTrue(sub.declaredGroups.isEmpty)
    }
}

/// Panels choose the response format by User-Agent, so the client Veil
/// presents decides whether balancers and routing arrive at all.
final class SubscriptionRequestProfileTests: XCTestCase {

    func testAutomaticKeepsVeilsOwnAgentOrTheGlobalOverride() {
        let sub = Subscription(name: "s", url: "https://example.com/sub")
        XCTAssertNil(sub.requestUserAgent(global: ""))
        XCTAssertEqual(sub.requestUserAgent(global: " Custom/1 "), "Custom/1")
    }

    func testPresetsWinOverTheGlobalOverride() {
        var sub = Subscription(name: "s", url: "https://example.com/sub")
        sub.requestAs = .xrayJSON
        XCTAssertEqual(sub.requestUserAgent(global: "Custom/1"), "Happ/3.0.0")
        sub.requestAs = .singbox
        XCTAssertEqual(sub.requestUserAgent(global: "Custom/1"), "SFM/1.14.0")
    }

    func testCustomUsesTheSubscriptionsOwnAgent() {
        var sub = Subscription(name: "s", url: "https://example.com/sub")
        sub.requestAs = .custom
        sub.userAgentOverride = "Streisand/1.0"
        XCTAssertEqual(sub.requestUserAgent(global: "Custom/1"), "Streisand/1.0")
        sub.userAgentOverride = "  "
        XCTAssertEqual(sub.requestUserAgent(global: "Custom/1"), "Custom/1")
    }

    func testAStoreWrittenBeforeTheFieldStillDecodes() throws {
        let old = #"{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","name":"s","servers":[],"autoUpdate":true,"isCollapsed":false}"#
        let sub = try JSONDecoder().decode(Subscription.self, from: Data(old.utf8))
        XCTAssertNil(sub.requestAs)
    }
}

/// Remnawave answers a client it serves Xray JSON to with a list of whole
/// configs, one per host, each naming its server in `remarks`.
final class XrayConfigListTests: XCTestCase {

    private func config(remarks: String, address: String, tag: String = "proxy") -> String {
        """
        {"remarks": "\(remarks)",
         "outbounds": [
           {"tag": "\(tag)", "protocol": "vless",
            "settings": {"vnext": [{"address": "\(address)", "port": 443,
              "users": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "encryption": "none"}]}]},
            "streamSettings": {"network": "tcp", "security": "tls"}},
           {"tag": "direct", "protocol": "freedom"}
         ],
         "routing": {"rules": []}}
        """
    }

    func testEveryConfigInTheListBecomesANamedServer() {
        let body = "[\(config(remarks: "🇩🇪 Germany", address: "1.1.1.1")),\(config(remarks: "🇫🇮 Finland", address: "2.2.2.2"))]"
        let payload = SubscriptionPayloadParser.parse(body)
        XCTAssertEqual(payload.format, .xrayJSON)
        XCTAssertEqual(payload.servers.map(\.name), ["🇩🇪 Germany", "🇫🇮 Finland"])
        XCTAssertEqual(payload.servers.map(\.address), ["1.1.1.1", "2.2.2.2"])
        XCTAssertTrue(payload.skipped.isEmpty, "freedom is structural: \(payload.skipped)")
    }

    func testABase64WrappedListIsReadToo() {
        let body = "[\(config(remarks: "A", address: "1.1.1.1"))]"
        let payload = SubscriptionPayloadParser.parse(Data(body.utf8).base64EncodedString())
        XCTAssertEqual(payload.format, .xrayBase64)
        XCTAssertEqual(payload.servers.map(\.name), ["A"])
    }

    func testABalancedProfileIsOneEntryOverItsNodes() {
        let body = """
        [{"remarks": "Auto",
          "outbounds": [
            {"tag": "proxy-1", "protocol": "vless",
             "settings": {"vnext": [{"address": "1.1.1.1", "port": 443,
               "users": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "encryption": "none"}]}]}},
            {"tag": "proxy-2", "protocol": "vless",
             "settings": {"vnext": [{"address": "2.2.2.2", "port": 443,
               "users": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "encryption": "none"}]}]}}
          ],
          "routing": {"balancers": [{"tag": "auto", "selector": ["proxy-"]}]}}]
        """
        let payload = SubscriptionPayloadParser.parse(body)
        XCTAssertEqual(payload.servers.map(\.name), ["Auto"])
        XCTAssertEqual(payload.servers.first?.allAddresses, ["1.1.1.1", "2.2.2.2"])
        XCTAssertTrue(payload.groups.isEmpty)
    }

    private func node(_ tag: String, _ address: String) -> String {
        """
        {"tag": "\(tag)", "protocol": "vless",
         "settings": {"vnext": [{"address": "\(address)", "port": 443,
           "users": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "encryption": "none"}]}]}}
        """
    }

    private func profile(_ remarks: String, _ nodes: [(String, String)], meta: String = "") -> String {
        """
        {"remarks": "\(remarks)", \(meta)
         "outbounds": [\(nodes.map { node($0.0, $0.1) }.joined(separator: ","))],
         "routing": {"balancers": [
           {"tag": "auto", "selector": ["testpath-"]},
           {"tag": "telegram-fast", "selector": ["tg-"]}]}}
        """
    }

    /// Happ lists one entry per profile; the internal outbound tags never show.
    func testEachProfileIsOneEntryNamedByItsRemarks() {
        let body = "[" + [
            profile("Europe | Auto", [("testpath-0", "1.1.1.1"), ("testpath-1", "2.2.2.2"),
                                      ("tg-0", "9.9.9.9")]),
            profile("Germany", [("testpath-0", "2.2.2.2")]),
        ].joined(separator: ",") + "]"
        let payload = SubscriptionPayloadParser.parse(body)
        XCTAssertEqual(payload.servers.map(\.name), ["Europe | Auto", "Germany"])
        XCTAssertEqual(payload.servers[0].allAddresses, ["1.1.1.1", "2.2.2.2"],
                       "only what the main balancer picks from; the Telegram one is routing's")
        XCTAssertFalse(payload.servers[1].isBalancer)
        XCTAssertFalse(payload.servers.contains { $0.name.contains("testpath") })
    }

    func testTheProfilesServerDescriptionReachesItsEntry() {
        let body = "[" + profile("Germany", [("testpath-0", "1.1.1.1")],
                                 meta: #""meta": {"serverDescription": "Fast · 10 Gbit"},"#) + "]"
        XCTAssertEqual(SubscriptionPayloadParser.parse(body).servers.first?.serverDescription,
                       "Fast · 10 Gbit")
    }

    func testAnEmptyListIsNotAConfig() {
        XCTAssertEqual(SubscriptionPayloadParser.parse("[]").format, .unknown)
    }
}

/// Remnawave's per-host "Server Description", in Happ's link convention.
final class ServerDescriptionLinkTests: XCTestCase {

    private let base = "vless://3F2504E0-4F89-11D3-9A0C-0305E82C3301@1.2.3.4:443?encryption=none&security=none&type=tcp"

    func testTheDescriptionIsSplitOffTheName() throws {
        let text = Data("Через РФ · 1 Гбит".utf8).base64EncodedString()
        let fragment = "🇸🇪 Швеция?serverDescription=\(text)"
            .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!
        let server = try LinkParser.parse("\(base)#\(fragment)")
        XCTAssertEqual(server.name, "🇸🇪 Швеция")
        XCTAssertEqual(server.serverDescription, "Через РФ · 1 Гбит")
    }

    func testANameWithoutOneIsLeftAlone() throws {
        let server = try LinkParser.parse("\(base)#Plain%20name")
        XCTAssertEqual(server.name, "Plain name")
        XCTAssertNil(server.serverDescription)
    }
}
