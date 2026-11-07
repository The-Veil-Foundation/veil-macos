import Foundation

/// Input validation for everything that crosses the privilege boundary.
///
/// The helper runs as root, so it treats every value from the app as hostile
/// even though the connection is already restricted to a pinned client: a bug
/// in the app should not become a root bug.
public enum HelperValidation {

    /// Upper bound on how many addresses one call may pin. A subscription with
    /// thousands of nodes must not be able to turn one call into thousands of
    /// `route` invocations.
    public static let maxAddresses = 64

    /// Strict dotted-quad IPv4. No hostnames, no ranges, no CIDR: the helper
    /// only ever pins single hosts.
    public static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), number <= 255 else { return false }
            // Reject leading zeros: `010` is octal to some resolvers.
            if part.count > 1 && part.first == "0" { return false }
        }
        return true
    }

    public static func isPort(_ value: Int) -> Bool {
        (1...65535).contains(value)
    }

    /// Only the loopback may be named as the SOCKS host: the helper must never
    /// be talked into pointing the tunnel at a remote proxy.
    public static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Validated, de-duplicated and capped address list.
    public static func sanitizeAddresses(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard isIPv4(trimmed), !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
            if result.count == maxAddresses { break }
        }
        return result
    }

    /// Resolvers to hand the system. Same rules as any other address, plus a
    /// small cap — macOS ignores anything past the first few anyway.
    public static func sanitizeResolvers(_ values: [String]) -> [String] {
        Array(sanitizeAddresses(values).prefix(4))
    }
}

/// The command line the helper starts `tun2socks` with.
///
/// It lives here, beside the validation, because getting it wrong is silent:
/// tun2socks answers an unparseable argument by printing its usage and exiting,
/// and all the helper sees is an interface that never appeared.
public enum Tun2socksArguments {

    /// tun2socks 2.7 parses POSIX-style flags, so every long name needs two
    /// dashes — `-device` is read as the shorthand `-d` with the value
    /// `evice`, which starts nothing.
    public static func build(device: String,
                             socksHost: String,
                             socksPort: Int,
                             interface: String) -> [String] {
        [
            "--device", device,
            "--proxy", "socks5://\(socksHost):\(socksPort)",
            "--interface", interface,
        ]
    }
}

/// Vets the routing-core configuration before root runs it.
///
/// The app is already pinned by code signature, so this is not a trust
/// boundary against a stranger — it is a blast radius limit. A bug (or an
/// injected subscription) that reaches the config builder must not be able to
/// turn "start the tunnel" into "read this file as root" or "write that one".
///
/// The rule is simple: nothing in the configuration may name a path on disk.
/// Every path the core needs is one the helper decides and substitutes here.
public enum CoreConfigGuard {

    public enum GuardError: LocalizedError, Equatable {
        case tooLarge(Int)
        case notAnObject
        case unknownSection(String)
        case forbiddenKey(String)
        case localRuleSet
        case remoteController(String)
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                return "Configuration is too large (\(bytes) bytes)"
            case .notAnObject:
                return "Configuration is not a JSON object"
            case .unknownSection(let key):
                return "Configuration has an unsupported top-level section: \(key)"
            case .forbiddenKey(let key):
                return "Configuration names a path the helper will not open: \(key)"
            case .localRuleSet:
                return "Local rule-sets are not allowed in a privileged configuration"
            case .remoteController(let value):
                return "The control API must listen on the loopback, not \(value)"
            case .encodingFailed:
                return "Configuration could not be re-encoded"
            }
        }
    }

    /// A configuration bigger than this is a bug, not a profile.
    public static let maxConfigBytes = 4 * 1024 * 1024

    /// Sections the core is allowed to have. Anything else is refused rather
    /// than passed through, so a new upstream section cannot arrive unnoticed.
    public static let allowedSections: Set<String> = [
        "log", "dns", "inbounds", "outbounds", "endpoints", "route",
        "experimental", "ntp", "certificate"
    ]

    /// Keys whose value is a filesystem path or a download destination. None of
    /// them have a legitimate use in a config the helper runs as root.
    ///
    /// Note what is *not* here: `path` is a transport field (`ws` path, DoH
    /// query path) far more often than a filename, so it is handled where it
    /// actually means a file — `cache_file` and `rule_set` — instead of being
    /// banned outright.
    public static let forbiddenKeys: Set<String> = [
        "certificate_path", "key_path", "ech_key_path",
        "external_ui", "external_ui_download_url", "external_ui_download_detour",
        "command_server"
    ]

    /// Returns the configuration the helper should actually write.
    ///
    /// - Parameters:
    ///   - cachePath: where the core may keep its cache and rule-sets.
    ///   - workingDirectory: the only directory the core is given.
    public static func sanitize(_ data: Data,
                                cachePath: String,
                                workingDirectory: String) throws -> Data {
        guard data.count <= maxConfigBytes else {
            throw GuardError.tooLarge(data.count)
        }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard var config = parsed as? [String: Any] else {
            throw GuardError.notAnObject
        }
        for key in config.keys where !allowedSections.contains(key) {
            throw GuardError.unknownSection(key)
        }
        try reject(config)

        // The core's stdout is already captured into a root-owned log, so it
        // must not also be told to open a file of its own.
        if var log = config["log"] as? [String: Any] {
            log.removeValue(forKey: "output")
            config["log"] = log
        }

        // Rule-sets may be fetched, never read from a path the app chose.
        if var route = config["route"] as? [String: Any],
           let sets = route["rule_set"] as? [[String: Any]] {
            for set in sets where (set["type"] as? String) == "local" {
                throw GuardError.localRuleSet
            }
            route["rule_set"] = sets
            config["route"] = route
        }

        // The cache file is the one path the core legitimately writes, and the
        // helper picks it.
        var experimental = config["experimental"] as? [String: Any] ?? [:]
        if !experimental.isEmpty || config["experimental"] != nil {
            if let api = experimental["clash_api"] as? [String: Any] {
                if let controller = api["external_controller"] as? String,
                   !isLoopbackEndpoint(controller) {
                    throw GuardError.remoteController(controller)
                }
                for key in forbiddenKeys where api[key] != nil {
                    throw GuardError.forbiddenKey(key)
                }
            }
            if var cache = experimental["cache_file"] as? [String: Any] {
                cache["path"] = cachePath
                experimental["cache_file"] = cache
            }
            config["experimental"] = experimental
        }
        _ = workingDirectory

        guard let encoded = try? JSONSerialization.data(withJSONObject: config,
                                                        options: [.sortedKeys]) else {
            throw GuardError.encodingFailed
        }
        return encoded
    }

    /// Walks the whole tree looking for keys that name a file.
    private static func reject(_ value: Any) throws {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                if forbiddenKeys.contains(key) { throw GuardError.forbiddenKey(key) }
                try reject(child)
            }
        } else if let array = value as? [Any] {
            for child in array { try reject(child) }
        }
    }

    /// `127.0.0.1:9090`, `localhost:9090` or `[::1]:9090`.
    public static func isLoopbackEndpoint(_ value: String) -> Bool {
        guard let separator = value.lastIndex(of: ":") else { return false }
        var host = String(value[value.startIndex..<separator])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard let port = Int(value[value.index(after: separator)...]),
              HelperValidation.isPort(port) else { return false }
        return HelperValidation.isLoopback(host)
    }
}
