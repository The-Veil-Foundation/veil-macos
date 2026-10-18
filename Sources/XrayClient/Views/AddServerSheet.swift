import SwiftUI
import UniformTypeIdentifiers

/// The single "add something" sheet.
///
/// There is deliberately no subscription-vs-link choice: the user pastes,
/// scans or imports whatever they have and `AddInputClassifier` works out
/// which it is. The sheet reports what it found and does the right thing.
struct AddServerSheet: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var nameText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showScanner = false

    private var input: AddInput { AddInputClassifier.classify(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(loc("Add")).font(.title2).bold()
            Text(loc("Paste a link, subscription URL or config"))
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))

            if case .subscription = input {
                TextField(loc("Name (optional)"), text: $nameText)
                    .textFieldStyle(.roundedBorder)
            }

            detectionLine

            HStack(spacing: 8) {
                Button {
                    importFromImage()
                } label: {
                    Label(loc("From image…"), systemImage: "qrcode")
                }
                Button {
                    showScanner = true
                } label: {
                    Label(loc("Scan camera"), systemImage: "camera")
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(loc("Cancel")) { dismiss() }
                Button(loc("Add")) { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input == .unrecognized || isLoading)
            }
        }
        .padding().frame(width: 480)
        .sheet(isPresented: $showScanner) {
            ScannerSheet { scanned in
                append(scanned)
                showScanner = false
            }
        }
    }

    /// Live feedback so the user can see the app understood the paste before
    /// committing to it.
    @ViewBuilder
    private var detectionLine: some View {
        switch input {
        case .servers(let servers, _):
            // Never interpolate a count into a translated noun — plural forms
            // differ per language. "Label: N" reads correctly everywhere.
            Label(servers.count == 1
                  ? "\(loc("Server")): \(servers[0].name)"
                  : "\(loc("Servers found")): \(servers.count)",
                  systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        case .subscription(let url):
            Label("\(loc("Subscription")) · \(URL(string: url)?.host ?? url)",
                  systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.green)
        case .unrecognized where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            Text(loc("vless:// · vmess:// · trojan:// · ss:// · wireguard:// · https://…/sub"))
                .font(.caption).foregroundStyle(.secondary)
        case .unrecognized:
            Label(loc("Not a link or subscription URL"), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    /// Appends a scanned/decoded payload to the text box (newline-separated).
    private func append(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        text += text.isEmpty ? trimmed : "\n" + trimmed
    }

    /// Opens an image file and decodes a QR-code link from it.
    private func importFromImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let payload = QRCode.decode(fileURL: url) else {
            errorMessage = loc("No QR code found in that image.")
            return
        }
        append(payload)
    }

    private func commit() async {
        errorMessage = nil
        switch input {
        case .servers(let servers, let groups):
            store.addManualServers(servers, groups: groups)
            dismiss()

        case .subscription(let url):
            isLoading = true
            defer { isLoading = false }
            do {
                let result = try await SubscriptionFetcher.fetch(
                    url,
                    hwid: store.settings.sendHwid ? DeviceID.hwid : nil,
                    userAgent: store.settings.userAgentOverride)
                guard !result.servers.isEmpty else {
                    errorMessage = loc("The subscription returned no servers.")
                    return
                }
                let name = nameText.isEmpty
                    ? (result.profileTitle ?? URL(string: url)?.host ?? loc("Subscription"))
                    : nameText
                store.addOrUpdateSubscription(name: name, url: url,
                                              servers: result.servers,
                                              groups: result.payload.groups,
                                              metadata: result.metadata,
                                              format: result.payload.format,
                                              skipped: result.payload.skipped)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }

        case .unrecognized:
            errorMessage = loc("Not a link or subscription URL")
        }
    }
}

/// A small sheet wrapping the live camera scanner.
struct ScannerSheet: View {
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss
    var onScan: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(loc("Point the camera at a QR code")).font(.headline)
            CameraScannerView { value in onScan(value) }
                .frame(width: 360, height: 270)
                .cornerRadius(10)
            Button(loc("Cancel")) { dismiss() }
        }
        .padding(16)
        .frame(width: 400)
    }
}
