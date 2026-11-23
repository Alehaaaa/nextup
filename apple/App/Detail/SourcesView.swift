import SwiftUI
import NextupKit

struct SourceTarget: Identifiable, Hashable {
    var item: MediaItem
    var season: Int?
    var episode: Int?
    var episodeTitle: String?

    var id: String { "\(item.id):\(season ?? 0):\(episode ?? 0)" }
}

/// Every stream the installed addons offer for one movie or episode.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let target: SourceTarget
    /// Called with the stream to play; the presenter opens the player once this sheet is gone.
    let onPlay: (PlaybackRequest) -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case addon = "Addon order", quality = "Quality", size = "Size"
        var id: String { rawValue }
    }

    @State private var lookup: StreamLookup?
    @State private var sort: Sort = .addon
    @State private var resolvingID: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .inlineTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Sort", selection: $sort) {
                            ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                }
        }
        .task { await load() }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var title: String {
        guard let s = target.season, let e = target.episode else { return target.item.title }
        return String(format: "%@ · S%02dE%02d", target.item.title, s, e)
    }

    @ViewBuilder
    private var content: some View {
        if model.addons.isEmpty {
            ContentUnavailableView("No addons installed", systemImage: "puzzlepiece.extension",
                                   description: Text("Install a stream addon in Settings → Addons to see sources here."))
        } else if let lookup {
            if sorted(lookup.streams).isEmpty {
                ContentUnavailableView("No sources found", systemImage: "tray",
                                       description: Text(lookup.failedAddons.isEmpty ? "None of your addons had a stream for this title."
                                                                                     : "These addons did not answer: \(lookup.failedAddons.joined(separator: ", "))."))
            } else {
                List {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                    }
                    if model.activeDebrid == nil, lookup.streams.contains(where: { $0.infoHash != nil }) {
                        Label("Connect Real-Debrid or TorBox in Settings to play torrent sources.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(sorted(lookup.streams)) { stream in
                        Button { Task { await open(stream) } } label: {
                            StreamRow(stream: stream, isResolving: resolvingID == stream.id)
                        }
                        .buttonStyle(.plain)
                        .disabled(resolvingID != nil)
                        .contextMenu {
                            if let magnet = stream.magnet {
                                Button("Copy Magnet Link") { Clipboard.copy(magnet) }
                            }
                            if let url = stream.url {
                                Button("Copy Stream Link") { Clipboard.copy(url) }
                            }
                        }
                    }
                    if !lookup.failedAddons.isEmpty {
                        Text("Did not answer: \(lookup.failedAddons.joined(separator: ", "))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            ProgressView("Asking your addons…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func sorted(_ streams: [StremioStream]) -> [StremioStream] {
        switch sort {
        case .addon: return streams
        case .quality:
            return streams.enumerated().sorted { a, b in
                a.element.quality != b.element.quality ? a.element.quality > b.element.quality : a.offset < b.offset
            }.map(\.element)
        case .size:
            return streams.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }
    }

    private func load() async {
        guard let imdb = target.item.imdbID else {
            lookup = StreamLookup(streams: [], failedAddons: [], askedAddons: 0)
            return
        }
        let id = AddonClient.videoID(imdbID: imdb, season: target.season, episode: target.episode)
        lookup = await model.addonClient.streams(from: model.addons, type: target.item.kind.stremioType, id: id)
    }

    private func open(_ stream: StremioStream) async {
        error = nil
        if let yt = stream.ytId, let url = URL(string: "https://www.youtube.com/watch?v=\(yt)") { openURL(url); return }
        if let external = stream.externalUrl, let url = URL(string: external) { openURL(url); return }

        resolvingID = stream.id
        defer { resolvingID = nil }
        do {
            let url: URL
            if let direct = stream.url, let parsed = URL(string: direct) {
                url = parsed
            } else if let magnet = stream.magnet {
                guard let debrid = model.activeDebrid else {
                    throw HTTPError.notConfigured("A debrid service")
                }
                let hint = FileHint(fileIndex: stream.fileIdx, filename: stream.behaviorHints?.filename,
                                    season: target.season, episode: target.episode)
                url = try await debrid.resolve(magnet: magnet, hint: hint).url
            } else {
                throw DebridError.noPlayableFile
            }
            let request = PlaybackRequest(url: url, item: target.item, season: target.season, episode: target.episode,
                                          episodeTitle: target.episodeTitle, sourceLabel: stream.headline)
            onPlay(request)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct StreamRow: View {
    let stream: StremioStream
    let isResolving: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(stream.quality.label)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .glassEffect(.regular.tint(Theme.accent.opacity(0.6)), in: Capsule())
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.headline.replacingOccurrences(of: "\n", with: " "))
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                if !stream.label.isEmpty {
                    Text(stream.label).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                }
                HStack(spacing: 8) {
                    if let addon = stream.addonName { Text(addon) }
                    if let size = Format.bytes(stream.sizeBytes) { Text(size) }
                    if stream.infoHash != nil { Text("Torrent") } else if stream.url != nil { Text("Direct") }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if isResolving { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
