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

    var addons: [InstalledAddon] { didSet { defaults.save(addons, key: Keys.addons) } }
    var preferredDebrid: DebridService? {
        didSet { defaults.defaults.set(preferredDebrid?.rawValue, forKey: Keys.preferredDebrid) }
    }
    /// Saved on this device; shown in Library.
    var favorites: [MediaItem] { didSet { defaults.save(favorites, key: Keys.favorites) } }
    var watchlist: [MediaItem] { didSet { defaults.save(watchlist, key: Keys.watchlist) } }
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
        self.addons = defaults.load([InstalledAddon].self, key: Keys.addons) ?? []
        self.favorites = defaults.load([MediaItem].self, key: Keys.favorites) ?? []
        self.watchlist = defaults.load([MediaItem].self, key: Keys.watchlist) ?? []
        self.preferredDebrid = defaults.defaults.string(forKey: Keys.preferredDebrid).flatMap(DebridService.init(rawValue:))
        seedBuildTimeTMDBToken()
    }

    enum Keys {
        static let addons = "nextup.addons.v1"
        static let preferredDebrid = "nextup.preferredDebrid"
        static let favorites = "nextup.favorites.v1"
        static let watchlist = "nextup.watchlist.v1"
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
        accountsRevision += 1
    }

    /// Tells screens that depend on accounts (Home, Library) to reload.
    func accountsChanged() { accountsRevision += 1 }

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
