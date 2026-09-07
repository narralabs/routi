import SwiftUI

// MARK: - Welcome

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            icon: "sparkles",
            logo: "Logo",
            title: "Welcome to Routi Bot",
            subtitle: "Bots that live on your Mac, work in a browser of their own, and run on the AI you already pay for."
        ) {
            EmptyView()
        } actions: {
            Button(action: onContinue) {
                Text("Get Started").frame(maxWidth: 260)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Where does the core run

/// Reached only when no core answered on this Mac, so the local choice is to install
/// one rather than to use one.
struct ConnectionStep: View {
    let onInstallHere: () -> Void
    let onConnectRemote: () -> Void

    var body: some View {
        OnboardingScaffold(
            icon: "externaldrive.connected.to.line.below",
            title: "Where should Routi run?",
            subtitle: "Routi Core keeps your bots, conversations, and AI connections, and does the work. It needs a Mac that stays on."
        ) {
            VStack(spacing: 12) {
                OptionCard(
                    icon: "desktopcomputer",
                    title: "Install Routi Core on this Mac",
                    detail: "One command in Terminal. Best if this is the machine that stays awake; your phone can connect to it later.",
                    isRecommended: true,
                    action: onInstallHere
                )
                OptionCard(
                    icon: "network",
                    title: "Connect to another Mac",
                    detail: "Routi Core is already running somewhere else — your Mac mini, or a server.",
                    action: onConnectRemote
                )
            }
            .frame(maxWidth: 420)
        } actions: {
            EmptyView()
        }
    }
}

// MARK: - Install the core here

/// The install command, and a watch on the port.
///
/// There is nothing to press to continue: the app keeps trying the port while the
/// installer runs, and moves on the moment the core answers. The one thing a person
/// does here is paste a line into Terminal, so that is the one thing on the screen.
struct InstallStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onConnected: () -> Void

    var body: some View {
        OnboardingScaffold(
            icon: "terminal",
            title: "Install Routi Core",
            subtitle: "Paste this into Terminal. It installs the core and starts it at every login. Claude Code and Codex come with it; nothing else to install."
        ) {
            VStack(spacing: 18) {
                InstallCommand()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the core to start… this screen moves on by itself.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 460)
        } actions: {
            Button("Back", action: onBack)
                .controlSize(.large)
        }
        .task { await model.watchForCore() }
        .onChange(of: model.connection, initial: true) { _, state in
            if state == .connected { onConnected() }
        }
    }
}

// MARK: - Endpoint

struct EndpointStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onConnected: () -> Void

    @AppStorage("daemonHost") private var host = "127.0.0.1"
    @AppStorage("daemonPort") private var port = 7171
    @State private var isConnecting = false
    @State private var failure: String?

    var body: some View {
        OnboardingScaffold(
            icon: "network",
            title: "Connect to Routi",
            subtitle: "Enter the address of the Mac running Routi. A Tailscale name works here too."
        ) {
            VStack(spacing: 14) {
                Form {
                    TextField("Host", text: $host, prompt: Text("mac-mini.tail1234.ts.net"))
                    TextField("Port", value: $port, format: .number.grouping(.never))
                }
                .formStyle(.grouped)
                .frame(height: 100)

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 420)
        } actions: {
            HStack(spacing: 12) {
                Button("Back", action: onBack)
                    .controlSize(.large)

                Button(action: connect) {
                    if isConnecting {
                        ProgressView().controlSize(.small).frame(maxWidth: 200)
                    } else {
                        Text("Connect").frame(maxWidth: 200)
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(host.isEmpty || isConnecting)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func connect() {
        isConnecting = true
        failure = nil
        model.updateEndpoint(host: host, port: port)

        Task {
            // Give the socket a moment, then judge by the connection state rather
            // than assuming success.
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
                if model.connection == .connected {
                    isConnecting = false
                    onConnected()
                    return
                }
            }
            isConnecting = false
            failure = "Couldn't reach Routi at \(host):\(port). Check that routid is running and that this device can see that Mac."
        }
    }
}

// MARK: - First connection

/// The one connection Routi needs to start, from whichever of the four a person has.
///
/// This was Anthropic-only, which made the app unusable for someone with a ChatGPT plan
/// and no Claude account — the daemon supports them; the first screen refused them.
/// Accounts run through the vendor CLI's own sign-in on the Mac running the core; keys
/// are checked against the live API before they are stored.
struct CredentialStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onDone: () -> Void

    private enum Choice: String, Identifiable {
        case claude, anthropicKey, codex, openaiKey
        var id: String { rawValue }
    }
    private enum Mode { case choosing, key(Choice), signingIn(Choice) }

    @State private var mode: Mode = .choosing
    @State private var apiKey = ""
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        OnboardingScaffold(icon: "brain", title: "Connect an AI", subtitle: subtitle) {
            VStack(spacing: 12) {
                switch mode {
                case .choosing: choices
                case .key: keyField
                case .signingIn(let choice): signingIn(choice)
                }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 440, alignment: .leading)
                }
            }
            .frame(maxWidth: 460)
        } actions: {
            actions
        }
    }

    private var subtitle: String {
        switch mode {
        case .choosing:
            return "Routi needs one connection to start. Use a plan you already pay for, or an API key. More can be added later in Settings."
        case .key(.anthropicKey):
            return "Paste a key from console.anthropic.com. It's stored in this Mac's Keychain, never in the app."
        case .key:
            return "Paste a key from platform.openai.com. It's stored in this Mac's Keychain, never in the app."
        case .signingIn:
            return "Finish signing in, in the browser window that just opened on the Mac running Routi."
        }
    }

    @ViewBuilder
    private var choices: some View {
        let claude = model.auth.subscription
        let codex = model.auth.provider("openai-codex")?.cli

        OptionCard(
            icon: "person.crop.circle.badge.checkmark",
            title: claude.loggedIn ? "Continue with \(claude.planLabel)" : "Use my Claude account",
            detail: claude.loggedIn
                ? "Already signed in on this Mac through Claude Code. No extra cost — it uses the plan you have."
                : "Opens Anthropic in your browser to sign in through Claude Code. No per-token billing.",
            badge: claude.loggedIn ? claude.email : nil,
            isRecommended: true,
            action: { signIn(.claude) }
        )
        OptionCard(
            icon: "person.crop.circle",
            title: codex?.loggedIn == true ? "Continue with my ChatGPT account" : "Use my ChatGPT account",
            detail: codex?.loggedIn == true
                ? "Already signed in on this Mac through Codex. No per-token billing."
                : "Opens OpenAI in your browser to sign in through Codex. No per-token billing.",
            badge: codex?.loggedIn == true ? codex?.account : nil,
            action: { signIn(.codex) }
        )
        OptionCard(
            icon: "key.horizontal",
            title: "Use an Anthropic API key",
            detail: "Billed per token against your Anthropic account. Routi's agent runs the bot.",
            action: { withAnimation { mode = .key(.anthropicKey); failure = nil } }
        )
        OptionCard(
            icon: "key.horizontal",
            title: "Use an OpenAI API key",
            detail: "Billed per token against your OpenAI account. Routi's agent runs the bot.",
            action: { withAnimation { mode = .key(.openaiKey); failure = nil } }
        )

        // Claude Code and Codex both ship with the core, so neither account option
        // needs anything installed first; sign-in is the only step.
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(isAnthropicKey ? "sk-ant-…" : "sk-…", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(submitKey)
            Link(
                isAnthropicKey ? "Get a key at console.anthropic.com" : "Get a key at platform.openai.com",
                destination: URL(string: isAnthropicKey
                    ? "https://console.anthropic.com/settings/keys"
                    : "https://platform.openai.com/api-keys")!
            )
            .font(.system(size: 12))
        }
    }

    private var isAnthropicKey: Bool {
        if case .key(.anthropicKey) = mode { return true }
        return false
    }

    private func signingIn(_ choice: Choice) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(choice == .claude ? "Waiting for you to approve with Anthropic…" : "Waiting for you to approve with OpenAI…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            #if !os(macOS)
            Text("The browser opens on the Mac running Routi, not here.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            #endif
        }
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var actions: some View {
        switch mode {
        case .choosing:
            Button("Back", action: onBack).controlSize(.large)
        case .key:
            HStack(spacing: 12) {
                Button("Back") { withAnimation { mode = .choosing; failure = nil } }
                    .controlSize(.large)
                Button(action: submitKey) {
                    if isWorking {
                        ProgressView().controlSize(.small).frame(maxWidth: 200)
                    } else {
                        Text("Connect").frame(maxWidth: 200)
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty || isWorking)
                .keyboardShortcut(.defaultAction)
            }
        case .signingIn:
            Button("Cancel") { withAnimation { mode = .choosing; isWorking = false } }
                .controlSize(.large)
        }
    }

    private func signIn(_ choice: Choice) {
        failure = nil
        isWorking = true
        withAnimation { mode = .signingIn(choice) }
        Task {
            do {
                if choice == .claude {
                    try await model.signInWithClaude()
                } else {
                    try await model.providerLogin("openai-codex")
                }
                onDone()
            } catch {
                isWorking = false
                withAnimation { mode = .choosing }
                failure = error.localizedDescription
            }
        }
    }

    private func submitKey() {
        guard !apiKey.isEmpty else { return }
        failure = nil
        isWorking = true
        Task {
            do {
                if isAnthropicKey {
                    try await model.setApiKey(apiKey)
                } else {
                    _ = try await model.providerSetApiKey("openai", key: apiKey)
                }
                onDone()
            } catch {
                isWorking = false
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Screens

/// Where the bots' screens come from, said up front.
///
/// Docker was a surprise: nothing in setup mentioned it, and the first bot to ask for
/// a screen ended at a message about it. This step says what the desktop is, checks
/// what that Mac has, and offers to build it now — or to skip, since a bot that only
/// talks needs none of it.
struct ScreensStep: View {
    @Environment(AppModel.self) private var model
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            icon: "desktopcomputer",
            title: "Give your bots a screen",
            subtitle: "A bot that browses for you gets a desktop of its own: a Linux machine with a browser, one screen per bot, kept apart from yours. It runs in Docker on the Mac running Routi Core."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                DesktopHostView()
                Text("Bots without a screen still work. This can be set up any time under Settings → Screens.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 460)
        } actions: {
            Button(action: onContinue) {
                Text(model.desktopHost?.isReady == true ? "Continue" : "Skip for now").frame(maxWidth: 260)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Finishing

struct FinishingStep: View {
    @Environment(AppModel.self) private var model
    @State private var displayName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        OnboardingScaffold(
            icon: "checkmark.circle.fill",
            title: "You're set",
            subtitle: summary
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What should we call you?")
                    .font(.system(size: 13, weight: .medium))
                TextField("Your name", text: $displayName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($nameFocused)
            }
            .frame(maxWidth: 300)
            .onAppear {
                // Pre-fill from the Anthropic account so most people just continue.
                if displayName.isEmpty { displayName = model.account?.firstName ?? "" }
            }
        } actions: {
            Button {
                Task {
                    await model.setUserName(displayName)
                    model.completeOnboarding()
                }
            } label: {
                Text("Start Chatting").frame(maxWidth: 260)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var summary: String {
        let auth = model.auth
        if auth.mode == "api_key" { return "Connected to Claude with your API key." }
        if auth.mode == "subscription", let email = auth.subscription.email {
            return "Connected as \(email) on \(auth.subscription.planLabel)."
        }
        if let codex = auth.provider("openai-codex"), codex.configured {
            return codex.mode == "api_key" ? "Connected to OpenAI with your API key." : "Connected with your ChatGPT account."
        }
        if auth.provider("openai")?.configured == true { return "Connected to OpenAI with your API key." }
        return "You're connected."
    }
}
