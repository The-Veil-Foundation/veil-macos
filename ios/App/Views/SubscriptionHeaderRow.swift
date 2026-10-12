import SwiftUI

/// The first row of a subscription's section: what the source is called, what
/// it has left, and everything that can be done to the source itself.
struct SubscriptionHeaderRow: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc
    @Environment(MenuBackdrop.self) private var backdrop

    let subscription: Subscription
    /// How many of its rows the current filter left visible.
    var count: Int

    @State private var confirmRemove = false
    @State private var isRefreshing = false
    @State private var rowWidth: CGFloat = 0

    private var isPinned: Bool { subscription.pinned == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            SubscriptionDetails(subscription: subscription)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { rowWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in rowWidth = width }
            }
        }
        // The same actions as the ⋯ button, on a long press. Its own preview
        // gets the blurred backdrop the bare menu button never has.
        .contextMenu { menuItems } preview: { preview }
        .confirmationDialog(loc("Remove this subscription?"),
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(loc("Remove"), role: .destructive) {
                let id = subscription.id
                store.removeSubscription(id: id)
            }
            Button(loc("Cancel"), role: .cancel) {}
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            // Tapping anywhere across the name collapses the group, but the
            // menu keeps its own hit area.
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    // Rotating one glyph animates; swapping two would not.
                    .rotationEffect(.degrees(subscription.isCollapsed ? -90 : 0))
                    .frame(width: 20)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(subscription.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: "\(count)")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleCollapsed() }

            menu
        }
    }

    private var menu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .padding(.leading, 4)
        }
    }

    /// The source's name and figures as a card, for the long-press preview.
    /// It is hosted outside the list, so the observable objects its parts read
    /// have to be handed over again.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Text(subscription.name).font(.headline).lineLimit(1)
                Text(verbatim: "\(count)")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                Spacer(minLength: 0)
            }
            SubscriptionDetails(subscription: subscription)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: rowWidth > 0 ? rowWidth + 32 : nil, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .environment(loc)
        .environment(store)
        .environment(tunnel)
        .environment(pinger)
        .liftsMenuBackdrop(backdrop)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(loc("Test ping (group)"), systemImage: "speedometer") {
            pinger.test(subscription.servers)
        }
        Button(subscription.isCollapsed ? loc("Expand") : loc("Collapse"),
               systemImage: subscription.isCollapsed ? "chevron.down" : "chevron.up") {
            toggleCollapsed()
        }
        Button(isPinned ? loc("Unpin") : loc("Pin"),
               systemImage: isPinned ? "pin.slash" : "pin") {
            store.togglePinned(subscriptionID: subscription.id)
        }
        Button(loc("Move up"), systemImage: "arrow.up") { moveBy(-1) }
            .disabled(index == 0)
        Button(loc("Move down"), systemImage: "arrow.down") { moveBy(1) }
            .disabled(index == store.subscriptions.count - 1)
        Divider()
        Button(loc("Make a fastest-node group"), systemImage: "bolt.horizontal") {
            store.addAutoGroup(named: subscription.name,
                               query: GroupQuery(sourceIDs: [subscription.id]))
        }
        if !subscription.isManual {
            Divider()
            Button(loc("Refresh now"), systemImage: "arrow.clockwise") {
                Task {
                    isRefreshing = true
                    await SubscriptionService.refresh(subscription, into: store)
                    isRefreshing = false
                }
            }
            Toggle(loc("Auto-update"), isOn: Binding(
                get: { subscription.autoUpdate },
                set: { store.setAutoUpdate($0, id: subscription.id) }
            ))
            Button(loc("Copy subscription link"), systemImage: "link") {
                // The path in it is the access token: onto the clipboard,
                // never onto the screen.
                if let url = store.subscriptionURL(for: subscription) {
                    UIPasteboard.general.string = url
                }
            }
            if let support = subscription.supportURL, let url = URL(string: support) {
                Link(destination: url) {
                    Label(loc("Support"), systemImage: "questionmark.circle")
                }
            }
            if let page = subscription.webPageURL, let url = URL(string: page) {
                Link(destination: url) {
                    Label(loc("Provider's page"), systemImage: "safari")
                }
            }
            Divider()
            // Can't remove a subscription that holds the active server.
            let holdsActive = tunnel.isConnected
                && subscription.servers.contains { $0.id == tunnel.activeServerID }
            Button(loc("Remove"), systemImage: "trash", role: .destructive) {
                confirmRemove = true
            }
            .disabled(holdsActive)
        }
    }

    // MARK: - Order

    private var index: Int {
        store.subscriptions.firstIndex { $0.id == subscription.id } ?? 0
    }

    private func moveBy(_ delta: Int) {
        let target = index + delta
        guard store.subscriptions.indices.contains(target) else { return }
        // The destination counts before the removal, so moving down is one
        // further than it looks.
        withAnimation {
            store.moveSubscriptions(fromOffsets: IndexSet(integer: index),
                                    toOffset: delta > 0 ? target + 1 : target)
        }
    }

    private func toggleCollapsed() {
        withAnimation(.snappy(duration: 0.28)) {
            store.toggleCollapsed(id: subscription.id)
        }
    }
}

/// Note, traffic and expiry of a subscription, as the panel reported them.
struct SubscriptionDetails: View {
    @Environment(Loc.self) private var loc
    let subscription: Subscription

    /// Shown in full. Providers pad the Announce header with runs of blank
    /// lines; those collapse to a single break so the paragraphs survive
    /// without the dead space between them.
    private var noteText: String {
        let lines = (subscription.note ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var kept: [String] = []
        for line in lines {
            // Drops leading blanks and every repeat of one.
            if line.isEmpty && (kept.last?.isEmpty ?? true) { continue }
            kept.append(line)
        }
        while kept.last?.isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !noteText.isEmpty {
                Text(noteText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if subscription.hwidStatus == .maxDevicesReached {
                Label(loc("The provider's device limit is reached."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let used = subscription.usedBytes {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        // An uncapped plan gets the amount used and nothing
                        // else: there is no denominator, so no ratio to draw.
                        if subscription.isUnlimitedTraffic || subscription.totalBytes == nil {
                            Text(verbatim: ByteFormat.string(used)).monospacedDigit()
                            Text(loc("Unlimited")).foregroundStyle(.tertiary)
                        } else if let total = subscription.totalBytes {
                            Text(verbatim: "\(ByteFormat.string(used)) / \(ByteFormat.string(total))")
                                .monospacedDigit()
                        }
                        Spacer(minLength: 8)
                        if let expiry = subscription.expiresAt {
                            Text(expiry.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if let fraction = subscription.usageFraction, !subscription.isUnlimitedTraffic {
                        usageBar(fraction)
                    }
                }
            } else if let expiry = subscription.expiresAt {
                Text("\(loc("Expires")) \(expiry.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Hand-drawn rather than a `ProgressView`, whose bar is too tall and too
    /// loud for a line of metadata.
    private func usageBar(_ fraction: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(fraction > 0.9 ? Color.red : Color.accentColor)
                    .frame(width: max(3, geometry.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}
