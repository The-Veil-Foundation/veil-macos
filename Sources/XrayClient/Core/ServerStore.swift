import Foundation
import Observation

/// Holds subscription profiles, the selected server, and app settings.
/// Persists everything to JSON in Application Support.
@MainActor
@Observable
final class ServerStore {
    private(set) var subscriptions: [Subscription] = []
    var settings = AppSettings()
    var selectedServerID: UUID?

    private let fileURL: URL

    init() {
        #if os(iOS)
        // Live in the shared app group so the tunnel extension reads the same
        // servers and settings the app writes.
        let dir = AppGroup.supportDirectory
        #else
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("XrayClient", isDirectory: true)
        #endif
        // Whether an earlier build already ran here has to be answered before
        // anything is written, because the first save would otherwise make
        // every fresh install look like an upgrade. `DeviceID` uses it to
        // decide if there is an identifier worth carrying forward.
        let store = dir.appendingPathComponent("store.json")
        DeviceID.isUpgrade = FileManager.default.fileExists(atPath: store.path)

        // Application Support is world-readable by default and this file holds
        // server addresses, UUIDs and passwords.
        SecureFile.ensureDirectory(dir)
        self.fileURL = store
        load()
        selectedServerID = settings.lastSelectedServerID
        // The list on disk is a snapshot; an automatic group is answered
        // against the list that exists now.
        refreshAutoGroups()
    }

    // MARK: - Derived

    /// All servers across every subscription, flattened.
    var allServers: [ProxyConfig] {
        subscriptions.flatMap(\.servers)
    }

    /// Every group the panels declared, across all subscriptions. The user's
    /// own groups live in `settings.serverGroups` and stay separate.
    var declaredGroups: [ServerGroup] {
        subscriptions.flatMap(\.declaredGroups)
    }

    /// Every server paired with the source that produced it — the one thing a
    /// `ProxyConfig` does not carry, and what an automatic group's query is
    /// answered against.
    var groupCandidates: [GroupResolver.Candidate] {
        orderedSubscriptions.flatMap { sub in
            sub.servers.map { GroupResolver.Candidate(server: $0, sourceID: sub.id) }
        }
    }

    /// Builds a group that follows a source: every node it has now and every
    /// node it gains later, with the quickest in use. This is the one-click
    /// version of writing the query out by hand, and the shape most people
    /// want from a subscription.
    @discardableResult
    func addAutoGroup(named name: String, query: GroupQuery,
                      kind: ServerGroup.Kind = .urltest) -> ServerGroup {
        var group = ServerGroup(name: name, kind: kind)
        group.query = query
        settings.serverGroups.append(group)
        save()
        return settings.serverGroups.last ?? group
    }

    /// Removes one of the user's own groups, and with it any selection that
    /// pointed at it. A panel's declared group is not the user's to delete:
    /// the next refresh would bring it straight back.
    func removeGroup(id: UUID) {
        settings.serverGroups.removeAll { $0.id == id }
        if selectedServerID == id { selectedServerID = nil }
        if settings.lastSelectedServerID == id { settings.lastSelectedServerID = nil }
        save()
    }

    /// Re-answers every automatic group. Pure and cheap, so it runs wherever
    /// the set of servers or the annotations can have changed rather than at
    /// carefully chosen moments that are easy to miss one of.
    func refreshAutoGroups() {
        let resolved = GroupResolver.resolved(settings.serverGroups,
                                              in: groupCandidates,
                                              annotations: settings.nodeAnnotations,
                                              autoTags: settings.autoTags)
        guard resolved != settings.serverGroups else { return }
        settings.serverGroups = resolved
    }

    /// Every group that can be shown and connected to: the user's own first,
    /// because those are the ones they built, then the panels'.
    var allGroups: [ServerGroup] {
        settings.serverGroups + declaredGroups
    }

