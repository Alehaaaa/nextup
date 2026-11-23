import Foundation

/// A Stremio addon manifest (https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/api/responses/manifest.md).
public struct AddonManifest: Codable, Hashable, Sendable {
    public struct Resource: Codable, Hashable, Sendable {
        public var name: String
        public var types: [String]?
        public var idPrefixes: [String]?

        public init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
            self.name = name
            self.types = types
            self.idPrefixes = idPrefixes
        }

        // A resource is either "stream" or {"name": "stream", "types": [...]}.
        public init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: name)
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(name: try c.decode(String.self, forKey: .name),
                      types: try c.decodeIfPresent([String].self, forKey: .types),
                      idPrefixes: try c.decodeIfPresent([String].self, forKey: .idPrefixes))
        }
    }

    public struct Catalog: Codable, Hashable, Sendable, Identifiable {
        public struct Extra: Codable, Hashable, Sendable {
            public var name: String
            public var isRequired: Bool?
            public var options: [String]?
        }
        public var type: String
        public var id: String
        public var name: String?
        public var extra: [Extra]?

        public var identity: String { "\(type)/\(id)" }
        public var supportsSearch: Bool { extra?.contains { $0.name == "search" } ?? false }
        /// Catalogs that cannot be shown without user input (search-only, genre-required).
        public var requiresInput: Bool { extra?.contains { $0.isRequired == true } ?? false }
    }

    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var logo: String?
    public var resources: [Resource]
    public var types: [String]
    public var catalogs: [Catalog]
    public var idPrefixes: [String]?

    enum CodingKeys: String, CodingKey { case id, name, version, description, logo, resources, types, catalogs, idPrefixes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        resources = try c.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        catalogs = try c.decodeIfPresent([Catalog].self, forKey: .catalogs) ?? []
        idPrefixes = try c.decodeIfPresent([String].self, forKey: .idPrefixes)
    }

    /// Whether this addon can answer `resource` for `type` and `id` (e.g. "stream", "series", "tt0903747:1:1").
    public func supports(_ resource: String, type: String, id: String) -> Bool {
        guard let entry = resources.first(where: { $0.name == resource }) else { return false }
        let types = entry.types ?? self.types
        guard types.isEmpty || types.contains(type) else { return false }
        let prefixes = entry.idPrefixes ?? idPrefixes
        guard let prefixes, !prefixes.isEmpty else { return true }
        return prefixes.contains { id.hasPrefix($0) }
    }
}

/// An installed addon: its manifest plus where it was installed from.
public struct InstalledAddon: Codable, Hashable, Sendable, Identifiable {
    public var manifestURL: URL
    public var manifest: AddonManifest
    public var enabled: Bool

    public init(manifestURL: URL, manifest: AddonManifest, enabled: Bool = true) {
        self.manifestURL = manifestURL
        self.manifest = manifest
        self.enabled = enabled
    }

    public var id: String { manifestURL.absoluteString }

