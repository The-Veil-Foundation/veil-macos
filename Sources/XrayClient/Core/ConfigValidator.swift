import Foundation

/// Runs an edited configuration past the core that will execute it.
///
/// The cores can check a config without running it — `xray run -test` and
/// `sing-box check` — and their complaints name the offending field. Showing
/// that message is the difference between a typo caught while it is being typed
/// and a connection that never comes up for no stated reason.
enum ConfigValidator {

    enum Outcome: Equatable {
        case ok
        /// The core refused it, with its own message.
        case failed(String)
        /// The core is not on disk. A development build with unfetched
        /// binaries, not something the user can act on.
        case unavailable
    }

    #if os(macOS)
    static func check(_ server: ProxyConfig) async -> Outcome {
        // The cores do not mind a node with no credential in it: sing-box will
        // happily dial a Hysteria2 server with an empty password, and the
        // server answers with its masquerade page, which the core reports as
        // "authentication failed, status code: 404" — a message about the far
        // end when the problem is a link that never carried an auth string.
        // Say so here instead.
        if let missing = missingCredential(server) { return .failed(missing) }

        let engine = server.engine
        guard let binary = CoreBinary.locate(for: engine) else { return .unavailable }

        let data: Data
        do {
            switch engine {
            case .singbox:
                var profile = SingBoxProfile()
                profile.servers = [server]
                profile.defaultTarget = .server(server.id)
                data = try SingBoxProfileBuilder.jsonData(profile)
            case .xray:
                data = try XrayConfigBuilder.jsonData(for: server)
            }
        } catch {
            return .failed(error.localizedDescription)
        }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("veil-check-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            return .failed(error.localizedDescription)
        }

        let arguments = engine == .singbox
            ? ["check", "-c", file.path]
            : ["run", "-test", "-config", file.path]
        return await run(binary, arguments)
    }

    #endif

    /// The credential this protocol cannot connect without, when it is absent.
    static func missingCredential(_ server: ProxyConfig) -> String? {
        func blank(_ value: String?) -> Bool {
            (value ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        switch server.proto {
        case .vless, .vmess:
            return blank(server.uuid) ? "This node has no UUID." : nil
        case .trojan, .shadowsocks, .hysteria2, .anytls:
            return blank(server.password) ? "This node has no password." : nil
        case .tuic:
            if blank(server.uuid) { return "This node has no UUID." }
            return blank(server.password) ? "This node has no password." : nil
        case .wireguard:
            if blank(server.privateKey) { return "This node has no private key." }
            return blank(server.peerPublicKey) ? "This node has no peer public key." : nil
        }
    }

    #if os(macOS)
    private static func run(_ binary: URL, _ arguments: [String]) async -> Outcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                return continuation.resume(returning: .failed(error.localizedDescription))
            }
            // Read before waiting: a core with plenty to say would otherwise
            // fill the pipe and block forever.
            let output = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()

            guard process.terminationStatus != 0 else {
                return continuation.resume(returning: .ok)
            }
            let message = String(data: output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            continuation.resume(returning: .failed(message.isEmpty
                ? "The core refused this configuration."
                : message))
        }
    }
    #endif
}
