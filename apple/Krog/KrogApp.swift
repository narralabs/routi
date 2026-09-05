import SwiftUI

@main
struct KrogApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        // The `#if` wraps whole scenes rather than starting with a leading-dot
        // modifier — a result builder can't parse a conditional that opens mid-chain.
        #if os(macOS)
        WindowGroup {
            RootView().environment(model)
        }
        // Unified toolbar puts controls inline with the title bar, which is what
        // gives a modern Mac app its single-row chrome.
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView().environment(model)
        }
        #else
        WindowGroup {
            RootView().environment(model)
        }
        #endif
    }
}

#if os(macOS)
struct SettingsView: View {
    @AppStorage("daemonHost") private var host = "127.0.0.1"
    @AppStorage("daemonPort") private var port = 7171
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
            } header: {
                Text("krogd")
            } footer: {
                Text("The daemon runs on the Mac that owns your Anthropic login. Leave this as localhost when the app runs on that same Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onDisappear { model.updateEndpoint(host: host, port: port) }
    }
}
#endif
