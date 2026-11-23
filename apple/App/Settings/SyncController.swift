import Foundation
import Observation
import NextupKit

/// WebDAV sync: keeps this device in step with the user's other Apple devices, and brings
/// accounts and addons over from the Flutter app's sync on the same account.
@MainActor
@Observable
final class SyncController {
    private let model: AppModel
    var account: WebDAVAccount { didSet { model.defaults.save(account, key: Self.accountKey) } }
    private(set) var isSyncing = false
    private(set) var lastSync: Date? { didSet { model.defaults.defaults.set(lastSync?.timeIntervalSince1970, forKey: Self.lastSyncKey) } }
    private(set) var lastError: String?
    /// Mirrors whether the Keychain holds a password, so views update when it changes.
    private(set) var hasPassword: Bool

    private static let accountKey = "nextup.webdav.account.v1"
    private static let lastSyncKey = "nextup.webdav.lastSync"

    init(model: AppModel) {
        self.model = model
        account = model.defaults.load(WebDAVAccount.self, key: Self.accountKey) ?? WebDAVAccount()
        let last = model.defaults.defaults.double(forKey: Self.lastSyncKey)
        lastSync = last > 0 ? Date(timeIntervalSince1970: last) : nil
        hasPassword = !model.secret(SecretKey.webDAVPassword).isEmpty
    }

    var password: String { model.secret(SecretKey.webDAVPassword) }
    var isConnected: Bool { hasPassword && account.endpoint != nil && !account.username.isEmpty }

    private func client() throws -> WebDAVClient {
        try WebDAVClient(account: account, password: password)
    }

    /// Signs in, then syncs straight away.
    func connect(account: WebDAVAccount, password: String) async throws {
        let candidate = try WebDAVClient(account: account, password: password)
        try await candidate.verify()
        self.account = account
        model.secrets.set(password, for: SecretKey.webDAVPassword)
        hasPassword = true
        await syncNow()
    }

    func disconnect() {
        model.secrets.set(nil, for: SecretKey.webDAVPassword)
        hasPassword = false
        lastSync = nil
        lastError = nil
    }

    /// Pull, merge, push. Quiet when sync is not set up.
    func syncNow() async {
        guard !isSyncing, let client = try? client() else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let merged = try await NativeSync.sync(local: model.syncState(), client: client, folder: account.folder)
            if merged != model.syncState() { model.apply(merged) }
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Reads the Flutter app's sync in the same folder and adds what is missing here.
    /// Returns a sentence for the Settings footer.
    func importFromFlutter() async throws -> String {
        let client = try client()
        let found = try await FlutterSync.read(client: client, folder: account.folder)
        var added: [String] = []
        if let key = found.realDebridKey, model.secret(SecretKey.realDebridToken) != key {
            model.setSecret(key, for: SecretKey.realDebridToken); added.append("Real-Debrid")
        }
        if let key = found.torboxKey, model.secret(SecretKey.torboxToken) != key {
            model.setSecret(key, for: SecretKey.torboxToken); added.append("TorBox")
        }
        if let session = found.trakt, model.trakt.session == nil {
            model.trakt.session = session
            model.accountsChanged()
            added.append("Trakt")
        }
        var addons = 0
        let installed = Set(model.addons.map(\.manifestURL.absoluteString))
        for url in found.addonURLs {
            let normalized = (try? AddonClient.normalizeManifestURL(url))?.absoluteString ?? url
            guard !installed.contains(normalized) else { continue }
            if (try? await model.install(addonURL: url)) != nil { addons += 1 }
        }
        if addons > 0 { added.append(addons == 1 ? "1 addon" : "\(addons) addons") }
        await syncNow()

        var sentence = added.isEmpty ? "Everything from the Flutter app was already here."
                                     : "Imported " + ListFormatter.localizedString(byJoining: added) + "."
        if !found.notSupported.isEmpty {
            sentence += " Not in the native app yet: " + ListFormatter.localizedString(byJoining: found.notSupported) + "."
        }
        return sentence
    }
}
