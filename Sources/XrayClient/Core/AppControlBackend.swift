// macOS-only.
#if os(macOS)
import Foundation

/// Connects the control API to the running app.
///
/// The API deliberately reaches only the routing surface: rules, groups, DNS,
/// the preset, and connect/disconnect. Subscriptions, their URLs and the
/// device identifier stay out of it — a caller does not need them to configure
/// where traffic goes, and an API that cannot read a secret cannot leak one.
@MainActor
final class AppControlBackend: ControlBackend {

    enum Failure: LocalizedError {
        case noSuchServer(UUID)
        var errorDescription: String? {
            switch self {
            case .noSuchServer(let id): return "no server with id \(id.uuidString)"
            }
        }
    }

    private let store: ServerStore
    private let connection: ConnectionManager

    init(store: ServerStore, connection: ConnectionManager) {
        self.store = store
        self.connection = connection
    }

    // MARK: Reading

    func state() -> ControlState {
        let connectionLabel: String
        switch connection.state {
        case .disconnected: connectionLabel = "disconnected"
        case .connecting:   connectionLabel = "connecting"
        case .connected:    connectionLabel = "connected"
        case .failed(let message): connectionLabel = "failed: \(message)"
        }
        let uptime = connection.connectedSince.map { Int(Date().timeIntervalSince($0)) }
        let native = store.settings.useNativeTun
        return ControlState(
            version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
            connection: connectionLabel,
            mode: store.settings.mode.rawValue,
            activeServerID: connection.activeServerID,
            activeServerName: connection.activeServerName,
            uptimeSeconds: uptime,
            preset: store.settings.routingPreset.rawValue,
            ruleCount: store.settings.customRules.count,
            groupCount: store.settings.serverGroups.count,
            serverCount: store.allServers.count,
            nativeCore: native,
            // Matching an application means seeing the process that opened the
            // socket, which only happens when the core owns the interface.
            processRoutingAvailable: native && store.settings.mode == .tun)
    }

    func servers() -> [ControlServerInfo] {
        store.subscriptions.flatMap { subscription in
            subscription.servers.map { server in
                ControlServerInfo(id: server.id,
                                  name: server.name,
                                  proto: server.proto.rawValue,
                                  address: server.address,
                                  port: server.port,
                                  engine: server.engine == .singbox ? "sing-box" : "xray",
                                  group: subscription.name,
                                  tag: ProfileTags.server(server.id))
            }
        }
    }

    func apps(matching query: String, limit: Int) -> [ControlApp] {
        let catalog = ProcessCatalog.shared
        // The catalog is normally warmed at launch, but a caller that reaches
        // /v1/apps first (or after a headless start) must not see an empty list.
        if catalog.entries.isEmpty {
            Task { await catalog.reload() }
        }
        return catalog.search(query).prefix(limit).map { entry in
            ControlApp(name: entry.displayName,
                       processName: entry.executableName,
                       path: entry.executablePath,
                       bundleID: entry.bundleID,
                       running: entry.isRunning)
        }
    }

    /// Where the servers came from, with the URLs left out — the path of a
    /// subscription URL is the access token, and a caller configuring routing
    /// never needs it.
    func sources() -> [ControlSource] {
        store.subscriptions.map { subscription in
            ControlSource(id: subscription.id,
                          name: subscription.name,
                          serverCount: subscription.servers.count,
                          groupCount: subscription.declaredGroups.count,
                          lastUpdated: subscription.lastUpdated,
                          skipped: (subscription.lastSkipped ?? []).map {
                              ControlSkipNote(label: $0.label, count: $0.count)
                          },
                          hasStoredURL: subscription.hasStoredURL ?? (subscription.url != nil))
        }
    }

    func refreshSources() {
        let store = store
        Task { await SubscriptionService.refreshAll(store) }
    }

    func annotations() -> [UUID: NodeAnnotation] { store.settings.nodeAnnotations }

    func setAnnotations(_ annotations: [UUID: NodeAnnotation]) {
        store.settings.nodeAnnotations = annotations
        persist()
    }

    func log() -> String { connection.logs }

    func diagnostics() -> String {
        Diagnostics.report(store: store, logText: connection.logs)
    }

    /// What the Apply now button does: hand the edited settings to the live
    /// connection instead of waiting for the next connect.
    func apply() {
        persist()
        connection.reconnectForRoutingChange()
    }

    func rules() -> [RoutingRule] { store.settings.customRules }
    /// Both the user's groups and the ones the panels declared: the API
    /// answers with the outbound graph as it is built, not with the half of it
    /// that happens to be stored in settings.
    func groups() -> [ServerGroup] { store.settings.serverGroups + store.declaredGroups }
    func dns() -> DNSSettings { store.settings.dns }
    func preset() -> RoutingPreset { store.settings.routingPreset }

    func renderedProfile() throws -> String {
        var input = ProfileAssembler.Input()
        input.servers = store.allServers
        input.settings = store.settings
        input.activeServerID = connection.activeServerID ?? store.selectedServerID
        input.ports = connection.ports
        input.includeTun = store.settings.mode == .tun
        if input.includeTun {
            input.physicalResolvers = PhysicalInterface.physicalResolvers()
        }
        input.subscriptionGroups = store.declaredGroups
        let data = try SingBoxProfileBuilder.jsonData(ProfileAssembler.profile(input))
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: Writing

    func setRules(_ rules: [RoutingRule]) {
        store.settings.customRules = rules
        persist()
    }

    func setGroups(_ groups: [ServerGroup]) {
        store.settings.serverGroups = groups
        persist()
    }

    func setDNS(_ dns: DNSSettings) {
        store.settings.dns = dns
        persist()
    }

    func setPreset(_ preset: RoutingPreset) {
        store.settings.routingPreset = preset
        persist()
    }

    func connect(serverID: UUID) throws {
        guard let server = store.server(withID: serverID) else {
            throw Failure.noSuchServer(serverID)
        }
        store.select(serverID)
        connection.connect(to: server)
    }

    func disconnect() {
        connection.disconnect()
    }

    /// Saves, and hands the new rules to the connection manager so a caller
    /// that goes on to reconnect gets what it just wrote.
    private func persist() {
        store.save()
        connection.applyStore(store)
        connection.routingRules = store.settings.effectiveRoutingRules
    }
}
#endif
