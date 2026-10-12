import SwiftUI

/// Tail of the Xray log. The core runs in the extension, so the log is a file
/// in the shared container that the provider ships back a chunk at a time —
/// and only while this screen is open.
struct LogView: View {
    @Environment(TunnelController.self) private var tunnel
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Severity floor. `.none` keeps every line.
    @State private var minimum: LogLevel = .none
    @State private var follow = true

    private var shown: String {
        LogFilter.apply(tunnel.logs, query: query, minimum: minimum)
    }

    var body: some View {
        let text = shown
        NavigationStack {
            VStack(spacing: 0) {
                filterBar(shownCount: count(text), total: count(tunnel.logs))
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(text.isEmpty ? placeholder : text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(text.isEmpty ? Color.secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .onChange(of: tunnel.logs) { _, _ in
                        guard follow else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .navigationTitle(loc("Log"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("Done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        // Copy takes what is shown, not everything the core wrote.
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel(loc("Copy"))
                    .disabled(text.isEmpty)

                    ShareLink(item: text) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(text.isEmpty)

                    Button {
                        tunnel.clearLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel(loc("Clear"))
                    .disabled(tunnel.logs.isEmpty)
                }
            }
            .task {
                tunnel.wantsLog = true
                // Keep the tail fresh while this screen is open even when the
                // status poll is not running.
                while !Task.isCancelled {
                    await tunnel.refreshStatus()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            .onDisappear { tunnel.wantsLog = false }
        }
    }

    private var placeholder: String {
        if !tunnel.isConnected { return loc("The log is written while the tunnel is up.") }
        return tunnel.logs.isEmpty ? loc("No logs yet.") : loc("Nothing matches the filter.")
    }

    private func filterBar(shownCount: Int, total: Int) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(loc("Filter"), text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))

            Menu {
                Picker(loc("Severity"), selection: $minimum) {
                    Text(loc("All")).tag(LogLevel.none)
                    Text(loc("Info")).tag(LogLevel.info)
                    Text(loc("Warning")).tag(LogLevel.warning)
                    Text(loc("Error")).tag(LogLevel.error)
                }
                Toggle(loc("Follow"), isOn: $follow)
            } label: {
                Image(systemName: minimum == .none
                      ? "line.3.horizontal.decrease.circle"
                      : "line.3.horizontal.decrease.circle.fill")
            }

            Text(verbatim: "\(shownCount)/\(total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func count(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: true).count
    }
}
