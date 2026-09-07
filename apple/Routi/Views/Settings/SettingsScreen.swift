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
        case screens
        case about

        var id: String {
            switch self {
            case .general: return "general"
            case .provider(let id): return "provider.\(id)"
            case .core: return "core"
            case .screens: return "screens"
            case .about: return "about"
            }
        }

        var title: String {
            switch self {
            case .general: return "General"
            case .provider(let id): return ProviderInfo.find(id).name
            case .core: return "Routi Core"
            case .screens: return "Screens"
            case .about: return "About"
            }
        }

        var symbol: String? {
            switch self {
            case .general: return "gearshape"
            case .provider: return nil // uses ProviderIcon instead
            case .core: return "externaldrive.connected.to.line.below"
            case .screens: return "desktopcomputer"
            case .about: return "info.circle"
            }
        }
    }

    private static let sections: [(String, [Pane])] = [
        ("App", [.general]),
        ("Providers", ProviderInfo.all.map { .provider($0.id) }),
        ("Core", [.core, .screens]),
        ("About", [.about]),
    ]

    @State private var selection: Pane? = .general

    /// The pane the opener asked for, if any, else General.
    private func openRequestedPane() {
        guard let requested = model.requestedSettingsPane else { return }
        model.requestedSettingsPane = nil
        switch requested {
        case "general": selection = .general
        case "core": selection = .core
        case "screens": selection = .screens
        case "about": selection = .about
        default: selection = .provider(requested)
        }
    }

    var body: some View {
        #if os(macOS)
        // A floating panel over the dimmed app, not a full-window takeover: the nav
        // list is plain rows rather than a split view, so the sheet keeps a fixed
        // size and never grows a sidebar toggle of its own.
        HStack(spacing: 0) {
            navList
                .frame(width: 232)
                .background(.background.secondary)
                .onAppear(perform: openRequestedPane)

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
        case .screens: ScreensPane()
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
        case .screens: ScreensPane()
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
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("showToolActivity") private var showToolActivity = false

    var body: some View {
        SettingsPane(title: "General") {
            SettingsSection("Account") {
                AccountCard()
            }

            // What every bot knows about the person. Here rather than in a bot's rail
            // because it is not any one bot's: the same list reaches all of them.
            SettingsSection(
                "About you",
                footnote: "Read by every bot before it answers — your name, your timezone, how you like things done. Bots add to this as they learn; you can too."
            ) {
                AboutYouRows()
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

/// The shared notes as rows. A row opens the note; the last row adds one.
private struct AboutYouRows: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Memory?
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.sharedMemories.enumerated()), id: \.element.id) { index, memory in
                if index > 0 { Divider().padding(.leading, 14) }
                Button { editing = memory } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(memory.text)
                            .font(.system(size: 13))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !model.sharedMemories.isEmpty { Divider().padding(.leading, 14) }
            Button { adding = true } label: {
                Label("Add a fact", systemImage: "plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .sheet(item: $editing) { memory in
            NoteEditor(title: "About you", memory: memory)
        }
        .sheet(isPresented: $adding) {
            NoteEditor(title: "About you", memory: nil) { text in
                await model.addSharedMemory(text)
            }
        }
        .task { await model.loadSharedMemories() }
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
                SettingsRow(title: "Version", isFirst: true) {
                    SettingsValue(text: model.coreVersion.map { "v\($0)" } ?? "—")
                }
                if showsCoreUpdate {
                    SettingsRow(title: "Update", detail: coreUpdateDetail) {
                        if model.isUpdatingCore {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(model.coreUpdateStage ?? "Updating…")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .frame(maxWidth: 260, alignment: .trailing)
                            }
                        } else if model.coreUpdate?.available == true {
                            Button("Update Routi Core") { Task { await model.startCoreUpdate() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(!(model.coreUpdate?.canUpdate ?? false))
                        }
                    }
                }
                if model.appUpdateAvailable {
                    SettingsRow(
                        title: "App",
                        detail: "Routi Bot \(model.coreUpdate?.latest ?? "") is out; this is \(model.appVersion). The app does not update itself yet."
                    ) {
                        Link("Download", destination: AppModel.dmgURL)
                    }
                }
                SettingsRow(title: "Protocol") {
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
        .task { await model.checkCoreUpdate() }
    }

    private var showsCoreUpdate: Bool {
        model.isUpdatingCore || model.coreUpdateOutcome != nil || model.coreUpdate?.available == true
    }

    /// What the Update row says: the outcome of the last run, else the offer.
    private var coreUpdateDetail: String? {
        if model.isUpdatingCore { return "Bots pause while the core is rebuilt and restarted. This window reconnects by itself." }
        if let outcome = model.coreUpdateOutcome { return outcome }
        guard let update = model.coreUpdate, update.available, let latest = update.latest else { return nil }
        if !update.canUpdate, let reason = update.reason { return "Routi Core \(latest) is out. \(reason)" }
        return "Routi Core \(latest) is out; this core is \(update.current). Downloads and builds it, then restarts the core — a few minutes, during which bots pause."
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
            HStack(spacing: 16) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Routi Bot")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Version \(version)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text("Copyright © 2026 Narra Labs, LLC")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)

            SettingsSection("Open source") {
                SettingsRow(
                    title: "License",
                    detail: "Apache-2.0. The code is free to use, change and share; the copyright stays with Narra Labs.",
                    isFirst: true
                ) {
                    Link("routi on GitHub", destination: URL(string: "https://github.com/narralabs/routi")!)
                        .font(.system(size: 12.5))
                }
                SettingsRow(
                    title: "Provider marks",
                    detail: "From LobeHub's icon set, MIT. See NOTICE in the repository."
                ) {
                    Link("lobe-icons", destination: URL(string: "https://github.com/lobehub/lobe-icons")!)
                        .font(.system(size: 12.5))
                }
            }
        }
    }
}

// MARK: - Screens

/// The machine the container screens live on: what state it is in and what to do.
/// Refreshed while it is on screen, since the thing it describes changes in another app.
struct ScreensPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsPane(title: "Screens") {
            SettingsSection(
                "Desktop",
                footnote: "Bots set to Container get a screen on a shared Linux machine, one display each, with a browser. It runs in Docker on the Mac running Routi Core; bots set to None or This Mac do not need it."
            ) {
                DesktopHostView()
                    .padding(12)
            }

        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await model.refreshDesktopHost()
            }
        }
    }
}
