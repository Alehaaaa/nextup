import SwiftUI
import NextupKit

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var traktPlayback: [TraktClient.PlaybackItem] = []
    @State private var watchlist: [MediaItem] = []
    @State private var traktError: String?

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: Theme.railWideWidth, maximum: Theme.railWideWidth + 80), spacing: 16)] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                let entries = model.continueWatching()
                section("Continue Watching") {
                    if entries.isEmpty {
                        Text("Titles you start watching show up here.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(entries) { entry in
                                NavigationLink(value: entry.item) {
                                    WideCard(item: entry.item, width: Theme.railWideWidth, progress: entry.fraction,
                                             caption: entry.season.flatMap { s in entry.episode.map { String(format: "S%02dE%02d", s, $0) } })
                                }
                                .buttonStyle(.plain)
                                .contextMenu { TitleContextMenu(item: entry.item) { model.removeFromContinueWatching(entry.id) } }
                            }
                        }
                    }
                }

                if model.trakt.isSignedIn {
                    section("Paused on Trakt") {
                        if traktPlayback.isEmpty {
                            Text(traktError ?? "Nothing paused on Trakt.").foregroundStyle(.secondary)
                        } else {
                            ForEach(traktPlayback, id: \.id) { entry in
                                if let item = Self.mediaItem(entry) {
                                    NavigationLink(value: item) {
                                        TraktRow(title: item.title, subtitle: Self.subtitle(entry), progress: entry.progress / 100)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    section("Trakt Watchlist") {
                        if watchlist.isEmpty {
                            Text("Your Trakt watchlist is empty.").foregroundStyle(.secondary)
                        } else {
                            ForEach(watchlist) { item in
                                NavigationLink(value: item) {
                                    TraktRow(title: item.title, subtitle: [item.kind == .movie ? "Movie" : "Show", item.year.map(String.init)]
                                        .compactMap { $0 }.joined(separator: " · "), progress: nil)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical)
        }
        .nextupBackground()
        .navigationTitle("Library")
        .refreshable { await loadTrakt() }
        .task(id: model.accountsRevision) { await loadTrakt() }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }

    private func loadTrakt() async {
        guard model.trakt.isSignedIn else { return }
        traktError = nil
        do {
            let trakt = model.trakt
            async let playback = trakt.playback()
            async let list = trakt.watchlist()
            traktPlayback = try await playback
            let entries = try await list
            watchlist = entries.compactMap { entry in
                let kind: MediaKind = entry.type == "movie" ? .movie : .series
                guard let title = entry.movie ?? entry.show else { return nil }
                return MediaItem(kind: kind, tmdbID: title.ids.tmdb, imdbID: title.ids.imdb, title: title.title, year: title.year)
            }
        } catch {
            traktError = error.localizedDescription
        }
    }

    static func mediaItem(_ entry: TraktClient.PlaybackItem) -> MediaItem? {
        if let movie = entry.movie {
            return MediaItem(kind: .movie, tmdbID: movie.ids.tmdb, imdbID: movie.ids.imdb, title: movie.title, year: movie.year)
        }
        if let show = entry.show {
            return MediaItem(kind: .series, tmdbID: show.ids.tmdb, imdbID: show.ids.imdb, title: show.title, year: show.year)
        }
        return nil
    }

    static func subtitle(_ entry: TraktClient.PlaybackItem) -> String {
        var parts: [String] = []
        if let ep = entry.episode {
            parts.append(String(format: "S%02dE%02d", ep.season, ep.number) + (ep.title.map { " · \($0)" } ?? ""))
        }
        parts.append("\(Int(entry.progress))% watched")
        return parts.joined(separator: " · ")
    }
}

private struct TraktRow: View {
    let title: String
    let subtitle: String
    let progress: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if let progress { ProgressView(value: progress).tint(Theme.accent) }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(12)
        .glassCard(cornerRadius: 12)
        .contentShape(Rectangle())
    }
}
