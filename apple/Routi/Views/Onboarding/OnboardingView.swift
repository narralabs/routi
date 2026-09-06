import SwiftUI

/// First-run setup, shown before any chat UI exists.
///
/// One flow that branches on whether this device can host the daemon, rather than two
/// separate onboardings. A Mac can run routid; an iPhone can only connect to one, so
/// that branch is hidden there instead of being explained and then refused.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    enum Step {
        case welcome
        case connection   // Mac only, no core found: install here, or connect to another Mac
        case install      // the install command, watching the port for the core to appear
        case endpoint     // point at a remote routid
        case credential   // choose and complete a first connection
        case finishing
    }

    @State private var step: Step = .welcome
    @State private var direction: Edge = .trailing

    var body: some View {
        ZStack {
            BackdropGradient()

            Group {
                switch step {
                case .welcome:
                    WelcomeStep(onContinue: { advance(to: afterWelcome) })
                case .connection:
                    ConnectionStep(
                        onInstallHere: { advance(to: .install) },
                        onConnectRemote: { advance(to: .endpoint) }
                    )
                case .install:
                    InstallStep(
                        onBack: { retreat(to: .connection) },
                        onConnected: { advance(to: afterConnecting) }
                    )
                case .endpoint:
                    EndpointStep(
                        onBack: { retreat(to: canHostLocally ? .connection : .welcome) },
                        onConnected: { advance(to: afterConnecting) }
                    )
                case .credential:
                    CredentialStep(
                        onBack: { retreat(to: canHostLocally ? .welcome : .endpoint) },
                        onDone: { advance(to: .finishing) }
                    )
                case .finishing:
                    FinishingStep()
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: direction).combined(with: .opacity),
                removal: .move(edge: direction == .trailing ? .leading : .trailing).combined(with: .opacity)
            ))
        }
        .frame(minWidth: 560, minHeight: 560)
        .animation(.snappy(duration: 0.28), value: step)
    }

    /// Where "Get Started" leads depends on what the socket has already found.
    ///
    /// The app starts connecting the moment it launches, and a port on this Mac
    /// answers or refuses in milliseconds — so by the time anyone reads the welcome
    /// screen, the answer is in. A core that is up goes straight to the credential
    /// (or, if it already has one, to the finish); no core on a Mac asks where it
    /// should run; a phone can only ever be pointed at one.
    private var afterWelcome: Step {
        if model.connection == .connected { return afterConnecting }
        return canHostLocally ? .connection : .endpoint
    }

    /// A core that already holds a credential — an app reinstalled on a Mac that was
    /// set up before — has nothing to ask about AI.
    private var afterConnecting: Step {
        model.auth.configured ? .finishing : .credential
    }

    /// Only a Mac can run the daemon; a phone always connects to one.
    private var canHostLocally: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    private func advance(to next: Step) {
        direction = .trailing
        step = next
    }

    private func retreat(to previous: Step) {
        direction = .leading
        step = previous
    }
}

/// A soft tinted wash so the setup window doesn't read as an empty document window.
private struct BackdropGradient: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.10), Color.accentColor.opacity(0.02), .clear],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Shared chrome

struct OnboardingScaffold<Content: View, Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.accentColor.gradient)

                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(.horizontal, 40)

            content
                .padding(.horizontal, 40)
                .padding(.top, 28)

            Spacer(minLength: 24)

            actions
                .padding(.horizontal, 40)
                .padding(.bottom, 32)
        }
    }
}

/// Large tappable option card — the primary control of the whole flow.
struct OptionCard: View {
    let icon: String
    let title: String
    let detail: String
    var badge: String?
    var isRecommended = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title).font(.system(size: 15, weight: .semibold))
                        if isRecommended {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.16), in: .capsule)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let badge {
                        Label(badge, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.green)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHovering ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
