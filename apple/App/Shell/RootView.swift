import SwiftUI
import NextupKit

enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case home, search, library, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .search: return "Search"
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .library: return "rectangle.stack"
        case .settings: return "gearshape"
        }
    }
}

/// One navigation model for every device: a tab bar when space is compact (iPhone),
/// a sidebar when it is regular (iPad, Mac). Same sections, same order, same screens.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var selection: AppSection = .home

    var body: some View {
        Group {
            if usesSidebar {
                NavigationSplitView {
                    List(sidebarSections, selection: Binding<AppSection?>(get: { selection }, set: { if let s = $0 { selection = s } })) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                    .navigationTitle("Nextup")
                    #if os(macOS)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 200)
                    #endif
                } detail: {
                    SectionStack(section: selection)
                        .id(selection)
                }
            } else {
                TabView(selection: $selection) {
                    ForEach(AppSection.allCases) { section in
                        SectionStack(section: section)
                            .tabItem { Label(section.title, systemImage: section.symbol) }
                            .tag(section)
                    }
                }
            }
        }
        .environment(\.play, playAction)
        #if os(macOS)
        .focusedSceneValue(\.sectionSelection, $selection)
        #else
        .fullScreenCover(item: Binding(get: { model.activePlayback }, set: { model.activePlayback = $0 })) { request in
            PlayerView(request: request)
                .environment(model)
        }
        #endif
    }

    private var playAction: PlayAction {
        #if os(macOS)
        PlayAction(model: model, openWindow: openWindow)
        #else
        PlayAction(model: model)
        #endif
    }

    private var usesSidebar: Bool {
        #if os(macOS)
        return true
        #else
        return sizeClass == .regular
        #endif
    }

    /// On the Mac, Settings lives in its own window (⌘,) like every Mac app.
    private var sidebarSections: [AppSection] {
        #if os(macOS)
        return AppSection.allCases.filter { $0 != .settings }
        #else
        return AppSection.allCases
        #endif
    }
}

/// A navigation stack per section, with the shared title destination.
struct SectionStack: View {
    let section: AppSection

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .home: HomeView()
                case .search: SearchView()
                case .library: LibraryView()
                case .settings: SettingsView()
                }
            }
            .navigationDestination(for: MediaItem.self) { item in
                TitleDetailView(item: item)
            }
        }
    }
}

/// Opens the player the native way on each platform.
@MainActor
struct PlayAction {
    let model: AppModel
    #if os(macOS)
    let openWindow: OpenWindowAction
    #endif

    func callAsFunction(_ request: PlaybackRequest) {
        #if os(macOS)
        openWindow(value: request)
        #else
        model.activePlayback = request
        #endif
    }
}

private struct PlayActionKey: EnvironmentKey {
    static let defaultValue: PlayAction? = nil
}

extension EnvironmentValues {
    /// `play(request)` from any screen: full screen on iPhone/iPad, a new window on the Mac.
    var play: PlayAction? {
        get { self[PlayActionKey.self] }
        set { self[PlayActionKey.self] = newValue }
    }
}
