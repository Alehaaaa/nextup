import Foundation

/// Real-Debrid REST API v1 (https://api.real-debrid.com).
public struct RealDebridClient: DebridProvider {
    public let service = DebridService.realDebrid
    private let base = "https://api.real-debrid.com/rest/1.0"
    private let apiKey: String
    private let http: HTTPClient

    public init(apiKey: String, http: HTTPClient = .shared) {
        self.apiKey = apiKey
        self.http = http
    }

    private var auth: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    public func account() async throws -> DebridAccount {
        struct User: Decodable { let username: String; let type: String?; let expiration: String? }
        let user = try await http.json(User.self, "GET", try URL.build("\(base)/user"), headers: auth)
        let expiry = user.expiration.flatMap { ISO8601DateFormatter.flexible.date(from: $0) }
        return DebridAccount(username: user.username, premiumUntil: expiry, isPremium: user.type == "premium")
    }

    struct Added: Decodable { let id: String }
    struct Info: Decodable {
        struct File: Decodable { let id: Int; let path: String; let bytes: Int64; let selected: Int? }
        let id: String
        let status: String
        let progress: Double?
        let files: [File]?
        let links: [String]?
    }
    struct Unrestricted: Decodable { let download: String; let filename: String?; let filesize: Int64? }

    public func resolve(magnet: String, hint: FileHint) async throws -> ResolvedStream {
        let added = try await http.json(Added.self, "POST", try URL.build("\(base)/torrents/addMagnet"),
                                        headers: auth, body: .form(["magnet": magnet]))
        var info = try await torrentInfo(added.id)

        // Wait for RD to read the torrent's file list.
        var attempts = 0
        while info.status == "magnet_conversion" || (info.status == "queued" && (info.files ?? []).isEmpty) {
            attempts += 1
            if attempts > 10 { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            info = try await torrentInfo(added.id)
        }

        let files = (info.files ?? []).map { TorrentFile(id: $0.id, path: $0.path, bytes: $0.bytes) }
        guard let file = FilePicker.pick(files, hint: hint) else {
            try? await delete(added.id)
            throw DebridError.noPlayableFile
        }

        if info.status == "waiting_files_selection" || !(info.files ?? []).contains(where: { $0.id == file.id && $0.selected == 1 }) {
            try await http.send("POST", try URL.build("\(base)/torrents/selectFiles/\(added.id)"),
                                headers: auth, body: .form(["files": String(file.id)]))
        }

        // Cached torrents flip to "downloaded" within a moment; anything else is not instantly playable.
        for _ in 0..<6 {
            info = try await torrentInfo(added.id)
            if info.status == "downloaded" { break }
            if ["error", "magnet_error", "virus", "dead"].contains(info.status) {
                throw DebridError.provider("Real-Debrid could not load this source (\(info.status)).")
            }
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        guard info.status == "downloaded", let link = info.links?.first else {
            throw DebridError.notCached(service.displayName)
        }

        let unrestricted = try await http.json(Unrestricted.self, "POST", try URL.build("\(base)/unrestrict/link"),
                                               headers: auth, body: .form(["link": link]))
        guard let url = URL(string: unrestricted.download) else { throw HTTPError.invalidURL(unrestricted.download) }
        return ResolvedStream(url: url, filename: unrestricted.filename ?? file.name, sizeBytes: unrestricted.filesize ?? file.bytes)
    }

    func torrentInfo(_ id: String) async throws -> Info {
        try await http.json(Info.self, "GET", try URL.build("\(base)/torrents/info/\(id)"), headers: auth)
    }

    func delete(_ id: String) async throws {
        try await http.send("DELETE", try URL.build("\(base)/torrents/delete/\(id)"), headers: auth)
    }
}
