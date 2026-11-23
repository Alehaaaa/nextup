import Foundation

public struct TraktSession: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 24 * 3600 }
}

public struct TraktDeviceCode: Decodable, Hashable, Sendable {
    public let device_code: String
    public let user_code: String
    public let verification_url: String
    public let expires_in: Int
    public let interval: Int
}

public enum TraktPollResult: Sendable, Equatable {
    case authorized
    case pending
    case slowDown
    case expired
    case denied
}

/// Trakt API v2. Uses the same public client as the Flutter app so existing authorizations look the same.
public final class TraktClient: @unchecked Sendable {
    public static let clientID = "76697eeb2143258ec076134ed0a1d99fa075ef6e1e68263b00cd61e86540794b"
    static let clientSecret = "74f0994f0783dfb470645685dbf39675f0102fd66f475579ae1de7b2ec2bd466"
    private let base = "https://api.trakt.tv"
    private let http: HTTPClient
    private let secrets: SecretStoring
    private let lock = NSLock()

    public init(secrets: SecretStoring, http: HTTPClient = .shared) {
        self.secrets = secrets
        self.http = http
    }

    // MARK: Session

    public var session: TraktSession? {
        get {
            guard let raw = secrets.string(for: SecretKey.traktSession), let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(TraktSession.self, from: data)
        }
        set {
            let raw = newValue.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
            secrets.set(raw, for: SecretKey.traktSession)
        }
    }

    public var isSignedIn: Bool { session != nil }

    public func signOut() { session = nil }

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int
        let created_at: Int?
    }

    private func store(_ token: TokenResponse) {
        let created = token.created_at.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        session = TraktSession(accessToken: token.access_token, refreshToken: token.refresh_token,
                               expiresAt: created.addingTimeInterval(TimeInterval(token.expires_in)))
    }

    public func requestDeviceCode() async throws -> TraktDeviceCode {
        let body = try JSONSerialization.data(withJSONObject: ["client_id": Self.clientID])
        return try await http.json(TraktDeviceCode.self, "POST", try URL.build("\(base)/oauth/device/code"), body: .json(body))
    }

    public func poll(deviceCode: String) async throws -> TraktPollResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "code": deviceCode, "client_id": Self.clientID, "client_secret": Self.clientSecret,
        ])
        let (data, response) = try await http.data("POST", try URL.build("\(base)/oauth/device/token"), body: .json(body))
        switch response.statusCode {
        case 200:
            store(try JSONDecoder().decode(TokenResponse.self, from: data))
            return .authorized
        case 400: return .pending
        case 429: return .slowDown
        case 410, 404: return .expired
        case 418: return .denied
        default: throw HTTPError.status(response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    private func refreshIfNeeded() async throws -> String {
        guard let current = session else { throw HTTPError.notConfigured("Trakt") }
        guard current.needsRefresh else { return current.accessToken }
        let body = try JSONSerialization.data(withJSONObject: [
            "refresh_token": current.refreshToken, "client_id": Self.clientID, "client_secret": Self.clientSecret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token",
        ])
        let token = try await http.json(TokenResponse.self, "POST", try URL.build("\(base)/oauth/token"), body: .json(body))
        store(token)
        return token.access_token
    }

    private func headers() async throws -> [String: String] {
        [
            "Authorization": "Bearer \(try await refreshIfNeeded())",
            "trakt-api-version": "2",
            "trakt-api-key": Self.clientID,
        ]
    }

    // MARK: Data

    public struct IDs: Codable, Hashable, Sendable { public var trakt: Int?; public var imdb: String?; public var tmdb: Int? }
    public struct Title: Codable, Hashable, Sendable { public var title: String; public var year: Int?; public var ids: IDs }
    public struct EpisodeRef: Codable, Hashable, Sendable { public var season: Int; public var number: Int; public var title: String?; public var ids: IDs? }

    public struct PlaybackItem: Decodable, Hashable, Sendable {
        public var id: Int
        public var progress: Double
        public var paused_at: Date?
        public var type: String
        public var movie: Title?
        public var show: Title?
        public var episode: EpisodeRef?
    }

    /// Paused playback across devices ("Continue Watching" on Trakt).
    public func playback() async throws -> [PlaybackItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            return ISO8601DateFormatter.flexible.date(from: s) ?? Date()
        }
        return try await http.json([PlaybackItem].self, "GET", try URL.build("\(base)/sync/playback"),
                                   headers: try await headers(), decoder: decoder)
    }

    public struct WatchlistItem: Decodable, Hashable, Sendable {
        public var type: String
        public var movie: Title?
        public var show: Title?
    }

    public func watchlist() async throws -> [WatchlistItem] {
        try await http.json([WatchlistItem].self, "GET", try URL.build("\(base)/sync/watchlist"), headers: try await headers())
    }

    public enum ScrobbleAction: String, Sendable { case start, pause, stop }

    /// Reports playback. `progress` is 0…100. Trakt marks the item watched on `stop` above 80%.
    public func scrobble(_ action: ScrobbleAction, item: MediaItem, episode: (season: Int, number: Int)?, progress: Double) async throws {
        var payload: [String: Any] = ["progress": max(0, min(100, progress))]
        var ids: [String: Any] = [:]
        if let imdb = item.imdbID { ids["imdb"] = imdb }
        if let tmdb = item.tmdbID { ids["tmdb"] = tmdb }
        if let episode, item.kind == .series {
            payload["show"] = ["title": item.title, "ids": ids]
            payload["episode"] = ["season": episode.season, "number": episode.number]
        } else {
            payload["movie"] = ["title": item.title, "ids": ids]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        try await http.send("POST", try URL.build("\(base)/scrobble/\(action.rawValue)"), headers: try await headers(), body: .json(body))
    }
}