    /// The addon's base: the manifest URL without the trailing `/manifest.json`.
    public var baseURL: String {
        var s = manifestURL.absoluteString
        if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

public struct StremioStream: Codable, Hashable, Sendable, Identifiable {
    public struct BehaviorHints: Codable, Hashable, Sendable {
        public var bingeGroup: String?
        public var filename: String?
        public var notWebReady: Bool?
        public var videoSize: Int64?
    }

    public var name: String?
    public var title: String?
    public var description: String?
    public var url: String?
    public var infoHash: String?
    public var fileIdx: Int?
    public var ytId: String?
    public var externalUrl: String?
    public var behaviorHints: BehaviorHints?

    /// Filled in by the client after decoding: which addon returned it.
    public var addonName: String?

    public var id: String { [infoHash, url, ytId, externalUrl, title, name].compactMap { $0 }.joined(separator: "|") + "#\(fileIdx ?? -1)" }

    /// The free-text label addons use for quality/size/seeders, title first.
    public var label: String { description ?? title ?? "" }
    public var headline: String { name ?? addonName ?? "Stream" }

    public var magnet: String? {
        guard let infoHash, !infoHash.isEmpty else { return nil }
        return "magnet:?xt=urn:btih:\(infoHash)"
    }

    /// Best-effort size parsed from labels like "💾 12.3 GB".
    public var sizeBytes: Int64? {
        if let size = behaviorHints?.videoSize { return size }
        return StreamLabelParser.size(in: label)
    }

    public var quality: StreamQuality { StreamLabelParser.quality(in: "\(headline) \(label)") }
}

public enum StreamQuality: Int, Comparable, Sendable, CaseIterable {
    case unknown = 0, sd, hd720, hd1080, uhd2160

    public var label: String {
        switch self {
        case .unknown: return "?"
        case .sd: return "SD"
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .uhd2160: return "4K"
        }
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public enum StreamLabelParser {
    public static func quality(in text: String) -> StreamQuality {
        let t = text.lowercased()
        if t.contains("2160") || t.contains("4k") || t.contains("uhd") { return .uhd2160 }
        if t.contains("1080") { return .hd1080 }
        if t.contains("720") { return .hd720 }
        if t.contains("480") || t.contains("360") || t.contains(" sd") { return .sd }
        return .unknown
    }

    public static func size(in text: String) -> Int64? {
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(TB|GB|MB|KB)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let multiplier: Double
        switch text[unitRange].uppercased() {
        case "TB": multiplier = 1_099_511_627_776
        case "GB": multiplier = 1_073_741_824
        case "MB": multiplier = 1_048_576
        default: multiplier = 1024
        }
        return Int64(value * multiplier)
    }
}

/// Minimal Stremio meta preview/detail, for addon catalogs.
public struct StremioMeta: Codable, Hashable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var poster: String?
    public var background: String?
    public var description: String?
    public var releaseInfo: JSONValue?
    public var imdbRating: JSONValue?

    public var mediaItem: MediaItem {
        let kind: MediaKind = type == "movie" ? .movie : .series
        return MediaItem(
            kind: kind,
            imdbID: id.hasPrefix("tt") ? id : nil,
            title: name,
            year: releaseInfo?.stringValue.flatMap { Int($0.prefix(4)) },
            overview: description ?? "",
            posterURL: poster.flatMap(URL.init(string:)),
            backdropURL: background.flatMap(URL.init(string:)),
            rating: imdbRating?.stringValue.flatMap(Double.init)
        )
    }
}

public struct StremioMetaDetail: Codable, Hashable, Sendable {
    public struct Video: Codable, Hashable, Sendable {
        public var id: String
        public var title: String?
        public var name: String?
        public var season: Int?
        public var episode: Int?
        public var number: Int?
        public var thumbnail: String?
        public var overview: String?
        public var description: String?
        public var released: String?
    }

    public var meta: StremioMeta
    public var genres: [String]?
    public var runtime: String?
    public var videos: [Video]?

    enum CodingKeys: String, CodingKey { case genres, runtime, videos }

    public init(from decoder: Decoder) throws {
        meta = try StremioMeta(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
        runtime = try? c.decodeIfPresent(String.self, forKey: .runtime)
        videos = try? c.decodeIfPresent([Video].self, forKey: .videos)
    }

    public func encode(to encoder: Encoder) throws {
        try meta.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(videos, forKey: .videos)
    }

    /// Episodes grouped the way the detail page shows them. Season 0 (specials) is left out.
    public var episodes: [Episode] {
        (videos ?? []).compactMap { video in
            guard let season = video.season, season > 0, let number = video.episode ?? video.number else { return nil }
            return Episode(
                season: season, number: number,
                title: video.name ?? video.title ?? "Episode \(number)",
                overview: video.overview ?? video.description ?? "",
                stillURL: video.thumbnail.flatMap(URL.init(string:)),
                airDate: video.released.flatMap { ISO8601DateFormatter.flexible.date(from: $0) }
            )
        }
        .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }
}
