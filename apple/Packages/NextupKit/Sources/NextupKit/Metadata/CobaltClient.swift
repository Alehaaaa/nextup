import Foundation

/// Turns a YouTube video into a plain MP4 URL through public Cobalt instances, the same relay the
/// Flutter app's Reels use. Instances are tried one at a time, fastest first; never raced.
public actor CobaltClient {
    public static let publicInstances = [
        URL(string: "https://rue-cobalt.xenon.zone/")!,
        URL(string: "https://cobaltapi.cjs.nz/")!,
    ]

    private struct Health { var latency: Double = .infinity; var restUntil: Date? }

    private let instances: [URL]
    private var health: [URL: Health] = [:]
    private var misses: [String: Date] = [:]
    private let http: HTTPClient

    public init(instances: [URL] = CobaltClient.publicInstances, http: HTTPClient = .shared) {
        self.instances = instances
        self.http = http
    }

    struct Response: Decodable {
        struct Failure: Decodable { let code: String? }
        let status: String?
        let url: String?
        let error: Failure?
    }

    public static func isValidVideoID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil
    }

    public func resolve(videoID: String, maxHeight: Int = 1080) async -> URL? {
        guard Self.isValidVideoID(videoID) else { return nil }
        if let until = misses[videoID], until > Date() { return nil }
        let height = [1080, 720, 480, 360].first { $0 <= maxHeight } ?? 360
        let now = Date()
        let candidates = instances
            .filter { (health[$0]?.restUntil ?? .distantPast) <= now }
            .sorted { (health[$0]?.latency ?? .infinity) < (health[$1]?.latency ?? .infinity) }

        var refusals = 0
        for instance in candidates {
            let started = Date()
            do {
                let body = try JSONSerialization.data(withJSONObject: [
                    "url": "https://www.youtube.com/watch?v=\(videoID)",
                    "videoQuality": "\(height)",
                    "youtubeVideoCodec": "h264",
                    "downloadMode": "auto",
                    "localProcessing": "disabled",
                ])
                let (data, response) = try await http.data("POST", instance, headers: ["Accept": "application/json"],
                                                           body: .json(body), timeout: 8)
                if response.statusCode == 429 { rest(instance, seconds: 60); continue }
                let decoded = try? JSONDecoder().decode(Response.self, from: data)
                if let code = decoded?.error?.code,
                   code.hasPrefix("error.api.youtube.") || code.hasPrefix("error.api.content.") || code.hasPrefix("error.api.fetch.") {
                    refusals += 1
                    continue
                }
                guard response.statusCode == 200, let decoded, ["tunnel", "redirect"].contains(decoded.status ?? ""),
                      let raw = decoded.url, let url = URL(string: raw), url.scheme == "https",
                      url.host == instance.host || (url.host ?? "").hasSuffix(".googlevideo.com") else {
                    rest(instance, seconds: 300)
                    continue
                }
                let elapsed = Date().timeIntervalSince(started) * 1000
                var h = health[instance] ?? Health()
                h.latency = h.latency.isFinite ? h.latency * 0.3 + elapsed * 0.7 : elapsed
                health[instance] = h
                return url
            } catch {
                rest(instance, seconds: 45)
            }
        }
        if refusals == instances.count { misses[videoID] = Date().addingTimeInterval(600) }
        return nil
    }

    private func rest(_ instance: URL, seconds: TimeInterval) {
        var h = health[instance] ?? Health()
        h.restUntil = Date().addingTimeInterval(seconds)
        health[instance] = h
    }
}
