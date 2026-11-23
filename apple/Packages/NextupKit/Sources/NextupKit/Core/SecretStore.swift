import Foundation
#if canImport(Security)
import Security
#endif

/// Where API keys and OAuth tokens live. The Keychain on Apple platforms,
/// an in-memory dictionary elsewhere (tests on Linux).
public protocol SecretStoring: Sendable {
    func string(for key: String) -> String?
    func set(_ value: String?, for key: String)
}

public enum SecretKey {
    public static let realDebridToken = "realdebrid.apiKey"
    public static let torboxToken = "torbox.apiKey"
    public static let tmdbToken = "tmdb.readAccessToken"
    public static let traktSession = "trakt.session"
}

public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()
    #if !canImport(Security)
    private var memory: [String: String] = [:]
    #endif

    public init(service: String = "com.alehaaaa.nextup") {
        self.service = service
    }

    public func string(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return memory[key]
        #endif
    }

    public func set(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        #else
        memory[key] = (value?.isEmpty ?? true) ? nil : value
        #endif
    }
}

/// Test double.
public final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private var values: [String: String]
    private let lock = NSLock()
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
    public func set(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = (value?.isEmpty ?? true) ? nil : value
    }
}

/// Small Codable persistence on top of `UserDefaults` for non-secret state
/// (installed addons, continue watching, preferences).
public struct DefaultsStore: @unchecked Sendable {
    public let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    public func remove(_ key: String) { defaults.removeObject(forKey: key) }
}
