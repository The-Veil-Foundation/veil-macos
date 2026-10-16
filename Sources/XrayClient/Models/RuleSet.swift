import Foundation

/// Outbound tag names shared by every builder and by the control API.
///
/// Tags have to be stable across rebuilds — a rule stored in `store.json`
/// names one — so they are derived from the entity's UUID rather than from its
/// display name, which the user can rename at any time.
enum ProfileTags {
    static let defaultSelector = "proxy"
    static let direct = "direct"
    static let block = "block"
    static let dnsOut = "dns-out"

    static func server(_ id: UUID) -> String {
        "srv-" + id.uuidString.lowercased()
    }

    static func group(_ id: UUID) -> String {
        "grp-" + id.uuidString.lowercased()
    }

    /// Local SOCKS inbound of the child Xray process that fronts a node
    /// sing-box cannot speak (XHTTP, mKCP, VLESS post-quantum encryption).
    static func bridge(_ id: UUID) -> String {
        "bridge-" + id.uuidString.lowercased()
    }

    static func ruleSet(geosite code: String) -> String {
        "geosite-" + code.lowercased()
    }

    static func ruleSet(geoip code: String) -> String {
        "geoip-" + code.lowercased()
    }
}

/// A sing-box rule-set: the replacement for the `geosite:` / `geoip:` fields
/// that were removed from route rules in sing-box 1.12.
///
/// Remote sets are fetched and cached by sing-box itself, so the app only has
/// to name them. Local sets point at a `.srs` (binary) or `.json` (source)
/// file the user supplied.
struct RuleSetRef: Codable, Equatable, Identifiable, Hashable {
    enum Kind: String, Codable, Hashable { case remote, local }
    enum Format: String, Codable, Hashable { case binary, source }

    var id = UUID()
    var tag: String
    var kind: Kind = .remote
    var format: Format = .binary
    /// Remote sets only.
    var url: String = ""
    /// Local sets only.
    var path: String = ""
    /// How often sing-box refreshes a remote set.
    var updateInterval: String = "1d"
    /// Outbound tag used to download a remote set. Empty means "let sing-box
    /// decide", which resolves to the default route — fine before the tunnel is
    /// up, and what every other client does.
    var downloadDetour: String = ProfileTags.direct

    init(id: UUID = UUID(), tag: String, kind: Kind = .remote,
         format: Format = .binary, url: String = "", path: String = "",
         updateInterval: String = "1d",
         downloadDetour: String = ProfileTags.direct) {
        self.id = id
        self.tag = tag
        self.kind = kind
        self.format = format
        self.url = url
        self.path = path
        self.updateInterval = updateInterval
        self.downloadDetour = downloadDetour
    }

    /// sing-box `route.rule_set[]` entry, or nil when the reference is empty.
    func json() -> [String: Any]? {
        var dict: [String: Any] = [
            "tag": tag,
            "type": kind.rawValue,
            "format": format.rawValue
        ]
        switch kind {
        case .remote:
            guard !url.isEmpty else { return nil }
            dict["url"] = url
            if !updateInterval.isEmpty { dict["update_interval"] = updateInterval }
            if !downloadDetour.isEmpty { dict["download_detour"] = downloadDetour }
        case .local:
            guard !path.isEmpty else { return nil }
            dict["path"] = path
        }
        return dict
    }
}

/// Turns the `geosite:` / `geoip:` entries scattered through the rule list into
/// concrete rule-set references.
///
/// The upstream SagerNet repositories publish a compiled `.srs` per category,
/// which is exactly the shape sing-box wants, so a category the user typed in
/// the Xray dialect keeps working instead of being dropped.
enum RuleSetCatalog {

    /// `geosite:cn` → the compiled set for category `cn`.
    static func geositeURL(_ code: String) -> String {
        "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-\(code.lowercased()).srs"
    }

    /// `geoip:ru` → the compiled set for country `ru`.
    static func geoipURL(_ code: String) -> String {
        "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-\(code.lowercased()).srs"
    }

    /// `geoip:private` has a native matcher (`ip_is_private`), so it never
    /// becomes a rule-set.
    static let privateGeoIPCode = "private"

    /// Every rule-set the given rules imply, de-duplicated and ordered.
    /// `explicit` entries (ones the user configured by hand) win over a derived
    /// set with the same tag.
    static func derive(from rules: [RoutingRule],
                       dnsRules: [DNSRule] = [],
                       explicit: [RuleSetRef] = [],
                       updateInterval: String = "1d") -> [RuleSetRef] {
        var byTag: [String: RuleSetRef] = [:]
        var order: [String] = []

        func add(_ ref: RuleSetRef) {
            if byTag[ref.tag] == nil { order.append(ref.tag) }
            byTag[ref.tag] = ref
        }

        for rule in rules where rule.enabled {
            for entry in rule.domains {
                guard let code = MatcherSyntax.geositeCode(entry) else { continue }
                add(RuleSetRef(tag: ProfileTags.ruleSet(geosite: code),
                               url: geositeURL(code),
                               updateInterval: updateInterval))
            }
            for entry in rule.ips {
                guard let code = MatcherSyntax.geoipCode(entry),
                      code.lowercased() != privateGeoIPCode else { continue }
                add(RuleSetRef(tag: ProfileTags.ruleSet(geoip: code),
                               url: geoipURL(code),
                               updateInterval: updateInterval))
            }
        }
        for rule in dnsRules where rule.enabled {
            for entry in rule.domains {
                guard let code = MatcherSyntax.geositeCode(entry) else { continue }
                add(RuleSetRef(tag: ProfileTags.ruleSet(geosite: code),
                               url: geositeURL(code),
                               updateInterval: updateInterval))
            }
        }
        // Explicit references replace derived ones and are appended if new.
        for ref in explicit { add(ref) }
        return order.compactMap { byTag[$0] }
    }
}

