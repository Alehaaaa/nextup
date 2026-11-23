import Foundation
import Observation
import NextupKit

/// One movie or episode saved to the device.
struct DownloadRecord: Codable, Identifiable, Hashable {
    enum State: String, Codable { case queued, downloading, paused, finished, failed }

    var item: MediaItem
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    var remoteURL: URL
    var filename: String
    var state: State = .queued
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var error: String?
    var addedAt = Date()
    /// Session task while it runs (not meaningful across launches; re-matched by URL).
    var taskID: Int?

    /// Same key as playback, so resume positions are shared with streaming.
    var id: String {
        guard let season, let episode else { return item.id }
        return "\(item.id):\(season):\(episode)"
    }

    var fraction: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }

    var displayTitle: String {
        guard let season, let episode else { return item.title }
        return String(format: "S%02dE%02d", season, episode) + (episodeTitle.map { " · \($0)" } ?? "")
    }
}

/// Background downloads with `URLSession`: they keep going when the app is in the background or
/// closed, and finished files play offline with the system player.
@MainActor
@Observable
final class DownloadManager {
    static let sessionIdentifier = "com.alehaaaa.nextup.downloads"

    private(set) var records: [DownloadRecord] = []
    @ObservationIgnored private let defaults: DefaultsStore
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let delegate = DownloadDelegate()
    @ObservationIgnored private var resumeData: [String: Data] = [:]
    @ObservationIgnored var backgroundCompletion: (() -> Void)?
    private let key = "nextup.downloads.v1"

    init(defaults: DefaultsStore) {
        self.defaults = defaults
        records = defaults.load([DownloadRecord].self, key: key) ?? []
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        delegate.manager = self
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        reconcile()
    }

    // MARK: Queries

    func record(for id: String) -> DownloadRecord? { records.first { $0.id == id } }

    func localURL(for id: String) -> URL? {
        guard let record = record(for: id), record.state == .finished else { return nil }
        let url = Self.folder.appendingPathComponent(record.filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func downloadedEpisodes(of item: MediaItem) -> [DownloadRecord] {
        records.filter { $0.item.id == item.id && $0.season != nil }
    }

    /// Titles with at least one finished file, newest first, for the offline library.
    var library: [DownloadRecord] {
        var seen = Set<String>()
        return records
            .filter { $0.state == .finished }
            .sorted { $0.addedAt > $1.addedAt }
            .filter { seen.insert($0.item.id).inserted }
    }

    var active: [DownloadRecord] { records.filter { $0.state != .finished } }

    // MARK: Actions

    func start(url: URL, item: MediaItem, season: Int?, episode: Int?, episodeTitle: String?, filename: String?) {
        var record = DownloadRecord(item: item, season: season, episode: episode, episodeTitle: episodeTitle,
                                    remoteURL: url, filename: Self.safeFilename(for: item, season: season, episode: episode,
                                                                              original: filename ?? url.lastPathComponent))
        if let existing = records.firstIndex(where: { $0.id == record.id }) {
            if records[existing].state == .finished { return }
            cancelTask(records[existing])
            records.remove(at: existing)
        }
        let task = session.downloadTask(with: url)
        task.taskDescription = record.id
        record.taskID = task.taskIdentifier
        record.state = .downloading
        records.insert(record, at: 0)
        save()
        task.resume()
    }

    func pause(_ id: String) {
        guard let record = record(for: id) else { return }
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskDescription == id }) as? URLSessionDownloadTask else { return }
            task.cancel { data in
                Task { @MainActor in
                    self.resumeData[id] = data
                    self.update(id) { $0.state = .paused }
                }
            }
        }
        _ = record
    }

    func resume(_ id: String) {
        guard let record = record(for: id) else { return }
        let task: URLSessionDownloadTask
        if let data = resumeData.removeValue(forKey: id) {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: record.remoteURL)
        }
        task.taskDescription = id
        update(id) { $0.state = .downloading; $0.error = nil; $0.taskID = task.taskIdentifier }
        task.resume()
    }

    func delete(_ id: String) {
        guard let record = record(for: id) else { return }
        cancelTask(record)
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(record.filename))
        resumeData[id] = nil
        records.removeAll { $0.id == id }
        save()
    }

    func deleteAll(of item: MediaItem) {
        for record in records where record.item.id == item.id { delete(record.id) }
    }

    // MARK: Delegate callbacks

    fileprivate func progress(id: String, received: Int64, total: Int64) {
        update(id, persist: false) {
            $0.receivedBytes = received
            if total > 0 { $0.totalBytes = total }
            $0.state = .downloading
        }
    }

    fileprivate func finished(id: String, file: URL) {
        guard let record = record(for: id) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let destination = Self.folder.appendingPathComponent(record.filename)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: file, to: destination)
            update(id) { $0.state = .finished; $0.receivedBytes = max($0.receivedBytes, $0.totalBytes) }
        } catch {
            update(id) { $0.state = .failed; $0.error = error.localizedDescription }
        }
    }

    fileprivate func failed(id: String, error: Error, resumeData data: Data?) {
        if (error as NSError).code == NSURLErrorCancelled, record(for: id)?.state == .paused { return }
        if let data { resumeData[id] = data }
        update(id) { $0.state = .failed; $0.error = error.localizedDescription }
    }

    fileprivate func sessionFinishedEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    // MARK: Plumbing

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Re-creatable from the user's services, so keep it out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try? mutable.setResourceValues(values)
        return url
    }

    static func safeFilename(for item: MediaItem, season: Int?, episode: Int?, original: String) -> String {
        let ext = (original as NSString).pathExtension.isEmpty ? "mp4" : (original as NSString).pathExtension
        var base = item.title
        if let season, let episode { base += String(format: " S%02dE%02d", season, episode) }
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: " ")
        return "\(cleaned).\(ext)"
    }

    private func update(_ id: String, persist: Bool = true, _ change: (inout DownloadRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        if persist { save() }
    }

    private func save() { defaults.save(records, key: key) }

    private func cancelTask(_ record: DownloadRecord) {
        let id = record.id
        session.getAllTasks { tasks in tasks.filter { $0.taskDescription == id }.forEach { $0.cancel() } }
    }

    /// After a relaunch: tasks still running in the session keep their records "downloading";
    /// records that lost their task become paused so the user can resume them.
    private func reconcile() {
        session.getAllTasks { tasks in
            let running = Set(tasks.compactMap(\.taskDescription))
            Task { @MainActor in
                for record in self.records where record.state == .downloading && !running.contains(record.id) {
                    self.update(record.id) { $0.state = .paused }
                }
            }
        }
    }
}

/// URLSession calls back on its own queue; everything is forwarded to the main actor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var manager: DownloadManager?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor [weak manager] in
            manager?.progress(id: id, received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                userInfo: [NSLocalizedDescriptionKey: "Server returned \(http.statusCode)"])
            Task { @MainActor [weak manager] in manager?.failed(id: id, error: error, resumeData: nil) }
            return
        }
        // The temporary file is deleted when this method returns, so move it first.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            Task { @MainActor [weak manager] in manager?.failed(id: id, error: error, resumeData: nil) }
            return
        }
        Task { @MainActor [weak manager] in manager?.finished(id: id, file: staged) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak manager] in manager?.failed(id: id, error: error, resumeData: data) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak manager] in manager?.sessionFinishedEvents() }
    }
}
