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

/// One navigation model for every device. The adaptable tab view is a floating Liquid Glass
/// tab bar on iPhone, and a sidebar on iPad and Mac. Search is the system search tab.
struct RootView: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.openURL) private var openURL
    @State private var selection: AppSection = .home

    var body: some View {
        TabView(selection: $selection) {
            Tab(AppSection.home.title, systemImage: AppSection.home.symbol, value: AppSection.home) {
                SectionStack(section: .home)
            }
            Tab(AppSection.library.title, systemImage: AppSection.library.symbol, value: AppSection.library) {
                SectionStack(section: .library)
            }
            Tab(value: AppSection.search, role: .search) {
                SectionStack(section: .search)
            }
        }
        #if os(macOS)
        // Mac: the tabs sit in the toolbar as a glass segmented control.
        .tabViewStyle(.automatic)
        #else
        // iPhone: floating glass tab bar. iPad: tab bar that can turn into a sidebar.
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: Binding(get: { model.showingSettings }, set: { model.showingSettings = $0 })) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.showingSettings = false }
                        }
                    }
            }
            .environment(model)
        }
        #endif
        .environment(\.play, playAction)
        #if os(macOS)
        .focusedSceneValue(\.sectionSelection, $selection)
        #else
        .alert("Can't play this stream",
               isPresented: Binding(get: { model.playbackFailure != nil }, set: { if !$0 { model.playbackFailure = nil } }),
               presenting: model.playbackFailure) { failure in
            ForEach(ExternalPlayer.options(for: failure.request.url)) { option in
                Button("Open in \(option.name)") { openURL(option.url) }
            }
            Button("Copy Link") { Clipboard.copy(failure.request.url.absoluteString) }
            Button("Close", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
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
            .navigationDestination(for: MediaRail.self) { rail in
                SeeAllView(rail: rail)
            }
        }
    }
}

/// The glass gear in the top corner. Settings is a sheet on iPhone/iPad and the Settings window on the Mac.
struct SettingsToolbarItem: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            #if os(macOS)
            SettingsLink { Image(systemName: "gearshape") }
                .help("Settings")
            #else
            Button { model.showingSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Settings")
            #endif
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
        NativePlayer.present(request, model: model)
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
