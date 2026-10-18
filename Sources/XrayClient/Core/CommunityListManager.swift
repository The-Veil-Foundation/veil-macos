import Foundation
import Observation

/// Downloads, caches and expands the community rule lists.
///
/// The lists are plain text, one matcher per line, so nothing here has to
/// understand a binary database format: a list becomes a routing rule with its
/// domains and subnets filled in, and both cores already know what to do with
/// that.
///
/// The parsed contents are also kept in a lock-guarded snapshot, because
/// `AppSettings.effectiveRoutingRules` is a synchronous, non-isolated property
/// and every builder reads it on whatever thread it happens to be on.
@MainActor
@Observable
final class CommunityListManager {

    static let shared = CommunityListManager()

    /// One list as it sits on disk.
    struct Cached: Sendable {
        var domains: [String] = []
        var ips: [String] = []
        var updated: Date?

        var isEmpty: Bool { domains.isEmpty && ips.isEmpty }
        var entryCount: Int { domains.count + ips.count }
    }

    private(set) var downloading: Set<String> = []
    private(set) var lastError: String?
    /// Bumped after every successful refresh so views re-read the counts.
    private(set) var revision = 0

    private init() {
        Self.snapshot.load(from: Self.directory)
    }

    // MARK: - Reading

    /// What is cached for one list, or nil when it was never downloaded.
    func cached(_ id: String) -> Cached? { Self.snapshot.value(for: id) }

    func isDownloading(_ id: String) -> Bool { downloading.contains(id) }

    var isBusy: Bool { !downloading.isEmpty }

    /// When the oldest selected list was last refreshed.
    func oldestUpdate(among ids: [String]) -> Date? {
        ids.compactMap { Self.snapshot.value(for: $0)?.updated }.min()
    }

    // MARK: - Rules

    /// The routing rules the selected lists expand into.
    ///
    /// One rule per list rather than one merged rule: the log then names which
    /// list sent a connection where, and turning a single list off does not
    /// force everything else to be rebuilt.
    nonisolated static func rules(for settings: AppSettings) -> [RoutingRule] {
        settings.communityLists.compactMap { id in
            guard let list = CommunityListCatalog.list(id: id),
                  let cached = snapshot.value(for: id),
                  !cached.isEmpty else { return nil }
            var rule = RoutingRule(name: list.title,
                                   target: settings.communityListTarget,
                                   domains: cached.domains,
                                   ips: cached.ips)
            // These are generated on every build from the stored ids; a stable
            // identifier keeps them from churning in the diff of a rendered
            // config between two otherwise identical runs.
            rule.id = UUID(uuidString: Self.stableUUID(for: id)) ?? UUID()
            return rule
        }
    }

    /// A deterministic UUID per list id, so the generated rules keep the same
    /// identity across launches.
    private nonisolated static func stableUUID(for id: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        let hex = String(format: "%016lx", hash)
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-4\(hex.dropFirst(12).prefix(3))-8000-\(hex)"
    }

    // MARK: - Downloading

    /// Fetches every selected list that is missing or stale.
    func refreshDue(_ settings: AppSettings, maxAge: TimeInterval = 24 * 3600) async {
        let stale = settings.communityLists.filter { id in
            guard let updated = Self.snapshot.value(for: id)?.updated else { return true }
            return Date().timeIntervalSince(updated) > maxAge
        }
        guard !stale.isEmpty else { return }
        await refresh(ids: stale)
    }

    /// Fetches the named lists, whatever their age.
    func refresh(ids: [String]) async {
        guard !ids.isEmpty else { return }
        lastError = nil
        downloading.formUnion(ids)
        defer { downloading.subtract(ids); revision += 1 }

        await withTaskGroup(of: (String, Cached?, String?).self) { group in
            for id in ids {
                guard let list = CommunityListCatalog.list(id: id) else { continue }
                group.addTask {
                    do {
                        return (id, try await Self.fetch(list), nil)
                    } catch {
                        return (id, nil, error.localizedDescription)
                    }
                }
            }
            for await (id, cached, failure) in group {
                if let cached {
                    Self.snapshot.set(cached, for: id)
                    Self.snapshot.write(id: id, cached: cached, in: Self.directory)
                } else if let failure {
                    lastError = failure
                }
                downloading.remove(id)
                revision += 1
            }
        }
    }

