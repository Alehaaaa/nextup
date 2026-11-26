import SwiftUI
import NextupKit

/// Everything saved to this device. Opens and plays fully offline.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.play) private var play

    var body: some View {
        let downloads = model.downloads
        List {
            if !downloads.active.isEmpty {
                Section("In Progress") {
                    ForEach(downloads.active) { record in
                        ActiveDownloadRow(record: record)
                            .contextMenu { menu(for: record) }
                            .swipeActions { deleteButton(record) }
                    }
                }
            }
            Section {
                if downloads.library.isEmpty {
                    Text("Movies and episodes you download appear here and play without a connection.")
                        .foregroundStyle(.secondary)
                }
                ForEach(downloads.library) { record in
                    if record.season != nil {
                        NavigationLink {
                            DownloadedShowView(item: record.item)
                        } label: {
                            DownloadedRow(item: record.item, subtitle: episodesSubtitle(record.item))
                        }
                        .contextMenu {
                            Button(role: .destructive) { downloads.deleteAll(of: record.item) } label: {
                                Label("Delete All Episodes", systemImage: "trash")
                            }
                        }
                    } else {
                        Button { playLocal(record) } label: {
                            DownloadedRow(item: record.item, subtitle: Format.bytes(record.totalBytes) ?? "Downloaded")
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: record) }
                        .swipeActions { deleteButton(record) }
                    }
                }
            } header: {
                Text("Downloaded")
            } footer: {
                Text(storageLine(downloads))
            }
        }
        .navigationTitle("Downloads")
    }

    private func storageLine(_ downloads: DownloadManager) -> String {
        let used = Format.bytes(downloads.usedBytes) ?? "Nothing"
        guard let free = Format.bytes(DownloadManager.availableBytes) else { return "\(used) used." }
        return "\(used) used · \(free) available"
    }

    private func episodesSubtitle(_ item: MediaItem) -> String {
        let count = model.downloads.downloadedEpisodes(of: item).filter { $0.state == .finished }.count
        return count == 1 ? "1 episode" : "\(count) episodes"
    }

    private func playLocal(_ record: DownloadRecord) {
        guard let url = model.downloads.localURL(for: record.id) else { return }
        play?.callAsFunction(PlaybackRequest(url: url, item: record.item, season: record.season, episode: record.episode,
                                             episodeTitle: record.episodeTitle, sourceLabel: "Downloaded"))
    }

    @ViewBuilder
    private func menu(for record: DownloadRecord) -> some View {
        let downloads = model.downloads
        switch record.state {
        case .finished:
            Button { playLocal(record) } label: { Label("Play", systemImage: "play") }
        case .downloading, .queued:
            Button { downloads.pause(record.id) } label: { Label("Pause", systemImage: "pause") }
        case .paused, .failed:
            Button { downloads.resume(record.id) } label: { Label(record.state == .failed ? "Retry" : "Resume", systemImage: "arrow.clockwise") }
        }
        Button(role: .destructive) { downloads.delete(record.id) } label: { Label("Delete", systemImage: "trash") }
    }

    private func deleteButton(_ record: DownloadRecord) -> some View {
        Button(role: .destructive) { model.downloads.delete(record.id) } label: { Label("Delete", systemImage: "trash") }
    }
}

private struct ActiveDownloadRow: View {
    @Environment(AppModel.self) private var model
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: record.item.posterURL)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(record.item.title).font(.headline).lineLimit(1)
                if record.season != nil { Text(record.displayTitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                ProgressView(value: record.fraction)
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Button {
                record.state == .downloading ? model.downloads.pause(record.id) : model.downloads.resume(record.id)
            } label: {
                Label(record.state == .downloading ? "Pause" : "Resume",
                      systemImage: record.state == .downloading ? "pause.circle" : "arrow.down.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.title2)
        }
    }

    private var status: String {
        switch record.state {
        case .failed: return record.error ?? "Failed"
        case .paused: return "Paused"
        case .queued: return "Waiting"
        default:
            let received = Format.bytes(record.receivedBytes) ?? "0 MB"
            guard let total = Format.bytes(record.totalBytes) else { return received }
            return "\(received) of \(total)"
        }
    }
}

private struct DownloadedRow: View {
    let item: MediaItem
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: item.posterURL)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(1)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

/// The downloaded episodes of one show.
private struct DownloadedShowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.play) private var play
    let item: MediaItem

    var body: some View {
        let episodes = model.downloads.downloadedEpisodes(of: item)
            .filter { $0.state == .finished }
            .sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
        List {
            ForEach(episodes) { record in
                Button {
                    if let url = model.downloads.localURL(for: record.id) {
                        play?.callAsFunction(PlaybackRequest(url: url, item: item, season: record.season, episode: record.episode,
                                                             episodeTitle: record.episodeTitle, sourceLabel: "Downloaded"))
                    }
                } label: {
                    LabeledContent(record.displayTitle, value: Format.bytes(record.totalBytes) ?? "")
                }
                .contextMenu {
                    Button(role: .destructive) { model.downloads.delete(record.id) } label: { Label("Delete", systemImage: "trash") }
                }
                .swipeActions {
                    Button(role: .destructive) { model.downloads.delete(record.id) } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .navigationTitle(item.title)
    }
}
