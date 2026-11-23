import Foundation
import CryptoKit

/// Reads the Flutter app's WebDAV sync folder (`<folder>/debrify-sync`) so its accounts and addons
/// can be brought into the native app. Read only: the native app never writes into that folder, so
/// the Flutter devices' sync is never disturbed.
///
/// Format (lib/services/webdav_sync in the Flutter app):
/// - `circle.authority`: JSON `{version: 1, marker: base64, syncPassphrase}`.
/// - The marker is an AES-256-GCM envelope whose key is Argon2id(passphrase, salt); the whole
///   header is the associated data, written as canonical (sorted-key) JSON.
/// - `devices/<id>/manifest.enc` lists sections; each is `devices/<id>/sections/<sha256>.enc`,
///   sealed with the same key and bound to circle, device, logical name and schema version.
/// - The `resources` section holds every connection (debrid, Trakt, Stremio addons…); secrets are
///   a further sealed document per resource (`resource-secret/<id>`).
public enum FlutterSync {
    public struct Circle: Sendable {
        public let id: String
        let key: SymmetricKey
    }

    public enum Failure: Error, LocalizedError, Sendable {
        case noSyncFolder(String)
        case unreadable(String)
        case wrongKey

        public var errorDescription: String? {
            switch self {
            case .noSyncFolder(let folder):
                return "No Flutter sync was found in “\(folder)”. In the Flutter app, turn on WebDAV sync with the same account first."
            case .unreadable(let what): return "The Flutter sync data could not be read (\(what))."
            case .wrongKey: return "The Flutter sync key does not match its data."
            }
        }
    }

    /// What the native app can use from the Flutter sync.
    public struct Import: Sendable, Equatable {
        public var realDebridKey: String?
        public var torboxKey: String?
        public var allDebridKey: String?
        public var trakt: TraktSession?
        public var addonURLs: [String] = []
        /// Connections the native app does not support yet, by label (AllDebrid, IPTV…).
        public var notSupported: [String] = []
        public var devices = 0

        public init() {}

        public var isEmpty: Bool { realDebridKey == nil && torboxKey == nil && allDebridKey == nil && trakt == nil && addonURLs.isEmpty }
    }

    // MARK: Reading a sync folder

    public static func read(client: WebDAVClient, folder: String) async throws -> Import {
        let root = join(folder, "debrify-sync")
        let circle = try await openCircle(client: client, root: root)
        let removed = Set(((try? await client.list(join(root, "removed"))) ?? []).map { $0.replacingOccurrences(of: ".enc", with: "") })
        let devices = try await client.list(join(root, "devices")).filter { !removed.contains($0) }

        var documents: [(device: String, resources: [String: Any])] = []
        for device in devices {
            guard let data = try? await client.get(join(root, "devices/\(device)/manifest.enc")),
                  let manifest = try? openDocument(data, circle: circle, deviceID: device, logicalName: "manifest", schemaVersion: 1) as? [String: Any],
                  let sections = manifest["sections"] as? [[String: Any]],
                  let reference = sections.first(where: { $0["name"] as? String == "resources" }),
                  let hash = reference["contentHash"] as? String,
                  let schema = reference["schemaVersion"] as? Int,
                  let sealed = try? await client.get(join(root, "devices/\(device)/sections/\(hash).enc")),
                  sha256Hex(sealed) == hash,
                  let resources = try? openDocument(sealed, circle: circle, deviceID: device, logicalName: "resources",
                                                    schemaVersion: schema, maxBytes: 256 << 20) as? [String: Any]
            else { continue }
            documents.append((device, resources))
        }
        guard !documents.isEmpty else { throw Failure.unreadable("no device has published its connections yet") }
        var result = try importResources(documents.map(\.resources), circle: circle)
        result.devices = documents.count
        return result
    }

