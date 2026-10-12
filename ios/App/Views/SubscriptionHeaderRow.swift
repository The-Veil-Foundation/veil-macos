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

    private var isPinned: Bool { subscription.pinned == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            SubscriptionDetails(subscription: subscription)
                .contentShape(Rectangle())
                // The same menu as the ⋯ button, on a long press.
                .overlay { surface(onTap: nil) }
        }
        .padding(.vertical, 4)
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
            .overlay { surface(onTap: toggleCollapsed) }

            menu
        }
    }

    private var menu: some View {
        RowMenuButton(backdrop: backdrop, backTitle: loc("Back"),
                      accessibilityLabel: loc("More")) { menuSections }
            .fixedSize()
    }

    private func surface(onTap: (() -> Void)?) -> some View {
        RowMenuSurface(isEnabled: true, backdrop: backdrop, backTitle: loc("Back"),
                       onTap: onTap) { menuSections }
    }

    /// Everyday actions first. Advanced swaps the open menu's contents for the
    /// rarer ones, with Back to return, instead of opening a submenu over them.
    private var menuSections: RowMenu {
        var main: [RowMenuItem] = []
        if !subscription.isManual {
            main.append(.button(loc("Refresh now"), systemImage: "arrow.clockwise") {
                Task {
                    isRefreshing = true
                    await SubscriptionService.refresh(subscription, into: store)
                    isRefreshing = false
                }
            })
        }
        main.append(.button(loc("Test ping (group)"), systemImage: "speedometer") {
            pinger.test(subscription.servers)
        })
        main.append(.button(isPinned ? loc("Unpin") : loc("Pin"),
                            systemImage: isPinned ? "pin.slash" : "pin") {
            store.togglePinned(subscriptionID: subscription.id)
        })
        if let support = subscription.supportURL, let url = URL(string: support) {
            main.append(.button(loc("Support"), systemImage: "questionmark.circle") {
                UIApplication.shared.open(url)
            })
        }
        if let page = subscription.webPageURL, let url = URL(string: page) {
            main.append(.button(loc("Provider's page"), systemImage: "safari") {
                UIApplication.shared.open(url)
            })
        }

        var advanced: [RowMenuItem] = [
            .button(subscription.isCollapsed ? loc("Expand") : loc("Collapse"),
                    systemImage: subscription.isCollapsed ? "chevron.down" : "chevron.up") {
                toggleCollapsed()
            },
            .button(loc("Move up"), systemImage: "arrow.up", disabled: index == 0) { moveBy(-1) },
            .button(loc("Move down"), systemImage: "arrow.down",
                    disabled: index == store.subscriptions.count - 1) { moveBy(1) },
            .button(loc("Make a fastest-node group"), systemImage: "bolt.horizontal") {
                store.addAutoGroup(named: subscription.name,
                                   query: GroupQuery(sourceIDs: [subscription.id]))
            }
        ]
        var end: [RowMenuItem] = []
        if !subscription.isManual {
            let id = subscription.id
            let autoUpdate = subscription.autoUpdate
            advanced.append(.button(loc("Auto-update"), systemImage: "arrow.triangle.2.circlepath",
                                    checked: autoUpdate) {
                store.setAutoUpdate(!autoUpdate, id: id)
            })
            advanced.append(.button(loc("Copy subscription link"), systemImage: "link") {
                // The path in it is the access token: onto the clipboard,
                // never onto the screen.
                if let url = store.subscriptionURL(for: subscription) {
                    UIPasteboard.general.string = url
                }
            })
            // Can't remove a subscription that holds the active server.
            let holdsActive = tunnel.isConnected
                && subscription.servers.contains { $0.id == tunnel.activeServerID }
            end.append(.button(loc("Remove"), systemImage: "trash",
                               destructive: true, disabled: holdsActive) {
                confirmRemove = true
            })
        }
        return [main, [.level(loc("Advanced"), systemImage: "ellipsis.circle", [advanced])], end]
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
