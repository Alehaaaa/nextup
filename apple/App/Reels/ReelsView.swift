import AVKit
import SwiftUI
import NextupKit

/// One clip in the feed.
struct Reel: Identifiable, Hashable {
    let item: MediaItem
    let clipKey: String
    let clipName: String
    var id: String { clipKey }
}

/// Builds an endless feed of official scene clips (then featurettes, teasers, trailers) from TMDB,
/// alternating movies and shows, and resolves each clip to MP4 shortly before it is shown.
@MainActor
@Observable
final class ReelsFeed {
    private(set) var reels: [Reel] = []
    private(set) var isLoading = false
    private(set) var message: String?

    @ObservationIgnored private var urls: [String: URL] = [:]
    @ObservationIgnored private var resolving: Set<String> = []
    @ObservationIgnored private var seenTitles: Set<String> = []
    @ObservationIgnored private var page = 1
    @ObservationIgnored private let cobalt = CobaltClient()
    @ObservationIgnored private var failed: Set<String> = []

    private static let lists: [TMDBClient.ListKind] = [.trendingMovies, .trendingSeries, .popularMovies, .popularSeries]

    func url(for reel: Reel) -> URL? { urls[reel.clipKey] }
    func hasFailed(_ reel: Reel) -> Bool { failed.contains(reel.clipKey) }

    func loadMore(tmdb: TMDBClient) async {
        guard !isLoading else { return }
        guard tmdb.isConfigured else {
            message = "Reels use TMDB. Add a TMDB token in Settings."
            return
        }
        isLoading = true
        defer { isLoading = false }
        let page = self.page
        self.page += 1

        var titles: [MediaItem] = []
        await withTaskGroup(of: [MediaItem].self) { group in
            for list in Self.lists {
                group.addTask { (try? await tmdb.list(list, page: page)) ?? [] }
            }
            for await batch in group { titles.append(contentsOf: batch) }
        }
        titles = titles.filter { $0.tmdbID != nil && seenTitles.insert($0.id).inserted }.shuffled()

        var found: [Reel] = []
        await withTaskGroup(of: Reel?.self) { group in
            for title in titles.prefix(16) {
                group.addTask {
                    guard let id = title.tmdbID, let videos = try? await tmdb.videos(kind: title.kind, tmdbID: id),
                          let clip = Self.bestClip(videos) else { return nil }
                    var item = title
                    if item.imdbID == nil { item.imdbID = try? await tmdb.externalIMDbID(kind: title.kind, tmdbID: id) }
                    return Reel(item: item, clipKey: clip.key, clipName: clip.name)
                }
            }
            for await reel in group { if let reel { found.append(reel) } }
        }
        // Alternate movies and shows so the feed doesn't clump.
        let movies = found.filter { $0.item.kind == .movie }, shows = found.filter { $0.item.kind == .series }
        var mixed: [Reel] = []
        for i in 0..<max(movies.count, shows.count) {
            if i < movies.count { mixed.append(movies[i]) }
            if i < shows.count { mixed.append(shows[i]) }
        }
        reels.append(contentsOf: mixed)
        message = reels.isEmpty ? "No clips found right now. Pull to try again." : nil
    }

    nonisolated static func bestClip(_ videos: [TMDBClient.Video]) -> TMDBClient.Video? {
        let order = ["Clip", "Featurette", "Teaser", "Trailer"]
        return videos
            .filter { order.contains($0.type) && CobaltClient.isValidVideoID($0.key) }
            .sorted { a, b in
                let ra = order.firstIndex(of: a.type) ?? 9, rb = order.firstIndex(of: b.type) ?? 9
                if ra != rb { return ra < rb }
                return (a.official ?? false) && !(b.official ?? false)
            }
            .first
    }

    /// Resolves this reel and the next couple, so swiping never waits.
    func prepare(around reel: Reel) async {
        guard let index = reels.firstIndex(of: reel) else { return }
        for candidate in reels[index..<min(reels.count, index + 3)] {
            await resolve(candidate)
        }
    }

    private func resolve(_ reel: Reel) async {
        guard urls[reel.clipKey] == nil, !failed.contains(reel.clipKey), resolving.insert(reel.clipKey).inserted else { return }
        defer { resolving.remove(reel.clipKey) }
        if let url = await cobalt.resolve(videoID: reel.clipKey) {
            urls[reel.clipKey] = url
        } else {
            failed.insert(reel.clipKey)
        }
        // Make views that are waiting re-render.
        reels = reels
    }
}

