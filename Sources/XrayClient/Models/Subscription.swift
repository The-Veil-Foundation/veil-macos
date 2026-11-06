import Foundation

/// A subscription profile: a named group of servers fetched from one URL,
/// with optional traffic/expiry metadata (parsed from the Subscription-Userinfo
/// HTTP header that most panels return).
struct Subscription: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var url: String?               // nil for the manual/local group
    var servers: [ProxyConfig] = []
    /// Groups this subscription's panel declared in its config, over
    /// `servers`. Refreshed with the node list and never merged with the
    /// user's own groups: the panel owns these, the user owns those.
    ///
    /// Optional so that stores written by older builds still decode — the
    /// whole file is read with one `try?`, so a key a 1.6.3 store cannot
    /// contain would empty every subscription on upgrade.
    var groups: [ServerGroup]?

    /// The declared groups, or none.
    var declaredGroups: [ServerGroup] { groups ?? [] }
    var lastUpdated: Date?
    var autoUpdate: Bool = true
    var isCollapsed: Bool = false
    /// Kept at the top of the list, above the sources the user did not pin.
    /// Optional so that stores written by older builds still decode.
    var pinned: Bool?
    var note: String?              // free-form description

    /// True when `url` lives in the Keychain rather than in `store.json`.
    /// Optional so that stores written by older builds still decode.
    var hasStoredURL: Bool?

    // Panel metadata (see `SubscriptionMetadata`). All optional: a panel that
    // says nothing leaves them nil.
    var supportURL: String?
    var webPageURL: String?
    var updateIntervalHours: Int?  // refresh cadence the panel asked for
    var refillDate: Date?          // when the traffic allowance is topped up
    var hwidStatus: SubscriptionMetadata.HWIDStatus?
    var lastFormat: SubscriptionPayload.Format?
    /// What the last fetch could not use, so the sources page can say why a
    /// server the provider lists is not in the list. Optional so that stores
    /// written by older builds still decode.
    var lastSkipped: [SubscriptionPayload.SkipNote]?

    /// Per-subscription overrides. nil means "follow the global setting".
    var sendHWID: Bool?
    /// The User-Agent sent when `requestAs` is `.custom`. A value stored by an
    /// older build, before `requestAs` existed, is still honoured.
    var userAgentOverride: String?
    /// Which kind of client Veil introduces itself as when fetching this
    /// subscription. nil is `.automatic`. Optional so that stores written by
    /// older builds still decode.
    var requestAs: SubscriptionRequestProfile?

    // Traffic accounting (bytes). nil when the panel doesn't report it.
    var uploadBytes: Int64?
    var downloadBytes: Int64?
    var totalBytes: Int64?
    var expiresAt: Date?           // from `expire=` epoch seconds

    init(name: String, url: String? = nil) {
        self.name = name
        self.url = url
    }

    var usedBytes: Int64? {
        guard let up = uploadBytes, let down = downloadBytes else { return nil }
        return up + down
    }

    /// 0...1 fraction of traffic used, when both used and total are known.
    var usageFraction: Double? {
        guard let used = usedBytes, let total = totalBytes, total > 0 else { return nil }
        return min(1.0, Double(used) / Double(total))
    }

    /// True when the plan has no traffic cap. Panels say so by sending
    /// `total=0` — which `ByteCountFormatter` renders as "Zero KB", a quota of
    /// nothing rather than the unlimited one it means.
    var isUnlimitedTraffic: Bool {
        guard let total = totalBytes else { return false }
        return total <= 0
    }

    /// True when there is any traffic figure worth putting on screen.
    var hasTrafficInfo: Bool { usedBytes != nil }

    /// The manual/local group is the one that never had a URL. A subscription
    /// whose URL is in the Keychain is not manual even while `url` is nil.
    var isManual: Bool { url == nil && hasStoredURL != true }

    /// Applies what the panel reported in the response headers.
    mutating func apply(_ metadata: SubscriptionMetadata) {
        if let info = metadata.userinfo {
            uploadBytes = info.upload
            downloadBytes = info.download
            totalBytes = info.total
            expiresAt = info.expire
        }
        if let announce = metadata.announce { note = announce }
        if let support = metadata.supportURL { supportURL = support }
        if let page = metadata.webPageURL { webPageURL = page }
        if let hours = metadata.updateIntervalHours { updateIntervalHours = hours }
        if let refill = metadata.refillDate { refillDate = refill }
        if metadata.hwidStatus != .unknown { hwidStatus = metadata.hwidStatus }
    }

    /// The User-Agent override to fetch this subscription with, or nil for
    /// Veil's own. `global` is the app-wide override from Settings.
    func requestUserAgent(global: String) -> String? {
        switch requestAs ?? .automatic {
        case .automatic, .custom:
            let own = userAgentOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !own.isEmpty { return own }
            let shared = global.trimmingCharacters(in: .whitespacesAndNewlines)
            return shared.isEmpty ? nil : shared
        case .xrayJSON, .singbox:
            return (requestAs ?? .automatic).presetUserAgent
        }
    }

    /// How long to wait before refreshing, honouring the panel's own request
    /// when it made one.
    func refreshInterval(defaultHours: Int) -> TimeInterval {
        TimeInterval(max(1, updateIntervalHours ?? defaultHours) * 3600)
    }
}

/// Which client to present to a subscription panel.
///
/// Panels (Remnawave's Response Rules, Marzban's templates) pick what to send
/// from the User-Agent: a client they know as an Xray one gets a full Xray
/// config with balancers and routing, a sing-box one gets a sing-box config,
/// and anything unknown — Veil included — gets a bare list of share links. The
/// same subscription can look very different in Veil and in Happ for that
/// reason alone.
enum SubscriptionRequestProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Veil's own User-Agent, or the override from Settings.
    case automatic
    /// Ask for a full Xray-core config.
    case xrayJSON
    /// Ask for a full sing-box config.
    case singbox
    /// A User-Agent the user typed.
    case custom

    var id: String { rawValue }

    /// What to call it in the interface (an English `Loc` key).
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .xrayJSON:  return "Xray config"
        case .singbox:   return "sing-box config"
        case .custom:    return "Custom User-Agent"
        }
    }

    /// The User-Agent panels map to this format. Picked to match the default
    /// rules panels ship with: Remnawave and Marzban both serve Xray JSON to
    /// Happ and sing-box JSON to the official sing-box apps (`SF*`).
    var presetUserAgent: String? {
        switch self {
        case .xrayJSON: return "Happ/3.0.0"
        case .singbox:  return "SFM/1.14.0"
        case .automatic, .custom: return nil
        }
    }
}

/// Parses the `Subscription-Userinfo` response header, e.g.
/// `upload=1234; download=5678; total=10737418240; expire=1700000000`.
enum SubscriptionUserinfo {
    struct Info: Equatable {
        var upload: Int64?
        var download: Int64?
        var total: Int64?
        var expire: Date?
    }

    static func parse(_ header: String) -> Info {
        var info = Info()
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "upload":   info.upload = Int64(value)
            case "download": info.download = Int64(value)
            case "total":    info.total = Int64(value)
            case "expire":
                if let epoch = TimeInterval(value), epoch > 0 {
                    info.expire = Date(timeIntervalSince1970: epoch)
                }
            default: break
            }
        }
        return info
    }
}

/// Human-readable byte formatting (GB/MB/etc.).
enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }
}
