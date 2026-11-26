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
    @State private var scope: SearchScope = .titles
    @State private var torrents: [TorrentResult] = []
    @State private var torrentNote: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.railPosterWidth, maximum: Theme.railPosterWidth + 40), spacing: 16)] }

    var body: some View {
        Group {
            if scope == .torrents {
                TorrentResultsList(query: query, results: torrents, note: torrentNote, isSearching: isSearching)
            } else {
                titleResults
            }
        }
        .navigationTitle("Search")
        .inlineTitle()
        .toolbar { SettingsToolbarItem() }
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: scope.prompt)
        #else
        .searchable(text: $query, placement: .toolbar, prompt: scope.prompt)
        #endif
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
        }
        .task { await loadDiscover() }
        .task(id: "\(scope.rawValue):\(query)") {
            // Debounce typing; torrent providers are slower and rate-limited, so wait a little longer.
            try? await Task.sleep(nanoseconds: scope == .torrents ? 700_000_000 : 350_000_000)
            guard !Task.isCancelled else { return }
            if scope == .torrents { await searchTorrents(query) } else { await search(query) }
        }
    }

    private var titleResults: some View {
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
    }

    /// Every enabled provider that can search by name, at once.
    private func searchTorrents(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { torrents = []; torrentNote = nil; return }
        let providers = model.providers
        guard providers.enabledEngines.contains(where: \.keywordSearch) else {
            torrents = []
            torrentNote = "Turn on a provider that searches by name, such as The Pirate Bay or Knaben, in Settings → Providers."
            return
        }
        isSearching = true
        defer { isSearching = false }
        let found = await providers.search(TorrentQuery(keyword: text))
        guard !Task.isCancelled else { return }
        torrents = found.results
        torrentNote = found.failed.isEmpty ? nil : "Didn't answer: " + ListFormatter.localizedString(byJoining: found.failed) + "."
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
                                .contextMenu { TitleContextMenu(item: item) }
                            if index < picks.count - 1 { Divider().padding(.leading, 64) }
                        }
                    }
                    .padding(.horizontal, Theme.gutter - 14)
                }
            }
            if !trendingMovies.isEmpty {
                PosterRail(title: "Trending Movies", items: trendingMovies) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                }
            }
            if !trendingSeries.isEmpty {
                PosterRail(title: "Trending Shows", items: trendingSeries) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }.buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
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

enum SearchScope: String, CaseIterable, Identifiable {
    case titles, torrents
    var id: String { rawValue }
    var title: String { self == .titles ? "Titles" : "Torrents" }
    var prompt: String { self == .titles ? "Search Nextup" : "Search Providers" }
}

/// Name search across the torrent providers, like the Flutter app's Torrent Search.
private struct TorrentResultsList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.play) private var play
    let query: String
    let results: [TorrentResult]
    let note: String?
    let isSearching: Bool
    @State private var working: String?
    @State private var failure: String?

    var body: some View {
        List {
            if results.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty || isSearching ? "Torrents" : "No Torrents", systemImage: "magnifyingglass")
                } description: {
                    Text(note ?? (query.isEmpty ? "Search every provider by name." : isSearching ? "Asking providers…" : "Try other words."))
                }
                .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(results) { result in
                        Button { open(result, download: false) } label: { TorrentRow(result: result, working: working == result.id) }
                            .buttonStyle(.plain)
                            .contextMenu { menu(result) }
                            .swipeActions(edge: .trailing) {
                                Button { open(result, download: true) } label: { Label("Download", systemImage: "arrow.down.circle") }
                                    .tint(.blue)
                            }
                    }
                } footer: {
                    Text([("\(results.count) torrents"), note].compactMap { $0 }.joined(separator: " · "))
                }
            }
        }
        .overlay(alignment: .top) { if isSearching && !results.isEmpty { ProgressView().padding() } }
        .alert("Couldn't Open Torrent", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    @ViewBuilder
    private func menu(_ result: TorrentResult) -> some View {
        Button { open(result, download: false) } label: { Label("Play", systemImage: "play") }
        Button { open(result, download: true) } label: { Label("Download", systemImage: "arrow.down.circle") }
        Button { Clipboard.copy(result.stream.magnet ?? "") } label: { Label("Copy Magnet Link", systemImage: "link") }
    }

    /// Resolves through the connected debrid service, then plays or downloads the largest video.
    private func open(_ result: TorrentResult, download: Bool) {
        guard working == nil else { return }
        let item = MediaItem(kind: .movie, title: result.name)
        let target = SourceTarget(item: item, intent: download ? .download : .play)
        working = result.id
        Task {
            defer { working = nil }
            do {
                let resolved = try await model.resolve(result.stream, for: target)
                if download {
                    model.downloads.start(url: resolved.url, item: item, season: nil, episode: nil,
                                          episodeTitle: nil, filename: resolved.filename)
                } else {
                    play?.callAsFunction(PlaybackRequest(url: resolved.url, item: item, sourceLabel: result.engine))
                }
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct TorrentRow: View {
    let result: TorrentResult
    let working: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(result.name).font(.subheadline.weight(.medium)).lineLimit(3)
                HStack(spacing: 10) {
                    if let seeders = result.seeders {
                        Label("\(seeders)", systemImage: "person.2.fill").foregroundStyle(seeders > 0 ? Color.green : Color.secondary)
                    }
                    if let size = Format.bytes(result.sizeBytes) { Label(size, systemImage: "internaldrive") }
                    if let date = result.uploaded { Text(date, format: .dateTime.year().month().day()) }
                    Text(result.engine)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            if working { ProgressView() }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
