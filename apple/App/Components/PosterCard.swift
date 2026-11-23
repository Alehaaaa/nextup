import SwiftUI
import NextupKit

struct ArtworkImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
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

struct PosterCard: View {
    let item: MediaItem
    var width: CGFloat? = nil
    var progress: Double? = nil
    var caption: String? = nil

    var body: some View {
        let width = self.width ?? Theme.railPosterWidth
        return VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(url: item.posterURL)
                .frame(width: width, height: width / Theme.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.black.opacity(0.5))
                                Capsule().fill(Theme.accent).frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 4)
                        .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(.white.opacity(0.06))
                }
            Text(item.title)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
            if let caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A titled horizontal row of posters.
struct PosterRail<Item: Identifiable, Card: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder var card: (Item) -> Card

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in card(item) }
                }
                .padding(.horizontal)
            }
            .scrollClipDisabled()
        }
    }
}

/// Context menu shared by every poster so hold (iPhone/iPad) and right-click (Mac) behave the same.
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
