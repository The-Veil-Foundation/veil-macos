// macOS-only.
#if os(macOS)
import Foundation

/// `Veil mcp` — a Model Context Protocol server on stdin/stdout.
///
/// An assistant's config points at the app binary itself:
///
///     { "mcpServers": { "veil": {
///         "command": "/Applications/Veil.app/Contents/MacOS/Veil",
///         "args": ["mcp"] } } }
///
/// The process it starts is not the app: it holds no servers and no tunnel.
/// It translates each tool call into a control-API request and sends it to the
/// running Veil over `ControlSocket`, so the window and the assistant always
/// edit the same live state. When the user has turned on No AI the socket is
/// not there, and every call says so instead of doing anything.
enum MCPBridge {

    static let latestProtocolVersion = "2025-06-18"

    /// Serves until stdin closes. Nothing but protocol messages may reach
    /// stdout — a stray print breaks the client — so diagnostics go to stderr.
    static func run() -> Never {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = handle(line: line) {
                write(reply)
            }
        }
        exit(0)
    }

    // MARK: - JSON-RPC

    /// The reply to one line, or nil for a notification.
    static func handle(line: String, transport: (Call) -> Reply = MCPBridge.send) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let message = object as? [String: Any] else {
            return failure(id: NSNull(), code: -32700, message: "parse error")
        }
        let method = message["method"] as? String ?? ""
        // A message without an id is a notification and gets no answer, even
        // when it is one this server does not know.
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return success(id: id, result: [
                "protocolVersion": requested ?? latestProtocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "veil", "title": "Veil", "version": version],
                "instructions": instructions
            ])
        case "ping":
            return success(id: id, result: [String: Any]())
        case "tools/list":
            return success(id: id, result: ["tools": tools.map(\.descriptor)])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            guard let tool = tools.first(where: { $0.name == name }) else {
                return failure(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let reply: Reply
            do {
                reply = transport(try tool.call(arguments))
            } catch {
                reply = Reply(ok: false, text: "\(error)")
            }
            return success(id: id, result: [
                "content": [["type": "text", "text": reply.text]],
                "isError": !reply.ok
            ])
        default:
            return failure(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    private static func success(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(
            withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("[veil mcp] \(text)\n".utf8))
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    // MARK: - Tools

    /// One control-API request.
    struct Call {
        var method: String
        var path: String
        var body: Data?
    }

    struct Reply {
        var ok: Bool
        var text: String
    }

    struct ArgumentError: Error, CustomStringConvertible {
        var description: String
    }

    struct Tool {
        var name: String
        var description: String
        var properties: [String: Any] = [:]
        var required: [String] = []
        var readOnly = true
        var call: ([String: Any]) throws -> Call

        var descriptor: [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            return ["name": name, "description": description, "inputSchema": schema,
                    "annotations": ["readOnlyHint": readOnly]]
        }
    }

    private static func get(_ path: String) -> ([String: Any]) throws -> Call {
        { _ in Call(method: "GET", path: path) }
    }

    private static func post(_ path: String) -> ([String: Any]) throws -> Call {
        { _ in Call(method: "POST", path: path) }
    }

    /// PUTs `arguments[key]` as the whole body.
    private static func put(_ path: String, _ key: String) -> ([String: Any]) throws -> Call {
        { arguments in
            guard let value = arguments[key] else {
                throw ArgumentError(description: "missing \"\(key)\"")
            }
            return Call(method: "PUT", path: path, body: try json(value))
        }
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    private static func query(_ path: String, _ arguments: [String: Any], _ keys: [String]) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?")
        let pairs = keys.compactMap { key -> String? in
            guard let value = arguments[key] else { return nil }
            let text = "\(value)".addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(text)"
        }
        return pairs.isEmpty ? path : path + "?" + pairs.joined(separator: "&")
    }

    private static func array(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "object"], "description": description]
    }

    static var tools: [Tool] {
        [
            Tool(name: "get_state",
                 description: "Connection, tunnel mode, counts, and whether application rules can be enforced right now (processRoutingAvailable). Call this first.",
                 call: get("/v1/state")),
            Tool(name: "list_servers",
                 description: "Every server (node) with its id and the tag a rule uses to name it.",
                 call: get("/v1/servers")),
            Tool(name: "list_sources",
                 description: "Where the servers came from (subscriptions, manual) and what the last fetch skipped. Never returns subscription URLs.",
                 call: get("/v1/sources")),
            Tool(name: "refresh_sources",
                 description: "Re-download every subscription.",
                 readOnly: false, call: post("/v1/sources/refresh")),
            Tool(name: "find_apps",
                 description: "Installed and running applications with the executable name a rule must use. The executable is often not the name on the icon (Visual Studio Code is \"Electron\").",
                 properties: ["q": ["type": "string", "description": "part of the app name"],
                              "limit": ["type": "integer", "description": "at most this many, default 50"]],
                 call: { query("/v1/apps", $0, ["q", "limit"]).asGet }),
            Tool(name: "get_rules",
                 description: "The ordered routing rules. The first match wins.",
                 call: get("/v1/rules")),
            Tool(name: "set_rules",
                 description: "Replace ALL routing rules. Read them with get_rules, edit the array keeping its order, send it back. A rule looks like {\"name\":\"Work\",\"target\":\"server:<uuid>\",\"processNames\":[\"Slack\"],\"enabled\":true}; target is proxy, direct, block, server:<uuid> or group:<uuid>.",
                 properties: ["rules": array("the complete ordered list of rules")],
                 required: ["rules"], readOnly: false, call: put("/v1/rules", "rules")),
            Tool(name: "get_groups",
                 description: "Server groups: selectors and urltest groups, including automatic ones defined by a query.",
                 call: get("/v1/groups")),
            Tool(name: "set_groups",
                 description: "Replace ALL server groups with the given array (read with get_groups first).",
                 properties: ["groups": array("the complete list of groups")],
                 required: ["groups"], readOnly: false, call: put("/v1/groups", "groups")),
            Tool(name: "get_dns",
                 description: "Resolver settings.",
                 call: get("/v1/dns")),
            Tool(name: "set_dns",
                 description: "Replace the resolver settings with the given object (read with get_dns first).",
                 properties: ["dns": ["type": "object", "description": "the complete DNS settings"]],
                 required: ["dns"], readOnly: false, call: put("/v1/dns", "dns")),
            Tool(name: "get_preset",
                 description: "The routing preset in use and the ones available.",
                 call: get("/v1/preset")),
            Tool(name: "set_preset",
                 description: "Switch the routing preset.",
                 properties: ["preset": ["type": "string", "description": "one of the names get_preset lists"]],
                 required: ["preset"], readOnly: false,
                 call: { arguments in
                     guard let preset = arguments["preset"] as? String else {
                         throw ArgumentError(description: "missing \"preset\"")
                     }
                     return Call(method: "PUT", path: "/v1/preset", body: try json(["preset": preset]))
                 }),
            Tool(name: "get_node_annotations",
                 description: "The user's own labels, pins, hides and renames, keyed by node id.",
                 call: get("/v1/nodes")),
            Tool(name: "set_node_annotations",
                 description: "Replace ALL node annotations with the given object keyed by node id.",
                 properties: ["nodes": ["type": "object", "description": "annotations keyed by node uuid"]],
                 required: ["nodes"], readOnly: false, call: put("/v1/nodes", "nodes")),
            Tool(name: "render_config",
                 description: "The core profile the current settings would produce, without connecting. The cheapest way to check an edit.",
                 call: get("/v1/config")),
            Tool(name: "get_logs",
                 description: "The tail of the core's log, redacted.",
                 properties: ["limit": ["type": "integer", "description": "lines, default 200"],
                              "level": ["type": "string", "enum": ["debug", "info", "warning", "error"]],
                              "q": ["type": "string", "description": "only lines containing this"]],
                 call: { query("/v1/logs", $0, ["limit", "level", "q"]).asGet }),
            Tool(name: "get_diagnostics",
                 description: "The redacted diagnostics report.",
                 call: get("/v1/diagnostics")),
            Tool(name: "apply",
                 description: "Push the current settings into a live connection. Edits are saved at once but reach a running tunnel only on apply or the next connect.",
                 readOnly: false, call: post("/v1/apply")),
            Tool(name: "connect",
                 description: "Connect to a server by id.",
                 properties: ["serverID": ["type": "string", "description": "uuid from list_servers"]],
                 required: ["serverID"], readOnly: false,
                 call: { arguments in
                     guard let id = arguments["serverID"] as? String else {
                         throw ArgumentError(description: "missing \"serverID\"")
                     }
                     return Call(method: "POST", path: "/v1/connect", body: try json(["serverID": id]))
                 }),
            Tool(name: "disconnect",
                 description: "Stop the tunnel.",
                 readOnly: false, call: post("/v1/disconnect")),
        ]
    }

    static let instructions = """
    Veil is the VPN client on this Mac. These tools read and change how its \
    traffic is routed: sources -> servers -> groups -> rules -> the profile a core runs.
    - Start with get_state.
    - To send an application through a server: find_apps for its executable name, \
    list_servers for the server id, get_rules, append a rule, set_rules with the \
    whole array, then apply (or connect).
    - Every set_* replaces the whole collection; rules are ordered, first match wins.
    - Application rules work only when get_state reports processRoutingAvailable.
    - Subscription URLs and the device identifier are never exposed, and servers \
    cannot be added here.
    """

    // MARK: - Transport

    /// Sends `call` to the running app, starting it once if it is not up.
    static func send(_ call: Call) -> Reply {
        let path = ControlSocket.url.path
        if let reply = exchange(call, socketPath: path) { return reply }

        if noAIIsOn() {
            return Reply(ok: false, text: "No AI is switched on in Veil (Settings → Advanced), so assistants cannot read or change it. Ask the user to switch it off if they want this.")
        }
        guard launchApp() else {
            return Reply(ok: false, text: "Veil is not running and could not be started.")
        }
        for _ in 0..<40 {
            usleep(250_000)
            if let reply = exchange(call, socketPath: path) { return reply }
        }
        return Reply(ok: false, text: "Veil did not answer. Open the app and try again.")
    }

    /// One request over the socket, or nil when nothing is listening.
    static func exchange(_ call: Call, socketPath: String) -> Reply? {
        guard var address = ControlSocket.address(socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let body = call.body ?? Data()
        var request = Data("\(call.method) \(call.path) HTTP/1.1\r\n".utf8)
        request.append(Data("Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
        request.append(body)
        ControlServer.writeAll(request, to: fd)

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { break }
            response.append(chunk, count: count)
        }
        return parse(response)
    }

    static func parse(_ response: Data) -> Reply {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: response[..<split.lowerBound], encoding: .utf8) else {
            return Reply(ok: false, text: "Veil sent an unreadable answer.")
        }
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 500
        let text = String(decoding: response[split.upperBound...], as: UTF8.self)
        return Reply(ok: (200..<300).contains(status), text: text)
    }

    /// Reads the switch straight from the store, so a refusal names the reason
    /// rather than looking like a crash.
    private static func noAIIsOn() -> Bool {
        let store = ControlSocket.url.deletingLastPathComponent().appendingPathComponent("store.json")
        guard let data = try? Data(contentsOf: store),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = object["settings"] as? [String: Any] else { return false }
        return settings["noAI"] as? Bool ?? false
    }

    /// Opens the bundle this binary lives in, in the background.
    private static func launchApp() -> Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            log("not inside an app bundle, cannot start Veil")
            return false
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-j", bundle.path]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
            open.waitUntilExit()
            return open.terminationStatus == 0
        } catch {
            log("open failed: \(error)")
            return false
        }
    }
}

private extension String {
    var asGet: MCPBridge.Call { MCPBridge.Call(method: "GET", path: self) }
}
#endif
