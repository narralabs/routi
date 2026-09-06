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
    /// than a single lumped "Connections" row. Routi Core is deliberately *not* in
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
            case .core: return "Routi Core"
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
        #if os(macOS)
        // A floating panel over the dimmed app, not a full-window takeover: the nav
        // list is plain rows rather than a split view, so the sheet keeps a fixed
        // size and never grows a sidebar toggle of its own.
        HStack(spacing: 0) {
            navList
                .frame(width: 232)
                .background(.background.secondary)

            ZStack(alignment: .topTrailing) {
                pane
                Button {
                    model.isShowingSettings = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .padding(14)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 880, height: 620)
        #else
        NavigationStack {
            navList
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.isShowingSettings = false }
                    }
                }
        }
        #endif
    }

    @ViewBuilder
    private var pane: some View {
        switch selection ?? .general {
        case .general: GeneralPane()
        case .provider(let id): ProviderPane(provider: ProviderInfo.find(id))
        case .core: ConnectionPane()
        case .about: AboutPane()
        }
    }

    private var navList: some View {
        List(selection: $selection) {
            ForEach(Self.sections, id: \.0) { group, panes in
                Section(group) {
                    ForEach(panes) { pane in
                        #if os(macOS)
                        PaneRow(pane: pane)
                            .tag(pane)
                            .listRowSeparator(.hidden)
                        #else
                        NavigationLink { paneView(pane) } label: { PaneRow(pane: pane) }
                        #endif
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    #if !os(macOS)
    @ViewBuilder
    private func paneView(_ pane: Pane) -> some View {
        switch pane {
        case .general: GeneralPane()
        case .provider(let id): ProviderPane(provider: ProviderInfo.find(id))
        case .core: ConnectionPane()
        case .about: AboutPane()
        }
    }
    #endif
}

/// One sidebar row. Providers render their brand mark on a tinted tile; everything else uses an
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
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage("sendBehavior") private var sendBehavior = SendBehavior.returnKey.rawValue
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("showToolActivity") private var showToolActivity = false

    var body: some View {
        SettingsPane(title: "General") {
            SettingsSection("Account") {
                AccountCard()
            }

            SettingsSection("Appearance") {
                SettingsRow(title: "Theme", detail: "How Routi looks on this device.", isFirst: true) {
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
                SettingsRow(
                    title: "Show tool activity",
                    detail: "Every page opened, click made and screenshot taken, as cards in the transcript. Off, the bot just says what it did."
                ) {
                    Toggle("", isOn: $showToolActivity).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

/// Avatar, editable name, account email, and sign-out — the card from the reference.
private struct AccountCard: View {
    @Environment(AppModel.self) private var model
    @State private var draftName = ""
    @State private var showingDisconnect = false

    var body: some View {
        HStack(spacing: 12) {
            Text(model.userInitials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                TextField("Your name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .onSubmit { Task { await model.setUserName(draftName) } }
                if let email = model.auth.subscription.email {
                    Text(email)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            Button("Sign Out") { showingDisconnect = true }
                .disabled(!model.auth.configured)
        }
        .padding(14)
        .onAppear { draftName = model.userName }
        // Commit on focus loss as well as Return; a name typed and abandoned should
        // still stick, the way every other settings field behaves.
        .onDisappear { Task { await model.setUserName(draftName) } }
        .confirmationDialog("Sign out of Claude?", isPresented: $showingDisconnect) {
            Button("Sign Out", role: .destructive) {
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

// MARK: - Routi Core

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
        SettingsPane(title: "Routi Core") {
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
                    SettingsValue(text: "v\(RoutiClient.protocolVersion)")
                }
                SettingsRow(title: "Data") {
                    SettingsValue(text: "~/.routi on the host Mac", monospaced: true)
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
                SettingsRow(title: "Routi Bot", detail: "Bots that live on your Mac.", isFirst: true) {
                    SettingsValue(text: version)
                }
            }
        }
    }
}
