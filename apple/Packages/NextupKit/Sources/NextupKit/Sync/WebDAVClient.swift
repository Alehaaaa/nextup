import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Where a WebDAV account lives. The presets match the Flutter app's sign-in screen.
public enum WebDAVPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case pCloudEU, pCloudUS, koofr, custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pCloudEU: return "pCloud (Europe)"
        case .pCloudUS: return "pCloud (United States)"
        case .koofr: return "Koofr"
        case .custom: return "Other WebDAV server"
        }
    }

    public var endpoint: URL? {
        switch self {
        case .pCloudEU: return URL(string: "https://ewebdav.pcloud.com/")
        case .pCloudUS: return URL(string: "https://webdav.pcloud.com/")
        case .koofr: return URL(string: "https://app.koofr.net/dav/Koofr/")
        case .custom: return nil
        }
    }
}

/// The saved sign-in. The password goes to the Keychain; the rest to UserDefaults.
public struct WebDAVAccount: Codable, Hashable, Sendable {
    public var preset: WebDAVPreset
    public var customURL: String
    public var username: String
    /// Folder that holds the Flutter app's `debrify-sync` and the native `nextup-native` folders.
    public var folder: String

    public init(preset: WebDAVPreset = .pCloudEU, customURL: String = "", username: String = "", folder: String = "Debrify") {
        self.preset = preset
        self.customURL = customURL
        self.username = username
        self.folder = folder
    }

    public var endpoint: URL? {
        if let url = preset.endpoint { return url }
        var raw = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, !raw.contains("://") { raw = "https://" + raw }
        if !raw.hasSuffix("/") { raw += "/" }
        return URL(string: raw)
    }
}

public enum WebDAVError: Error, LocalizedError, Sendable {
    case notConfigured
    case unauthorized
    case notFound(String)
    case status(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add a WebDAV account first."
        case .unauthorized: return "The server did not accept this username and password."
        case .notFound(let path): return "Nothing found at \(path)."
        case .status(let code, let path): return "The server returned \(code) for \(path)."
        }
    }
}

/// The few WebDAV verbs sync needs: PROPFIND (list), GET, PUT and MKCOL.
public struct WebDAVClient: Sendable {
    public let endpoint: URL
    let authorization: String
    let session: URLSession

    public init(endpoint: URL, username: String, password: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        self.session = session
    }

    public init(account: WebDAVAccount, password: String) throws {
        guard let endpoint = account.endpoint, !account.username.isEmpty, !password.isEmpty else {
            throw WebDAVError.notConfigured
        }
        self.init(endpoint: endpoint, username: account.username, password: password)
    }

    public func url(_ path: String, collection: Bool = false) -> URL {
        let segments = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0)
        }
        let joined = segments.joined(separator: "/") + (collection && !segments.isEmpty ? "/" : "")
        return URL(string: joined, relativeTo: endpoint)?.absoluteURL ?? endpoint
    }

    private func send(_ method: String, _ path: String, collection: Bool = false, body: Data? = nil,
                      headers: [String: String] = [:]) async throws -> (Data, Int) {
        var request = URLRequest(url: url(path, collection: collection), timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("Nextup/1.0 (Apple)", forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 || status == 403 { throw WebDAVError.unauthorized }
        return (data, status)
    }

    /// Checks the sign-in by listing the endpoint itself.
    public func verify() async throws {
        let (_, status) = try await send("PROPFIND", "", collection: true, body: Self.propfindBody,
                                         headers: ["Depth": "0", "Content-Type": "application/xml"])
        guard (200..<300).contains(status) else { throw WebDAVError.status(status, endpoint.host ?? "") }
    }

    public func get(_ path: String) async throws -> Data {
        let (data, status) = try await send("GET", path)
        if status == 404 { throw WebDAVError.notFound(path) }
        guard (200..<300).contains(status) else { throw WebDAVError.status(status, path) }
        return data
    }

    public func getIfPresent(_ path: String) async throws -> Data? {
        do { return try await get(path) } catch WebDAVError.notFound { return nil }
    }

    public func put(_ path: String, data: Data) async throws {
        let (_, status) = try await send("PUT", path, body: data, headers: ["Content-Type": "application/octet-stream"])
        guard (200..<300).contains(status) else { throw WebDAVError.status(status, path) }
    }

    /// Creates every missing folder along the path.
    public func makeFolders(_ path: String) async throws {
        var current = ""
        for segment in path.split(separator: "/") {
            current += (current.isEmpty ? "" : "/") + segment
            let (_, status) = try await send("MKCOL", current, collection: true)
            // 405: already exists. Some servers answer 409/301 for existing folders too.
            guard (200..<300).contains(status) || [301, 405, 409].contains(status) else {
                throw WebDAVError.status(status, current)
            }
        }
    }

    /// Names of the direct children of a folder (files and folders, without the folder itself).
    public func list(_ path: String) async throws -> [String] {
        let (data, status) = try await send("PROPFIND", path, collection: true, body: Self.propfindBody,
                                            headers: ["Depth": "1", "Content-Type": "application/xml"])
        if status == 404 { throw WebDAVError.notFound(path) }
        guard (200..<300).contains(status) else { throw WebDAVError.status(status, path) }
        let own = url(path, collection: true).path
        let parser = HrefParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        xml.shouldProcessNamespaces = true
        xml.parse()
        return parser.hrefs.compactMap { href -> String? in
            let target = URL(string: href, relativeTo: endpoint)?.path ?? href
            let trimmed = target.hasSuffix("/") ? String(target.dropLast()) : target
            let ownTrimmed = own.hasSuffix("/") ? String(own.dropLast()) : own
            guard trimmed != ownTrimmed, let name = trimmed.split(separator: "/").last else { return nil }
            return String(name).removingPercentEncoding ?? String(name)
        }
    }

    static let propfindBody = Data(#"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>"#.utf8)

    private final class HrefParser: NSObject, XMLParserDelegate {
        var hrefs: [String] = []
        private var text: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "href" { text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text? += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "href", let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                hrefs.append(value)
            }
            if elementName == "href" { text = nil }
        }
    }
}
