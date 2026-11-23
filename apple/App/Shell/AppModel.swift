import Foundation
import Observation
import NextupKit

/// App-wide state shared by every screen on iPhone, iPad and Mac.
@MainActor
@Observable
final class AppModel {
    let secrets: SecretStoring
    let defaults: DefaultsStore
    let progress: WatchProgressStore
    let addonClient = AddonClient()
    let trakt: TraktClient
    let downloads: DownloadManager

    var addons: [InstalledAddon] { didSet { defaults.save(addons, key: Keys.addons); settingsChanged() } }
    var preferredDebrid: DebridService? {
        didSet { defaults.defaults.set(preferredDebrid?.rawValue, forKey: Keys.preferredDebrid) }
    }
    var preferences: Preferences { didSet { defaults.save(preferences, key: Keys.preferences) } }
    /// Saved on this device; shown in Library.
    var favorites: [MediaItem] { didSet { defaults.save(favorites, key: Keys.favorites); settingsChanged() } }
    var watchlist: [MediaItem] { didSet { defaults.save(watchlist, key: Keys.watchlist); settingsChanged() } }
    /// iPhone/iPad open Settings as a sheet from the gear button; the Mac uses its Settings window.
    var showingSettings = false

    /// Bumped when Continue Watching changes so rails reload.
    private(set) var progressRevision = 0
    /// Bumped when an account or token changes.
    private(set) var accountsRevision = 0

    /// A stream the system player could not open; Root shows a system alert offering other players.
    var playbackFailure: PlaybackFailure?

    init(secrets: SecretStoring = KeychainSecretStore(), defaults: DefaultsStore = DefaultsStore()) {
        self.secrets = secrets
        self.defaults = defaults
        self.progress = WatchProgressStore(store: defaults)
        self.trakt = TraktClient(secrets: secrets)
        self.downloads = DownloadManager(defaults: defaults)
        self.addons = defaults.load([InstalledAddon].self, key: Keys.addons) ?? []
        self.favorites = defaults.load([MediaItem].self, key: Keys.favorites) ?? []
        self.watchlist = defaults.load([MediaItem].self, key: Keys.watchlist) ?? []
        self.preferences = defaults.load(Preferences.self, key: Keys.preferences) ?? Preferences()
        self.preferredDebrid = defaults.defaults.string(forKey: Keys.preferredDebrid).flatMap(DebridService.init(rawValue:))
        seedBuildTimeTMDBToken()
    }

    enum Keys {
        static let addons = "nextup.addons.v1"
        static let preferredDebrid = "nextup.preferredDebrid"
        static let favorites = "nextup.favorites.v1"
        static let watchlist = "nextup.watchlist.v1"
        static let settingsChangedAt = "nextup.settingsChangedAt"
        static let preferences = "nextup.preferences.v1"
    }

    // MARK: Sync

    /// Set while a synced state is applied, so applying it does not count as a new local change.
    private var applyingSync = false

    private func settingsChanged() {
        guard !applyingSync else { return }
        defaults.defaults.set(Date().timeIntervalSinceReferenceDate, forKey: Keys.settingsChangedAt)
    }

    func syncState() -> SyncState {
        var values: [String: String] = [:]
        for key in SecretKey.synced { if let value = secrets.string(for: key), !value.isEmpty { values[key] = value } }
        return SyncState(settingsChangedAt: Date(timeIntervalSinceReferenceDate: defaults.defaults.double(forKey: Keys.settingsChangedAt)),
                         addons: addons, favorites: favorites, watchlist: watchlist,
                         secrets: values, progress: progress.all())
    }

    func apply(_ state: SyncState) {
        applyingSync = true
        defer { applyingSync = false }
        if addons != state.addons { addons = state.addons }
        if favorites != state.favorites { favorites = state.favorites }
        if watchlist != state.watchlist { watchlist = state.watchlist }
        for key in SecretKey.synced where secrets.string(for: key) != state.secrets[key] {
            // Trakt rotates refresh tokens: never replace a session with an older one.
            if key == SecretKey.traktSession, let local = trakt.session,
               let remote = state.secrets[key].flatMap({ try? JSONDecoder().decode(TraktSession.self, from: Data($0.utf8)) }),
               local.expiresAt > remote.expiresAt { continue }
            secrets.set(state.secrets[key], for: key)
        }
        defaults.defaults.set(state.settingsChangedAt.timeIntervalSinceReferenceDate, forKey: Keys.settingsChangedAt)
        progress.replaceAll(state.progress)
        progressRevision += 1
        accountsRevision += 1
    }

