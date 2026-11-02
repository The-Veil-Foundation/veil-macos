import Foundation

/// What the user attached to a node, as opposed to what its source says about
/// it. Keyed by the node's id, which `NodeReconciler` keeps stable across a
/// subscription refresh — without that this would silently empty itself every
/// time a provider republished its list.
///
/// An annotation whose node is gone resolves to nothing and is kept rather than
/// collected: it is a handful of bytes, a provider that drops a node for a day
/// and restores it is ordinary, and a refresh that failed is not proof that
/// anything disappeared. Annotations go away with the source they belong to.
struct NodeAnnotation: Codable, Equatable {
    /// The user's own labels. Facets — country, protocol, transport — are read
    /// from the node itself and are not stored here.
    var tags: [String] = []
    /// Sorts to the top of its section.
    var pinned: Bool = false
    /// Stays in the store and out of the list.
    var hidden: Bool = false
    /// Shown instead of the name the source supplied.
    var nameOverride: String?
    /// Where the user dragged this node within its section. Nodes without one
    /// keep the order their source sent.
    var sortIndex: Int?

    var isEmpty: Bool {
        tags.isEmpty && !pinned && !hidden && nameOverride == nil && sortIndex == nil
    }

    /// Resilient decoding, like the rest of the store: a key this build does
    /// not recognise, or one an older build never wrote, falls back to its
    /// default instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
        nameOverride = try? c.decode(String.self, forKey: .nameOverride)
        sortIndex = try? c.decode(Int.self, forKey: .sortIndex)
    }

    init(tags: [String] = [], pinned: Bool = false, hidden: Bool = false,
         nameOverride: String? = nil, sortIndex: Int? = nil) {
        self.tags = tags
        self.pinned = pinned
        self.hidden = hidden
        self.nameOverride = nameOverride
        self.sortIndex = sortIndex
    }
}

/// How the server list is divided into sections.
enum ListGrouping: String, Codable, CaseIterable, Identifiable {
    /// One section per subscription — what the list has always done.
    case subscription
    /// One section per user label.
    case tag
    /// One section per country, merging every source.
    case country
    /// One section per protocol — VLESS, Hysteria2, WireGuard…
    case protocolType = "protocol"
    /// One flat list.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscription: return "Subscription"
        case .tag:          return "Tag"
        case .country:      return "Country"
        case .protocolType: return "Protocol"
        case .none:         return "No grouping"
        }
    }

    var icon: String {
        switch self {
        case .subscription: return "square.stack.3d.up"
        case .tag:          return "tag"
        case .country:      return "globe"
        case .protocolType: return "network"
        case .none:         return "list.bullet"
        }
    }
}

/// Writes and clears the manual order a drag produces.
enum NodeOrdering {

    /// Numbers the given ids from zero, in the order they are now in. Only
    /// those ids are touched, so dragging inside one section cannot renumber
    /// another.
    static func apply(order ids: [UUID], to annotations: inout [UUID: NodeAnnotation]) {
        for (index, id) in ids.enumerated() {
            var annotation = annotations[id] ?? NodeAnnotation()
            annotation.sortIndex = index
            annotations[id] = annotation
        }
    }

    /// Drops the manual order, handing the section back to the order its source
    /// supplies. An annotation left with nothing in it goes too.
    static func clear(_ ids: [UUID], in annotations: inout [UUID: NodeAnnotation]) {
        for id in ids {
            guard var annotation = annotations[id] else { continue }
            annotation.sortIndex = nil
            annotations[id] = annotation.isEmpty ? nil : annotation
        }
    }
}
