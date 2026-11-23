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
    /// Called once if the stream cannot be played, so the presenter can offer other players.
    var onFailure: ((String) -> Void)?

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
            let text = Self.explain(message, url: request.url)
            failure = text
            onFailure?(text)
            onFailure = nil
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
    var externalPlayers: [ExternalPlayer] { ExternalPlayer.options(for: request.url) }
}

/// Another app that can take over a stream the built-in player cannot decode.
struct ExternalPlayer: Identifiable {
    let name: String
    let url: URL
    var id: String { name }

    static func options(for url: URL) -> [ExternalPlayer] {
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var options: [ExternalPlayer] = []
        #if os(iOS)
        if let vlc = URL(string: "vlc-x-callback://x-callback-url/stream?url=\(encoded)") { options.append(ExternalPlayer(name: "VLC", url: vlc)) }
        if let infuse = URL(string: "infuse://x-callback-url/play?url=\(encoded)") { options.append(ExternalPlayer(name: "Infuse", url: infuse)) }
        #endif
        options.append(ExternalPlayer(name: "Browser", url: url))
        return options
    }
}


/// Shown with a system alert when a stream fails.
struct PlaybackFailure: Identifiable {
    let request: PlaybackRequest
    let message: String
    var id: String { request.id }
}

#if os(iOS)

/// The system player, presented the system way: full screen, with its own close button,
/// Picture in Picture, AirPlay, and audio and subtitle menus.
@MainActor
enum NativePlayer {
    static func present(_ request: PlaybackRequest, model: AppModel) {
        let controller = PlayerController(request: request, model: model)
        let viewController = NativePlayerViewController()
        viewController.controller = controller
        viewController.player = controller.player
        viewController.allowsPictureInPicturePlayback = true
        viewController.canStartPictureInPictureAutomaticallyFromInline = true
        viewController.modalPresentationStyle = .fullScreen
        controller.onFailure = { [weak viewController] message in
            viewController?.dismiss(animated: true) {
                model.playbackFailure = PlaybackFailure(request: request, message: message)
            }
        }
        topViewController()?.present(viewController, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Keeps the playback session alive for as long as the player (or its Picture in Picture window) is up.
final class NativePlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    var controller: PlayerController?
    private var pictureInPictureActive = false
    private weak var restoreFrom: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Leaving for Picture in Picture is not the end of playback.
        if isBeingDismissed, !pictureInPictureActive { finish() }
    }

    private func finish() {
        controller?.stop()
        controller = nil
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPictureActive = true
        restoreFrom = presentingViewController
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        pictureInPictureActive = false
        if presentingViewController == nil { finish() }
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard presentingViewController == nil, let host = restoreFrom else { completionHandler(true); return }
        host.present(self, animated: true) { completionHandler(true) }
    }
}
#endif

#if os(macOS)

/// The system player view in its own window, with floating controls, full screen and Picture in Picture.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let request: PlaybackRequest
    @State private var controller: PlayerController?
    @State private var failure: String?

    var body: some View {
        Group {
            if let controller {
                SystemPlayerView(player: controller.player)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .navigationTitle(request.displayTitle)
        .onAppear {
            guard controller == nil else { return }
            let controller = PlayerController(request: request, model: model)
            controller.onFailure = { failure = $0 }
            self.controller = controller
        }
        .onDisappear { controller?.stop() }
        .alert("Can't play this stream", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            ForEach(ExternalPlayer.options(for: request.url)) { option in
                Button("Open in \(option.name)") { openURL(option.url) }
            }
            Button("Copy Link") { Clipboard.copy(request.url.absoluteString) }
            Button("Close", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}

private struct SystemPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#endif
