import SwiftUI
import NextupKit

struct ArtworkImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: contentMode)
            case .failure:
                Theme.placeholder.overlay(Image(systemName: "film").foregroundStyle(.secondary))
            default:
                Theme.placeholder
            }
        }
    }
}

/// How a Home row draws its titles.
enum RailStyle: Hashable {
    case poster
    case wide
    case top10
}

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: max(4, geo.size.width * value))
            }
        }
        .frame(height: 4)
    }
}

private struct CardShape: ViewModifier {
    func body(content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
    }
}

/// Portrait poster with the title under it.
struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat? = nil
    var progress: Double? = nil
    var caption: String? = nil

    var body: some View {
        let width = self.width ?? Theme.railPosterWidth
        return VStack(alignment: .leading, spacing: 8) {
            ArtworkImage(url: item.posterURL)
                .frame(width: width, height: width / Theme.posterAspect)
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 { ProgressBar(value: progress).padding(10) }
                }
                .modifier(CardShape())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline).lineLimit(1)
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Landscape card: backdrop art with the title over a soft scrim, like a TV app's wide row.
struct WideCard: View {
    let item: MediaItem
    var width: CGFloat? = nil
    var progress: Double? = nil
    var caption: String? = nil

    var body: some View {
        let width = self.width ?? Theme.railWideWidth
        return ArtworkImage(url: item.backdropURL ?? item.posterURL)
            .frame(width: width, height: width / Theme.wideAspect)
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.bold)).lineLimit(1)
                    if let caption { Text(caption).font(.caption).foregroundStyle(.white.opacity(0.75)).lineLimit(1) }
                    if let progress, progress > 0 { ProgressBar(value: progress).padding(.top, 2) }
                }
                .padding(12)
            }
            .modifier(CardShape())
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

/// Ranked poster for Top 10 rows: a large outlined number tucked behind the poster.
struct Top10Card: View {
    let item: MediaItem
    let rank: Int

    var body: some View {
        let width = Theme.railPosterWidth
        return HStack(alignment: .bottom, spacing: -width * 0.18) {
            Text("\(rank)")
                .font(.system(size: width * 0.95, weight: .black, design: .rounded))
                .foregroundStyle(.clear)
                .overlay {
                    Text("\(rank)")
                        .font(.system(size: width * 0.95, weight: .black, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.15)],
                                                        startPoint: .top, endPoint: .bottom))
                }
                .offset(y: width * 0.12)
            ArtworkImage(url: item.posterURL)
                .frame(width: width, height: width / Theme.posterAspect)
                .modifier(CardShape())
        }
        .contentShape(Rectangle())
        .accessibilityLabel("Number \(rank), \(item.title)")
    }
}

/// A titled horizontal row (a Home "branch").
struct PosterRail<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    /// When set, the header becomes a link to the whole list ("Movie night ›").
    var seeAll: MediaRail? = nil
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        HStack(spacing: 6) {
                            Text(title)
                            Image(systemName: "chevron.right").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }
            }
            .font(.title3.weight(.bold))
            .padding(.horizontal, Theme.gutter)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in card(item) }
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 12) // room for card shadows
                .scrollTargetLayout()
            }
            .scrollClipDisabled()
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// Context menu shared by every card so hold (iPhone/iPad) and right-click (Mac) behave the same.
struct TitleContextMenu: View {
    let item: MediaItem
    var onRemove: (() -> Void)? = nil

    var body: some View {
        if let imdb = item.imdbID, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            Link(destination: url) { Label("Open on IMDb", systemImage: "safari") }
        }
        if let onRemove {
            Button(role: .destructive, action: onRemove) { Label("Remove from Continue Watching", systemImage: "xmark.circle") }
        }
    }
}

/// Every title in a row, as a grid.
struct SeeAllView: View {
    let rail: MediaRail

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.railPosterWidth, maximum: Theme.railPosterWidth + 40), spacing: 16)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(rail.items) { item in
                    NavigationLink(value: item) { PosterCard(item: item) }
                        .buttonStyle(.plain)
                        .contextMenu { TitleContextMenu(item: item) }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical)
        }
        .nextupBackground()
        .navigationTitle(rail.title)
        .inlineTitle()
    }
}
