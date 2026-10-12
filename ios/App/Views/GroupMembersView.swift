import SwiftUI

/// A group's members, what each one measured, and — for a manual group — the
/// one in use.
struct GroupMembersView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let group: ServerGroup

    /// The stored copy, so a pick made here is reflected straight away.
    private var current: ServerGroup { store.group(withID: group.id) ?? group }

    var body: some View {
        let members = store.members(of: current)
        NavigationStack {
            List {
                Section {
                    LabeledContent(loc("Picks"), value: loc(current.kind.title))
                    if current.kind == .urltest {
                        LabeledContent(loc("Test URL"), value: current.testURL)
                            .font(.caption)
                    }
                } footer: {
                    Text(loc(current.kind.subtitle))
                }

                Section(loc("Members")) {
                    if members.isEmpty {
                        Text(loc("No members yet.")).foregroundStyle(.secondary)
                    }
                    ForEach(members) { member in
                        memberRow(member)
                    }
                }
            }
            .navigationTitle(current.name.isEmpty ? loc("Group") : current.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pinger.test(members)
                    } label: {
                        Image(systemName: "speedometer")
                    }
                    .accessibilityLabel(loc("Test ping"))
                    .disabled(members.isEmpty || pinger.isBusy)
                }
            }
        }
    }

    private func memberRow(_ member: ProxyConfig) -> some View {
        let isPicked = current.kind == .selector
            && (current.selectedID ?? current.memberIDs.first) == member.id
        let observed = tunnel.observed(member.id)
        return Button {
            guard current.kind == .selector else { return }
            store.setSelectedMember(member.id, groupID: current.id)
            if tunnel.isConnected, tunnel.activeServerID == current.id {
                Task { await tunnel.applyChanges(store: store) }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.annotation(for: member.id).nameOverride ?? member.name)
                        .foregroundStyle(member.xraySupported ? .primary : .secondary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(member.proto.rawValue.uppercased())
                        if !member.xraySupported {
                            Text(loc("needs sing-box")).foregroundStyle(.orange)
                        }
                        if let observed {
                            Text(observed.alive
                                 ? "\(loc("Probe")): \(observed.delay) ms"
                                 : "\(loc("Probe")): \(loc("timeout"))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if pinger.isTesting(member.id) {
                    ProgressView().controlSize(.mini)
                } else if let outer = pinger.latency(for: member.id) {
                    if let ms = outer {
                        Text(verbatim: "\(ms) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(ServerRow.latencyColor(ms))
                    } else {
                        Text(loc("timeout")).font(.caption2).foregroundStyle(.red)
                    }
                }
                if isPicked {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
