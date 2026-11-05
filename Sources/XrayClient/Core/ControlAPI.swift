// macOS-only.
#if os(macOS)
import Foundation

/// What a control-API caller may do, expressed without any transport.
///
/// The router below turns HTTP into these calls and back, so the interesting
/// half — what each endpoint means, and what it refuses — is testable without
/// opening a socket.
@MainActor
protocol ControlBackend: AnyObject {
    func state() -> ControlState
    func servers() -> [ControlServerInfo]
    func apps(matching query: String, limit: Int) -> [ControlApp]

    func rules() -> [RoutingRule]
    func setRules(_ rules: [RoutingRule])
    func groups() -> [ServerGroup]
    func setGroups(_ groups: [ServerGroup])
    func dns() -> DNSSettings
    func setDNS(_ dns: DNSSettings)
    func preset() -> RoutingPreset
    func setPreset(_ preset: RoutingPreset)

    /// The sources the list is built from, and what each one produced. Never
    /// their URLs: the path of a subscription URL is the access token.
    func sources() -> [ControlSource]
    func refreshSources()
    /// What the user attached to individual nodes, keyed by node id.
    func annotations() -> [UUID: NodeAnnotation]
    func setAnnotations(_ annotations: [UUID: NodeAnnotation])
    /// The core's log, as it stands. The router redacts and narrows it.
    func log() -> String
    /// The same report the Export diagnostics button copies.
    func diagnostics() -> String
    /// Pushes the current settings into a live connection, so an edit takes
    /// effect without naming a server to reconnect to.
    func apply()

    func connect(serverID: UUID) throws
    func disconnect()
    /// The configuration the current settings would produce, for a caller that
    /// wants to check its own edit before asking for a reconnect.
    func renderedProfile() throws -> String
}

// MARK: - Wire types

/// A snapshot an assistant can orient itself with in one request.
struct ControlState: Codable {
    var version: String
    var connection: String          // disconnected | connecting | connected | failed
    var mode: String                // systemProxy | tun
    var activeServerID: UUID?
    var activeServerName: String
    var uptimeSeconds: Int?
    var preset: String
    var ruleCount: Int
    var groupCount: Int
    var serverCount: Int
    var nativeCore: Bool
    /// True when process rules can actually be enforced right now.
    var processRoutingAvailable: Bool
}

struct ControlServerInfo: Codable {
    var id: UUID
    var name: String
    var proto: String
    var address: String
    var port: Int
    var engine: String
    var group: String
    /// The outbound tag a rule would use to name this server.
    var tag: String
}

/// A source of servers — a subscription, or the nodes added by hand.
///
/// Deliberately without the URL. An API that cannot read a secret cannot leak
/// one, and knowing that a URL exists is all a caller needs.
struct ControlSource: Codable {
    var id: UUID
    var name: String
    var serverCount: Int
    var groupCount: Int
    var lastUpdated: Date?
    /// What the last fetch could not use, so a caller can explain a server
    /// that the provider lists and the app does not show.
    var skipped: [ControlSkipNote]
    var hasStoredURL: Bool
}

/// One reason entries were dropped, and how many it accounted for.
struct ControlSkipNote: Codable {
    var label: String
    var count: Int
}

/// One application a rule can be written against.
struct ControlApp: Codable {
    var name: String
    /// What a rule must contain — sing-box matches the executable, not the
    /// name on the icon.
    var processName: String
    var path: String
    var bundleID: String?
    var running: Bool
}

struct ControlRequest {
    var method: String
    var path: String
    var query: [String: String] = [:]
    var body: Data = Data()
    /// Present when a browser made the request. Any value at all is a reason
    /// to refuse: a page the user happened to open must not be able to drive
    /// the tunnel just because it can reach the loopback.
    var origin: String?
}

struct ControlResponse {
    var status: Int
    var body: Data
    var contentType = "application/json"

    static func json(_ object: Any, status: Int = 200) -> ControlResponse {
        // Without the last option every path comes back as "\/v1\/state",
        // which is valid JSON and unreadable to the person the schema is for.
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
        return ControlResponse(status: status, body: data)
    }