    static func openCircle(client: WebDAVClient, root: String) async throws -> Circle {
        if let authority = try await client.getIfPresent(join(root, "circle.authority")) {
            guard let json = try? JSONSerialization.jsonObject(with: authority) as? [String: Any],
                  json["version"] as? Int == 1,
                  let marker = (json["marker"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let passphrase = json["syncPassphrase"] as? String
            else { throw Failure.unreadable("circle.authority") }
            return try openRoot(marker, passphrase: passphrase)
        }
        // Older layout: the marker and its key in two files.
        if let marker = try await client.getIfPresent(join(root, "circle.json.enc")),
           let keyFile = try await client.getIfPresent(join(root, "circle.key")),
           let json = try? JSONSerialization.jsonObject(with: keyFile) as? [String: Any],
           let passphrase = json["syncPassphrase"] as? String {
            return try openRoot(marker, passphrase: passphrase)
        }
        throw Failure.noSyncFolder(root.replacingOccurrences(of: "/debrify-sync", with: ""))
    }

    // MARK: Envelopes

    public static func openRoot(_ encoded: Data, passphrase: String) throws -> Circle {
        guard let envelope = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let header = envelope["header"] as? [String: Any],
              header["format"] as? String == "debrify-webdav-sync-root",
              header["aead"] as? String == "aes-256-gcm",
              let kdf = header["kdf"] as? [String: Any],
              kdf["algorithm"] as? String == "argon2id",
              let salt = (kdf["salt"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let memory = kdf["memoryKiB"] as? Int, (8...131_072).contains(memory),
              let iterations = kdf["iterations"] as? Int, (1...16).contains(iterations),
              let lanes = kdf["parallelism"] as? Int, (1...8).contains(lanes), memory >= 8 * lanes
        else { throw Failure.unreadable("root marker") }
        let keyBytes = Argon2id.hash(password: Array(passphrase.utf8), salt: Array(salt),
                                     iterations: iterations, memoryKiB: memory, parallelism: lanes, length: 32)
        let key = SymmetricKey(data: keyBytes)
        guard let clear = try? open(envelope, key: key, header: header),
              let body = try? JSONSerialization.jsonObject(with: clear) as? [String: Any],
              let circleID = body["circleId"] as? String,
              let check = body["keyCheck"] as? String
        else { throw Failure.wrongKey }
        guard check == keyCheck(key) else { throw Failure.wrongKey }
        return Circle(id: circleID, key: key)
    }

    public static func openDocument(_ encoded: Data, circle: Circle, deviceID: String, logicalName: String,
                                    schemaVersion: Int, maxBytes: Int = 4 << 20) throws -> Any {
        guard let envelope = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw Failure.unreadable(logicalName)
        }
        // The expected header is rebuilt, never trusted from the server.
        let header: [String: Any] = [
            "format": "debrify-webdav-sync-document", "version": 1, "circleId": circle.id,
            "deviceId": deviceID, "logicalName": logicalName, "schemaVersion": schemaVersion, "aead": "aes-256-gcm",
        ]
        guard let clear = try? open(envelope, key: circle.key, header: header) else { throw Failure.unreadable(logicalName) }
        let payload = try inflateIfNeeded(clear, maxBytes: maxBytes)
        return try JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed])
    }

    private static func open(_ envelope: [String: Any], key: SymmetricKey, header: [String: Any]) throws -> Data {
        guard let nonce = (envelope["nonce"] as? String).flatMap({ Data(base64Encoded: $0) }), nonce.count == 12,
              let sealed = (envelope["ciphertext"] as? String).flatMap({ Data(base64Encoded: $0) }), sealed.count >= 16
        else { throw Failure.unreadable("envelope") }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                        ciphertext: sealed.dropLast(16), tag: sealed.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: Data(CanonicalJSON.encode(header).utf8))
    }

