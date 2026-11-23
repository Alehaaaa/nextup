import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Layout constants only. Colours, materials and controls are the system's: the app sets the
/// accent colour (asset catalog) and dark appearance, and every surface is native.
enum Theme {
    /// The platform's own window background, used where artwork fades into the page.
    static var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static let accent = Color.accentColor

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
        return 184
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? 170 : 118
        #endif
    }
}

extension View {
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