    static func encode<T: Encodable>(_ value: T, status: Int = 200) -> ControlResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return .error("could not encode the response", status: 500)
        }
        return ControlResponse(status: status, body: data)
    }

    static func error(_ message: String, status: Int) -> ControlResponse {
        json(["error": message], status: status)
    }

    static let ok = ControlResponse.json(["ok": true])
}

// MARK: - Router

/// Maps requests onto the backend.
///
/// Everything here is deliberately small and boring: the API exists so an
/// assistant can read the current configuration, look up what an application
/// is really called, write rules back and ask for a reconnect. It cannot add
/// servers or read a subscription URL, because neither is needed to configure
/// routing and both are worth keeping out of reach.
@MainActor
struct ControlRouter {
    let backend: ControlBackend

    func handle(_ request: ControlRequest) -> ControlResponse {
        if request.origin != nil {
            return .error("cross-origin requests are not accepted", status: 403)
        }

        let path = request.path.hasSuffix("/") && request.path.count > 1
            ? String(request.path.dropLast()) : request.path

        switch (request.method, path) {
        case ("GET", "/v1/schema"):
            return .json(ControlRouter.schema)
        case ("GET", "/v1/state"):
            return .encode(backend.state())
        case ("GET", "/v1/servers"):
            return .encode(backend.servers())
        case ("GET", "/v1/apps"):
            let limit = Int(request.query["limit"] ?? "") ?? 50
            return .encode(backend.apps(matching: request.query["q"] ?? "",
                                        limit: max(1, min(limit, 500))))

        case ("GET", "/v1/rules"):
            return .encode(backend.rules())
        case ("PUT", "/v1/rules"):
            return decode([RoutingRule].self, request) { rules in
                backend.setRules(rules)
                return .encode(backend.rules())
            }

        case ("GET", "/v1/groups"):
            return .encode(backend.groups())
        case ("PUT", "/v1/groups"):
            return decode([ServerGroup].self, request) { groups in
                backend.setGroups(groups)
                return .encode(backend.groups())
            }

        case ("GET", "/v1/dns"):
            return .encode(backend.dns())
        case ("PUT", "/v1/dns"):
            return decode(DNSSettings.self, request) { dns in
                backend.setDNS(dns)
                return .encode(backend.dns())
            }

        case ("GET", "/v1/preset"):
            return .json(["preset": backend.preset().rawValue,
                          "available": RoutingPreset.allCases.map(\.rawValue)])
        case ("PUT", "/v1/preset"):
            return decode(PresetBody.self, request) { body in
                guard let preset = RoutingPreset(rawValue: body.preset) else {
                    return .error("unknown preset \"\(body.preset)\"", status: 400)
                }
                backend.setPreset(preset)
                return .json(["preset": preset.rawValue])
            }

        case ("GET", "/v1/config"):
            do {
                return ControlResponse(status: 200,
                                       body: Data(try backend.renderedProfile().utf8))
            } catch {
                return .error(error.localizedDescription, status: 500)
            }

        case ("POST", "/v1/connect"):
            return decode(ConnectBody.self, request) { body in
                guard let id = UUID(uuidString: body.serverID) else {
                    return .error("serverID is not a uuid", status: 400)
                }
                do {
                    try backend.connect(serverID: id)
                    return .ok
                } catch {
                    return .error(error.localizedDescription, status: 404)
                }
            }
        case ("POST", "/v1/disconnect"):
            backend.disconnect()
            return .ok

        case ("GET", "/v1/sources"):
            return .encode(backend.sources())
        case ("POST", "/v1/sources/refresh"):
            backend.refreshSources()
            return .ok

        case ("GET", "/v1/nodes"):
            return .encode(keyed(backend.annotations()))
        case ("PUT", "/v1/nodes"):
            return decode([String: NodeAnnotation].self, request) { posted in
                var parsed: [UUID: NodeAnnotation] = [:]
                for (key, annotation) in posted {
                    guard let id = UUID(uuidString: key) else {
                        return .error("\"\(key)\" is not a node id", status: 400)
                    }
                    parsed[id] = annotation
                }
                backend.setAnnotations(parsed)
                return .encode(keyed(backend.annotations()))
            }

        case ("GET", "/v1/logs"):
            let limit = max(1, min(Int(request.query["limit"] ?? "") ?? 200, 2000))
            let level = request.query["level"].flatMap { LogLevel(rawValue: $0) }
            let narrowed = LogFilter.apply(backend.log(),
                                           query: request.query["q"] ?? "",
                                           minimum: level)
            // The tail, not the head: the lines that explain what just
            // happened are the last ones.
            let lines = narrowed.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(limit).joined(separator: "\n")
            // Redacted here rather than in the backend, because this is the
            // boundary the secret would cross.
            return .json(["log": Redaction.text(tail)])

        case ("GET", "/v1/diagnostics"):
            return .json(["report": Redaction.text(backend.diagnostics())])

        case ("POST", "/v1/apply"):
            backend.apply()
            return .ok

        default:
            return .error("no such endpoint: \(request.method) \(path)", status: 404)
        }
    }