    func server(withID id: UUID?) -> ProxyConfig? {
        guard let id else { return nil }
        if let server = allServers.first(where: { $0.id == id }) { return server }
        // A group is a connectable thing too, and the id the user picked may
        // well be one — auto-connect on launch reads the stored selection back
        // through here.
        guard let group = allGroups.first(where: { $0.id == id }) else { return nil }
        return representative(for: group)
    }

    /// A declared group as a single entry the list can show.
    func representative(for group: ServerGroup) -> ProxyConfig? {
        group.representative(in: allServers)
    }

    func subscriptionContaining(serverID: UUID?) -> Subscription? {
        guard let id = serverID else { return nil }
        return subscriptions.first { $0.servers.contains(where: { $0.id == id }) }
    }

    // MARK: - Manual servers

    private func ensureManualGroup() -> Int {
        if let idx = subscriptions.firstIndex(where: { $0.isManual }) { return idx }
        subscriptions.insert(Subscription(name: "Manual"), at: 0)
        return 0
    }

    func addManualServers(_ servers: [ProxyConfig], groups: [ServerGroup] = []) {
        let idx = ensureManualGroup()
        subscriptions[idx].servers.append(contentsOf: servers)
        if !groups.isEmpty {
            subscriptions[idx].groups = subscriptions[idx].declaredGroups + groups
        }
        save()
    }

    /// Removes specific servers (by id) from any subscription group. Empties the
    /// Manual group if it becomes empty.
    func removeServers(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for i in subscriptions.indices {
            subscriptions[i].servers.removeAll { ids.contains($0.id) }
        }
        // Drop an emptied Manual group to keep the list tidy.
        subscriptions.removeAll { $0.isManual && $0.servers.isEmpty }
        if let sel = selectedServerID, !ids.contains(sel) {} else { selectedServerID = nil }
        save()
    }

    /// Removes a single server by id.
    func removeServer(id: UUID) {
        removeServers(ids: [id])
    }

    /// Adds one server the user owns.
    func addManualServer(_ server: ProxyConfig) {
        addManualServers([server])
    }

    /// Writes an edited server back over the one with the same id, wherever it
    /// lives. The id is kept by `NodeRepresentation.parse`, so the groups,
    /// rules and annotations naming it still resolve.
    func replaceServer(_ server: ProxyConfig) {
        for i in subscriptions.indices {
            guard let j = subscriptions[i].servers.firstIndex(where: { $0.id == server.id })
            else { continue }
            subscriptions[i].servers[j] = server
        }
        save()
    }

    /// The subscription's URL, read back from the Keychain. The path in it is
    /// the access token, so this is for putting on the user's clipboard, never
    /// for drawing on screen or writing to a log.
    func subscriptionURL(for subscription: Subscription) -> String? {
        subscription.url ?? Keychain.get(account: KeychainAccount.subscriptionURL(subscription.id))
    }

    // MARK: - Subscriptions

    /// Adds or refreshes a subscription; everything the panel reported in its
    /// response headers lands on the profile.
    func addOrUpdateSubscription(name: String, url: String,
                                 servers: [ProxyConfig],
                                 groups: [ServerGroup] = [],
                                 metadata: SubscriptionMetadata,
                                 format: SubscriptionPayload.Format?,
                                 skipped: [SubscriptionPayload.SkipNote] = []) {
        let idx = subscriptions.firstIndex { $0.url == url }
        if let idx {
            // Preserve UI state and identity, refresh the contents. A fetch
            // reparses every entry and so mints a new id for each one; matching
            // them back onto what is stored is what keeps group membership,
            // routing rule targets, tags and the current selection pointing at
            // the nodes the user chose.
            let reconciled = NodeReconciler.reconcile(incoming: servers,
                                                      groups: groups,
                                                      existing: subscriptions[idx].servers,
                                                      existingGroups: subscriptions[idx].declaredGroups)
            subscriptions[idx].name = name
            subscriptions[idx].servers = reconciled.servers
            subscriptions[idx].groups = reconciled.groups
            subscriptions[idx].lastUpdated = Date()
            subscriptions[idx].lastFormat = format
            subscriptions[idx].lastSkipped = skipped.isEmpty ? nil : skipped
            subscriptions[idx].apply(metadata)
        } else {
            var sub = Subscription(name: name, url: url)
            sub.servers = servers
            sub.groups = groups
            sub.lastUpdated = Date()
            sub.lastFormat = format
            sub.lastSkipped = skipped.isEmpty ? nil : skipped
            sub.apply(metadata)
            subscriptions.append(sub)
        }
        save()
    }

