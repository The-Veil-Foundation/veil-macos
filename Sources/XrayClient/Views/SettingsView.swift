import SwiftUI
import AppKit

/// App settings: tunnel mode, appearance, updates, routing, ports, privacy.
///
/// This is a window of its own rather than a sheet. A sheet is sized by its
/// content and happily grows past the edges of the window it is attached to,
/// which is exactly what a long settings form does; a window is resizable,
/// scrolls, and remembers where it was.
struct SettingsView: View {
    @Environment(ServerStore.self) private var store
    @Environment(ConnectionManager.self) private var connection
    @Environment(UpdateChecker.self) private var updater
    @Environment(PingTester.self) private var pinger
    @Environment(Loc.self) private var loc
    @Environment(\.openWindow) private var openWindow

    // Asking the helper whether it is there is an XPC round trip, so the view
    // starts pessimistic and refreshes off the main thread.
    @State private var helperInstalled = false
    /// Files are in place but the daemon refuses this build: the client is
    /// pinned by code hash, and that hash changes on every app update.
    @State private var helperStale = false
    @State private var helperBusy = false
    @State private var helperError: String?
    @State private var diagnosticsCopied = false
    @State private var hwidCopied = false
    /// The identifier on screen. `DeviceID` is a static store SwiftUI cannot
    /// observe, so the view keeps its own copy and updates it on every change.
    @State private var hwid = DeviceID.hwid
    /// What is typed into the manual field, empty unless it is being edited.
    @State private var hwidDraft = ""

    /// Sections, one per toolbar tab. A single scrolling form of everything is
    /// what made this window taller than the screen in the first place.
    enum Pane: String, CaseIterable, Identifiable {
        case general, tunnel, subscriptions, advanced
        case rules, lists, groups, dns, database

        var id: String { rawValue }

        /// The routing pane this stands for, when it is one. Routing used to
        /// be a window of its own reached from a button in here, which meant
        /// two windows, two tab strips and a settings tab whose only content
        /// was a link to the other window.
        var routing: RoutingSheet.Tab? {
            switch self {
            case .rules:    return .rules
            case .lists:    return .lists
            case .groups:   return .groups
            case .dns:      return .dns
            case .database: return .database
            default:        return nil
            }
        }

        var title: String {
            switch self {
            case .general:       return "General"
            case .tunnel:        return "Tunnel"
            case .subscriptions: return "Subscriptions"
            case .advanced:      return "Advanced"
            case .rules:         return "Rules"
            case .lists:         return "Lists"
            case .groups:        return "Groups"
            case .dns:           return "DNS"
            case .database:      return "Database"
            }
        }

        var icon: String {
            switch self {
            case .general:       return "gearshape"
            case .tunnel:        return "shield.lefthalf.filled"
            case .subscriptions: return "arrow.down.circle"
            case .advanced:      return "wrench.and.screwdriver"
            case .rules:         return "arrow.triangle.branch"
            case .lists:         return "list.bullet.rectangle"
            case .groups:        return "square.stack.3d.up"
            case .dns:           return "globe"
            case .database:      return "externaldrive"
            }
        }

        static let app: [Pane] = [.general, .tunnel, .subscriptions, .advanced]
        static let routingPanes: [Pane] = [.rules, .lists, .groups, .dns, .database]
    }

    @State private var pane: Pane = .general

