import SwiftUI

/// The server list: the connect control on top, then every source, group and
/// node, arranged and narrowed the way the user asked.
///
/// What is shown is decided by `ServerListBuilder` — the same function the Mac
/// uses — so the two apps cannot disagree about order, grouping or filtering.
struct ContentView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc

    @State private var showAddSheet = false
    @State private var showLog = false
    @State private var showFilters = false
    @State private var isRefreshing = false
    @State private var searchText = ""
    @State private var aliveOnly = false
    @State private var sortByPing = false
    @State private var selectedTags: Set<String> = []
    @State private var selectedCountries: Set<String> = []
    @State private var selectedProtocols: Set<ProxyProtocol> = []
    /// Drives edit mode by hand instead of using `EditButton`: system controls
    /// draw their own title from the *device* language, which would ignore the
    /// language picked in this app's settings.
    @State private var isArranging = false

    @State private var qrServer: ProxyConfig?
    @State private var annotating: ProxyConfig?
    @State private var inspecting: ProxyConfig?
    @State private var groupDetail: ServerGroup?

    private var filter: ListFilter {
        var filter = ListFilter()
        filter.search = searchText
        filter.aliveOnly = aliveOnly
        filter.sortByPing = sortByPing
        filter.tags = Array(selectedTags)
        filter.countries = Array(selectedCountries)
        filter.protocols = Array(selectedProtocols)
        filter.showHidden = store.settings.showHiddenNodes
        let results = pinger.results
        filter.latency = { id in results[id] ?? nil }
        return filter
    }

    private var activeFilterCount: Int {
        selectedTags.count + selectedCountries.count + selectedProtocols.count
            + (aliveOnly ? 1 : 0)
    }

    var body: some View {
        let sections = store.listSections(filter: filter)

        NavigationStack {
            List {
                Section { StatusCard().listRowInsets(EdgeInsets()) }

                if store.subscriptions.isEmpty && store.settings.serverGroups.isEmpty {
                    Section { emptyState }
                } else if sections.isEmpty {
                    Section {
                        Text(loc("Nothing matches the current filters."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(sections) { section in
                        ServerSectionView(section: section,
                                          isArranging: isArranging,
                                          qrServer: $qrServer,
                                          annotating: $annotating,
                                          inspecting: $inspecting,
                                          groupDetail: $groupDetail)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The default gap between inset sections is sized for settings
            // screens; between a list's cards it reads as empty space.
            .listSectionSpacing(12)
            .contentMargins(.top, 8, for: .scrollContent)
            .environment(\.editMode, .constant(isArranging ? .active : .inactive))
            .navigationTitle("Veil")
            .navigationBarTitleDisplayMode(.inline)
            // Pinned open. The automatic drawer collapses and re-expands as
            // the list is pulled, which jumps the field on pull-to-refresh.
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: loc("Search servers…"))
            // Pull-to-refresh draws its own spinner. Flipping `isRefreshing`
            // here would also swap the toolbar button mid-drag, which makes
            // the navigation bar relayout under the finger.
            .refreshable { await SubscriptionService.refreshAll(store) }
            .toolbar { toolbarContent }
            .sheet(isPresented: $showAddSheet) { AddView() }
            .sheet(isPresented: $showLog) { LogView() }
            .sheet(isPresented: $showFilters) {
                FilterSheet(aliveOnly: $aliveOnly,
                            sortByPing: $sortByPing,
                            selectedTags: $selectedTags,
                            selectedCountries: $selectedCountries,
                            selectedProtocols: $selectedProtocols)
            }
            .sheet(item: $qrServer) { QRDisplayView(server: $0) }
            .sheet(item: $annotating) { NodeAnnotationView(server: $0) }
            .sheet(item: $inspecting) { server in
                NodeEditorView(server: server,
                               isEditable: store.subscriptionContaining(serverID: server.id)?.isManual == true)
            }
            .sheet(item: $groupDetail) { GroupMembersView(group: $0) }
            // A filter whose chips are gone would narrow the list invisibly.
            .onChange(of: store.settings.listGrouping) { _, _ in store.save() }
            .onChange(of: sortByPing) { _, on in if on { pingAllIfUntested() } }
            .onChange(of: aliveOnly) { _, on in if on { pingAllIfUntested() } }
            .onChange(of: store.settings.autoTags) { _, on in
                if !on { selectedCountries = []; selectedTags = [] }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showAddSheet = true } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel(loc("Add"))
        }
        if !isArranging && !store.allServers.isEmpty {
            ToolbarItem(placement: .topBarTrailing) { viewMenu }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isArranging {
                Button(loc("Done")) { withAnimation { isArranging = false } }
                    .fontWeight(.semibold)
            } else {
                Menu {
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label(loc("Refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)

                    Button {
                        pinger.test(store.allServers)
                    } label: {
                        Label(loc("Test Ping"), systemImage: "speedometer")
                    }
                    .disabled(store.allServers.isEmpty)

                    Button {
                        withAnimation { isArranging = true }
                    } label: {
                        Label(loc("Arrange"), systemImage: "arrow.up.arrow.down")
                    }
                    .disabled(store.allServers.isEmpty)

                    Divider()

                    Button { showLog = true } label: {
                        Label(loc("Log"), systemImage: "text.alignleft")
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    /// How the list is divided up, and what narrows it. Both answer the same
    /// question — what am I looking at — and neither belongs in Settings. One
    /// system menu in the bar, the way Mail and Files do it, rather than a row
    /// of home-made buttons over the list.
    private var viewMenu: some View {
        @Bindable var store = store
        let narrowed = activeFilterCount > 0 || sortByPing
        return Menu {
            Picker(selection: $store.settings.listGrouping) {
                ForEach(ListGrouping.allCases) { grouping in
                    Label(loc(grouping.title), systemImage: grouping.icon).tag(grouping)
                }
            } label: {
                Label(loc("Group by"), systemImage: store.settings.listGrouping.icon)
            }
            .pickerStyle(.menu)

            Toggle(isOn: $sortByPing) {
                Label(loc("By ping"), systemImage: "arrow.up.arrow.down")
            }

            Divider()

            Button {
                showFilters = true
            } label: {
                Label(activeFilterCount > 0
                      ? "\(loc("Filters")): \(activeFilterCount)"
                      : loc("Filters"),
                      systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: narrowed
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(loc("Filters"))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(loc("No servers yet")).font(.headline)
            Text(loc("Paste a server link or a subscription URL to get started."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddSheet = true
            } label: {
                // Without an explicit label style the button drops the icon and
                // shows a bare word.
                Label(loc("Add"), systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowBackground(Color.clear)
    }

    private func refreshAll() async {
        isRefreshing = true
        await SubscriptionService.refreshAll(store)
        isRefreshing = false
    }

    /// Measures every server, unless a measurement is already there or running.
    /// Both list filters are meaningless without one.
    private func pingAllIfUntested() {
        guard !pinger.hasResults, !pinger.isBusy else { return }
        pinger.test(store.allServers)
    }
}

// MARK: - One section

/// One section of the list. Under subscription grouping it is a source, with
/// the source's traffic, expiry and actions in its first row; under the other
/// groupings it is a facet — a country or a tag — and the header is a name and
/// a count.
struct ServerSectionView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc
    @Environment(MenuBackdrop.self) private var backdrop

    let section: ListSection
    var isArranging: Bool
    @Binding var qrServer: ProxyConfig?
    @Binding var annotating: ProxyConfig?
    @Binding var inspecting: ProxyConfig?
    @Binding var groupDetail: ServerGroup?

    /// The width a row's content gets, so a long-press preview can be drawn
    /// as wide as the row it lifts out of.
    @State private var rowWidth: CGFloat = 0

    private var subscription: Subscription? {
        guard let id = section.subscriptionID else { return nil }
        return store.subscriptions.first { $0.id == id }
    }

    var body: some View {
        // The heading is the section's first *row*, not its header, so it
        // shares the one rounded card the list draws around a section instead
        // of floating on its own slab next to it.
        Section {
            if let subscription {
                SubscriptionHeaderRow(subscription: subscription,
                                      count: section.servers.count + section.groups.count)
            } else {
                facetHeader
            }
            if !section.isCollapsed {
                ForEach(section.groups) { group in
                    groupRow(group)
                }
                ForEach(section.servers) { server in
                    serverRow(server)
                }
                .onMove(perform: mover)
                if section.hiddenCount > 0 && !isArranging {
                    hiddenFooter
                }
            }
        }
    }

    /// Only while arranging: a list that can always be dragged steals the
    /// long press the context menu lives on.
    private var mover: ((IndexSet, Int) -> Void)? {
        guard isArranging else { return nil }
        return { source, destination in move(from: source, to: destination) }
    }

    private var facetHeader: some View {
        HStack(spacing: 8) {
            if section.subscriptionID == ServerStore.ownGroupsSourceID {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
            }
            Text(loc(section.title))
                .font(.headline)
                .lineLimit(1)
            Text(verbatim: "\(section.servers.count + section.groups.count)")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.secondary.opacity(0.18)))
            Spacer()
            if !section.servers.isEmpty {
                Button {
                    pinger.test(section.servers)
                } label: {
                    Image(systemName: "speedometer")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(loc("Test ping (group)"))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Group rows

    private func groupRow(_ row: ProxyConfig) -> some View {
        let group = store.group(withID: row.id)
        let isActive = tunnel.isConnected && tunnel.activeServerID == row.id
        let content = ServerRow(server: row,
                                isSelected: store.selectedServerID == row.id,
                                isActive: isActive,
                                latency: nil,
                                isTesting: false,
                                group: group,
                                via: isActive ? favouredMember(group) : nil)
        return content
            .contentShape(Rectangle())
            .background(widthReader)
            .onTapGesture { if !isArranging { handleTap(row.id) } }
            .contextMenu {
                Button(tunnel.isConnected ? loc("Switch here") : loc("Connect"),
                       systemImage: "bolt.fill") {
                    store.select(row.id)
                    Task { await tunnel.connect(to: row.id, store: store) }
                }
                .disabled(!store.canRun(row.id))
                if let group {
                    Button(loc("Members and latency"), systemImage: "list.bullet") {
                        groupDetail = group
                    }
                    // A group has no latency of its own: it is whichever member
                    // the core finds quickest, so the useful measurement is theirs.
                    Button(loc("Test ping"), systemImage: "speedometer") {
                        pinger.test(store.members(of: group))
                    }
                    if store.isOwnGroup(group.id) {
                        Divider()
                        Button(loc("Delete group"), systemImage: "trash", role: .destructive) {
                            // By value: reading the row's own binding inside the
                            // removal traps with an exclusivity conflict.
                            let id = group.id
                            store.removeGroup(id: id)
                        }
                    }
                }
            } preview: {
                previewCard(content)
            }
    }

    /// The member a "fastest" group's probes put first.
    private func favouredMember(_ group: ServerGroup?) -> String? {
        guard let group, group.kind == .urltest else { return nil }
        let measured = store.members(of: group).compactMap { member -> (String, Int64)? in
            guard let seen = tunnel.observed(member.id), seen.alive else { return nil }
            return (store.annotation(for: member.id).nameOverride ?? member.name, seen.delay)
        }
        guard let best = measured.min(by: { $0.1 < $1.1 }) else { return nil }
        return "\(best.0) · \(best.1) ms"
    }

    // MARK: Server rows

    private func serverRow(_ server: ProxyConfig) -> some View {
        let isActive = tunnel.isConnected && tunnel.activeServerID == server.id
        let annotation = store.annotation(for: server.id)
        let isManual = store.subscriptionContaining(serverID: server.id)?.isManual == true

        let content = ServerRow(server: server,
                                isSelected: store.selectedServerID == server.id,
                                isActive: isActive,
                                latency: pinger.latency(for: server.id),
                                isTesting: pinger.isTesting(server.id),
                                annotation: annotation,
                                autoTags: store.settings.autoTags)
        return content
            .contentShape(Rectangle())
            .background(widthReader)
            .onTapGesture { if !isArranging { handleTap(server.id) } }
            .contextMenu {
                Button(tunnel.isConnected ? loc("Switch here") : loc("Connect"),
                       systemImage: "bolt.fill") {
                    store.select(server.id)
                    Task { await tunnel.connect(to: server.id, store: store) }
                }
                .disabled(!server.xraySupported)
                Button(loc("Test ping"), systemImage: "speedometer") { pinger.test([server]) }
                Divider()
                Button(annotation.pinned ? loc("Unpin") : loc("Pin"),
                       systemImage: annotation.pinned ? "pin.slash" : "pin") {
                    store.togglePinned(serverID: server.id)
                }
                Button(annotation.hidden ? loc("Unhide") : loc("Hide"),
                       systemImage: annotation.hidden ? "eye" : "eye.slash") {
                    store.setHidden(!annotation.hidden, serverID: server.id)
                }
                Button(loc("Rename and tag…"), systemImage: "tag") { annotating = server }
                if annotation.sortIndex != nil {
                    Button(loc("Reset manual order"), systemImage: "arrow.uturn.backward") {
                        store.clearManualOrder(section: section.servers.map(\.id))
                    }
                }
                Divider()
                Button(isManual ? loc("Edit") : loc("Inspect"),
                       systemImage: "curlybraces") { inspecting = server }
                Button(loc("Copy link"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = LinkBuilder.link(for: server)
                }
                Button(loc("Show QR code"), systemImage: "qrcode") { qrServer = server }
                if isManual && !isActive {
                    Divider()
                    Button(loc("Delete"), systemImage: "trash", role: .destructive) {
                        let id = server.id
                        store.removeServer(id: id)
                    }
                }
            } preview: {
                previewCard(content)
            }
            .swipeActions(edge: .leading) {
                Button {
                    store.togglePinned(serverID: server.id)
                } label: {
                    Label(annotation.pinned ? loc("Unpin") : loc("Pin"),
                          systemImage: annotation.pinned ? "pin.slash" : "pin")
                }
                .tint(.orange)
            }
            .swipeActions(edge: .trailing) {
                if isManual && !isActive {
                    Button(role: .destructive) {
                        let id = server.id
                        store.removeServer(id: id)
                    } label: {
                        Label(loc("Delete"), systemImage: "trash")
                    }
                }
                Button {
                    store.setHidden(!annotation.hidden, serverID: server.id)
                } label: {
                    Label(annotation.hidden ? loc("Unhide") : loc("Hide"),
                          systemImage: annotation.hidden ? "eye" : "eye.slash")
                }
                .tint(.gray)
            }
    }

    // MARK: Long-press preview

    /// Left to itself the menu lifts the bare row content: cut flush to the
    /// text, square-cornered, and on iOS 26 over an unblurred list. A preview
    /// of its own is a padded, rounded card, and gets the blurred backdrop.
    private func previewCard(_ content: some View) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(width: rowWidth > 0 ? rowWidth + 32 : nil, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            // The preview is hosted outside the list and inherits none of its
            // observable objects; a row reading one there traps.
            .environment(loc)
            .environment(store)
            .environment(tunnel)
            .environment(pinger)
            .liftsMenuBackdrop(backdrop)
    }

    private var widthReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { rowWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in rowWidth = width }
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
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    /// Records the order a drag left the section in. Dragging works inside a
    /// section only: under tag or country grouping a node's section is decided
    /// by what it is, so moving it elsewhere would mean nothing.
    private func move(from source: IndexSet, to destination: Int) {
        var order = section.servers.map(\.id)
        let moving = source.map { order[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { order.remove(at: index) }
        order.insert(contentsOf: moving, at: max(0, min(insertAt, order.count)))
        store.reorder(section: order)
    }

    /// Disconnected: tap selects. Connected: tap switches straight away, which
    /// only restarts the core inside the extension — the tunnel never drops.
    private func handleTap(_ id: UUID) {
        store.select(id)
        guard tunnel.isConnected, store.canRun(id) else { return }
        Task { await tunnel.connect(to: id, store: store) }
    }
}

// MARK: - Status card

/// The connect/disconnect hero at the top of the list: state, active server,
/// uptime and live traffic counters read back from the tunnel provider.
struct StatusCard: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(Loc.self) private var loc

    @State private var holdProgress: CGFloat = 0
    @State private var isHolding = false

    private var selectedID: UUID? { store.selectedServerID }
    private var selected: ProxyConfig? { store.server(withID: selectedID) }

    var body: some View {
        // Kept compact on purpose: this sits above the server list, and every
        // point it takes is a row the user has to scroll for.
        VStack(spacing: 12) {
            shieldControl

            VStack(spacing: 2) {
                Text(stateLabel)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if tunnel.isConnected {
                HStack(spacing: 20) {
                    trafficLabel(icon: "arrow.up", bytes: tunnel.uplinkBytes)
                    trafficLabel(icon: "arrow.down", bytes: tunnel.downlinkBytes)
                    if let since = tunnel.connectedSince {
                        // Drawn by the system from the start time; nothing in
                        // the app ticks to keep it current.
                        Label {
                            Text(since, style: .timer)
                        } icon: {
                            Image(systemName: "clock")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if tunnel.hasUnappliedChanges(store: store) {
                Button {
                    Task { await tunnel.applyChanges(store: store) }
                } label: {
                    Label(loc("Apply now"), systemImage: "arrow.clockwise.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
            } else {
                Text(holdHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// The shield *is* the connect control — hold it to toggle the tunnel.
    /// A deliberate press beats a button you can hit by accident, since
    /// dropping the VPN mid-session is disruptive.
    private var shieldControl: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.16))
                .frame(width: 104, height: 104)

            // Fills while held; completing the ring is what fires the action.
            Circle()
                .trim(from: 0, to: holdProgress)
                .stroke(statusColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 104, height: 104)

            Image(systemName: tunnel.isConnected ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .opacity(canToggle ? 1 : 0.4)
        .scaleEffect(isHolding ? 0.93 : 1)
        .animation(.easeOut(duration: 0.15), value: isHolding)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: Self.holdDuration) {
            toggle()
        } onPressingChanged: { pressing in
            guard canToggle else { return }
            isHolding = pressing
            withAnimation(.linear(duration: pressing ? Self.holdDuration : 0.2)) {
                holdProgress = pressing ? 1 : 0
            }
        }
        .accessibilityLabel(holdHint)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private static let holdDuration: TimeInterval = 0.6

    /// False while a connect is already in flight, or when the selection is
    /// one the Xray-only build cannot run.
    private var canToggle: Bool {
        if tunnel.isConnected { return true }
        guard tunnel.state != .connecting else { return false }
        return store.canRun(selectedID)
    }

    private var holdHint: String {
        if !canToggle && !tunnel.isConnected { return " " }
        return tunnel.isConnected ? loc("Hold to disconnect") : loc("Hold to connect")
    }

    private func toggle() {
        guard canToggle else { return }
        withAnimation(.easeOut(duration: 0.2)) { holdProgress = 0 }
        isHolding = false
        if tunnel.isConnected {
            tunnel.disconnect()
        } else if let id = selectedID {
            Task { await tunnel.connect(to: id, store: store) }
        }
    }

    private func trafficLabel(icon: String, bytes: Int64) -> some View {
        Label(ByteFormat.string(bytes), systemImage: icon)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private var stateLabel: String {
        switch tunnel.state {
        case .disconnected: return loc("Disconnected")
        case .connecting:   return loc("Connecting…")
        case .connected:    return loc("Connected")
        case .failed:       return loc("Failed")
        }
    }

    private var subtitle: String {
        if case .failed(let message) = tunnel.state { return loc(message) }
        if tunnel.isConnected { return tunnel.activeServerName }
        if let selected {
            let name = store.annotation(for: selected.id).nameOverride ?? selected.name
            return store.canRun(selected.id)
                ? name
                : "\(name) — \(loc("not supported on iOS"))"
        }
        return loc("Select a server")
    }

    private var statusColor: Color {
        switch tunnel.state {
        case .connected:    return .green
        case .connecting:   return .orange
        case .failed:       return .red
        case .disconnected: return .secondary
        }
    }
}
