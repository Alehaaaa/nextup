import Foundation
import NextupKit

/// The options behind Settings → Playback & Sources and Settings → Home.
struct Preferences: Codable, Equatable {
    // Playback
    var autoplayNextEpisode = true
    var upNextCountdown = 10
    var showSkipIntro = true
    var autoSkipIntro = false

    // Sources
    var sourceSort: SourceSort = .best
    var hideLowQualitySources = true
    /// 0 = no limit, else `StreamQuality.rawValue`.
    var maxQuality = 0
    var cachedFirst = true

    // Home
    var showHero = true
    var showTop10 = true
    var showAddonCatalogs = true

    init() {}

    init(from decoder: Decoder) throws {
        // Every field is optional on disk, so new options never reset the saved ones.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        autoplayNextEpisode = try c.decodeIfPresent(Bool.self, forKey: .autoplayNextEpisode) ?? d.autoplayNextEpisode
        upNextCountdown = try c.decodeIfPresent(Int.self, forKey: .upNextCountdown) ?? d.upNextCountdown
        showSkipIntro = try c.decodeIfPresent(Bool.self, forKey: .showSkipIntro) ?? d.showSkipIntro
        autoSkipIntro = try c.decodeIfPresent(Bool.self, forKey: .autoSkipIntro) ?? d.autoSkipIntro
        sourceSort = try c.decodeIfPresent(SourceSort.self, forKey: .sourceSort) ?? d.sourceSort
        hideLowQualitySources = try c.decodeIfPresent(Bool.self, forKey: .hideLowQualitySources) ?? d.hideLowQualitySources
        maxQuality = try c.decodeIfPresent(Int.self, forKey: .maxQuality) ?? d.maxQuality
        cachedFirst = try c.decodeIfPresent(Bool.self, forKey: .cachedFirst) ?? d.cachedFirst
        showHero = try c.decodeIfPresent(Bool.self, forKey: .showHero) ?? d.showHero
        showTop10 = try c.decodeIfPresent(Bool.self, forKey: .showTop10) ?? d.showTop10
        showAddonCatalogs = try c.decodeIfPresent(Bool.self, forKey: .showAddonCatalogs) ?? d.showAddonCatalogs
    }

    /// Applies the source options: drops what should be hidden, then orders the rest.
    func arrange(_ streams: [StremioStream], sort: SourceSort? = nil) -> [StremioStream] {
        let entries = streams.enumerated().map { (offset: $0.offset, stream: $0.element, traits: $0.element.traits) }
        let kept = entries.filter { entry in
            if hideLowQualitySources, entry.traits.isLowQualitySource { return false }
            if maxQuality > 0, entry.traits.quality.rawValue > maxQuality { return false }
            return true
        }
        let order = sort ?? sourceSort
        return kept.sorted { a, b in
            if cachedFirst, order != .addon, (a.traits.cache == .cached) != (b.traits.cache == .cached) {
                return a.traits.cache == .cached
            }
            switch order {
            case .addon: return a.offset < b.offset
            case .best:
                if a.traits.quality != b.traits.quality { return a.traits.quality > b.traits.quality }
                if a.traits.hdr.isEmpty != b.traits.hdr.isEmpty { return !a.traits.hdr.isEmpty }
                return a.offset < b.offset
            case .size: return (a.traits.sizeBytes ?? 0) > (b.traits.sizeBytes ?? 0)
            case .seeders: return (a.traits.seeders ?? -1) > (b.traits.seeders ?? -1)
            }
        }.map(\.stream)
    }
}

enum SourceSort: String, Codable, CaseIterable, Identifiable {
    case best, addon, size, seeders
    var id: String { rawValue }
    var title: String {
        switch self {
        case .best: return "Best First"
        case .addon: return "Addon Order"
        case .size: return "Largest First"
        case .seeders: return "Most Seeders"
        }
    }
}
