import Foundation

/// Swift mirror of the daemon's `AuthStatus`.
struct AuthStatus: Codable, Hashable {
    var configured: Bool
    var mode: String?
    var subscription: Subscription
    var apiKey: ApiKey
    /// Providers configured after onboarding, keyed by id. Anthropic keeps the flat
    /// fields above because setup is built on it.
    var providers: [String: ProviderAuth] = [:]

    struct ProviderAuth: Codable, Hashable {
        var configured: Bool
        var mode: String?
        /// Which harness runs the turn, where the provider offers a choice.
        var harness: String?
        var cli: Cli
        var apiKey: ApiKey

        struct Cli: Codable, Hashable {
            var installed: Bool
            var version: String?
            var loggedIn: Bool
            /// How the CLI is signed in, in the vendor's own words.
            var account: String?
        }
    }

    func provider(_ id: String) -> ProviderAuth? { providers[id] }

    struct Subscription: Codable, Hashable {
        var cliInstalled: Bool
        var cliVersion: String?
        var loggedIn: Bool
        var email: String?
        var organization: String?
        var subscriptionType: String?

        /// "max" / "pro" from the CLI, presented the way Anthropic writes it.
        var planLabel: String {
            switch subscriptionType?.lowercased() {
            case "max": return "Claude Max"
            case "pro": return "Claude Pro"
            case .some(let other) where !other.isEmpty: return "Claude \(other.capitalized)"
            default: return "Claude subscription"
            }
        }
    }

    struct ApiKey: Codable, Hashable {
        var present: Bool
    }

    static let unknown = AuthStatus(
        configured: false,
        mode: nil,
        subscription: .init(cliInstalled: false, cliVersion: nil, loggedIn: false),
        apiKey: .init(present: false)
    )
}
