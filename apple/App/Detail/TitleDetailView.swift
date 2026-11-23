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
    @State private var error: String?

    init(item: MediaItem) {
        _item = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actions.padding(.horizontal)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding(.horizontal)
                }
                if !item.overview.isEmpty {
                    Text(item.overview).font(.body).foregroundStyle(.secondary).padding(.horizontal)
                        .frame(maxWidth: 820, alignment: .leading)
                }
                if item.kind == .series { episodesSection }
                if let cast = detail?.cast, !cast.isEmpty { castRail(cast) }
                if let similar = detail?.similar, !similar.isEmpty {
                    PosterRail(title: "More Like This", items: similar) { other in
                        NavigationLink(value: other) { PosterCard(item: other) }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .nextupBackground()
        .navigationTitle(item.title)
        .inlineTitle()
        .task(id: item.id) { await load() }
        .sheet(item: $sourceTarget, onDismiss: startPendingPlayback) { target in
            SourcesView(target: target) { pendingPlayback = $0 }
                .environment(model)
        }
    }

    // MARK: Sections

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: item.backdropURL ?? item.posterURL)
                .frame(maxWidth: .infinity)
                .frame(height: 340)
                .clipped()
            LinearGradient(colors: [.clear, Theme.background], startPoint: .top, endPoint: .bottom)
            HStack(alignment: .bottom, spacing: 16) {
                ArtworkImage(url: item.posterURL)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.title.weight(.bold)).lineLimit(2)
                    if let tagline = detail?.tagline { Text(tagline).font(.callout).italic().foregroundStyle(.secondary) }
                    Text(facts).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = Format.runtime(detail?.runtimeMinutes) { parts.append(runtime) }
        if let rating = item.rating { parts.append(String(format: "★ %.1f", rating)) }
        if let genres = detail?.genres, !genres.isEmpty { parts.append(genres.prefix(3).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private var resumeEntry: WatchProgress? {
        model.continueWatching().first { $0.id == item.id }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                playPrimary()
            } label: {
                Label(primaryLabel, systemImage: "play.fill").frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(item.imdbID == nil)

            if let key = detail?.trailerYouTubeKey, let url = URL(string: "https://www.youtube.com/watch?v=\(key)") {
                Link(destination: url) { Label("Trailer", systemImage: "film") }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
            if let imdb = item.imdbID, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }

    private var primaryLabel: String {
        guard let entry = resumeEntry else { return item.kind == .series ? "Play S1E1" : "Play" }
        if let s = entry.season, let e = entry.episode {
            return entry.isFinished ? "Next: S\(s)E\(e + 1)" : "Resume S\(s)E\(e)"
        }
        return "Resume"
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

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes").font(.title3.weight(.semibold))
                Spacer()
                if seasonNumbers.count > 1 {
                    Picker("Season", selection: $season) {
                        ForEach(seasonNumbers, id: \.self) { Text("Season \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .padding(.horizontal)

            if loadingEpisodes {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(episodes) { episode in
                        Button {
                            sourceTarget = SourceTarget(item: item, season: episode.season, episode: episode.number, episodeTitle: episode.title)
                        } label: {
                            EpisodeRow(episode: episode, progress: progress(for: episode))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .task(id: season) { await loadEpisodes() }
    }

    private func progress(for episode: Episode) -> Double? {
        let key = "\(item.id):\(episode.season):\(episode.number)"
        guard let position = model.progress.position(for: key), let runtime = episode.runtimeMinutes, runtime > 0 else { return nil }
        return min(1, position / Double(runtime * 60))
    }

    private func castRail(_ cast: [CastMember]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cast").font(.title3.weight(.semibold)).padding(.horizontal)
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
                .padding(.horizontal)
            }
        }
    }

    /// The player opens after the sources sheet has gone, so two presentations never overlap.
    private func startPendingPlayback() {
        guard let request = pendingPlayback else { return }
        pendingPlayback = nil
        play?(request)
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

private struct EpisodeRow: View {
    let episode: Episode
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtworkImage(url: episode.stillURL)
                .frame(width: 160, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        ProgressView(value: progress).tint(Theme.accent).padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.number). \(episode.title)").font(.subheadline.weight(.semibold)).lineLimit(2)
                if let runtime = Format.runtime(episode.runtimeMinutes) {
                    Text(runtime).font(.caption).foregroundStyle(.secondary)
                }
                if !episode.overview.isEmpty {
                    Text(episode.overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle").font(.title2).foregroundStyle(Theme.accent)
        }
        .padding(10)
        .glassCard(cornerRadius: 12)
        .contentShape(Rectangle())
    }
}
