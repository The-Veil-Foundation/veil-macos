import SwiftUI

struct ServerRow: View {
    @Environment(Loc.self) private var loc

    let server: ProxyConfig
    let isSelected: Bool
    let isActive: Bool
    /// Outer nil = never tested; inner nil = tested and unreachable.
    let latency: Int??
    let isTesting: Bool
    /// What the user attached to this node, if anything.
    var annotation = NodeAnnotation()
    /// Whether the row also shows the tags read out of the node's own name.
    var autoTags = false
    /// Set for a group's row: how many members it has and what kind it is.
    var group: ServerGroup?
    /// For an active "fastest" group: the member the probes favour.
    var via: String?

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if group != nil {
                        Image(systemName: group?.kind == .urltest ? "bolt.horizontal" : "hand.point.up.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if annotation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(server.name)
                        .lineLimit(1)
                        .foregroundStyle(server.xraySupported && !annotation.hidden
                                         ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                HStack(spacing: 6) {
                    if let group {
                        Text(verbatim: "\(loc("Members")): \(group.memberIDs.count)")
                        Text(loc(group.kind.title))
                    } else {
                        Text(server.proto.rawValue.uppercased())
                        if server.isBalancer {
                            Text(verbatim: "×\((server.alternates?.count ?? 0) + 1)")
                        }
                        if !server.xraySupported {
                            Text(loc("needs sing-box"))
                                .foregroundStyle(.orange)
                        }
                    }
                    if let via {
                        Text(verbatim: "→ \(via)")
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                let tags = Array(AutoTags.all(for: server, annotation: annotation,
                                              derived: autoTags).prefix(4))
                if group == nil, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            let isOwn = annotation.tags.contains(tag)
                            Text(tag)
                                .font(.caption2)
                                .lineLimit(1)
                                .foregroundStyle(isOwn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(isOwn
                                                           ? Color.accentColor.opacity(0.18)
                                                           : Color.secondary.opacity(0.12)))
                        }
                    }
                }
            }

            Spacer(minLength: 4)

            latencyBadge

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var latencyBadge: some View {
        if isTesting {
            ProgressView().controlSize(.mini)
        } else if let outer = latency {
            if let ms = outer {
                Text(verbatim: "\(ms) ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Self.latencyColor(ms))
            } else {
                Text(loc("timeout"))
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    static func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<150: return .green
        case ..<350: return .orange
        default:     return .red
        }
    }
}
