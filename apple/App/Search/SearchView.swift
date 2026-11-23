import SwiftUI
import NextupKit

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var message: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.railPosterWidth, maximum: Theme.railPosterWidth + 40), spacing: 16)] }

    var body: some View {
        ScrollView {
            if results.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "Search" : "No results", systemImage: "magnifyingglass")
                } description: {
                    Text(message ?? (query.isEmpty ? "Find movies and shows." : "Try another title."))
                }
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    ForEach(results) { item in
                        NavigationLink(value: item) {
                            PosterCard(item: item, width: Theme.railPosterWidth,
                                       caption: [item.kind == .movie ? "Movie" : "Show", item.year.map(String.init)]
                                           .compactMap { $0 }.joined(separator: " · "))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                    }
                }
                .padding()
            }
        }
        .overlay(alignment: .top) { if isSearching { ProgressView().padding() } }
        .nextupBackground()
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Movies, shows")
        .task(id: query) {
            // Debounce typing.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    private func search(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { results = []; message = nil; return }
        isSearching = true
        defer { isSearching = false }
        message = nil

        let tmdb = model.tmdb
        if tmdb.isConfigured {
            do {
                results = try await tmdb.search(text)
            } catch {
                results = []
                message = error.localizedDescription
            }
            return
        }

        // Without TMDB, search through addon catalogs that support it (Cinemeta and friends).
        let client = model.addonClient
        var found: [MediaItem] = []
        for addon in model.addons where addon.enabled {
            for catalog in addon.manifest.catalogs where catalog.supportsSearch {
                if let metas = try? await client.catalog(from: addon, catalog: catalog, search: text) {
                    found.append(contentsOf: metas.map(\.mediaItem))
                }
            }
        }
        var seen = Set<String>()
        results = found.filter { seen.insert($0.id).inserted }
        if results.isEmpty && model.addons.isEmpty {
            message = "Add a TMDB token or install a catalog addon (such as Cinemeta) in Settings to search."
        }
    }
}
