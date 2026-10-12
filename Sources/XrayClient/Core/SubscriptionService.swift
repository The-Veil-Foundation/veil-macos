import Foundation

/// Refreshes subscription profiles from their URLs.
@MainActor
enum SubscriptionService {

    /// Refresh a single subscription by URL and write results into the store.
    @discardableResult
    static func refresh(_ sub: Subscription, into store: ServerStore) async -> Bool {
        guard let url = sub.url else { return false }

        // A per-subscription toggle wins over the global one; a panel that
        // answered `x-hwid-not-supported` is never asked again.
        let sendHWID = (sub.sendHWID ?? store.settings.sendHwid)
            && sub.hwidStatus != .notSupported
        let hwid = sendHWID ? DeviceID.hwid(for: sub.id) : nil
        let userAgent = sub.userAgentOverride ?? store.settings.userAgentOverride

        do {
            let result = try await SubscriptionFetcher.fetch(url, hwid: hwid,
                                                             userAgent: userAgent)
            if result.metadata.hwidStatus == .notSupported {
                store.mutateSubscription(id: sub.id) { $0.sendHWID = false }
            }
            guard !result.servers.isEmpty else {
                // Keep the last known good node list rather than emptying the
                // group because one refresh came back unusable.
                store.mutateSubscription(id: sub.id) { $0.apply(result.metadata) }
                return false
            }
            let name = result.metadata.profileTitle ?? sub.name
            store.addOrUpdateSubscription(name: name, url: url,
                                          servers: result.servers,
                                          groups: result.payload.groups,
                                          metadata: result.metadata,
                                          format: result.payload.format,
                                          skipped: result.payload.skipped)
            return true
        } catch SubscriptionFetcher.FetchError.maxDevicesReached {
            store.mutateSubscription(id: sub.id) { $0.hwidStatus = .maxDevicesReached }
            return false
        } catch {
            return false
        }
    }

    /// Refresh all subscriptions that have auto-update enabled and are stale.
    /// The panel's own `profile-update-interval` wins over the app setting.
    static func refreshDue(_ store: ServerStore) async {
        guard store.settings.autoUpdateSubscriptions else { return }
        let fallback = store.settings.autoUpdateIntervalHours
        let now = Date()
        for sub in store.subscriptions where sub.autoUpdate && !sub.isManual {
            let interval = sub.refreshInterval(defaultHours: fallback)
            let due = sub.lastUpdated.map { now.timeIntervalSince($0) >= interval } ?? true
            if due { await refresh(sub, into: store) }
        }
    }

    /// Refresh every subscription regardless of staleness (manual "refresh all").
    /// The fetches run side by side, so one slow or dead panel holds the
    /// spinner for its own timeout rather than for everyone's in turn.
    static func refreshAll(_ store: ServerStore) async {
        let tasks = store.subscriptions.filter { !$0.isManual }.map { sub in
            Task { await refresh(sub, into: store) }
        }
        for task in tasks { _ = await task.value }
    }
}