/// Splits the Xray-dialect matcher strings the rest of the app stores into the
/// typed fields sing-box expects.
///
/// Note on bare entries: Xray treats `example.com` with no prefix as a
/// *substring* match, while every GUI that writes these lists — including this
/// one — means "this domain and its subdomains". sing-box gets the second
/// reading (`domain` + `domain_suffix`), which is what users expect and what
/// the previous builder already did.
enum MatcherSyntax {

    static func geositeCode(_ entry: String) -> String? {
        prefixValue(entry, "geosite:")
    }

    static func geoipCode(_ entry: String) -> String? {
        prefixValue(entry, "geoip:")
    }

    private static func prefixValue(_ entry: String, _ prefix: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let value = String(trimmed.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The domain matchers of one rule, already sorted into sing-box fields.
    struct Domains {
        var exact: [String] = []
        var suffix: [String] = []
        var keyword: [String] = []
        var regex: [String] = []
        var ruleSetTags: [String] = []

        var isEmpty: Bool {
            exact.isEmpty && suffix.isEmpty && keyword.isEmpty
                && regex.isEmpty && ruleSetTags.isEmpty
        }
    }

    static func domains(_ entries: [String]) -> Domains {
        var out = Domains()
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            let lower = entry.lowercased()
            if let code = geositeCode(entry) {
                out.ruleSetTags.append(ProfileTags.ruleSet(geosite: code))
            } else if lower.hasPrefix("full:") {
                out.exact.append(String(entry.dropFirst(5)))
            } else if lower.hasPrefix("domain:") {
                appendSubdomain(String(entry.dropFirst(7)), to: &out)
            } else if lower.hasPrefix("keyword:") {
                out.keyword.append(String(entry.dropFirst(8)))
            } else if lower.hasPrefix("regexp:") {
                out.regex.append(String(entry.dropFirst(7)))
            } else if lower.hasPrefix("ext:") {
                continue    // external .dat file: Xray-only, nothing to map
            } else {
                appendSubdomain(entry, to: &out)
            }
        }
        return out
    }

    /// "this domain and anything under it". `domain_suffix` alone would also
    /// match `notexample.com`, so the apex goes in as an exact match and the
    /// suffix carries the leading dot.
    private static func appendSubdomain(_ value: String, to out: inout Domains) {
        let host = value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return }
        out.exact.append(host)
        out.suffix.append("." + host)
    }

    /// The IP matchers of one rule, already sorted into sing-box fields.
    struct IPs {
        var cidrs: [String] = []
        var ruleSetTags: [String] = []
        var isPrivate = false

        var isEmpty: Bool { cidrs.isEmpty && ruleSetTags.isEmpty && !isPrivate }
    }

    static func ips(_ entries: [String]) -> IPs {
        var out = IPs()
        for raw in entries {
            let entry = raw.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if let code = geoipCode(entry) {
                if code.lowercased() == RuleSetCatalog.privateGeoIPCode {
                    out.isPrivate = true
                } else {
                    out.ruleSetTags.append(ProfileTags.ruleSet(geoip: code))
                }
            } else {
                out.cidrs.append(entry)
            }
        }
        return out
    }

    /// Ports as sing-box wants them: single values in `port`, ranges in
    /// `port_range`. Accepts "443", "443,8443", "1000-2000", "1000:2000",
    /// open ends like ":1024" and mixtures. Ranges come out as "a:b", the only
    /// form sing-box parses; anything it would reject is dropped here so one
    /// bad entry cannot stop the core from starting.
    static func ports(_ text: String) -> (ports: [Int], ranges: [String]) {
        var ports: [Int] = []
        var ranges: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            if let value = port(piece) {
                ports.append(value)
            } else if let range = portRange(piece) {
                ranges.append(range)
            }
        }
        return (ports, ranges)
    }

    private static func port(_ token: Substring) -> Int? {
        guard !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(token), (1...65535).contains(value) else { return nil }
        return value
    }

    private static func portRange(_ token: Substring) -> String? {
        let parts = token.split(separator: token.contains(":") ? ":" : "-",
                                omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let (lower, upper) = (parts[0], parts[1])
        if lower.isEmpty && upper.isEmpty { return nil }
        // "a-" and "-b" read as a negative number or a typo; only the colon
        // form may leave an end open, as in sing-box itself.
        if (lower.isEmpty || upper.isEmpty) && !token.contains(":") { return nil }
        let low = lower.isEmpty ? nil : port(lower)
        let high = upper.isEmpty ? nil : port(upper)
        if !lower.isEmpty && low == nil { return nil }
        if !upper.isEmpty && high == nil { return nil }
        if let low, let high, low > high { return nil }
        return "\(low.map(String.init) ?? ""):\(high.map(String.init) ?? "")"
    }
}
