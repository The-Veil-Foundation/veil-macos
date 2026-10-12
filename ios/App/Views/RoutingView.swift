import SwiftUI

/// Where traffic goes, at every level of detail: the preset, the user's own
/// rules, the community lists, the groups a rule can point at, the resolver,
/// and the geo database the older matchers need.
struct RoutingView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(Loc.self) private var loc

    private var geo = GeoAssetManager.shared
    private var lists = CommunityListManager.shared

    // Spelled out because private stored properties make the synthesized
    // initializer private too.
    init() {}

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                if tunnel.hasUnappliedChanges(store: store) {
                    Section {
                        HStack {
                            Label(loc("Changes apply on the next connect or reconnect."),
                                  systemImage: "arrow.clockwise.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(loc("Apply now")) {
                                store.save()
                                Task { await tunnel.applyChanges(store: store) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }

                Section {
                    Picker(loc("Preset"), selection: $store.settings.routingPreset) {
                        ForEach(RoutingPreset.allCases) { Text(loc($0.title)).tag($0) }
                    }
                    .onChange(of: store.settings.routingPreset) { _, _ in
                        store.save()
                        Task { await downloadGeoIfNeeded() }
                    }
                    Text(loc(store.settings.routingPreset.subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    presetExplainer

                    Toggle(isOn: $store.settings.blockAds) {
                        HintLabel(loc("Block ads & trackers"),
                                  loc("Drops connections to known advertising and tracking domains before your own rules are consulted."))
                    }
                    .onChange(of: store.settings.blockAds) { _, _ in
                        store.save()
                        Task { await downloadGeoIfNeeded() }
                    }
                } header: {
                    Text(loc("Mode"))
                } footer: {
                    Text(loc("Your own rules below run under every preset, after the LAN bypass and before the preset's country rules."))
                }

                Section {
                    NavigationLink {
                        RulesListView()
                    } label: {
                        row(loc("Rules"), icon: "arrow.triangle.branch",
                            value: "\(store.settings.customRules.count)")
                    }
                    NavigationLink {
                        CommunityListsView()
                    } label: {
                        row(loc("Lists"), icon: "list.bullet.rectangle",
                            value: "\(store.settings.communityLists.count)")
                    }
                    NavigationLink {
                        GroupsView()
                    } label: {
                        row(loc("Groups"), icon: "square.stack.3d.up",
                            value: "\(store.allGroups.count)")
                    }
                    NavigationLink {
                        DNSView()
                    } label: {
                        row(loc("DNS"), icon: "globe",
                            value: store.settings.dns.enabled ? loc("On") : loc("Off"))
                    }
                    NavigationLink {
                        GeoDatabaseView()
                    } label: {
                        row(loc("Database"), icon: "externaldrive",
                            value: geo.hasAssets ? loc("Downloaded") : loc("Not downloaded"))
                    }
                }

                if store.routingNeedsGeoAssets && !geo.hasAssets {
                    Section {
                        Label(loc("This preset needs the rule database. Download it to use geosite/geoip rules."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button(loc("Download")) { Task { await downloadGeo() } }
                            .disabled(geo.isDownloading)
                    }
                }
            }
            .navigationTitle(loc("Routing"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ title: String, icon: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    /// What the chosen preset puts in front of and behind the user's own
    /// rules. A preset that only describes itself in a sentence is a preset
    /// whose effect has to be guessed at.
    @ViewBuilder
    private var presetExplainer: some View {
        let preset = store.settings.routingPreset
        let guards = preset.guardRules(blockAds: store.settings.blockAds)
        let after = preset.presetRules()
        if !guards.isEmpty || !after.isEmpty {
            DisclosureGroup(loc("What this preset does")) {
                VStack(alignment: .leading, spacing: 6) {
                    if !guards.isEmpty {
                        Text(loc("Before your rules")).font(.caption2).foregroundStyle(.secondary)
                        ForEach(guards) { presetLine($0) }
                    }
                    if !after.isEmpty {
                        Text(loc("After your rules")).font(.caption2).foregroundStyle(.secondary)
                        ForEach(after) { presetLine($0) }
                    }
                }
                .padding(.vertical, 2)
            }
            .font(.caption)
        }
    }

    private func presetLine(_ rule: RoutingRule) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(loc(rule.name))
                Text(verbatim: "→").foregroundStyle(.secondary)
                Text(loc(rule.target.title(servers: store.allServers, groups: store.allGroups)))
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: (rule.domains + rule.ips).joined(separator: ", "))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    private func downloadGeoIfNeeded() async {
        guard store.routingNeedsGeoAssets, !geo.hasAssets, !geo.isDownloading else { return }
        await downloadGeo()
    }

    private func downloadGeo() async {
        await geo.download(source: store.settings.geoSource,
                           customGeoip: store.settings.customGeoipURL,
                           customGeosite: store.settings.customGeositeURL)
    }
}

extension RuleTarget {
    /// Display name, resolved against the current servers and groups.
    func title(servers: [ProxyConfig], groups: [ServerGroup]) -> String {
        if let builtIn = builtInTitle { return builtIn }
        switch self {
        case .server(let id):
            return servers.first { $0.id == id }?.name ?? "Missing server"
        case .group(let id):
            return groups.first { $0.id == id }?.name ?? "Missing group"
        default:
            return "Proxy"
        }
    }
}
