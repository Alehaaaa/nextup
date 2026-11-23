import Foundation
import CryptoKit

/// Everything the native app keeps in step between iPhone, iPad and Mac. One small encrypted file:
/// `<folder>/nextup-native/state.enc`, next to the Flutter app's `debrify-sync` folder.
public struct SyncState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = SyncState.currentVersion
    /// When the settings below last changed on any device.
    public var settingsChangedAt: Date
    public var addons: [InstalledAddon]
    public var favorites: [MediaItem]
    public var watchlist: [MediaItem]
    /// Keychain values by `SecretKey` name (debrid keys, TMDB token, Trakt session).
    public var secrets: [String: String]
    /// Continue Watching; merged entry by entry, newest wins.
    public var progress: [WatchProgress]

    public init(settingsChangedAt: Date, addons: [InstalledAddon], favorites: [MediaItem], watchlist: [MediaItem],
                secrets: [String: String], progress: [WatchProgress]) {
        self.settingsChangedAt = settingsChangedAt
        self.addons = addons
        self.favorites = favorites
        self.watchlist = watchlist
        self.secrets = secrets
        self.progress = progress
    }

    /// Settings: the side changed most recently wins as a whole. Progress: per title, newest wins.
    public func merged(with remote: SyncState) -> SyncState {
        var result = remote.settingsChangedAt > settingsChangedAt ? remote : self
        var byID: [String: WatchProgress] = [:]
        for entry in progress + remote.progress {
            if let existing = byID[entry.id], existing.updatedAt >= entry.updatedAt { continue }
            byID[entry.id] = entry
        }
        result.progress = Array(byID.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(WatchProgressStore.cap))
        return result
    }
}

public enum NativeSync {
    static let folderName = "nextup-native"

    public enum Failure: Error, LocalizedError {
        case damaged
        public var errorDescription: String? { "The sync file on the server could not be read." }
    }

    /// Pulls, merges and pushes. Returns the merged state for the app to apply.
    public static func sync(local: SyncState, client: WebDAVClient, folder: String) async throws -> SyncState {
        let base = FlutterSync.join(folder, folderName)
        try await client.makeFolders(base)
        let key = try await sharedKey(client: client, base: base)
        var merged = local
        if let sealed = try await client.getIfPresent(FlutterSync.join(base, "state.enc")) {
            guard let remote = try? open(sealed, key: key) else { throw Failure.damaged }
            merged = local.merged(with: remote)
            if merged == remote { return merged }
        }
        try await client.put(FlutterSync.join(base, "state.enc"), data: try seal(merged, key: key))
        return merged
    }

    /// The key lives beside the data, like the Flutter app's `circle.authority`: whoever can sign in
    /// to the WebDAV account can read it. It keeps the file unreadable to anyone browsing a copy of it.
    static func sharedKey(client: WebDAVClient, base: String) async throws -> SymmetricKey {
        let path = FlutterSync.join(base, "key.json")
        if let data = try await client.getIfPresent(path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = (json["key"] as? String).flatMap({ Data(base64Encoded: $0) }), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "key": raw.base64EncodedString()])
        try await client.put(path, data: json)
        return key
    }

    static let associatedData = Data("nextup-native-sync-v1".utf8)

    static func seal(_ state: SyncState, key: SymmetricKey) throws -> Data {
        // Default date coding keeps dates exact, so an unchanged state compares equal after a round trip.
        let box = try AES.GCM.seal(try JSONEncoder().encode(state), using: key, authenticating: associatedData)
        guard let combined = box.combined else { throw Failure.damaged }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> SyncState {
        let clear = try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key, authenticating: associatedData)
        return try JSONDecoder().decode(SyncState.self, from: clear)
    }
}
