import SwiftUI
import NextupKit

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var message: String?
    @State private var trendingMovies: [MediaItem] = []
    @State private var trendingSeries: [MediaItem] = []
    @State private var picks: [MediaItem] = []

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.railPosterWidth, maximum: Theme.railPosterWidth + 40), spacing: 16)] }

    var body: some View {
        ScrollView {
            if query.isEmpty && !(trendingMovies.isEmpty && trendingSeries.isEmpty) {
                discover
            } else if results.isEmpty {
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
        .navigationTitle("Search")
        .inlineTitle()
        .toolbar { SettingsToolbarItem() }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Nextup")
        #else
        .searchable(text: $query, placement: .toolbar, prompt: "Search Nextup")
        #endif
        .task { await loadDiscover() }
        .task(id: query) {
            // Debounce typing.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    /// Before typing: trending rows and a ranked "What should I watch" list.
    private var discover: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if !picks.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What Should I Watch").font(.title3.weight(.bold)).padding(.horizontal, Theme.gutter)
                    VStack(spacing: 0) {
                        ForEach(Array(picks.enumerated()), id: \.element.id) { index, item in
                            NavigationLink(value: item) { PickRow(rank: index + 1, item: item) }
                                .buttonStyle(.plain)
                            if index < picks.count - 1 { Divider().padding(.leading, 64) }
                        }
                    }
                    .padding(.horizontal, Theme.gutter - 14)
                }
            }
            if !trendingMovies.isEmpty {
                PosterRail(title: "Trending Movies", items: trendingMovies) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                }
            }
            if !trendingSeries.isEmpty {
                PosterRail(title: "Trending Shows", items: trendingSeries) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private func loadDiscover() async {
        let tmdb = model.tmdb
        guard tmdb.isConfigured, trendingMovies.isEmpty else { return }
        async let movies = tmdb.list(.trendingMovies)
        async let series = tmdb.list(.trendingSeries)
        async let topMovies = tmdb.list(.topRatedMovies)
        async let topSeries = tmdb.list(.topRatedSeries)
        trendingMovies = (try? await movies) ?? []
        trendingSeries = (try? await series) ?? []
        // Ranked mix of well-rated titles, alternating movies and shows.
        let a = (try? await topMovies) ?? [], b = (try? await topSeries) ?? []
        picks = Array(zip(a, b).flatMap { [$0, $1] }.prefix(8))
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

private struct PickRow: View {
    let rank: Int
    let item: MediaItem

    var body: some View {
        HStack(spacing: 14) {
            Text("\(rank)").font(.title2.weight(.heavy)).monospacedDigit().frame(width: 30)
            ArtworkImage(url: item.posterURL)
                .frame(width: 40, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text([item.kind == .movie ? "Movie" : "Show", item.year.map(String.init), item.rating.map { String(format: "★ %.1f", $0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
