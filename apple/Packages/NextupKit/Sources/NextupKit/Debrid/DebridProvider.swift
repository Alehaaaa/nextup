import Foundation

public enum DebridService: String, Codable, CaseIterable, Sendable, Identifiable {
    case realDebrid
    case torbox
    case allDebrid

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .torbox: return "TorBox"
        case .allDebrid: return "AllDebrid"
        }
    }

    public var secretKey: String {
        switch self {
        case .realDebrid: return SecretKey.realDebridToken
        case .torbox: return SecretKey.torboxToken
        case .allDebrid: return SecretKey.allDebridToken
        }
    }

    public var apiKeyPageURL: URL {
        switch self {
        case .realDebrid: return URL(string: "https://real-debrid.com/apitoken")!
        case .torbox: return URL(string: "https://torbox.app/settings")!
        case .allDebrid: return URL(string: "https://alldebrid.com/apikeys/")!
        }
    }
}

public struct DebridAccount: Hashable, Sendable {
    public var username: String
    public var premiumUntil: Date?
    public var isPremium: Bool

    public init(username: String, premiumUntil: Date?, isPremium: Bool) {
        self.username = username
        self.premiumUntil = premiumUntil
        self.isPremium = isPremium
    }
}

/// What the player should open, after a provider has turned a torrent into a link.
public struct ResolvedStream: Hashable, Sendable {
    public var url: URL
    public var filename: String?
    public var sizeBytes: Int64?

    public init(url: URL, filename: String? = nil, sizeBytes: Int64? = nil) {
        self.url = url
        self.filename = filename
        self.sizeBytes = sizeBytes
    }
}

/// Hints used to pick the right file inside a multi-file torrent (season packs).
public struct FileHint: Hashable, Sendable {
    public var fileIndex: Int?
    public var filename: String?
    public var season: Int?
    public var episode: Int?

    public init(fileIndex: Int? = nil, filename: String? = nil, season: Int? = nil, episode: Int? = nil) {
        self.fileIndex = fileIndex
        self.filename = filename
        self.season = season
        self.episode = episode
    }
}

public enum DebridError: Error, LocalizedError, Sendable {
    case notCached(String)
    case noPlayableFile
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .notCached(let service): return "This source is not cached on \(service) yet. Try another source."
        case .noPlayableFile: return "No playable video file was found in this source."
        case .provider(let message): return message
        }
    }
}

public protocol DebridProvider: Sendable {
    var service: DebridService { get }
    func account() async throws -> DebridAccount
    func resolve(magnet: String, hint: FileHint) async throws -> ResolvedStream
}

/// A file inside a torrent, as seen by any provider.
public struct TorrentFile: Hashable, Sendable {
    public var id: Int
    public var path: String
    public var bytes: Int64

    public init(id: Int, path: String, bytes: Int64) {
        self.id = id
        self.path = path
        self.bytes = bytes
    }

    public var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

public enum FilePicker {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "wmv", "flv", "mpg", "mpeg"]

    public static func isVideo(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }

    /// Chooses the file to play: exact filename, then episode match, then the addon's index, then the largest video.
    public static func pick(_ files: [TorrentFile], hint: FileHint) -> TorrentFile? {
        let videos = files.filter { isVideo($0.path) && !$0.path.lowercased().contains("sample") }
        let pool = videos.isEmpty ? files.filter { isVideo($0.path) } : videos
        guard !pool.isEmpty else { return nil }

        if let name = hint.filename?.lowercased(), let match = pool.first(where: { $0.name.lowercased() == name }) {
            return match
        }
        if let season = hint.season, let episode = hint.episode {
            let matches = pool.filter { EpisodeMatcher.matches($0.name, season: season, episode: episode) }
            if let best = matches.max(by: { $0.bytes < $1.bytes }) { return best }
        }
        if let index = hint.fileIndex, files.indices.contains(index), isVideo(files[index].path) {
            return files[index]
        }
        return pool.max(by: { $0.bytes < $1.bytes })
    }
}

public enum EpisodeMatcher {
    /// Matches S01E02, 1x02 and "Season 1 Episode 2" style names.
    public static func matches(_ name: String, season: Int, episode: Int) -> Bool {
        let patterns = [
            #"s0*\#(season)[ ._-]*e0*\#(episode)(?!\d)"#,
            #"(?<!\d)0*\#(season)x0*\#(episode)(?!\d)"#,
            #"season[ ._-]*0*\#(season)[ ._-]*episode[ ._-]*0*\#(episode)(?!\d)"#,
        ]
        let range = NSRange(name.startIndex..., in: name)
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: name, range: range) != nil
        }
    }
}
