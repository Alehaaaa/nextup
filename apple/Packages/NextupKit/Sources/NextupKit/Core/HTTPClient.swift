import Foundation

public enum HTTPError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case status(Int, String)
    case decoding(String)
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid address: \(url)"
        case .status(let code, let body):
            let snippet = body.prefix(200)
            return "Server returned \(code)\(snippet.isEmpty ? "" : ": \(snippet)")"
        case .decoding(let what): return "Could not read the response (\(what))."
        case .notConfigured(let what): return "\(what) is not set up yet."
        }
    }
}

/// Thin async wrapper over `URLSession` shared by every API client.
public struct HTTPClient: Sendable {
    public var session: URLSession
    public var userAgent: String

    public init(session: URLSession = .shared, userAgent: String = "Nextup/1.0 (Apple)") {
        self.session = session
        self.userAgent = userAgent
    }

    public static let shared = HTTPClient()

    public enum Body: Sendable {
        case none
        case json(Data)
        case form([String: String])
        case multipart([String: String])
    }

    public func data(
        _ method: String = "GET",
        _ url: URL,
        headers: [String: String] = [:],
        body: Body = .none,
        timeout: TimeInterval = 20
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        switch body {
        case .none: break
        case .json(let data):
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .form(let fields):
            request.httpBody = Self.formEncode(fields).data(using: .utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case .multipart(let fields):
            let boundary = "nextup-\(UUID().uuidString)"
            var data = Data()
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                data.append(Data("--\(boundary)\r\n".utf8))
                data.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
                data.append(Data("\(value)\r\n".utf8))
            }
            data.append(Data("--\(boundary)--\r\n".utf8))
            request.httpBody = data
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.status(-1, "")
        }
        return (data, http)
    }

    /// Performs the request and decodes a 2xx JSON body.
    public func json<T: Decodable>(
        _ type: T.Type,
        _ method: String = "GET",
        _ url: URL,
        headers: [String: String] = [:],
        body: Body = .none,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let (data, response) = try await self.data(method, url, headers: headers, body: body)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw HTTPError.decoding(String(describing: T.self))
        }
    }

    /// Performs the request and only checks for a 2xx status.
    @discardableResult
    public func send(
        _ method: String,
        _ url: URL,
        headers: [String: String] = [:],
        body: Body = .none
    ) async throws -> Data {
        let (data, response) = try await self.data(method, url, headers: headers, body: body)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    public static func formEncode(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

public extension URL {
    /// Builds a URL from a base string plus query items, throwing instead of crashing.
    static func build(_ string: String, query: [String: String?] = [:]) throws -> URL {
        guard var components = URLComponents(string: string) else { throw HTTPError.invalidURL(string) }
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty {
            components.queryItems = (components.queryItems ?? []) + items.sorted { $0.name < $1.name }
        }
        guard let url = components.url else { throw HTTPError.invalidURL(string) }
        return url
    }
}

/// Decodes any JSON value, for API fields whose type varies between servers.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .number(let v): return v == v.rounded() ? String(Int(v)) : String(v)
        case .bool(let v): return String(v)
        default: return nil
        }
    }
}