    var body: some View {
        // A sidebar rather than a strip of tabs: nine panes do not fit on a
        // titlebar, and the routing ones used to live in a second window
        // reached by a button, which is one window and one tab strip more than
        // the settings of one app need.
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    ForEach(Pane.app) { item in row(item) }
                }
                Section(loc("Routing")) {
                    ForEach(Pane.routingPanes) { item in row(item) }
                }
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 220)
        } detail: {
            detail
                .navigationTitle(loc(pane.title))
        }
        .frame(minWidth: 740, idealWidth: 860,
               minHeight: 460, idealHeight: 660)
        .windowTitle(loc("Settings"))
        .onAppear(perform: restorePane)
        .task { await refreshHelperStatus() }
    }

    private func row(_ item: Pane) -> some View {
        Label(loc(item.title), systemImage: item.icon).tag(item)
    }

    /// Opening the settings from a group's row should land on the groups. The
    /// pane is remembered in the same setting the routing window used.
    private func restorePane() {
        guard let stored = RoutingSheet.Tab(rawValue: store.settings.lastRoutingTab),
              let match = Pane.routingPanes.first(where: { $0.routing == stored })
        else { return }
        pane = match
        store.settings.lastRoutingTab = RoutingSheet.Tab.rules.rawValue
        store.save()
    }

    @ViewBuilder
    private var detail: some View {
        if let routing = pane.routing {
            RoutingSheet(pane: routing)
        } else {
            Form {
                switch pane {
                case .general:       generalSections
                case .tunnel:        tunnelSections
                case .subscriptions: subscriptionSections
                default:             advancedSections
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalSections: some View {
        @Bindable var store = store
        @Bindable var updater = updater

        Section(loc("Appearance")) {
            Picker(loc("Theme"), selection: $store.settings.appearance) {
                ForEach(AppAppearance.allCases) { a in Text(loc(a.title)).tag(a) }
            }
            .onChange(of: store.settings.appearance) { _, _ in store.save() }

            Picker(loc("Language"), selection: $store.settings.language) {
                ForEach(AppLanguage.allCases) { l in
                    Text(l == .system ? loc("System") : l.displayName).tag(l)
                }
            }
            .onChange(of: store.settings.language) { _, newLang in
                loc.language = newLang; store.save()
            }
        }

        Section(loc("Server list")) {
            Toggle(isOn: $store.settings.autoTags) {
                HintLabel(loc("Tag servers from their names"), loc("Reads the country, the protocol and words a provider uses — Premium, Trial, Game — out of each node's name and shows them as tags beside the ones you attach yourself. They also filter and group. Off by default, because they are guesses about someone else's naming."))
            }
            .onChange(of: store.settings.autoTags) { _, _ in store.save() }

            Toggle(isOn: $store.settings.showSourcesTab) {
                HintLabel(loc("Show the Sources tab"), loc("The page that says where the servers came from, what each source returned and what it could not use. Hide it once your subscriptions are set up; everything on it stays available here."))
            }
            .onChange(of: store.settings.showSourcesTab) { _, _ in store.save() }
        }

        Section(loc("Ping")) {
            Picker(selection: $store.settings.pingMode) {
                ForEach(PingMode.allCases) { mode in Text(loc(mode.title)).tag(mode) }
            } label: {
                HintLabel(loc("Ping mode"), loc("TCP and ICMP time the way to the server itself. Proxy HEAD and Proxy GET send a request through the server and time the answer, which also catches a node that accepts connections but carries nothing."))
            }
            .onChange(of: store.settings.pingMode) { _, mode in
                pinger.mode = mode
                pinger.clear()
                store.save()
            }
            Text(loc(store.settings.pingMode.detail))
                .font(.caption).foregroundStyle(.secondary)
            if store.settings.pingMode.usesProxy {
                TextField(loc("Test URL"), text: $store.settings.pingURL,
                          prompt: Text(verbatim: PingMode.defaultURL))
                    .onSubmit {
                        pinger.probeURL = store.settings.effectivePingURL
                        store.save()
                    }
                    .onChange(of: store.settings.pingURL) { _, _ in
                        pinger.probeURL = store.settings.effectivePingURL
                        store.save()
                    }
            }
        }

        Section(loc("Window")) {
            Toggle(loc("Close button hides to menu bar"), isOn: $store.settings.closeToTray)
                .onChange(of: store.settings.closeToTray) { _, _ in store.save() }
            Toggle(isOn: $store.settings.hideDockIcon) {
                HintLabel(loc("Hide the Dock icon"), loc("Runs Veil from the menu bar alone: no Dock tile, no ⌘-Tab entry, no menus at the top of the screen. The window stays reachable through Open Window in the menu bar item, and the app keeps running when you close it."))
            }
            .onChange(of: store.settings.hideDockIcon) { _, on in
                DockIcon.setHidden(on)
                (NSApp.delegate as? AppDelegate)?.dockHidden = on
                store.save()
            }
            Toggle(loc("Launch at login"), isOn: $store.settings.launchAtLogin)
                .onChange(of: store.settings.launchAtLogin) { _, on in
                    LoginItem.setEnabled(on); store.save()
                }
            Toggle(loc("Auto-connect on launch"), isOn: $store.settings.autoConnectOnLaunch)
                .onChange(of: store.settings.autoConnectOnLaunch) { _, _ in store.save() }
            Toggle(loc("Notify on connect / disconnect"), isOn: $store.settings.notifyOnConnect)
                .onChange(of: store.settings.notifyOnConnect) { _, on in
                    connection.notifyOnConnect = on
                    if on { NotificationManager.requestAuthorization() }
                    store.save()
                }
        }

        Section {
            Toggle(loc("Check for updates automatically"),
                   isOn: $updater.automaticallyChecks)
            Toggle(loc("Download and install them without asking"),
                   isOn: $updater.automaticallyInstalls)
                .disabled(!updater.automaticallyChecks)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "Veil \(AppVersion.current)")
                    if let last = updater.lastCheck {
                        Text(verbatim: "\(loc("Last checked")) \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(loc("Check Now")) {
                    Task {
                        await UpdateAlert.runUserCheck(updater, loc: loc) {
                            openWindow(id: WindowID.update)
                        }
                    }
                }
                .glassButton()
            }
        } header: {
            Text(loc("Updates"))
        } footer: {
            Text(loc("Updates come from the project's GitHub releases."))
                .font(.caption2)
        }
    }

    // MARK: - Tunnel

    @ViewBuilder
    private var tunnelSections: some View {
        @Bindable var store = store

        Section(loc("Mode")) {
            Picker(selection: $store.settings.mode) {
                ForEach(TunnelMode.allCases) { m in Text(loc(m.title)).tag(m) }
            } label: {
                HintLabel(loc("Mode"), loc("System Proxy points macOS at Veil's local ports, so only apps that read the system proxy are routed — Telegram, the terminal and anything over UDP are not. TUN takes over a network interface instead, and everything on this Mac goes through it."))
            }
            .onChange(of: store.settings.mode) { _, m in
                connection.mode = m; store.save()
            }
            Text(loc(store.settings.mode.subtitle))
                .font(.caption).foregroundStyle(.secondary)
        }

        if store.settings.mode == .tun {
            Section(loc("TUN")) {
                Toggle(loc("Let the core own the interface"),
                       isOn: $store.settings.useNativeTun)
                    .onChange(of: store.settings.useNativeTun) { _, _ in store.save() }
                Text(loc("sing-box handles the tunnel itself, which is what lets a rule match an application. Turn this off to fall back to tun2socks."))
                    .font(.caption).foregroundStyle(.secondary)

                if store.settings.useNativeTun {
                    Toggle(loc("Strict route"), isOn: $store.settings.tunStrictRoute)
                        .onChange(of: store.settings.tunStrictRoute) { _, _ in store.save() }
                    Text(loc("Stops traffic from leaving around the tunnel. Can break local network access."))
                        .font(.caption2).foregroundStyle(.secondary)
                    Picker(selection: $store.settings.tunStack) {
                        Text(loc("Automatic")).tag("")
                        Text(verbatim: "system").tag("system")
                        Text(verbatim: "gvisor").tag("gvisor")
                        Text(verbatim: "mixed").tag("mixed")
                    } label: {
                        HintLabel(loc("Stack"), loc("How the tunnel moves packets. Leave this automatic: sing-box's mixed stack has killed every TCP connection here while the app still reported a healthy tunnel."))
                    }
                    .onChange(of: store.settings.tunStack) { _, _ in store.save() }
                }
            }
        }

        Section {
            HStack {
                Image(systemName: helperInstalled ? "checkmark.shield.fill"
                      : (helperStale ? "exclamationmark.shield.fill" : "shield.slash"))
                    .foregroundStyle(helperInstalled ? .green
                                     : (helperStale ? .orange : .secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(helperInstalled ? loc("Helper installed")
                         : (helperStale ? loc("Helper needs reinstalling")
                            : loc("Helper not installed")))
                    Text(helperInstalled
                         ? loc("TUN switches servers without asking for a password.")
                         : (helperStale
                            ? loc("The installed helper was pinned to an older build of Veil and refuses this one, so TUN cannot start.")
                            : loc("Install once to stop password prompts on every switch.")))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if helperBusy {
                    ProgressView().controlSize(.small)
                } else if helperInstalled {
                    Button(loc("Remove")) {
                        runHelperTask { TunManager.uninstallHelper() }
                    }
                    .glassButton().tint(.red)
                } else {
                    Button(helperStale ? loc("Reinstall") : loc("Install")) {
                        runHelperTask { try TunManager.installHelper() }
                    }
                    .glassProminentButton()
                }
            }
            // An install can fail for reasons the user can act on — a
            // cancelled password prompt, an unsigned bundle — so say so
            // instead of leaving the button looking inert.
            if let helperError {
                Text(helperError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } header: {
            Text(loc("TUN helper"))
        }

        Section(loc("Ports")) {
            LabeledContent {
                TextField("", value: $store.settings.socksPort, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            } label: {
                HintLabel(loc("SOCKS port"), loc("The port the core listens on. Change it only if another program on this Mac already holds it."))
            }
            LabeledContent {
                TextField("", value: $store.settings.httpPort, format: .number.grouping(.never))
                    .frame(width: 80).multilineTextAlignment(.trailing)
            } label: {
                HintLabel(loc("HTTP port"), loc("The port proxy-aware apps are pointed at in System Proxy mode."))
            }
            Picker(selection: $store.settings.logLevel) {
                ForEach(LogLevel.allCases) { l in Text(loc(l.title)).tag(l) }
            } label: {
                HintLabel(loc("Log level"), loc("How much the core writes to the log. Debug is for chasing a problem and is very noisy; warning is enough day to day."))
            }
            .onChange(of: store.settings.logLevel) { _, l in
                connection.logLevel = l; store.save()
            }
        }
        .onChange(of: store.settings.socksPort) { _, p in
            connection.ports.socks = p; store.save()
        }
        .onChange(of: store.settings.httpPort) { _, p in
            connection.ports.http = p; store.save()
        }
    }

    // MARK: - Routing

    // MARK: - Subscriptions

    @ViewBuilder
    private var subscriptionSections: some View {
        @Bindable var store = store

        Section(loc("Updates")) {
            Toggle(isOn: $store.settings.autoUpdateSubscriptions) {
                HintLabel(loc("Auto-update subscriptions"), loc("Re-downloads every source on a timer, so nodes your provider adds or drops appear without you pressing anything."))
            }
                .onChange(of: store.settings.autoUpdateSubscriptions) { _, _ in store.save() }
            // Hidden rather than disabled: with the toggle off the interval
            // governs nothing, and a greyed row still reads as a setting.
            if store.settings.autoUpdateSubscriptions {
                Picker(loc("Check every"), selection: $store.settings.autoUpdateIntervalHours) {
                    ForEach(AppSettings.autoUpdateIntervalChoices(
                        including: store.settings.autoUpdateIntervalHours), id: \.self) { hours in
                        Text(verbatim: "\(hours) \(loc("h"))").tag(hours)
                    }
                }
                .onChange(of: store.settings.autoUpdateIntervalHours) { _, _ in store.save() }
            }
        }

        Section {
            Toggle(loc("Send HWID with subscription requests"), isOn: $store.settings.sendHwid)
                .onChange(of: store.settings.sendHwid) { _, _ in store.save() }
            Text(loc("Identifies this device to providers that require it."))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("Device ID"))
                    // Held in state rather than read from `DeviceID` on every
                    // draw: that is a static store SwiftUI cannot observe, so
                    // a rotated ID used to stay on screen until some unrelated
                    // change happened to redraw the row.
                    Text(verbatim: hwid)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(hwidCopied ? loc("Copied") : loc("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hwid, forType: .string)
                    hwidCopied = true
                }
                .glassButton()
                Button(loc("Regenerate")) {
                    hwid = DeviceID.regenerate()
                    hwidDraft = ""
                    hwidCopied = false
                }
                .glassButton()
            }
            Text(loc("A new ID looks like a new device to your provider and may use up a device slot."))
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                TextField(loc("Set the ID by hand"), text: $hwidDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit { applyManualHwid() }
                Button(loc("Apply")) { applyManualHwid() }
                    .glassButton()
                    .disabled(DeviceID.normalizedManual(hwidDraft) == nil)
            }
            Text(loc("Use the ID your provider issued. Stored exactly as typed."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(loc("Device"))
        }

        Section {
            TextField(loc("User-Agent (optional)"),
                      text: $store.settings.userAgentOverride)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.save() }
            Text(verbatim: "\(loc("Sent as")): \(DeviceInfo.userAgent(override: store.settings.userAgentOverride))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(loc("Leave empty unless your provider's rules expect a particular client."))
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text(loc("Identification"))
        }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSections: some View {
        ControlAPISection()

        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("Export diagnostics"))
                    Text(loc("Copies a report with subscription URLs, tokens and IDs removed."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(diagnosticsCopied ? loc("Copied") : loc("Copy")) {
                    let report = Diagnostics.report(store: store,
                                                    logText: connection.logs)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    diagnosticsCopied = true
                }
                .glassButton()
            }
        } header: {
            Text(loc("Privacy"))
        }
    }

    // MARK: - Helper plumbing

    /// Adopts whatever is in the manual field, then clears it. A blank field
    /// is not an identifier, so the button is disabled and this does nothing.
    private func applyManualHwid() {
        guard let applied = DeviceID.setManual(hwidDraft) else { return }
        hwid = applied
        hwidDraft = ""
        hwidCopied = false
    }

    /// Runs an install or removal off the main thread — both wait on the admin
    /// prompt and on an XPC round trip, and neither may freeze the window.
    private func runHelperTask(_ work: @escaping @Sendable () throws -> Void) {
        helperBusy = true
        helperError = nil
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do { try work() } catch { failure = error.localizedDescription }
            let installed = TunManager.isHelperInstalled
            let stale = !installed && PrivilegedHelper.isInstalled
            await MainActor.run {
                helperError = failure
                helperInstalled = installed
                helperStale = stale
                helperBusy = false
            }
        }
    }

    private func refreshHelperStatus() async {
        let status = await Task.detached(priority: .utility) {
            let ready = TunManager.isHelperInstalled
            return (ready: ready, stale: !ready && PrivilegedHelper.isInstalled)
        }.value
        helperInstalled = status.ready
        helperStale = status.stale
    }
}
