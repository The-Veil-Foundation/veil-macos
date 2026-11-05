import SwiftUI
import AppKit

/// AI access to Veil: the No AI switch, and the MCP config an assistant needs.
///
/// There is no token and no port. An assistant runs `Veil mcp` from this very
/// bundle, which talks to the app over a socket only this user can open; No AI
/// removes the socket altogether.
struct ControlAPISection: View {
    @Environment(ServerStore.self) private var store
    @Environment(ConnectionManager.self) private var connection
    @Environment(ControlServer.self) private var control
    @Environment(Loc.self) private var loc

    @State private var copied = false

    @ViewBuilder
    var body: some View {
        @Bindable var store = store
        Section {
            Toggle(isOn: $store.settings.noAI) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(loc("No AI"))
                    Text(loc("Block assistants from reading or changing Veil."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: store.settings.noAI) { _, _ in apply() }

            if !store.settings.noAI {
                status
                Text(verbatim: mcpConfig)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button(loc("Copy MCP config")) { copy(mcpConfig) }
                        .glassButton()
                    Spacer()
                    if copied {
                        Text(loc("Copied")).font(.caption).foregroundStyle(.green)
                    }
                }
            }
        } header: {
            Text(loc("AI agents (MCP)"))
        } footer: {
            Text(loc("Add this to Claude, Cursor or any MCP client. It works only for your user account, and while No AI is off it can change where your traffic goes."))
                .font(.caption2)
        }

        Section {
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
        }
    }

    private var status: some View {
        HStack(spacing: 6) {
            if control.isRunning {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(loc("Ready for assistants")).font(.caption)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(control.lastError ?? loc("Not listening"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// The snippet for an MCP client, pointing at the binary that is running
    /// now — `/Applications` or wherever the user keeps Veil.
    private var mcpConfig: String {
        let path = Bundle.main.executablePath ?? "/Applications/Veil.app/Contents/MacOS/Veil"
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "mcpServers": {
            "veil": {
              "command": "\(escaped)",
              "args": [
                "mcp"
              ]
            }
          }
        }
        """
    }

    // MARK: - Actions

    private func apply() {
        store.save()
        control.sync(settings: store.settings, store: store, connection: connection)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
