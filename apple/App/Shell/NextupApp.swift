import Combine
import SwiftUI
import NextupKit

#if os(iOS)
import UIKit

/// Lets background downloads finish while the app is suspended or closed.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var pendingBackgroundCompletion: (() -> Void)?

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else { completionHandler(); return }
        Self.pendingBackgroundCompletion = completionHandler
        NotificationCenter.default.post(name: .nextupBackgroundSessionEvents, object: nil)
    }
}

extension Notification.Name {
    static let nextupBackgroundSessionEvents = Notification.Name("nextup.backgroundSessionEvents")
}
#endif

@main
struct NextupApp: App {
    @State private var model = AppModel()
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: .nextupBackgroundSessionEvents)) { _ in
                    model.downloads.backgroundCompletion = AppDelegate.pendingBackgroundCompletion
                    AppDelegate.pendingBackgroundCompletion = nil
                }
                .task {
                    // Relaunched by the system for download events before any UI existed.
                    if let pending = AppDelegate.pendingBackgroundCompletion {
                        model.downloads.backgroundCompletion = pending
                        AppDelegate.pendingBackgroundCompletion = nil
                    }
                }
                #endif
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #if os(macOS)
        .defaultSize(width: 1280, height: 800)
        .commands { NextupCommands() }
        #endif

        #if os(macOS)
        // Each stream opens in its own window on the Mac, like a native player.
        WindowGroup("Player", for: PlaybackRequest.self) { $request in
            if let request {
                PlayerView(request: request)
                    .environment(model)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 1280, height: 720)

        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 520)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        #endif
    }
}

#if os(macOS)
struct NextupCommands: Commands {
    @FocusedValue(\.sectionSelection) private var selection

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(AppSection.allCases.filter { $0 != .settings }.enumerated()), id: \.element) { index, section in
                Button(section.title) { selection?.wrappedValue = section }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}

struct SectionSelectionKey: FocusedValueKey {
    typealias Value = Binding<AppSection>
}

extension FocusedValues {
    var sectionSelection: Binding<AppSection>? {
        get { self[SectionSelectionKey.self] }
        set { self[SectionSelectionKey.self] = newValue }
    }
}
#endif