/// A vertical, swipeable feed: clips start on arrival, tap to pause, jump to the title from any clip.
struct ReelsView: View {
    @Environment(AppModel.self) private var model
    @State private var feed = ReelsFeed()
    @State private var current: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(feed.reels) { reel in
                    ReelPage(reel: reel, url: feed.url(for: reel), failed: feed.hasFailed(reel), isCurrent: current == reel.id)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(reel.id)
                        .onAppear {
                            if reel.id == feed.reels.suffix(4).first?.id { Task { await feed.loadMore(tmdb: model.tmdb) } }
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $current)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .background(.black)
        .overlay {
            if feed.reels.isEmpty {
                if let message = feed.message {
                    ContentUnavailableView("Reels", systemImage: "play.rectangle.on.rectangle", description: Text(message))
                } else {
                    ProgressView()
                }
            }
        }
        .navigationTitle("Reels")
        .toolbar(removing: .title)
        .task { if feed.reels.isEmpty { await feed.loadMore(tmdb: model.tmdb) } }
        .task(id: current) {
            if current == nil { current = feed.reels.first?.id }
            if let reel = feed.reels.first(where: { $0.id == current }) { await feed.prepare(around: reel) }
        }
        .onChange(of: feed.reels.count) { _, _ in
            if current == nil, let first = feed.reels.first { current = first.id }
        }
    }
}

private struct ReelPage: View {
    @Environment(AppModel.self) private var model
    let reel: Reel
    let url: URL?
    let failed: Bool
    let isCurrent: Bool
    @State private var player: AVPlayer?
    @State private var paused = false
    @State private var looper: NSObjectProtocol?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: reel.item.backdropURL ?? reel.item.posterURL)
                .opacity(player == nil ? 1 : 0)
            if let player {
                PlayerLayer(player: player)
                    .contentShape(Rectangle())
                    .onTapGesture { togglePause() }
            }
            if paused {
                Image(systemName: "play.fill").font(.system(size: 56)).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }
            if failed {
                Label("This clip isn't available.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reel.item.title).font(.title2.bold())
                    Text([reel.item.year.map(String.init), reel.clipName].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if !reel.item.overview.isEmpty {
                        Text(reel.item.overview).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    NavigationLink(value: reel.item) {
                        Label(reel.item.kind == .movie ? "View Movie" : "View Series", systemImage: "info.circle")
                    }
                    .buttonStyle(.glass)
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
                VStack(spacing: 14) {
                    Button { model.toggleWatchlist(reel.item) } label: {
                        Label("Watchlist", systemImage: model.isOnWatchlist(reel.item) ? "bookmark.fill" : "bookmark")
                    }
                    Button { model.toggleFavorite(reel.item) } label: {
                        Label("Favorite", systemImage: model.isFavorite(reel.item) ? "heart.fill" : "heart")
                    }
                    if let imdb = reel.item.imdbID, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
                        ShareLink(item: url, subject: Text(reel.item.title)) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 110) // clear of the tab bar
        }
        .clipped()
        .contextMenu { TitleContextMenu(item: reel.item) }
        .onChange(of: isCurrent, initial: true) { _, now in now ? start() : stop() }
        .onChange(of: url) { _, _ in if isCurrent { start() } }
        .onDisappear { stop() }
    }

    private func start() {
        guard let url else { return }
        if player == nil {
            let player = AVPlayer(url: url)
            player.isMuted = false
            player.actionAtItemEnd = .none
            looper = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                            object: player.currentItem, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
            self.player = player
        }
        paused = false
        player?.play()
    }

    private func stop() {
        player?.pause()
        if let looper { NotificationCenter.default.removeObserver(looper) }
        looper = nil
        player = nil
        paused = false
    }

    private func togglePause() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play(); paused = false } else { player.pause(); paused = true }
    }
}

/// A bare `AVPlayerLayer`: video only, no controls, filling the page.
private struct PlayerLayer {
    let player: AVPlayer
}

#if os(iOS)
extension PlayerLayer: UIViewRepresentable {
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#else
extension PlayerLayer: NSViewRepresentable {
    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    }

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#endif
