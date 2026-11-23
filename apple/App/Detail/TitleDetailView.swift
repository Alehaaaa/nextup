import SwiftUI
import NextupKit

/// One detail page for every title, whatever catalog it came from.
struct TitleDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var item: MediaItem
    @State private var detail: MediaDetail?
    @State private var addonEpisodes: [Episode] = []
    @State private var season: Int = 1
    @State private var episodes: [Episode] = []
    @State private var loadingEpisodes = false
    @State private var sourceTarget: SourceTarget?
    @State private var pendingPlayback: PlaybackRequest?
    @Environment(\.play) private var play
    @Environment(\.isCompactWidth) private var isCompact
    @State private var error: String?

    init(item: MediaItem) {
        _item = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actions.padding(.horizontal, Theme.gutter)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding(.horizontal, Theme.gutter)
                }
                if item.kind == .series { episodesSection }
                if let cast = detail?.cast, !cast.isEmpty { castRail(cast) }
                if let similar = detail?.similar, !similar.isEmpty {
                    PosterRail(title: "More Like This", items: similar) { other in
                        NavigationLink(value: other) { PosterCard(item: other) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(edges: .top)
        .navigationTitle(item.title)
        .inlineTitle()
        #if os(iOS)
        .toolbar(removing: .title)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) { moreMenu }
        }
        .task { await load() }
        .sheet(item: $sourceTarget, onDismiss: startPendingPlayback) { target in
            SourcesView(target: target) { pendingPlayback = $0 }
                .environment(model)
        }
    }

    // MARK: Sections

    private var headerHeight: CGFloat { isCompact ? 560 : 520 }

    /// Full-bleed artwork under the glass toolbar; title, facts and synopsis centered over it.
    private var header: some View {
        ZStack(alignment: .bottom) {
            ArtworkImage(url: item.backdropURL ?? item.posterURL)
                .frame(maxWidth: .infinity)
                .frame(height: headerHeight)
                .clipped()
                .backgroundExtensionEffect()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.3),
                .init(color: Theme.background.opacity(0.7), location: 0.72),
                .init(color: Theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                Text(item.title)
                    .font(isCompact ? .largeTitle.bold() : .title.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                if !facts.isEmpty {
                    Text(facts).font(.subheadline.weight(.medium))
                }
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(isCompact ? 3 : 2)
                        .frame(maxWidth: 720)
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
    }

    private var moreMenu: some View {
        Menu {
            if let imdb = item.imdbID, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Link(destination: url) { Label("Open on IMDb", systemImage: "safari") }
            }
            if let key = detail?.trailerYouTubeKey, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                Link(destination: url) { Label("Watch Trailer", systemImage: "film") }
            }
            if resumeEntry != nil {
                Button(role: .destructive) { model.removeFromContinueWatching(item.id) } label: {
                    Label("Remove from Continue Watching", systemImage: "xmark.circle")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    private var facts: String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = Format.runtime(detail?.runtimeMinutes) { parts.append(runtime) }
        if let genres = detail?.genres, !genres.isEmpty { parts.append(genres.prefix(2).joined(separator: ", ")) }
        if let rating = item.rating { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: " · ")
    }

    private var resumeEntry: WatchProgress? {
        model.continueWatching().first { $0.id == item.id }
    }

    /// System glass buttons: a prominent Resume, then Random / Favorite / Watchlist
    /// (round icon buttons on iPhone, labelled buttons on iPad and Mac).
    private var actions: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                Button { playPrimary() } label: {
                    Label {
                        Text(primaryLabel.title) + Text(primaryLabel.code.map { "  \($0)" } ?? "").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "play.fill")
                    }
                    .frame(maxWidth: isCompact ? .infinity : nil)
                }
                .buttonStyle(.glassProminent)
                .disabled(item.imdbID == nil)

                if item.kind == .series {
                    actionButton("Random", symbol: "dice") { playRandom() }
                        .disabled(episodes.isEmpty)
                }
                actionButton("Favorite", symbol: model.isFavorite(item) ? "heart.fill" : "heart") {
                    model.toggleFavorite(item)
                }
                actionButton("Watchlist", symbol: model.isOnWatchlist(item) ? "bookmark.fill" : "bookmark") {
                    model.toggleWatchlist(item)
                }
            }
            .controlSize(isCompact ? .extraLarge : .regular)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func actionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        if isCompact {
            Button(action: action) { Label(title, systemImage: symbol) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else {
            Button(action: action) { Label(title, systemImage: symbol) }
                .buttonStyle(.glass)
        }
    }

    private func playRandom() {
        guard let episode = episodes.randomElement() else { return }
        openSources(for: episode)
    }

    private var primaryLabel: (title: String, code: String?) {
        guard let entry = resumeEntry else {
            return item.kind == .series ? ("Play", "S01E01") : ("Play", nil)
        }
        if let s = entry.season, let e = entry.episode {
            return entry.isFinished ? ("Next", String(format: "S%02dE%02d", s, e + 1)) : ("Resume", String(format: "S%02dE%02d", s, e))
        }
        return ("Resume", nil)
    }

    private func playPrimary() {
        guard item.kind == .series else {
            sourceTarget = SourceTarget(item: item)
            return
        }
        if let entry = resumeEntry, let s = entry.season, let e = entry.episode {
            let next = entry.isFinished ? e + 1 : e
            let title = episodes.first { $0.season == s && $0.number == next }?.title
            sourceTarget = SourceTarget(item: item, season: s, episode: next, episodeTitle: title)
        } else {
            let first = episodes.first
            sourceTarget = SourceTarget(item: item, season: first?.season ?? 1, episode: first?.number ?? 1, episodeTitle: first?.title)
        }
    }

    private var seasonNumbers: [Int] {
        if let seasons = detail?.seasons, !seasons.isEmpty { return seasons.map(\.number) }
        return Array(Set(addonEpisodes.map(\.season))).sorted()
    }

    /// Season menu, then an episode rail (the same on iPhone, iPad and Mac).
    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            seasonMenu.padding(.horizontal, Theme.gutter)

            if loadingEpisodes {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(episodes) { episode in
                            Button { openSources(for: episode) } label: {
                                EpisodeCard(episode: episode, progress: progress(for: episode), width: isCompact ? 250 : 340)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.gutter)
                    .scrollTargetLayout()
                }
                .scrollClipDisabled()
                .scrollTargetBehavior(.viewAligned)
            }
        }
        .task(id: season) { await loadEpisodes() }
    }

    @ViewBuilder
    private var seasonMenu: some View {
        if seasonNumbers.count > 1 {
            Picker("Season", selection: $season) {
                ForEach(seasonNumbers, id: \.self) { Text("Season \($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        } else {
            Text("Season \(season)").font(.headline)
        }
    }

    private func openSources(for episode: Episode) {
        sourceTarget = SourceTarget(item: item, season: episode.season, episode: episode.number, episodeTitle: episode.title)
    }

    private func progress(for episode: Episode) -> Double? {
        let key = "\(item.id):\(episode.season):\(episode.number)"
        guard let position = model.progress.position(for: key), let runtime = episode.runtimeMinutes, runtime > 0 else { return nil }
        return min(1, position / Double(runtime * 60))
    }

    private func castRail(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.title3.weight(.bold)).padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { person in
                        VStack(spacing: 6) {
                            ArtworkImage(url: person.profileURL)
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                            Text(person.name).font(.caption.weight(.medium)).lineLimit(1)
                            Text(person.character).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 88)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }

    /// The player opens after the sources sheet has gone, so two presentations never overlap.
    private func startPendingPlayback() {
        guard let request = pendingPlayback else { return }
        pendingPlayback = nil
        play?.callAsFunction(request)
    }

    // MARK: Loading

    private func load() async {
        error = nil
        let tmdb = model.tmdb
        do {
            if tmdb.isConfigured {
                if item.tmdbID == nil, let imdb = item.imdbID, let found = try await tmdb.find(imdbID: imdb) {
                    item.tmdbID = found.tmdbID
                    if item.backdropURL == nil { item.backdropURL = found.backdropURL }
                }
                if let id = item.tmdbID {
                    let loaded = try await tmdb.detail(kind: item.kind, tmdbID: id)
                    detail = loaded
                    let keepIMDb = item.imdbID
                    item = loaded.item
                    if item.imdbID == nil { item.imdbID = keepIMDb }
                }
            }
            if item.kind == .series, detail?.seasons.isEmpty ?? true, let imdb = item.imdbID {
                let meta = try await model.addonClient.meta(from: model.addons, type: "series", id: imdb)
                addonEpisodes = meta?.episodes ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
        if item.kind == .series {
            if let resume = resumeEntry?.season, seasonNumbers.contains(resume) { season = resume }
            else if let first = seasonNumbers.first { season = first }
            await loadEpisodes()
        }
    }

    private func loadEpisodes() async {
        if detail?.seasons.isEmpty ?? true {
            episodes = addonEpisodes.filter { $0.season == season }
            return
        }
        guard let id = item.tmdbID else { return }
        loadingEpisodes = true
        defer { loadingEpisodes = false }
        episodes = (try? await model.tmdb.season(tmdbID: id, number: season)) ?? []
    }
}

/// A landscape card in the episode rail: still, progress, "E1 • Title", runtime.
private struct EpisodeCard: View {
    let episode: Episode
    var progress: Double?
    var width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(url: episode.stillURL)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressView(value: progress)
                            .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            (Text("E\(episode.number)  •  ").foregroundStyle(.secondary) + Text(episode.title).fontWeight(.semibold))
                .font(.subheadline)
                .lineLimit(1)
            if let runtime = Format.runtime(episode.runtimeMinutes) {
                Text(runtime).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}
