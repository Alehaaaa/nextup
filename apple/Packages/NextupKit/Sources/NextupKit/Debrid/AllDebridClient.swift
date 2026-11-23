import Foundation

/// AllDebrid API v4 (https://docs.alldebrid.com), the same calls the Flutter app makes:
/// magnet/upload (its `ready` flag is the cache check), magnet/files, link/unlock (+ link/delayed).
public struct AllDebridClient: DebridProvider {
    public let service = DebridService.allDebrid
    private let base = "https://api.alldebrid.com/v4"
    private let apiKey: String
    private let http: HTTPClient

    public init(apiKey: String, http: HTTPClient = .shared) {
        self.apiKey = apiKey
        self.http = http
    }

    private var auth: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { let code: String?; let message: String? }
        let status: String
        let data: T?
        let error: Failure?
    }

    private func call<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, form: [String: String] = [:]) async throws -> T {
        let (data, response) = try await http.data(method, try URL.build("\(base)/\(path)"), headers: auth,
                                                   body: form.isEmpty ? .none : .form(form), timeout: 30)
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw DebridError.provider("AllDebrid returned an invalid response (\(response.statusCode)).")
        }
        guard envelope.status == "success", let value = envelope.data else {
            throw DebridError.provider(envelope.error?.message ?? "AllDebrid request failed (\(response.statusCode)).")
        }
        return value
    }

    public func account() async throws -> DebridAccount {
        struct Response: Decodable {
            struct User: Decodable { let username: String?; let isPremium: Bool?; let premiumUntil: Double? }
            let user: User
        }
        let user = try await call(Response.self, "GET", "user").user
        let until = user.premiumUntil.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return DebridAccount(username: user.username ?? "AllDebrid", premiumUntil: until, isPremium: user.isPremium ?? false)
    }

    struct Uploaded: Decodable {
        struct Magnet: Decodable {
            struct Failure: Decodable { let message: String? }
            let id: Int?
            let ready: Bool?
            let error: Failure?
        }
        let magnets: [Magnet]
    }

    struct FilesResponse: Decodable {
        struct Magnet: Decodable { let files: [Node]? }
        let magnets: [Magnet]
    }

    /// A file (`n`, `s`, `l`) or a folder (`n`, `e`).
    struct Node: Decodable {
        let n: String?
        let s: Int64?
        let l: String?
        let e: [Node]?
    }

    struct Unlocked: Decodable { let link: String?; let filename: String?; let delayed: FlexibleString? }
    struct Delayed: Decodable { let status: Int?; let link: String? }

    public func resolve(magnet: String, hint: FileHint) async throws -> ResolvedStream {
        let uploaded = try await call(Uploaded.self, "POST", "magnet/upload", form: ["magnets[]": magnet])
        guard let entry = uploaded.magnets.first else { throw DebridError.provider("AllDebrid did not accept this source.") }
        if let message = entry.error?.message { throw DebridError.provider(message) }
        guard let id = entry.id else { throw DebridError.provider("AllDebrid did not return a magnet id.") }
        guard entry.ready == true else {
            // Not cached: remove it again so it does not queue a download on the account.
            _ = try? await call(EmptyData.self, "POST", "magnet/delete", form: ["id": String(id)])
            throw DebridError.notCached(service.displayName)
        }

        let tree = try await call(FilesResponse.self, "POST", "magnet/files", form: ["id[]": String(id)])
        var links: [String] = []
        var files: [TorrentFile] = []
        func flatten(_ nodes: [Node], _ parent: String) {
            for node in nodes {
                let path = parent.isEmpty ? (node.n ?? "") : "\(parent)/\(node.n ?? "")"
                if let children = node.e { flatten(children, path); continue }
                guard let link = node.l, !link.isEmpty else { continue }
                files.append(TorrentFile(id: links.count, path: path, bytes: node.s ?? 0))
                links.append(link)
            }
        }
        flatten(tree.magnets.first?.files ?? [], "")
        guard let file = FilePicker.pick(files, hint: FileHint(fileIndex: nil, filename: hint.filename,
                                                               season: hint.season, episode: hint.episode)) else {
            throw DebridError.noPlayableFile
        }

        let unlocked = try await call(Unlocked.self, "POST", "link/unlock", form: ["link": links[file.id]])
        var direct = unlocked.link ?? ""
        if direct.isEmpty, let delayed = unlocked.delayed?.value, delayed != "0" {
            for _ in 0..<12 where direct.isEmpty {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                let state = try await call(Delayed.self, "POST", "link/delayed", form: ["id": delayed])
                if state.status == 3 { throw DebridError.provider("AllDebrid could not prepare this file.") }
                if state.status == 2 { direct = state.link ?? "" }
            }
        }
        guard let url = URL(string: direct), !direct.isEmpty else { throw DebridError.provider("AllDebrid did not return a link.") }
        return ResolvedStream(url: url, filename: unlocked.filename ?? file.name, sizeBytes: file.bytes)
    }
}

struct EmptyData: Decodable {}

/// AllDebrid sends some ids as numbers and some as strings.
struct FlexibleString: Decodable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = String(int) } else { value = try container.decode(String.self) }
    }
}
