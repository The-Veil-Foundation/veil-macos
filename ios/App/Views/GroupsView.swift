import SwiftUI

/// The groups a rule — or the user — can point at.
///
/// A group behaves like one server. Membership is either a hand-picked list,
/// which suits the three nodes that can reach the office, or a query — this
/// source, that country, that tag — answered again on every refresh, which is
/// the only way a group over a subscription of fifty nodes stays correct when
/// the provider adds a node.
struct GroupsView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    @State private var editing: UUID?

    var body: some View {
        @Bindable var store = store

        List {
            if store.settings.serverGroups.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("No groups yet.")).font(.callout)
                        Text(loc("A group behaves like one server: pick a member by hand, or let the fastest one win."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            if !store.settings.serverGroups.isEmpty {
                Section(loc("Your groups")) {
                    ForEach(store.settings.serverGroups) { group in
                        NavigationLink {
                            GroupEditorView(groupID: group.id)
                        } label: {
                            groupRow(group)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.settings.serverGroups[$0].id }
                        for id in ids { store.removeGroup(id: id) }
                    }
                    .onMove { from, to in
                        store.settings.serverGroups.move(fromOffsets: from, toOffset: to)
                        store.save()
                    }
                }
            }

            Section {
                Button {
                    let group = ServerGroup(name: loc("Group"), kind: .urltest)
                    store.settings.serverGroups.append(group)
                    store.save()
                    editing = group.id
                } label: {
                    Label(loc("Add group"), systemImage: "plus")
                }
                Button {
                    // The group a sing-box-launcher profile calls `proxy-out`:
                    // every node, measured, the quickest in use.
                    let group = store.addAutoGroup(named: loc("Fastest"), query: GroupQuery())
                    editing = group.id
                } label: {
                    Label(loc("Fastest of everything"), systemImage: "bolt.horizontal")
                }
            } footer: {
                Text(loc("One group holding every server, measured and re-measured, with the quickest in use."))
            }

            if !store.declaredGroups.isEmpty {
                Section {
                    ForEach(store.declaredGroups) { group in
                        groupRow(group)
                    }
                } header: {
                    Text(loc("Groups the panel declared"))
                } footer: {
                    Text(loc("These come with a subscription and are replaced on every refresh."))
                }
            }
        }
        .navigationTitle(loc("Groups"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editing) { id in
            GroupEditorView(groupID: id)
        }
    }

    private func groupRow(_ group: ServerGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: group.kind == .urltest ? "bolt.horizontal" : "hand.point.up.left")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name.isEmpty ? loc("Group") : group.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(loc(group.kind.title))
                    Text(verbatim: "·")
                    Text(String(format: loc("%d servers"), group.memberIDs.count))
                    if group.isAutomatic {
                        Text(verbatim: "·")
                        Text(loc("Automatic"))
                    }
                }
                .font(.caption2)
                .foregroundStyle(group.memberIDs.isEmpty ? Color.red : Color.secondary)
            }
        }
    }
}

// MARK: - One group

