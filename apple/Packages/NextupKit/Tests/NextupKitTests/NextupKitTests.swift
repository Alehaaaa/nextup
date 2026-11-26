import XCTest
import CryptoKit
@testable import NextupKit

final class AddonTests: XCTestCase {
    func testNormalizesManifestURLs() throws {
        XCTAssertEqual(try AddonClient.normalizeManifestURL("stremio://torrentio.strem.fun/manifest.json").absoluteString,
                       "https://torrentio.strem.fun/manifest.json")
        XCTAssertEqual(try AddonClient.normalizeManifestURL("https://v3-cinemeta.strem.io/").absoluteString,
                       "https://v3-cinemeta.strem.io/manifest.json")
        XCTAssertEqual(try AddonClient.normalizeManifestURL("example.com/abc").absoluteString,
                       "https://example.com/abc/manifest.json")
    }

    func testBaseURLStripsManifest() throws {
        let data = Data(#"{"id":"x","name":"X","version":"1","resources":["stream"],"types":["movie"],"catalogs":[]}"#.utf8)
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: data)
        let addon = InstalledAddon(manifestURL: URL(string: "https://a.example/cfg=1/manifest.json")!, manifest: manifest)
        XCTAssertEqual(addon.baseURL, "https://a.example/cfg=1")
    }

