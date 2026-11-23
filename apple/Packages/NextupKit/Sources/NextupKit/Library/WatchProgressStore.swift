import Foundation

/// How far the user got in one movie or episode.
public struct WatchProgress: Codable, Hashable, Sendable, Identifiable {
    public var item: MediaItem
    public var season: Int?
    public var episode: Int?
    public var episodeTitle: String?
    public var position: Double
    public var duration: Double
    public var updatedAt: Date

    public init(item: MediaItem, season: Int? = nil, episode: Int? = nil, episodeTitle: String? = nil,
                position: Double, duration: Double, updatedAt: Date = Date()) {
        self.item = item
        self.season = season
        self.episode = episode
        self.episodeTitle = episodeTitle
        self.position = position
        self.duration = duration
        self.updatedAt = updatedAt
    }

    /// One entry per title: the latest episode of a show replaces earlier ones.
    public var id: String { item.id }
    public var playbackKey: String {
        guard let season, let episode else { return item.id }
        return "\(item.id):\(season):\(episode)"
    }

    public var fraction: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    /// Matches the Flutter app: past 90% counts as finished.
    public var isFinished: Bool { fraction >= 0.9 }
}

/// Local Continue Watching, capped like the Flutter app (50 entries).
public final class WatchProgressStore: @unchecked Sendable {
    public static let cap = 50
    private let store: DefaultsStore
    private let key = "nextup.continueWatching.v1"
    private let positionsKey = "nextup.playbackPositions.v1"
    private let lock = NSLock()

    public init(store: DefaultsStore = DefaultsStore()) { self.store = store }

    public func all() -> [WatchProgress] {
        lock.lock(); defer { lock.unlock() }
        return (store.load([WatchProgress].self, key: key) ?? []).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Saved resume position for a specific movie or episode, in seconds.
    public func position(for playbackKey: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return store.load([String: Double].self, key: positionsKey)?[playbackKey]
    }

    public func record(_ progress: WatchProgress) {
        lock.lock(); defer { lock.unlock() }
        var positions = store.load([String: Double].self, key: positionsKey) ?? [:]
        positions[progress.playbackKey] = progress.isFinished ? nil : progress.position
        store.save(positions, key: positionsKey)

        var list = store.load([WatchProgress].self, key: key) ?? []
        list.removeAll { $0.id == progress.id }
        // A finished movie leaves the row; a finished episode keeps the show (Next Up) at that point.
        if !(progress.isFinished && progress.item.kind == .movie) {
            list.insert(progress, at: 0)
        }
        store.save(Array(list.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.cap)), key: key)
    }

    /// Replaces Continue Watching with entries merged from another device.
    public func replaceAll(_ entries: [WatchProgress]) {
        lock.lock(); defer { lock.unlock() }
        var positions = store.load([String: Double].self, key: positionsKey) ?? [:]
        for entry in entries where !entry.isFinished { positions[entry.playbackKey] = entry.position }
        store.save(positions, key: positionsKey)
        store.save(Array(entries.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.cap)), key: key)
    }

    public func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        var list = store.load([WatchProgress].self, key: key) ?? []
        list.removeAll { $0.id == id }
        store.save(list, key: key)
    }
}
