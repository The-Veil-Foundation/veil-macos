import XCTest
@testable import XrayClient

/// `Veil mcp` speaks JSON-RPC on stdio. These feed it lines as a client would
/// and check the replies, with the socket replaced by a closure.
final class MCPBridgeTests: XCTestCase {

    private var calls: [MCPBridge.Call] = []

    private func reply(_ line: String,
                       answer: MCPBridge.Reply = .init(ok: true, text: "{}")) -> [String: Any]? {
        MCPBridge.handle(line: line) { call in
            self.calls.append(call)
            return answer
        }
    }

    private func result(_ message: [String: Any]?) -> [String: Any]? {
        message?["result"] as? [String: Any]
    }

    func testInitializeEchoesTheClientsProtocolVersion() {
        let message = reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
        XCTAssertEqual(message?["id"] as? Int, 1)
        XCTAssertEqual(result(message)?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result(message)?["capabilities"] as? [String: Any])?["tools"])
    }

    func testNotificationsGetNoReply() {
        XCTAssertNil(reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(reply(#"{"jsonrpc":"2.0","method":"notifications/whatever"}"#))
    }

    func testToolsListHasSchemasAndUniqueNames() throws {
        let tools = try XCTUnwrap(result(reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))?["tools"]
            as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertTrue(names.contains("set_rules"))
        for tool in tools {
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
    }

    func testSetRulesPutsTheWholeArray() throws {
        let message = reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_rules","arguments":{"rules":[{"name":"Work","target":"direct"}]}}}"#)
        XCTAssertEqual(result(message)?["isError"] as? Bool, false)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.method, "PUT")
        XCTAssertEqual(call.path, "/v1/rules")
        let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(call.body)) as? [[String: Any]]
        XCTAssertEqual(body?.first?["name"] as? String, "Work")
    }

    func testQueryArgumentsAreEncoded() throws {
        _ = reply(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"find_apps","arguments":{"q":"google chrome&x"}}}"#)
        XCTAssertEqual(calls.first?.path, "/v1/apps?q=google%20chrome%26x")
    }

    func testMissingArgumentIsAToolErrorAndSendsNothing() {
        let message = reply(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"connect","arguments":{}}}"#)
        XCTAssertEqual(result(message)?["isError"] as? Bool, true)
        XCTAssertTrue(calls.isEmpty)
    }

    func testAppRefusalIsReportedAsAToolError() {
        let message = reply(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_state"}}"#,
                            answer: .init(ok: false, text: "No AI is switched on"))
        XCTAssertEqual(result(message)?["isError"] as? Bool, true)
        let content = result(message)?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "No AI is switched on")
    }

    func testUnknownMethodAndBadJSON() {
        let unknown = reply(#"{"jsonrpc":"2.0","id":7,"method":"resources/list"}"#)
        XCTAssertEqual((unknown?["error"] as? [String: Any])?["code"] as? Int, -32601)
        let broken = reply("{not json")
        XCTAssertEqual((broken?["error"] as? [String: Any])?["code"] as? Int, -32700)
    }

    func testParsesAControlResponse() {
        let data = Data("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\n\r\n{}".utf8)
        let parsed = MCPBridge.parse(data)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.text, "{}")
    }
}
