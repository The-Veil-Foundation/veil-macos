import SwiftUI

/// Picks the community rule lists and says where a match in one of them goes.
struct CommunityListsView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    private var lists = CommunityListManager.shared
    @State private var confirmClear = false

    init() {}

    var body: some View {
        @Bindable var store = store
        let selected = store.settings.communityLists

        Form {
            Section {
                Picker(loc("Matches go to"), selection: $store.settings.communityListTarget) {
                    Text(loc("Proxy")).tag(RuleTarget.proxy)
                    Text(loc("Direct")).tag(RuleTarget.direct)
                    Text(loc("Block")).tag(RuleTarget.block)
                }
                .pickerStyle(.segmented)
                .onChange(of: store.settings.communityListTarget) { _, _ in store.save() }
            } header: {
                Text(loc("Destination"))
            } footer: {
                Text(loc("Your own rules are checked first, so a list never overrides a rule you wrote."))
            }

            ForEach(CommunityList.Category.allCases) { category in
                Section(loc(category.title)) {
                    ForEach(CommunityListCatalog.lists(in: category)) { list in
                        Toggle(isOn: Binding(
                            get: { selected.contains(list.id) },
                            set: { on in set(list.id, on) }
                        )) {
                            listLabel(list)
                        }
                    }
                }
            }

            Section {
                HStack {
                    status(selected)
                    Spacer()
                    Button(loc("Update now")) {
                        Task { await lists.refresh(ids: selected) }
                    }
                    .disabled(selected.isEmpty || lists.isBusy)
                }
                if let error = lists.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Link(loc("Source on GitHub"),
                     destination: URL(string: CommunityListCatalog.homepage)!)
                Button(loc("Clear cache"), role: .destructive) { confirmClear = true }
            } header: {
                Text(loc("Cache"))
            } footer: {
                Text(loc("Ready-made domain and subnet lists from the allow-domains project. Picking one adds a rule that matches everything in it."))
            }
        }
        .navigationTitle(loc("Lists"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(loc("Delete the downloaded lists?"),
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button(loc("Clear cache"), role: .destructive) { lists.clearCache() }
            Button(loc("Cancel"), role: .cancel) {}
        } message: {
            Text(loc("The lists you picked stay selected and are fetched again on the next update."))
        }
        .task { await lists.refreshDue(store.settings) }
    }

    private func listLabel(_ list: CommunityList) -> some View {
        let cached = lists.cached(list.id)
        return HStack(spacing: 6) {
            Text(loc(list.title))
            if lists.isDownloading(list.id) {
                ProgressView().controlSize(.mini)
            } else if let cached, !cached.isEmpty {
                Text(verbatim: "\(cached.entryCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func status(_ selected: [String]) -> some View {
        if lists.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(loc("Downloading…")).font(.caption).foregroundStyle(.secondary)
            }
        } else if selected.isEmpty {
            Text(loc("Nothing to download.")).font(.caption).foregroundStyle(.secondary)
        } else if let oldest = lists.oldestUpdate(among: selected) {
            Text(verbatim: "\(loc("Updated")) \(oldest.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(loc("Not downloaded yet")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func set(_ id: String, _ on: Bool) {
        if on {
            guard !store.settings.communityLists.contains(id) else { return }
            store.settings.communityLists.append(id)
            store.save()
            Task { await lists.refresh(ids: [id]) }
        } else {
            store.settings.communityLists.removeAll { $0 == id }
            store.save()
        }
    }
}