    /// Re-fetches everything that is selected, ignoring the cache age.
    func refreshAll(_ settings: AppSettings) async {
        await refresh(ids: settings.communityLists)
    }

    private nonisolated static func fetch(_ list: CommunityList) async throws -> Cached {
        var cached = Cached(updated: Date())
        cached.domains = try await lines(at: CommunityListCatalog.rawURL(list.domainPath))
            .compactMap(normalizeDomain)
        for path in [list.ipv4Path, list.ipv6Path].compactMap({ $0 }) {
            // A missing subnet file is not a failure: most services only
            // publish domains.
            if let subnets = try? await lines(at: CommunityListCatalog.rawURL(path)) {
                cached.ips.append(contentsOf: subnets.compactMap(normalizeCIDR))
            }
        }
        guard !cached.isEmpty else {
            throw ListError.empty(list.title)
        }
        return cached
    }

    private nonisolated static func lines(at url: URL) async throws -> [String] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(DeviceInfo.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ListError.http(url.lastPathComponent, http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ListError.unreadable(url.lastPathComponent)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// `.ua` and `example.com` both mean "this name and everything under it",
    /// which is how the rest of the app already reads a bare entry.
    private nonisolated static func normalizeDomain(_ raw: String) -> String? {
        var value = raw
        if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
        value = value.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !value.isEmpty, value.allSatisfy({ !$0.isWhitespace }) else { return nil }
        return value
    }

    private nonisolated static func normalizeCIDR(_ raw: String) -> String? {
        var value = raw
        if let comment = value.firstIndex(of: "#") { value = String(value[..<comment]) }
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.contains("/") || value.contains(":")
                || value.contains(".") else { return nil }
        return value
    }

    // MARK: - Storage

    /// Cached lists live beside the geo databases, not in `store.json`: they
    /// are bulk data that can always be fetched again.
    static var directory: URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("XrayClient/lists", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Drops every cached list from disk and memory.
    func clearCache() {
        try? FileManager.default.removeItem(at: Self.directory)
        Self.snapshot.removeAll()
        revision += 1
    }

    enum ListError: LocalizedError {
        case http(String, Int)
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .http(let name, let code): return "\(name): HTTP \(code)"
            case .unreadable(let name):     return "\(name): unreadable"
            case .empty(let name):          return "\(name): the list came back empty"
            }
        }
    }

    // MARK: - Snapshot

    /// Lock-guarded store shared between the actor-isolated manager and the
    /// non-isolated rule expansion.
    private final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Cached] = [:]

        func value(for id: String) -> Cached? {
            lock.lock(); defer { lock.unlock() }
            return values[id]
        }

        func set(_ value: Cached, for id: String) {
            lock.lock(); defer { lock.unlock() }
            values[id] = value
        }

        func removeAll() {
            lock.lock(); defer { lock.unlock() }
            values.removeAll()
        }

        /// One JSON file per list, so a partial cache is still usable.
        func write(id: String, cached: Cached, in directory: URL) {
            let payload: [String: Any] = [
                "domains": cached.domains,
                "ips": cached.ips,
                "updated": cached.updated?.timeIntervalSince1970 ?? 0
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            try? data.write(to: directory.appendingPathComponent("\(id).json"),
                            options: .atomic)
        }

        func load(from directory: URL) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                var cached = Cached()
                cached.domains = (json["domains"] as? [String]) ?? []
                cached.ips = (json["ips"] as? [String]) ?? []
                if let stamp = json["updated"] as? TimeInterval, stamp > 0 {
                    cached.updated = Date(timeIntervalSince1970: stamp)
                }
                set(cached, for: file.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private nonisolated static let snapshot = Snapshot()
}
