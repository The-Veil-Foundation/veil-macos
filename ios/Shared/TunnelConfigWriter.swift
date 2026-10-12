import Foundation

/// Renders the outbound graph into the Xray configuration the tunnel provider
/// boots from, and drops it in the shared container.
///
/// The iOS config differs from the desktop one in its inbound: instead of local
/// SOCKS/HTTP listeners it uses Xray's native layer-3 `tun` inbound, which reads
/// the descriptor NetworkExtension handed us. The outbounds, the transports and
/// Reality are built by the same code as on the Mac.
enum TunnelConfigWriter {

    /// Builds the config + session sidecar and writes both to the app group.
    @discardableResult
    static func write(profile: XrayProfile, session: TunnelSession) throws -> String {
        let json = try XrayProfileBuilder.jsonString(profile)
        try Data(json.utf8).write(to: AppGroup.configURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try session.write()
        return json
    }

    /// Reads back the config the extension should boot.
    static func loadConfig() throws -> String {
        let data = try Data(contentsOf: AppGroup.configURL)
        return String(decoding: data, as: UTF8.self)
    }
}
