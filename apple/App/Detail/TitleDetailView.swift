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
    @State private var downloadMessage: String?
    @Environment(\.play) private var play
    @Environment(\.openURL) private var openURL
    @Environment(\.isCompactWidth) private var isCompact
    @State private var error: String?
    @State private var overviewExpanded = false

    init(item: MediaItem) {
        _item = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actions.padding(.horizontal, Theme.gutter)
                if let downloadMessage {
                    Text(downloadMessage).font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding(.horizontal, Theme.gutter)
                }
                if item.kind == .series { episodesSection }
                if let cast = detail?.cast, !cast.isEmpty { castRail(cast) }
                if let detail { AboutTitleSection(item: item, detail: detail).padding(.horizontal, Theme.gutter) }
                if let similar = detail?.similar, !similar.isEmpty {
                    PosterRail(title: "More Like This", items: similar) { other in
                        NavigationLink(value: other) { PosterCard(item: other) }.buttonStyle(.plain)
                            .contextMenu { TitleContextMenu(item: other) }
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
                TitleLogo(title: item.title, logoURL: detail?.logoURL, compact: isCompact)
                if !facts.isEmpty || detail?.certification != nil {
                    HStack(spacing: 8) {
                        if let rating = detail?.certification {
                            Text(rating)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary, lineWidth: 1))
                        }
                        Text(facts).font(.subheadline.weight(.medium))
                    }
                }
                if let genres = detail?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(overviewExpanded ? nil : 3)
                        .frame(maxWidth: 720)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { withAnimation(.smooth) { overviewExpanded.toggle() } }
                        .accessibilityHint("Shows the whole synopsis")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
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
        if item.kind == .series, let seasons = detail?.seasons.count, seasons > 0 {
            parts.append(seasons == 1 ? "1 Season" : "\(seasons) Seasons")
        } else if let runtime = Format.runtime(detail?.runtimeMinutes) {
            parts.append(runtime)
        }
        if let rating = item.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        if item.kind == .series, let status = detail?.status, status == "Ended" || status == "Canceled" { parts.append(status) }
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
                if let key = detail?.trailerYouTubeKey, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                    actionButton("Trailer", symbol: "film") { openURL(url) }
                }
                downloadButton
            }
            .controlSize(isCompact ? .extraLarge : .regular)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var movieDownload: DownloadRecord? { model.downloads.record(for: item.id) }

    @ViewBuilder
    private var downloadButton: some View {
        if item.kind == .movie {
            switch movieDownload?.state {
            case .finished?:
                actionButton("Downloaded", symbol: "checkmark.circle.fill") {}
                    .disabled(true)
            case .downloading?, .queued?:
                actionButton("Downloading", symbol: "arrow.down.circle.dotted") {}
                    .disabled(true)
            default:
                actionButton("Download", symbol: "arrow.down.circle") { download(SourceTarget(item: item, intent: .download)) }
            }
        } else {
            actionButton(seriesDownloadTitle, symbol: "arrow.down.circle") { downloadSeries() }
                .disabled(episodes.isEmpty)
        }
    }

    private var seriesDownloadTitle: String {
        switch model.preferences.seriesDownload {
        case .episode: return "Download Episode"
        case .next: return "Download Next \(model.preferences.nextEpisodeCount)"
        case .season: return "Download Season \(season)"
        }
    }

    /// The Download setting: open the sources sheet, or take the best source straight away.
    private func download(_ target: SourceTarget) {
        var target = target
        target.intent = .download
        guard model.preferences.downloadMode == .automatic else {
            sourceTarget = target
            return
        }
        let label = target.season.flatMap { s in target.episode.map { String(format: "S%02dE%02d", s, $0) } } ?? item.title
        downloadMessage = "Finding the best source for \(label)…"
        Task {
            let ok = await model.downloadAutomatically(target)
            downloadMessage = ok ? "Downloading \(label)." : "No source for \(label) could be opened. Try choosing one."
        }
    }

    /// The episode Play would start: where Continue Watching is, else the first one shown.
    private var currentEpisode: Episode? {
        if let entry = resumeEntry, let s = entry.season, let e = entry.episode {
            let number = entry.isFinished ? e + 1 : e
            if let match = episodes.first(where: { $0.season == s && $0.number == number }) { return match }
            if s == season { return nil }
        }
        return episodes.first
    }

    /// One episode, the next few, or the whole season, as set in Settings → Downloads.
    private func downloadSeries() {
        let item = self.item
        switch model.preferences.seriesDownload {
        case .episode:
            guard let episode = currentEpisode ?? episodes.first else { return }
            download(SourceTarget(item: item, season: episode.season, episode: episode.number, episodeTitle: episode.title))
        case .next:
            guard let first = currentEpisode ?? episodes.first else { return }
            let count = model.preferences.nextEpisodeCount
            downloadMessage = "Finding sources for \(count) episodes…"
            Task {
                var list = [first]
                while list.count < count, let last = list.last,
                      let next = await model.nextEpisode(after: item, season: last.season, episode: last.number) {
                    list.append(next)
                }
                let started = await model.downloadEpisodes(item: item, episodes: list)
                downloadMessage = started == 0 ? "No episodes could be queued." : "Downloading \(started) of \(list.count) episodes."
            }
        case .season:
            let list = episodes
            downloadMessage = "Finding sources for \(list.count) episodes…"
            Task {
                let started = await model.downloadEpisodes(item: item, episodes: list)
                downloadMessage = started == 0 ? "No episodes could be queued." : "Downloading \(started) of \(list.count) episodes."
            }
        }
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
            open(SourceTarget(item: item))
            return
        }
        if let entry = resumeEntry, let s = entry.season, let e = entry.episode {
            let next = entry.isFinished ? e + 1 : e
            let title = episodes.first { $0.season == s && $0.number == next }?.title
            open(SourceTarget(item: item, season: s, episode: next, episodeTitle: title))
        } else {
            let first = episodes.first
            open(SourceTarget(item: item, season: first?.season ?? 1, episode: first?.number ?? 1, episodeTitle: first?.title))
        }
    }

    /// Downloaded files play straight away, offline; everything else goes through the sources sheet.
    private func open(_ target: SourceTarget) {
        let key = target.season.flatMap { s in target.episode.map { "\(item.id):\(s):\($0)" } } ?? item.id
        if target.intent == .play, let local = model.downloads.localURL(for: key) {
            play?.callAsFunction(PlaybackRequest(url: local, item: item, season: target.season, episode: target.episode,
                                                 episodeTitle: target.episodeTitle, sourceLabel: "Downloaded"))
        } else {
            sourceTarget = target
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
                                EpisodeCard(episode: episode, progress: progress(for: episode), watched: isWatched(episode),
                                            width: isCompact ? 260 : 340)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { episodeMenu(episode) }
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

    @ViewBuilder
    private func episodeMenu(_ episode: Episode) -> some View {
        Button { openSources(for: episode) } label: { Label("Play", systemImage: "play") }
        if let record = model.downloads.record(for: "\(item.id):\(episode.season):\(episode.number)") {
            Button {} label: { Label(record.state == .finished ? "Downloaded" : "Downloading", systemImage: "arrow.down.circle.fill") }
                .disabled(true)
        } else {
            Button {
                download(SourceTarget(item: item, season: episode.season, episode: episode.number, episodeTitle: episode.title))
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            Button { openSources(for: episode, intent: .download) } label: { Label("Download From…", systemImage: "list.bullet") }
        }
        Button { model.markWatched(item, season: episode.season, episode: episode.number) } label: {
            Label("Mark as Watched", systemImage: "checkmark.circle")
        }
    }

    private func openSources(for episode: Episode, intent: SourceIntent = .play) {
        open(SourceTarget(item: item, season: episode.season, episode: episode.number, episodeTitle: episode.title, intent: intent))
    }

    /// Finished, or before the episode Continue Watching is on.
    private func isWatched(_ episode: Episode) -> Bool {
        guard let entry = resumeEntry, let s = entry.season, let e = entry.episode else { return false }
        if episode.season != s { return episode.season < s }
        return episode.number < e || (episode.number == e && entry.isFinished)
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

/// A landscape card in the episode rail: still with progress, "E1 · Title", air date or runtime, and the synopsis.
private struct EpisodeCard: View {
    let episode: Episode
    var progress: Double?
    var watched: Bool
    var width: CGFloat

    private var isUpcoming: Bool { episode.airDate.map { $0 > Date() } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(url: episode.stillURL)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0, !watched {
                        ProgressView(value: progress)
                            .padding(.horizontal, 10).padding(.bottom, 10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if watched {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(isUpcoming ? 0.55 : 1)
            (Text("E\(episode.number)  ·  ").foregroundStyle(.secondary) + Text(episode.title).fontWeight(.semibold))
                .font(.subheadline)
                .lineLimit(1)
            Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !episode.overview.isEmpty {
                Text(episode.overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var meta: String {
        var parts: [String] = []
        if let date = episode.airDate {
            parts.append(isUpcoming ? "Airs " + date.formatted(date: .abbreviated, time: .omitted)
                                    : date.formatted(date: .abbreviated, time: .omitted))
        }
        if let runtime = Format.runtime(episode.runtimeMinutes) { parts.append(runtime) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

/// The title's logo when TMDB has one, else its name in large type.
private struct TitleLogo: View {
    let title: String
    let logoURL: URL?
    let compact: Bool

    var body: some View {
        if let logoURL {
            AsyncImage(url: logoURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit()
                } else {
                    text.opacity(phase.error == nil ? 0 : 1)
                }
            }
            .frame(maxWidth: compact ? 300 : 420, maxHeight: compact ? 120 : 140)
            .accessibilityLabel(title)
        } else {
            text
        }
    }

    private var text: some View {
        Text(title)
            .font(compact ? .largeTitle.bold() : .title.bold())
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
    }
}

/// Tagline, full synopsis and the facts table (director, studio, release, language…).
private struct AboutTitleSection: View {
    let item: MediaItem
    let detail: MediaDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About").font(.title3.weight(.bold))
            if let tagline = detail.tagline {
                Text(tagline).font(.subheadline.italic()).foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1)
                    }
                }
            }
            .font(.subheadline)
        }
        .frame(maxWidth: 820, alignment: .leading)
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        if !detail.creators.isEmpty {
            rows.append((item.kind == .movie ? (detail.creators.count > 1 ? "Directors" : "Director") : "Created by",
                         detail.creators.joined(separator: ", ")))
        }
        if !detail.writers.isEmpty { rows.append(("Writers", detail.writers.joined(separator: ", "))) }
        let stars = detail.cast.prefix(4).map(\.name)
        if !stars.isEmpty { rows.append(("Stars", stars.joined(separator: ", "))) }
        if !detail.genres.isEmpty { rows.append(("Genres", detail.genres.joined(separator: ", "))) }
        if let date = detail.releaseDate {
            rows.append((item.kind == .movie ? "Released" : "First aired", date.formatted(date: .long, time: .omitted)))
        }
        if let status = detail.status { rows.append(("Status", status)) }
        if item.kind == .series, let count = detail.episodeCount, count > 0 { rows.append(("Episodes", "\(count)")) }
        if let runtime = Format.runtime(detail.runtimeMinutes) { rows.append(("Runtime", runtime)) }
        if !detail.studios.isEmpty { rows.append((item.kind == .movie ? "Studio" : "Network", detail.studios.joined(separator: ", "))) }
        if let language = detail.originalLanguage { rows.append(("Language", language)) }
        if let rating = item.rating, rating > 0 {
            rows.append(("TMDB", String(format: "%.1f", rating) + (detail.voteCount.map { " (\($0.formatted()) votes)" } ?? "")))
        }
        if let budget = detail.budget { rows.append(("Budget", budget.formatted(.currency(code: "USD").precision(.fractionLength(0))))) }
        if let revenue = detail.revenue { rows.append(("Box office", revenue.formatted(.currency(code: "USD").precision(.fractionLength(0))))) }
        return rows
    }
}
