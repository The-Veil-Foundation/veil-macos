import SwiftUI

/// The geoip.dat / geosite.dat rule databases the `geosite:` and `geoip:`
/// matchers read.
struct GeoDatabaseView: View {
    @Environment(ServerStore.self) private var store
    @Environment(Loc.self) private var loc

    private var geo = GeoAssetManager.shared

    init() {}

    var body: some View {
        @Bindable var store = store

        Form {
            Section {
                Picker(loc("Rule database"), selection: $store.settings.geoSource) {
                    ForEach(GeoAssetSource.allCases) { Text(loc($0.title)).tag($0) }
                }
                .onChange(of: store.settings.geoSource) { _, _ in store.save() }

                if store.settings.geoSource == .custom {
                    TextField("geoip.dat URL", text: $store.settings.customGeoipURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit { store.save() }
                    TextField("geosite.dat URL", text: $store.settings.customGeositeURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit { store.save() }
                }
            } header: {
                Text(loc("Rule database (geosite / geoip)"))
            }

            Section {
                HStack {
                    if geo.isDownloading {
                        ProgressView()
                        Text(loc("Downloading…")).foregroundStyle(.secondary)
                    } else if geo.hasAssets, let updated = geo.lastUpdated {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(loc("Updated")) \(updated.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(loc("Not downloaded")).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Button(geo.hasAssets ? loc("Update") : loc("Download")) {
                    Task {
                        await geo.download(source: store.settings.geoSource,
                                           customGeoip: store.settings.customGeoipURL,
                                           customGeosite: store.settings.customGeositeURL)
                    }
                }
                .disabled(geo.isDownloading)
                if let error = geo.lastError {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            } footer: {
                if store.routingNeedsGeoAssets && !geo.hasAssets {
                    Text(loc("This preset needs the rule database. Download it to use geosite/geoip rules."))
                        .foregroundStyle(.orange)
                } else {
                    Text(loc("Without the database, rules that name geosite: or geoip: are left out instead of stopping the tunnel."))
                }
            }
        }
        .navigationTitle(loc("Database"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
