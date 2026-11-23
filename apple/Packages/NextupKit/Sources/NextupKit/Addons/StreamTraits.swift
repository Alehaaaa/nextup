import Foundation

/// What a stream is, read from the free text addons put in `name`, `title` and `description`
/// (Torrentio, Comet, MediaFusion and friends all use the same release-name vocabulary).
public struct StreamTraits: Hashable, Sendable {
    public enum Cache: String, Sendable { case cached, notCached, unknown }

    public var quality: StreamQuality
    /// "DV", "HDR10+", "HDR10", "HDR".
    public var hdr: [String] = []
    /// "HEVC", "AV1", "AVC".
    public var codec: String?
    /// "Atmos", "TrueHD", "DTS-HD MA", "DTS", "DD+", "DD", "AAC", plus "7.1"/"5.1".
    public var audio: [String] = []
    /// "REMUX", "BluRay", "WEB-DL", "WEBRip", "HDTV", "CAM".
    public var source: String?
    public var container: String?
    public var seeders: Int?
    public var sizeBytes: Int64?
    public var cache: Cache = .unknown
    /// Flags found in the text (🇬🇧, 🇪🇸…) or language words ("Multi", "Dual Audio").
    public var languages: [String] = []
    /// Release group, when the filename ends with "-GROUP".
    public var group: String?

    /// Camera and telesync copies, hidden by default.
    public var isLowQualitySource: Bool { source == "CAM" || source == "TS" }

    public init(stream: StremioStream) {
        let name = stream.name ?? ""
        let text = [name, stream.title, stream.description, stream.behaviorHints?.filename]
            .compactMap { $0 }.joined(separator: "\n")
        let lower = text.lowercased()
        func has(_ pattern: String) -> Bool {
            lower.range(of: pattern, options: .regularExpression) != nil
        }

        quality = stream.quality
        sizeBytes = stream.sizeBytes

        if has(#"\b(dv|dovi|dolby[ ._-]?vision)\b"#) { hdr.append("DV") }
        if has(#"hdr10\+|hdr10plus"#) { hdr.append("HDR10+") }
        else if has(#"\bhdr10\b"#) { hdr.append("HDR10") }
        else if has(#"\bhdr\b"#) { hdr.append("HDR") }

        if has(#"\b(hevc|x265|h\.?265)\b"#) { codec = "HEVC" }
        else if has(#"\bav1\b"#) { codec = "AV1" }
        else if has(#"\b(avc|x264|h\.?264)\b"#) { codec = "AVC" }

        if has(#"\batmos\b"#) { audio.append("Atmos") }
        if has(#"\btruehd\b"#) { audio.append("TrueHD") }
        if has(#"dts[ ._-]?hd[ ._-]?ma|dts[ ._-]?x\b"#) { audio.append("DTS-HD") }
        else if has(#"\bdts\b"#) { audio.append("DTS") }
        if has(#"\b(ddp|dd\+|e-?ac-?3)"#) { audio.append("DD+") }
        else if has(#"\b(dd|ac-?3)\b"#) { audio.append("DD") }
        if audio.isEmpty, has(#"\baac\b"#) { audio.append("AAC") }
        if has(#"\b7[ .]1\b"#) { audio.append("7.1") } else if has(#"\b5[ .]1\b"#) { audio.append("5.1") }

        if has(#"\bremux\b"#) { source = "REMUX" }
        else if has(#"\b(blu-?ray|bdrip|brrip)\b"#) { source = "BluRay" }
        else if has(#"\bweb[ ._-]?dl\b"#) { source = "WEB-DL" }
        else if has(#"\bweb-?rip\b"#) { source = "WEBRip" }
        else if has(#"\bhdtv\b"#) { source = "HDTV" }
        else if has(#"\b(cam|camrip|hdcam)\b"#) { source = "CAM" }
        else if has(#"\b(telesync|hdts|ts|tc)\b"#) && !has(#"\bm2ts\b"#) { source = "TS" }

        if let ext = stream.behaviorHints?.filename.map({ ($0 as NSString).pathExtension.lowercased() }), !ext.isEmpty {
            container = ext.uppercased()
        } else if has(#"\.mkv\b|\bmkv\b"#) { container = "MKV" } else if has(#"\.mp4\b"#) { container = "MP4" }

        seeders = Self.firstInt(after: ["👤", "👥", "seeders:", "seeds:", "s:"], in: text)

        // Debrid addons mark cached results in the name: "[RD+]", "RD⚡", "[TB+]", "⚡", "Instant".
        let tag = name.uppercased()
        if tag.contains("⚡") || tag.range(of: #"\[(RD|TB|AD|PM|DL|OC|ED|PP)\+\]"#, options: .regularExpression) != nil
            || tag.contains("INSTANT") || tag.contains("CACHED") {
            cache = .cached
        } else if tag.range(of: #"\[(RD|TB|AD|PM|DL|OC|ED|PP)( DOWNLOAD)?\]"#, options: .regularExpression) != nil
                    || tag.contains("⏳") || tag.contains("UNCACHED") {
            cache = .notCached
        }

        let scalars = Array(text.unicodeScalars)
        var found: [String] = []
        var i = 0
        while i + 1 < scalars.count {
            if (0x1F1E6...0x1F1FF).contains(scalars[i].value), (0x1F1E6...0x1F1FF).contains(scalars[i + 1].value) {
                let flag = String(scalars[i]) + String(scalars[i + 1])
                if !found.contains(flag) { found.append(flag) }
                i += 2
            } else { i += 1 }
        }
        if has(#"\bmulti\b"#) { found.append("Multi") }
        if has(#"dual[ ._-]?audio"#) { found.append("Dual Audio") }
        languages = found

        if let file = stream.behaviorHints?.filename ?? stream.title?.components(separatedBy: "\n").first,
           let match = file.range(of: #"-([A-Za-z0-9]{2,12})(\.[a-z0-9]{2,4})?$"#, options: .regularExpression) {
            group = String(file[match]).dropFirst().components(separatedBy: ".").first
        }
    }

    /// Short chips for the source row, most telling first.
    public var badges: [String] {
        var out: [String] = []
        out += hdr
        if let codec { out.append(codec) }
        if let source { out.append(source) }
        out += audio
        if let container, container != "MP4" { out.append(container) }
        return out
    }

    static func firstInt(after markers: [String], in text: String) -> Int? {
        for marker in markers {
            guard let range = text.range(of: marker, options: .caseInsensitive) else { continue }
            let digits = text[range.upperBound...].drop(while: { $0 == " " }).prefix(while: \.isNumber)
            if let value = Int(digits) { return value }
        }
        return nil
    }
}

public extension StremioStream {
    var traits: StreamTraits { StreamTraits(stream: self) }
}
