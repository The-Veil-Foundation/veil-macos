import SwiftUI
import AppKit

@main
struct XrayClientApp: App {
    @State private var store = ServerStore()
    @State private var connection = ConnectionManager()
    @State private var pinger = PingTester()
    @State private var loc = Loc()
    @State private var control = ControlServer()
    @State private var updater = UpdateChecker()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Startup needs to be able to raise the update window when the previous
    /// install left a failure behind.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Veil", id: WindowID.main) {
            ContentView()
                .veilEnvironment(store: store, connection: connection,
                                 pinger: pinger, loc: loc, control: control,
                                 updater: updater)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { startUp() }
        }
        .windowResizability(.contentSize)
        .commands {
            VeilCommands(loc: loc, updater: updater, store: store)
        }

        // Settings is a window of its own rather than a sheet: a long form no
        // longer hangs off the edges of a main window the user made small.
        //
        // It is a `Window` and not the `Settings` scene because that scene
        // insists on a title row of its own above the toolbar, which pushed the
        // tab switcher onto a second line. ⌘, is wired up in `VeilCommands`.
        Window(loc("Settings"), id: WindowID.settings) {
            SettingsView()
                .veilEnvironment(store: store, connection: connection,
                                 pinger: pinger, loc: loc, control: control,
                                 updater: updater)
        }
        .defaultSize(width: 620, height: 640)

        Window(loc("About Veil"), id: WindowID.about) {
            AboutWindow()
                .veilEnvironment(store: store, connection: connection,
                                 pinger: pinger, loc: loc, control: control,
                                 updater: updater)
        }
        .windowResizability(.contentSize)

        Window(loc("Software Update"), id: WindowID.update) {
            UpdateWindow()
                .veilEnvironment(store: store, connection: connection,
                                 pinger: pinger, loc: loc, control: control,
                                 updater: updater)
        }
        .windowResizability(.contentSize)

        // Menu bar control: switch servers / disconnect without opening the window.
        MenuBarExtra {
            MenuBarContent()
                .environment(store)
                .environment(connection)
                .environment(loc)
        } label: {
            Image(systemName: connection.isConnected ? "shield.lefthalf.filled" : "shield.slash")
        }
        .menuBarExtraStyle(.menu)
    }

    /// Everything that has to happen once, when the main window first appears.
    ///
    /// `onAppear` fires again every time the window is reopened from the menu
    /// bar. Running all of this a second time tore the live TUN core down (the
    /// crash cleanup below cannot tell a leftover tunnel from the current one),
    /// reconnected on top of a working connection and re-registered the login
    /// item — so the guard is not an optimisation.
    private func startUp() {
        guard !appDelegate.didStartUp else { return }
        appDelegate.didStartUp = true
        loc.language = store.settings.language
        connection.bind(store)
        control.onLog = { [weak connection] line in
            connection?.appendLog(line)
        }
        control.sync(settings: store.settings, store: store, connection: connection)
        appDelegate.closeToTray = store.settings.closeToTray
        appDelegate.dockHidden = store.settings.hideDockIcon
        DockIcon.setHidden(store.settings.hideDockIcon)
        appDelegate.connection = connection
        // Keep the login-item registration in sync with the setting.
        LoginItem.setEnabled(store.settings.launchAtLogin)
        if store.settings.notifyOnConnect {
            NotificationManager.requestAuthorization()
        }
        // Recover from a previous crash/force-quit that left the tunnel routes
        // in place (which kills internet). Three XPC round trips, so off the
        // main thread — and auto-connect waits for it, or the cleanup could
        // tear down the tunnel it had just brought up.
        let autoConnectID = store.settings.autoConnectOnLaunch ? store.selectedServerID : nil
        Task {
            await ConnectionManager.onTransport { TunManager.emergencyCleanup() }
            if let server = store.server(withID: autoConnectID), !connection.isConnected {
                connection.connect(to: server)
            }
        }
        Task { await SubscriptionService.refreshDue(store) }
        // Warm the process catalog so the control API's /v1/apps has data
        // before the picker is ever opened.
        Task { await ProcessCatalog.shared.reload() }
        // Auto-download geo .dat files if the active preset needs them and
        // they're missing (first launch).
        if store.settings.routingPreset.needsGeoAssets,
           !GeoAssetManager.shared.hasAssets {
            Task {
                await GeoAssetManager.shared.download(
                    source: store.settings.geoSource,
                    customGeoip: store.settings.customGeoipURL,
                    customGeosite: store.settings.customGeositeURL)
            }
        }
        // Keep the community rule lists fresh in the background.
        Task { await CommunityListManager.shared.refreshDue(store.settings) }
        // An install runs after this process is gone, so a failed one can only
        // be reported by the launch that follows it. Checked before the next
        // check is scheduled, which would otherwise offer the same update
        // again with no hint of why the last attempt did nothing.
        if updater.reportPreviousInstall() {
            openWindow(id: WindowID.update)
        } else {
            updater.checkInBackgroundIfDue()
        }
        scheduleBackgroundRefresh()
    }

    /// Keeps subscriptions, community lists and the update check fresh while
    /// the app sits in the menu bar for days.
    ///
    /// They used to be checked only at launch — and, by accident, whenever the
    /// window was reopened. The system scheduler picks the moment itself, so
    /// the work lands alongside other wake-ups instead of adding its own.
    private func scheduleBackgroundRefresh() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.local.veil.refresh")
        scheduler.repeats = true
        scheduler.interval = 60 * 60
        scheduler.tolerance = 15 * 60
        scheduler.qualityOfService = .utility
        let store = store
        let updater = updater
        scheduler.schedule { completion in
            let done = SchedulerCompletion(completion)
            Task { @MainActor in
                await SubscriptionService.refreshDue(store)
                await CommunityListManager.shared.refreshDue(store.settings)
                updater.checkInBackgroundIfDue()
                done.finish()
            }
        }
        appDelegate.refreshScheduler = scheduler
    }
}

