import XCTest
@testable import XrayClient

/// The control API can rewrite where the machine's traffic goes, so these
/// cover the two halves that decide whether a request is allowed to: the HTTP
/// parser and the router's own checks.
@MainActor
final class ControlAPITests: XCTestCase {

    private final class FakeBackend: ControlBackend {
        var storedRules: [RoutingRule] = []
        var storedGroups: [ServerGroup] = []
        var storedDNS = DNSSettings()
        var storedPreset: RoutingPreset = .bypassLAN
        var connected: UUID?
        var disconnectCount = 0
        var knownServer = UUID()

        func state() -> ControlState {
            ControlState(version: "1.0", connection: "disconnected", mode: "tun",
                         activeServerID: nil, activeServerName: "", uptimeSeconds: nil,
                         preset: storedPreset.rawValue, ruleCount: storedRules.count,
                         groupCount: storedGroups.count, serverCount: 1,
                         nativeCore: true, processRoutingAvailable: true)
        }
        func servers() -> [ControlServerInfo] {
            [ControlServerInfo(id: knownServer, name: "DE", proto: "vless",
                               address: "1.2.3.4", port: 443, engine: "sing-box",
                               group: "Manual", tag: ProfileTags.server(knownServer))]
        }
        func apps(matching query: String, limit: Int) -> [ControlApp] {
            [ControlApp(name: "Visual Studio Code", processName: "Electron",
                        path: "/Applications/VSCode.app/Contents/MacOS/Electron",
                        bundleID: nil, running: true)]
        }
        func rules() -> [RoutingRule] { storedRules }
        func setRules(_ rules: [RoutingRule]) { storedRules = rules }
        func groups() -> [ServerGroup] { storedGroups }
        func setGroups(_ groups: [ServerGroup]) { storedGroups = groups }
        func dns() -> DNSSettings { storedDNS }
        func setDNS(_ dns: DNSSettings) { storedDNS = dns }
        func preset() -> RoutingPreset { storedPreset }
        func setPreset(_ preset: RoutingPreset) { storedPreset = preset }
        func connect(serverID: UUID) throws {
            guard serverID == knownServer else {
                throw AppControlBackend.Failure.noSuchServer(serverID)
            }
            connected = serverID
        }
        func disconnect() { disconnectCount += 1 }
        func renderedProfile() throws -> String { "{\"outbounds\":[]}" }
        func sources() -> [ControlSource] { [] }
        func refreshSources() {}
        func annotations() -> [UUID: NodeAnnotation] { [:] }
        func setAnnotations(_ annotations: [UUID: NodeAnnotation]) {}
        func log() -> String { "" }
        func diagnostics() -> String { "" }
        func apply() {}
    }

    private func router(_ backend: FakeBackend) -> ControlRouter {
        ControlRouter(backend: backend)
    }

    private func request(_ method: String, _ path: String,
                         body: Data = Data(),
                         origin: String? = nil,
                         query: [String: String] = [:]) -> ControlRequest {
        ControlRequest(method: method, path: path, query: query, body: body,
                       origin: origin)
    }

    private func object(_ response: ControlResponse) -> Any? {
        try? JSONSerialization.jsonObject(with: response.body)
    }

    // MARK: - Access

    func testRefusesARequestFromAWebPage() {
        // A page the user happens to have open can reach the loopback. It must
        // not be able to drive the tunnel even if it guesses the port.
        let response = router(FakeBackend())
            .handle(request("GET", "/v1/state", origin: "https://example.com"))
        XCTAssertEqual(response.status, 403)
    }

    // MARK: - Endpoints

    func testStateReportsWhetherProcessRulesCanBeEnforced() throws {
        let response = router(FakeBackend()).handle(request("GET", "/v1/state"))
        let json = object(response) as? [String: Any]
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(json?["processRoutingAvailable"] as? Bool, true)
    }

    func testAppsReportTheExecutableRatherThanTheDisplayName() throws {
        let response = router(FakeBackend())
            .handle(request("GET", "/v1/apps", query: ["q": "code"]))
        let apps = object(response) as? [[String: Any]]
        XCTAssertEqual(apps?.first?["processName"] as? String, "Electron")
    }

