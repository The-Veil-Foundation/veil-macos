import SwiftUI

/// The second mode of the main window: where servers come from, rather than
/// which one is in use.
///
/// The connection list answers "what am I connecting through". This answers
/// "what is in my list and why" — which source produced a node, what the source
/// actually returned, and, for a node Veil owns, what it is made of. A
/// WireGuard peer that today shows up as a name and nothing else is readable
/// and editable here.
struct SourcesView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    @State private var selectedSourceID: UUID?
    @State private var selectedServer: ProxyConfig?
    /// Custom User-Agents being typed, by subscription, until Return.
    @State private var agentDraft: [UUID: String] = [:]

    private var sources: [Subscription] { store.orderedSubscriptions }

    private var selectedSource: Subscription? {
        sources.first { $0.id == selectedSourceID } ?? sources.first
    }

    var body: some View {
        HSplitView {
            sourceList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
            detail
                .frame(minWidth: 340, maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
        .sheet(item: $selectedServer) { server in
            NodeEditorSheet(server: server,
                            isEditable: selectedSource?.isManual == true)
        }
    }

    // MARK: - Sources

    private var sourceList: some View {
        List(selection: $selectedSourceID) {
            ForEach(sources) { source in
                HStack(spacing: 6) {
                    Image(systemName: source.isManual ? "tray" : "square.stack.3d.up")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(source.name).lineLimit(1)
                        Text(String(format: loc("%d servers"), source.servers.count))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if source.pinned == true {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .tag(source.id)
                .contextMenu {
                    Button(source.pinned == true ? loc("Unpin") : loc("Pin")) {
                        store.togglePinned(subscriptionID: source.id)
                    }
                    Button(loc("Make a fastest-node group")) { makeAutoGroup(for: source) }
                        .help(loc("One group over this source, re-measured as it changes."))
                    if !source.isManual {
                        Button(loc("Refresh now")) {
                            Task { await SubscriptionService.refresh(source, into: store) }
                        }
                        Button(loc("Copy subscription link")) { copyURL(of: source) }
                        Divider()
                        Button(loc("Remove"), role: .destructive) {
                            store.removeSubscription(id: source.id)
                        }
                    }
                }
            }
            .onMove { from, to in store.moveSubscriptions(fromOffsets: from, toOffset: to) }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let source = selectedSource {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sourceSummary(source)
                    Divider()
                    nodeList(source)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                Text(loc("No sources yet")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sourceSummary(_ source: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(source.name).font(.title3).bold()
                Spacer()
                Button(loc("Make a fastest-node group")) { makeAutoGroup(for: source) }
                    .help(loc("One group over this source, re-measured as it changes."))
                if !source.isManual {
                    Button(loc("Refresh now")) {
                        Task { await SubscriptionService.refresh(source, into: store) }
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                if !source.isManual {
                    row(loc("Address"), source.hasStoredURL == true || source.url != nil
                        ? loc("Stored in the Keychain")
                        : loc("Missing"))
                }
                row(loc("Servers"), "\(source.servers.count)")
                if !source.declaredGroups.isEmpty {
                    row(loc("Groups the panel declared"), "\(source.declaredGroups.count)")
                }
                if let format = source.lastFormat {
                    row(loc("Format"), format.label)
                }
                if let updated = source.lastUpdated {
                    row(loc("Last updated"), updated.formatted(date: .abbreviated, time: .shortened))
                }
                if let expires = source.expiresAt {
                    row(loc("Expires"), expires.formatted(date: .abbreviated, time: .omitted))
                }
                if let used = source.usedBytes {
                    row(loc("Traffic"), source.totalBytes.map {
                        "\(ByteFormat.string(used)) / \(ByteFormat.string($0))"
                    } ?? ByteFormat.string(used))
                }
            }
            .font(.callout)

            if !source.isManual { requestAsControls(source) }

            if let skipped = source.lastSkipped, !skipped.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label(loc("Not everything in this source could be used"),
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    ForEach(skipped, id: \.label) { note in
                        Text(verbatim: "· \(note.label) × \(note.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(loc("These entries were dropped while reading the source. A server that is missing from the list is listed here with the reason."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            }

            if !source.isManual {
                Text(loc("A subscription's servers are the panel's. Rename them, tag them, pin them — that is yours and survives a refresh — but to change what one connects to, duplicate it into Manual."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Which client Veil presents itself as to this panel. Changing it
    /// refetches at once, so the user sees the format change in the row above.
    private func requestAsControls(_ source: Subscription) -> some View {
        let id = source.id
        let profile = Binding<SubscriptionRequestProfile>(
            get: { store.subscriptions.first { $0.id == id }?.requestAs ?? .automatic },
            set: { value in
                store.mutateSubscription(id: id) { $0.requestAs = value == .automatic ? nil : value }
                if value != .custom { refetch(id) }
            })
        // Written on submit only: saving the store on every keystroke rewrites
        // the file and the Keychain entry for nothing.
        let customAgent = Binding<String>(
            get: { agentDraft[id] ?? store.subscriptions.first { $0.id == id }?.userAgentOverride ?? "" },
            set: { agentDraft[id] = $0 })
        return VStack(alignment: .leading, spacing: 4) {
            Picker(loc("Request as"), selection: profile) {
                ForEach(SubscriptionRequestProfile.allCases) { option in
                    Text(loc(option.label)).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if profile.wrappedValue == .custom {
                TextField(loc("User-Agent"), text: customAgent)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit {
                        if let draft = agentDraft.removeValue(forKey: id) {
                            let value = draft.trimmingCharacters(in: .whitespaces)
                            store.mutateSubscription(id: id) { $0.userAgentOverride = value.isEmpty ? nil : value }
                        }
                        refetch(id)
                    }
            }
            Text(loc("Panels choose what to send by the client asking. Pick Xray config to get the servers and balancer groups Happ gets, or sing-box config for what sing-box apps get."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refetch(_ id: UUID) {
        guard let current = store.subscriptions.first(where: { $0.id == id }) else { return }
        Task { await SubscriptionService.refresh(current, into: store) }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func nodeList(_ source: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("Servers")).font(.headline)
            if source.servers.isEmpty {
                Text(loc("This source has no servers in it."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(source.servers) { server in
                HStack(spacing: 8) {
                    Text(server.proto.rawValue.uppercased())
                        .font(.caption2).monospaced()
                        .frame(width: 66, alignment: .leading)
                        .foregroundStyle(.secondary)
                    Text(store.annotation(for: server.id).nameOverride ?? server.name)
                        .lineLimit(1)
                    Spacer()
                    Text(verbatim: "\(server.address):\(server.port)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button(source.isManual ? loc("Edit") : loc("Inspect")) {
                        selectedServer = server
                    }
                    .buttonStyle(.link)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .onTapGesture { selectedServer = server }
                Divider()
            }
        }
    }

    /// A group that follows this source: every node it has and every node it
    /// gains, with the quickest in use.
    private func makeAutoGroup(for source: Subscription) {
        store.addAutoGroup(named: source.name,
                           query: GroupQuery(sourceIDs: [source.id]))
    }

    /// Puts the subscription's URL on the clipboard without ever drawing it:
    /// the path in it is the access token, so it belongs in the Keychain and in
    /// the user's paste buffer, not on screen or in a log.
    private func copyURL(of source: Subscription) {
        guard let url = store.subscriptionURL(for: source) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}

// MARK: - One node, in the form the user wants it

/// Shows a node as its `wg-quick` file, its outbound JSON, or its share link —
/// and, when Veil owns it, lets that text be edited and checked by the core
/// that will run it.
struct NodeEditorSheet: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let server: ProxyConfig
    var isEditable: Bool

    @State private var kind: NodeRepresentation.Kind = .json
    @State private var text = ""
    @State private var message: String?
    @State private var isBad = false
    @State private var isChecking = false

    private var kinds: [NodeRepresentation.Kind] { NodeRepresentation.kinds(for: server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(server.name).font(.headline)
                Spacer()
                Picker("", selection: $kind) {
                    ForEach(kinds) { kind in
                        Text(loc(kind.title)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: kind) { _, new in
                    text = NodeRepresentation.text(new, for: server)
                    message = nil
                }
            }

            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 260)
                .disabled(!isEditable)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25)))

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isBad ? .red : .secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(loc("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                if !isEditable {
                    Button(loc("Duplicate and edit")) { duplicate() }
                        .help(loc("Copies this server into Manual, where it can be changed. The subscription's own copy is left alone."))
                }
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
                if isEditable {
                    Button(loc("Check")) { Task { await check() } }
                    Button(loc("Save")) { Task { await save() } }
                        .keyboardShortcut(.defaultAction)
                }
                Button(loc("Close")) { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 560)
        .onAppear {
            kind = kinds.first ?? .json
            text = NodeRepresentation.text(kind, for: server)
        }
    }

    // MARK: - Actions

    private func parsed() -> ProxyConfig? {
        do {
            let node = try NodeRepresentation.parse(kind, text: text, keeping: server)
            return node
        } catch {
            message = error.localizedDescription
            isBad = true
            return nil
        }
    }

    /// Asks the real core, so the message the user reads is the core's own.
    @discardableResult
    private func check() async -> ProxyConfig? {
        guard let node = parsed() else { return nil }
        isChecking = true
        let outcome = await ConfigValidator.check(node)
        isChecking = false
        switch outcome {
        case .ok:
            message = loc("The core accepted this configuration.")
            isBad = false
            return node
        case .failed(let reason):
            message = reason
            isBad = true
            return nil
        case .unavailable:
            // Nothing the user can do about a missing binary, and refusing to
            // save over it would lose their edit.
            message = loc("The core is not available, so this was not checked.")
            isBad = false
            return node
        }
    }

    private func save() async {
        guard let node = await check() else { return }
        store.replaceServer(node)
        dismiss()
    }

    private func duplicate() {
        var copy = server
        copy.id = UUID()
        copy.name = server.name + " " + loc("(copy)")
        store.addManualServer(copy)
        dismiss()
    }
}
