import XCTest
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
