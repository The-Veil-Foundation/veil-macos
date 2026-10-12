import SwiftUI

/// The user's own rules, top to bottom, first match wins.
struct RulesListView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    @State private var isArranging = false
    @State private var editing: UUID?

    var body: some View {
        @Bindable var store = store

        List {
            if store.settings.customRules.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loc("No rules yet.")).font(.callout)
                        Text(loc("Add one to send a domain or a network through a particular server."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            Section {
                ForEach(store.settings.customRules) { rule in
                    NavigationLink {
                        RuleEditorView(ruleID: rule.id)
                    } label: {
                        ruleRow(rule)
                    }
                }
                .onMove { from, to in
                    store.settings.customRules.move(fromOffsets: from, toOffset: to)
                    store.save()
                }
                .onDelete { offsets in
                    // By value: the ids are read before anything is removed.
                    let ids = Set(offsets.map { store.settings.customRules[$0].id })
                    store.settings.customRules.removeAll { ids.contains($0.id) }
                    store.save()
                }
            } header: {
                Text(loc("Rules — top to bottom, first match wins"))
            } footer: {
                Text(loc("A rule matches when every filled-in field matches. Domains: example.com, domain:example.com, keyword:google, geosite:netflix. IPs: 1.2.3.0/24, geoip:cn."))
            }

            Section {
                Button {
                    let rule = RoutingRule(name: "")
                    store.settings.customRules.append(rule)
                    store.save()
                    editing = rule.id
                } label: {
                    Label(loc("Add rule"), systemImage: "plus.circle")
                }
                Menu {
                    ForEach(RuleTemplate.all) { template in
                        Button(loc(template.title)) {
                            store.settings.customRules.append(template.rule())
                            store.save()
                        }
                    }
                } label: {
                    Label(loc("From template"), systemImage: "wand.and.stars")
                }
            }
        }
        .environment(\.editMode, .constant(isArranging ? .active : .inactive))
        .navigationTitle(loc("Rules"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editing) { id in
            RuleEditorView(ruleID: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isArranging ? loc("Done") : loc("Arrange")) {
                    withAnimation { isArranging.toggle() }
                }
                .disabled(store.settings.customRules.isEmpty && !isArranging)
            }
        }
    }

    private func ruleRow(_ rule: RoutingRule) -> some View {
        let matchers = rule.domains + rule.ips + (rule.port.isEmpty ? [] : [":" + rule.port])
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(rule.name.isEmpty ? loc("Rule") : rule.name)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                    .lineLimit(1)
                Text(verbatim: "→").foregroundStyle(.secondary)
                Text(loc(rule.target.title(servers: store.allServers, groups: store.allGroups)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !Self.runsOnXray(rule) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if !matchers.isEmpty {
                Text(matchers.joined(separator: ", "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(rule.enabled ? 1 : 0.55)
    }

    /// Whether this build can enforce the rule at all. Application matching
    /// and inversion are sing-box features, and a rule that cannot be honoured
    /// must not look configured.
    static func runsOnXray(_ rule: RoutingRule) -> Bool {
        !rule.needsProcessMatching && !rule.invert && rule.ruleSets.isEmpty
            && rule.clashMode.isEmpty
    }
}

/// Rules people write over and over, pre-filled.
struct RuleTemplate: Identifiable, Sendable {
    var id: String { title }
    var title: String
    var rule: @Sendable () -> RoutingRule

    static let all: [RuleTemplate] = [
        RuleTemplate(title: "Streaming through the proxy") {
            RoutingRule(name: "Streaming", target: .proxy,
                        domains: ["geosite:netflix", "geosite:youtube",
                                  "geosite:disney", "geosite:spotify"])
        },
        RuleTemplate(title: "Block QUIC (force TLS)") {
            var rule = RoutingRule(name: "Block QUIC", target: .block, port: "443")
            rule.network = "udp"
            return rule
        },
        RuleTemplate(title: "LAN direct") {
            RoutingRule(name: "LAN direct", target: .direct,
                        ips: RoutingPreset.privateCIDRs)
        }
    ]
}

// MARK: - One rule

struct RuleEditorView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let ruleID: UUID

    /// Edited as a copy and written back by id. A binding into the stored
    /// array by index traps the moment the rule is deleted under it.
    @State private var rule = RoutingRule()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField(loc("Rule name"), text: $rule.name)
                Toggle(loc("Enabled"), isOn: $rule.enabled)
                RuleTargetPicker(target: $rule.target,
                                 servers: store.allServers,
                                 groups: store.allGroups)
            }

            Section {
                TokenListEditor(values: $rule.domains,
                                placeholder: "example.com, geosite:netflix")
            } header: {
                Text(loc("Domains"))
            }

            Section {
                TokenListEditor(values: $rule.ips,
                                placeholder: "1.2.3.0/24, geoip:cn")
                Picker(loc("Addresses are"), selection: $rule.direction) {
                    ForEach(RuleDirection.allCases) { Text(loc($0.title)).tag($0) }
                }
            } header: {
                Text(loc("IPs / CIDR"))
            }

            Section {
                LabeledContent(loc("Port")) {
                    TextField("443, 1000-2000", text: $rule.port)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                Picker(loc("Network"), selection: $rule.network) {
                    Text(loc("Any")).tag("")
                    Text(verbatim: "TCP").tag("tcp")
                    Text(verbatim: "UDP").tag("udp")
                }
            } header: {
                Text(loc("More"))
            }

            Section {
                TokenListEditor(values: $rule.protocols,
                                placeholder: "tls, quic, bittorrent")
            } header: {
                Text(loc("Protocols (sniffed)"))
            } footer: {
                Text(loc("Xray recognises http, tls, quic and bittorrent."))
            }

            if !RulesListView.runsOnXray(rule) {
                Section {
                    Label(loc("This rule matches applications or is inverted. Only the sing-box core on the Mac can do that, so this build leaves it out."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button(loc("Delete rule"), role: .destructive) {
                    let id = ruleID
                    store.settings.customRules.removeAll { $0.id == id }
                    store.save()
                    dismiss()
                }
            }
        }
        .navigationTitle(rule.name.isEmpty ? loc("Rule") : rule.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            if let stored = store.settings.customRules.first(where: { $0.id == ruleID }) {
                rule = stored
            }
            loaded = true
        }
        .onChange(of: rule) { _, edited in
            guard loaded,
                  let index = store.settings.customRules.firstIndex(where: { $0.id == ruleID })
            else { return }
            store.settings.customRules[index] = edited
        }
        .onDisappear { store.save() }
    }
}

/// Picks where a rule sends its traffic: one of the three built-ins, a group,
/// or a specific server.
struct RuleTargetPicker: View {
    @Environment(Loc.self) private var loc
    @Binding var target: RuleTarget
    var servers: [ProxyConfig]
    var groups: [ServerGroup]
    var title: String?

    var body: some View {
        Picker(title ?? loc("Send to"), selection: $target) {
            Text(loc("Proxy")).tag(RuleTarget.proxy)
            Text(loc("Direct")).tag(RuleTarget.direct)
            Text(loc("Block")).tag(RuleTarget.block)
            if !groups.isEmpty {
                Section(loc("Groups")) {
                    ForEach(groups) { group in
                        Text(group.name.isEmpty ? loc("Group") : group.name)
                            .tag(RuleTarget.group(group.id))
                    }
                }
            }
            let runnable = servers.filter(\.xraySupported)
            if !runnable.isEmpty {
                Section(loc("Servers")) {
                    ForEach(runnable) { server in
                        Text(server.name).tag(RuleTarget.server(server.id))
                    }
                }
            }
            // A target whose server or group was deleted would otherwise have
            // no matching tag and the picker would show blank.
            if let orphan = orphanLabel {
                Text(orphan).tag(target)
            }
        }
        .pickerStyle(.navigationLink)
    }

    private var orphanLabel: String? {
        switch target {
        case .server(let id):
            return servers.contains { $0.id == id && $0.xraySupported } ? nil : loc("Missing server")
        case .group(let id):
            return groups.contains { $0.id == id } ? nil : loc("Missing group")
        case .proxy, .direct, .block:
            return nil
        }
    }
}
