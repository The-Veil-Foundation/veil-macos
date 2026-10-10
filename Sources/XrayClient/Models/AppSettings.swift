import Foundation

/// How traffic is captured.
enum TunnelMode: String, Codable, CaseIterable, Identifiable {
    case systemProxy   // SOCKS/HTTP system proxy (no admin, browsers only)
    case tun           // full-traffic TUN via tun2socks (needs admin)

    var id: String { rawValue }
    var title: String {
        switch self {
        case .systemProxy: return "System Proxy"
        case .tun:         return "TUN (All Apps)"
        }
    }
    var subtitle: String {
        switch self {
        case .systemProxy: return "Browsers & proxy-aware apps. No password needed."
        case .tun:         return "All traffic incl. Telegram, terminal, games. Asks for password."
        }
    }
}

enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// Verbosity of the bundled Xray core's log output.
enum LogLevel: String, Codable, CaseIterable, Identifiable {
    case debug, info, warning, error, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .debug:   return "Debug"
        case .info:    return "Info"
        case .warning: return "Warning"
        case .error:   return "Error"
        case .none:    return "None"
        }
    }
}


/// User-facing settings, persisted alongside subscriptions.
struct AppSettings: Codable, Equatable {
    var mode: TunnelMode = .systemProxy
    var appearance: AppAppearance = .system
    var language: AppLanguage = .system
    var autoUpdateSubscriptions: Bool = true
    var autoUpdateIntervalHours: Int = 12

    /// Intervals offered for `autoUpdateIntervalHours`, in hours.
    ///
    /// A list beats the stepper this replaced: the old control moved one hour
    /// at a time between 1 and 168, so reaching a day meant twenty-four hits on
    /// an arrow a few pixels tall. `current` is folded in so a value an earlier
    /// build stored — or one set from the control API — is still selectable
    /// rather than being snapped to the nearest preset the first time Settings
    /// is opened.
    static func autoUpdateIntervalChoices(including current: Int) -> [Int] {
        let presets = [1, 3, 6, 12, 24, 48, 168]
        guard current > 0, !presets.contains(current) else { return presets }
        return (presets + [current]).sorted()
    }
    var closeToTray: Bool = true            // red button hides to menu bar
    /// Keep Veil out of the Dock and the ⌘-Tab switcher, running from the menu
    /// bar alone. Flipping it swaps the activation policy live, so it takes
    /// effect without a relaunch.
    var hideDockIcon: Bool = false
    var socksPort: Int = 10808
    var httpPort: Int = 10809
    var lastSelectedServerID: UUID?
    var logLevel: LogLevel = .warning

    // Routing
    var routingPreset: RoutingPreset = .bypassLAN
    var customRules: [RoutingRule] = []
    var blockAds: Bool = false
    var geoSource: GeoAssetSource = .loyalsoldier
    var customGeoipURL: String = ""
    var customGeositeURL: String = ""

    // Routing v2 — the outbound graph. Groups are named sets of servers that
    // behave like one outbound, so a rule can send an app through a specific
    // group instead of through "the proxy".
    var serverGroups: [ServerGroup] = []
    /// The Routing window's last tab, so opening it from a group row can land
    /// on the groups rather than on the rules.
    var lastRoutingTab: String = "rules"
    // What the user attached to individual nodes — tags, pinning, hiding,
    // manual order, a name of their own — and how the list is divided up.
    // Keyed by node id, which survives a subscription refresh now that
    // `NodeReconciler` matches incoming nodes onto stored ones.
    var nodeAnnotations: [UUID: NodeAnnotation] = [:]
    var listGrouping: ListGrouping = .subscription
    /// Show nodes the user hid.
    var showHiddenNodes: Bool = false
    /// Read tags out of a node's own name and settings — the country, the
    /// protocol, a provider's own words like "Premium" — on top of the labels
    /// the user attached by hand.
    ///
    /// Off by default: these are guesses about someone else's naming, and a
    /// list where every node carries four tags nobody wrote is noisier than
    /// one with none.
    var autoTags: Bool = false
    /// Show the Sources tab at the top of the main window. Someone who set
    /// their subscriptions up once does not need the page every day.
    var showSourcesTab: Bool = true
    /// How tall the log pane is, in points, dragged by its top edge.
    var logPaneHeight: Double = 168

