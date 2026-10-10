import SwiftUI
import AppKit

/// Turns the local control API on, and hands over what a caller needs to use
/// it: the address, the token, and instructions an assistant can follow.
///
/// The API can rewrite the routing rules, so nothing here is on by default and
/// the token is shown only when asked for.
struct ControlAPISection: View {
    @Environment(ServerStore.self) private var store
    @Environment(ConnectionManager.self) private var connection
    @Environment(ControlServer.self) private var control
    @Environment(Loc.self) private var loc

    @State private var revealToken = false
    @State private var copied: String?

    var body: some View {
        @Bindable var store = store
        Section {
            Toggle(loc("Let other programs configure Veil"),
                   isOn: $store.settings.veilAPIEnabled)
                .onChange(of: store.settings.veilAPIEnabled) { _, _ in apply() }

            if store.settings.veilAPIEnabled {
                HStack {
                    Text(loc("Port"))
                    Spacer()
                    TextField("", value: $store.settings.veilAPIPort,
                              format: .number.grouping(.never))
                        .frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit { apply() }
                }
                status
                tokenRow
                HStack {
                    Button(loc("Copy setup for an assistant")) {
                        copy(assistantBriefing, as: "briefing")
                    }
                    .glassButton()
                    Button(loc("New token")) {
                        ControlServer.rotateToken()
                        revealToken = false
                        apply(restart: true)
                    }
                    .glassButton()
                    Spacer()
                    if let copied {
                        Text(copied == "token" ? loc("Token copied") : loc("Copied"))
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            }

            Toggle(loc("Clash-compatible API (dashboards)"),
                   isOn: $store.settings.clashAPIEnabled)
                .onChange(of: store.settings.clashAPIEnabled) { _, _ in store.save() }
            if store.settings.clashAPIEnabled {
                HStack {
                    Text(loc("Clash API port"))
                    Spacer()
                    TextField("", value: $store.settings.controlAPIPort,
                              format: .number.grouping(.never))
                        .frame(width: 80).multilineTextAlignment(.trailing)
                        .onSubmit { store.save() }
                }
                Text(loc("Served by the core while connected, for dashboards like Yacd. Its secret changes on every launch."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text(loc("Control API"))
        } footer: {
            Text(loc("Listens on 127.0.0.1 only and needs the token. Anything holding it can change where your traffic goes."))
                .font(.caption2)
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if control.isRunning {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(verbatim: "http://127.0.0.1:\(control.port)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(control.lastError ?? loc("Not listening"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var tokenRow: some View {
        HStack(spacing: 6) {
            Text(loc("Token")).font(.caption).foregroundStyle(.secondary)
            if revealToken {
                Text(ControlServer.token())
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            } else {
                Text(String(repeating: "•", count: 16)).font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(revealToken ? loc("Hide") : loc("Show")) { revealToken.toggle() }
                .buttonStyle(.borderless).font(.caption)
            Button(loc("Copy")) { copy(ControlServer.token(), as: "token") }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    // MARK: - Actions

    private func apply(restart: Bool = false) {
        store.save()
        if restart { control.stop() }
        control.sync(settings: store.settings, store: store, connection: connection)
    }

    private func copy(_ text: String, as kind: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = kind
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = nil
        }
    }

    /// Everything a language model needs to configure Veil, in one paste.
    ///
    /// Written as plain instructions rather than a schema dump: the API serves
    /// its own schema, so the useful thing to hand over is the address, the
    /// token and the two mistakes that are easy to make — naming an app by its
    /// icon label, and forgetting that rules apply on the next connect.
    private var assistantBriefing: String {
        let base = "http://127.0.0.1:\(store.settings.veilAPIPort)"
        return """
        You can configure Veil, a VPN client on this machine, over its local HTTP API.

        Base URL: \(base)
        Every request needs the header: Authorization: Bearer \(ControlServer.token())

        Start with GET \(base)/v1/schema — it lists every endpoint.

        Typical task — send one application through a particular server:
        1. GET /v1/servers and pick the server; its "tag" names it in a rule.
        2. GET /v1/apps?q=<part of the app name> and take "processName".
           That is the executable, which is often not the name on the icon.
        3. GET /v1/rules, append a rule, PUT the whole array back:
           {"name": "Work", "target": "server:<uuid>", "processNames": ["Slack"],
            "enabled": true}
           target is "proxy", "direct", "block", "server:<uuid>" or "group:<uuid>".
        4. Rules take effect on the next connect: POST /v1/connect
           {"serverID": "<uuid>"}.

        Rules are ordered and the first match wins. Application rules only work
        in TUN mode with the native core — GET /v1/state reports
        processRoutingAvailable.

        Other things you can do:
        - POST /v1/apply pushes an edit into a connection that is already up.
        - GET /v1/sources says where the servers came from and what the last
          fetch had to skip; POST /v1/sources/refresh re-downloads them.
        - GET/PUT /v1/nodes carries the user's own labels, pins and renames.
        - GET /v1/logs?level=warning&limit=50 is the core's log, redacted.

        The API never returns a subscription URL or the device identifier, and
        it cannot add servers. The full contract is in docs/agents.md.
        """
    }
}