    func testRulesRoundTrip() throws {
        let backend = FakeBackend()
        let serverID = backend.knownServer
        var rule = RoutingRule(name: "Work", target: .server(serverID),
                               processNames: ["Slack"])
        rule.network = "tcp"
        let body = try JSONEncoder().encode([rule])

        let response = router(backend).handle(request("PUT", "/v1/rules", body: body))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(backend.storedRules.count, 1)
        XCTAssertEqual(backend.storedRules.first?.target, .server(serverID))
        XCTAssertEqual(backend.storedRules.first?.processNames, ["Slack"])

        // What comes back must decode as the same thing, or a caller that
        // reads, edits and writes would corrupt the list.
        let echoed = try JSONDecoder().decode([RoutingRule].self, from: response.body)
        XCTAssertEqual(echoed, backend.storedRules)
    }

    func testAMalformedBodyIsRejectedWithoutTouchingTheRules() {
        let backend = FakeBackend()
        backend.storedRules = [RoutingRule(name: "Keep me")]
        let response = router(backend)
            .handle(request("PUT", "/v1/rules", body: Data("not json".utf8)))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(backend.storedRules.map(\.name), ["Keep me"])
    }

    func testPresetMustBeOneThatExists() {
        let backend = FakeBackend()
        let body = Data("{\"preset\":\"nonsense\"}".utf8)
        let response = router(backend).handle(request("PUT", "/v1/preset", body: body))
        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(backend.storedPreset, .bypassLAN)
    }

    func testConnectingToAnUnknownServerIsAnError() {
        let backend = FakeBackend()
        let body = Data("{\"serverID\":\"\(UUID().uuidString)\"}".utf8)
        let response = router(backend).handle(request("POST", "/v1/connect", body: body))
        XCTAssertEqual(response.status, 404)
        XCTAssertNil(backend.connected)
    }

    func testConnectAndDisconnect() {
        let backend = FakeBackend()
        let body = Data("{\"serverID\":\"\(backend.knownServer.uuidString)\"}".utf8)
        XCTAssertEqual(router(backend).handle(request("POST", "/v1/connect", body: body)).status, 200)
        XCTAssertEqual(backend.connected, backend.knownServer)
        XCTAssertEqual(router(backend).handle(request("POST", "/v1/disconnect")).status, 200)
        XCTAssertEqual(backend.disconnectCount, 1)
    }

    func testUnknownEndpoint() {
        XCTAssertEqual(router(FakeBackend()).handle(request("GET", "/v1/nope")).status, 404)
    }

    func testTrailingSlashIsTheSameEndpoint() {
        XCTAssertEqual(router(FakeBackend()).handle(request("GET", "/v1/state/")).status, 200)
    }

    // MARK: - HTTP parsing

    private func parse(_ text: String) -> ControlHTTP.ParseResult {
        ControlHTTP.parse(Data(text.utf8))
    }

    func testParsesMethodPathAndQuery() {
        guard case .request(let request) = parse(
            "GET /v1/apps?q=google%20chrome&limit=5 HTTP/1.1\r\n\r\n") else {
            return XCTFail("did not parse")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/v1/apps")
        XCTAssertEqual(request.query["q"], "google chrome")
        XCTAssertEqual(request.query["limit"], "5")
    }

    func testWaitsForTheWholeBody() {
        let head = "PUT /v1/rules HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"
        guard case .incomplete = parse(head) else {
            return XCTFail("a half-received body must not be handled")
        }
        guard case .request(let request) = parse(head + "67890") else {
            return XCTFail("did not parse once complete")
        }
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "1234567890")
    }

    func testCarriesTheOriginHeaderThrough() {
        guard case .request(let request) = parse(
            "GET /v1/state HTTP/1.1\r\nOrigin: https://evil.example\r\n\r\n") else {
            return XCTFail("did not parse")
        }
        XCTAssertEqual(request.origin, "https://evil.example")
    }

    func testRejectsAnOversizedBody() {
        let text = "PUT /v1/rules HTTP/1.1\r\nContent-Length: \(ControlHTTP.maxBodyBytes + 1)\r\n\r\n"
        guard case .failure = parse(text) else {
            return XCTFail("an oversized body must be refused before it is read")
        }
    }

    func testResponseHasALengthAndClosesTheConnection() throws {
        let raw = ControlHTTP.response(.json(["ok": true]))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: "))
        XCTAssertTrue(text.contains("Connection: close"))
    }
}
