import SwiftUI

struct SettingsView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(Loc.self) private var loc

    @State private var dnsText = ""
    @State private var showRemoveConfirm = false
    @State private var showRegenerateConfirm = false
    /// Held in state rather than read from `DeviceID` on every draw: that is
    /// a static store SwiftUI cannot observe, so a rotated ID would stay on
    /// screen until some unrelated change redrew the row.
    @State private var hwid = DeviceID.hwid
    @State private var hwidDraft = ""
    @State private var copied: String?
    @State private var report: String?

    private static let repository = "faustyu1/veil"

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                if tunnel.hasUnappliedChanges(store: store) {
                    Section {
                        Button {
                            Task { await tunnel.applyChanges(store: store) }
                        } label: {
                            Label(loc("Apply now"), systemImage: "arrow.clockwise.circle")
                        }
                    } footer: {
                        Text(loc("Changes apply on the next connect or reconnect."))
                    }
                }

                appearanceSection
                tunnelSection
                startupSection
                subscriptionSection
                deviceSection
                profileSection
                privacySection
                aboutSection
            }
            .navigationTitle(loc("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                dnsText = store.settings.effectiveDNSServers.joined(separator: ", ")
                hwid = DeviceID.hwid
            }
            .onDisappear {
                commitDNS()
                store.save()
            }
            .confirmationDialog(loc("Remove VPN profile?"),
                                isPresented: $showRemoveConfirm, titleVisibility: .visible) {
                Button(loc("Remove"), role: .destructive) {
                    Task { await tunnel.removeProfile() }
                }
                Button(loc("Cancel"), role: .cancel) {}
            }
            .confirmationDialog(loc("Regenerate"),
                                isPresented: $showRegenerateConfirm, titleVisibility: .visible) {
                Button(loc("Regenerate"), role: .destructive) {
                    hwid = DeviceID.regenerate()
                    hwidDraft = ""
                }
                Button(loc("Cancel"), role: .cancel) {}
            } message: {
                Text(loc("A new ID looks like a new device to your provider and may use up a device slot."))
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var appearanceSection: some View {
        @Bindable var store = store
        Section(loc("Appearance")) {
            Picker(loc("Theme"), selection: $store.settings.appearance) {
                ForEach(AppAppearance.allCases) { Text(loc($0.title)).tag($0) }
            }
            .onChange(of: store.settings.appearance) { _, _ in store.save() }
            Picker(loc("Language"), selection: $store.settings.language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            }
            .onChange(of: store.settings.language) { _, language in
                loc.language = language
                store.save()
            }
        }

        Section(loc("Server list")) {
            Toggle(isOn: $store.settings.autoTags) {
                HintLabel(loc("Tag servers from their names"),
                          loc("Reads the country, the protocol and words a provider uses — Premium, Trial, Game — out of each node's name and shows them as tags beside the ones you attach yourself. They also filter and group. Off by default, because they are guesses about someone else's naming."))
            }
            .onChange(of: store.settings.autoTags) { _, _ in store.save() }
            Toggle(isOn: $store.settings.showSourcesTab) {
                HintLabel(loc("Show the Sources tab"),
                          loc("The page that says where the servers came from, what each source returned and what it could not use. Hide it once your subscriptions are set up; everything on it stays available here."))
            }
            .onChange(of: store.settings.showSourcesTab) { _, _ in store.save() }
        }
    }

    @ViewBuilder
    private var tunnelSection: some View {
        @Bindable var store = store
        Section {
            // No mode picker: iOS has exactly one way to capture traffic, and
            // it is the one this app uses.
            LabeledContent(loc("Mode"), value: loc("Network Extension (all apps)"))
            Picker(selection: $store.settings.logLevel) {
                ForEach(LogLevel.allCases) { Text(loc($0.title)).tag($0) }
            } label: {
                HintLabel(loc("Log level"), loc("How much the core writes to the log. Debug is for chasing a problem and is very noisy; warning is enough day to day."))
            }
            Toggle(loc("IPv6 inside tunnel"), isOn: $store.settings.ipv6Enabled)
            Stepper(value: $store.settings.tunnelMTU, in: 1280...1500, step: 20) {
                LabeledContent { Text(verbatim: "\(store.settings.tunnelMTU)") } label: { Text(verbatim: "MTU") }
            }
            LabeledContent(loc("System DNS")) {
                TextField("1.1.1.1, 8.8.8.8", text: $dnsText)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    .onSubmit(commitDNS)
            }
        } header: {
            Text(loc("Tunnel"))
        } footer: {
            Text(loc("The addresses iOS sends its lookups to. The core answers them with the resolver set in Routing › DNS."))
        }
    }

    @ViewBuilder
    private var startupSection: some View {
        @Bindable var store = store
        Section(loc("Startup")) {
            Toggle(loc("Auto-connect on launch"), isOn: $store.settings.autoConnectOnLaunch)
                .onChange(of: store.settings.autoConnectOnLaunch) { _, _ in store.save() }
            Toggle(loc("Notify on connect / disconnect"), isOn: $store.settings.notifyOnConnect)
                .onChange(of: store.settings.notifyOnConnect) { _, on in
                    tunnel.notifyOnConnect = on
                    if on { NotificationManager.requestAuthorization() }
                    store.save()
                }
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        @Bindable var store = store
        Section {
            Toggle(isOn: $store.settings.autoUpdateSubscriptions) {
                HintLabel(loc("Auto-update subscriptions"),
                          loc("Re-downloads every source on a timer, so nodes your provider adds or drops appear without you pressing anything."))
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
            TextField(loc("User-Agent (optional)"), text: $store.settings.userAgentOverride)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { store.save() }
            Text(verbatim: "\(loc("Sent as")): \(DeviceInfo.userAgent(override: store.settings.userAgentOverride))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } header: {
            Text(loc("Subscriptions"))
        } footer: {
            Text(loc("Leave empty unless your provider's rules expect a particular client."))
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        @Bindable var store = store
        Section {
            Toggle(loc("Send HWID with subscription requests"), isOn: $store.settings.sendHwid)
                .onChange(of: store.settings.sendHwid) { _, _ in store.save() }
            VStack(alignment: .leading, spacing: 2) {
                Text(loc("Device ID"))
                Text(verbatim: hwid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button(copied == "hwid" ? loc("Copied") : loc("Copy"), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = hwid
                copied = "hwid"
            }
            Button(loc("Regenerate"), systemImage: "arrow.triangle.2.circlepath") {
                showRegenerateConfirm = true
            }
            HStack {
                TextField(loc("Set the ID by hand"), text: $hwidDraft)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(applyManualHwid)
                Button(loc("Apply"), action: applyManualHwid)
                    .disabled(DeviceID.normalizedManual(hwidDraft) == nil)
            }
        } header: {
            Text(loc("Device"))
        } footer: {
            Text(loc("Identifies this device to providers that require it.")
                 + " " + loc("Use the ID your provider issued. Stored exactly as typed."))
        }
    }

    @ViewBuilder
    private var profileSection: some View {
        Section {
            LabeledContent(loc("Status"),
                           value: tunnel.isInstalled ? loc("Installed") : loc("Not installed"))
            if tunnel.isInstalled {
                Button(loc("Remove VPN profile"), role: .destructive) {
                    showRemoveConfirm = true
                }
            }
        } header: {
            Text(loc("VPN profile"))
        } footer: {
            Text(loc("iOS asks you to allow the VPN configuration the first time you connect."))
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            // Built on request: redacting every credential out of the report
            // is not something to do on every redraw of this screen.
            if let report {
                ShareLink(item: report) {
                    Label(loc("Share"), systemImage: "square.and.arrow.up")
                }
                Button(copied == "diag" ? loc("Copied") : loc("Copy"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = report
                    copied = "diag"
                }
            } else {
                Button(loc("Export diagnostics"), systemImage: "stethoscope") {
                    report = Diagnostics.report(store: store, logText: tunnel.logs)
                }
            }
        } header: {
            Text(loc("Privacy"))
        } footer: {
            Text(loc("Copies a report with subscription URLs, tokens and IDs removed."))
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section(loc("About")) {
            LabeledContent(loc("App version"), value: appVersion)
            LabeledContent(loc("Xray core"),
                           value: tunnel.coreVersion.isEmpty ? "—" : tunnel.coreVersion)
            Link(loc("GitHub"), destination: URL(string: "https://github.com/\(Self.repository)")!)
            Link(loc("Changelog"),
                 destination: URL(string: "https://github.com/\(Self.repository)/blob/main/CHANGELOG.md")!)
            Link(loc("Report an issue"),
                 destination: URL(string: "https://github.com/\(Self.repository)/issues")!)
        }
    }

    // MARK: - Helpers

    private func commitDNS() {
        let servers = dnsText
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.settings.dnsServers = servers
        dnsText = store.settings.effectiveDNSServers.joined(separator: ", ")
    }

    /// Adopts whatever is in the manual field, then clears it.
    private func applyManualHwid() {
        guard let applied = DeviceID.setManual(hwidDraft) else { return }
        hwid = applied
        hwidDraft = ""
    }

    private var appVersion: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(AppVersion.current) (\(build))"
    }
}
