import SwiftUI

/// The provider roster shown in Settings.
///
/// Only Anthropic is wired up; the rest are listed because they are the planned
/// adapters and it is more honest to show them marked "Not yet available" than to
/// pretend the list is complete. Each is a daemon-side adapter, so none of them will
/// need an app update to arrive.
struct ProviderInfo: Identifiable, Hashable {
    let id: String
    let name: String
    /// What the provider is called in conversation, if different from the company.
    let models: String
    let monogram: String
    let tint: Color
    let isAvailable: Bool

    static let all: [ProviderInfo] = [
        ProviderInfo(
            id: "anthropic",
            name: "Anthropic",
            models: "Claude",
            monogram: "A",
            tint: Color(red: 0.85, green: 0.47, blue: 0.34),
            isAvailable: true
        ),
        ProviderInfo(
            id: "openai",
            name: "OpenAI",
            models: "GPT",
            monogram: "O",
            tint: Color(red: 0.06, green: 0.64, blue: 0.50),
            isAvailable: true
        ),
        ProviderInfo(
            id: "xai",
            name: "xAI",
            models: "Grok",
            monogram: "G",
            tint: Color(red: 0.20, green: 0.22, blue: 0.26),
            isAvailable: false
        ),
        ProviderInfo(
            id: "moonshot",
            name: "Moonshot",
            models: "Kimi",
            monogram: "K",
            tint: Color(red: 0.42, green: 0.34, blue: 0.85),
            isAvailable: false
        ),
    ]

    static func find(_ id: String) -> ProviderInfo {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Rounded-square monogram tile.
///
/// Deliberately not a reproduction of anyone's logo: a consistent set of tinted
/// monograms reads as intentional design, where hand-drawn approximations of real
/// brand marks would just look wrong next to the genuine article.
struct ProviderIcon: View {
    let provider: ProviderInfo
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(provider.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(provider.monogram)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .opacity(provider.isAvailable ? 1 : 0.45)
            .saturation(provider.isAvailable ? 1 : 0.3)
    }
}

// MARK: - Pane

struct ProviderPane: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderInfo

    var body: some View {
        if provider.id == "anthropic" {
            AnthropicPane(provider: provider)
        } else if provider.id == "openai" {
            OpenAiPane(provider: provider)
        } else {
            UnavailableProviderPane(provider: provider)
        }
    }
}

private struct AnthropicPane: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderInfo
    @State private var showingDisconnect = false

    private var methodLabel: String {
        switch model.auth.mode {
        case "api_key": return "API key"
        case "subscription": return model.auth.subscription.planLabel
        default: return "Not connected"
        }
    }

    private var isConnected: Bool { model.auth.configured }

