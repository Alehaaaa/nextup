import SwiftUI
import NextupKit

/// What tapping a source does: play it now, or save it to the device.
enum SourceIntent: Hashable { case play, download }

struct SourceTarget: Identifiable, Hashable {
    var item: MediaItem
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var intent: SourceIntent = .play

    var id: String { "\(item.id):\(season ?? 0):\(episode ?? 0):\(intent)" }
}

/// Every stream the installed addons offer for one movie or episode.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let target: SourceTarget
    /// Called with the stream to play; the presenter opens the player once this sheet is gone.
    let onPlay: (PlaybackRequest) -> Void

    @State private var lookup: StreamLookup?
    @State private var sort: SourceSort = .best
    @State private var qualityFilter: StreamQuality?
    @State private var addonFilter: String?
    @State private var cachedOnly = false
    @State private var resolvingID: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { filterMenu }
                }
        }
        .task {
            sort = model.preferences.sourceSort
            await load()
        }
        #if os(macOS)
        .frame(minWidth: 680, minHeight: 560)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var title: String {
        let base: String
        if let s = target.season, let e = target.episode {
            base = String(format: "%@ · S%02dE%02d", target.item.title, s, e)
        } else {
            base = target.item.title
        }
        return target.intent == .download ? "Download \(base)" : base
    }

    /// Sort, quality, addon and cached filters in one system menu.
    private var filterMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SourceSort.allCases) { Text($0.title).tag($0) }
            }
            Picker("Quality", selection: $qualityFilter) {
                Text("Any Quality").tag(StreamQuality?.none)
                ForEach(qualities, id: \.self) { Text($0.label).tag(StreamQuality?.some($0)) }
            }
            if addonNames.count > 1 {
                Picker("Addon", selection: $addonFilter) {
                    Text("All Addons").tag(String?.none)
                    ForEach(addonNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
            }
            Toggle("Cached Only", isOn: $cachedOnly)
        } label: {
            Label("Sort and Filter", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
    }

    private var isFiltering: Bool { qualityFilter != nil || addonFilter != nil || cachedOnly }

    private var qualities: [StreamQuality] {
        Array(Set((lookup?.streams ?? []).map(\.quality))).sorted(by: >)
    }

    private var addonNames: [String] {
        (lookup?.streams ?? []).compactMap(\.addonName).uniquedInOrder()
    }

    private var visible: [StremioStream] {
        model.preferences.arrange(lookup?.streams ?? [], sort: sort).filter { stream in
            if let qualityFilter, stream.quality != qualityFilter { return false }
            if let addonFilter, stream.addonName != addonFilter { return false }
            if cachedOnly, stream.traits.cache != .cached { return false }
            return true
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.addons.isEmpty && model.providers.enabledEngines.isEmpty {
            ContentUnavailableView("No addons or providers", systemImage: "puzzlepiece.extension",
                                   description: Text("Install a stream addon in Settings → Addons, or a provider in Settings → Providers, to see sources here."))
        } else if let lookup {
            let streams = visible
            if lookup.streams.isEmpty {
                ContentUnavailableView("No sources found", systemImage: "tray",
                                       description: Text(lookup.failedAddons.isEmpty ? "None of your addons had a stream for this title."
                                                                                     : "These addons did not answer: \(lookup.failedAddons.joined(separator: ", "))."))
            } else {
                List {
                    Section {
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        }
                        if model.activeDebrid == nil, lookup.streams.contains(where: { $0.infoHash != nil }) {
                            Label("Connect Real-Debrid, TorBox or AllDebrid in Settings to play torrent sources.", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        if let best = streams.first, target.intent == .play {
                            Button { Task { await open(best) } } label: {
                                Label("Play Best Source", systemImage: "bolt.fill")
                            }
                            .disabled(resolvingID != nil)
                        }
                        ForEach(streams) { stream in
                            Button { Task { await open(stream) } } label: {
                                StreamRow(stream: stream, isResolving: resolvingID == stream.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(resolvingID != nil)
                            .contextMenu {
                                Button { Task { await open(stream) } } label: { Label("Play", systemImage: "play") }
                                if let magnet = stream.magnet {
                                    Button { Clipboard.copy(magnet) } label: { Label("Copy Magnet Link", systemImage: "link") }
                                }
                                if let url = stream.url {
                                    Button { Clipboard.copy(url) } label: { Label("Copy Stream Link", systemImage: "link") }
                                }
                                if let name = stream.behaviorHints?.filename {
                                    Button { Clipboard.copy(name) } label: { Label("Copy File Name", systemImage: "doc.on.doc") }
                                }
                            }
                        }
                    } header: {
                        Text(summary(lookup, shown: streams.count))
                    } footer: {
                        if !lookup.failedAddons.isEmpty {
                            Text("Did not answer: \(lookup.failedAddons.joined(separator: ", ")). Pull down to try again.")
                        }
                    }
                }
                .refreshable { await load() }
                .overlay {
                    if streams.isEmpty {
                        ContentUnavailableView("No sources match", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Change the filters, or the source options in Settings."))
                    }
                }
            }
        } else {
            ProgressView("Asking your addons…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ lookup: StreamLookup, shown: Int) -> String {
        let cached = lookup.streams.filter { $0.traits.cache == .cached }.count
        var parts = ["\(shown) of \(lookup.streams.count) sources"]
        if cached > 0 { parts.append("\(cached) cached") }
        parts.append(lookup.askedAddons == 1 ? "1 source list" : "\(lookup.askedAddons) source lists")
        return parts.joined(separator: " · ")
    }

    private func load() async {
        lookup = await model.streams(for: target)
    }

    private func open(_ stream: StremioStream) async {
        error = nil
        if let yt = stream.ytId, let url = URL(string: "https://www.youtube.com/watch?v=\(yt)") { openURL(url); return }
        if let external = stream.externalUrl, let url = URL(string: external) { openURL(url); return }

        resolvingID = stream.id
        defer { resolvingID = nil }
        do {
            let resolved = try await model.resolve(stream, for: target)
            switch target.intent {
            case .download:
                model.downloads.start(url: resolved.url, item: target.item, season: target.season, episode: target.episode,
                                      episodeTitle: target.episodeTitle, filename: resolved.filename)
                dismiss()
            case .play:
                let request = PlaybackRequest(url: resolved.url, item: target.item, season: target.season, episode: target.episode,
                                              episodeTitle: target.episodeTitle, sourceLabel: stream.headline)
                onPlay(request)
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StreamRow: View {
    let stream: StremioStream
    let isResolving: Bool

    var body: some View {
        let traits = stream.traits
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                Text(traits.quality.label)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.tint)
                if traits.cache == .cached {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.yellow)
                        .accessibilityLabel("Cached")
                }
            }
            .frame(width: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text(primaryLine)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if !traits.badges.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(traits.badges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.quaternary, in: .capsule)
                        }
                    }
                    .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let size = Format.bytes(traits.sizeBytes) { Label(size, systemImage: "internaldrive") }
                    if let seeders = traits.seeders { Label("\(seeders)", systemImage: "person.2") }
                    if !traits.languages.isEmpty { Text(traits.languages.prefix(4).joined(separator: " ")) }
                    if let addon = stream.addonName { Label(addon, systemImage: "puzzlepiece.extension") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                if let group = traits.group {
                    Text(group).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if isResolving {
                ProgressView().controlSize(.small)
            } else if stream.infoHash != nil, traits.cache == .notCached {
                Text("Not cached").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// The release name when the addon gives one, else its own heading.
    private var primaryLine: String {
        if let file = stream.behaviorHints?.filename, !file.isEmpty { return file }
        if let first = stream.title?.components(separatedBy: "\n").first, !first.isEmpty { return first }
        if let first = stream.description?.components(separatedBy: "\n").first, !first.isEmpty { return first }
        return stream.headline.replacingOccurrences(of: "\n", with: " ")
    }
}

extension Sequence where Element: Hashable {
    func uniquedInOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
