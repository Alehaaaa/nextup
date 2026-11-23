import Foundation

/// TorBox API v1 (https://api.torbox.app/v1/api).
public struct TorBoxClient: DebridProvider {
    public let service = DebridService.torbox
    private let base = "https://api.torbox.app/v1/api"
    private let apiKey: String
    private let http: HTTPClient

    public init(apiKey: String, http: HTTPClient = .shared) {
        self.apiKey = apiKey
        self.http = http
    }

    private var auth: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    struct Envelope<T: Decodable>: Decodable {
        let success: Bool?
        let error: String?
        let detail: String?
        let data: T?
    }

    public func account() async throws -> DebridAccount {
        struct User: Decodable { let email: String?; let plan: Int?; let premium_expires_at: String? }
        let response = try await http.json(Envelope<User>.self, "GET", try URL.build("\(base)/user/me"), headers: auth)
        guard let user = response.data else { throw DebridError.provider(response.detail ?? "TorBox did not return an account.") }
        let expiry = user.premium_expires_at.flatMap { ISO8601DateFormatter.flexible.date(from: $0) }
        return DebridAccount(username: user.email ?? "TorBox", premiumUntil: expiry, isPremium: (user.plan ?? 0) > 0)
    }

    struct Created: Decodable { let torrent_id: Int? }
    struct Torrent: Decodable {
        struct File: Decodable { let id: Int; let name: String?; let short_name: String?; let size: Int64? }
        let id: Int
        let download_finished: Bool?
        let download_present: Bool?
        let files: [File]?
    }

    public func resolve(magnet: String, hint: FileHint) async throws -> ResolvedStream {
        let (data, status) = try await http.data(
            "POST", try URL.build("\(base)/torrents/createtorrent"), headers: auth,
            body: .multipart(["magnet": magnet, "seed": "1", "allow_zip": "false", "add_only_if_cached": "true"])
        )
        let created = try? JSONDecoder().decode(Envelope<Created>.self, from: data)
        if created?.error == "DOWNLOAD_NOT_CACHED" { throw DebridError.notCached(service.displayName) }
        guard (200..<300).contains(status.statusCode), let id = created?.data?.torrent_id else {
            throw DebridError.provider(created?.detail ?? "TorBox could not add this source (\(status.statusCode)).")
        }

        var torrent: Torrent?
        for _ in 0..<8 {
            let response = try await http.json(Envelope<Torrent>.self, "GET",
                                               try URL.build("\(base)/torrents/mylist", query: ["id": String(id), "bypass_cache": "true"]),
                                               headers: auth)
            torrent = response.data
            if let t = torrent, !(t.files ?? []).isEmpty, t.download_present == true || t.download_finished == true { break }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        guard let torrent, let rawFiles = torrent.files, !rawFiles.isEmpty else { throw DebridError.notCached(service.displayName) }

        let files = rawFiles.map { TorrentFile(id: $0.id, path: $0.name ?? $0.short_name ?? "", bytes: $0.size ?? 0) }
        guard let file = FilePicker.pick(files, hint: hint) else { throw DebridError.noPlayableFile }

        let link = try await http.json(
            Envelope<String>.self, "GET",
            try URL.build("\(base)/torrents/requestdl", query: [
                "token": apiKey, "torrent_id": String(torrent.id), "file_id": String(file.id),
                "zip_link": "false", "redirect": "false",
            ]),
            headers: auth
        )
        guard let string = link.data, let url = URL(string: string) else {
            throw DebridError.provider(link.detail ?? "TorBox did not return a link.")
        }
        return ResolvedStream(url: url, filename: file.name, sizeBytes: file.bytes)
    }
}

extension ISO8601DateFormatter {
    /// Accepts timestamps with and without fractional seconds.
    static var flexible: FlexibleISO8601 { FlexibleISO8601() }
}

struct FlexibleISO8601 {
    func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

public enum DebridFactory {
    public static func provider(_ service: DebridService, secrets: SecretStoring) -> DebridProvider? {
        guard let key = secrets.string(for: service.secretKey), !key.isEmpty else { return nil }
        switch service {
        case .realDebrid: return RealDebridClient(apiKey: key)
        case .torbox: return TorBoxClient(apiKey: key)
        case .allDebrid: return AllDebridClient(apiKey: key)
        }
    }
}
