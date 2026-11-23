import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Cinematic dark look: near-black ground so artwork carries the colour, Liquid Glass for chrome,
/// Nextup's violet as the tint.
enum Theme {
    static let background = Color(red: 0x08 / 255, green: 0x09 / 255, blue: 0x0B / 255)
    static let surface = Color(red: 0x16 / 255, green: 0x13 / 255, blue: 0x1F / 255)
    static let accent = Color(red: 0x7B / 255, green: 0x5C / 255, blue: 0xFF / 255)
    static let focus = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
    static let success = Color(red: 0x10 / 255, green: 0xB9 / 255, blue: 0x81 / 255)
    static let danger = Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    static let placeholder = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x18 / 255)

    static let posterAspect: CGFloat = 2.0 / 3.0
    static let corner: CGFloat = 14
    static let wideAspect: CGFloat = 16.0 / 9.0

    /// Side margin for rows and headers.
    static var gutter: CGFloat {
        #if os(macOS)
        return 28
        #else
        return 20
        #endif
    }

    /// Poster width for rails, sized per platform so iPhone, iPad and Mac all show a sensible count.
    /// Landscape card width for wide rows and Continue Watching.
    @MainActor static var railWideWidth: CGFloat {
        #if os(macOS)
        return 300
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 300 : 260
        #endif
    }

    @MainActor static var railPosterWidth: CGFloat {
        #if os(macOS)
        return 150
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 150 : 118
        #endif
    }
}

extension View {
    /// The app's background, edge to edge.
    func nextupBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }

    /// Liquid Glass panel for cards and controls that float over content.
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Inline navigation title on iOS; no-op on the Mac, which has no title display modes.
    @ViewBuilder
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension EnvironmentValues {
    /// iPhone-width layout. Always false on the Mac, where windows use the regular layout.
    var isCompactWidth: Bool {
        #if os(iOS)
        return horizontalSizeClass == .compact
        #else
        return false
        #endif
    }
}

enum Format {
    static func bytes(_ value: Int64?) -> String? {
        guard let value, value > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func runtime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    static func remaining(position: Double, duration: Double) -> String {
        let left = max(0, Int(duration - position) / 60)
        return left >= 60 ? "\(left / 60)h \(left % 60)m left" : "\(left)m left"
    }
}

@MainActor
enum Clipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
