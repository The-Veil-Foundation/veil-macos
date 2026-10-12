import SwiftUI

/// The resolver: which servers answer, which names go where, and what leaks.
///
/// DNS is where a tunnel usually leaks: the traffic goes through the proxy but
/// the lookup that preceded it went to the ISP in clear text. The defaults
/// resolve names through the tunnel.
struct DNSView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    var body: some View {
        @Bindable var store = store
        let dns = $store.settings.dns

        Form {
            Section {
                Toggle(loc("Handle DNS in the tunnel"), isOn: dns.enabled)
                if !store.settings.dns.enabled {
                    Label(loc("With this off, lookups travel through the tunnel as ordinary traffic to the servers in Settings, and the rules below do nothing."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // The bootstrap resolver is deliberately absent: picking it
                // here would quietly send every lookup around the tunnel.
                Picker(loc("Answer with"), selection: dns.finalTag) {
                    ForEach(store.settings.dns.finalCandidates) { server in
                        Text(server.tag).tag(server.tag)
                    }
                }
                Picker(loc("Address family"), selection: dns.strategy) {
                    Text(loc("Prefer IPv4")).tag("prefer_ipv4")
                    Text(loc("Prefer IPv6")).tag("prefer_ipv6")
                    Text(loc("IPv4 only")).tag("ipv4_only")
                    Text(loc("IPv6 only")).tag("ipv6_only")
                }
                Toggle(loc("Serve stale answers while refreshing"), isOn: dns.optimistic)
                Toggle(loc("Disable cache"), isOn: dns.disableCache)
            } header: {
                Text(loc("Resolver"))
            }

            Section {
                Toggle(loc("FakeIP"), isOn: dns.fakeIPEnabled)
                if store.settings.dns.fakeIPEnabled {
                    LabeledContent("IPv4") {
                        TextField("198.18.0.0/15", text: dns.fakeIPv4Range)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    LabeledContent("IPv6") {
                        TextField("fc00::/18", text: dns.fakeIPv6Range)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
            } footer: {
                Text(loc("Answers instantly from a private range and keeps the domain visible to rules. Breaks software that resolves names itself."))
            }

            Section {
                ForEach(store.settings.dns.servers) { server in
                    NavigationLink {
                        DNSServerEditor(serverID: server.id)
                    } label: {
                        serverRow(server)
                    }
                    .deleteDisabled(DNSView.builtinTags.contains(server.tag))
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.settings.dns.servers[$0].id }
                    store.settings.dns.servers.removeAll {
                        ids.contains($0.id) && !DNSView.builtinTags.contains($0.tag)
                    }
                }
                Button {
                    store.settings.dns.servers.append(
                        DNSServerEntry(tag: uniqueTag(), kind: .https, server: "", path: "/dns-query"))
                } label: {
                    Label(loc("Add resolver"), systemImage: "plus")
                }
            } header: {
                Text(loc("Servers"))
            } footer: {
                Text(loc("Xray has no DNS over TLS; use DNS over HTTPS or QUIC for an encrypted resolver."))
            }

            Section {
                ForEach(store.settings.dns.rules) { rule in
                    NavigationLink {
                        DNSRuleEditor(ruleID: rule.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? loc("Rule") : rule.name)
                                .foregroundStyle(rule.enabled ? .primary : .secondary)
                            Text(verbatim: (rule.reject ? loc("Refused") : rule.serverTag)
                                 + " · " + rule.domains.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.settings.dns.rules[$0].id }
                    store.settings.dns.rules.removeAll { ids.contains($0.id) }
                }
                .onMove { from, to in store.settings.dns.rules.move(fromOffsets: from, toOffset: to) }
                Button {
                    store.settings.dns.rules.append(
                        DNSRule(name: "", serverTag: store.settings.dns.servers.first?.tag ?? ""))
                } label: {
                    Label(loc("Add DNS rule"), systemImage: "plus")
                }
            } header: {
                Text(loc("DNS rules — first match wins"))
            } footer: {
                Text(loc("Same matchers as a routing rule, minus the ones that need an address: a name is being resolved, so there is no destination IP yet."))
            }

            Section {
                Button(loc("Restore defaults"), role: .destructive) {
                    store.settings.dns = DNSSettings()
                }
            }
        }
        .navigationTitle(loc("DNS"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { store.save() }
    }

    private func serverRow(_ server: DNSServerEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(server.tag)
                if server.tag == store.settings.dns.finalTag {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
            }
            Text(verbatim: loc(server.kind.title)
                 + (server.server.isEmpty ? "" : " · \(server.server)"))
                .font(.caption2)
                .foregroundStyle(server.kind == .tls ? Color.orange : Color.secondary)
        }
    }

    static let builtinTags: Set<String> = [
        DNSSettings.Builtin.remote,
        DNSSettings.Builtin.local,
        DNSSettings.Builtin.bootstrap,
        DNSSettings.Builtin.fakeIP
    ]

    private func uniqueTag() -> String {
        var index = 1
        while store.settings.dns.servers.contains(where: { $0.tag == "dns-\(index)" }) { index += 1 }
        return "dns-\(index)"
    }
}

// MARK: - One resolver

struct DNSServerEditor: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    let serverID: UUID
    @State private var entry = DNSServerEntry(tag: "")
    @State private var loaded = false

    /// Xray speaks no DNS over TLS, so it is not offered here.
    private static let kinds: [DNSServerEntry.Kind] = [.https, .quic, .udp, .tcp, .local, .h3]

    var body: some View {
        let isBuiltin = DNSView.builtinTags.contains(entry.tag)
        let isBootstrap = entry.tag == DNSSettings.Builtin.bootstrap

        Form {
            Section {
                LabeledContent(loc("Name")) {
                    TextField("", text: $entry.tag)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        // Renaming a built-in would orphan the rules that name it.
                        .disabled(isBuiltin)
                }
                Picker(loc("Protocol"), selection: $entry.kind) {
                    ForEach(Self.kinds + (Self.kinds.contains(entry.kind) ? [] : [entry.kind]), id: \.self) { kind in
                        Text(loc(kind.title)).tag(kind)
                    }
                }
                if entry.kind.needsServer {
                    LabeledContent(loc("Host or IP")) {
                        TextField("1.1.1.1", text: $entry.server)
                            .multilineTextAlignment(.trailing)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    LabeledContent(loc("Port")) {
                        TextField(loc("Default"), value: $entry.port, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    if entry.kind.needsPath {
                        LabeledContent(loc("Path")) {
                            TextField("/dns-query", text: $entry.path)
                                .multilineTextAlignment(.trailing)
                                .font(.callout.monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                    }
                }
            } footer: {
                if entry.kind == .tls {
                    Text(loc("Xray has no DNS over TLS; use DNS over HTTPS or QUIC for an encrypted resolver."))
                        .foregroundStyle(.orange)
                } else if entry.kind == .h3 {
                    Text(loc("Xray asks this resolver over HTTP/2, which every public DNS-over-HTTP/3 resolver also serves."))
                } else if entry.kind == .quic {
                    Text(loc("DNS over QUIC always goes direct in Xray."))
                }
            }

            if entry.kind != .fakeip && entry.kind != .local {
                Section {
                    if isBootstrap {
                        LabeledContent(loc("Queries go through"), value: loc("Direct"))
                    } else {
                        DetourPicker(detour: $entry.detour)
                    }
                } footer: {
                    Text(loc("A resolver reached through the proxy hides your lookups; one on direct is faster."))
                }
            }
        }
        .navigationTitle(entry.tag.isEmpty ? loc("Resolver") : entry.tag)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            if let stored = store.settings.dns.servers.first(where: { $0.id == serverID }) {
                entry = stored
            }
            loaded = true
        }
        .onChange(of: entry) { _, edited in
            guard loaded,
                  let index = store.settings.dns.servers.firstIndex(where: { $0.id == serverID })
            else { return }
            store.settings.dns.servers[index] = edited
        }
        .onDisappear { store.save() }
    }
}

/// Which outbound a resolver's own queries take.
struct DetourPicker: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Binding var detour: String

    var body: some View {
        Picker(loc("Queries go through"), selection: $detour) {
            Text(loc("Default route")).tag("")
            Text(loc("Proxy")).tag(ProfileTags.defaultSelector)
            Text(loc("Direct")).tag(ProfileTags.direct)
            if !store.allGroups.isEmpty {
                Section(loc("Groups")) {
                    ForEach(store.allGroups) { group in
                        Text(group.name.isEmpty ? loc("Group") : group.name)
                            .tag(ProfileTags.group(group.id))
                    }
                }
            }
            let runnable = store.allServers.filter(\.xraySupported)
            if !runnable.isEmpty {
                Section(loc("Servers")) {
                    ForEach(runnable) { server in
                        Text(server.name).tag(ProfileTags.server(server.id))
                    }
                }
            }
            if !knownDetours.contains(detour) {
                Text(loc("Missing outbound")).tag(detour)
            }
        }
        .pickerStyle(.navigationLink)
    }

    private var knownDetours: Set<String> {
        var tags: Set<String> = ["", ProfileTags.defaultSelector, ProfileTags.direct]
        tags.formUnion(store.allGroups.map { ProfileTags.group($0.id) })
        tags.formUnion(store.allServers.filter(\.xraySupported).map { ProfileTags.server($0.id) })
        return tags
    }
}

// MARK: - One DNS rule

struct DNSRuleEditor: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    let ruleID: UUID
    @State private var rule = DNSRule()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField(loc("Rule name"), text: $rule.name)
                Toggle(loc("Enabled"), isOn: $rule.enabled)
                Toggle(loc("Refuse these names"), isOn: $rule.reject)
                if !rule.reject {
                    Picker(loc("Answer with"), selection: $rule.serverTag) {
                        ForEach(store.settings.dns.servers) { server in
                            Text(server.tag).tag(server.tag)
                        }
                    }
                }
            }
            Section {
                TokenListEditor(values: $rule.domains,
                                placeholder: "example.com, geosite:google")
            } header: {
                Text(loc("Domains"))
            }
        }
        .navigationTitle(rule.name.isEmpty ? loc("Rule") : rule.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            if let stored = store.settings.dns.rules.first(where: { $0.id == ruleID }) {
                rule = stored
            }
            loaded = true
        }
        .onChange(of: rule) { _, edited in
            guard loaded,
                  let index = store.settings.dns.rules.firstIndex(where: { $0.id == ruleID })
            else { return }
            store.settings.dns.rules[index] = edited
        }
        .onDisappear { store.save() }
    }
}
