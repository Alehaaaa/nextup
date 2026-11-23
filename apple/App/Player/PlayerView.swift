import AVKit
import SwiftUI
import NextupKit

/// Owns the AVPlayer for one viewing session (which can run through several episodes) and reports
/// progress to Continue Watching and Trakt. Also drives Skip Intro and the Up Next popup.
@MainActor
@Observable
final class PlayerController {
    let player: AVPlayer
    private(set) var failure: String?
    private(set) var isReady = false
    /// Called once if the stream cannot be played, so the presenter can offer other players.
    @ObservationIgnored var onFailure: ((String) -> Void)?

    private(set) var request: PlaybackRequest
    /// The intro being played right now, if any: shows "Skip Intro".
    private(set) var activeIntro: SkipSegment?
    /// The episode that follows, once known.
    private(set) var nextEpisode: Episode?
    /// Up Next is on screen, counting down to `nextEpisode`.
    private(set) var upNextVisible = false
    private(set) var countdown = 0
    private(set) var isAdvancing = false

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var tickObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastSaved: Double = 0
    @ObservationIgnored private var scrobbleStarted = false
    @ObservationIgnored private var segments = SkipSegments.empty
    @ObservationIgnored private var skippedIntros: Set<Double> = []
    @ObservationIgnored private var upNextDismissed = false
    @ObservationIgnored private var countdownTask: Task<Void, Never>?

    static let upNextCountdown = 10
    /// Without credits data, Up Next appears this long before the end.
    static let upNextLeadTime: Double = 35

