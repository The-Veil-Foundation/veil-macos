import SwiftUI

/// The server list: the sections, the rows, and everything the user can do to
/// arrange them.
///
/// What is shown is decided by `ServerListBuilder`, not here — the same call
/// feeds the keyboard navigation order in `ContentView`, so the two cannot
/// disagree about what is on screen.
struct ServerListView: View {
    @Environment(ServerStore.self) private var store
    let filter: ListFilter
    var selectionMode: Bool = false
    var selectedForDeletion: Binding<Set<UUID>> = .constant([])

    var body: some View {
        ForEach(store.listSections(filter: filter)) { section in
            ListSectionView(section: section,
                            selectionMode: selectionMode,
                            selectedForDeletion: selectedForDeletion)
        }
    }
}

/// One section of the list. Under subscription grouping it is a source, with
/// the source's traffic, expiry and actions in its header; under the other
/// groupings it is a facet — a country or a tag — and the header is just a name
/// and a count.
struct ListSectionView: View {
    @Environment(ServerStore.self) private var store
    @Environment(ConnectionManager.self) private var connection
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc
    @Environment(\.openWindow) private var openWindow

    let section: ListSection
    var selectionMode: Bool = false
    var selectedForDeletion: Binding<Set<UUID>> = .constant([])

    @State private var qrServer: ProxyConfig?
    @State private var editing: ProxyConfig?
    @State private var showHiddenHere = false

    /// The subscription this section stands for, when it stands for one.
    private var subscription: Subscription? {
        guard let id = section.subscriptionID else { return nil }
        return store.subscriptions.first { $0.id == id }
    }

    private var isCollapsed: Bool { section.isCollapsed }