    /// Rule-sets the user added by hand. The ones implied by `geosite:` /
    /// `geoip:` entries are derived at build time and need no storage.
    var ruleSets: [RuleSetRef] = []

    /// Community rule lists the user turned on, by `CommunityList.id`. Only
    /// the ids live here; the lists themselves are cached on disk by
    /// `CommunityListManager`, because they are bulk data that can be fetched
    /// again at any time.
    var communityLists: [String] = []
    /// Where a match in one of those lists goes. Selecting a list normally
    /// means "send this through the tunnel", which is what `.proxy` does.
    var communityListTarget: RuleTarget = .proxy

    // Resolver
    var dns = DNSSettings()

    // sing-box TUN. Process-aware rules only work when sing-box owns the
    // interface, so the native inbound is the default and tun2socks is the
    // fallback for anyone who hits a problem with it.
    var useNativeTun: Bool = true
    var tunStrictRoute: Bool = false
    var tunStack: String = ""

    // Local control API (Clash-compatible, served by sing-box). Off unless
    // asked for: it is one more listening port, and its secret is random per
    // launch, so nothing outside Veil could use it anyway. Stored under a new
    // key so the old default-on value is not carried forward.
    var clashAPIEnabled: Bool = false
    var controlAPIPort: Int = 9090

    // Veil's own control API: read and write the routing configuration from
    // outside the app. Off by default — it can change where the machine's
    // traffic goes, so it is turned on deliberately or not at all.
    var veilAPIEnabled: Bool = false
    var veilAPIPort: Int = 9091

    // Startup
    var autoConnectOnLaunch: Bool = false
    var launchAtLogin: Bool = false

    // Notifications
    var notifyOnConnect: Bool = false

    // Subscription
    var sendHwid: Bool = true
    /// Overrides the User-Agent sent with subscription requests. Empty means
    /// the default one. Panels with custom Response Rules key off it.
    var userAgentOverride: String = ""

    // Tunnel shape. Only the iOS build reads these — there the whole tunnel is
    // Xray's own layer-3 inbound behind NetworkExtension, so the interface MTU,
    // the address families we claim and the resolver are ours to pick.
    var tunnelMTU: Int = 1500
    var ipv6Enabled: Bool = true
    var dnsServers: [String] = ["1.1.1.1", "8.8.8.8"]

    /// The heights the log pane may be dragged to. Below the minimum its own
    /// toolbar no longer fits; above the maximum there is no list left.
    static func clampedLogHeight(_ height: Double) -> Double {
        min(max(height, 96), 520)
    }

    init() {}

