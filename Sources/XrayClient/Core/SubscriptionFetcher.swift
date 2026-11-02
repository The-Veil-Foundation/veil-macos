import Foundation
import os

/// Fetches a subscription URL and decodes it into servers + panel metadata.
enum SubscriptionFetcher {

    private static let log = Logger(subsystem: "com.veil.client", category: "sub-fetch")

    /// A session that never caches. `URLSession.shared` keeps responses in the
    /// on-disk `URLCache` and serves them back whenever a panel or the CDN in
    /// front of it sends `Cache-Control: max-age` — so "refresh" kept returning
    /// the node list from hours ago, with the hosts the provider had already
    /// moved. The body is also a secret and has no business on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    /// Drops whatever earlier builds left in the shared cache: subscription
    /// bodies fetched through `URLSession.shared`.
    static func purgeLegacyCache() {
        URLCache.shared.removeAllCachedResponses()
    }

    struct Result {
        var payload: SubscriptionPayload
        var metadata: SubscriptionMetadata

        var servers: [ProxyConfig] { payload.servers }
        var userinfo: SubscriptionUserinfo.Info? { metadata.userinfo }
        var profileTitle: String? { metadata.profileTitle }
        var announce: String? { metadata.announce }
    }

    /// Errors a panel can report through the HWID headers. They are surfaced as
    /// errors rather than swallowed, because the user has to do something.
    enum FetchError: LocalizedError {
        case maxDevicesReached
        case httpStatus(Int)
        case undecodableBody

        var errorDescription: String? {
            switch self {
            case .maxDevicesReached:
                return "The panel refused this device: the subscription is at its device limit."
            case .httpStatus(let code):
                return "The subscription server answered with HTTP \(code)."
            case .undecodableBody:
                return "The subscription response was not text."
            }
        }
    }

    /// - Parameters:
    ///   - hwid: identifier to present, or nil to send none.
    ///   - userAgent: override for panels with custom Response Rules.
    static func fetch(_ urlString: String,
                      hwid: String? = nil,
                      userAgent: String? = nil) async throws -> Result {
        guard let url = URL(string: urlString), url.host != nil else {
            throw LinkParseError.malformed(urlString)
        }

        var request = URLRequest(url: url,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 20)
        // Ask every cache on the path — the panel's own and a CDN's — for a
        // fresh copy too.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        // The HWID goes in exactly one place. Putting it in the query string as
        // well would write it into the panel's access log, and putting it in
        // the User-Agent would show it to every proxy on the path.
        request.setValue(DeviceInfo.userAgent(override: userAgent),
                         forHTTPHeaderField: "User-Agent")
        request.setValue(DeviceInfo.osName, forHTTPHeaderField: "X-Device-OS")
        request.setValue(DeviceInfo.osVersion, forHTTPHeaderField: "X-Ver-OS")
        request.setValue(DeviceInfo.model, forHTTPHeaderField: "X-Device-Model")
        if let hwid, !hwid.isEmpty {
            request.setValue(hwid, forHTTPHeaderField: "X-Hwid")
        }

        // Never log the URL itself: its path is the subscription token.
        log.info("""
            subscription fetch host=\(Redaction.url(urlString), privacy: .public) \
            hwid=\(Redaction.fingerprint(hwid), privacy: .public) \
            device=\(DeviceInfo.model, privacy: .public) \
            os=\(DeviceInfo.osName, privacy: .public) \(DeviceInfo.osVersion, privacy: .public)
            """)

        let (data, response) = try await session.data(for: request)

        var metadata = SubscriptionMetadata()
        if let http = response as? HTTPURLResponse {
            metadata = RemnawaveHeaders.parse(http.allHeaderFields)
            if metadata.hwidStatus == .maxDevicesReached {
                throw FetchError.maxDevicesReached
            }
            guard (200..<300).contains(http.statusCode) else {
                throw FetchError.httpStatus(http.statusCode)
            }
        }

        // Panels have been known to send Latin-1 in the node names.
        guard let body = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw FetchError.undecodableBody
        }

        let payload = BalancerGrouper.applied(to: SubscriptionPayloadParser.parse(body))

        log.info("""
            subscription decoded format=\(payload.format.rawValue, privacy: .public) \
            servers=\(payload.servers.count, privacy: .public) \
            groups=\(payload.groups.count, privacy: .public) \
            hwid-status=\(metadata.hwidStatus.rawValue, privacy: .public)
            """)

        return Result(payload: payload, metadata: metadata)
    }

    /// Decode a subscription body that may be base64-wrapped or plain text.
    /// Kept for the "paste a subscription body" path in the add sheet.
    static func decode(_ body: String) -> [ProxyConfig] {
        SubscriptionPayloadParser.parse(body).servers
    }
}
