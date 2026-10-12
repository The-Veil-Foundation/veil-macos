import SwiftUI

/// The name and labels the user puts on a node, as opposed to what its source
/// calls it. Both are annotations, so both survive the next refresh.
struct NodeAnnotationView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc
    @Environment(\.dismiss) private var dismiss

    let server: ProxyConfig
    @State private var name = ""
    @State private var tags: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(server.name, text: $name)
                        .autocorrectionDisabled()
                } header: {
                    Text(loc("Name"))
                } footer: {
                    Text(loc("Shown instead of the name the source gives this server."))
                }

                Section(loc("Tags")) {
                    TokenListEditor(values: $tags, placeholder: loc("Add a tag…"),
                                    monospaced: false)
                }

                let inUse = store.allTags.filter { !tags.contains($0) }
                if !inUse.isEmpty {
                    Section(loc("In use elsewhere")) {
                        ChipFlow(spacing: 6) {
                            ForEach(inUse, id: \.self) { tag in
                                Chip(title: tag, systemImage: "plus") { tags.append(tag) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Only when the setting is on: with it off these tags are not
                // in the list, the filter or the groups, so showing them here
                // would promise something the rest of the app does not do.
                let derived = store.settings.autoTags
                    ? AutoTags.tags(for: server, name: name.isEmpty ? nil : name)
                    : []
                if !derived.isEmpty {
                    Section {
                        ChipFlow(spacing: 6) {
                            ForEach(derived, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text(loc("Read from the name"))
                    } footer: {
                        Text(loc("These come from the server's own name and its settings. They filter and group like any tag, and change when the name does."))
                    }
                }

                Section {
                    Button(loc("Reset"), role: .destructive) {
                        name = ""
                        tags = []
                    }
                }
            }
            .navigationTitle(loc("Rename and tag…"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(loc("Save")) {
                        store.rename(serverID: server.id, to: name)
                        store.setTags(tags, serverID: server.id)
                        dismiss()
                    }
                }
            }
            .onAppear {
                let annotation = store.annotation(for: server.id)
                name = annotation.nameOverride ?? ""
                tags = annotation.tags
            }
        }
    }
}
