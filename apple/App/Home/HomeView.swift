import SwiftUI
import NextupKit

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var rails: [MediaRail] = []
    @State private var hero: MediaItem?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let hero { HeroBanner(item: hero) }

                let continueWatching = model.continueWatching()
                if !continueWatching.isEmpty {
                    PosterRail(title: "Continue Watching", items: continueWatching) { entry in
                        NavigationLink(value: entry.item) {
                            PosterCard(item: entry.item, progress: entry.fraction, caption: caption(for: entry))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            TitleContextMenu(item: entry.item) { model.removeFromContinueWatching(entry.id) }
                        }
                    }
                }

                ForEach(rails) { rail in
                    PosterRail(title: rail.title, items: rail.items) { item in
                        NavigationLink(value: item) { PosterCard(item: item) }
                            .buttonStyle(.plain)
                            .contextMenu { TitleContextMenu(item: item) }
                    }
                }

                if rails.isEmpty && !isLoading {
                    GetStartedCard(error: loadError)
                        .padding(.horizontal)
                }
            }
            .padding(.bottom, 32)
        }
        .overlay { if isLoading && rails.isEmpty { ProgressView() } }
        .nextupBackground()
        .navigationTitle("Home")
        .inlineTitle()
        .refreshable { await load() }
        .task(id: "\(model.accountsRevision)-\(model.addons.count)") { await load() }
    }

    private func caption(for entry: WatchProgress) -> String {
        if let season = entry.season, let episode = entry.episode {
            return String(format: "S%02dE%02d", season, episode)
        }
        return Format.remaining(position: entry.position, duration: entry.duration)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        loadError = nil

        let tmdb = model.tmdb
        let addonClient = model.addonClient
        let addons = model.addons.filter(\.enabled)

        var loaded: [(Int, MediaRail)] = []
        await withTaskGroup(of: (Int, MediaRail?).self) { group in
            if tmdb.isConfigured {
                for (i, list) in TMDBClient.ListKind.allCases.enumerated() {
                    group.addTask {
                        let items = (try? await tmdb.list(list)) ?? []
                        return (i, items.isEmpty ? nil : MediaRail(id: "tmdb.\(list.rawValue)", title: list.title, items: items))
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
                        let title = "\(catalog.name ?? catalog.id) · \(addon.manifest.name)"
                        return (slot, metas.isEmpty ? nil : MediaRail(id: "\(addon.id)/\(catalog.identity)", title: title,
                                                                       items: metas.map(\.mediaItem)))
                    }
                }
            }
            for await (slot, rail) in group {
                if let rail { loaded.append((slot, rail)) }
            }
        }
        rails = loaded.sorted { $0.0 < $1.0 }.map(\.1)
        hero = rails.first?.items.first { $0.backdropURL != nil }
        if rails.isEmpty && (tmdb.isConfigured || !addons.isEmpty) {
            loadError = "Nothing loaded. Check your connection, TMDB token and addons."
        }
    }
}

private struct HeroBanner: View {
    let item: MediaItem

    var body: some View {
        NavigationLink(value: item) {
            ZStack(alignment: .bottomLeading) {
                ArtworkImage(url: item.backdropURL)
                    .frame(maxWidth: .infinity)
                    .frame(height: heroHeight)
                    .clipped()
                LinearGradient(colors: [.clear, Theme.background], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title).font(.largeTitle.weight(.bold)).lineLimit(2)
                    if !item.overview.isEmpty {
                        Text(item.overview).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            .frame(maxWidth: 560, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .buttonStyle(.plain)
    }

    private var heroHeight: CGFloat {
        #if os(macOS)
        return 420
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 440 : 300
        #endif
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
                .buttonStyle(.borderedProminent)
            #else
            Text("Open the Settings tab to get started.").font(.footnote).foregroundStyle(.secondary)
            #endif
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
