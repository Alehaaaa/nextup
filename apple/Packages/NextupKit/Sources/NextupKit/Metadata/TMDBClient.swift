import Foundation

/// TMDB v3 client authenticated with a v4 read access token (Bearer).
public struct TMDBClient: Sendable {
    public static let imageBase = "https://image.tmdb.org/t/p/"
    private let base = "https://api.themoviedb.org/3"
    private let token: @Sendable () -> String?
    private let http: HTTPClient
    public var language: String

    public init(http: HTTPClient = .shared, language: String = Locale.preferredLanguages.first ?? "en-US",
                token: @escaping @Sendable () -> String?) {
        self.http = http
        self.token = token
        self.language = language
    }

    public var isConfigured: Bool { !(token() ?? "").isEmpty }

    // MARK: Lists

    public enum ListKind: String, Sendable, CaseIterable {
        case trendingMovies, trendingSeries, popularMovies, popularSeries, topRatedMovies, topRatedSeries

        public var title: String {
            switch self {
            case .trendingMovies: return "Trending Movies"
            case .trendingSeries: return "Trending Shows"
            case .popularMovies: return "Popular Movies"
            case .popularSeries: return "Popular Shows"
            case .topRatedMovies: return "Top Rated Movies"
            case .topRatedSeries: return "Top Rated Shows"
            }
        }

        var path: String {
            switch self {
            case .trendingMovies: return "/trending/movie/week"
            case .trendingSeries: return "/trending/tv/week"
            case .popularMovies: return "/movie/popular"
            case .popularSeries: return "/tv/popular"
            case .topRatedMovies: return "/movie/top_rated"
            case .topRatedSeries: return "/tv/top_rated"
            }
        }

        var kind: MediaKind {
            switch self {
            case .trendingMovies, .popularMovies, .topRatedMovies: return .movie
            default: return .series
            }
        }
    }

    public func list(_ list: ListKind, page: Int = 1) async throws -> [MediaItem] {
        let response: Page<Title> = try await get(list.path, ["page": String(page)])
        return response.results.compactMap { $0.item(defaultKind: list.kind) }
    }

