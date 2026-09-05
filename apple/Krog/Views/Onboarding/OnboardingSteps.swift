import SwiftUI

// MARK: - Welcome

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        OnboardingScaffold(
            icon: "sparkles",
            title: "Welcome to Krog",
            subtitle: "Bots that live on your Mac, work while you're away, and answer from your phone."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(
                    icon: "person.2.fill",
                    title: "Bots with their own minds",
                    detail: "Give each one a personality, a model, and its own ongoing conversation."
                )
                FeatureRow(
                    icon: "desktopcomputer",
                    title: "They get a screen",
                    detail: "Hand a bot a sandboxed desktop — or your real one — and watch it work."
                )
                FeatureRow(
                    icon: "iphone.and.arrow.forward",
                    title: "Yours, everywhere",
                    detail: "Everything runs on your Mac. Your phone is just another window onto it."
                )
            }
            .frame(maxWidth: 400)
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

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Where does the core run

struct ConnectionStep: View {
    let onHostHere: () -> Void
    let onConnectRemote: () -> Void

    var body: some View {
        OnboardingScaffold(
            icon: "externaldrive.connected.to.line.below",
            title: "Where should Krog run?",
            subtitle: "Krog's core keeps your bots, conversations, and Anthropic connection. It needs a Mac that stays on."
        ) {
            VStack(spacing: 12) {
                OptionCard(
                    icon: "desktopcomputer",
                    title: "Run it on this Mac",
                    detail: "Best if this is the machine that stays awake. Your phone can connect to it later.",
                    isRecommended: true,
                    action: onHostHere
                )
                OptionCard(
                    icon: "network",
                    title: "Connect to another Mac",
                    detail: "Krog is already running somewhere else — your Mac mini, or a server.",
                    action: onConnectRemote
                )
            }
            .frame(maxWidth: 420)
        } actions: {
            EmptyView()
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
            title: "Connect to Krog",
            subtitle: "Enter the address of the Mac running Krog. A Tailscale name works here too."
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
            failure = "Couldn't reach Krog at \(host):\(port). Check that krogd is running and that this device can see that Mac."
        }
    }
}

// MARK: - Anthropic

struct AnthropicStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void
    let onDone: () -> Void

    private enum Mode { case choosing, apiKey, signingIn }
    @State private var mode: Mode = .choosing
    @State private var apiKey = ""
    @State private var failure: String?
    @State private var isWorking = false

    var body: some View {
        OnboardingScaffold(
            icon: "brain",
            title: "Connect Claude",
            subtitle: subtitle
        ) {
            VStack(spacing: 12) {
                switch mode {
                case .choosing: choices
                case .apiKey: apiKeyField
                case .signingIn: signingIn
                }

                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }
            .frame(maxWidth: 440)
        } actions: {
            actions
        }
    }

    private var subtitle: String {
        switch mode {
        case .choosing:
            return "Krog needs a way to reach Claude. You can use the Claude plan you already pay for, or an API key."
        case .apiKey:
            return "Paste a key from console.anthropic.com. It's stored in this Mac's Keychain, never in the app."
        case .signingIn:
            return "Finish signing in with Anthropic in the browser window that just opened."
        }
    }

    @ViewBuilder
    private var choices: some View {
        let sub = model.auth.subscription

        OptionCard(
            icon: "person.crop.circle.badge.checkmark",
            title: sub.loggedIn ? "Continue with \(sub.planLabel)" : "Use my Claude account",
            detail: sub.loggedIn
                ? "Already signed in on this Mac. No extra cost — it uses the plan you have."
                : "Opens Anthropic in your browser to sign in. No per-token billing.",
            badge: sub.loggedIn ? sub.email : nil,
            isRecommended: true,
            action: signInWithClaude
        )

        OptionCard(
            icon: "key.horizontal",
            title: "Use an Anthropic API key",
            detail: "Billed per token against your Anthropic account. Good if you don't have a Claude plan.",
            action: { withAnimation { mode = .apiKey; failure = nil } }
        )

        if !sub.cliInstalled {
            // The account option depends on the Claude Code CLI being present, so say
            // so up front rather than failing after the click.
            Label(
                "Signing in with a Claude account needs Claude Code on this Mac. Install it with `npm install -g @anthropic-ai/claude-code`.",
                systemImage: "info.circle"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField("sk-ant-…", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(submitApiKey)

            Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.system(size: 12))
        }
    }

    private var signingIn: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Waiting for you to approve in the browser…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            #if !os(macOS)
            Text("The browser opens on the Mac running Krog, not here.")
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

        case .apiKey:
            HStack(spacing: 12) {
                Button("Back") { withAnimation { mode = .choosing; failure = nil } }
                    .controlSize(.large)
                Button(action: submitApiKey) {
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

    private func signInWithClaude() {
        failure = nil
        isWorking = true
        withAnimation { mode = .signingIn }
        Task {
            do {
                try await model.signInWithClaude()
                onDone()
            } catch {
                isWorking = false
                withAnimation { mode = .choosing }
                failure = error.localizedDescription
            }
        }
    }

    private func submitApiKey() {
        guard !apiKey.isEmpty else { return }
        failure = nil
        isWorking = true
        Task {
            do {
                try await model.setApiKey(apiKey)
                onDone()
            } catch {
                isWorking = false
                failure = error.localizedDescription
            }
        }
    }
}

// MARK: - Finishing

struct FinishingStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OnboardingScaffold(
            icon: "checkmark.circle.fill",
            title: "You're set",
            subtitle: summary
        ) {
            EmptyView()
        } actions: {
            Button {
                model.completeOnboarding()
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
        if let email = auth.subscription.email {
            return "Connected as \(email) on \(auth.subscription.planLabel)."
        }
        return "Connected to Claude."
    }
}