    /// Applies an in-place edit to one subscription and persists it.
    func mutateSubscription(id: UUID, _ body: (inout Subscription) -> Void) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        body(&subscriptions[idx])
        save()
    }

    func removeSubscription(id: UUID) {
        // The annotations belong to the source: tags on nodes that are about to
        // stop existing have nothing left to describe.
        if let going = subscriptions.first(where: { $0.id == id }) {
            for server in going.servers { settings.nodeAnnotations[server.id] = nil }
        }
        subscriptions.removeAll { $0.id == id }
        Keychain.remove(account: KeychainAccount.subscriptionURL(id))
        DeviceID.clearOverride(for: id)
        save()
    }

    func toggleCollapsed(id: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[idx].isCollapsed.toggle()
        save()
    }

    func setAutoUpdate(_ on: Bool, id: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[idx].autoUpdate = on
        save()
    }

    func setNote(_ note: String, id: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        subscriptions[idx].note = note.isEmpty ? nil : note
        save()
    }

    func select(_ serverID: UUID) {
        selectedServerID = serverID
        settings.lastSelectedServerID = serverID
        save()
    }

    // MARK: - Arranging the list

    /// Sources in the order the list shows them, which is simply the order they
    /// are stored in. Pinning moves a source to the top and marks it; it is not
    /// a second sort, so a drag always wins and the list never springs back.
    var orderedSubscriptions: [Subscription] { subscriptions }

    func togglePinned(subscriptionID: UUID) {
        guard let idx = subscriptions.firstIndex(where: { $0.id == subscriptionID }) else { return }
        if subscriptions[idx].pinned == true {
            subscriptions[idx].pinned = nil
        } else {
            var pinned = subscriptions.remove(at: idx)
            pinned.pinned = true
            subscriptions.insert(pinned, at: 0)
        }
        save()
    }

    /// Reorders the sources themselves.
    func moveSubscriptions(fromOffsets: IndexSet, toOffset: Int) {
        // Spelled out rather than SwiftUI's `move(fromOffsets:toOffset:)`: the
        // iOS tunnel extension compiles this file too, and links no SwiftUI.
        let moving = fromOffsets.map { subscriptions[$0] }
        let insertAt = toOffset - fromOffsets.filter { $0 < toOffset }.count
        for index in fromOffsets.sorted(by: >) { subscriptions.remove(at: index) }
        subscriptions.insert(contentsOf: moving, at: max(0, min(insertAt, subscriptions.count)))
        // Anything dragged out of the run of pinned sources at the top is no
        // longer pinned, so the badge never contradicts the order.
        for idx in subscriptions.indices where subscriptions[idx].pinned == true {
            let isStillAtTheTop = subscriptions[..<idx].allSatisfy { $0.pinned == true }
            if !isStillAtTheTop { subscriptions[idx].pinned = nil }
        }
        save()
    }

    /// The user's own notes on a node — tags, pinning, hiding, a name of their
    /// own. Never nil: a node with nothing attached has an empty annotation.
    func annotation(for serverID: UUID) -> NodeAnnotation {
        settings.nodeAnnotations[serverID] ?? NodeAnnotation()
    }

    /// Edits one node's annotation and persists it. An annotation left with
    /// nothing in it is dropped rather than stored as an empty record.
    func annotate(_ serverID: UUID, _ body: (inout NodeAnnotation) -> Void) {
        var annotation = annotation(for: serverID)
        body(&annotation)
        settings.nodeAnnotations[serverID] = annotation.isEmpty ? nil : annotation
        save()
    }

    func togglePinned(serverID: UUID) {
        annotate(serverID) { $0.pinned.toggle() }
    }

    func setHidden(_ hidden: Bool, serverID: UUID) {
        annotate(serverID) { $0.hidden = hidden }
    }

    /// Renames a node for display only; the source keeps its own name, and an
    /// empty string hands the row back to it.
    func rename(serverID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        annotate(serverID) { $0.nameOverride = trimmed.isEmpty ? nil : trimmed }
    }

    func setTags(_ tags: [String], serverID: UUID) {
        var seen = Set<String>()
        let cleaned = tags
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        annotate(serverID) { $0.tags = cleaned }
    }

    /// Every label in use, for the filter chips and the tag editor.
    /// Every tag in play: the user's own labels and the ones read out of the
    /// node names, which is what makes the tag dimension usable on a fresh
    /// install rather than empty until fifty nodes are labelled by hand.
    var allTags: [String] {
        var tags = Set(settings.nodeAnnotations.values.flatMap(\.tags))
        for server in allServers {
            tags.formUnion(AutoTags.all(for: server,
                                        annotation: annotation(for: server.id),
                                        derived: settings.autoTags))
        }
        return tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Records the order a drag left a section in.
    func reorder(section ids: [UUID]) {
        NodeOrdering.apply(order: ids, to: &settings.nodeAnnotations)
        save()
    }

    func clearManualOrder(section ids: [UUID]) {
        NodeOrdering.clear(ids, in: &settings.nodeAnnotations)
        save()
    }

    /// The sources as the list builder wants them, with each panel's declared
    /// groups already resolved to the single row that stands for them.
    var listSources: [ListSource] {
        let subscriptions = orderedSubscriptions.map { sub in
            ListSource(id: sub.id,
                       name: sub.name,
                       isCollapsed: sub.isCollapsed,
                       groupRows: sub.declaredGroups.compactMap { representative(for: $0) },
                       servers: sub.servers)
        }
        // The user's own groups draw from every source at once, so they cannot
        // sit under one of them. They lead the list: a group is usually the
        // thing you actually connect to.
        let own = settings.serverGroups.compactMap { representative(for: $0) }
        guard !own.isEmpty else { return subscriptions }
        return [ListSource(id: ServerStore.ownGroupsSourceID,
                           name: "Groups",
                           groupRows: own)] + subscriptions
    }

    /// A fixed id so the section keeps its collapse state and its place; it is
    /// not a subscription and is never fetched.
    static let ownGroupsSourceID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    func listSections(filter: ListFilter) -> [ListSection] {
        ServerListBuilder.sections(sources: listSources,
                                   annotations: settings.nodeAnnotations,
                                   grouping: settings.listGrouping,
                                   filter: filter,
                                   autoTags: settings.autoTags)
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        settings = decoded.settings ?? AppSettings()
        subscriptions = decoded.subscriptions.map { sub in
            guard sub.url == nil, sub.hasStoredURL == true else { return sub }
            var restored = sub
            restored.url = Keychain.get(account: KeychainAccount.subscriptionURL(sub.id))
            return restored
        }
    }

    func save() {
        refreshAutoGroups()
        // Subscription URLs are bearer credentials: the Keychain holds them,
        // `store.json` only records that it did. A build where the Keychain is
        // unavailable keeps the URL in the (0600) file rather than losing it.
        let persisted = subscriptions.map { sub -> Subscription in
            guard let url = sub.url, !url.isEmpty else { return sub }
            var copy = sub
            if Keychain.set(url, account: KeychainAccount.subscriptionURL(sub.id)) {
                copy.url = nil
                copy.hasStoredURL = true
            } else {
                copy.hasStoredURL = false
            }
            return copy
        }
        let payload = Persisted(subscriptions: persisted, settings: settings)
        if let data = try? JSONEncoder().encode(payload) {
            SecureFile.write(data, to: fileURL)
        }
    }

    private struct Persisted: Codable {
        var subscriptions: [Subscription]
        var settings: AppSettings?
    }
}