    public func search(_ query: String) async throws -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let response: Page<Title> = try await get("/search/multi", ["query": trimmed, "include_adult": "false"])
        return response.results.compactMap { $0.item(defaultKind: nil) }
    }

    // MARK: Detail

    public func detail(kind: MediaKind, tmdbID: Int) async throws -> MediaDetail {
        let raw: Detail = try await get(
            "/\(kind.tmdbPath)/\(tmdbID)",
            ["append_to_response": "external_ids,credits,videos,recommendations,images,release_dates,content_ratings",
             "include_image_language": "\(languageCode),en,null"]
        )
        var item = raw.asResult.item(defaultKind: kind) ?? MediaItem(kind: kind, tmdbID: tmdbID, title: "")
        item.imdbID = raw.imdb_id ?? raw.external_ids?.imdb_id
        let trailer = raw.videos?.results.first { $0.site == "YouTube" && $0.type == "Trailer" }
            ?? raw.videos?.results.first { $0.site == "YouTube" }
        var detail = MediaDetail(
            item: item,
            genres: raw.genres?.map(\.name) ?? [],
            runtimeMinutes: raw.runtime ?? raw.episode_run_time?.first,
            tagline: raw.tagline?.isEmpty == false ? raw.tagline : nil,
            seasons: (raw.seasons ?? [])
                .filter { $0.season_number > 0 }
                .map { SeasonSummary(number: $0.season_number, name: $0.name ?? "Season \($0.season_number)",
                                     episodeCount: $0.episode_count ?? 0, posterURL: Self.image($0.poster_path, "w342")) },
            cast: (raw.credits?.cast ?? []).prefix(20).map {
                CastMember(id: $0.id, name: $0.name, character: $0.character ?? "",
                           profileURL: Self.image($0.profile_path, "w185"))
            },
            trailerYouTubeKey: trailer?.key,
            similar: (raw.recommendations?.results ?? []).compactMap { $0.item(defaultKind: kind) }
        )
        let logos = raw.images?.logos ?? []
        let logo = logos.first { $0.iso_639_1 == languageCode } ?? logos.first { $0.iso_639_1 == "en" } ?? logos.first
        detail.logoURL = Self.image(logo?.file_path, "w500")
        let region = Locale.current.region?.identifier ?? "US"
        if kind == .movie {
            let entries = raw.release_dates?.results ?? []
            let pick = { (code: String) -> String? in
                entries.first { $0.iso_3166_1 == code }?.release_dates.compactMap { $0.certification?.isEmpty == false ? $0.certification : nil }.first
            }
            detail.certification = pick(region) ?? pick("US")
            detail.creators = (raw.credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)
            detail.writers = Array((raw.credits?.crew ?? []).filter { $0.department == "Writing" }.map(\.name).uniqued().prefix(3))
            detail.studios = (raw.production_companies ?? []).prefix(2).map(\.name)
        } else {
            let entries = raw.content_ratings?.results ?? []
            let pick = { (code: String) -> String? in entries.first { $0.iso_3166_1 == code && !($0.rating ?? "").isEmpty }?.rating }
            detail.certification = pick(region) ?? pick("US")
            detail.creators = (raw.created_by ?? []).map(\.name)
            detail.studios = (raw.networks ?? []).prefix(2).map(\.name)
            detail.episodeCount = raw.number_of_episodes
        }
        detail.status = raw.status
        detail.originalLanguage = raw.original_language.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
        detail.releaseDate = (raw.release_date ?? raw.first_air_date).flatMap(Self.dateFormatter.date(from:))
        detail.voteCount = raw.vote_count
        detail.budget = raw.budget.flatMap { $0 > 0 ? $0 : nil }
        detail.revenue = raw.revenue.flatMap { $0 > 0 ? $0 : nil }
        return detail
    }

    /// The title's logo image (a transparent "clear logo"), preferring the app language, then English.
    public func logo(kind: MediaKind, tmdbID: Int) async throws -> URL? {
        let images: Detail.Images = try await get("/\(kind.tmdbPath)/\(tmdbID)/images",
                                                  ["include_image_language": "\(languageCode),en,null"])
        let logos = images.logos ?? []
        let logo = logos.first { $0.iso_639_1 == languageCode } ?? logos.first { $0.iso_639_1 == "en" } ?? logos.first
        return Self.image(logo?.file_path, "w500")
    }

    /// "es" from "es-ES".
    var languageCode: String { String(language.prefix(while: { $0 != "-" })) }

    public func season(tmdbID: Int, number: Int) async throws -> [Episode] {
        let raw: SeasonDetail = try await get("/tv/\(tmdbID)/season/\(number)", [:])
        return raw.episodes.map {
            Episode(season: number, number: $0.episode_number, title: $0.name ?? "Episode \($0.episode_number)",
                    overview: $0.overview ?? "", stillURL: Self.image($0.still_path, "w300"),
                    airDate: $0.air_date.flatMap(Self.dateFormatter.date(from:)), runtimeMinutes: $0.runtime)
        }
    }

    public struct Video: Decodable, Hashable, Sendable {
        public let key: String
        public let name: String
        public let site: String
        public let type: String
        public let official: Bool?
    }

    /// YouTube videos for a title: clips, featurettes, teasers and trailers.
    public func videos(kind: MediaKind, tmdbID: Int) async throws -> [Video] {
        struct Response: Decodable { let results: [Video] }
        // Ask without a language so clips in the original language are included.
        let response: Response = try await get("/\(kind.tmdbPath)/\(tmdbID)/videos", ["include_video_language": "en,null"])
        return response.results.filter { $0.site == "YouTube" }
    }

    /// TMDB ids for a title page, adding the IMDb id (needed for streams).
    public func externalIMDbID(kind: MediaKind, tmdbID: Int) async throws -> String? {
        struct Response: Decodable { let imdb_id: String? }
        let response: Response = try await get("/\(kind.tmdbPath)/\(tmdbID)/external_ids", [:])
        return response.imdb_id
    }

    /// Resolves a TMDB id from an IMDb id (used for addon and tracker items).
    public func find(imdbID: String) async throws -> MediaItem? {
        let raw: FindResult = try await get("/find/\(imdbID)", ["external_source": "imdb_id"])
        var item = raw.movie_results.first?.item(defaultKind: .movie) ?? raw.tv_results.first?.item(defaultKind: .series)
        item?.imdbID = imdbID
        return item
    }

    // MARK: Plumbing

    public static func image(_ path: String?, _ size: String = "w500") -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: imageBase + size + path)
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func get<T: Decodable>(_ path: String, _ query: [String: String]) async throws -> T {
        guard let token = token(), !token.isEmpty else { throw HTTPError.notConfigured("TMDB") }
        var q: [String: String?] = query.mapValues { Optional($0) }
        q["language"] = language
        let url = try URL.build(base + path, query: q)
        return try await http.json(T.self, "GET", url, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/json",
        ])
    }

    // MARK: Wire types

    struct Page<T: Decodable>: Decodable { let results: [T] }

    struct Title: Decodable {
        let id: Int
        let media_type: String?
        let title: String?
        let name: String?
        let overview: String?
        let poster_path: String?
        let backdrop_path: String?
        let release_date: String?
        let first_air_date: String?
        let vote_average: Double?

        func item(defaultKind: MediaKind?) -> MediaItem? {
            let kind: MediaKind
            switch media_type {
            case "movie": kind = .movie
            case "tv": kind = .series
            case nil: guard let defaultKind else { return nil }; kind = defaultKind
            default: return nil // people
            }
            let date = kind == .movie ? release_date : first_air_date
            return MediaItem(
                kind: kind, tmdbID: id, title: title ?? name ?? "",
                year: date.flatMap { Int($0.prefix(4)) },
                overview: overview ?? "",
                posterURL: TMDBClient.image(poster_path, "w342"),
                backdropURL: TMDBClient.image(backdrop_path, "w1280"),
                rating: vote_average.flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    struct Detail: Decodable {
        struct Named: Decodable { let name: String }
        struct External: Decodable { let imdb_id: String? }
        struct Credits: Decodable {
            struct Cast: Decodable { let id: Int; let name: String; let character: String?; let profile_path: String? }
            struct Crew: Decodable { let name: String; let job: String?; let department: String? }
            let cast: [Cast]
            let crew: [Crew]?
        }
        struct Images: Decodable {
            struct Image: Decodable { let file_path: String; let iso_639_1: String? }
            let logos: [Image]?
        }
        struct ReleaseDates: Decodable {
            struct Country: Decodable {
                struct Entry: Decodable { let certification: String? }
                let iso_3166_1: String
                let release_dates: [Entry]
            }
            let results: [Country]
        }
        struct ContentRatings: Decodable {
            struct Rating: Decodable { let iso_3166_1: String; let rating: String? }
            let results: [Rating]
        }
        struct Videos: Decodable {
            struct Video: Decodable { let key: String; let site: String; let type: String }
            let results: [Video]
        }
        struct Season: Decodable { let season_number: Int; let name: String?; let episode_count: Int?; let poster_path: String? }

        let id: Int
        let title: String?
        let name: String?
        let overview: String?
        let poster_path: String?
        let backdrop_path: String?
        let release_date: String?
        let first_air_date: String?
        let vote_average: Double?
        let imdb_id: String?
        let genres: [Named]?
        let runtime: Int?
        let episode_run_time: [Int]?
        let tagline: String?
        let seasons: [Season]?
        let external_ids: External?
        let credits: Credits?
        let videos: Videos?
        let recommendations: Page<Title>?
        let images: Images?
        let release_dates: ReleaseDates?
        let content_ratings: ContentRatings?
        let created_by: [Named]?
        let networks: [Named]?
        let production_companies: [Named]?
        let status: String?
        let original_language: String?
        let vote_count: Int?
        let number_of_episodes: Int?
        let budget: Int?
        let revenue: Int?

        var asResult: Title {
            Title(id: id, media_type: nil, title: title, name: name, overview: overview, poster_path: poster_path,
                   backdrop_path: backdrop_path, release_date: release_date, first_air_date: first_air_date,
                   vote_average: vote_average)
        }
    }

    struct SeasonDetail: Decodable {
        struct Ep: Decodable {
            let episode_number: Int
            let name: String?
            let overview: String?
            let still_path: String?
            let air_date: String?
            let runtime: Int?
        }
        let episodes: [Ep]
    }

    struct FindResult: Decodable {
        let movie_results: [Title]
        let tv_results: [Title]
    }
}

extension Sequence where Element: Hashable {
    /// Keeps the first of each value, in order.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