    func testManifestResourceForms() throws {
        let json = #"""
        {"id":"org.test","name":"Test","version":"1.0.0","types":["movie","series"],
         "resources":["catalog",{"name":"stream","types":["series"],"idPrefixes":["tt"]}],
         "catalogs":[{"type":"movie","id":"top","extra":[{"name":"search","isRequired":true}]}]}
        """#
        let manifest = try JSONDecoder().decode(AddonManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.supports("stream", type: "series", id: "tt1:1:1"))
        XCTAssertFalse(manifest.supports("stream", type: "movie", id: "tt1"))
        XCTAssertFalse(manifest.supports("stream", type: "series", id: "kitsu:1"))
        XCTAssertTrue(manifest.catalogs[0].supportsSearch)
        XCTAssertTrue(manifest.catalogs[0].requiresInput)
    }

    func testVideoID() {
        XCTAssertEqual(AddonClient.videoID(imdbID: "tt0903747"), "tt0903747")
        XCTAssertEqual(AddonClient.videoID(imdbID: "tt0903747", season: 2, episode: 5), "tt0903747:2:5")
    }

    func testStreamLabels() {
        XCTAssertEqual(StreamLabelParser.quality(in: "Torrentio\n4k DV"), .uhd2160)
        XCTAssertEqual(StreamLabelParser.quality(in: "1080p WEB-DL"), .hd1080)
        XCTAssertEqual(StreamLabelParser.size(in: "👤 12 💾 1.5 GB ⚙️ x"), Int64(1.5 * 1_073_741_824))
        XCTAssertNil(StreamLabelParser.size(in: "no size here"))
    }
}

final class DebridTests: XCTestCase {
    func testEpisodeMatcher() {
        XCTAssertTrue(EpisodeMatcher.matches("Show.S01E02.1080p.mkv", season: 1, episode: 2))
        XCTAssertTrue(EpisodeMatcher.matches("show 1x02.mkv", season: 1, episode: 2))
        XCTAssertFalse(EpisodeMatcher.matches("Show.S01E12.mkv", season: 1, episode: 2))
        XCTAssertFalse(EpisodeMatcher.matches("Show.S11E02.mkv", season: 1, episode: 2))
    }

    func testFilePickerPrefersEpisodeThenLargest() {
        let files = [
            TorrentFile(id: 1, path: "/Pack/Show.S01E01.mkv", bytes: 900),
            TorrentFile(id: 2, path: "/Pack/Show.S01E02.mkv", bytes: 800),
            TorrentFile(id: 3, path: "/Pack/sample.mkv", bytes: 5000),
            TorrentFile(id: 4, path: "/Pack/readme.txt", bytes: 10),
        ]
        XCTAssertEqual(FilePicker.pick(files, hint: FileHint(season: 1, episode: 2))?.id, 2)
        XCTAssertEqual(FilePicker.pick(files, hint: FileHint())?.id, 1)
        XCTAssertEqual(FilePicker.pick(files, hint: FileHint(filename: "Show.S01E02.mkv"))?.id, 2)
        XCTAssertNil(FilePicker.pick([files[3]], hint: FileHint()))
    }
}

final class ProgressTests: XCTestCase {
    func testContinueWatchingKeepsLatestEpisodeAndDropsFinishedMovies() {
        let defaults = UserDefaults(suiteName: "nextup-tests-\(UUID().uuidString)")!
        let store = WatchProgressStore(store: DefaultsStore(defaults: defaults))
        let show = MediaItem(kind: .series, imdbID: "tt1", title: "Show")
        let movie = MediaItem(kind: .movie, imdbID: "tt2", title: "Movie")

        store.record(WatchProgress(item: show, season: 1, episode: 1, position: 100, duration: 1000))
        store.record(WatchProgress(item: show, season: 1, episode: 2, position: 50, duration: 1000))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.episode, 2)
        XCTAssertEqual(store.position(for: "series:tt1:1:1"), 100)

        store.record(WatchProgress(item: movie, position: 10, duration: 100))
        XCTAssertEqual(store.all().count, 2)
        store.record(WatchProgress(item: movie, position: 95, duration: 100))
        XCTAssertEqual(store.all().map(\.item.title), ["Show"])
        XCTAssertNil(store.position(for: movie.id))
    }
}

final class SkipSegmentTests: XCTestCase {
    func testBoundsAreValidated() {
        let ok: [String: JSONValue] = ["start_ms": .number(30_000), "end_ms": .number(90_000)]
        XCTAssertEqual(SkipSegmentsClient.bounded(ok, kind: .intro, duration: 2400),
                       SkipSegment(kind: .intro, start: 30, end: 90))
        let early: [String: JSONValue] = ["start_ms": .number(60_000), "end_ms": .number(120_000)]
        XCTAssertNil(SkipSegmentsClient.bounded(early, kind: .outro, duration: 2400), "credits must be in the last 10%")
        let openEnded: [String: JSONValue] = ["start_ms": .number(2_300_000), "end_ms": .null]
        XCTAssertEqual(SkipSegmentsClient.bounded(openEnded, kind: .outro, duration: 2400, nullEndAtEnd: true)?.end, 2400)
        XCTAssertNil(SkipSegmentsClient.bounded(ok, kind: .intro, duration: 0))
    }
}

final class SyncCryptoTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    func testBLAKE2b() {
        XCTAssertEqual(hex(BLAKE2b.hash(Array("abc".utf8))),
                       "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    }

    func testArgon2idRFC9106() {
        let tag = Argon2id.hash(password: [UInt8](repeating: 1, count: 32), salt: [UInt8](repeating: 2, count: 16),
                                secret: [UInt8](repeating: 3, count: 8), associatedData: [UInt8](repeating: 4, count: 12),
                                iterations: 3, memoryKiB: 32, parallelism: 4, length: 32)
        XCTAssertEqual(hex(tag), "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    func testArgon2idMatchesReferenceLibrary() {
        let salt = Array("somesaltsomesalt".utf8)
        XCTAssertEqual(hex(Argon2id.hash(password: Array("password".utf8), salt: salt, iterations: 2, memoryKiB: 64, parallelism: 1)),
                       "1a98fba8e6394425c9bdc333a9c750aaf811df070f5fb4a5788e1cf4db5793a1")
        XCTAssertEqual(hex(Argon2id.hash(password: Array("password".utf8), salt: salt, iterations: 3, memoryKiB: 256, parallelism: 2)),
                       "4405b9089a2a4a7add167d11d63f8ec41c2408e1d8e45e02b85bf4ac98102e51")
    }

    func testCanonicalJSON() {
        let value: [String: Any] = ["b": 1, "a": ["z": true, "y": "x/y"], "c": [1, "two"]]
        XCTAssertEqual(CanonicalJSON.encode(value), #"{"a":{"y":"x/y","z":true},"b":1,"c":[1,"two"]}"#)
    }

    /// A sync folder written the way the Flutter app writes it (generated with argon2-cffi + AES-GCM).
    func testReadsFlutterSyncResources() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(Self.fixture.utf8)) as! [String: String]
        let authority = try JSONSerialization.jsonObject(with: Data(fixture["authority"]!.utf8)) as! [String: Any]
        let marker = Data(base64Encoded: authority["marker"] as! String)!
        let circle = try FlutterSync.openRoot(marker, passphrase: authority["syncPassphrase"] as! String)
        XCTAssertEqual(circle.id, "circle1")
        XCTAssertThrowsError(try FlutterSync.openRoot(marker, passphrase: "wrong passphrase"))

        let sealed = Data(fixture["resources"]!.utf8)
        XCTAssertEqual(FlutterSync.sha256Hex(sealed), fixture["resourcesSha"])
        XCTAssertThrowsError(try FlutterSync.openDocument(sealed, circle: circle, deviceID: "devB", logicalName: "resources", schemaVersion: 1))
        let resources = try FlutterSync.openDocument(sealed, circle: circle, deviceID: "devA", logicalName: "resources", schemaVersion: 1)
        let result = try FlutterSync.importResources([resources as! [String: Any]], circle: circle)
        XCTAssertEqual(result.realDebridKey, "RDKEY123")
        XCTAssertNil(result.torboxKey)
        XCTAssertEqual(result.trakt?.accessToken, "AT")
        XCTAssertEqual(result.trakt?.refreshToken, "RT")
        XCTAssertEqual(result.trakt?.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.addonURLs, ["https://torrentio.strem.fun/manifest.json"])
        XCTAssertEqual(result.notSupported, ["My IPTV"])
    }

    func testNativeSyncRoundTripAndMerge() throws {
        let key = SymmetricKey(size: .bits256)
        let item = MediaItem(kind: .movie, imdbID: "tt1", title: "A")
        let old = WatchProgress(item: item, position: 10, duration: 100, updatedAt: Date(timeIntervalSince1970: 100))
        let new = WatchProgress(item: item, position: 50, duration: 100, updatedAt: Date(timeIntervalSince1970: 200))
        let local = SyncState(settingsChangedAt: Date(timeIntervalSince1970: 300), addons: [], favorites: [item], watchlist: [],
                              secrets: ["k": "v"], progress: [old])
        let remote = SyncState(settingsChangedAt: Date(timeIntervalSince1970: 250), addons: [], favorites: [], watchlist: [item],
                               secrets: [:], progress: [new])
        let opened = try NativeSync.open(try NativeSync.seal(remote, key: key), key: key)
        XCTAssertEqual(opened, remote)
        let merged = local.merged(with: opened)
        XCTAssertEqual(merged.favorites, [item])
        XCTAssertEqual(merged.secrets, ["k": "v"])
        XCTAssertEqual(merged.progress.first?.position, 50)
    }

    static let fixture = #"""
{"authority": "{\"version\": 1, \"marker\": \"eyJjaXBoZXJ0ZXh0IjoiVDlPVjNuRmxjdHJlYW8zb0tEdys3dEl5ZmVyby9meFJ0MWgrdldmQ3BzYmdBeWVCWnd3N2dqNElSTVcrSDhtTjFpelRocFBEcXJpQzg4Z2M5TVEyRkozNUZWZUc2VVVzK0tHNjI4M0RyQndhOEp3UmFLOEYvUWMwK2ZJQ3ZPKy9HTGdwMnljNnpEVGlZNmxsYVY5SFN5aml2WGM1VXE0MThaYTRWMVFRZjFwcDUrYW5pRWtBdUNJTXIzK2dsVWFYeW9jNVJtLzkiLCJoZWFkZXIiOnsiYWVhZCI6ImFlcy0yNTYtZ2NtIiwiZW5jcnlwdGVkIjp0cnVlLCJmb3JtYXQiOiJkZWJyaWZ5LXdlYmRhdi1zeW5jLXJvb3QiLCJrZGYiOnsiYWxnb3JpdGhtIjoiYXJnb24yaWQiLCJpdGVyYXRpb25zIjoyLCJtZW1vcnlLaUIiOjY0LCJwYXJhbGxlbGlzbSI6MSwic2FsdCI6IkFBRUNBd1FGQmdjSUNRb0xEQTBPRHc9PSJ9LCJ2ZXJzaW9uIjoxfSwibm9uY2UiOiJBQUVDQXdRRkJnY0lDUW9MIn0=\", \"syncPassphrase\": \"correct horse battery staple\"}", "resources": "{\"ciphertext\":\"BNpu4GktO+uo7n1zp5R0JrwzVlvn7iGLovRrEMghvJ3a/izVcRgsjVD8EtrUj04J9vgg4UZoGRkWmTxu908EGodXGyFLHifA5n4ddNbmRkboPcW0l8KyB8BPC/Y80kpZGU2C0B8VoOiGfLLhQy+NO78sCanj7KDoCiX5JgM/u3Bafg1A2eQQLG+GgMesoi6pisGdQOJyRiy/BaaLjytmEJcGQiricCXnj9Qwr17PgHbJY9h8k1m73WZ57msQ/JBTs5puZACQ6s51k9zRVPngsoyKHrmNHSa0UJpEZEBDrWE3TJdvtLd0UoqjtS615C5gjj69k1iz3XY+Pr4YLdAYVvNTnwvCVWMiUXqnN68+DqK/4QJnOQyKL1NemuZ6jvD02eJbZQQDIMhY6OU9IBum1LbxyisyfkKElz2QFOes62HsoBL09IlzSmOXWti1kaqH9PcP6N2FsvE8h0Z1RGtqy7h7fV80hVYDqAFCFgqva6iaDvDp3oMJclloKxCV4NeYwiWWi8yieh/R+V156GBEzeAUCkbcHypSkwod0TEEvcFxB2widC6NSWkx3M4GYqQItjE41/L3ityZWcTFvP91slfp4u64G3NlRdVrpMMJJShhKoGdQQX6lJfniGlBQhwPXGGYGMlkIM0qHpKfddbTEW4JqTl7MPRpXwflvBByajWjOuwXxyRLyy23iASZ+5m8RhX1AY/eg2ua2cZc3QoaYlnT0pWEDDa4i3cRQ9DM0Fnl/6rhJIbKkRsDhY1BiK2dRQlpFAKnUlzmG3M5wGvj6OdG9xt6q+9U/MRNGKFBC+2lLKVQgV8dtjLqfgp6UObgGxuGNQbPFANDpSVli14Pjmi4NFu7VWLlNyVEksbyWsXAFt5P+Yjzw3pJo95R+RDIgzUgv7sf+05Rrzh6D4paVcVNoXn4+NV6MeU7NJgNbo8M/Zw29hBz5JhYXJL8FbyFkf2FOCy2FfcQEKjuItFrueSWVplMkmSVC+AtNmwgOfO1ftzVcqhsXdIsXkNVdn9yVltKzAasOnX8UPl33RAkAnadqQy8TVz89W6qIuQkjURVxIPdRGZrJIVd3xKicbyvQzim3DmlMinDVekf41eN0IesUmEHb5j0qySmo3dq64z1yGBywwTRLDp3B8D2NKwDK1Y+4Vq7boxsrBHfDyMpa0HwZmM5fW8trkTSYF2sEIkvj0rcnrYlz9CEhGBZzR7BixzhK6FCRfYt2BJVvC88l8EuZcO3Ikx62/EEyJRBVrcy13UdFZFhDgkYhNkl5lFR91R7cQpDisjZNSjBlAzcvgKFweGyV7mMkR4+Xrz9j7py8zt16NU2PxT1dzso0m6dJPW4qyPoezaROWeOrJsbyqo7da7SDO4FptiXkkLW1JR83qfIQJUa7yoOu3bmicz3vBC3Oz06UMC+sIS2k/hIIewCYt9n2P/uJEdzyPI05gBAFNCUQ8AFkCoAtnqb0z8Fqvd9Jg1qiX6x\",\"header\":{\"aead\":\"aes-256-gcm\",\"circleId\":\"circle1\",\"deviceId\":\"devA\",\"format\":\"debrify-webdav-sync-document\",\"logicalName\":\"resources\",\"schemaVersion\":1,\"version\":1},\"nonce\":\"BQUFBQUFBQUFBQUF\"}", "resourcesSha": "b59aeed84147661b4b4ff8710aa9a3e13e504b744e21b20c40621bffb4f74af5"}
"""#
}

final class StreamTraitsTests: XCTestCase {
    func testTorrentioStyleLabel() {
        var stream = StremioStream()
        stream.name = "[RD+] Torrentio\n4k DV | HDR"
        stream.title = "Movie.2024.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.TrueHD.Atmos.7.1-FGT\n👤 152 💾 58.3 GB ⚙️ ThePirateBay\n🇬🇧 / 🇪🇸"
        let t = stream.traits
        XCTAssertEqual(t.quality, .uhd2160)
        XCTAssertEqual(t.hdr, ["DV", "HDR"])
        XCTAssertEqual(t.codec, "HEVC")
        XCTAssertEqual(t.source, "REMUX")
        XCTAssertEqual(t.audio, ["Atmos", "TrueHD", "7.1"])
        XCTAssertEqual(t.seeders, 152)
        XCTAssertEqual(t.cache, .cached)
        XCTAssertEqual(t.languages, ["🇬🇧", "🇪🇸"])
        XCTAssertEqual(t.group, "FGT")
    }

    func testCamIsLowQuality() {
        var stream = StremioStream()
        stream.name = "[RD download] Torrentio\n720p"
        stream.title = "Movie.2025.HDCAM.x264-XYZ"
        XCTAssertTrue(stream.traits.isLowQualitySource)
        XCTAssertEqual(stream.traits.cache, .notCached)
        XCTAssertEqual(stream.traits.codec, "AVC")
    }
}

final class ProviderEngineTests: XCTestCase {
    func testMiniYAMLBasics() throws {
        let yaml = """
        # comment
        id: x
        list:
          - name: "A"
            path: "a.yaml"
          - name: B   # trailing
            path: b.yaml
        inline: [25, 50, "x y"]
        nested:
          flag: true
          pattern: "👤\\\\s*(\\\\d+)"
          find: "\\n"
        empty:
        """
        let root = try XCTUnwrap(MiniYAML.parse(yaml) as? [String: Any])
        XCTAssertEqual(root["id"] as? String, "x")
        let list = try XCTUnwrap(root["list"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[1]["name"] as? String, "B")
        XCTAssertEqual(list[1]["path"] as? String, "b.yaml")
        XCTAssertEqual((root["inline"] as? [Any])?.count, 3)
        let nested = try XCTUnwrap(root["nested"] as? [String: Any])
        XCTAssertEqual(nested["flag"] as? Bool, true)
        XCTAssertEqual(nested["pattern"] as? String, #"👤\s*(\d+)"#)
        XCTAssertEqual(nested["find"] as? String, "\n")
        XCTAssertTrue(root["empty"] is NSNull)
    }

    func testPirateBay() throws {
        let engine = try TorrentEngine(yaml: Self.pirateBay)
        XCTAssertEqual(engine.id, "pirate_bay")
        XCTAssertEqual(engine.displayName, "The Pirate Bay")
        XCTAssertTrue(engine.imdbSearch && engine.keywordSearch)
        XCTAssertEqual(engine.maxResults, 100)
        let body = #"[{"id":"1","name":"Movie.2024.1080p.WEB-DL.x264","info_hash":"ABCDEF0123456789ABCDEF0123456789ABCDEF01","leechers":"3","seeders":"42","size":"1073741824","added":"1700000000","category":"207"}]"#
        let payload = try XCTUnwrap(engine.decode(Data(body.utf8), type: "imdb"))
        XCTAssertTrue(engine.passesChecks(payload))
        let results = engine.extractItems(payload, type: "imdb").compactMap(engine.map)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].infoHash, "abcdef0123456789abcdef0123456789abcdef01")
        XCTAssertEqual(results[0].seeders, 42)
        XCTAssertEqual(results[0].sizeBytes, 1_073_741_824)
        let empty = #"[{"id":"0","name":"No results returned","info_hash":"0000000000000000000000000000000000000000"}]"#
        XCTAssertFalse(engine.passesChecks(try XCTUnwrap(engine.decode(Data(empty.utf8), type: "imdb"))))
    }

    func testTorrentioSpecialParsers() throws {
        let engine = try TorrentEngine(yaml: Self.torrentio)
        XCTAssertFalse(engine.keywordSearch)
        let body = #"{"streams":[{"name":"Torrentio\n1080p","title":"Show.S01E02.1080p.WEB.h264\n👤 17 💾 1.5 GB ⚙️ EZTV","infoHash":"ABCDEF0123456789ABCDEF0123456789ABCDEF02"}]}"#
        let payload = try XCTUnwrap(engine.decode(Data(body.utf8), type: "series"))
        let results = engine.extractItems(payload, type: "series").compactMap(engine.map)
        XCTAssertEqual(results.first?.seeders, 17)
        XCTAssertEqual(results.first?.sizeBytes, Int64(1.5 * 1_073_741_824))
        XCTAssertFalse(results.first?.name.contains("\n") ?? true)
    }

    func testYTSNestedResults() throws {
        let engine = try TorrentEngine(yaml: Self.yts)
        let inner = #"{"status":"ok","data":{"movie":{"title_long":"Film (2020)","genres":["Drama","Crime"],"torrents":[{"hash":"ABCDEF0123456789ABCDEF0123456789ABCDEF03","quality":"1080p","type":"bluray","size_bytes":2000,"seeds":9,"peers":1}]}}}"#
        let wrapped = try JSONSerialization.data(withJSONObject: ["code": 200, "data": ["content": inner]])
        let payload = try XCTUnwrap(engine.decode(wrapped, type: "imdb"))
        XCTAssertTrue(engine.passesChecks(payload))
        let results = engine.extractItems(payload, type: "imdb").compactMap(engine.map)
        XCTAssertEqual(results.first?.name, "Film (2020) [1080p bluray]")
        XCTAssertEqual(results.first?.seeders, 9)
    }

    func testKnabenParses() throws {
        let engine = try TorrentEngine(yaml: Self.knaben)
        XCTAssertTrue(engine.keywordSearch)
        XCTAssertFalse(engine.imdbSearch)
        let body = #"{"hits":[{"title":"Film 2020 2160p","hash":"abcdef0123456789abcdef0123456789abcdef04","bytes":5,"seeders":3,"peers":1}]}"#
        let payload = try XCTUnwrap(engine.decode(Data(body.utf8), type: "keyword"))
        XCTAssertEqual(engine.extractItems(payload, type: "keyword").compactMap(engine.map).first?.name, "Film 2020 2160p")
    }

    func testSeasonFit() {
        XCTAssertTrue(ProviderStore.fits("Show.S02E05.1080p", season: 2, episode: 5))
        XCTAssertTrue(ProviderStore.fits("Show.S02.1080p.WEB", season: 2, episode: 5))
        XCTAssertTrue(ProviderStore.fits("Show Complete Series", season: 2, episode: 5))
        XCTAssertFalse(ProviderStore.fits("Show.S02E06.1080p", season: 2, episode: 5))
        XCTAssertFalse(ProviderStore.fits("Show.S03.1080p", season: 2, episode: 5))
    }

    static let pirateBay = #"""
# The Pirate Bay Search Engine Configuration
# Classic torrent search via The Pirate Bay API

id: pirate_bay
display_name: "The Pirate Bay"
icon: sailing

# Engine capabilities
capabilities:
  keyword_search: true
  imdb_search: true
  series_support: false

# API endpoint
# Note: IMDB search uses keyword URL - searches for IMDB ID in torrent names
api:
  urls:
    keyword: "https://apibay.org/q.php"
    imdb: "https://apibay.org/q.php"

# Query parameters
query_params:
  type: query_params
  param_name: "q"

# No pagination - returns fixed ~100 results
pagination:
  type: none

# Response format
response_format:
  type: direct_json
  results_path: "$"  # Root array

# Empty result check
empty_check:
  type: field_value
  field: "[0].name"
  equals: "No results returned"

# Field mappings with transformations
field_mappings:
  infohash:
    source: "info_hash"
    type: direct
  name:
    source: "name"
    type: direct
  size_bytes:
    source: "size"
    type: direct
    conversion: string_to_int
  seeders:
    source: "seeders"
    type: direct
    conversion: string_to_int
  leechers:
    source: "leechers"
    type: direct
    conversion: string_to_int
  created_unix:
    source: "added"
    type: direct
    conversion: string_to_int
  category:
    source: "category"
    type: direct

# User-configurable settings
settings:
  - id: enabled
    type: toggle
    label: "Enable The Pirate Bay"
    default: true
  - id: max_results
    type: dropdown
    label: "Maximum Results"
    default: 100
    options: [25, 50, 75, 100]

# TV mode specific configuration
tv_mode:
  enabled_default: true
  limits:
    small: 100
    large: 100
    quick_play: 100
"""#

    static let torrentio = #"""
# Torrentio Search Engine Configuration
# Stremio addon for IMDB-based searches with series support

id: torrentio
display_name: "Torrentio"
icon: cloud

# Engine capabilities
capabilities:
  keyword_search: false  # IMDB only
  imdb_search: true
  series_support: true

# API endpoints - different for movies and series
api:
  urls:
    movie: "https://torrentio.strem.fun/stream/movie/{imdb_id}.json"
    series: "https://torrentio.strem.fun/stream/series/{imdb_id}:{season}:{episode}.json"

# Path parameters (URL template variables)
path_params:
  type: path_params

# Series configuration
series_config:
  max_season_probes: 5
  default_episode: 1

# No pagination
pagination:
  type: none

# Response format
response_format:
  type: direct_json
  results_path: "streams"

# Field mappings with transformations
field_mappings:
  infohash:
    source: "infoHash"
    type: direct
    conversion: lowercase
  name:
    source: "title"
    type: direct
    conversion:
      type: replace
      find: "\n"
      replace: " "

# Special parsers for extracting data from title field
special_parsers:
  seeders:
    source: "title"
    type: regex
    pattern: "👤\\s*(\\d+)"
    capture_group: 1
    conversion: string_to_int
  size_bytes:
    source: "title"
    type: regex
    pattern: "💾\\s*([\\d\\.]+)\\s*(KB|MB|GB|TB)"
    parser_type: size_with_unit

# User-configurable settings
settings:
  - id: enabled
    type: toggle
    label: "Enable Torrentio"
    default: true
  # No max_results setting - returns all available

# No TV mode configuration - advanced search only
"""#

    static let yts = #"""
# YTS Search Engine Configuration
# Movie-focused torrent search via YTS API

id: yts
display_name: "YTS"
icon: movie_creation

# Engine capabilities
capabilities:
  keyword_search: true
  imdb_search: true
  series_support: false

# API endpoints - different for keyword and IMDB search
api:
  urls:
    keyword: "https://r.jina.ai/http://yts.mx/api/v2/list_movies.json"
    imdb: "https://r.jina.ai/http://yts.mx/api/v2/movie_details.json"

# Query parameters - different param names for each search type
query_params:
  type: query_params
  param_name:
    keyword: "query_term"
    imdb: "imdb_id"

# Extra parameters
extra_params:
  keyword:
    limit: 50

# No pagination - fixed limit
pagination:
  type: none

# Response format - jina wrapped
response_format:
  type: jina_wrapped
  extract_json: true
  results_path:
    keyword: "data.movies"
    imdb: "data.movie"

# Pre-checks for valid response
pre_checks:
  - field: "status"
    equals: "ok"

# Nested results configuration - torrents within movies
nested_results:
  enabled: true
  items_field: "torrents"
  parent_fields:
    - name: "_movie_title"
      source: "title_long"
      fallback: "title"
    - name: "_genres"
      source: "genres"
      type: join_comma

# Field mappings with transformations
field_mappings:
  infohash:
    source: "hash"
    type: direct
    conversion: lowercase
  name:
    type: template
    template: "{_movie_title} [{quality} {type}]"
  size_bytes:
    source: "size_bytes"
    type: direct
  seeders:
    source: "seeds"
    type: direct
  leechers:
    source: "peers"
    type: direct
  created_unix:
    source: "date_uploaded_unix"
    type: direct
  category:
    type: template
    template: "{_genres}"

# User-configurable settings
settings:
  - id: enabled
    type: toggle
    label: "Enable YTS"
    default: true
  # No max_results setting - fixed API limit

# TV mode specific configuration
tv_mode:
  enabled_default: false  # Movies only, not ideal for TV
  limits:
    small: 50
    large: 50
    quick_play: 50
"""#

    static let knaben = #"""
# Knaben Torrent Search Engine
# Uses POST request with JSON body
id: "knaben"
display_name: "Knaben"
description: "Knaben torrent search using API v1"
icon: "search"
categories: ["general"]

capabilities:
  keyword_search: true
  imdb_search: false
  series_support: false

# API configuration with POST method
api:
  base_url: "https://api.knaben.org/v1"
  method: "POST"
  timeout_seconds: 30
  params:
    - name: "query"
      source: "query"
      location: "body"
      required: true
    - name: "search_field"
      value: "title"
      location: "body"
    - name: "size"
      value: "100"
      location: "body"
      value_type: "int"
    - name: "hide_unsafe"
      value: "true"
      location: "body"
      value_type: "bool"
    - name: "hide_xxx"
      value: "false"
      location: "body"
      value_type: "bool"

# Query params configuration (for POST body in this case)
query_params:
  type: "query_params"
  param_name: "query"
  encode: false

# Pagination using offset-based approach
pagination:
  type: "offset"
  results_per_page: 100
  max_pages: 5
  offset:
    param_name: "from"
    start_offset: 0
    location: "body"  # Pagination goes in POST body

# Response parsing
response_format:
  type: "json"
  results_path: "hits"

field_mappings:
  name: "title"
  infohash: "hash"
  size_bytes: "bytes"
  seeders: "seeders"
  leechers: "peers"

# Settings
settings:
  - id: "enabled"
    type: "toggle"
    label: "Enable Knaben"
    default: true
  - id: "max_results"
    type: "dropdown"
    label: "Max Results"
    default: 100
    options: [100, 200, 300, 400, 500]

"""#

}
