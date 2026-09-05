import SwiftUI

@main
struct KrogApp: App {
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearanceRaw = AppearanceMode.system.rawValue

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some Scene {
        // The `#if` wraps whole scenes rather than starting with a leading-dot
        // modifier — a result builder can't parse a conditional that opens mid-chain.
        #if os(macOS)
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
        }
        // Unified toolbar puts controls inline with the title bar, which is what
        // gives a modern Mac app its single-row chrome.
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // ⌘, opens settings in-window rather than a separate panel, so the Mac
            // and the phone show the same screen.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.isShowingSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Show Sidebar") {
                    withAnimation(.snappy(duration: 0.25)) { model.sidebarVisibility = .all }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
        }
        #endif
    }
}
