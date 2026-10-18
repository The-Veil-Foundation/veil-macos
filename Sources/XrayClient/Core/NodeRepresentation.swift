import Foundation

/// A node, written out in whichever form the user wants to read or edit it in.
///
/// Veil parses share links and subscription bodies into `ProxyConfig`, and that
/// is the only thing the app has ever shown. A WireGuard peer pasted as a
/// `wg-quick` file then becomes a name and nothing else: there is no way to see
/// what was understood, and no way to correct it. These are the three forms a
/// node can be shown in, each of which reads back into a node.
enum NodeRepresentation {

    enum Kind: String, CaseIterable, Identifiable {
        /// `wg-quick` text with `[Interface]` and `[Peer]`, as every WireGuard
        /// client writes it.
        case wireguard
        /// The outbound its core will actually run.
        case json
        /// The share link.
        case link

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wireguard: return "WireGuard config"
            case .json:      return "Outbound JSON"
            case .link:      return "Share link"
            }
        }
    }

    enum Failure: LocalizedError, Equatable {
        case notALink(String)
        case notJSON
        case noNodeInJSON
        case incompleteConf

        var errorDescription: String? {
            switch self {
            case .notALink(let reason):
                return reason
            case .notJSON:
                return "This is not valid JSON."
            case .noNodeInJSON:
                return "This JSON does not describe a server Veil can connect to."
            case .incompleteConf:
                return "This WireGuard config is missing an address, a private key or a peer."
            }
        }
    }

    /// The forms this node has, in the order they should be offered: the one
    /// closest to how the node is normally written comes first.
    static func kinds(for server: ProxyConfig) -> [Kind] {
        server.proto == .wireguard ? [.wireguard, .json, .link] : [.json, .link]
    }

    // MARK: - Writing

    static func text(_ kind: Kind, for server: ProxyConfig) -> String {
        switch kind {
        case .link:
            return LinkBuilder.link(for: server)
        case .json:
            #if os(macOS)
            let object = SingBoxOutbound.isEndpoint(server)
                ? SingBoxOutbound.endpoint(server, tag: server.name)
                : SingBoxOutbound.outbound(server, tag: server.name)
            #else
            // Xray is the only core on iOS, so the outbound shown is the one
            // it will run.
            let object = XrayConfigBuilder.outbound(server, tag: server.name)
            #endif
            guard let data = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else { return "{}" }
            return text
        case .wireguard:
            return wireGuardConf(for: server)
        }
    }

    /// `wg-quick` text, the form the peer was most likely handed over in.
    private static func wireGuardConf(for server: ProxyConfig) -> String {
        var lines = ["[Interface]"]
        if let key = server.privateKey { lines.append("PrivateKey = \(key)") }
        if let addresses = server.localAddresses, !addresses.isEmpty {
            lines.append("Address = \(addresses.joined(separator: ", "))")
        }
        if let mtu = server.mtu { lines.append("MTU = \(mtu)") }

        lines.append("")
        lines.append("[Peer]")
        if let key = server.peerPublicKey { lines.append("PublicKey = \(key)") }
        if let psk = server.presharedKey { lines.append("PresharedKey = \(psk)") }
        lines.append("Endpoint = \(server.address):\(server.port)")
        lines.append("AllowedIPs = \(server.effectiveAllowedIPs.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    // MARK: - Reading

    /// Reads an edited representation back into a node, keeping everything the
    /// representation does not carry: the node's id above all, so that the
    /// groups, rules and annotations naming it still find it.
    static func parse(_ kind: Kind, text: String, keeping original: ProxyConfig) throws -> ProxyConfig {
        var parsed: ProxyConfig
        switch kind {
        case .link:
            do {
                parsed = try LinkParser.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                throw Failure.notALink(error.localizedDescription)
            }
        case .json:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                throw Failure.notJSON
            }
            // Accept either one outbound or a whole config with several, so a
            // block copied out of a panel's own file can be pasted as it is.
            let outbounds: [[String: Any]]
            if let single = object as? [String: Any] {
                if let list = single["outbounds"] as? [[String: Any]] {
                    outbounds = list + ((single["endpoints"] as? [[String: Any]]) ?? [])
                } else {
                    outbounds = [single]
                }
            } else if let list = object as? [[String: Any]] {
                outbounds = list
            } else {
                throw Failure.noNodeInJSON
            }
            // Xray names an outbound's protocol under `protocol`, sing-box
            // under `type`; either is accepted on either platform.
            let isXray = outbounds.contains { $0["protocol"] != nil }
            let nodes = isXray
                ? SubscriptionPayloadParser.xrayServers(outbounds)
                : SubscriptionPayloadParser.singBoxServers(outbounds)
            guard let first = nodes.first else {
                throw Failure.noNodeInJSON
            }
            parsed = first
        case .wireguard:
            guard let node = LinkParser.parseWireGuardConf(text, name: original.name) else {
                throw Failure.incompleteConf
            }
            parsed = node
        }

        parsed.id = original.id
        if parsed.name.isEmpty { parsed.name = original.name }
        return parsed
    }
}
