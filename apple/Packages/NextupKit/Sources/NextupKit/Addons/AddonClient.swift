import Foundation

/// Talks to Stremio-protocol addons: install, catalogs, streams.
public struct AddonClient: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = .shared) { self.http = http }

    /// Accepts `stremio://`, `https://…/manifest.json` or a bare base URL.
    public static func normalizeManifestURL(_ raw: String) throws -> URL {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        if !s.contains("://") { s = "https://" + s }
        let path = s.split(separator: "?", maxSplits: 1).first.map(String.init) ?? s
        if !path.hasSuffix("/manifest.json") {
            var base = path
            while base.hasSuffix("/") { base.removeLast() }
            s = base + "/manifest.json"
        }
        guard let url = URL(string: s), url.host != nil else { throw HTTPError.invalidURL(raw) }
        return url
    }

    public func install(_ raw: String) async throws -> InstalledAddon {
        let url = try Self.normalizeManifestURL(raw)
        let manifest = try await http.json(AddonManifest.self, "GET", url)
        return InstalledAddon(manifestURL: url, manifest: manifest)
    }

    public func refresh(_ addon: InstalledAddon) async throws -> InstalledAddon {
        var updated = addon
        updated.manifest = try await http.json(AddonManifest.self, "GET", addon.manifestURL)
        return updated
    }

    /// Stremio's video id: `tt123` for movies, `tt123:1:2` for an episode.
    public static func videoID(imdbID: String, season: Int? = nil, episode: Int? = nil) -> String {
        guard let season, let episode else { return imdbID }
        return "\(imdbID):\(season):\(episode)"
    }

    public func streams(from addon: InstalledAddon, type: String, id: String) async throws -> [StremioStream] {
        struct Response: Decodable { let streams: [StremioStream]? }
        let url = try URL.build("\(addon.baseURL)/stream/\(type)/\(Self.pathEscape(id)).json")
        let response = try await http.json(Response.self, "GET", url)
        return (response.streams ?? []).map { stream in
            var s = stream
            s.addonName = addon.manifest.name
            return s
        }
    }

    /// Asks every enabled addon that can answer, in parallel, and returns results in addon order.
    /// Addons that fail are reported but do not fail the whole lookup.
    public func streams(from addons: [InstalledAddon], type: String, id: String) async -> StreamLookup {
        let eligible = addons.enumerated().filter { $0.element.enabled && $0.element.manifest.supports("stream", type: type, id: id) }
        var collected: [(Int, [StremioStream])] = []
        var failures: [String] = []
        await withTaskGroup(of: (Int, String, Result<[StremioStream], Error>).self) { group in
            for (index, addon) in eligible {
                group.addTask {
                    do { return (index, addon.manifest.name, .success(try await self.streams(from: addon, type: type, id: id))) }
                    catch { return (index, addon.manifest.name, .failure(error)) }
                }
            }
            for await (index, name, result) in group {
                switch result {
                case .success(let streams): collected.append((index, streams))
                case .failure: failures.append(name)
                }
            }
        }
        let ordered = collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        return StreamLookup(streams: ordered, failedAddons: failures.sorted(), askedAddons: eligible.count)
    }

    public func catalog(from addon: InstalledAddon, catalog: AddonManifest.Catalog, search: String? = nil, skip: Int = 0) async throws -> [StremioMeta] {
        struct Response: Decodable { let metas: [StremioMeta]? }
        var extras: [String] = []
        if let search, !search.isEmpty { extras.append("search=\(Self.pathEscape(search))") }
        if skip > 0 { extras.append("skip=\(skip)") }
        let suffix = extras.isEmpty ? "" : "/" + extras.joined(separator: "&")
        let url = try URL.build("\(addon.baseURL)/catalog/\(catalog.type)/\(Self.pathEscape(catalog.id))\(suffix).json")
        return try await http.json(Response.self, "GET", url).metas ?? []
    }

    /// Full meta (with episode list) from the first addon that serves `meta` for this id, e.g. Cinemeta.
    public func meta(from addons: [InstalledAddon], type: String, id: String) async throws -> StremioMetaDetail? {
        struct Response: Decodable { let meta: StremioMetaDetail? }
        for addon in addons where addon.enabled && addon.manifest.supports("meta", type: type, id: id) {
            let url = try URL.build("\(addon.baseURL)/meta/\(type)/\(Self.pathEscape(id)).json")
            if let meta = try? await http.json(Response.self, "GET", url).meta { return meta }
        }
        return nil
    }

    static func pathEscape(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

public struct StreamLookup: Sendable {
    public var streams: [StremioStream]
    public var failedAddons: [String]
    public var askedAddons: Int

    public init(streams: [StremioStream], failedAddons: [String], askedAddons: Int) {
        self.streams = streams
        self.failedAddons = failedAddons
        self.askedAddons = askedAddons
    }
}
