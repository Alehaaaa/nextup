import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One torrent found by a provider.
public struct TorrentResult: Hashable, Sendable, Identifiable {
    public var infoHash: String
    public var name: String
    public var sizeBytes: Int64?
    public var seeders: Int?
    public var leechers: Int?
    public var uploaded: Date?
    public var engine: String

    public var id: String { infoHash }

    /// As an addon-style stream, so it flows through the same list, badges, debrid and downloads.
    public var stream: StremioStream {
        var lines = [name]
        var stats: [String] = []
        if let seeders { stats.append("👤 \(seeders)") }
        if let size = sizeBytes, size > 0 {
            stats.append("💾 " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if !stats.isEmpty { lines.append(stats.joined(separator: " ")) }
        var stream = StremioStream()
        stream.name = engine
        stream.title = lines.joined(separator: "\n")
        stream.infoHash = infoHash
        stream.addonName = engine
        if let sizeBytes, sizeBytes > 0 {
            stream.behaviorHints = StremioStream.BehaviorHints(bingeGroup: nil, filename: nil, notWebReady: nil, videoSize: sizeBytes)
        }
        return stream
    }
}

/// What to look for.
public struct TorrentQuery: Hashable, Sendable {
    public var imdbID: String?
    public var keyword: String?
    public var isSeries: Bool
    public var season: Int?
    public var episode: Int?

    public init(imdbID: String? = nil, keyword: String? = nil, isSeries: Bool = false, season: Int? = nil, episode: Int? = nil) {
        self.imdbID = imdbID
        self.keyword = keyword
        self.isSeries = isSeries
        self.season = season
        self.episode = episode
    }
}

/// A provider described by one of the Flutter app's engine YAML files
/// (gitlab.com/mediacontent/search-engines), run natively.
public struct TorrentEngine: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let keywordSearch: Bool
    public let imdbSearch: Bool
    public let seriesSupport: Bool
    let config: ConfigBox

    final class ConfigBox: @unchecked Sendable {
        let value: [String: Any]
        init(_ value: [String: Any]) { self.value = value }
    }

    public enum Failure: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self { case .invalid(let why): return "This provider file is not valid (\(why))." }
        }
    }

    public init(yaml: String) throws {
        guard let root = try MiniYAML.parse(yaml) as? [String: Any] else { throw Failure.invalid("not a map") }
        guard let id = root["id"] as? String, !id.isEmpty else { throw Failure.invalid("no id") }
        self.id = id
        displayName = root["display_name"] as? String ?? id
        let caps = root["capabilities"] as? [String: Any] ?? [:]
        keywordSearch = caps["keyword_search"] as? Bool ?? false
        imdbSearch = caps["imdb_search"] as? Bool ?? false
        seriesSupport = caps["series_support"] as? Bool ?? false
        config = ConfigBox(root)
        guard api["urls"] != nil || api["base_url"] != nil else { throw Failure.invalid("no address") }
    }

    private var root: [String: Any] { config.value }
    private var api: [String: Any] { root["api"] as? [String: Any] ?? [:] }

    /// The "Maximum Results" default from the file's settings, if it has one.
    public var maxResults: Int? {
        (root["settings"] as? [[String: Any]])?.first { $0["id"] as? String == "max_results" }?["default"] as? Int
    }

    public var supportsTitles: Bool { imdbSearch || keywordSearch }

    // MARK: Searching

    public func search(_ query: TorrentQuery, http: HTTPClient = .shared) async throws -> [TorrentResult] {
        let type: String
        if let imdb = query.imdbID, !imdb.isEmpty, imdbSearch {
            type = query.isSeries && urls["series"] != nil ? "series" : "imdb"
        } else if let keyword = query.keyword, !keyword.isEmpty, keywordSearch {
            type = "keyword"
        } else {
            return []
        }
        let pagination = root["pagination"] as? [String: Any] ?? [:]
        let paging = pagination["type"] as? String ?? "none"
        let maxPages = paging == "none" ? 1 : min(pagination["max_pages"] as? Int ?? 1, 3)
        let limit = maxResults ?? 100

        var results: [TorrentResult] = []
        var seen = Set<String>()
        var cursor: String?
        for page in 0..<maxPages {
            let (data, _) = try await request(type: type, query: query, page: page, cursor: cursor, http: http)
            guard let payload = decode(data, type: type) else { break }
            if !passesChecks(payload) { break }
            let items = extractItems(payload, type: type)
            for item in items {
                guard let result = map(item), seen.insert(result.infoHash).inserted else { continue }
                results.append(result)
            }
            if results.count >= limit || items.isEmpty { break }
            var more = false
            switch paging {
            case "cursor":
                let field = pagination["cursor_field"] as? String ?? "next"
                cursor = Self.value(at: field, in: payload).flatMap(Self.string)
                more = !(cursor ?? "").isEmpty
            case "page":
                if let flag = pagination["has_more_field"] as? String {
                    more = Self.value(at: flag, in: payload) as? Bool == true
                } else {
                    more = items.count >= (pagination["page_size"] as? Int ?? items.count)
                }
            case "offset":
                more = items.count >= (pagination["results_per_page"] as? Int ?? items.count)
            default:
                more = false
            }
            if !more { break }
        }
        return Array(results.prefix(limit))
    }

    private var urls: [String: Any] { api["urls"] as? [String: Any] ?? [:] }

    private func baseURL(type: String, query: TorrentQuery) -> String? {
        if type != "keyword" {
            if query.isSeries, let url = urls["series"] as? String { return url }
            if !query.isSeries, let url = urls["movie"] as? String { return url }
            if let url = urls["imdb"] as? String { return url }
        }
        if type == "keyword", let url = urls["keyword"] as? String { return url }
        return api["base_url"] as? String
    }

    private func request(type: String, query: TorrentQuery, page: Int, cursor: String?, http: HTTPClient) async throws -> (Data, HTTPURLResponse) {
        guard var address = baseURL(type: type, query: query) else { throw Failure.invalid("no address for \(type)") }
        let mainValue = type == "keyword" ? (query.keyword ?? "") : (query.imdbID ?? "")
        let replacements: [String: String] = [
            "imdb_id": query.imdbID ?? "", "imdbId": query.imdbID ?? "", "query": mainValue,
            "season": query.season.map(String.init) ?? "1", "episode": query.episode.map(String.init) ?? "1",
        ]
        for (key, value) in replacements {
            address = address.replacingOccurrences(of: "{\(key)}",
                                                   with: value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value)
        }
        let method = (api["method"] as? String ?? "GET").uppercased()
        var queryItems: [String: String] = [:]
        var body: [String: Any] = [:]

        // Fixed and query-sourced parameters.
        let fixed = (api["params"] as? [[String: Any]] ?? [])
        for param in fixed {
            guard let name = param["name"] as? String else { continue }
            let value: Any?
            if let source = param["source"] as? String {
                value = source == "query" ? mainValue : nil
            } else {
                value = param["value"]
            }
            guard let raw = value.flatMap(Self.string), !raw.isEmpty else { continue }
            if param["location"] as? String == "body" {
                switch param["value_type"] as? String {
                case "int": body[name] = Int(raw) ?? raw
                case "bool": body[name] = raw == "true"
                default: body[name] = raw
                }
            } else {
                queryItems[name] = raw
            }
        }

        // The main search value.
        if let builder = root["query_params"] as? [String: Any], !mainValue.isEmpty, address.contains(mainValue) == false {
            var name: String?
            if let single = builder["param_name"] as? String { name = single }
            else if let byType = builder["param_name"] as? [String: Any] { name = byType[type == "series" ? "imdb" : type] as? String }
            if let name {
                if method == "POST" { body[name] = mainValue } else { queryItems[name] = mainValue }
            }
        }
        if let extra = (root["extra_params"] as? [String: Any])?[type] as? [String: Any] {
            for (key, value) in extra { if let s = Self.string(value) { queryItems[key] = s } }
        }

        // Pagination.
        if let pagination = root["pagination"] as? [String: Any] {
            switch pagination["type"] as? String {
            case "page":
                let name = pagination["page_param"] as? String ?? "page"
                let start = pagination["start_page"] as? Int ?? 1
                if page > 0 || pagination["start_page"] != nil { queryItems[name] = String(start + page) }
            case "offset":
                let offset = pagination["offset"] as? [String: Any] ?? [:]
                let name = offset["param_name"] as? String ?? "offset"
                let value = (offset["start_offset"] as? Int ?? 0) + page * (pagination["results_per_page"] as? Int ?? 100)
                if offset["location"] as? String == "body" || method == "POST" { body[name] = value } else { queryItems[name] = String(value) }
            case "cursor":
                if let cursor, let name = pagination["cursor_param"] as? String { queryItems[name] = cursor }
            default:
                break
            }
        }

        guard var components = URLComponents(string: address) else { throw Failure.invalid("bad address") }
        if !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw Failure.invalid("bad address") }
        let timeout = TimeInterval(api["timeout_seconds"] as? Int ?? (root["request"] as? [String: Any])?["timeout_seconds"] as? Int ?? 20)
        let headers = ["Accept": "application/json", "User-Agent": "Nextup/1.0"]
        if method == "POST" {
            let data = try JSONSerialization.data(withJSONObject: body)
            return try await http.data("POST", url, headers: headers, body: .json(data), timeout: timeout)
        }
        return try await http.data("GET", url, headers: headers, timeout: timeout)
    }

    // MARK: Responses

    private var responseFormat: [String: Any] { root["response_format"] as? [String: Any] ?? [:] }

    func decode(_ data: Data, type: String) -> Any? {
        switch responseFormat["type"] as? String {
        case "rss": return RSSItems.parse(data)
        case "jina_wrapped":
            if let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                if let content = ((json as? [String: Any])?["data"] as? [String: Any])?["content"] as? String,
                   let inner = Self.extractJSON(content) { return inner }
                return json
            }
            return String(data: data, encoding: .utf8).flatMap(Self.extractJSON)
        default:
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
    }

    /// The first JSON object or array inside text (Jina wraps the page in Markdown).
    static func extractJSON(_ text: String) -> Any? {
        if let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           json is [String: Any] || json is [Any] { return json }
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let closing: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: closing), end > start else { return nil }
        return String(text[start...end]).data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    func passesChecks(_ payload: Any) -> Bool {
        for check in root["pre_checks"] as? [[String: Any]] ?? [] {
            guard let field = check["field"] as? String else { continue }
            if !Self.equal(Self.value(at: field, in: payload), check["equals"]) { return false }
        }
        if let empty = root["empty_check"] as? [String: Any] {
            switch empty["type"] as? String {
            case "field_value":
                if let field = empty["field"] as? String, Self.equal(Self.value(at: field, in: payload), empty["equals"]) { return false }
            case "array_empty":
                if (payload as? [Any])?.isEmpty == true { return false }
            default: break
            }
        }
        return true
    }

    func extractItems(_ payload: Any, type: String) -> [[String: Any]] {
        var path: String?
        if let single = responseFormat["results_path"] as? String { path = single }
        else if let byType = responseFormat["results_path"] as? [String: Any] { path = byType[type == "series" ? "imdb" : type] as? String }
        let found = path.flatMap { $0 == "$" ? payload : Self.value(at: $0, in: payload) } ?? payload
        var items: [[String: Any]] = (found as? [Any])?.compactMap { $0 as? [String: Any] } ?? ((found as? [String: Any]).map { [$0] } ?? [])

        if let nested = root["nested_results"] as? [String: Any], nested["enabled"] as? Bool ?? true,
           let field = nested["items_field"] as? String {
            let parents = nested["parent_fields"] as? [[String: Any]] ?? []
            items = items.flatMap { parent -> [[String: Any]] in
                let children = (parent[field] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
                return children.map { child in
                    var merged = child
                    for spec in parents {
                        guard let name = spec["name"] as? String, let source = spec["source"] as? String else { continue }
                        var value = parent[source]
                        if value == nil || value is NSNull, let fallback = spec["fallback"] as? String { value = parent[fallback] }
                        if spec["type"] as? String == "join_comma", let list = value as? [Any] {
                            value = list.compactMap(Self.string).joined(separator: ", ")
                        }
                        merged[name] = value
                    }
                    return merged
                }
            }
        }
        return items
    }

    func map(_ item: [String: Any]) -> TorrentResult? {
        let mappings = root["field_mappings"] as? [String: Any] ?? [:]
        func field(_ name: String) -> Any? {
            if let parser = (root["special_parsers"] as? [String: Any])?[name] as? [String: Any],
               let value = Self.special(parser, item: item) { return value }
            guard let spec = mappings[name] else { return nil }
            if let source = spec as? String { return item[source] }
            guard let spec = spec as? [String: Any] else { return nil }
            var value: Any?
            if spec["type"] as? String == "template", let template = spec["template"] as? String {
                value = Self.fill(template, with: item)
            } else if let source = spec["source"] as? String {
                value = item[source]
            }
            return Self.convert(value, spec["conversion"])
        }
        guard let hash = field("infohash").flatMap(Self.string)?.trimmingCharacters(in: .whitespaces).lowercased(),
              hash.count == 40 || hash.count == 32,
              let name = field("name").flatMap(Self.string), !name.isEmpty else { return nil }
        let created = field("created_unix").flatMap(Self.int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return TorrentResult(infoHash: hash, name: name, sizeBytes: field("size_bytes").flatMap(Self.int).map(Int64.init),
                             seeders: field("seeders").flatMap(Self.int), leechers: field("leechers").flatMap(Self.int),
                             uploaded: created, engine: displayName)
    }

    // MARK: Helpers

    static func special(_ parser: [String: Any], item: [String: Any]) -> Any? {
        guard parser["type"] as? String == "regex", let source = parser["source"] as? String,
              let text = item[source].flatMap(string), let pattern = parser["pattern"] as? String,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        if parser["parser_type"] as? String == "size_with_unit", match.numberOfRanges >= 3,
           let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text) {
            return StreamLabelParser.size(in: "\(text[numberRange]) \(text[unitRange])")
        }
        let group = parser["capture_group"] as? Int ?? 1
        guard group < match.numberOfRanges, let range = Range(match.range(at: group), in: text) else { return nil }
        return convert(String(text[range]), parser["conversion"])
    }

    static func convert(_ value: Any?, _ conversion: Any?) -> Any? {
        guard let value else { return nil }
        if let name = conversion as? String {
            switch name {
            case "lowercase": return string(value)?.lowercased()
            case "uppercase": return string(value)?.uppercased()
            case "trim": return string(value)?.trimmingCharacters(in: .whitespacesAndNewlines)
            case "string_to_int": return int(value)
            default: return value
            }
        }
        if let spec = conversion as? [String: Any], spec["type"] as? String == "replace",
           let find = spec["find"] as? String, let text = string(value) {
            return text.replacingOccurrences(of: find, with: spec["replace"] as? String ?? "")
        }
        return value
    }

    static func fill(_ template: String, with item: [String: Any]) -> String {
        let out = NSMutableString(string: template)
        let regex = try? NSRegularExpression(pattern: #"\{([^}]+)\}"#)
        let matches = regex?.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length)) ?? []
        // From the end, so earlier ranges stay valid.
        for match in matches.reversed() {
            let key = (template as NSString).substring(with: match.range(at: 1))
            out.replaceCharacters(in: match.range, with: item[key].flatMap(string) ?? "")
        }
        return (out as String).trimmingCharacters(in: .whitespaces)
    }

    /// "data.movies", "pagination.hasNext", "[0].name".
    static func value(at path: String, in root: Any) -> Any? {
        var current: Any? = root
        for raw in path.split(separator: ".") {
            var segment = String(raw)
            var indexes: [Int] = []
            while let open = segment.lastIndex(of: "["), segment.hasSuffix("]") {
                if let index = Int(segment[segment.index(after: open)..<segment.index(before: segment.endIndex)]) { indexes.insert(index, at: 0) }
                segment = String(segment[..<open])
            }
            if !segment.isEmpty { current = (current as? [String: Any])?[segment] }
            for index in indexes {
                guard let list = current as? [Any], list.indices.contains(index) else { return nil }
                current = list[index]
            }
        }
        return current
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        if let a = a.flatMap(string), let b = b.flatMap(string) { return a == b }
        return false
    }

    static func string(_ value: Any) -> String? {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        case is NSNull: return nil
        default: return "\(value)"
        }
    }

    static func int(_ value: Any) -> Int? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.intValue }
        if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) ?? Double(s).map { Int($0) } }
        return nil
    }
}

/// RSS `<item>` children as a dictionary, namespace prefixes dropped (`nyaa:seeders` → `seeders`),
/// with `size` turned into `size_bytes` the way the Flutter app does.
enum RSSItems {
    static func parse(_ data: Data) -> Any? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return ["channel": ["item": delegate.items]]
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [[String: Any]] = []
        private var current: [String: Any]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            if elementName == "item" { current = [:] }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(data: CDATABlock, encoding: .utf8) ?? "" }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "item" {
                if var item = current {
                    if let seeders = (item["seeders"] as? String).flatMap({ Int($0) }) { item["seeders"] = seeders }
                    if let leechers = (item["leechers"] as? String).flatMap({ Int($0) }) { item["leechers"] = leechers }
                    if let size = (item["size"] as? String).flatMap(Self.bytes) { item["size_bytes"] = size }
                    items.append(item)
                }
                current = nil
            } else if current != nil {
                let key = elementName.split(separator: ":").last.map(String.init) ?? elementName
                current?[key] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            text = ""
        }

        static func bytes(_ text: String) -> Int64? {
            StreamLabelParser.size(in: text.replacingOccurrences(of: "iB", with: "B"))
        }
    }
}