    init(request: PlaybackRequest, model: AppModel) {
        self.request = request
        self.model = model
        self.player = AVPlayer()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        tickObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.save(force: false) }
        }
        load(request)
    }

    private func load(_ request: PlaybackRequest) {
        self.request = request
        isReady = false
        failure = nil
        activeIntro = nil
        nextEpisode = nil
        upNextVisible = false
        upNextDismissed = false
        segments = .empty
        skippedIntros = []
        lastSaved = 0
        scrobbleStarted = false

        let item = AVPlayerItem(url: request.url)
        item.preferredForwardBufferDuration = 30
        #if !os(macOS)
        item.externalMetadata = Self.metadata(for: request)
        #endif
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in self?.handle(status: status, message: message) }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.itemEnded() }
        }
        player.replaceCurrentItem(with: item)
    }

    /// Title and artwork for the system player's info panel and Now Playing.
    private static func metadata(for request: PlaybackRequest) -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item.copy() as! AVMetadataItem
        }
        var items = [entry(.commonIdentifierTitle, request.displayTitle)]
        if !request.item.overview.isEmpty { items.append(entry(.commonIdentifierDescription, request.item.overview)) }
        return items
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
            Task { await prepareEpisodeExtras() }
        case .failed:
            let text = Self.explain(message, url: request.url)
            failure = text
            onFailure?(text)
            onFailure = nil
        default:
            break
        }
    }

    /// Fetches intro/credits times and the next episode for shows.
    private func prepareEpisodeExtras() async {
        guard request.item.kind == .series, let season = request.season, let episode = request.episode else { return }
        let item = request.item, key = request.playbackKey
        async let next = model.nextEpisode(after: item, season: season, episode: episode)
        if let imdb = item.imdbID {
            let duration = self.duration
            let fetched = await SkipSegmentsClient().fetch(imdbID: imdb, season: season, episode: episode, duration: duration)
            if request.playbackKey == key { segments = fetched }
        }
        let found = await next
        if request.playbackKey == key { nextEpisode = found }
    }

    private func tick() {
        guard isReady, !isAdvancing else { return }
        let position = self.position
        activeIntro = segments.intros.first { $0.contains(position) && !skippedIntros.contains($0.start) && $0.end - position > 2 }

        guard nextEpisode != nil, !upNextDismissed, duration > 0 else { return }
        let creditsStart = segments.outros.first?.start ?? max(0, duration - Self.upNextLeadTime)
        if position >= creditsStart, !upNextVisible {
            showUpNext()
        } else if position < creditsStart - 1, upNextVisible {
            // Seeked back out of the credits.
            hideUpNext()
        }
    }

    // MARK: Skip Intro

    func skipIntro() {
        guard let intro = activeIntro else { return }
        skippedIntros.insert(intro.start)
        activeIntro = nil
        player.seek(to: CMTime(seconds: intro.end, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Up Next

    private func showUpNext() {
        upNextVisible = true
        countdown = Self.upNextCountdown
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            while let self, self.countdown > 0, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if self.player.timeControlStatus == .playing { self.countdown -= 1 }
            }
            guard let self, !Task.isCancelled else { return }
            await self.playNext()
        }
    }

    private func hideUpNext() {
        upNextVisible = false
        countdownTask?.cancel()
        countdownTask = nil
    }

    /// "Keep watching the credits".
    func dismissUpNext() {
        upNextDismissed = true
        hideUpNext()
    }

    private func itemEnded() {
        if nextEpisode != nil, !upNextDismissed {
            Task { await playNext() }
        }
    }

    func playNext() async {
        guard let next = nextEpisode, !isAdvancing else { return }
        isAdvancing = true
        hideUpNext()
        defer { isAdvancing = false }
        // The current episode counts as watched.
        let finishing = request
        if duration > 0 {
            model.record(WatchProgress(item: finishing.item, season: finishing.season, episode: finishing.episode,
                                       episodeTitle: finishing.episodeTitle, position: duration, duration: duration))
        }
        if scrobbleStarted { scrobble(.stop, progress: 100) }
        do {
            let request = try await model.playbackRequest(for: finishing.item, episode: next)
            load(request)
        } catch {
            failure = error.localizedDescription
            onFailure?(error.localizedDescription)
        }
    }

    // MARK: Progress

    /// AVFoundation's errors are vague; most failures here are containers or codecs it cannot decode.
    private static func explain(_ message: String?, url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ["mkv", "avi", "wmv", "flv", "webm"].contains(ext) {
            return "The built-in player cannot open .\(ext) files yet. Open it in VLC or Infuse, or pick an MP4 source."
        }
        return message ?? "This stream could not be played."
    }

    var position: Double { player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0 }
    var duration: Double {
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

    private func scrobble(_ action: TraktClient.ScrobbleAction, progress override: Double? = nil) {
        guard model.trakt.isSignedIn else { return }
        if action == .start { scrobbleStarted = true }
        let trakt = model.trakt
        let item = request.item
        let episode = request.season.flatMap { s in request.episode.map { (season: s, number: $0) } }
        let progress = override ?? (duration > 0 ? position / duration * 100 : 0)
        Task.detached {
            try? await trakt.scrobble(action, item: item, episode: episode, progress: progress)
        }
    }

    func stop() {
        save(force: true)
        if scrobbleStarted { scrobble(.stop) }
        scrobbleStarted = false
        countdownTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let tickObserver { player.removeTimeObserver(tickObserver) }
        timeObserver = nil
        tickObserver = nil
        statusObservation?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// Links that hand the stream to another player app.
    var externalPlayers: [ExternalPlayer] { ExternalPlayer.options(for: request.url) }
}

/// Skip Intro and Up Next, drawn over the system player with system components.
struct PlayerOverlay: View {
    let controller: PlayerController

    var body: some View {
        Group {
            if controller.upNextVisible, let next = controller.nextEpisode {
                UpNextCard(episode: next, countdown: controller.countdown,
                           play: { Task { await controller.playNext() } },
                           dismiss: { controller.dismissUpNext() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if controller.activeIntro != nil {
                Button("Skip Intro") { controller.skipIntro() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .transition(.opacity)
            } else if controller.isAdvancing {
                ProgressView("Loading next episode…")
                    .padding()
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
        }
        .animation(.smooth, value: controller.upNextVisible)
        .animation(.smooth, value: controller.activeIntro)
        .padding(24)
    }
}

private struct UpNextCard: View {
    let episode: Episode
    let countdown: Int
    let play: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ArtworkImage(url: episode.stillURL)
                .frame(width: 128, height: 72)
                .clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text("Up Next in \(countdown)").font(.caption).foregroundStyle(.secondary)
                Text(episode.code).font(.caption.weight(.semibold))
                Text(episode.title).font(.headline).lineLimit(1)
                HStack {
                    Button("Play Now", systemImage: "play.fill", action: play)
                        .buttonStyle(.glassProminent)
                    Button("Watch Credits", action: dismiss)
                        .buttonStyle(.glass)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .frame(maxWidth: 460)
    }
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
        viewController.controller = controller  // set before the view loads so the overlay can attach
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
        installOverlay()
    }

    /// Skip Intro / Up Next float above the system controls, bottom-right, in a hosting view sized to
    /// its content so the rest of the screen still reaches the player.
    private func installOverlay() {
        guard let controller else { return }
        let host = UIHostingController(rootView: PlayerOverlay(controller: controller))
        host.sizingOptions = .intrinsicContentSize
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -56),
        ])
        host.didMove(toParent: self)
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
                    .overlay(alignment: .bottomTrailing) {
                        PlayerOverlay(controller: controller).padding(.bottom, 60)
                    }
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .navigationTitle(controller?.request.displayTitle ?? request.displayTitle)
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
