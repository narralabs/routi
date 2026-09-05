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

    /// Providers each get their own entry, so the section reads as a roster rather
    /// than a single lumped "Connections" row. Krog Core is deliberately *not* in
    /// there — it is the daemon this app talks to, not a model provider.
    enum Pane: Hashable, Identifiable {
        case general
        case provider(String)
        case core
        case about

        var id: String {
            switch self {
            case .general: return "general"
            case .provider(let id): return "provider.\(id)"
            case .core: return "core"
            case .about: return "about"
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .provider(let id): return ProviderInfo.find(id).name
            case .core: return "Krog Core"
            case .about: return "About"
            }
        }

        var symbol: String? {
            switch self {
            case .general: return "gearshape"
            case .provider: return nil // uses ProviderIcon instead
            case .core: return "externaldrive.connected.to.line.below"
            case .about: return "info.circle"
            }
        }
    }

    private static let sections: [(String, [Pane])] = [
        ("App", [.general]),
        ("Providers", ProviderInfo.all.map { .provider($0.id) }),
        ("Core", [.core]),
        ("About", [.about]),
    ]

    @State private var selection: Pane? = .general

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

                ForEach(Self.sections, id: \.0) { group, panes in
                    Section(group) {
                        ForEach(panes) { pane in
                            PaneRow(pane: pane)
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
            case .provider(let id): ProviderPane(provider: ProviderInfo.find(id))
            case .core: ConnectionPane()
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

/// One sidebar row. Providers render their tinted monogram; everything else uses an
/// SF Symbol, sized to line up with it.
private struct PaneRow: View {
    let pane: SettingsScreen.Pane

    var body: some View {
        HStack(spacing: 9) {
            Group {
                if case .provider(let id) = pane {
                    ProviderIcon(provider: ProviderInfo.find(id), size: 20)
                } else if let symbol = pane.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                        .frame(width: 20, height: 20)
                }
            }
            Text(pane.title).font(.system(size: 13))
            Spacer(minLength: 0)
            if case .provider(let id) = pane, !ProviderInfo.find(id).isAvailable {
                Text("Soon")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
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