    /// Annotations travel as an object keyed by node id, which JSON can carry
    /// and a `[UUID: …]` dictionary cannot.
    private func keyed(_ annotations: [UUID: NodeAnnotation]) -> [String: NodeAnnotation] {
        Dictionary(uniqueKeysWithValues: annotations.map { ($0.key.uuidString, $0.value) })
    }

    private struct ConnectBody: Decodable { var serverID: String }
    private struct PresetBody: Decodable { var preset: String }

    private func decode<T: Decodable>(_ type: T.Type, _ request: ControlRequest,
                                      _ body: (T) -> ControlResponse) -> ControlResponse {
        do {
            return body(try JSONDecoder().decode(type, from: request.body))
        } catch {
            return .error("could not read the request body: \(error)", status: 400)
        }
    }

    /// Enough for a caller to work the API without documentation — which is
    /// the point: the assistant reads this first and goes from there.
    static let schema: [String: Any] = [
        "name": "Veil control API",
        "auth": "none: reached through `Veil mcp`, over a socket only this user can open",
        "notes": [
            "Rules are ordered; the first match wins.",
            "A rule's target is \"proxy\", \"direct\", \"block\", \"server:<uuid>\" or \"group:<uuid>\".",
            "processNames must hold executable names — look them up with GET /v1/apps.",
            "Changes take effect on the next connect; POST /v1/connect to apply them now."
        ],
        "endpoints": [
            ["GET /v1/state", "connection, mode, counts, whether process rules can be enforced"],
            ["GET /v1/servers", "servers with the tag a rule uses to name them"],
            ["GET /v1/apps?q=&limit=", "installed and running applications, with executable names"],
            ["GET /v1/rules", "the ordered routing rules"],
            ["PUT /v1/rules", "replace the routing rules with the posted array"],
            ["GET /v1/groups", "server groups"],
            ["PUT /v1/groups", "replace the groups"],
            ["GET /v1/dns", "resolver settings"],
            ["PUT /v1/dns", "replace the resolver settings"],
            ["GET /v1/preset", "current preset and the available ones"],
            ["PUT /v1/preset", "{\"preset\": \"bypassLAN\"}"],
            ["GET /v1/config", "the configuration the current settings would produce"],
            ["POST /v1/connect", "{\"serverID\": \"<uuid>\"}"],
            ["POST /v1/disconnect", "stop the tunnel"],
            ["GET /v1/sources", "where the servers come from, with what each fetch skipped"],
            ["POST /v1/sources/refresh", "re-download every source"],
            ["GET /v1/nodes", "the user's own labels, pins, hides and renames, by node id"],
            ["PUT /v1/nodes", "replace them; the body is an object keyed by node id"],
            ["GET /v1/logs?limit=&level=&q=", "the tail of the core's log, redacted"],
            ["GET /v1/diagnostics", "the redacted diagnostics report"],
            ["POST /v1/apply", "push the current settings into a live connection"]
        ]
    ]
}
#endif
