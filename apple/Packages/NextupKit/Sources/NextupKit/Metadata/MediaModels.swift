import Foundation

public enum MediaKind: String, Codable, Hashable, Sendable, CaseIterable {
    case movie
    case series

    /// The type string used by Stremio addons.
    public var stremioType: String { self == .movie ? "movie" : "series" }
    var tmdbPath: String { self == .movie ? "movie" : "tv" }
}

/// One title, regardless of where it came from (TMDB, an addon catalog, a tracker).
public struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    public var kind: MediaKind
    public var tmdbID: Int?
    public var imdbID: String?
    public var title: String
    public var year: Int?
    public var overview: String
    public var posterURL: URL?
    public var backdropURL: URL?
    public var rating: Double?

    public init(
        kind: MediaKind, tmdbID: Int? = nil, imdbID: String? = nil, title: String, year: Int? = nil,
        overview: String = "", posterURL: URL? = nil, backdropURL: URL? = nil, rating: Double? = nil
    ) {
        self.kind = kind
        self.tmdbID = tmdbID
        self.imdbID = imdbID
        self.title = title
        self.year = year
        self.overview = overview
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.rating = rating
    }

    /// Stable identity: IMDb id when known (what addons and trackers key on), TMDB id otherwise.
    public var id: String {
        if let imdbID { return "\(kind.rawValue):\(imdbID)" }
        if let tmdbID { return "\(kind.rawValue):tmdb:\(tmdbID)" }
        return "\(kind.rawValue):title:\(title.lowercased()):\(year ?? 0)"
    }
}

public struct Episode: Identifiable, Hashable, Codable, Sendable {
    public var season: Int
    public var number: Int
    public var title: String
    public var overview: String
    public var stillURL: URL?
    public var airDate: Date?
    public var runtimeMinutes: Int?

    public init(season: Int, number: Int, title: String, overview: String = "", stillURL: URL? = nil,
                airDate: Date? = nil, runtimeMinutes: Int? = nil) {
        self.season = season
        self.number = number
        self.title = title
        self.overview = overview
        self.stillURL = stillURL
        self.airDate = airDate
        self.runtimeMinutes = runtimeMinutes
    }

    public var id: String { "S\(season)E\(number)" }
    public var code: String { String(format: "S%02dE%02d", season, number) }
}

public struct SeasonSummary: Identifiable, Hashable, Codable, Sendable {
    public var number: Int
    public var name: String
    public var episodeCount: Int
    public var posterURL: URL?
    public var id: Int { number }

    public init(number: Int, name: String, episodeCount: Int, posterURL: URL? = nil) {
        self.number = number
        self.name = name
        self.episodeCount = episodeCount
        self.posterURL = posterURL
    }
}

public struct CastMember: Identifiable, Hashable, Codable, Sendable {
    public var id: Int
    public var name: String
    public var character: String
    public var profileURL: URL?

    public init(id: Int, name: String, character: String, profileURL: URL? = nil) {
        self.id = id
        self.name = name
        self.character = character
        self.profileURL = profileURL
    }
}

public struct MediaDetail: Hashable, Codable, Sendable {
    public var item: MediaItem
    public var genres: [String]
    public var runtimeMinutes: Int?
    public var tagline: String?
    public var seasons: [SeasonSummary]
    public var cast: [CastMember]
    public var trailerYouTubeKey: String?
    public var similar: [MediaItem]
    /// The title's logo (TMDB "clear logo"), drawn instead of plain text in the title page header.
    public var logoURL: URL?
    /// Age rating for the user's region, else the US one ("PG-13", "TV-MA").
    public var certification: String?
    /// "Returning Series", "Ended", "Released"…
    public var status: String?
    /// Directors for movies, creators for shows.
    public var creators: [String] = []
    public var writers: [String] = []
    /// Studios for movies, networks for shows.
    public var studios: [String] = []
    public var originalLanguage: String?
    public var releaseDate: Date?
    public var voteCount: Int?
    public var episodeCount: Int?
    public var budget: Int?
    public var revenue: Int?

    public init(item: MediaItem, genres: [String] = [], runtimeMinutes: Int? = nil, tagline: String? = nil,
                seasons: [SeasonSummary] = [], cast: [CastMember] = [], trailerYouTubeKey: String? = nil,
                similar: [MediaItem] = []) {
        self.item = item
        self.genres = genres
        self.runtimeMinutes = runtimeMinutes
        self.tagline = tagline
        self.seasons = seasons
        self.cast = cast
        self.trailerYouTubeKey = trailerYouTubeKey
        self.similar = similar
    }
}

/// A row on the Home board.
public struct MediaRail: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var items: [MediaItem]

    public init(id: String, title: String, items: [MediaItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}
