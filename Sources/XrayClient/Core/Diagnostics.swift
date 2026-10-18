import Foundation
#if os(macOS)
import VeilHelperKit
#endif

/// Builds the "Export diagnostics" report.
///
/// The point of the button is that a user can paste the result into an issue
/// without having to read it first, so everything that could identify them or
/// let someone else use their subscription is removed here rather than left to
/// the reader: URLs keep only their host, HWIDs become fingerprints, and the
/// log text goes through the same redaction as everything else.
@MainActor
enum Diagnostics {

    static func report(store: ServerStore, logText: String = "") -> String {
        var lines: [String] = []

        lines.append("# Veil diagnostics")
        lines.append("generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("## Build")
        lines.append("app: Veil \(AppVersion.current)")
        lines.append("os: \(DeviceInfo.osName) \(DeviceInfo.osVersion)")
        lines.append("model: \(DeviceInfo.model)")
        lines.append("hwid: \(Redaction.fingerprint(DeviceID.hwid))")
        lines.append("keychain: \(Keychain.isAvailable ? "available" : "unavailable")")
        lines.append("")

        lines.append("## Settings")
        #if os(macOS)
        lines.append("mode: \(store.settings.mode.rawValue)")
        lines.append("socks port: \(store.settings.socksPort)")
        lines.append("http port: \(store.settings.httpPort)")
        #else
        lines.append("mode: network extension")
        lines.append("mtu: \(store.settings.tunnelMTU)")
        lines.append("ipv6: \(store.settings.ipv6Enabled)")
        lines.append("dns in tunnel: \(store.settings.dns.enabled)")
        lines.append("groups: \(store.settings.serverGroups.count)")
        lines.append("community lists: \(store.settings.communityLists.count)")
        #endif
        lines.append("routing preset: \(store.settings.routingPreset.rawValue)")
        lines.append("custom rules: \(store.settings.customRules.count)")
        lines.append("block ads: \(store.settings.blockAds)")
        lines.append("geo source: \(store.settings.geoSource.rawValue)")
        lines.append("auto-update: \(store.settings.autoUpdateSubscriptions) "
                     + "every \(store.settings.autoUpdateIntervalHours)h")
        lines.append("send hwid: \(store.settings.sendHwid)")
        lines.append("user-agent override: \(store.settings.userAgentOverride.isEmpty ? "no" : "yes")")
        lines.append("")

        #if os(macOS)
        lines.append("## Helper")
        lines.append("installed: \(PrivilegedHelper.isInstalled)")
        lines.append("protocol: \(PrivilegedHelper.installedVersion.map(String.init) ?? "unreachable") "
                     + "(app expects \(VeilHelperInfo.protocolVersion))")
        lines.append("tunnel up: \(PrivilegedHelper.tunnelIsUp)")
        lines.append("")
        #endif

        lines.append("## Subscriptions (\(store.subscriptions.count))")
        for sub in store.subscriptions {
            lines.append("- \(sub.name)")
            lines.append("  host: \(sub.url.map(Redaction.url) ?? "local")")
            lines.append("  servers: \(sub.servers.count)")
            if let format = sub.lastFormat { lines.append("  format: \(format.rawValue)") }
            if let status = sub.hwidStatus { lines.append("  hwid: \(status.rawValue)") }
            if let interval = sub.updateIntervalHours { lines.append("  panel interval: \(interval)h") }
            if let updated = sub.lastUpdated {
                lines.append("  last updated: \(ISO8601DateFormatter().string(from: updated))")
            }
            if let fraction = sub.usageFraction {
                lines.append("  traffic used: \(Int(fraction * 100))%")
            }
        }
        lines.append("")

        lines.append("## Protocols in use")
        let counts = Dictionary(grouping: store.allServers, by: \.proto)
            .mapValues(\.count)
            .sorted { $0.key.rawValue < $1.key.rawValue }
        for (proto, count) in counts {
            lines.append("\(proto.rawValue): \(count)")
        }
        lines.append("")

        if !logText.isEmpty {
            lines.append("## Log (redacted)")
            lines.append(Redaction.text(logText, knownSecrets: knownSecrets(store)))
        }

        // Belt and braces: the whole report goes through redaction as well, so
        // a field added later cannot leak by being forgotten here.
        return Redaction.text(lines.joined(separator: "\n"),
                              knownSecrets: knownSecrets(store))
    }

    /// Literal values that must never appear in the output, whatever produced
    /// them: subscription URLs, HWIDs and per-server credentials.
    private static func knownSecrets(_ store: ServerStore) -> [String] {
        var secrets: [String] = [DeviceID.hwid]
        for sub in store.subscriptions {
            if let url = sub.url { secrets.append(url) }
            secrets.append(DeviceID.hwid(for: sub.id))
        }
        for server in store.allServers {
            secrets.append(contentsOf: [server.uuid, server.password,
                                        server.privateKey, server.presharedKey,
                                        server.publicKey, server.obfsPassword]
                .compactMap { $0 })
        }
        return secrets
    }
}
