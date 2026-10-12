import SwiftUI

/// Where servers come from, rather than which one is in use.
///
/// The server list answers "what am I connecting through". This answers "what
/// is in my list and why" — which source produced a node, what the source
/// actually returned and could not use, and, for a node Veil owns, what it is
/// made of.
struct SourcesView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(Loc.self) private var loc

    @State private var showAdd = false
    @State private var isArranging = false
    @State private var removing: Subscription?

    var body: some View {
        NavigationStack {
            List {
                if store.subscriptions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(loc("No sources yet")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
                ForEach(store.orderedSubscriptions) { source in
                    NavigationLink {
                        SourceDetailView(sourceID: source.id)
                    } label: {
                        sourceRow(source)
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            store.togglePinned(subscriptionID: source.id)
                        } label: {
                            Label(source.pinned == true ? loc("Unpin") : loc("Pin"),
                                  systemImage: source.pinned == true ? "pin.slash" : "pin")
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            removing = source
                        } label: {
                            Label(loc("Remove"), systemImage: "trash")
                        }
                        .disabled(holdsActive(source))
                    }
                }
                .onMove { from, to in store.moveSubscriptions(fromOffsets: from, toOffset: to) }
            }
            .environment(\.editMode, .constant(isArranging ? .active : .inactive))
            .navigationTitle(loc("Sources"))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await SubscriptionService.refreshAll(store) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(loc("Add"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isArranging ? loc("Done") : loc("Arrange")) {
                        withAnimation { isArranging.toggle() }
                    }
                    .disabled(store.subscriptions.count < 2 && !isArranging)
                }
            }
            .sheet(isPresented: $showAdd) { AddView() }
            .confirmationDialog(loc("Remove this subscription?"),
                                isPresented: Binding(get: { removing != nil },
                                                     set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button(loc("Remove"), role: .destructive) {
                    if let id = removing?.id { store.removeSubscription(id: id) }
                    removing = nil
                }
                Button(loc("Cancel"), role: .cancel) { removing = nil }
            }
        }
    }

    private func sourceRow(_ source: Subscription) -> some View {
        HStack(spacing: 10) {
            Image(systemName: source.isManual ? "tray" : "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(source.name).lineLimit(1)
                    if source.pinned == true {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(String(format: loc("%d servers"), source.servers.count))
                    if let format = source.lastFormat {
                        Text(verbatim: "· \(format.label)")
                    }
                    if let skipped = source.lastSkipped, !skipped.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func holdsActive(_ source: Subscription) -> Bool {
        tunnel.isConnected && source.servers.contains { $0.id == tunnel.activeServerID }
    }
}

/// One source in full: what the last fetch returned, what it could not use,
/// and every node in it.
struct SourceDetailView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    let sourceID: UUID
    @State private var inspecting: ProxyConfig?
    @State private var isRefreshing = false
    @State private var madeGroup = false

    private var source: Subscription? {
        store.subscriptions.first { $0.id == sourceID }
    }

    var body: some View {
        if let source {
            List {
                summary(source)

                if let skipped = source.lastSkipped, !skipped.isEmpty {
                    Section {
                        ForEach(skipped, id: \.label) { note in
                            LabeledContent(note.label, value: "× \(note.count)")
                        }
                    } header: {
                        Label(loc("Not everything in this source could be used"),
                              systemImage: "exclamationmark.triangle")
                    } footer: {
                        Text(loc("These entries were dropped while reading the source. A server that is missing from the list is listed here with the reason."))
                    }
                }

                if !source.declaredGroups.isEmpty {
                    Section(loc("Groups the panel declared")) {
                        ForEach(source.declaredGroups) { group in
                            LabeledContent(group.name,
                                           value: "\(loc(group.kind.title)) · \(group.memberIDs.count)")
                        }
                    }
                }

                Section {
                    if source.servers.isEmpty {
                        Text(loc("This source has no servers in it."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(source.servers) { server in
                        Button {
                            inspecting = server
                        } label: {
                            nodeRow(server)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: source.isManual ? { offsets in
                        let ids = Set(offsets.map { source.servers[$0].id })
                        store.removeServers(ids: ids)
                    } : nil)
                } header: {
                    Text(loc("Servers"))
                } footer: {
                    if !source.isManual {
                        Text(loc("A subscription's servers are the panel's. Rename them, tag them, pin them — that is yours and survives a refresh — but to change what one connects to, duplicate it into Manual."))
                    }
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                if !source.isManual { await SubscriptionService.refresh(source, into: store) }
            }
            .sheet(item: $inspecting) { server in
                NodeEditorView(server: server, isEditable: source.isManual)
            }
        } else {
            Text(loc("No sources yet")).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func summary(_ source: Subscription) -> some View {
        @Bindable var store = store
        Section {
            if !source.isManual {
                LabeledContent(loc("Address"), value: source.hasStoredURL == true || source.url != nil
                               ? loc("Stored in the Keychain") : loc("Missing"))
            }
            LabeledContent(loc("Servers"), value: "\(source.servers.count)")
            if let format = source.lastFormat {
                LabeledContent(loc("Format"), value: format.label)
            }
            if let updated = source.lastUpdated {
                LabeledContent(loc("Last updated"),
                               value: updated.formatted(date: .abbreviated, time: .shortened))
            }
            if let expires = source.expiresAt {
                LabeledContent(loc("Expires"),
                               value: expires.formatted(date: .abbreviated, time: .omitted))
            }
            if let used = source.usedBytes {
                LabeledContent(loc("Traffic"), value: source.totalBytes.map {
                    $0 > 0 ? "\(ByteFormat.string(used)) / \(ByteFormat.string($0))"
                           : "\(ByteFormat.string(used)) · \(loc("Unlimited"))"
                } ?? ByteFormat.string(used))
            }
            if let hours = source.updateIntervalHours {
                LabeledContent(loc("Panel asks to refresh every"), value: "\(hours) \(loc("h"))")
            }
            SubscriptionDetails(subscription: source)
        }

        Section {
            Button {
                store.addAutoGroup(named: source.name, query: GroupQuery(sourceIDs: [source.id]))
                madeGroup = true
            } label: {
                Label(madeGroup ? loc("Group created") : loc("Make a fastest-node group"),
                      systemImage: madeGroup ? "checkmark" : "bolt.horizontal")
            }
            .disabled(madeGroup)
            if !source.isManual {
                Button {
                    Task {
                        isRefreshing = true
                        await SubscriptionService.refresh(source, into: store)
                        isRefreshing = false
                    }
                } label: {
                    HStack {
                        Label(loc("Refresh now"), systemImage: "arrow.clockwise")
                        if isRefreshing { Spacer(); ProgressView() }
                    }
                }
                .disabled(isRefreshing)
                Toggle(loc("Auto-update"), isOn: Binding(
                    get: { source.autoUpdate },
                    set: { store.setAutoUpdate($0, id: source.id) }
                ))
                Toggle(loc("Send HWID with subscription requests"), isOn: Binding(
                    get: { source.sendHWID ?? store.settings.sendHwid },
                    set: { value in store.mutateSubscription(id: source.id) { $0.sendHWID = value } }
                ))
                .disabled(source.hwidStatus == .notSupported)
                Button {
                    if let url = store.subscriptionURL(for: source) {
                        UIPasteboard.general.string = url
                    }
                } label: {
                    Label(loc("Copy subscription link"), systemImage: "link")
                }
            }
        } footer: {
            Text(loc("One group over this source, re-measured as it changes."))
        }
    }

    private func nodeRow(_ server: ProxyConfig) -> some View {
        HStack(spacing: 8) {
            Text(server.proto.rawValue.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(server.xraySupported ? Color.secondary : Color.orange)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.annotation(for: server.id).nameOverride ?? server.name)
                    .lineLimit(1)
                Text(verbatim: "\(server.address):\(server.port)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}
