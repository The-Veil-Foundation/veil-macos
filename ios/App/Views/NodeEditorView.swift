import SwiftUI

/// Shows a node as its `wg-quick` file, its Xray outbound JSON, or its share
/// link — and, when Veil owns it, lets that text be edited and checked by the
/// core that will run it.
struct NodeEditorView: View {
    @Environment(ServerStore.self) private var store
    @Environment(TunnelController.self) private var tunnel
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let server: ProxyConfig
    var isEditable: Bool

    @State private var kind: NodeRepresentation.Kind = .json
    @State private var text = ""
    @State private var message: String?
    @State private var isBad = false
    @State private var isChecking = false

    private var kinds: [NodeRepresentation.Kind] { NodeRepresentation.kinds(for: server) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(loc("Format"), selection: $kind) {
                        ForEach(kinds) { kind in
                            Text(loc(kind.title)).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .onChange(of: kind) { _, new in
                        text = NodeRepresentation.text(new, for: server)
                        message = nil
                    }
                }

                Section {
                    TextEditor(text: $text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 280)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(!isEditable)
                } footer: {
                    if let message {
                        Text(message)
                            .foregroundStyle(isBad ? .red : .secondary)
                            .textSelection(.enabled)
                    } else if !isEditable {
                        Text(loc("A subscription's servers are the panel's. Rename them, tag them, pin them — that is yours and survives a refresh — but to change what one connects to, duplicate it into Manual."))
                    }
                }

                Section {
                    Button(loc("Copy"), systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = text
                    }
                    if isEditable {
                        Button(loc("Check"), systemImage: "checkmark.seal") {
                            Task { await check() }
                        }
                        .disabled(isChecking)
                    } else {
                        Button(loc("Duplicate and edit"), systemImage: "plus.square.on.square") {
                            duplicate()
                        }
                    }
                }
            }
            .navigationTitle(server.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("Close")) { dismiss() }
                }
                if isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        if isChecking {
                            ProgressView()
                        } else {
                            Button(loc("Save")) { Task { await save() } }
                        }
                    }
                }
            }
            .onAppear {
                kind = kinds.first ?? .json
                text = NodeRepresentation.text(kind, for: server)
            }
        }
    }

    // MARK: - Actions

    private func parsed() -> ProxyConfig? {
        do {
            return try NodeRepresentation.parse(kind, text: text, keeping: server)
        } catch {
            message = loc(error.localizedDescription)
            isBad = true
            return nil
        }
    }

    /// Asks the real core when it is running, so the message the user reads is
    /// the core's own.
    @discardableResult
    private func check() async -> ProxyConfig? {
        guard let node = parsed() else { return nil }
        isChecking = true
        let outcome = await tunnel.check(node)
        isChecking = false
        switch outcome {
        case .ok:
            message = loc("The core accepted this configuration.")
            isBad = false
            return node
        case .failed(let reason):
            message = loc(reason)
            isBad = true
            return nil
        case .unavailable:
            // The core runs in the VPN extension, which is only up while
            // connected. Refusing to save over that would lose the edit.
            message = loc("The core is not available, so this was not checked.")
            isBad = false
            return node
        }
    }

    private func save() async {
        guard let node = await check() else { return }
        store.replaceServer(node)
        dismiss()
    }

    private func duplicate() {
        var copy = server
        copy.id = UUID()
        copy.name = server.name + " " + loc("(copy)")
        store.addManualServer(copy)
        dismiss()
    }
}
