import Foundation

/// One source as the list sees it: a subscription, or the manual set.
struct ListSource {
    var id: UUID
    var name: String
    var isCollapsed: Bool = false
    /// Groups shown as single rows — the panel's balancers and the user's own.
    var groupRows: [ProxyConfig] = []
    var servers: [ProxyConfig] = []
}

/// Everything the list header offers, in one value.
struct ListFilter {
    var search: String = ""
    var aliveOnly: Bool = false
    var sortByPing: Bool = false
    /// Manual labels. Several are OR-ed: a node matching any of them stays.
    var tags: [String] = []
    /// ISO codes, OR-ed among themselves and AND-ed with the other kinds.
    var countries: [String] = []
    var protocols: [ProxyProtocol] = []
    var showHidden: Bool = false
    /// Injected so the builder stays a pure function of its arguments; the app
    /// passes `PingTester`'s reading.
    var latency: (UUID) -> Int? = { _ in nil }

    /// Whether anything here can empty a section. Collapse and the ping sort
    /// cannot, so they do not count.
    var isNarrowing: Bool {
        !search.trimmingCharacters(in: .whitespaces).isEmpty
            || aliveOnly || !tags.isEmpty || !countries.isEmpty || !protocols.isEmpty
    }
}

struct ListSection: Identifiable {
    var id: String
    var title: String
    /// Set under subscription grouping, so the header can show the source's
    /// traffic, expiry and actions. Nil when the section is a facet.
    var subscriptionID: UUID?
    var isCollapsed: Bool = false
    var groups: [ProxyConfig] = []
    var servers: [ProxyConfig] = []
    /// Nodes held back by their `hidden` annotation, which the section offers
    /// to show.
    var hiddenCount: Int = 0
}

/// Turns the store's sources into the sections the list draws.
///
/// This is where ordering, grouping and filtering live, so that the rows on
/// screen and the order the arrow keys walk cannot disagree — they ask the same
/// function.
enum ServerListBuilder {

    static func sections(sources: [ListSource],
                         annotations: [UUID: NodeAnnotation],
                         grouping: ListGrouping,
                         filter: ListFilter,
                         autoTags: Bool = false,
                         locale: Locale = .current) -> [ListSection] {
        switch grouping {
        case .subscription:
            return sources.compactMap { source in
                let servers = prepare(source.servers, annotations: annotations,
                                      filter: filter, autoTags: autoTags)
                let groups = prepare(source.groupRows, annotations: annotations,
                                     filter: filter, autoTags: autoTags)
                guard !(filter.isNarrowing && servers.rows.isEmpty && groups.rows.isEmpty) else {
                    return nil
                }
                return ListSection(id: source.id.uuidString,
                                   title: source.name,
                                   subscriptionID: source.id,
                                   isCollapsed: source.isCollapsed,
                                   groups: groups.rows,
                                   servers: servers.rows,
                                   hiddenCount: servers.hidden + groups.hidden)
            }

        case .none:
            let servers = prepare(sources.flatMap(\.servers),
                                  annotations: annotations, filter: filter,
                                  autoTags: autoTags)
            let groups = prepare(sources.flatMap(\.groupRows),
                                 annotations: annotations, filter: filter,
                                 autoTags: autoTags)
            guard !servers.rows.isEmpty || !groups.rows.isEmpty || !filter.isNarrowing else {
                return []
            }
            return [ListSection(id: "all", title: "All servers",
                                groups: groups.rows, servers: servers.rows,
                                hiddenCount: servers.hidden + groups.hidden)]

        case .country:
            return facetSections(sources: sources, annotations: annotations,
                                 filter: filter, autoTags: autoTags) { server in
                NodeFacets(for: server).country.map {
                    [Facet(key: $0, title: NodeFacets.countryName(for: $0, locale: locale))]
                } ?? []
            }

        case .protocolType:
            return facetSections(sources: sources, annotations: annotations,
                                 filter: filter, autoTags: autoTags) { server in
                [Facet(key: server.proto.rawValue, title: server.proto.rawValue.uppercased())]
            }

        case .tag:
            return facetSections(sources: sources, annotations: annotations,
                                 filter: filter, autoTags: autoTags) { server in
                AutoTags.all(for: server,
                             annotation: annotations[server.id] ?? NodeAnnotation(),
                             derived: autoTags)
                    .map { Facet(key: $0, title: $0) }
            }
        }
    }

    // MARK: - Facet sections

    private struct Facet {
        var key: String
        var title: String
    }

