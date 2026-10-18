import Foundation

/// The platform-neutral half of turning the server list into an outbound graph.
///
/// Both profile builders — sing-box's on the Mac and Xray's on iOS — start from
/// the same question: which nodes exist, which groups sit over them, and what
/// the user's pick resolves to. Answering it once keeps the two cores agreeing
/// about what "connect to this" means.
enum OutboundGraph {

    /// The user's groups and the panels' groups as one list.
    ///
    /// A collision can only happen if a stored group was built from a panel's
    /// in the first place, and the user's copy is the one they edited.
    static func allGroups(own: [ServerGroup], declared: [ServerGroup]) -> [ServerGroup] {
        let ids = Set(own.map(\.id))
        return own + declared.filter { !ids.contains($0.id) }
    }

    /// Flattens balancer entries into real nodes plus a group over them.
    ///
    /// A subscription's balancer arrives as one `ProxyConfig` carrying its
    /// alternates. The graph has no place for that shape: every node needs its
    /// own tag, and "pick one of these" is what a group is for.
    static func expand(_ servers: [ProxyConfig],
                       groups: [ServerGroup]) -> (servers: [ProxyConfig], groups: [ServerGroup]) {
        var flattened: [ProxyConfig] = []
        var derived: [ServerGroup] = []

        for server in servers {
            guard server.isBalancer else {
                flattened.append(server)
                continue
            }
            var own = server
            own.alternates = nil
            let nodes = [own] + (server.alternates ?? [])
            flattened.append(contentsOf: nodes)
            var group = ServerGroup(id: server.id, name: server.name,
                                    kind: .urltest, memberIDs: nodes.map(\.id))
            group.interval = "1m"
            group.tolerance = 150
            derived.append(group)
        }
        // A user-defined group with the same id as a derived one wins: the
        // user configured it on purpose.
        let userIDs = Set(groups.map(\.id))
        return (flattened, groups + derived.filter { !userIDs.contains($0.id) })
    }

    /// Which outbound the default `proxy` route should resolve to.
    ///
    /// The picked id may name a group rather than a server — groups and
    /// servers share one selection in the UI, because from the user's side
    /// "connect to this" means the same thing either way.
    static func target(for id: UUID?,
                       groups: [ServerGroup],
                       servers: [ProxyConfig]) -> RuleTarget {
        guard let id else { return .direct }
        if groups.contains(where: { $0.id == id }) { return .group(id) }
        if servers.contains(where: { $0.id == id }) { return .server(id) }
        return .direct
    }

    /// Reads a stored outbound tag — a DNS detour, say — back into a target.
    static func target(forTag tag: String) -> RuleTarget? {
        switch tag {
        case ProfileTags.defaultSelector: return .proxy
        case ProfileTags.direct:          return .direct
        case ProfileTags.block:           return .block
        default:
            if tag.hasPrefix("srv-"), let id = UUID(uuidString: String(tag.dropFirst(4))) {
                return .server(id)
            }
            if tag.hasPrefix("grp-"), let id = UUID(uuidString: String(tag.dropFirst(4))) {
                return .group(id)
            }
            return nil
        }
    }
}