/// Carries the scheduler's completion handler across to the main actor.
private final class SchedulerCompletion: @unchecked Sendable {
    private let handler: NSBackgroundActivityScheduler.CompletionHandler
    init(_ handler: @escaping NSBackgroundActivityScheduler.CompletionHandler) {
        self.handler = handler
    }
    func finish() { handler(.finished) }
}

/// Injects the app-wide observable objects and the appearance/writing-direction
/// settings every window needs, so a new window is one modifier away from
/// behaving like the main one.
private struct VeilEnvironment: ViewModifier {
    let store: ServerStore
    let connection: ConnectionManager
    let pinger: PingTester
    let loc: Loc
    let control: ControlServer
    let updater: UpdateChecker

    func body(content: Content) -> some View {
        content
            .environment(store)
            .environment(connection)
            .environment(pinger)
            .environment(loc)
            .environment(control)
            .environment(updater)
            .preferredColorScheme(colorScheme)
            .environment(\.layoutDirection, loc.isRTL ? .rightToLeft : .leftToRight)
    }

    private var colorScheme: ColorScheme? {
        switch store.settings.appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

extension View {
    func veilEnvironment(store: ServerStore, connection: ConnectionManager,
                         pinger: PingTester, loc: Loc, control: ControlServer,
                         updater: UpdateChecker) -> some View {
        modifier(VeilEnvironment(store: store, connection: connection,
                                 pinger: pinger, loc: loc, control: control,
                                 updater: updater))
    }
}

/// The application menu: About, Check for Updates, Settings.
///
/// The standard About panel is replaced so the version, the build and the
/// project links sit together; everything else in the menu is AppKit's own.
private struct VeilCommands: Commands {
    let loc: Loc
    let updater: UpdateChecker
    let store: ServerStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(loc("Settings…")) { openWindow(id: WindowID.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .appInfo) {
            Button(loc("About Veil")) { openWindow(id: WindowID.about) }
            Button(loc("Check for Updates…")) {
                Task {
                    await UpdateAlert.runUserCheck(updater, loc: loc) {
                        openWindow(id: WindowID.update)
                    }
                }
            }
        }
        CommandGroup(after: .toolbar) {
            // Routing is a set of panes in Settings now, not a window of its
            // own; the shortcut opens it there.
            Button(loc("Routing…")) {
                store.settings.lastRoutingTab = RoutingSheet.Tab.rules.rawValue
                store.save()
                openWindow(id: WindowID.settings)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

/// Handles "close to tray" and clean shutdown of the tunnel on quit so the
/// network is never left routed through a dead tun2socks.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var closeToTray = true
    /// Mirrors `AppSettings.hideDockIcon`. With no Dock tile the menu bar is
    /// the only way back in, so quitting on the last closed window would leave
    /// the user with a tunnel they cannot reach — stay alive regardless of
    /// close-to-tray.
    var dockHidden = false
    weak var connection: ConnectionManager?
    /// Set once the first window has run the start-up work.
    var didStartUp = false
    var refreshScheduler: NSBackgroundActivityScheduler?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar when close-to-tray is enabled.
        return !(closeToTray || dockHidden)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Always restore routes/proxy on quit, even if the user force-quits the
        // window, so the machine isn't left without internet.
        connection?.disconnect()
        // Teardown is queued off the main thread; it has to finish before the
        // process does, or the machine is left pointing at a dead proxy.
        ConnectionManager.waitForTransport()
        // Belt-and-suspenders: ensure any orphaned tunnel is torn down.
        TunManager.emergencyCleanup()
    }
}
