import Foundation
import Security

/// Thin wrapper over the generic-password keychain.
///
/// Everything that is a credential — subscription URLs (the path segment is the
/// bearer token), per-subscription HWIDs, and any future API token — lives here
/// rather than in `store.json`, so a file copy of Application Support does not
/// hand over the account.
///
/// All of it is kept in **one** keychain item holding a small JSON dictionary,
/// read once per launch and cached in memory. Veil is signed ad hoc, so its
/// code hash changes with every build and every release, and macOS then asks
/// for the keychain password again — with one item that is a single dialog you
/// can answer with "Always Allow", instead of one per subscription per launch.
enum Keychain {

    /// Service under which every Veil item is filed.
    static let service = "com.veil.client"

    /// Account of the item that holds every secret.
    private static let vaultAccount = "vault.v1"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String]?

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var vault = loadLocked()
        guard vault[account] != value else { return true }
        vault[account] = value
        return saveLocked(vault)
    }

    static func get(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()[account]
    }

    @discardableResult
    static func remove(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var vault = loadLocked()
        guard vault.removeValue(forKey: account) != nil else { return true }
        return saveLocked(vault)
    }

    /// True when the keychain is actually usable. An unsigned or sandboxed-away
    /// build can fail every write; callers fall back to file storage rather
    /// than silently dropping the user's subscriptions.
    static var isAvailable: Bool {
        let probe = "__veil_probe__"
        guard set(UUID().uuidString, account: probe) else { return false }
        defer { remove(account: probe) }
        return get(account: probe) != nil
    }

    // MARK: - The vault

    /// Reads the vault once, then serves it from memory. Callers hold `lock`.
    private static func loadLocked() -> [String: String] {
        if let cache { return cache }
        var vault = readItem(account: vaultAccount)
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            ?? [:]
        // Items written by Veil 1.5.1 and earlier were one per secret. Fold them
        // in — each one costs the user at most one more password dialog, once.
        let migrated = drainLegacyItems()
        if !migrated.isEmpty {
            vault.merge(migrated) { current, _ in current }
            cache = vault
            _ = saveLocked(vault)
            return vault
        }
        cache = vault
        return vault
    }

    /// Callers hold `lock`.
    private static func saveLocked(_ vault: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(vault) else { return false }
        cache = vault

        let query = baseQuery(account: vaultAccount)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var add = query
        add[kSecValueData as String] = data
        // The item is only needed while someone is using the Mac, and it must
        // never travel to another device via iCloud Keychain.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrSynchronizable as String] = false
        add[kSecAttrLabel as String] = "Veil"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Reads, then deletes, every pre-vault item of this service.
    private static func drainLegacyItems() -> [String: String] {
        var query = baseQuery(account: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [:] }

        var found: [String: String] = [:]
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != vaultAccount,
                  let data = readItem(account: account),
                  let value = String(data: data, encoding: .utf8) else { continue }
            found[account] = value
            SecItemDelete(baseQuery(account: account) as CFDictionary)
        }
        return found
    }

    private static func readItem(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else {
            return nil
        }
        return item as? Data
    }

    private static func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}

/// Keychain account names used by the app, in one place so nothing collides.
enum KeychainAccount {
    /// The URL of a subscription, keyed by its stable identifier.
    static func subscriptionURL(_ id: UUID) -> String { "sub.url.\(id.uuidString)" }
    /// The HWID Veil presents to one subscription's panel.
    static func subscriptionHWID(_ id: UUID) -> String { "sub.hwid.\(id.uuidString)" }
    /// Bearer token of the old HTTP control API. Only read to delete it.
    static let legacyAPIToken = "api.token"
}
