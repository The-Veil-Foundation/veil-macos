import SwiftUI
import PhotosUI

/// The single "add something" screen.
///
/// There is deliberately no subscription-vs-link choice: the user pastes,
/// scans or picks whatever they have and `AddInputClassifier` works out which
/// it is. The sheet just reports what it found and does the right thing.
struct AddView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var nameText = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showScanner = false
    @State private var photoItem: PhotosPickerItem?

    private var input: AddInput { AddInputClassifier.classify(text) }

    var body: some View {
        // PhotosPicker's label builder is @Sendable, so the localized title has
        // to be resolved here rather than inside the closure.
        let fromImageTitle = loc("From image…")

        return NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text(loc("Paste a link, subscription URL or config"))
                } footer: {
                    detectionFooter
                }

                if case .subscription = input {
                    Section {
                        TextField(loc("Name (optional)"), text: $nameText)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label(loc("Scan camera"), systemImage: "qrcode.viewfinder")
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(fromImageTitle, systemImage: "photo")
                    }
                    // A system paste button rather than reading
                    // UIPasteboard ourselves: that would pop the "Allow Paste?"
                    // alert on every tap, and a denied alert looks exactly like
                    // a broken button.
                    HStack {
                        Label(loc("Paste from clipboard"), systemImage: "doc.on.clipboard")
                        Spacer()
                        PasteButton(payloadType: String.self) { strings in
                            guard let pasted = strings.first else { return }
                            append(pasted)
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.capsule)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(loc("Add"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Button(loc("Add")) { Task { await commit() } }
                            .disabled(input == .unrecognized)
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { payload in
                    showScanner = false
                    append(payload)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await decode(item) }
            }
        }
    }

    /// Live feedback so the user can see the app understood the paste before
    /// committing to it.
    @ViewBuilder
    private var detectionFooter: some View {
        switch input {
        case .servers(let servers, _):
            // Never interpolate a count into a translated noun — plural forms
            // differ per language. "Label: N" reads correctly everywhere.
            Label(servers.count == 1
                  ? "\(loc("Server")): \(servers[0].name)"
                  : "\(loc("Servers found")): \(servers.count)",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .subscription(let url):
            Label("\(loc("Subscription")) · \(URL(string: url)?.host ?? url)",
                  systemImage: "arrow.down.circle")
                .foregroundStyle(.green)
        case .unrecognized where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            Text(loc("vless:// · vmess:// · trojan:// · ss:// · wireguard:// · https://…/sub"))
        case .unrecognized:
            Label(loc("Not a link or subscription URL"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func append(_ payload: String) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        errorMessage = nil
        text += text.isEmpty ? trimmed : "\n" + trimmed
    }

    private func decode(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = loc("Could not read that image.")
            return
        }
        guard let payload = QRCode.decode(from: image) else {
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
            let hwid = store.settings.sendHwid ? DeviceID.hwid : nil
            do {
                let result = try await SubscriptionFetcher.fetch(
                    url, hwid: hwid, userAgent: store.settings.userAgentOverride)
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