struct GroupEditorView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let groupID: UUID

    /// Edited as a copy and written back by id, so deleting the group while
    /// this screen is up cannot leave a binding pointing past the array.
    @State private var group = ServerGroup()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField(loc("Name"), text: $group.name)
                Picker(loc("Picks"), selection: $group.kind) {
                    ForEach(ServerGroup.Kind.allCases) { kind in
                        Text(loc(kind.title)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(loc(group.kind.subtitle))
            }

            Section {
                Picker(loc("Members"), selection: membershipBinding) {
                    Text(loc("Chosen by hand")).tag(false)
                    Text(loc("Everything that matches")).tag(true)
                }
                .pickerStyle(.segmented)
            }

            if group.query != nil {
                queryRows
            } else {
                manualMembers
            }

            if group.kind == .selector, !members.isEmpty {
                Section {
                    Picker(loc("Active member"), selection: $group.selectedID) {
                        Text(loc("First member")).tag(UUID?.none)
                        ForEach(members) { server in
                            Text(server.name).tag(UUID?.some(server.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }

            if group.kind == .urltest {
                Section {
                    LabeledContent(loc("Test URL")) {
                        TextField("https://www.gstatic.com/generate_204", text: $group.testURL)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    LabeledContent(loc("Every")) {
                        TextField("3m", text: $group.interval)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } header: {
                    Text(loc("Measuring"))
                } footer: {
                    Text(loc("Xray probes every member through the tunnel and sends traffic to the quickest one that answers."))
                }
            }

            Section {
                Button(loc("Delete group"), role: .destructive) {
                    let id = groupID
                    store.removeGroup(id: id)
                    dismiss()
                }
            }
        }
        .navigationTitle(group.name.isEmpty ? loc("Group") : group.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            if let stored = store.settings.serverGroups.first(where: { $0.id == groupID }) {
                group = stored
            }
            loaded = true
        }
        .onChange(of: group) { _, edited in
            guard loaded,
                  let index = store.settings.serverGroups.firstIndex(where: { $0.id == groupID })
            else { return }
            store.settings.serverGroups[index] = edited
            // Re-answers the query live, so the match count below is current.
            store.refreshAutoGroups()
            if let resolved = store.settings.serverGroups.first(where: { $0.id == groupID }),
               resolved.memberIDs != group.memberIDs {
                group.memberIDs = resolved.memberIDs
                group.selectedID = resolved.selectedID
            }
        }
        .onDisappear { store.save() }
    }

    // MARK: - Members

    private var members: [ProxyConfig] {
        let servers = store.allServers
        return group.memberIDs.compactMap { id in servers.first { $0.id == id } }
    }

    /// Switching membership mode, without losing the hand-picked list: turning
    /// the query off restores an empty list to pick into.
    private var membershipBinding: Binding<Bool> {
        Binding(get: { group.query != nil },
                set: { isAutomatic in
                    group.query = isAutomatic ? GroupQuery() : nil
                    if !isAutomatic { group.memberIDs = [] }
                })
    }

    @ViewBuilder
    private var manualMembers: some View {
        Section {
            if members.isEmpty {
                Text(store.allServers.isEmpty ? loc("Add a server first.") : loc("No members yet."))
                    .foregroundStyle(.secondary)
            }
            ForEach(members) { server in
                Text(server.name).lineLimit(1)
            }
            .onDelete { offsets in
                let ids = offsets.map { members[$0].id }
                group.memberIDs.removeAll { ids.contains($0) }
                if let selected = group.selectedID, ids.contains(selected) { group.selectedID = nil }
            }
            .onMove { from, to in group.memberIDs.move(fromOffsets: from, toOffset: to) }
            NavigationLink {
                MemberPickerView(memberIDs: $group.memberIDs)
            } label: {
                Label(loc("Add member"), systemImage: "plus")
            }
        } header: {
            Text(loc("Members"))
        }
    }

    // MARK: - Query

    @ViewBuilder
    private var queryRows: some View {
        let query = Binding(get: { group.query ?? GroupQuery() },
                            set: { group.query = $0 })
        Section {
            NavigationLink {
                MultiPickerView(title: loc("From"),
                                options: store.orderedSubscriptions.map { ($0.id.uuidString, $0.name) },
                                selection: Binding(
                                    get: { Set(query.wrappedValue.sourceIDs.map(\.uuidString)) },
                                    set: { query.wrappedValue.sourceIDs = $0.compactMap(UUID.init(uuidString:)) }))
            } label: {
                LabeledContent(loc("From"), value: sourcesLabel(query.wrappedValue))
            }
            if !countriesInUse.isEmpty {
                NavigationLink {
                    MultiPickerView(title: loc("Country"),
                                    options: countriesInUse.map {
                                        ($0, NodeFacets.flag(for: $0) + " " + NodeFacets.countryName(for: $0))
                                    },
                                    selection: Binding(
                                        get: { Set(query.wrappedValue.countries) },
                                        set: { query.wrappedValue.countries = $0.sorted() }))
                } label: {
                    LabeledContent(loc("Country"),
                                   value: query.wrappedValue.countries.isEmpty
                                   ? loc("Any") : query.wrappedValue.countries.joined(separator: ", "))
                }
            }
            if !store.allTags.isEmpty {
                NavigationLink {
                    MultiPickerView(title: loc("Tags"),
                                    options: store.allTags.map { ($0, $0) },
                                    selection: Binding(
                                        get: { Set(query.wrappedValue.tags) },
                                        set: { query.wrappedValue.tags = $0.sorted() }))
                } label: {
                    LabeledContent(loc("Tags"),
                                   value: query.wrappedValue.tags.isEmpty
                                   ? loc("Any") : query.wrappedValue.tags.joined(separator: ", "))
                }
            }
            NavigationLink {
                MultiPickerView(title: loc("Protocol"),
                                options: protocolsInUse.map { ($0.rawValue, $0.rawValue.uppercased()) },
                                selection: Binding(
                                    get: { Set(query.wrappedValue.protocols.map(\.rawValue)) },
                                    set: { query.wrappedValue.protocols = $0.sorted().compactMap(ProxyProtocol.init(rawValue:)) }))
            } label: {
                LabeledContent(loc("Protocol"),
                               value: query.wrappedValue.protocols.isEmpty
                               ? loc("Any")
                               : query.wrappedValue.protocols.map { $0.rawValue.uppercased() }.joined(separator: ", "))
            }
            LabeledContent(loc("Name contains")) {
                TextField(loc("Any"), text: query.nameContains)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
            }
            Toggle(loc("Include hidden servers"),
                   isOn: Binding(get: { !query.wrappedValue.excludeHidden },
                                 set: { query.wrappedValue.excludeHidden = !$0 }))
        } header: {
            Text(loc("Everything that matches"))
        } footer: {
            let matched = members
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: loc("%d servers match right now"), matched.count))
                    .foregroundStyle(matched.isEmpty ? .red : .secondary)
                if !matched.isEmpty {
                    Text(matched.prefix(6).map(\.name).joined(separator: " · ")
                         + (matched.count > 6 ? " …" : ""))
                        .lineLimit(2)
                }
            }
        }
    }

    private func sourcesLabel(_ query: GroupQuery) -> String {
        guard !query.sourceIDs.isEmpty else { return loc("Every source") }
        let names = query.sourceIDs.compactMap { id in
            store.subscriptions.first { $0.id == id }?.name
        }
        return names.isEmpty ? loc("Every source") : names.joined(separator: ", ")
    }

    private var countriesInUse: [String] {
        var seen: [String] = []
        for server in store.allServers {
            let name = store.annotation(for: server.id).nameOverride ?? server.name
            guard let code = NodeFacets.country(in: name, proto: server.proto),
                  !seen.contains(code) else { continue }
            seen.append(code)
        }
        return seen.sorted()
    }

    private var protocolsInUse: [ProxyProtocol] {
        var seen: [ProxyProtocol] = []
        for server in store.allServers where !seen.contains(server.proto) {
            seen.append(server.proto)
        }
        return seen
    }
}

// MARK: - Pickers

/// A checklist over a fixed set of options.
struct MultiPickerView: View {
    @Environment(Loc.self) private var loc
    let title: String
    let options: [(String, String)]
    @Binding var selection: Set<String>

    var body: some View {
        List {
            ForEach(options, id: \.0) { value, label in
                Button {
                    if selection.contains(value) { selection.remove(value) } else { selection.insert(value) }
                } label: {
                    HStack {
                        Text(label).foregroundStyle(.primary)
                        Spacer()
                        if selection.contains(value) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(loc("Any")) { selection = [] }
                    .disabled(selection.isEmpty)
            }
        }
    }
}

/// Every server, searchable, to add to a hand-picked group.
struct MemberPickerView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Binding var memberIDs: [UUID]
    @State private var search = ""

    var body: some View {
        List {
            ForEach(store.orderedSubscriptions) { source in
                let servers = source.servers.filter(matches)
                if !servers.isEmpty {
                    Section(source.name) {
                        ForEach(servers) { server in
                            Button {
                                if let index = memberIDs.firstIndex(of: server.id) {
                                    memberIDs.remove(at: index)
                                } else {
                                    memberIDs.append(server.id)
                                }
                            } label: {
                                HStack {
                                    Text(store.annotation(for: server.id).nameOverride ?? server.name)
                                        .foregroundStyle(server.xraySupported ? .primary : .secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    if memberIDs.contains(server.id) {
                                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .searchable(text: $search, prompt: loc("Search servers…"))
        .navigationTitle(loc("Add member"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func matches(_ server: ProxyConfig) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let name = store.annotation(for: server.id).nameOverride ?? server.name
        return name.lowercased().contains(q) || server.address.lowercased().contains(q)
    }
}