    static func keyCheck(_ key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("debrify-webdav-sync-key-check-v1".utf8), using: key)
        return base64URL(Data(mac))
    }

    /// Documents start with "\0DBRFY-ZLIB\u{1}" and a zlib stream when compressed.
    static let compressedPrefix: [UInt8] = [0x00, 0x44, 0x42, 0x52, 0x46, 0x59, 0x2d, 0x5a, 0x4c, 0x49, 0x42, 0x01]

    static func inflateIfNeeded(_ data: Data, maxBytes: Int) throws -> Data {
        guard data.count > compressedPrefix.count + 6, data.prefix(compressedPrefix.count).elementsEqual(compressedPrefix) else {
            return data
        }
        // zlib = 2-byte header + raw DEFLATE + 4-byte Adler-32. Apple's `.zlib` reads raw DEFLATE.
        let deflate = data.dropFirst(compressedPrefix.count + 2).dropLast(4)
        guard let inflated = try? (Data(deflate) as NSData).decompressed(using: .zlib) as Data,
              inflated.count <= maxBytes else { throw Failure.unreadable("compressed document") }
        return inflated
    }

    // MARK: Resources

    private struct Leaf {
        let time: Int
        let origin: String
        let value: [String: Any]?

        init?(_ raw: Any?) {
            guard let raw = raw as? [String: Any], let stamp = raw["stamp"] as? [String: Any],
                  let time = stamp["time"] as? Int, let origin = stamp["origin"] as? String else { return nil }
            self.time = time
            self.origin = origin
            self.value = raw["value"] as? [String: Any]
        }

        func isNewer(than other: Leaf?) -> Bool {
            guard let other else { return true }
            return time != other.time ? time > other.time : origin > other.origin
        }
    }

    /// Merges every device's view (newest stamp wins per connection) and decrypts the secrets.
    static func importResources(_ documents: [[String: Any]], circle: Circle) throws -> Import {
        var metadata: [String: Leaf] = [:]
        var secrets: [String: Leaf] = [:]
        var order: [String] = []
        for document in documents {
            guard let resources = document["resources"] as? [String: Any] else { continue }
            for (id, raw) in resources.sorted(by: { $0.key < $1.key }) {
                guard let entry = raw as? [String: Any] else { continue }
                if !order.contains(id) { order.append(id) }
                if let leaf = Leaf(entry["metadata"]), leaf.isNewer(than: metadata[id]) { metadata[id] = leaf }
                if let leaf = Leaf(entry["secretConfig"]), leaf.isNewer(than: secrets[id]) { secrets[id] = leaf }
            }
        }

        var result = Import()
        for id in order {
            guard let meta = metadata[id]?.value, let type = meta["type"] as? String,
                  meta["enabled"] as? Bool ?? true else { continue }
            let label = meta["label"] as? String ?? type
            var secret: [String: Any]?
            if let leaf = secrets[id], let config = leaf.value, config["type"] as? String == type,
               let envelope = (config["envelope"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                secret = try? openDocument(envelope, circle: circle, deviceID: leaf.origin,
                                           logicalName: "resource-secret/\(id)", schemaVersion: 1, maxBytes: 256 << 20) as? [String: Any]
            }
            switch type {
            case "realDebrid": result.realDebridKey = nonEmpty(secret?["apiKey"]) ?? result.realDebridKey
            case "torbox": result.torboxKey = nonEmpty(secret?["apiKey"]) ?? result.torboxKey
            case "allDebrid": result.allDebridKey = nonEmpty(secret?["apiKey"]) ?? result.allDebridKey
            case "trakt":
                if let access = nonEmpty(secret?["accessToken"]), let refresh = nonEmpty(secret?["refreshToken"]) {
                    let expiry = (secret?["expiryMs"] as? Int).map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
                    result.trakt = TraktSession(accessToken: access, refreshToken: refresh, expiresAt: expiry)
                }
            case "stremioAddon":
                if let url = nonEmpty(secret?["manifestUrl"]), !result.addonURLs.contains(url) { result.addonURLs.append(url) }
            default:
                if !result.notSupported.contains(label) { result.notSupported.append(label) }
            }
        }
        return result
    }

    // MARK: Helpers

    static func join(_ left: String, _ right: String) -> String {
        (left.split(separator: "/") + right.split(separator: "/")).joined(separator: "/")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Dart's `jsonEncode` of a map with sorted keys: compact, `/` unescaped, control characters as \uXXXX.
enum CanonicalJSON {
    static func encode(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return "null"
        case let string as String: return quote(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 9e15 { return String(number.int64Value) }
            return String(double)
        case let array as [Any]: return "[" + array.map { encode($0) }.joined(separator: ",") + "]"
        case let map as [String: Any]:
            return "{" + map.keys.sorted(by: { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) })
                .map { quote($0) + ":" + encode(map[$0]) }.joined(separator: ",") + "}"
        default: return "null"
        }
    }

    private static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
