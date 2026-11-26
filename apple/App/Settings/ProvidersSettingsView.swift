import SwiftUI
import NextupKit

/// Torrent providers, as in the Flutter app: download them from the shared catalog, switch them
/// on or off, and their results join the addon streams in every sources list.
struct ProvidersSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installed: [TorrentEngine] = []
    @State private var catalog: [ProviderStore.CatalogEntry] = []
    @State private var loadingCatalog = false
    @State private var busy: Set<String> = []
    @State private var link = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if installed.isEmpty {
                    Text("No providers yet. Add some below.").foregroundStyle(.secondary)
                }
                ForEach(installed) { engine in
                    Toggle(isOn: Binding(get: { model.providers.isEnabled(engine.id) },
                                         set: { model.providers.setEnabled($0, id: engine.id); refresh() })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName)
                            Text(capabilities(engine)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) { remove(engine.id) } label: { Label("Remove", systemImage: "trash") }
                    }
                }
                .onDelete { offsets in offsets.map { installed[$0].id }.forEach(remove) }
            } header: {
                Text("Installed")
            } footer: {
                Text("Results from these providers appear with your addon streams. Torrents play and download through your debrid service.")
            }

            Section {
                if loadingCatalog {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(catalog) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        if busy.contains(entry.id) {
                            ProgressView().controlSize(.small)
                        } else if installed.contains(where: { $0.id == entry.id }) {
                            Button("Update") { Task { await install(entry) } }
                        } else {
                            Button("Get") { Task { await install(entry) } }
                                .buttonStyle(.glassProminent)
                        }
                    }
                }
                if !catalog.isEmpty {
                    Button("Get All") { Task { for entry in catalog { await install(entry) } } }
                        .disabled(!busy.isEmpty)
                }
            } header: {
                Text("Available")
            } footer: {
                Text("The same catalog the Flutter app downloads from: gitlab.com/mediacontent/search-engines.")
            }

            Section {
                TextField("Link to a provider .yaml file", text: $link)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button("Add from Link") { Task { await addFromLink() } }
                    .disabled(link.isEmpty || !busy.isEmpty)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Other Providers")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Providers")
        .onAppear(perform: refresh)
        .task { await loadCatalog() }
        .refreshable { await loadCatalog() }
    }

    private func capabilities(_ engine: TorrentEngine) -> String {
        var parts: [String] = []
        if engine.imdbSearch { parts.append("Titles") }
        if engine.keywordSearch { parts.append("Keyword search") }
        if engine.seriesSupport { parts.append("Episodes") }
        return parts.joined(separator: " · ")
    }

    private func refresh() {
        installed = model.providers.installed()
        model.providersChanged()
    }

    private func loadCatalog() async {
        loadingCatalog = true
        defer { loadingCatalog = false }
        do {
            catalog = try await model.providers.catalog()
        } catch {
            message = "The providers list could not be loaded: \(error.localizedDescription)"
        }
    }

    private func install(_ entry: ProviderStore.CatalogEntry) async {
        busy.insert(entry.id)
        defer { busy.remove(entry.id) }
        do {
            try await model.providers.install(entry)
            message = nil
        } catch {
            message = "\(entry.name): \(error.localizedDescription)"
        }
        refresh()
    }

    private func addFromLink() async {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { message = "That is not a link."; return }
        busy.insert("link")
        defer { busy.remove("link") }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let engine = try model.providers.install(yaml: String(decoding: data, as: UTF8.self))
            message = "Added \(engine.displayName)."
            link = ""
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }

    private func remove(_ id: String) {
        model.providers.remove(id: id)
        refresh()
    }
}
