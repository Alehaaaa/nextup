import SwiftUI
import NextupKit

@main
struct NextupApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
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
