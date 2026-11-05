import XCTest
@testable import XrayClient

/// The half of the app an assistant could not reach.
///
/// The API started as a routing surface: rules, groups, DNS, connect. An agent
/// asked to fix "my provider's new server is missing" or "why is this domain
/// still direct" had no way to see the sources, the labels on a node, or the
/// log the core wrote — so it guessed. These endpoints are what it needs to
/// answer instead, and the one thing they must never hand back is a
/// subscription URL, whose path is the access token.
@MainActor
final class ControlCoverageTests: XCTestCase {

    func testSourcesAreListedWithWhatEachOneProduced() throws {
        let backend = FakeBackend()
        backend.storedSources = [
            ControlSource(id: UUID(), name: "Panel A", serverCount: 12, groupCount: 1,
                          lastUpdated: nil,
                          skipped: [ControlSkipNote(label: "ssr://", count: 3)],
                          hasStoredURL: true)
        ]

        let response = router(backend).handle(request("GET", "/v1/sources"))
        let rows = try XCTUnwrap(object(response) as? [[String: Any]])

        XCTAssertEqual(rows.first?["name"] as? String, "Panel A")
        XCTAssertEqual(rows.first?["serverCount"] as? Int, 12)
        XCTAssertEqual((rows.first?["skipped"] as? [[String: Any]])?.first?["count"] as? Int, 3)
    }

    func testASourceNeverCarriesItsURL() throws {
        let backend = FakeBackend()
        backend.storedSources = [
            ControlSource(id: UUID(), name: "Panel A", serverCount: 1, groupCount: 0,
                          lastUpdated: nil, skipped: [],
                          hasStoredURL: true)
        ]

        let response = router(backend).handle(request("GET", "/v1/sources"))
        let text = String(decoding: response.body, as: UTF8.self)

        XCTAssertFalse(text.contains("http"),
                       "the path of a subscription URL is the access token")
        XCTAssertTrue(text.contains("hasStoredURL"),
                      "saying one exists is the most the API may say")
    }

    func testRefreshingTheSourcesIsOneRequest() {
        let backend = FakeBackend()

        _ = router(backend).handle(request("POST", "/v1/sources/refresh"))

        XCTAssertEqual(backend.refreshCount, 1)
    }

    // MARK: - What the user attached to a node

    func testTheNodeLabelsRoundTrip() throws {
        let backend = FakeBackend()
        let id = UUID()
        let body = try JSONEncoder().encode(
            [id.uuidString: NodeAnnotation(tags: ["work"], pinned: true)])

        _ = router(backend).handle(request("PUT", "/v1/nodes", body: body))
        let back = router(backend).handle(request("GET", "/v1/nodes"))
        let rows = try XCTUnwrap(object(back) as? [String: Any])

        XCTAssertEqual((rows[id.uuidString] as? [String: Any])?["pinned"] as? Bool, true)
    }

    func testABodyThatIsNotKeyedByNodeIsRefused() {
        let backend = FakeBackend()
        backend.storedAnnotations = [UUID(): NodeAnnotation(tags: ["keep"])]

        let response = router(backend).handle(
            request("PUT", "/v1/nodes", body: Data("[1,2,3]".utf8)))

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual(backend.storedAnnotations.count, 1,
                       "a rejected body must not clear what is stored")
    }

    // MARK: - The log

    func testTheLogCanBeNarrowedToWhatWentWrong() throws {
        let backend = FakeBackend()
        backend.storedLog = "[Info] started\n[Error] dial failed"

        let response = router(backend).handle(
            request("GET", "/v1/logs", query: ["level": "error"]))
        let payload = try XCTUnwrap(object(response) as? [String: Any])

        XCTAssertEqual(payload["log"] as? String, "[Error] dial failed")
    }

    func testTheLogIsRedactedOnTheWayOut() throws {
        let backend = FakeBackend()
        backend.storedLog = "[Info] fetching https://panel.example.com/sub/SeCrEtToKeN"

        let response = router(backend).handle(request("GET", "/v1/logs"))
        let text = String(decoding: response.body, as: UTF8.self)

        XCTAssertFalse(text.contains("SeCrEtToKeN"),
                       "the log is the other place a subscription URL turns up")
    }

    func testTheLogIsCappedSoOneRequestCannotReturnMegabytes() throws {
        let backend = FakeBackend()
        backend.storedLog = (1...500).map { "[Info] line \($0)" }.joined(separator: "\n")

        let response = router(backend).handle(
            request("GET", "/v1/logs", query: ["limit": "10"]))
        let payload = try XCTUnwrap(object(response) as? [String: Any])
        let lines = (payload["log"] as? String)?.split(separator: "\n") ?? []

        XCTAssertEqual(lines.count, 10)
        XCTAssertEqual(lines.last, "[Info] line 500", "the last lines are the fresh ones")
    }

    // MARK: - Applying an edit

    func testAnEditCanBeAppliedWithoutNamingAServer() {
        let backend = FakeBackend()

        let response = router(backend).handle(request("POST", "/v1/apply"))

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(backend.applyCount, 1,
                       "an agent that edits rules has to be able to say 'now'")
    }

    // MARK: - The contract

    func testTheSchemaDescribesEveryNewEndpoint() throws {
        let response = router(FakeBackend()).handle(request("GET", "/v1/schema"))
        let text = String(decoding: response.body, as: UTF8.self)

        for path in ["/v1/sources", "/v1/sources/refresh", "/v1/nodes",
                     "/v1/logs", "/v1/apply", "/v1/diagnostics"] {
            XCTAssertTrue(text.contains(path),
                          "an endpoint the schema does not list does not exist to a caller")
        }
    }

    func testDiagnosticsComeBackRedacted() throws {
        let backend = FakeBackend()
        backend.storedDiagnostics = "url: https://panel.example.com/sub/SeCrEtToKeN"

        let response = router(backend).handle(request("GET", "/v1/diagnostics"))

        XCTAssertFalse(String(decoding: response.body, as: UTF8.self).contains("SeCrEtToKeN"))
    }

    // MARK: - Harness

    private final class FakeBackend: ControlBackend {
        var storedSources: [ControlSource] = []
        var storedAnnotations: [UUID: NodeAnnotation] = [:]
        var storedLog = ""
        var storedDiagnostics = ""
        var refreshCount = 0
        var applyCount = 0

        func sources() -> [ControlSource] { storedSources }
        func refreshSources() { refreshCount += 1 }
        func annotations() -> [UUID: NodeAnnotation] { storedAnnotations }
        func setAnnotations(_ annotations: [UUID: NodeAnnotation]) {
            storedAnnotations = annotations
        }
        func log() -> String { storedLog }
        func diagnostics() -> String { storedDiagnostics }
        func apply() { applyCount += 1 }

        func state() -> ControlState {
            ControlState(version: "1.0", connection: "disconnected", mode: "tun",
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
    }

    private func router(_ backend: FakeBackend) -> ControlRouter {
        ControlRouter(backend: backend)
    }

    private func request(_ method: String, _ path: String,
                         body: Data = Data(),
                         query: [String: String] = [:]) -> ControlRequest {
        ControlRequest(method: method, path: path, query: query, body: body,
                       origin: nil)
    }

    private func object(_ response: ControlResponse) -> Any? {
        try? JSONSerialization.jsonObject(with: response.body)
    }
}
