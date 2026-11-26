import Foundation

/// The providers catalog the Flutter app downloads from (gitlab.com/mediacontent/search-engines),
/// and the provider files installed on this device.
public final class ProviderStore: @unchecked Sendable {
    public struct CatalogEntry: Hashable, Sendable, Identifiable {
        public var name: String
        public var path: String
        /// "torrents/pirate_bay.yaml" → "pirate_bay".
        public var id: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    static let rawBase = "https://gitlab.com/mediacontent/search-engines/-/raw/main/"
    static let catalogPath = "torrents/metadata.yaml"

    private let directory: URL
    private let defaults: UserDefaults
    private let http: HTTPClient
    private let lock = NSLock()
    private static let disabledKey = "nextup.providers.disabled"

    public init(directory: URL? = nil, defaults: UserDefaults = .standard, http: HTTPClient = .shared) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nextup/Providers", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.directory = base
        self.defaults = defaults
        self.http = http
    }

    // MARK: Catalog

    public func catalog() async throws -> [CatalogEntry] {
        let (data, response) = try await http.data("GET", try URL.build(Self.rawBase + Self.catalogPath))
        guard (200..<300).contains(response.statusCode), let text = String(data: data, encoding: .utf8) else {
            throw HTTPError.status(response.statusCode, "The providers list could not be downloaded.")
        }
        let root = try MiniYAML.parse(text) as? [String: Any]
        return (root?["engines"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let name = entry["name"] as? String, let path = entry["path"] as? String else { return nil }
            return CatalogEntry(name: name, path: path)
        }
    }

    /// Downloads one provider file, checks it, and saves it.
    @discardableResult
    public func install(_ entry: CatalogEntry) async throws -> TorrentEngine {
        let (data, response) = try await http.data("GET", try URL.build(Self.rawBase + entry.path))
        guard (200..<300).contains(response.statusCode), let text = String(data: data, encoding: .utf8) else {
            throw HTTPError.status(response.statusCode, entry.name)
        }
        return try install(yaml: text)
    }

    /// Saves a provider file the user picked or pasted.
    @discardableResult
    public func install(yaml: String) throws -> TorrentEngine {
        let engine = try TorrentEngine(yaml: yaml)
        lock.lock(); defer { lock.unlock() }
        try Data(yaml.utf8).write(to: directory.appendingPathComponent("\(engine.id).yaml"), options: .atomic)
        return engine
    }

    public func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).yaml"))
    }

    // MARK: Installed

    public func installed() -> [TorrentEngine] {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "yaml" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap { try? TorrentEngine(yaml: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func isEnabled(_ id: String) -> Bool { !(defaults.stringArray(forKey: Self.disabledKey) ?? []).contains(id) }

    public func setEnabled(_ enabled: Bool, id: String) {
        var disabled = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
        if enabled { disabled.remove(id) } else { disabled.insert(id) }
        defaults.set(Array(disabled).sorted(), forKey: Self.disabledKey)
    }

    public var enabledEngines: [TorrentEngine] { installed().filter { isEnabled($0.id) } }

    // MARK: Searching

    /// Asks every enabled provider at once. Shows get episode-matched results (or season packs).
    public func search(_ query: TorrentQuery) async -> (results: [TorrentResult], failed: [String]) {
        let engines = enabledEngines.filter(\.supportsTitles)
        var results: [TorrentResult] = []
        var failed: [String] = []
        await withTaskGroup(of: (String, [TorrentResult]?).self) { group in
            for engine in engines {
                group.addTask {
                    do { return (engine.displayName, try await engine.search(query)) } catch { return (engine.displayName, nil) }
                }
            }
            for await (name, found) in group {
                if let found { results += found } else { failed.append(name) }
            }
        }
        if query.isSeries, let season = query.season, let episode = query.episode {
            results = results.filter { Self.fits($0.name, season: season, episode: episode) }
        }
        var seen = Set<String>()
        results = results.filter { seen.insert($0.infoHash).inserted }
            .sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
        return (results, failed.sorted())
    }

    /// The episode itself, or a pack for its season (or the whole show) with no other episode named.
    static func fits(_ name: String, season: Int, episode: Int) -> Bool {
        if EpisodeMatcher.matches(name, season: season, episode: episode) { return true }
        let lower = name.lowercased()
        let namesAnEpisode = lower.range(of: #"s\d{1,2}[ ._-]*e\d{1,3}|\d{1,2}x\d{2}"#, options: .regularExpression) != nil
        if namesAnEpisode { return false }
        let seasonPack = lower.range(of: #"(s0*\#(season)(?!\d)|season[ ._-]*0*\#(season)(?!\d))"#, options: .regularExpression) != nil
        let complete = lower.contains("complete") || lower.range(of: #"s\d{1,2}[ ._-]*-[ ._-]*s?\d{1,2}"#, options: .regularExpression) != nil
        return seasonPack || complete
    }
}