    /// Resilient decoding: any missing key falls back to its default so old
    /// `store.json` files (with fewer/older fields) still load cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        mode = get(.mode, .systemProxy)
        appearance = get(.appearance, .system)
        language = get(.language, .system)
        autoUpdateSubscriptions = get(.autoUpdateSubscriptions, true)
        autoUpdateIntervalHours = get(.autoUpdateIntervalHours, 12)
        closeToTray = get(.closeToTray, true)
        hideDockIcon = get(.hideDockIcon, false)
        socksPort = get(.socksPort, 10808)
        httpPort = get(.httpPort, 10809)
        lastSelectedServerID = try? c.decode(UUID.self, forKey: .lastSelectedServerID)
        logLevel = get(.logLevel, .warning)
        routingPreset = get(.routingPreset, .bypassLAN)
        customRules = get(.customRules, [])
        blockAds = get(.blockAds, false)
        geoSource = get(.geoSource, .loyalsoldier)
        customGeoipURL = get(.customGeoipURL, "")
        customGeositeURL = get(.customGeositeURL, "")
        serverGroups = get(.serverGroups, [])
        lastRoutingTab = get(.lastRoutingTab, "rules")
        nodeAnnotations = get(.nodeAnnotations, [:])
        listGrouping = get(.listGrouping, .subscription)
        showHiddenNodes = get(.showHiddenNodes, false)
        autoTags = get(.autoTags, false)
        showSourcesTab = get(.showSourcesTab, true)
        // A file written by hand, or by a build that clamped differently,
        // must not be able to hide the server list behind the log.
        logPaneHeight = AppSettings.clampedLogHeight(get(.logPaneHeight, 168))
        ruleSets = get(.ruleSets, [])
        communityLists = get(.communityLists, [])
        communityListTarget = get(.communityListTarget, .proxy)
        dns = get(.dns, DNSSettings())
        useNativeTun = get(.useNativeTun, true)
        tunStrictRoute = get(.tunStrictRoute, false)
        tunStack = get(.tunStack, "")
        clashAPIEnabled = get(.clashAPIEnabled, false)
        controlAPIPort = get(.controlAPIPort, 9090)
        veilAPIEnabled = get(.veilAPIEnabled, false)
        veilAPIPort = get(.veilAPIPort, 9091)
        autoConnectOnLaunch = get(.autoConnectOnLaunch, false)
        launchAtLogin = get(.launchAtLogin, false)
        notifyOnConnect = get(.notifyOnConnect, false)
        sendHwid = get(.sendHwid, true)
        userAgentOverride = get(.userAgentOverride, "")
        tunnelMTU = get(.tunnelMTU, 1500)
        ipv6Enabled = get(.ipv6Enabled, true)
        dnsServers = get(.dnsServers, ["1.1.1.1", "8.8.8.8"])
    }

    /// DNS servers to hand the tunnel, never empty — an empty resolver list
    /// would leave the device with no way to resolve anything at all.
    var effectiveDNSServers: [String] {
        let cleaned = dnsServers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? ["1.1.1.1", "8.8.8.8"] : cleaned
    }

    /// The ordered routing rules to feed Xray, derived from the active preset
    /// (or the user's custom list).
    var effectiveRoutingRules: [RoutingRule] {
        // The user's own rules apply under every preset, not only "Custom" —
        // wanting one application on a particular server is no reason to give
        // up the preset's bypasses. They sit between the guards, which have to
        // win, and the preset's country rules, which must not.
        //
        // With one exception, and it is the whole point of writing a rule by
        // hand: a rule that spells out the addresses or domains it is about
        // goes ahead of the guards. The LAN bypass exists to stop an
        // application rule from dragging the printer through the tunnel — it
        // was never meant to overrule "send 172.16.4.10 through this peer",
        // which is a sentence about the LAN and nothing else.
        let addressed = customRules.filter(\.namesItsOwnDestinations)
        let rest = customRules.filter { !$0.namesItsOwnDestinations }
        return addressed
            + routingPreset.guardRules(blockAds: blockAds)
            + rest
            + CommunityListManager.rules(for: self)
            + routingPreset.presetRules()
    }

    /// The parts of the settings the running core was built from.
    ///
    /// Everything else — the appearance, the update interval, where the log
    /// pane sits — can change without the tunnel caring. Comparing this
    /// against what the live connection started with is what says whether a
    /// reconnect would actually change anything, rather than announcing one
    /// every time the routing panes are opened.
    var routingFingerprint: RoutingFingerprint {
        RoutingFingerprint(preset: routingPreset,
                           blockAds: blockAds,
                           customRules: customRules,
                           serverGroups: serverGroups,
                           ruleSets: ruleSets,
                           communityLists: communityLists,
                           communityListTarget: communityListTarget,
                           dns: dns)
    }
}

/// What a routing edit can change about the configuration the core is running.
struct RoutingFingerprint: Equatable {
    var preset: RoutingPreset
    var blockAds: Bool
    var customRules: [RoutingRule]
    var serverGroups: [ServerGroup]
    var ruleSets: [RuleSetRef]
    var communityLists: [String]
    var communityListTarget: RuleTarget
    var dns: DNSSettings
}

