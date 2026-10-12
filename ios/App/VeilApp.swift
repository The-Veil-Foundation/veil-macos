import SwiftUI

@main
struct VeilApp: App {
    @State private var store = ServerStore()
    @State private var tunnel = TunnelController()
    @State private var pinger = PingTester()
    @State private var loc = Loc()
    @State private var backdrop = MenuBackdrop()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(tunnel)
                .environment(pinger)
                .environment(loc)
                .environment(backdrop)
                .preferredColorScheme(colorScheme)
                .environment(\.layoutDirection, loc.isRTL ? .rightToLeft : .leftToRight)
                .task { await bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // iOS gives an app no background timer worth having, so the
                    // sources are brought up to date whenever it comes forward.
                    // A menu cannot outlive the app leaving the screen; never
                    // come back to a blurred window.
                    if phase != .active { backdrop.reset() }
                    guard phase == .active else { return }
                    Task { await refreshInBackground() }
                }
        }
    }

    private func bootstrap() async {
        loc.language = store.settings.language
        tunnel.notifyOnConnect = store.settings.notifyOnConnect
        TunnelController.lastActiveID = store.selectedServerID
        // The app no longer hides servers; one hidden by an earlier build
        // would otherwise stay out of every group with no switch to undo it.
        for (id, note) in store.settings.nodeAnnotations where note.hidden {
            store.setHidden(false, serverID: id)
        }
        if store.settings.notifyOnConnect {
            NotificationManager.requestAuthorization()
        }

        await tunnel.loadManager()
        await refreshInBackground()

        if store.settings.autoConnectOnLaunch, !tunnel.isConnected,
           let id = store.selectedServerID, store.server(withID: id) != nil {
            await tunnel.connect(to: id, store: store)
        }
    }

    private func refreshInBackground() async {
        await SubscriptionService.refreshDue(store)
        await CommunityListManager.shared.refreshDue(store.settings)
        // Geo databases only matter when something names geosite:/geoip:.
        if store.routingNeedsGeoAssets, !GeoAssetManager.shared.hasAssets,
           !GeoAssetManager.shared.isDownloading {
            await GeoAssetManager.shared.download(source: store.settings.geoSource,
                                                  customGeoip: store.settings.customGeoipURL,
                                                  customGeosite: store.settings.customGeositeURL)
        }
    }

    private var colorScheme: ColorScheme? {
        switch store.settings.appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// The four places the app has: what to connect through, where it comes from,
/// where traffic goes, and how the app behaves.
struct RootView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(MenuBackdrop.self) private var backdrop

    enum Tab: Hashable { case servers, sources, routing, settings }
    @State private var tab: Tab = .servers

    var body: some View {
        TabView(selection: $tab) {
            ContentView()
                .tabItem { Label(loc("Servers"), systemImage: "server.rack") }
                .tag(Tab.servers)
            if store.settings.showSourcesTab {
                SourcesView()
                    .tabItem { Label(loc("Sources"), systemImage: "square.stack.3d.up") }
                    .tag(Tab.sources)
            }
            RoutingView()
                .tabItem { Label(loc("Routing"), systemImage: "arrow.triangle.branch") }
                .tag(Tab.routing)
            SettingsView()
                .tabItem { Label(loc("Settings"), systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // The menu and its preview live above this view, so they stay sharp.
        .blur(radius: backdrop.isOpen ? 24 : 0, opaque: true)
        .animation(.easeOut(duration: 0.25), value: backdrop.isOpen)
    }
}
