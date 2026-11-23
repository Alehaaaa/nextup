import SwiftUI
import NextupKit

/// A Home row and how it is drawn.
struct HomeRail: Identifiable {
    var rail: MediaRail
    var style: RailStyle
    var id: String { rail.id }
}

/// The hero on top, and the rows ("branches") under it.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var rails: [HomeRail] = []
    @State private var heroes: [MediaItem] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !heroes.isEmpty {
                    HeroCarousel(items: heroes)
                }

                let continueWatching = model.continueWatching()
                if !continueWatching.isEmpty {
                    PosterRail(title: "Continue Watching", items: continueWatching) { entry in
                        NavigationLink(value: entry.item) {
                            WideCard(item: entry.item, progress: entry.fraction, caption: caption(for: entry))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            TitleContextMenu(item: entry.item) { model.removeFromContinueWatching(entry.id) }
                        }
                    }
                }

                ForEach(rails) { row in
                    rail(row)
                }

                if rails.isEmpty && !isLoading {
                    GetStartedCard(error: loadError)
                        .padding(.horizontal, Theme.gutter)
                        .padding(.top, heroes.isEmpty ? 24 : 0)
                }
            }
            .padding(.bottom, 40)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(edges: heroes.isEmpty ? [] : .top)
        .overlay { if isLoading && rails.isEmpty { ProgressView().controlSize(.large) } }
        .nextupBackground()
        .navigationTitle("Home")
        .inlineTitle()
        .refreshable { await load() }
        .task(id: "\(model.accountsRevision)-\(model.addons.count)") { await load() }
    }

    @ViewBuilder
    private func rail(_ row: HomeRail) -> some View {
        switch row.style {
        case .poster:
            PosterRail(title: row.rail.title, items: row.rail.items) { item in
                NavigationLink(value: item) { PosterCard(item: item) }
                    .buttonStyle(.plain)
                    .contextMenu { TitleContextMenu(item: item) }
            }
        case .wide:
            PosterRail(title: row.rail.title, items: row.rail.items) { item in
                NavigationLink(value: item) {
                    WideCard(item: item, caption: [item.year.map(String.init), item.rating.map { String(format: "★ %.1f", $0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                }
                .buttonStyle(.plain)
                .contextMenu { TitleContextMenu(item: item) }
            }
        case .top10:
            PosterRail(title: row.rail.title, items: Self.ranked(row.rail.items)) { entry in
                NavigationLink(value: entry.item) { Top10Card(item: entry.item, rank: entry.rank) }
                    .buttonStyle(.plain)
                    .contextMenu { TitleContextMenu(item: entry.item) }
            }
        }
    }

    private static func ranked(_ items: [MediaItem]) -> [RankedItem] {
        items.prefix(10).enumerated().map { RankedItem(rank: $0.offset + 1, item: $0.element) }
    }

    private func caption(for entry: WatchProgress) -> String {
        if let season = entry.season, let episode = entry.episode {
            return String(format: "S%02dE%02d", season, episode) + (entry.episodeTitle.map { " · \($0)" } ?? "")
        }
        return Format.remaining(position: entry.position, duration: entry.duration)
    }

    private static func style(for list: TMDBClient.ListKind) -> RailStyle {
        switch list {
        case .trendingMovies, .trendingSeries: return .poster
        case .popularMovies, .popularSeries: return .wide
        case .topRatedMovies, .topRatedSeries: return .top10
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil

        let tmdb = model.tmdb
        let addonClient = model.addonClient
        let addons = model.addons.filter(\.enabled)

        var loaded: [(Int, HomeRail)] = []
        await withTaskGroup(of: (Int, HomeRail?).self) { group in
            if tmdb.isConfigured {
                for (i, list) in TMDBClient.ListKind.allCases.enumerated() {
                    let style = Self.style(for: list)
                    group.addTask {
                        let items = (try? await tmdb.list(list)) ?? []
                        guard !items.isEmpty else { return (i, nil) }
                        let rail = MediaRail(id: "tmdb.\(list.rawValue)", title: list.title, items: items)
                        return (i, HomeRail(rail: rail, style: style))
                    }
                }
            }
            // Addon catalogs follow, in the order the addons are listed in Settings.
            var order = 100
            for addon in addons {
                for catalog in addon.manifest.catalogs where !catalog.requiresInput && ["movie", "series"].contains(catalog.type) {
                    let slot = order
                    order += 1
                    group.addTask {
                        let metas = (try? await addonClient.catalog(from: addon, catalog: catalog)) ?? []
                        guard !metas.isEmpty else { return (slot, nil) }
                        let rail = MediaRail(id: "\(addon.id)/\(catalog.identity)",
                                             title: "\(catalog.name ?? catalog.id) · \(addon.manifest.name)",
                                             items: metas.map(\.mediaItem))
                        return (slot, HomeRail(rail: rail, style: .poster))
                    }
                }
            }
            for await (slot, rail) in group {
                if let rail { loaded.append((slot, rail)) }
            }
        }
        rails = loaded.sorted { $0.0 < $1.0 }.map(\.1)
        heroes = Array((rails.first?.rail.items ?? []).filter { $0.backdropURL != nil }.prefix(6))
        if rails.isEmpty && (tmdb.isConfigured || !addons.isEmpty) {
            loadError = "Nothing loaded. Check your connection, TMDB token and addons."
        }
    }
}

private struct RankedItem: Identifiable {
    let rank: Int
    let item: MediaItem
    var id: String { item.id }
}

/// Full-bleed hero that pages through a few featured titles. The artwork extends under the
/// glass toolbar and sidebar, and the controls sit on Liquid Glass.
private struct HeroCarousel: View {
    let items: [MediaItem]
    @State private var page: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    HeroPage(item: item)
                        .containerRelativeFrame(.horizontal)
                        .id(item.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .frame(height: HeroPage.height)
        .overlay(alignment: .bottom) {
            if items.count > 1 {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        Capsule()
                            .fill(.white.opacity((page ?? items.first?.id) == item.id ? 0.95 : 0.35))
                            .frame(width: (page ?? items.first?.id) == item.id ? 18 : 6, height: 6)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 10)
                .animation(.snappy, value: page)
            }
        }
    }
}

private struct HeroPage: View {
    let item: MediaItem

    static var height: CGFloat {
        #if os(macOS)
        return 520
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 560 : 520
        #endif
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkImage(url: item.backdropURL)
                .frame(maxWidth: .infinity)
                .frame(height: Self.height)
                .clipped()
                .backgroundExtensionEffect()
            LinearGradient(stops: [
                .init(color: .clear, location: 0.35),
                .init(color: Theme.background.opacity(0.7), location: 0.75),
                .init(color: Theme.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                Text(item.kind == .movie ? "MOVIE" : "SERIES")
                    .font(.caption.weight(.bold)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.7))
                Text(item.title)
                    .font(.system(size: 38, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 10) {
                    if let year = item.year { Text(String(year)) }
                    if let rating = item.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                if !item.overview.isEmpty {
                    Text(item.overview)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        NavigationLink(value: item) {
                            Label("Watch", systemImage: "play.fill").padding(.horizontal, 6)
                        }
                        .buttonStyle(.glassProminent)
                        NavigationLink(value: item) {
                            Label("Details", systemImage: "info.circle")
                        }
                        .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 40)
        }
    }
}

private struct GetStartedCard: View {
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Set up Nextup", systemImage: "sparkles").font(.headline)
            Text(error ?? "Add a TMDB token for Home rows and search, install addons for catalogs and streams, and connect Real-Debrid or TorBox to play.")
                .foregroundStyle(.secondary)
            #if os(macOS)
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.glassProminent)
            #else
            Text("Open the Settings tab to get started.").font(.footnote).foregroundStyle(.secondary)
            #endif
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
