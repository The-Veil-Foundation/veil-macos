import XCTest
@testable import XrayClient

/// Covers what the app keeps open and how much it holds on to: the listening
/// ports a connection opens, and the size of the log buffer.
final class ResourceUseTests: XCTestCase {

    private func node() -> ProxyConfig {
        var cfg = ProxyConfig(name: "DE", proto: .vless, address: "1.2.3.4", port: 443)
        cfg.uuid = "11111111-2222-3333-4444-555555555555"
        return cfg
    }

    // MARK: - Listening ports

    func testBridgeOpensOnlyItsSocksPort() {
        var ports = InboundPorts()
        ports.socks = 11808
        ports.serveHTTP = false
        let inbounds = XrayConfigBuilder.build(for: node(), ports: ports)["inbounds"]
            as! [[String: Any]]
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds.first?["protocol"] as? String, "socks")
        XCTAssertEqual(inbounds.first?["listen"] as? String, "127.0.0.1")
    }

    func testClashAPIIsOffByDefault() {
        XCTAssertFalse(AppSettings().clashAPIEnabled)
        var input = ProfileAssembler.Input()
        input.servers = [node()]
        input.activeServerID = input.servers[0].id
        XCTAssertFalse(ProfileAssembler.profile(input).clashAPI.enabled)
    }

    func testOldDefaultOnClashAPIValueIsNotCarriedForward() throws {
        let json = Data(#"{"controlAPIEnabled": true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(settings.clashAPIEnabled)
    }

    func testClashModeRuleKeepsTheClashAPIOn() {
        var input = ProfileAssembler.Input()
        input.servers = [node()]
        input.activeServerID = input.servers[0].id
        var rule = RoutingRule()
        rule.clashMode = "Direct"
        rule.target = .direct
        input.settings.customRules = [rule]
        XCTAssertTrue(ProfileAssembler.profile(input).clashAPI.enabled)
    }

    // MARK: - Log buffer

    func testTailOfShortTextIsTheText() {
        XCTAssertEqual(ConnectionManager.tail(of: "a\nb\n", bytes: 100), "a\nb\n")
    }

    func testTailStartsOnALineBoundary() {
        let text = (0..<100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let tail = ConnectionManager.tail(of: text, bytes: 40)
        XCTAssertLessThanOrEqual(tail.utf8.count, 40)
        XCTAssertTrue(tail.hasPrefix("line "))
        XCTAssertTrue(tail.hasSuffix("line 99\n"))
    }

    func testTailNeverSplitsACharacter() {
        // No newline in reach, and the cut lands inside a two-byte letter.
        let text = String(repeating: "ж", count: 50)
        let tail = ConnectionManager.tail(of: text, bytes: 21)
        XCTAssertFalse(tail.contains("\u{FFFD}"))
        XCTAssertEqual(tail, String(repeating: "ж", count: 10))
    }
}
