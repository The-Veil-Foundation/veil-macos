import XCTest
@testable import XrayClient

/// The proxy ping modes start a throwaway core built from every node in the
/// batch, so its config has to be one the real binaries accept — with the
/// interface pin the probes use while the tunnel is up.
final class PingProbeTests: XCTestCase {

    private func vless() -> ProxyConfig {
        var node = ProxyConfig(name: "NL", proto: .vless, address: "1.2.3.4", port: 443)
        node.uuid = "11111111-2222-3333-4444-555555555555"
        node.security = .reality
        node.publicKey = "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0"
        node.fingerprint = "chrome"
        return node
    }

    private func check(_ config: [String: Any], engine: CoreEngine) throws -> (Int32, String) {
        let binary = try XCTUnwrap(CoreBinary.locate(for: engine))
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-test-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: config).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process()
        process.executableURL = binary
        process.arguments = engine == .singbox
            ? ["check", "-c", file.path]
            : ["run", "-test", "-config", file.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    func testXrayAcceptsThePingCore() throws {
        try XCTSkipUnless(CoreBinary.locate(for: .xray) != nil, "core not fetched")
        var vmess = ProxyConfig(name: "DE", proto: .vmess, address: "example.com", port: 443)
        vmess.uuid = "11111111-2222-3333-4444-555555555555"
        let config = ProxyProbe.xrayConfig([vless(), vmess], ports: [20001, 20002],
                                           interface: "en0")
        let (status, output) = try check(config, engine: .xray)
        XCTAssertEqual(status, 0, output)
    }

    func testSingBoxAcceptsThePingCore() throws {
        try XCTSkipUnless(CoreBinary.locate(for: .singbox) != nil, "core not fetched")
        var hy2 = ProxyConfig(name: "hy", proto: .hysteria2, address: "example.com", port: 443)
        hy2.password = "pw"
        var wg = ProxyConfig(name: "wg", proto: .wireguard, address: "5.6.7.8", port: 51820)
        wg.privateKey = "aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvMDA="
        wg.peerPublicKey = "aGVsbG9oZWxsb2hlbGxvaGVsbG9oZWxsb2hlbGxvMDA="
        let config = ProxyProbe.singBoxConfig([hy2, wg], ports: [20003, 20004],
                                              interface: "en0")
        let (status, output) = try check(config, engine: .singbox)
        XCTAssertEqual(status, 0, output)
    }

    func testEveryNodeGetsItsOwnInboundAndRoute() {
        let config = ProxyProbe.xrayConfig([vless(), vless()], ports: [1, 2], interface: nil)
        let inbounds = config["inbounds"] as! [[String: Any]]
        let rules = (config["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(inbounds.map { $0["port"] as? Int }, [1, 2])
        XCTAssertEqual(rules.map { $0["outboundTag"] as? String },
                       [ProxyProbe.outboundTag(0), ProxyProbe.outboundTag(1)])
    }

    func testFreePortsAreDistinct() {
        let ports = ProxyProbe.freePorts(32)
        XCTAssertEqual(ports.count, 32)
        XCTAssertEqual(Set(ports).count, 32)
    }

    func testFakeIPsAreRecognised() {
        XCTAssertTrue(DirectResolver.isFakeIP("198.18.0.5"))
        XCTAssertTrue(DirectResolver.isFakeIP("198.19.255.1"))
        XCTAssertFalse(DirectResolver.isFakeIP("198.20.0.1"))
        XCTAssertFalse(DirectResolver.isFakeIP("1.1.1.1"))
    }

    func testDNSAnswersAreParsed() {
        // id 0x1234, 1 question (a.io A IN), 1 answer: pointer to the name,
        // A IN, TTL 60, 4 bytes 9.8.7.6.
        let message: [UInt8] = [0x12, 0x34, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0,
                                1, 0x61, 2, 0x69, 0x6f, 0, 0, 1, 0, 1,
                                0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 9, 8, 7, 6]
        XCTAssertEqual(DirectResolver.parseAnswers(message, id: 0x1234), ["9.8.7.6"])
        XCTAssertEqual(DirectResolver.parseAnswers(message, id: 0x9999), [])
    }

    func testTheTestURLFallsBackWhenUnusable() {
        var settings = AppSettings()
        settings.pingURL = "not a url"
        XCTAssertEqual(settings.effectivePingURL.absoluteString, PingMode.defaultURL)
        settings.pingURL = "https://cp.cloudflare.com/"
        XCTAssertEqual(settings.effectivePingURL.host, "cp.cloudflare.com")
    }
}

/// End to end: a local Shadowsocks server stands in for a node, and the probe
/// times a real request through the throwaway core in front of it.
final class PingProbeLiveTests: XCTestCase {

    func testARequestThroughALocalNodeIsTimed() async throws {
        try XCTSkipUnless(CoreBinary.locate(for: .xray) != nil, "core not fetched")
        let binary = try XCTUnwrap(CoreBinary.locate(for: .xray))
        let url = URL(string: PingMode.defaultURL)!
        let direct = try? await URLSession.shared.data(from: url)
        try XCTSkipIf(direct == nil, "no network")

        let port = ProxyProbe.freePorts(1)[0]
        let server: [String: Any] = [
            "log": ["loglevel": "none"],
            "inbounds": [[
                "listen": "127.0.0.1", "port": port, "protocol": "shadowsocks",
                "settings": ["method": "chacha20-ietf-poly1305", "password": "probe",
                             "network": "tcp,udp"]
            ]],
            "outbounds": [["protocol": "freedom"]]
        ]
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ping-server-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: server).write(to: file)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["run", "-c", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); try? FileManager.default.removeItem(at: file) }
        try await Task.sleep(nanoseconds: 500_000_000)

        var node = ProxyConfig(name: "local", proto: .shadowsocks, address: "127.0.0.1", port: port)
        node.method = "chacha20-ietf-poly1305"
        node.password = "probe"
        var dead = node
        dead.id = UUID()
        dead.password = "wrong"

        let results = Results()
        let request = ProxyProbe.Request(url: url, method: "GET", timeout: 5, interface: nil)
        await ProxyProbe.measure([node, dead], request: request) { batch in
            await results.merge(batch)
        }
        let all = await results.all
        XCTAssertNotNil(all[node.id] ?? nil, "a working node gets a number")
        XCTAssertNil(all[dead.id] ?? nil, "a node with the wrong key does not")
    }

    actor Results {
        var all: [UUID: Int?] = [:]
        func merge(_ batch: [UUID: Int?]) { all.merge(batch) { $1 } }
    }
}
