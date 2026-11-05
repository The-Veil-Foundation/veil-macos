import XCTest
@testable import XrayClient

/// The router is covered without a socket elsewhere; this one proves the
/// Unix socket around it actually serves, with the permissions that stand in
/// for a token, and that the MCP bridge's client speaks to it.

@MainActor
final class ControlServerLiveTests: XCTestCase {
    private final class Backend: ControlBackend {
        func state() -> ControlState {
            ControlState(version: "t", connection: "disconnected", mode: "tun",
                         activeServerID: nil, activeServerName: "", uptimeSeconds: nil,
                         preset: "bypassLAN", ruleCount: 0, groupCount: 0,
                         serverCount: 0, nativeCore: true, processRoutingAvailable: true)
        }
        func servers() -> [ControlServerInfo] { [] }
        func apps(matching query: String, limit: Int) -> [ControlApp] { [] }
        func rules() -> [RoutingRule] { [] }
        func setRules(_ rules: [RoutingRule]) {}
        func groups() -> [ServerGroup] { [] }
        func setGroups(_ groups: [ServerGroup]) {}
        func dns() -> DNSSettings { DNSSettings() }
        func setDNS(_ dns: DNSSettings) {}
        func preset() -> RoutingPreset { .bypassLAN }
        func setPreset(_ preset: RoutingPreset) {}
        func connect(serverID: UUID) throws {}
        func disconnect() {}
        func renderedProfile() throws -> String { "{}" }
        func sources() -> [ControlSource] { [] }
        func refreshSources() {}
        func annotations() -> [UUID: NodeAnnotation] { [:] }
        func setAnnotations(_ annotations: [UUID: NodeAnnotation]) {}
        func log() -> String { "" }
        func diagnostics() -> String { "" }
        func apply() {}
    }

    func testServesOverTheSocketAndTheBridgeReachesIt() async throws {
        let server = ControlServer()
        // Short and private: sun_path holds 104 bytes, and the test must not
        // touch the real app's socket.
        let path = "/tmp/veil-test-\(getpid()).sock"
        server.start(at: path, backend: Backend())
        XCTAssertTrue(server.isRunning, server.lastError ?? "not running")

        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "only the user may open the socket")

        let call = MCPBridge.Call(method: "GET", path: "/v1/state")
        let reply = await Task.detached { MCPBridge.exchange(call, socketPath: path) }.value
        XCTAssertEqual(reply?.ok, true)
        let json = try JSONSerialization.jsonObject(with: Data((reply?.text ?? "").utf8))
            as? [String: Any]
        XCTAssertEqual(json?["connection"] as? String, "disconnected")

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let gone = await Task.detached { MCPBridge.exchange(call, socketPath: path) }.value
        XCTAssertNil(gone, "nothing answers once the server stops")
    }
}
