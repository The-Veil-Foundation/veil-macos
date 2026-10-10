import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ServerStore.self) private var store
    @Environment(ConnectionManager.self) private var connection
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc

    @State private var showAddSheet = false
    @State private var showLog = false
    @State private var isRefreshing = false
    @State private var searchText = ""
    @State private var aliveOnly = false
    @State private var sortByPing = false
    /// Tag and country chips the user turned on. Chips of one kind are OR-ed,
    /// chips of different kinds narrow each other.
    @State private var selectedTags: Set<String> = []
    @State private var selectedCountries: Set<String> = []
    /// Which half of the window is on screen: the list you connect from, or the
    /// sources that fill it.
    @State private var mode: MainMode = .connection
    /// IDs selected for multi-delete in the Manual group.
    @State private var selectedForDeletion: Set<UUID> = []
    @State private var selectionMode = false
    /// True when a helper is installed but pinned to a different build of Veil.
    @State private var helperStale = false
    @State private var helperBusy = false

    /// True when the active tunnel is TUN — ping probes need host-routes then.
    private var tunActive: Bool {
        connection.mode == .tun && connection.isConnected
    }

    /// Drives keyboard focus so arrow keys / Enter target the server list.
    @FocusState private var listFocused: Bool

    /// Servers in on-screen order across all groups, honouring collapse state,
    /// search text, the alive filter, and ping sort. This is the order the
    /// up/down arrow keys walk through.
    private var navigableServers: [ProxyConfig] {
        store.listSections(filter: listFilter).flatMap { section in
            section.isCollapsed ? [] : section.groups + section.servers
        }
    }

    /// Everything the list header asks of the list, in one value. The rows on
    /// screen and the order the arrow keys walk are built from this same
    /// filter, so they cannot drift apart.
    private var listFilter: ListFilter {
        var filter = ListFilter()
        filter.search = searchText
        filter.aliveOnly = aliveOnly
        filter.sortByPing = sortByPing
        filter.tags = Array(selectedTags)
        filter.countries = Array(selectedCountries)
        filter.showHidden = store.settings.showHiddenNodes
        filter.latency = { [pinger] id in (pinger.latency(for: id) ?? nil) }
        return filter
    }

    /// Moves the selection up or down the visible list. Selecting a server while
    /// connected switches to it immediately (matching tap behaviour); while
    /// disconnected it just highlights, and Enter connects.
    private func moveSelection(by delta: Int) {
        let list = navigableServers
        guard !list.isEmpty else { return }
        let currentIdx = list.firstIndex { $0.id == store.selectedServerID }
        let nextIdx: Int
        if let currentIdx {
            nextIdx = min(max(currentIdx + delta, 0), list.count - 1)
        } else {
            // No selection yet: down picks the first, up picks the last.
            nextIdx = delta > 0 ? 0 : list.count - 1
        }
        store.select(list[nextIdx].id)
    }

    /// Connects to the currently-selected server (Enter / Return).
    private func connectSelected() {
        if let s = store.server(withID: store.selectedServerID) {
            connection.connect(to: s)
        }
    }

    var body: some View {
        @Bindable var store = store
        return VStack(spacing: 0) {
            // Its own view, so a change of connection state redraws the header
            // and not the server list beneath it.
            ConnectionHeader()
            Divider()
            staleHelperBanner
            modeSwitcher
            if mode == .sources && store.settings.showSourcesTab {
                SourcesView()
            } else {
                searchBar
                listControls
                serverList
            }
            if showLog {
                // Reads the log itself: read here, every line the core printed
                // would re-run this whole body — filters, chips and list.
                ConnectionLogPane(height: $store.settings.logPaneHeight,
                                  onHeightCommit: { store.save() })
                    .frame(height: store.settings.logPaneHeight)
            }
            Divider()
            footer
        }
        .sheet(isPresented: $showAddSheet) { AddServerSheet() }
        // Measure once on the first appearance, so the list carries latencies
        // without the user having to know a Test Ping button exists.
        .task { pingAllIfUntested() }
        .task { await refreshHelperStaleness() }
    }

    // MARK: - Stale helper

    /// Says so when the helper refuses this build, and offers the one fix.
    ///
    /// The helper pins its client by ad-hoc code hash, which changes with every
    /// build — including the one an in-app update installs. TUN then cannot
    /// start at all, and the only clue is a connection that never comes up, so
    /// this cannot wait for the user to open Settings and read the helper row.
    @ViewBuilder
    private var staleHelperBanner: some View {
        if helperStale, store.settings.mode == .tun {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("Helper needs reinstalling"))
                        .font(.callout)
                    Text(loc("The installed helper was pinned to an older build of Veil and refuses this one, so TUN cannot start."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if helperBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(loc("Reinstall")) { reinstallHelper() }
                        .glassProminentButton()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.12))
            Divider()
        }
    }

    private func refreshHelperStaleness() async {
        // Both calls block on an XPC round trip, so they stay off the main
        // thread — this runs while the window is drawing itself.
        helperStale = await Task.detached(priority: .utility) {
            !TunManager.isHelperInstalled && PrivilegedHelper.isInstalled
        }.value
    }

    private func reinstallHelper() {
        helperBusy = true
        Task.detached(priority: .userInitiated) {
            try? TunManager.installHelper()
            let stale = !TunManager.isHelperInstalled && PrivilegedHelper.isInstalled
            await MainActor.run {
                helperStale = stale
                helperBusy = false
            }
        }
    }

    // MARK: - Search & filter

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(loc("Search servers…"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            Divider().frame(height: 16)
            Toggle(loc("Alive"), isOn: $aliveOnly)
                .glassToggle().controlSize(.small)
                .help(loc("Show only servers that answered a ping. Turning this on measures them first."))
                // Without this the filter empties the whole list on a fresh
                // launch: nothing has been measured yet, so nothing is "alive".
                .onChange(of: aliveOnly) { _, on in
                    if on { pingAllIfUntested() }
                }
            Toggle(loc("By ping"), isOn: $sortByPing)
                .glassToggle().controlSize(.small)
                .help(loc("Sort servers by latency within each group"))
                .onChange(of: sortByPing) { _, on in
                    if on { pingAllIfUntested() }
                }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    /// The two halves of the main window. Where servers come from is a
    /// different question from which one is in use, and answering it used to
    /// mean a settings window with no view of the configuration at all.
    @ViewBuilder
    private var modeSwitcher: some View {
        // With the Sources page switched off there is one tab left, and a
        // segmented control with one segment is a label.
        if store.settings.showSourcesTab {
            Picker("", selection: $mode) {
                ForEach(MainMode.allCases) { mode in
                    Text(loc(mode.title)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
        }
    }

    /// How the list is divided up, and the chips that narrow it. Both sit
    /// under the search field because they answer the same question — what am
    /// I looking at — and neither belongs in a settings window.
    @ViewBuilder
    private var listControls: some View {
        @Bindable var store = store
        // Both rows are read out of the node names, so they answer to the same
        // switch: turning name-reading off and still being shown a row of
        // countries the app guessed is the setting not doing what it says.
        let countries = store.settings.autoTags ? countriesInUse : []
        let tags = store.allTags

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker(selection: $store.settings.listGrouping) {
                    ForEach(ListGrouping.allCases) { grouping in
                        Label(loc(grouping.title), systemImage: grouping.icon).tag(grouping)
                    }
                } label: {
                    Text(loc("Group by"))
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help(loc("Arrange the list by subscription, by tag, or by country. Tags and countries merge every subscription into one list."))
                .onChange(of: store.settings.listGrouping) { _, _ in store.save() }

                Spacer()

                if !selectedTags.isEmpty || !selectedCountries.isEmpty {
                    Button(loc("Clear filters")) {
                        selectedTags = []
                        selectedCountries = []
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }

            if countries.count > 1 || !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(countries, id: \.self) { code in
                        chip(title: NodeFacets.flag(for: code) + " " + NodeFacets.countryName(for: code),
                             isOn: selectedCountries.contains(code)) {
                            toggle(code, in: &selectedCountries)
                        }
                    }
                    ForEach(tags, id: \.self) { tag in
                        chip(title: tag, isOn: selectedTags.contains(tag)) {
                            toggle(tag, in: &selectedTags)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        // A filter whose chips are gone would narrow the list invisibly.
        .onChange(of: store.settings.autoTags) { _, on in
            if !on { selectedCountries = []; selectedTags = [] }
        }
    }

    /// The places the user actually has servers in, in the order the list shows
    /// them.
    private var countriesInUse: [String] {
        var seen = Set<String>()
        var codes: [String] = []
        for server in store.allServers {
            guard let code = NodeFacets(for: server).country, seen.insert(code).inserted else {
                continue
            }
            codes.append(code)
        }
        return codes.sorted {
            NodeFacets.countryName(for: $0).localizedStandardCompare(
                NodeFacets.countryName(for: $1)) == .orderedAscending
        }
    }

    private func chip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(isOn
                    ? Color.accentColor.opacity(0.25)
                    : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ value: String, in set: inout Set<String>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    /// Measures every server, unless a measurement is already there or running.
    /// Both list filters are meaningless without one, so they ask for it rather
    /// than showing an empty list and leaving the user to guess why.
    private func pingAllIfUntested() {
        guard !pinger.hasResults, !pinger.isBusy else { return }
        pinger.test(store.allServers, tunActive: tunActive)
    }

    // MARK: - Server list (collapsible groups)

    private var serverList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if store.subscriptions.isEmpty {
                        emptyState
                    }
                    ServerListView(filter: listFilter,
                                   selectionMode: selectionMode,
                                   selectedForDeletion: $selectedForDeletion)
                }
                .padding(12)
            }
            .frame(minHeight: 80, maxHeight: .infinity)
            // Keep the keyboard-selected row visible as it moves.
            .onChange(of: store.selectedServerID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        // Make the list the keyboard focus target and wire arrow keys + Enter.
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
        .onKeyPress(.return) { connectSelected(); return .handled }
        .onAppear { listFocused = true }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(loc("No servers yet")).font(.headline)
            Text(loc("Add a subscription or paste a link to get started."))
                .font(.caption).foregroundStyle(.secondary)
            Button(loc("Add")) { showAddSheet = true }
                .glassProminentButton()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: - Footer (toolbar)

    private var hasManualServers: Bool {
        store.subscriptions.contains { $0.isManual && !$0.servers.isEmpty }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if selectionMode { deletionBar }
            HStack(spacing: 12) {
                Button { showAddSheet = true } label: {
                    Label(loc("Add"), systemImage: "plus")
                }
                .glassButton()
                Button {
                    Task {
                        isRefreshing = true
                        await SubscriptionService.refreshAll(store)
                        isRefreshing = false
                        // A refresh can replace every node, so the latencies on
                        // screen now belong to servers that may be gone.
                        pinger.clear()
                        pinger.test(store.allServers, tunActive: tunActive)
                    }
                } label: {
                    if isRefreshing { ProgressView().controlSize(.small) }
                    else { Label(loc("Refresh"), systemImage: "arrow.clockwise") }
                }
                .glassButton()
                .disabled(isRefreshing)

                Button {
                    pinger.test(store.allServers, tunActive: tunActive)
                } label: {
                    Label(loc("Test Ping"), systemImage: "speedometer")
                }
                .glassButton()
                .disabled(store.allServers.isEmpty)

                if hasManualServers {
                    Button {
                        selectionMode.toggle()
                        selectedForDeletion.removeAll()
                    } label: {
                        Label(loc("Select"), systemImage: selectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .glassButton()
                }

                Spacer()

                Toggle(isOn: $showLog) { Label(loc("Log"), systemImage: "text.alignleft") }
                    .glassToggle()
                // Settings is a scene now, so this opens the same window ⌘,
                // does instead of a second, sheet-shaped copy of it.
                Button {
                    openWindow(id: WindowID.settings)
                } label: {
                    Label(loc("Settings"), systemImage: "gearshape")
                }
                .glassButton()
            }
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    /// Bar shown in multi-select mode: select-all / delete-selected / cancel.
    private var deletionBar: some View {
        // The active server can't be deleted while connected.
        let activeID = connection.isConnected ? connection.activeServerID : nil
        let manualIDs = Set(store.subscriptions.filter(\.isManual)
            .flatMap { $0.servers.map(\.id) })
            .subtracting(activeID.map { [$0] } ?? [])
        let allSelected = !manualIDs.isEmpty && selectedForDeletion == manualIDs
        return HStack(spacing: 12) {
            Button(allSelected ? loc("Deselect All") : loc("Select All")) {
                selectedForDeletion = allSelected ? [] : manualIDs
            }
            .glassButton()
            Text(verbatim: "\(selectedForDeletion.count)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                // Never delete the active server even if somehow selected.
                store.removeServers(ids: selectedForDeletion.subtracting(activeID.map { [$0] } ?? []))
                selectedForDeletion.removeAll()
                selectionMode = false
            } label: {
                Label(loc("Delete Selected"), systemImage: "trash")
            }
            .glassProminentButton().tint(.red)
            .disabled(selectedForDeletion.isEmpty)
            Button(loc("Cancel")) {
                selectionMode = false
                selectedForDeletion.removeAll()
            }
            .glassButton()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }
}

// MARK: - Header (status + connect)

/// Status, mode switch and the connect button.
private struct ConnectionHeader: View {
    @Environment(ServerStore.self) private var store
    @Environment(ConnectionManager.self) private var connection
    @Environment(Loc.self) private var loc

    var body: some View {
        let selected = store.server(withID: store.selectedServerID)
        return HStack(spacing: 14) {
            ZStack {
                Circle().fill(statusColor.opacity(0.18)).frame(width: 44, height: 44)
                Image(systemName: connection.isConnected ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(statusLabel)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                if connection.isConnected {
                    HStack(spacing: 0) {
                        Text(verbatim: "\(connection.activeServerName) · ")
                        // Drawn by the system from the start date: no app
                        // timer, no redraw of anything else once a second.
                        if let since = connection.connectedSince {
                            Text(since, style: .timer).monospacedDigit()
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
                } else if let selected {
                    Text(selected.name).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text(loc("Select a server")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            modePicker
            connectButton(selected: selected)
        }
        .padding(14)
    }

    private var modePicker: some View {
        @Bindable var conn = connection
        return ModeGlassSwitch(
            mode: $conn.mode,
            isDisabled: connection.isConnected
        ) { newMode in
            store.settings.mode = newMode
            store.save()
        }
        .help(connection.mode.subtitle)
    }

    @ViewBuilder
    private func connectButton(selected: ProxyConfig?) -> some View {
        if connection.isConnected || connection.state == .connecting {
            Button(role: .destructive) { connection.disconnect() } label: {
                Label(loc("Disconnect"), systemImage: "stop.fill").frame(minWidth: 96)
            }
            .controlSize(.large).glassProminentButton().tint(.red)
        } else {
            Button {
                if let s = selected { connection.connect(to: s) }
            } label: {
                Label(loc("Connect"), systemImage: "bolt.fill").frame(minWidth: 96)
            }
            .controlSize(.large).glassProminentButton()
            .disabled(selected == nil)
        }
    }

    /// The connection state, translated. `failed` carries the core's own
    /// message, which is not ours to translate, so only the label around it is.
    private var statusLabel: String {
        switch connection.state {
        case .disconnected:  return loc("Disconnected")
        case .connecting:    return loc("Connecting…")
        case .connected:     return loc("Connected")
        case .failed(let m): return "\(loc("Failed")): \(m)"
        }
    }

    private var statusColor: Color {
        switch connection.state {
        case .connected:  return .green
        case .connecting: return .orange
        case .failed:     return .red
        case .disconnected: return .secondary
        }
    }
}

/// The log pane, fed from the connection.
///
/// Also tells the connection when it is on screen: in TUN mode the core's log
/// lives with the root helper and is fetched over XPC, which is only worth
/// doing while someone is reading it.
private struct ConnectionLogPane: View {
    @Environment(ConnectionManager.self) private var connection
    @Binding var height: Double
    var onHeightCommit: (() -> Void)? = nil

    var body: some View {
        LogPane(text: connection.logs,
                height: $height,
                onClear: { connection.clearLogs() },
                onHeightCommit: onHeightCommit)
            .onAppear { connection.setLogVisible(true) }
            .onDisappear { connection.setLogVisible(false) }
    }
}

// MARK: - Subscription group (collapsible)

// MARK: - Server row

struct ServerRow: View {
    @Environment(Loc.self) private var loc
    let server: ProxyConfig
    let isSelected: Bool
    let isActive: Bool
    let latency: Int??     // outer nil = untested; inner nil = unreachable
    let isTesting: Bool
    /// What the user attached to this node, if anything.
    var annotation = NodeAnnotation()
    /// Whether the row also shows the tags read out of the node's own name.
    var autoTags = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 7, height: 7)
            if annotation.pinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
            }
            Text(server.name).lineLimit(1)
                .foregroundStyle(annotation.hidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            // The user's own labels are drawn in the accent colour; the ones
            // read out of the name are plainer, because they are a reading
            // rather than a decision. Only the first few fit on a row.
            ForEach(Array(AutoTags.all(for: server, annotation: annotation,
                                       derived: autoTags).prefix(3)),
                    id: \.self) { tag in
                let isOwn = annotation.tags.contains(tag)
                Text(tag)
                    .font(.caption2)
                    .foregroundStyle(isOwn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(isOwn
                                               ? Color.accentColor.opacity(0.15)
                                               : Color.secondary.opacity(0.12)))
            }
            if server.isBalancer {
                Text(verbatim: "\((server.alternates?.count ?? 0) + 1)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
            Spacer()
            latencyBadge
            Text(server.proto.rawValue.uppercased())
                .font(.caption2).foregroundStyle(.secondary)
            if isActive {
                Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .padding(.leading, 18)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private var latencyBadge: some View {
        if isTesting {
            ProgressView().controlSize(.mini)
        } else if let outer = latency {
            if let ms = outer {
                Text(verbatim: "\(ms) ms")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(latencyColor(ms))
            } else {
                Text(loc("timeout"))
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<150:  return .green
        case ..<350:  return .orange
        default:      return .red
        }
    }
}

// MARK: - Compact log pane

struct LogPane: View {
    @Environment(Loc.self) private var loc
    let text: String
    /// The pane's height, dragged by the grabber along its top edge and kept
    /// in the settings, because a diagnostics pane that forgets how tall it
    /// was has to be resized on every launch.
    @Binding var height: Double
    var onClear: (() -> Void)? = nil
    /// Called when a drag ends, so the new height reaches disk once rather
    /// than on every frame of the drag.
    var onHeightCommit: (() -> Void)? = nil

    /// What is typed in the search box, and the severity floor.
    @State private var query = ""
    @State private var minimum: LogLevel = .none
    /// The height the current drag started from.
    @State private var dragStart: Double?

    private var shown: String {
        LogFilter.apply(text, query: query, minimum: minimum)
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || minimum != .none
    }

    /// Lines in `text`, counted without splitting it into a copy of itself.
    private func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        return text.utf8.last == UInt8(ascii: "\n") ? newlines : newlines + 1
    }

    var body: some View {
        let body = shown
        return VStack(spacing: 0) {
            grabber
            // Header toolbar.
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(loc("Logs"))
                    .font(.system(size: 12, weight: .semibold))
                // While a filter is on, both numbers: how much is on screen
                // and how much the core actually wrote.
                Text(verbatim: isFiltering ? "\(count(body))/\(count(text))"
                                           : "\(count(text))")
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                Spacer()
                TextField(loc("Filter"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 140)
                Picker(selection: $minimum) {
                    Text(loc("All levels")).tag(LogLevel.none)
                    ForEach(LogLevel.allCases.filter { $0 != .none }) { level in
                        Text(loc(level.title)).tag(level)
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small)
                .frame(width: 96)
                Button {
                    NSPasteboard.general.clearContents()
                    // What the eye sees: copying a thousand hidden lines is
                    // not what the button under a filtered pane means.
                    NSPasteboard.general.setString(body, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(loc("Copy all logs"))
                .disabled(text.isEmpty)
                Button {
                    onClear?()
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(loc("Clear logs"))
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .logHeaderBackground()

            Divider().opacity(0.5)

            // Scrollable monospaced body. An AppKit text view rather than a
            // SwiftUI `Text`: the log is thousands of lines, and `Text` laid
            // all of them out again — and animated a scroll — on every flush.
            LogTextView(text: body.isEmpty
                        ? (isFiltering ? loc("Nothing matches this filter.")
                                       : loc("No logs yet."))
                        : body,
                        isPlaceholder: body.isEmpty)
        }
        .logPaneBackground()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// The top edge, dragged to make the pane taller or shorter.
    private var grabber: some View {
        Capsule()
            .fill(Color.secondary.opacity(dragStart == nil ? 0.3 : 0.6))
            .frame(width: 38, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStart ?? height
                        if dragStart == nil { dragStart = base }
                        // Upwards is a negative translation and a taller pane.
                        height = AppSettings.clampedLogHeight(base - value.translation.height)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onHeightCommit?()
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help(loc("Drag to resize"))
    }
}

/// Read-only, selectable, monospaced log text.
///
/// New output that extends what is already shown is appended rather than
/// replacing the whole text, which keeps a selection alive while the core is
/// still printing. It follows the end only when the reader was already there,
/// so scrolling back to read an error is not undone by the next line.
private struct LogTextView: NSViewRepresentable {
    let text: String
    var isPlaceholder = false

    final class Coordinator {
        var shown = ""
        var placeholder = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 6, height: 8)
            textView.isAutomaticLinkDetectionEnabled = false
            textView.layoutManager?.allowsNonContiguousLayout = true
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        let state = context.coordinator
        guard state.shown != text || state.placeholder != isPlaceholder else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: isPlaceholder ? NSColor.secondaryLabelColor : NSColor.labelColor
        ]
        let visible = scroll.contentView.bounds
        let wasAtBottom = visible.maxY >= textView.frame.height - 24

        if !isPlaceholder, !state.placeholder, !state.shown.isEmpty,
           text.utf8.starts(with: state.shown.utf8) {
            let added = String(decoding: text.utf8.dropFirst(state.shown.utf8.count), as: UTF8.self)
            storage.append(NSAttributedString(string: added, attributes: attributes))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        state.shown = text
        state.placeholder = isPlaceholder
        if wasAtBottom { textView.scrollToEndOfDocument(nil) }
    }
}

extension View {
    /// Glass material behind the log panel on macOS 26+, with a solid
    /// text-background fallback on earlier systems.
    @ViewBuilder
    func logPaneBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.background(.regularMaterial)
        } else {
            self.background(Color(nsColor: .textBackgroundColor))
        }
    }

    /// Slightly tinted header strip so the toolbar reads above the body.
    @ViewBuilder
    func logHeaderBackground() -> some View {
        if #available(macOS 26.0, *) {
            self.background(.thinMaterial)
        } else {
            self.background(Color.primary.opacity(0.05))
        }
    }
}

// MARK: - Liquid Glass styling (macOS 26+) with graceful fallback

extension View {
    /// Applies the Liquid Glass button style on macOS 26+, falling back to the
    /// bordered style on earlier releases so the app still builds and runs on
    /// the .macOS(.v14) deployment target.
    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    /// Prominent Liquid Glass variant for primary actions (e.g. Connect).
    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// Keeps the window title on the titlebar line instead of letting it take
    /// a row of its own above the toolbar, which is what pushed the Settings
    /// tab switcher onto a second line.
    @ViewBuilder
    func inlineWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarTitleDisplayMode(.inline)
        } else {
            self
        }
    }

    /// Liquid Glass toggle (a button-style toggle that picks up the glass
    /// material when selected on macOS 26+), with a bordered-button fallback.
    @ViewBuilder
    func glassToggle() -> some View {
        if #available(macOS 26.0, *) {
            self.toggleStyle(.button).buttonStyle(.glass)
        } else {
            self.toggleStyle(.button)
        }
    }
}

// MARK: - Draggable Liquid Glass mode switch (Proxy / TUN)

/// A two-position switch styled with Liquid Glass. The glass thumb can be
/// tapped on either side or grabbed and dragged across to flip between System
/// Proxy and TUN. Falls back to a plain segmented look on pre-macOS 26.
private struct ModeGlassSwitch: View {
    @Binding var mode: TunnelMode
    var isDisabled: Bool
    var onChange: (TunnelMode) -> Void

    /// Live horizontal offset of the thumb while dragging (nil = snapped).
    @State private var dragX: CGFloat? = nil

    private let labels: [(TunnelMode, String)] = [
        (.systemProxy, "Proxy"), (.tun, "TUN"),
    ]
    private let height: CGFloat = 28
    private let segWidth: CGFloat = 66

    private var trackWidth: CGFloat { segWidth * 2 }
    private var selectedIndex: Int { mode == .systemProxy ? 0 : 1 }

    var body: some View {
        ZStack(alignment: .leading) {
            // Track.
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(0.08))

            // Sliding glass thumb.
            thumb
                .frame(width: segWidth, height: height - 4)
                .offset(x: thumbOffset + 2)
                .animation(dragX == nil ? .spring(response: 0.28, dampingFraction: 0.8) : nil,
                           value: selectedIndex)

            // Labels on top.
            HStack(spacing: 0) {
                ForEach(Array(labels.enumerated()), id: \.offset) { idx, item in
                    Text(item.1)
                        .font(.system(size: 12, weight: idx == selectedIndex ? .semibold : .regular))
                        .foregroundStyle(idx == selectedIndex ? Color.primary : .secondary)
                        .frame(width: segWidth, height: height)
                        .contentShape(Rectangle())
                        .onTapGesture { select(labels[idx].0) }
                }
            }
        }
        .frame(width: trackWidth, height: height)
        .clipShape(Capsule(style: .continuous))
        .opacity(isDisabled ? 0.5 : 1)
        .allowsHitTesting(!isDisabled)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { v in
                    // Centre the thumb under the finger, clamped to the track.
                    let half = segWidth / 2
                    dragX = min(max(v.location.x - half, 0), trackWidth - segWidth)
                }
                .onEnded { v in
                    let target: TunnelMode = v.location.x > trackWidth / 2 ? .tun : .systemProxy
                    dragX = nil
                    select(target)
                }
        )
    }

    /// Where the thumb sits: follows the finger mid-drag, else snaps to segment.
    private var thumbOffset: CGFloat {
        if let dragX { return dragX }
        return CGFloat(selectedIndex) * segWidth
    }

    @ViewBuilder
    private var thumb: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: Capsule(style: .continuous))
        } else {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        }
    }

    private func select(_ newMode: TunnelMode) {
        guard newMode != mode else { return }
        mode = newMode
        onChange(newMode)
    }
}
