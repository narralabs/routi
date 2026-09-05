import Foundation

/// Swift mirror of the daemon's `AuthStatus`.
struct AuthStatus: Codable, Hashable {
    var configured: Bool
    var mode: String?
    var subscription: Subscription
    var apiKey: ApiKey

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
