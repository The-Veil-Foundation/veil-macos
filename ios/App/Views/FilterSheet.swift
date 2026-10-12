import SwiftUI

/// Everything that narrows the server list, in one sheet: reachability, the
/// user's tags, the countries and protocols the nodes are in.
struct FilterSheet: View {
    @Environment(ServerStore.self) private var store
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @Binding var aliveOnly: Bool
    @Binding var sortByPing: Bool
    @Binding var selectedTags: Set<String>
    @Binding var selectedCountries: Set<String>
    @Binding var selectedProtocols: Set<ProxyProtocol>

    var body: some View {
        @Bindable var store = store
        // Countries are read out of the node names, so they answer to the same
        // switch as the other derived tags.
        let countries = store.settings.autoTags ? countriesInUse : []

        NavigationStack {
            Form {
                Section {
                    Toggle(loc("Alive"), isOn: $aliveOnly)
                    Toggle(loc("By ping"), isOn: $sortByPing)
                    Toggle(loc("Show hidden servers"), isOn: $store.settings.showHiddenNodes)
                        .onChange(of: store.settings.showHiddenNodes) { _, _ in store.save() }
                } footer: {
                    Text(loc("Show only servers that answered a ping. Turning this on measures them first."))
                }

                if !store.allTags.isEmpty {
                    Section(loc("Tags")) {
                        ChipFlow(spacing: 6) {
                            ForEach(store.allTags, id: \.self) { tag in
                                Chip(title: tag, isOn: selectedTags.contains(tag)) {
                                    toggle(tag, in: &selectedTags)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if countries.count > 1 {
                    Section(loc("Country")) {
                        ChipFlow(spacing: 6) {
                            ForEach(countries, id: \.self) { code in
                                Chip(title: NodeFacets.flag(for: code) + " "
                                        + NodeFacets.countryName(for: code),
                                     isOn: selectedCountries.contains(code)) {
                                    toggle(code, in: &selectedCountries)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if protocolsInUse.count > 1 {
                    Section(loc("Protocol")) {
                        ChipFlow(spacing: 6) {
                            ForEach(protocolsInUse, id: \.self) { proto in
                                Chip(title: proto.rawValue.uppercased(),
                                     isOn: selectedProtocols.contains(proto)) {
                                    if selectedProtocols.contains(proto) {
                                        selectedProtocols.remove(proto)
                                    } else {
                                        selectedProtocols.insert(proto)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if !store.settings.autoTags {
                    Section {
                        Toggle(loc("Tag servers from their names"), isOn: $store.settings.autoTags)
                            .onChange(of: store.settings.autoTags) { _, _ in store.save() }
                    } footer: {
                        Text(loc("Reads the country, the protocol and words a provider uses — Premium, Trial, Game — out of each node's name and shows them as tags beside the ones you attach yourself. They also filter and group. Off by default, because they are guesses about someone else's naming."))
                    }
                }
            }
            .navigationTitle(loc("Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("Clear filters")) {
                        aliveOnly = false
                        selectedTags = []
                        selectedCountries = []
                        selectedProtocols = []
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("Done")) { dismiss() }
                }
            }
            .onChange(of: aliveOnly) { _, on in
                // Without a measurement nothing is "alive", and the filter
                // would empty the whole list.
                if on, !pinger.hasResults, !pinger.isBusy { pinger.test(store.allServers) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The places the user actually has servers in, sorted by name.
    private var countriesInUse: [String] {
        var seen = Set<String>()
        var codes: [String] = []
        for server in store.allServers {
            let name = store.annotation(for: server.id).nameOverride ?? server.name
            guard let code = NodeFacets.country(in: name, proto: server.proto),
                  seen.insert(code).inserted else { continue }
            codes.append(code)
        }
        return codes.sorted {
            NodeFacets.countryName(for: $0).localizedStandardCompare(
                NodeFacets.countryName(for: $1)) == .orderedAscending
        }
    }

    private var protocolsInUse: [ProxyProtocol] {
        var seen: [ProxyProtocol] = []
        for server in store.allServers where !seen.contains(server.proto) {
            seen.append(server.proto)
        }
        return seen
    }

    private func toggle(_ value: String, in set: inout Set<String>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}
