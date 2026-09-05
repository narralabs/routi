import SwiftUI

/// App preferences, stored per-device.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum SendBehavior: String, CaseIterable, Identifiable {
    case returnKey, commandReturn
    var id: String { rawValue }

    var label: String {
        switch self {
        case .returnKey: return "Return"
        case .commandReturn: return "⌘ Return"
        }
    }
}

/// The settings screen.
///
/// Replaces the whole window rather than opening a separate preferences panel, with a
/// "Back to app" affordance — the pattern the ChatGPT/Codex app uses, and the one that
/// works identically on a phone. `NavigationSplitView` does the adapting: two columns
/// on Mac and iPad, a push stack on iPhone, from the same code.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    enum Pane: String, CaseIterable, Identifiable, Hashable {
        case general, connection, claude, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "General"
            case .connection: return "Krog Core"
            case .claude: return "Claude"
            case .about: return "About"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .connection: return "externaldrive.connected.to.line.below"
            case .claude: return "brain"
            case .about: return "info.circle"
            }
        }

        var group: String {
            switch self {
            case .general: return "App"
            case .connection, .claude: return "Connections"
            case .about: return "About"
            }
        }
    }

    @State private var selection: Pane? = .general

    private var groups: [(String, [Pane])] {
        var order: [String] = []
        var buckets: [String: [Pane]] = [:]
        for pane in Pane.allCases {
            if buckets[pane.group] == nil { order.append(pane.group) }
            buckets[pane.group, default: []].append(pane)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Button {
                        model.isShowingSettings = false
                    } label: {
                        Label("Back to app", systemImage: "chevron.left")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                }

                ForEach(groups, id: \.0) { group, panes in
                    Section(group) {
                        ForEach(panes) { pane in
                            Label(pane.title, systemImage: pane.icon)
                                .font(.system(size: 13))
                                .tag(pane)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            switch selection ?? .general {
            case .general: GeneralPane()
            case .connection: ConnectionPane()
            case .claude: ClaudePane()
            case .about: AboutPane()
            }
        }
        #if !os(macOS)
        // On a phone the split view collapses to the sidebar, so the way out has to
        // be a toolbar button rather than the Mac's list row.
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { model.isShowingSettings = false }
            }
        }
        #endif
    }
}

// MARK: - General

struct GeneralPane: View {
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("sendBehavior") private var sendBehavior = SendBehavior.returnKey.rawValue
    @AppStorage("showThinking") private var showThinking = true

    var body: some View {
        SettingsPane(title: "General") {
            SettingsSection("Appearance") {
                SettingsRow(title: "Theme", detail: "How Krog looks on this device.", isFirst: true) {
                    Picker("", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection("Composing") {
                SettingsRow(
                    title: "Send with",
                    detail: "The other combination inserts a line break.",
                    isFirst: true
                ) {
                    Picker("", selection: $sendBehavior) {
                        ForEach(SendBehavior.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection("Transcript") {
                SettingsRow(
                    title: "Show reasoning",
                    detail: "Adds a collapsed \"Thought process\" section to replies that include it.",
                    isFirst: true
                ) {
                    Toggle("", isOn: $showThinking).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

// MARK: - Krog Core

struct ConnectionPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("daemonHost") private var host = "127.0.0.1"
    @AppStorage("daemonPort") private var port = 7171
    @State private var draftHost = ""
    @State private var draftPort = 7171

    private var status: (String, Color) {
        switch model.connection {
        case .connected: return ("Connected", .green)
        case .connecting: return ("Connecting…", .secondary)
        case .disconnected: return ("Not connected", .red)
        }
    }

    var body: some View {
        SettingsPane(title: "Krog Core") {
            SettingsSection("Connection") {
                SettingsRow(title: "Status", isFirst: true) {
                    HStack(spacing: 6) {
                        Circle().fill(status.1).frame(width: 7, height: 7)
                        SettingsValue(text: status.0)
                    }
                }
                SettingsRow(title: "Host", detail: "A Tailscale name works here too.") {
                    TextField("127.0.0.1", text: $draftHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                SettingsRow(title: "Port") {
                    TextField("7171", value: $draftPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                SettingsRow(title: "", detail: nil) {
                    HStack {
                        Spacer()
                        Button("Reconnect") { apply() }
                            .disabled(draftHost.isEmpty || (draftHost == host && draftPort == port))
                    }
                }
            }

            SettingsSection("Server") {
                SettingsRow(title: "Protocol version", isFirst: true) {
                    SettingsValue(text: "v\(KrogClient.protocolVersion)")
                }
                SettingsRow(title: "Data") {
                    SettingsValue(text: "~/.krog on the host Mac", monospaced: true)
                }
            }
        }
        .onAppear {
            draftHost = host
            draftPort = port
        }
    }

    private func apply() {
        host = draftHost
        port = draftPort
        model.updateEndpoint(host: draftHost, port: draftPort)
    }
}

// MARK: - Claude

struct ClaudePane: View {
    @Environment(AppModel.self) private var model
    @State private var showingDisconnect = false

    private var methodLabel: String {
        switch model.auth.mode {
        case "api_key": return "Anthropic API key"
        case "subscription": return model.auth.subscription.planLabel
        default: return "Not connected"
        }
    }

    var body: some View {
        SettingsPane(title: "Claude") {
            SettingsSection("Credential") {
                SettingsRow(title: "Method", isFirst: true) {
                    SettingsValue(text: methodLabel)
                }
                if model.auth.mode == "subscription", let email = model.auth.subscription.email {
                    SettingsRow(title: "Account") { SettingsValue(text: email) }
                }
                if let version = model.auth.subscription.cliVersion, model.auth.mode == "subscription" {
                    SettingsRow(title: "Claude Code", detail: "Krog signs in through the CLI; the token stays with it.") {
                        SettingsValue(text: version)
                    }
                }
                SettingsRow(title: "", detail: nil) {
                    HStack {
                        Spacer()
                        Button("Disconnect", role: .destructive) { showingDisconnect = true }
                    }
                }
            }

            SettingsSection("Other providers") {
                SettingsRow(
                    title: "OpenAI, Grok, Kimi",
                    detail: "Planned. Each is a provider adapter on the core — no app update needed.",
                    isFirst: true
                ) {
                    Text("Soon")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: .capsule)
                }
            }
        }
        .confirmationDialog("Disconnect Claude?", isPresented: $showingDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task {
                    await model.signOut()
                    model.isShowingSettings = false
                }
            }
        } message: {
            Text("You'll go back through setup to reconnect.")
        }
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsPane(title: "About") {
            SettingsSection {
                SettingsRow(title: "Krog", detail: "Bots that live on your Mac.", isFirst: true) {
                    SettingsValue(text: version)
                }
            }
        }
    }
}