    var body: some View {
        SettingsPane(title: provider.name) {
            ProviderHeader(provider: provider, isConnected: isConnected)

            SettingsSection("Credential") {
                SettingsRow(title: "Method", isFirst: true) {
                    SettingsValue(text: methodLabel)
                }
                if model.auth.mode == "subscription", let email = model.auth.subscription.email {
                    SettingsRow(title: "Account") { SettingsValue(text: email) }
                }
                if model.auth.mode == "subscription", let version = model.auth.subscription.cliVersion {
                    SettingsRow(
                        title: "Signed in through",
                        detail: "Krog drives the Claude Code CLI's browser sign-in; the token stays with it."
                    ) {
                        // `claude --version` already reports "2.1.261 (Claude Code)",
                        // so prefixing the name again reads as a stutter.
                        SettingsValue(text: version)
                    }
                }
                if model.auth.mode == "api_key" {
                    SettingsRow(
                        title: "Key storage",
                        detail: "Held in the login Keychain on the Mac running Krog Core."
                    ) {
                        SettingsValue(text: "Keychain")
                    }
                }
                SettingsRow(title: "") {
                    HStack {
                        Spacer()
                        Button("Disconnect", role: .destructive) { showingDisconnect = true }
                            .disabled(!isConnected)
                    }
                }
            }

            SettingsSection("Models") {
                if model.models.isEmpty {
                    SettingsRow(title: "None available", isFirst: true) { EmptyView() }
                } else {
                    ForEach(Array(model.models.enumerated()), id: \.element.id) { index, info in
                        SettingsRow(
                            title: info.displayName,
                            detail: info.description.isEmpty ? nil : info.description,
                            isFirst: index == 0
                        ) {
                            if let resolved = info.resolvedModel {
                                SettingsValue(text: resolved, monospaced: true)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Disconnect \(provider.name)?", isPresented: $showingDisconnect) {
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

private struct UnavailableProviderPane: View {
    let provider: ProviderInfo

    var body: some View {
        SettingsPane(title: provider.name) {
            ProviderHeader(provider: provider, isConnected: false)

            SettingsSection {
                SettingsRow(
                    title: "Not yet available",
                    detail: "\(provider.name) is a planned adapter on Krog Core. Because providers live on the core, it will appear here without an app update.",
                    isFirst: true
                ) {
                    EmptyView()
                }
            }
        }
    }
}

/// Large icon, name, and connection state at the top of a provider pane.
private struct ProviderHeader: View {
    let provider: ProviderInfo
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ProviderIcon(provider: provider, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(provider.models)
                    .font(.system(size: 15, weight: .semibold))
                StatusPill(isConnected: isConnected, isAvailable: provider.isAvailable)
            }

            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }
}

private struct StatusPill: View {
    let isConnected: Bool
    let isAvailable: Bool

    private var content: (String, Color) {
        if !isAvailable { return ("Coming soon", .secondary) }
        return isConnected ? ("Connected", .green) : ("Not connected", .secondary)
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(content.1).frame(width: 6, height: 6)
            Text(content.0)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - OpenAI

/// Connect OpenAI with either a ChatGPT account or an API key.
///
/// The same two paths as Anthropic, for the same reason: a plan someone already pays
/// for should be spendable without a second, metered bill. The account path runs
/// through the Codex CLI's own browser sign-in on the machine hosting the core, so
/// Krog never sees the credential — it only asks the CLI whether one exists.
private struct OpenAiPane: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderInfo

    @State private var isEnteringKey = false
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var failure: String?
    @State private var showingDisconnect = false

    private var auth: AuthStatus.ProviderAuth? { model.auth.provider(provider.id) }
    private var isConnected: Bool { auth?.configured ?? false }

    private var methodLabel: String {
        switch auth?.mode {
        case "api_key": return "API key"
        case "subscription": return auth?.cli.account.map { "\($0) account" } ?? "ChatGPT account"
        default: return "Not connected"
        }
    }

    var body: some View {
        SettingsPane(title: provider.name) {
            ProviderHeader(provider: provider, isConnected: isConnected)

            if isConnected {
                connected
            } else {
                choices
            }

            if let failure {
                SettingsSection {
                    SettingsRow(title: "Couldn't connect", detail: failure, isFirst: true) { EmptyView() }
                }
            }

            if isConnected {
                SettingsSection("Models") {
                    let list = model.models(for: provider.id)
                    if list.isEmpty {
                        SettingsRow(title: "None available", isFirst: true) { EmptyView() }
                    } else {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, info in
                            SettingsRow(
                                title: info.displayName,
                                detail: info.description.isEmpty ? nil : info.description,
                                isFirst: index == 0
                            ) {
                                if let resolved = info.resolvedModel {
                                    SettingsValue(text: resolved, monospaced: true)
                                }
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Disconnect \(provider.name)?", isPresented: $showingDisconnect) {
            Button("Disconnect", role: .destructive) {
                Task { await model.providerSignOut(provider.id) }
            }
        } message: {
            Text("Bots already using \(provider.name) will stop working until you reconnect.")
        }
    }

    @ViewBuilder
    private var connected: some View {
        SettingsSection("Credential") {
            SettingsRow(title: "Method", isFirst: true) { SettingsValue(text: methodLabel) }

            if auth?.mode == "subscription", let version = auth?.cli.version {
                SettingsRow(
                    title: "Signed in through",
                    detail: "Krog drives the Codex CLI's browser sign-in; the token stays with it."
                ) {
                    SettingsValue(text: version)
                }
            }
            if auth?.mode == "api_key" {
                SettingsRow(
                    title: "Key storage",
                    detail: "Held in the login Keychain on the Mac running Krog Core."
                ) {
                    SettingsValue(text: "Keychain")
                }
            }
            SettingsRow(title: "") {
                HStack {
                    Spacer()
                    Button("Disconnect", role: .destructive) { showingDisconnect = true }
                }
            }
        }
    }

    @ViewBuilder
    private var choices: some View {
        if isEnteringKey {
            SettingsSection("API key") {
                SettingsRow(
                    title: "Key",
                    detail: "From platform.openai.com. Billed per token against your OpenAI account.",
                    isFirst: true
                ) {
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 220)
                        .onSubmit(submitKey)
                }
                SettingsRow(title: "") {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Cancel") { withAnimation { isEnteringKey = false; failure = nil } }
                        Button("Connect", action: submitKey)
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKey.isEmpty || isWorking)
                    }
                }
            }
        } else {
            SettingsSection("Connect") {
                SettingsRow(
                    title: "Use my ChatGPT account",
                    detail: cliDetail,
                    isFirst: true
                ) {
                    Button(isWorking ? "Connecting…" : "Connect") { connectAccount() }
                        .disabled(isWorking || !(auth?.cli.installed ?? false))
                }
                SettingsRow(
                    title: "Use an API key",
                    detail: "Billed per token. Good if you don't have a ChatGPT plan."
                ) {
                    Button("Enter Key") { withAnimation { isEnteringKey = true; failure = nil } }
                        .disabled(isWorking)
                }
            }
        }
    }

    private var cliDetail: String {
        guard let cli = auth?.cli else { return "Checking for the Codex CLI…" }
        if !cli.installed {
            return "Needs the Codex CLI on the Mac running Krog Core. Install it with `npm install -g @openai/codex`."
        }
        if cli.loggedIn {
            return "Already signed in on that Mac\(cli.account.map { " using \($0)" } ?? ""). No per-token billing."
        }
        return "Opens OpenAI in the browser on the Mac running Krog Core. No per-token billing."
    }

    private func connectAccount() {
        failure = nil
        isWorking = true
        Task {
            do {
                try await model.providerLogin(provider.id)
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func submitKey() {
        guard !apiKey.isEmpty else { return }
        failure = nil
        isWorking = true
        Task {
            do {
                try await model.providerSetApiKey(provider.id, key: apiKey)
                apiKey = ""
                isEnteringKey = false
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }
}
