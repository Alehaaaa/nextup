import Foundation

public struct SkipSegment: Hashable, Sendable {
    public enum Kind: String, Sendable { case intro, outro }
    public var kind: Kind
    public var start: Double
    public var end: Double

    public init(kind: Kind, start: Double, end: Double) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    public func contains(_ position: Double) -> Bool { position >= start && position < end }
}

public struct SkipSegments: Hashable, Sendable {
    public var intros: [SkipSegment]
    public var outros: [SkipSegment]

    public init(intros: [SkipSegment] = [], outros: [SkipSegment] = []) {
        self.intros = intros
        self.outros = outros
    }

    public static let empty = SkipSegments()
    public var isEmpty: Bool { intros.isEmpty && outros.isEmpty }
}

/// Intro and credits times from the same community databases as the Flutter app
/// (SkipDB, TheIntroDB, IntroDB), asked together; the first answer per kind wins in that order.
public struct SkipSegmentsClient: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = .shared) { self.http = http }

    /// Credits must start in the last 10% to count, so a bad entry never skips the episode.
    static let minimumOutroFraction = 0.9

    public func fetch(imdbID: String, season: Int, episode: Int, duration: Double) async -> SkipSegments {
        async let first = skipDB(imdbID, season, episode, duration)
        async let second = theIntroDB(imdbID, season, episode, duration)
        async let third = introDB(imdbID, season, episode, duration)
        let results = [await first, await second, await third]
        var intros: [SkipSegment] = [], outros: [SkipSegment] = []
        for result in results {
            if intros.isEmpty { intros = result.intros }
            if outros.isEmpty { outros = result.outros }
        }
        return SkipSegments(intros: intros, outros: outros)
    }

    private func object(_ base: String, _ query: [String: String?]) async -> [String: JSONValue]? {
        guard let url = try? URL.build(base, query: query) else { return nil }
        let result = try? await http.data("GET", url, headers: ["Accept": "application/json"], timeout: 4)
        guard let result, result.1.statusCode == 200,
              case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: result.0) else { return nil }
        return object
    }

    private func skipDB(_ imdb: String, _ s: Int, _ e: Int, _ duration: Double) async -> SkipSegments {
        guard let root = await object("https://api.skipdb.tv/api/segments", [
            "imdb_id": imdb, "season": String(s), "episode": String(e),
            "duration": duration > 0 ? String(Int(duration)) : nil,
        ]), case .object(let segments)? = root["segments"] else { return .empty }
        func parse(_ key: String, _ kind: SkipSegment.Kind) -> [SkipSegment] {
            guard case .object(let value)? = segments[key], value["match"]?.stringValue != "out-of-range" else { return [] }
            return Self.bounded(value, kind: kind, duration: duration).map { [$0] } ?? []
        }
        return SkipSegments(intros: parse("intro", .intro), outros: parse("outro", .outro))
    }

    private func introDB(_ imdb: String, _ s: Int, _ e: Int, _ duration: Double) async -> SkipSegments {
        guard let root = await object("https://api.introdb.app/segments", [
            "imdb_id": imdb, "season": String(s), "episode": String(e),
        ]) else { return .empty }
        func parse(_ key: String, _ kind: SkipSegment.Kind) -> [SkipSegment] {
            guard case .object(let value)? = root[key] else { return [] }
            return Self.bounded(value, kind: kind, duration: duration).map { [$0] } ?? []
        }
        return SkipSegments(intros: parse("intro", .intro), outros: parse("outro", .outro))
    }

    private func theIntroDB(_ imdb: String, _ s: Int, _ e: Int, _ duration: Double) async -> SkipSegments {
        guard let root = await object("https://api.theintrodb.org/v4/media", [
            "imdb_id": imdb, "season": String(s), "episode": String(e),
            "duration_ms": duration > 0 ? String(Int(duration * 1000)) : nil,
        ]) else { return .empty }
        func parse(_ key: String, _ kind: SkipSegment.Kind, startAtZero: Bool, endAtEnd: Bool) -> [SkipSegment] {
            guard case .array(let values)? = root[key] else { return [] }
            return values.compactMap { value in
                guard case .object(let object) = value else { return nil }
                return Self.bounded(object, kind: kind, duration: duration, nullStartAtZero: startAtZero, nullEndAtEnd: endAtEnd)
            }
            .sorted { $0.start < $1.start }
        }
        return SkipSegments(intros: parse("intro", .intro, startAtZero: true, endAtEnd: false),
                            outros: parse("credits", .outro, startAtZero: false, endAtEnd: true))
    }

    /// Validates `start_ms` / `end_ms` against the real duration (seconds).
    static func bounded(_ value: [String: JSONValue], kind: SkipSegment.Kind, duration: Double,
                        nullStartAtZero: Bool = false, nullEndAtEnd: Bool = false) -> SkipSegment? {
        guard duration > 0, value.keys.contains("start_ms"), value.keys.contains("end_ms") else { return nil }
        func ms(_ key: String) -> Double? {
            switch value[key] {
            case .number(let n)?: return n
            case .string(let s)?: return Double(s)
            default: return nil
            }
        }
        let durationMs = duration * 1000
        let start = (value["start_ms"] == .null && nullStartAtZero) ? 0 : ms("start_ms")
        let end = (value["end_ms"] == .null && nullEndAtEnd) ? durationMs : ms("end_ms")
        guard let start, let end, start >= 0, end > start, start < durationMs, end <= durationMs else { return nil }
        if kind == .outro, start < durationMs * minimumOutroFraction { return nil }
        return SkipSegment(kind: kind, start: start / 1000, end: end / 1000)
    }
}