    var body: some View {
        // A single subscription can hold hundreds of rows. The outer stack
        // defers sections, so each section must defer its own rows as well.
        LazyVStack(alignment: .leading, spacing: 0) {
            if let subscription {
                SubscriptionHeader(subscription: subscription, count: section.servers.count)
            } else {
                facetHeader
            }
            if !isCollapsed {
                ForEach(section.groups) { group in
                    groupRow(group)
                }
                ForEach(section.servers) { server in
                    serverRow(server)
                }
                if section.hiddenCount > 0 {
                    hiddenFooter
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .sheet(item: $qrServer) { server in QRDisplaySheet(server: server) }
        .sheet(item: $editing) { server in
            NodeAnnotationSheet(server: server)
        }
    }

    // MARK: - Headers

    private var facetHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
            Text(loc(section.title)).font(.headline).lineLimit(1)
            Text(verbatim: "\(section.servers.count + section.groups.count)")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
            if let best = bestLatency {
                Text(verbatim: "\(best) ms")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .help(loc("Fastest server in this group"))
            }
            Spacer()
            Button {
                pinger.test(section.servers, tunActive: tunActive)
            } label: {
                Image(systemName: "bolt.horizontal")
            }
            .buttonStyle(.accessoryBar)
            .help(loc("Test ping (group)"))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { store.toggleFacet(section.id) }
        }
    }

    /// The lowest latency measured in this section, if any answered.
    private var bestLatency: Int? {
        section.servers.compactMap { pinger.latency(for: $0.id) ?? nil }.min()
    }

    // MARK: - Rows

    private func groupRow(_ group: ProxyConfig) -> some View {
        ServerRow(server: group,
                  isSelected: store.selectedServerID == group.id,
                  isActive: connection.activeServerID == group.id,
                  latency: nil,
                  isTesting: false)
            .contentShape(Rectangle())
            .id(group.id)
            .onTapGesture { if !selectionMode { handleTap(group) } }
            .contextMenu {
                Button(connection.isConnected ? loc("Switch here") : loc("Connect")) {
                    store.select(group.id); connection.connect(to: group)
                }
                // A group has no latency of its own: it is whichever member the
                // core finds quickest, so the useful measurement is theirs.
                Button(loc("Test ping")) {
                    let members = store.allGroups.first { $0.id == group.id }?.memberIDs ?? []
                    pinger.test(store.allServers.filter { members.contains($0.id) },
                                tunActive: tunActive)
                }
                // Only the user's own groups are theirs to change: a panel's
                // declared group would be back at the next refresh.
                if store.settings.serverGroups.contains(where: { $0.id == group.id }) {
                    Divider()
                    Button(loc("Edit groups…")) { openGroupsEditor() }
                    Button(loc("Delete group"), role: .destructive) {
                        // By value: reading the row's own binding inside the
                        // removal traps with an exclusivity conflict.
                        let id = group.id
                        store.removeGroup(id: id)
                    }
                }
            }
    }

    /// Opens the Routing window on its groups tab, which is where a group's
    /// membership and kind are edited.
    private func openGroupsEditor() {
        store.settings.lastRoutingTab = RoutingSheet.Tab.groups.rawValue
        store.save()
        openWindow(id: WindowID.settings)
    }

    private func serverRow(_ server: ProxyConfig) -> some View {
        let isActive = connection.activeServerID == server.id
        let isLocked = isActive && connection.isConnected
        let annotation = store.annotation(for: server.id)

        return HStack(spacing: 8) {
            if selectionMode {
                // A real checkbox, so selection looks and behaves the way it
                // does everywhere else on the Mac. The active server cannot be
                // picked.
                if isLocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .help(loc("Connected"))
                        .padding(.leading, 14)
                } else {
                    Toggle("", isOn: Binding(
                        get: { selectedForDeletion.wrappedValue.contains(server.id) },
                        set: { _ in toggleSelection(server.id) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.leading, 14)
                }
            }
            ServerRow(server: server,
                      isSelected: store.selectedServerID == server.id,
                      isActive: isActive,
                      latency: pinger.latency(for: server.id),
                      isTesting: pinger.isTesting(server.id),
                      annotation: annotation,
                      autoTags: store.settings.autoTags)
        }
        .contentShape(Rectangle())
        .id(server.id)
        .onTapGesture {
            if selectionMode {
                if !isLocked { toggleSelection(server.id) }
            } else { handleTap(server) }
        }
        .draggable(server.id.uuidString) {
            Text(server.name).padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            move(items.compactMap(UUID.init(uuidString:)), before: server.id)
        }
        .contextMenu { rowMenu(server, isLocked: isLocked, annotation: annotation) }
    }

    @ViewBuilder
    private func rowMenu(_ server: ProxyConfig, isLocked: Bool,
                         annotation: NodeAnnotation) -> some View {
        Button(connection.isConnected ? loc("Switch here") : loc("Connect")) {
            store.select(server.id); connection.connect(to: server)
        }
        Button(loc("Test ping")) { pinger.test([server], tunActive: tunActive) }
        Divider()
        Button(annotation.pinned ? loc("Unpin") : loc("Pin"),
               systemImage: annotation.pinned ? "pin.slash" : "pin") {
            store.togglePinned(serverID: server.id)
        }
        Button(annotation.hidden ? loc("Unhide") : loc("Hide"),
               systemImage: annotation.hidden ? "eye" : "eye.slash") {
            store.setHidden(!annotation.hidden, serverID: server.id)
        }
        Button(loc("Rename and tag…"), systemImage: "tag") { editing = server }
        if !section.servers.isEmpty {
            Button(loc("Reset manual order"), systemImage: "arrow.uturn.backward") {
                store.clearManualOrder(section: section.servers.map(\.id))
            }
        }
        Divider()
        Button(loc("Copy link")) {
            let link = LinkBuilder.link(for: server)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        Button(loc("Show QR code")) { qrServer = server }
        if subscription?.isManual == true && !isLocked {
            Divider()
            Button(loc("Delete"), role: .destructive) { store.removeServer(id: server.id) }
        }
    }

    private var hiddenFooter: some View {
        Button {
            store.settings.showHiddenNodes.toggle()
            store.save()
        } label: {
            Label(store.settings.showHiddenNodes
                  ? loc("Hide hidden servers")
                  : String(format: loc("%d hidden"), section.hiddenCount),
                  systemImage: store.settings.showHiddenNodes ? "eye.slash" : "eye")
                .font(.caption)
                .padding(.horizontal, 32).padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private var tunActive: Bool {
        connection.mode == .tun && connection.isConnected
    }

    /// Drops the dragged nodes in front of `target`, and records the order the
    /// section is left in. Dragging works inside a section only: under tag or
    /// country grouping a node's section is decided by what it is, so moving it
    /// elsewhere would mean nothing.
    private func move(_ dragged: [UUID], before target: UUID) -> Bool {
        var order = section.servers.map(\.id)
        let moving = dragged.filter { order.contains($0) }
        guard !moving.isEmpty, !moving.contains(target) else { return false }
        order.removeAll { moving.contains($0) }
        guard let index = order.firstIndex(of: target) else { return false }
        order.insert(contentsOf: moving, at: index)
        store.reorder(section: order)
        return true
    }

    private func toggleSelection(_ id: UUID) {
        if selectedForDeletion.wrappedValue.contains(id) {
            selectedForDeletion.wrappedValue.remove(id)
        } else {
            selectedForDeletion.wrappedValue.insert(id)
        }
    }

    /// Disconnected: tap = select only. Connected: tap = switch immediately.
    private func handleTap(_ server: ProxyConfig) {
        store.select(server.id)
        if connection.isConnected {
            connection.connect(to: server)
        }
    }
}

// MARK: - Renaming and tagging one node

/// The name and labels the user puts on a node, as opposed to what its source
/// calls it. Both are annotations, so both survive the next refresh.
struct NodeAnnotationSheet: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let server: ProxyConfig
    @State private var name = ""
    @State private var tags: [String] = []
    @State private var newTag = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc("Rename and tag…")).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                TextField(server.name, text: $name)
                    .textFieldStyle(.roundedBorder)
                Text(loc("Shown instead of the name the source gives this server."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(loc("Tags")).font(.subheadline)
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            Label(tag, systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField(loc("Add a tag…"), text: $newTag)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTag)
                    Button(loc("Add"), action: addTag)
                        .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                // Only when the setting is on: with it off these tags are not
                // in the list, the filter or the groups, so showing them here
                // would promise something the rest of the app does not do.
                let derived = store.settings.autoTags
                    ? AutoTags.tags(for: server, name: name.isEmpty ? nil : name)
                    : []
                if !derived.isEmpty {
                    Text(loc("Read from the name")).font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(derived, id: \.self) { tag in
                            Text(tag).font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }
                    Text(loc("These come from the server's own name and its settings. They filter and group like any tag, and change when the name does."))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !store.allTags.isEmpty {
                    Text(loc("In use elsewhere")).font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(store.allTags.filter { !tags.contains($0) }, id: \.self) { tag in
                            Button { tags.append(tag) } label: {
                                Text(tag).font(.caption)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack {
                Button(loc("Reset")) {
                    name = ""
                    tags = []
                }
                Spacer()
                Button(loc("Cancel")) { dismiss() }
                Button(loc("Save")) {
                    store.rename(serverID: server.id, to: name)
                    store.setTags(tags, serverID: server.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear {
            let annotation = store.annotation(for: server.id)
            name = annotation.nameOverride ?? ""
            tags = annotation.tags
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !tags.contains(tag) else { return }
        tags.append(tag)
        newTag = ""
    }
}
