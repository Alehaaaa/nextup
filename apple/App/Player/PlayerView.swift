import AVKit
import SwiftUI
import NextupKit

/// Owns the AVPlayer for one playback and reports progress to Continue Watching and Trakt.
@MainActor
@Observable
final class PlayerController {
    let player: AVPlayer
    private(set) var failure: String?
    private(set) var isReady = false

    private let request: PlaybackRequest
    private let model: AppModel
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var lastSaved: Double = 0
    private var scrobbleStarted = false

    init(request: PlaybackRequest, model: AppModel) {
        self.request = request
        self.model = model
        let item = AVPlayerItem(url: request.url)
        item.preferredForwardBufferDuration = 30
        self.player = AVPlayer(playerItem: item)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        observe(item)
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.handle(status: status, message: message) }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.save(force: false) }
        }
    }

    private func handle(status: AVPlayerItem.Status, message: String?) {
        switch status {
        case .readyToPlay where !isReady:
            isReady = true
            if let resume = model.progress.position(for: request.playbackKey), resume > 15 {
                player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player.play()
            scrobble(.start)
        case .failed:
            failure = Self.explain(message, url: request.url)
        default:
            break
        }
    }

    /// AVFoundation's errors are vague; most failures here are containers or codecs it cannot decode.
    private static func explain(_ message: String?, url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["mkv", "avi", "wmv", "flv", "webm"].contains(ext) {
            return "The built-in player cannot open .\(ext) files yet. Open it in VLC or Infuse, or pick an MP4 source."
        }
        return message ?? "This stream could not be played."
    }

    private var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    private var duration: Double {
        guard let d = player.currentItem?.duration.seconds, d.isFinite else { return 0 }
        return d
    }

    func save(force: Bool) {
        let position = self.position, duration = self.duration
        guard duration > 0, position > 5, force || abs(position - lastSaved) >= 10 else { return }
        lastSaved = position
        model.record(WatchProgress(item: request.item, season: request.season, episode: request.episode,
                                   episodeTitle: request.episodeTitle, position: position, duration: duration))
    }

    private func scrobble(_ action: TraktClient.ScrobbleAction) {
        guard model.trakt.isSignedIn else { return }
        if action == .start { scrobbleStarted = true }
        let trakt = model.trakt
        let item = request.item
        let episode = request.season.flatMap { s in request.episode.map { (season: s, number: $0) } }
        let progress = duration > 0 ? position / duration * 100 : 0
        Task.detached {
            try? await trakt.scrobble(action, item: item, episode: episode, progress: progress)
        }
    }

    func stop() {
        save(force: true)
        if scrobbleStarted { scrobble(.stop) }
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
    }

    /// Links that hand the stream to another player app.
    struct ExternalPlayer: Identifiable {
        let name: String
        let url: URL
        var id: String { name }
    }

    var externalPlayers: [ExternalPlayer] {
        let encoded = request.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var options: [ExternalPlayer] = []
        #if os(iOS)
        if let vlc = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)") { options.append(ExternalPlayer(name: "VLC", url: vlc)) }
        if let infuse = URL(string: "infuse://x-callback-url/play?url=\(encoded)") { options.append(ExternalPlayer(name: "Infuse", url: infuse)) }
        #endif
        options.append(ExternalPlayer(name: "Browser", url: request.url))
        return options
    }
}

struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let request: PlaybackRequest
    @State private var controller: PlayerController?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let controller {
                VideoPlayer(player: controller.player)
                    .ignoresSafeArea()
                if !controller.isReady && controller.failure == nil {
                    ProgressView().controlSize(.large).tint(.white)
                }
                if let failure = controller.failure {
                    failureCard(failure, controller: controller)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            #if os(iOS)
            Button { close() } label: {
                Image(systemName: "xmark").font(.headline).padding(14)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .padding()
            .accessibilityLabel("Close player")
            #endif
        }
        .navigationTitle(request.displayTitle)
        .onAppear {
            if controller == nil { controller = PlayerController(request: request, model: model) }
        }
        .onDisappear { controller?.stop() }
    }

    private func close() {
        controller?.stop()
        dismiss()
    }

    private func failureCard(_ message: String, controller: PlayerController) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.focus)
            Text(message).multilineTextAlignment(.center)
            HStack {
                ForEach(controller.externalPlayers) { option in
                    Button("Open in \(option.name)") { openURL(option.url) }.buttonStyle(.glass)
                }
                Button("Copy Link") { Clipboard.copy(request.url.absoluteString) }.buttonStyle(.glass)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .glassCard(cornerRadius: 18)
        .padding()
    }
}
