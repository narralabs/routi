import SwiftUI

/// The provider roster shown in Settings.
///
/// Everything here is wired up except Moonshot, which is listed because it is the next
/// planned adapter and it is more honest to show it marked "Not yet available" than to
/// pretend the list is complete. Each is a daemon-side adapter, so the ones still to
/// come arrive without an app update.
struct ProviderInfo: Identifiable, Hashable {
    let id: String
    let name: String
    /// What the provider is called in conversation, if different from the company.
    let models: String
    /// One line on who runs the bot and what pays for it — the whole difference
    /// between a vendor's two entries.
    let summary: String
    /// Asset name of the brand mark. See `ProviderIcon`.
    let mark: String
    let tint: Color
    let isAvailable: Bool

    static let all: [ProviderInfo] = [
        // Two entries per vendor, named by what runs the bot: the vendor's own agent,
        // which is the only thing that can spend a personal plan, and the direct API,
        // which Routi drives itself. Both can be connected at once, so a Max plan can
        // carry the everyday bots while a key carries one that needs a named model.
        ProviderInfo(
            id: "anthropic-claude",
            name: "Claude Code",
            models: "Claude",
            summary: "Your Claude plan, or an API key. Anthropic's agent runs the bot.",
            mark: "ProviderAnthropic",
            tint: Color(red: 0.85, green: 0.47, blue: 0.34),
            isAvailable: true
        ),
        ProviderInfo(
            id: "anthropic",
            name: "Anthropic API",
            models: "Claude",
            summary: "An API key. Routi's agent runs the bot.",
            mark: "ProviderAnthropic",
            tint: Color(red: 0.62, green: 0.42, blue: 0.34),
            isAvailable: true
        ),
        ProviderInfo(
            id: "openai-codex",
            name: "Codex",
            models: "GPT",
            summary: "Your ChatGPT plan, or an API key. OpenAI's agent runs the bot.",
            mark: "ProviderOpenaiCodex",
            tint: Color(red: 0.22, green: 0.23, blue: 0.25),
            isAvailable: true
        ),
        ProviderInfo(
            id: "openai",
            name: "OpenAI API",
            models: "GPT",
            summary: "An API key. Routi's agent runs the bot.",
            mark: "ProviderOpenai",
            tint: Color(red: 0.07, green: 0.07, blue: 0.08),
            isAvailable: true
        ),
        ProviderInfo(
            id: "xai-grok",
            name: "Grok CLI",
            models: "Grok",
            summary: "Your SuperGrok plan, or an API key. xAI's agent runs the bot.",
            mark: "ProviderXai",
            tint: Color(red: 0.28, green: 0.29, blue: 0.32),
            isAvailable: true
        ),
        ProviderInfo(
            id: "xai",
            name: "xAI API",
            models: "Grok",
            summary: "An API key. Routi's agent runs the bot.",
            mark: "ProviderXai",
            tint: Color(red: 0.13, green: 0.14, blue: 0.16),
            isAvailable: true
        ),
        ProviderInfo(
            id: "deepseek",
            name: "DeepSeek API",
            models: "DeepSeek",
            summary: "An API key. Routi's agent runs the bot.",
            mark: "ProviderDeepseek",
            tint: Color(red: 0.29, green: 0.40, blue: 0.95),
            isAvailable: true
        ),
        ProviderInfo(
            id: "moonshot",
            name: "Moonshot",
            models: "Kimi",
            summary: "An API key. Routi's agent runs the bot.",
            mark: "ProviderMoonshot",
            tint: Color(red: 0.42, green: 0.34, blue: 0.85),
            isAvailable: false
        ),
    ]

    static func find(_ id: String) -> ProviderInfo {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Rounded-square tile carrying the provider's own mark.
///
/// The marks are the real ones, from LobeHub's MIT-licensed set — used to identify
/// which company answers a bot, which is what they are for. They replace the tinted
/// monograms that stood in while there was nothing better: a letter in a box says
/// nothing a reader recognises, and a hand-drawn approximation of a real logo looks
/// wrong beside the genuine article.
///
/// Each is a single-path template image, so it takes the tile's foreground colour and
/// stays crisp at any size rather than needing a bitmap per scale.
struct ProviderIcon: View {
    let provider: ProviderInfo
    var size: CGFloat = 22

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
    }

    var body: some View {
        shape
            .fill(provider.tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(provider.mark)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.24)
            }
            // Near-black tiles would otherwise vanish into a dark window.
            .overlay { shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
            .opacity(provider.isAvailable ? 1 : 0.45)
            .saturation(provider.isAvailable ? 1 : 0.3)
    }
}

// MARK: - Pane

struct ProviderPane: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderInfo

    var body: some View {
        if provider.isAvailable {
            ProviderConnectPane(provider: provider)
        } else {
            UnavailableProviderPane(provider: provider)
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
                    detail: "\(provider.name) is a planned adapter on Routi Core. Because providers live on the core, it will appear here without an app update.",
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
                Text(provider.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Connect

/// Connect a provider with either the vendor's own account or an API key.
///
/// A plan someone already pays for should be spendable without a second, metered
/// bill, and the only way to spend one is the vendor's own agent — so the account
/// path runs through that CLI's sign-in on the machine hosting the core, and Routi
/// never sees the credential; it only asks the CLI whether one exists.
///
/// One pane for every provider, Anthropic included: they differ in where a key comes
/// from and whose account it is, which is copy, not structure.
private struct ProviderConnectPane: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderInfo

    /// The ways to reach a provider.
    ///
    /// Credential and harness vary independently, but not freely: a consumer plan has
    /// no API of its own, so an account can only be spent through the vendor's agent.
    /// That is why this is one list rather than two questions — the fourth combination
    /// does not exist.
    private enum Setup: String, Identifiable {
        case account          // a personal plan, through the vendor's CLI
        case key              // an API key, spent by whichever harness this pane is

        var id: String { rawValue }
    }

    /// What the account is called where the user would recognise it.
    private var accountName: String {
        switch provider.id {
        case "anthropic-claude": return "Claude"
        case "xai-grok": return "Grok"
        default: return "ChatGPT"
        }
    }

    private func title(_ setup: Setup) -> String {
        switch setup {
        case .account: return "Use my \(accountName) account"
        case .key: return "Use an API key"
        }
    }

    /// A consumer plan has no API of its own, so an account is only spendable through
    /// the agent that holds the login. The direct providers offer one way in.
    private var setups: [Setup] {
        isHarness ? [.account, .key] : [.key]
    }

    /// Providers whose turns are run by a vendor CLI rather than by Routi.
    private var isHarness: Bool {
        ["anthropic-claude", "openai-codex", "xai-grok"].contains(provider.id)
    }

    /// Where to get a key, per provider.
    private var keySource: String {
        switch provider.id {
        case "anthropic", "anthropic-claude": return "console.anthropic.com"
        case "deepseek": return "platform.deepseek.com"
        case "xai", "xai-grok": return "console.x.ai"
        default: return "platform.openai.com"
        }
    }

    private func keyDetail(_ setup: Setup) -> String {
        switch provider.id {
        case "anthropic-claude":
            return "Billed per token, but run by Claude Code rather than by Routi. Choose this for Claude Code's behaviour without a Claude plan."
        case "anthropic":
            return "Billed per token. Routi's agent runs the bot."
        case "openai-codex":
            return "Billed per token, but run by the Codex agent rather than by Routi. Choose this for Codex's behaviour without a ChatGPT plan."
        case "xai-grok":
            return "Billed per token, but run by the Grok agent rather than by Routi. Choose this for Grok's behaviour without a Grok plan."
        case "deepseek", "xai":
            return "Billed per token. Routi's agent runs the bot, so it can use its screen."
        default:
            return "Billed per token. Routi's agent runs the bot and hands it the desktop, so it can use its screen."
        }
    }

    @State private var entering: Setup?
    @State private var apiKey = ""
    @State private var isWorking = false
    @State private var failure: String?
    /// What the connection check proved, shown once after connecting.
    @State private var verified: String?
    @State private var showingDisconnect = false

    /// Which of the three is in effect, read back from mode and harness.
    private var current: Setup? {
        guard let auth, auth.configured else { return nil }
        return auth.mode == "subscription" ? .account : .key
    }

    private var auth: AuthStatus.ProviderAuth? { model.auth.provider(provider.id) }
    private var isConnected: Bool { auth?.configured ?? false }

    private var methodLabel: String {
        switch current {
        case .account: return auth?.cli.account.map { "\($0) account" } ?? "\(accountName) account"
        case .key: return "API key"
        case nil: return "Not connected"
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

            if let verified {
                SettingsSection {
                    SettingsRow(
                        title: "Verified",
                        detail: "Routi sent a real request and \(verified). The key works and the account can answer.",
                        isFirst: true
                    ) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            if isConnected {
                SettingsSection(
                    "Models you can choose",
                    footnote: "What a bot here can run on. The model can be changed on the bot at any time."
                ) {
                    let list = model.models(for: provider.id)
                    if list.isEmpty {
                        SettingsRow(title: "None available", isFirst: true) { EmptyView() }
                    } else {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, info in
                            SettingsRow(
                                title: info.presentedName(in: list),
                                detail: info.description.isEmpty ? nil : info.description,
                                isFirst: index == 0
                            ) {
                                ModelRowValue(info: info, users: users(of: info.id))
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

            if isHarness, let version = auth?.cli.version {
                SettingsRow(
                    title: "Signed in through",
                    detail: current == .account
                        ? "Routi drives the \(cliName) CLI's own sign-in; the token stays with it."
                        : "Turns are run by the \(cliName) agent on this Mac, using its own config, not yours."
                ) {
                    SettingsValue(text: version)
                }
            }
            if auth?.mode == "api_key" {
                SettingsRow(
                    title: "Key storage",
                    detail: "Held in the login Keychain on the Mac running Routi Core."
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
        if let entering {
            SettingsSection(title(entering)) {
                SettingsRow(
                    title: "Key",
                    detail: "From \(keySource). " + keyDetail(entering),
                    isFirst: true
                ) {
                    SecureField("sk-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 220)
                        .onSubmit { submitKey(entering) }
                }
                SettingsRow(title: "") {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Back") { withAnimation { self.entering = nil; failure = nil } }
                        Button(isWorking ? "Verifying…" : "Connect") { submitKey(entering) }
                            .buttonStyle(.borderedProminent)
                            .disabled(apiKey.isEmpty || isWorking)
                    }
                }
            }
        } else {
            SettingsSection("Connect") {
                ForEach(Array(setups.enumerated()), id: \.element.id) { index, setup in
                    SettingsRow(
                        title: title(setup),
                        detail: setup == .account ? cliDetail : keyDetail(setup),
                        isFirst: index == 0
                    ) {
                        if setup == .account {
                            Button(isWorking ? "Connecting…" : "Connect") { connectAccount() }
                                .disabled(isWorking || !(auth?.cli.installed ?? false))
                        } else {
                            Button("Enter Key") { withAnimation { entering = setup; failure = nil } }
                                .disabled(isWorking)
                        }
                    }
                }
            }
        }
    }

    /// The CLI that holds this provider's account login.
    private var cliName: String {
        switch provider.id {
        case "anthropic-claude": return "Claude Code"
        case "xai-grok": return "Grok"
        default: return "Codex"
        }
    }

    private var installHint: String {
        provider.id == "xai-grok"
            ? "Install it with `curl -fsSL https://x.ai/cli/install.sh | bash` on that Mac."
            : "It ships with Routi Core, so this shouldn't happen — restart the core."
    }

    /// Who the browser sign-in is with.
    private var vendorName: String {
        switch provider.id {
        case "anthropic-claude": return "Anthropic"
        case "xai-grok": return "xAI"
        default: return "OpenAI"
        }
    }

    private var cliDetail: String {
        guard let cli = auth?.cli else { return "Checking for the \(cliName) CLI…" }
        if !cli.installed {
            return "Needs the \(cliName) CLI on the Mac running Routi Core. \(installHint)"
        }
        if cli.loggedIn {
            return "Already signed in on that Mac\(cli.account.map { " as \($0)" } ?? ""). No per-token billing."
        }
        return "Opens \(vendorName) in the browser on the Mac running Routi Core. No per-token billing."
    }

    /// Bots currently built on a given model. Answers "which of these is it?" by
    /// naming the bots rather than leaving the reader to infer from a list of choices.
    private func users(of modelID: String) -> [String] {
        model.bots
            .filter { $0.provider == provider.id && $0.model == modelID }
            .map(\.name)
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

    private func submitKey(_ setup: Setup) {
        guard !apiKey.isEmpty else { return }
        failure = nil
        isWorking = true
        Task {
            do {
                _ = setup
                verified = try await model.providerSetApiKey(provider.id, key: apiKey)
                apiKey = ""
                entering = nil
            } catch {
                failure = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// The right-hand side of a model row: which bots use it, or its real id.
private struct ModelRowValue: View {
    let info: ModelInfo
    let users: [String]

    var body: some View {
        if users.isEmpty {
            if let resolved = info.resolvedModel {
                SettingsValue(text: resolved, monospaced: true)
            }
        } else {
            HStack(spacing: 5) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(users.count == 1 ? users[0] : "\(users.count) bots")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(users.joined(separator: ", "))
        }
    }
}