    // MARK: Metadata

    var tmdb: TMDBClient {
        let secrets = self.secrets
        return TMDBClient { secrets.string(for: SecretKey.tmdbToken) }
    }

    var hasTMDB: Bool { !(secrets.string(for: SecretKey.tmdbToken) ?? "").isEmpty }

    /// Builds pass a token through Info.plist (`NXTMDBToken`, from the TMDB_READ_ACCESS_TOKEN build setting).
    private func seedBuildTimeTMDBToken() {
        guard !hasTMDB,
              let token = Bundle.main.object(forInfoDictionaryKey: "NXTMDBToken") as? String,
              !token.isEmpty, !token.hasPrefix("$(") else { return }
        secrets.set(token, for: SecretKey.tmdbToken)
    }

    func setSecret(_ value: String?, for key: String) {
        secrets.set(value?.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
        accountsChanged()
    }

    /// Tells screens that depend on accounts (Home, Library) to reload.
    func accountsChanged() {
        accountsRevision += 1
        settingsChanged()
    }

    func secret(_ key: String) -> String { secrets.string(for: key) ?? "" }

    // MARK: Debrid

    var configuredDebrid: [DebridService] {
        DebridService.allCases.filter { !(secrets.string(for: $0.secretKey) ?? "").isEmpty }
    }

    /// The service used to play torrents: the preferred one if it is set up, else the first one that is.
    var activeDebrid: DebridProvider? {
        let configured = configuredDebrid
        let service = preferredDebrid.flatMap { configured.contains($0) ? $0 : nil } ?? configured.first
        return service.flatMap { DebridFactory.provider($0, secrets: secrets) }
    }

    // MARK: Addons

    func install(addonURL: String) async throws {
        let addon = try await addonClient.install(addonURL)
        if let index = addons.firstIndex(where: { $0.manifest.id == addon.manifest.id }) {
            addons[index] = addon
        } else {
            addons.append(addon)
        }
    }

    func removeAddons(at offsets: IndexSet) {
        addons.remove(atOffsets: offsets)
    }

    func moveAddons(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Favorites and watchlist

    func isFavorite(_ item: MediaItem) -> Bool { favorites.contains { $0.id == item.id } }
    func isOnWatchlist(_ item: MediaItem) -> Bool { watchlist.contains { $0.id == item.id } }

    func toggleFavorite(_ item: MediaItem) {
        if isFavorite(item) { favorites.removeAll { $0.id == item.id } } else { favorites.insert(item, at: 0) }
    }

    func toggleWatchlist(_ item: MediaItem) {
        if isOnWatchlist(item) { watchlist.removeAll { $0.id == item.id } } else { watchlist.insert(item, at: 0) }
    }

    /// Marks a movie finished: it leaves Continue Watching and Trakt hears about it.
    func markWatched(_ item: MediaItem, season: Int? = nil, episode: Int? = nil) {
        record(WatchProgress(item: item, season: season, episode: episode, position: 1, duration: 1))
        guard trakt.isSignedIn else { return }
        let trakt = self.trakt
        let ep = season.flatMap { s in episode.map { (season: s, number: $0) } }
        Task.detached { try? await trakt.scrobble(.stop, item: item, episode: ep, progress: 100) }
    }

    // MARK: Resolving sources

    enum ResolveError: LocalizedError {
        case noDebrid, nothingPlayable
        var errorDescription: String? {
            switch self {
            case .noDebrid: return "Connect Real-Debrid, TorBox or AllDebrid in Settings to use torrent sources."
            case .nothingPlayable: return "None of the sources could be opened."
            }
        }
    }

    /// Turns one addon stream into a URL the player or the downloader can open.
    func resolve(_ stream: StremioStream, for target: SourceTarget) async throws -> ResolvedStream {
        if let direct = stream.url, let url = URL(string: direct) {
            return ResolvedStream(url: url, filename: stream.behaviorHints?.filename, sizeBytes: stream.sizeBytes)
        }
        guard let magnet = stream.magnet else { throw DebridError.noPlayableFile }
        guard let debrid = activeDebrid else { throw ResolveError.noDebrid }
        let hint = FileHint(fileIndex: stream.fileIdx, filename: stream.behaviorHints?.filename,
                            season: target.season, episode: target.episode)
        return try await debrid.resolve(magnet: magnet, hint: hint)
    }

    /// Picks a source without asking: best quality first, trying a few until one opens.
    /// Used by season downloads (and later Quick Play).
    func autoResolve(_ target: SourceTarget, attempts: Int = 4) async throws -> ResolvedStream {
        guard let imdb = target.item.imdbID else { throw ResolveError.nothingPlayable }
        let id = AddonClient.videoID(imdbID: imdb, season: target.season, episode: target.episode)
        let lookup = await addonClient.streams(from: addons, type: target.item.kind.stremioType, id: id)
        let ranked = preferences.arrange(lookup.streams, sort: .best)
            .filter { $0.url != nil || ($0.infoHash != nil && activeDebrid != nil) }
        for stream in ranked.prefix(attempts) {
            if let resolved = try? await resolve(stream, for: target) { return resolved }
        }
        throw ResolveError.nothingPlayable
    }

    /// Queues every episode of a season, picking sources automatically. Returns how many started.
    func downloadSeason(item: MediaItem, episodes: [Episode]) async -> Int {
        var started = 0
        for episode in episodes where downloads.record(for: "\(item.id):\(episode.season):\(episode.number)") == nil {
            let target = SourceTarget(item: item, season: episode.season, episode: episode.number, episodeTitle: episode.title)
            if let resolved = try? await autoResolve(target) {
                downloads.start(url: resolved.url, item: item, season: episode.season, episode: episode.number,
                                episodeTitle: episode.title, filename: resolved.filename)
                started += 1
            }
        }
        return started
    }

    // MARK: Next episode

    /// The episode after this one: next in the season, else the first of the next season.
    func nextEpisode(after item: MediaItem, season: Int, episode: Int) async -> Episode? {
        if let list = await episodes(of: item, season: season), let next = list.first(where: { $0.number == episode + 1 }) {
            return next
        }
        if let list = await episodes(of: item, season: season + 1), let first = list.min(by: { $0.number < $1.number }) {
            return first
        }
        return nil
    }

    private func episodes(of item: MediaItem, season: Int) async -> [Episode]? {
        if let tmdbID = item.tmdbID, tmdb.isConfigured {
            return try? await tmdb.season(tmdbID: tmdbID, number: season)
        }
        guard let imdb = item.imdbID,
              let meta = try? await addonClient.meta(from: addons, type: "series", id: imdb) else { return nil }
        return meta.episodes.filter { $0.season == season }
    }

    /// A ready-to-play request for an episode: the downloaded file if there is one, else a source picked automatically.
    func playbackRequest(for item: MediaItem, episode: Episode) async throws -> PlaybackRequest {
        let key = "\(item.id):\(episode.season):\(episode.number)"
        if let local = downloads.localURL(for: key) {
            return PlaybackRequest(url: local, item: item, season: episode.season, episode: episode.number,
                                   episodeTitle: episode.title, sourceLabel: "Downloaded")
        }
        let target = SourceTarget(item: item, season: episode.season, episode: episode.number, episodeTitle: episode.title)
        let resolved = try await autoResolve(target)
        return PlaybackRequest(url: resolved.url, item: item, season: episode.season, episode: episode.number,
                               episodeTitle: episode.title, sourceLabel: nil)
    }

    // MARK: Progress

    func continueWatching() -> [WatchProgress] {
        _ = progressRevision
        return progress.all()
    }

    func record(_ entry: WatchProgress) {
        progress.record(entry)
        progressRevision += 1
    }

    func removeFromContinueWatching(_ id: String) {
        progress.remove(id)
        progressRevision += 1
    }
}

/// Everything the player needs, so a Mac player window can be restored from it.
struct PlaybackRequest: Codable, Hashable, Identifiable {
    var url: URL
    var item: MediaItem
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var sourceLabel: String?

    var id: String { url.absoluteString }

    var displayTitle: String {
        guard let season, let episode else { return item.title }
        let code = String(format: "S%02dE%02d", season, episode)
        return "\(item.title) · \(code)" + (episodeTitle.map { " · \($0)" } ?? "")
    }

    var playbackKey: String {
        guard let season, let episode else { return item.id }
        return "\(item.id):\(season):\(episode)"
    }
}