    /// Buckets every row by whatever `facets` reads off it. A row with no facet
    /// of that kind lands in "Other" rather than disappearing — a node with no
    /// country in its name is still a node the user can connect to. A row with
    /// several appears under each.
    private static func facetSections(sources: [ListSource],
                                      annotations: [UUID: NodeAnnotation],
                                      filter: ListFilter,
                                      autoTags: Bool,
                                      facets: (ProxyConfig) -> [Facet]) -> [ListSection] {
        let servers = prepare(sources.flatMap(\.servers), annotations: annotations,
                              filter: filter, autoTags: autoTags)
        let groups = prepare(sources.flatMap(\.groupRows), annotations: annotations,
                             filter: filter, autoTags: autoTags)

        var titles: [String: String] = [:]
        var bucketedServers: [String: [ProxyConfig]] = [:]
        var bucketedGroups: [String: [ProxyConfig]] = [:]

        func bucket(_ rows: [ProxyConfig], into store: inout [String: [ProxyConfig]]) {
            for row in rows {
                let found = facets(row)
                guard !found.isEmpty else {
                    store[otherKey, default: []].append(row)
                    continue
                }
                for facet in found {
                    titles[facet.key] = facet.title
                    store[facet.key, default: []].append(row)
                }
            }
        }
        bucket(servers.rows, into: &bucketedServers)
        bucket(groups.rows, into: &bucketedGroups)

        let keys = Set(bucketedServers.keys).union(bucketedGroups.keys)
        let named = keys.filter { $0 != otherKey }
            .sorted { (titles[$0] ?? $0).localizedStandardCompare(titles[$1] ?? $1) == .orderedAscending }

        var sections = named.map { key in
            ListSection(id: key, title: titles[key] ?? key,
                        groups: bucketedGroups[key] ?? [],
                        servers: bucketedServers[key] ?? [])
        }
        // "Other" always closes the list: it is the leftovers, not a place.
        if bucketedServers[otherKey] != nil || bucketedGroups[otherKey] != nil {
            sections.append(ListSection(id: otherKey, title: "Other",
                                        groups: bucketedGroups[otherKey] ?? [],
                                        servers: bucketedServers[otherKey] ?? [],
                                        hiddenCount: servers.hidden + groups.hidden))
        } else if let index = sections.indices.last {
            sections[index].hiddenCount = servers.hidden + groups.hidden
        }
        return sections
    }

    private static let otherKey = "\u{FFFF}other"

    // MARK: - Rows

    private struct Prepared {
        var rows: [ProxyConfig]
        var hidden: Int
    }

    /// Applies the user's annotations, drops what the filter excludes, and puts
    /// what is left in order: pinned first, then whatever the user dragged into
    /// place, then the ping sort or the order the source supplied.
    private static func prepare(_ servers: [ProxyConfig],
                                annotations: [UUID: NodeAnnotation],
                                filter: ListFilter,
                                autoTags: Bool) -> Prepared {
        let search = filter.search.trimmingCharacters(in: .whitespaces).lowercased()
        var hidden = 0
        var kept: [(row: ProxyConfig, annotation: NodeAnnotation, order: Int)] = []

        for (index, server) in servers.enumerated() {
            let annotation = annotations[server.id] ?? NodeAnnotation()
            var row = server
            if let override = annotation.nameOverride, !override.isEmpty {
                row.name = override
            }

            if !search.isEmpty,
               !row.name.lowercased().contains(search),
               !row.address.lowercased().contains(search) { continue }
            if !filter.tags.isEmpty,
               Set(AutoTags.all(for: row, annotation: annotation, derived: autoTags))
                   .isDisjoint(with: filter.tags) { continue }
            if !filter.countries.isEmpty {
                guard let country = NodeFacets(for: row).country,
                      filter.countries.contains(country) else { continue }
            }
            if !filter.protocols.isEmpty, !filter.protocols.contains(row.proto) { continue }
            if filter.aliveOnly, filter.latency(row.id) == nil { continue }

            if annotation.hidden {
                hidden += 1
                if !filter.showHidden { continue }
            }
            kept.append((row, annotation, index))
        }

        kept.sort { a, b in
            if a.annotation.pinned != b.annotation.pinned { return a.annotation.pinned }
            let aIndex = a.annotation.sortIndex ?? Int.max
            let bIndex = b.annotation.sortIndex ?? Int.max
            if aIndex != bIndex { return aIndex < bIndex }
            if filter.sortByPing {
                // An unreachable node sorts last rather than first.
                let aPing = filter.latency(a.row.id) ?? Int.max
                let bPing = filter.latency(b.row.id) ?? Int.max
                if aPing != bPing { return aPing < bPing }
            }
            return a.order < b.order
        }

        return Prepared(rows: kept.map(\.row), hidden: hidden)
    }
}
