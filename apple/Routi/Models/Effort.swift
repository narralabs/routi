import Foundation

/// How much thinking a bot spends per turn.
///
/// Chosen at creation alongside provider and model, and fixed the same way. When a bot
/// has none, Anthropic's own default applies — which is `high` — so the UI shows that
/// rather than leaving the slot blank or inventing a different value.
enum Effort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max
    var id: String { rawValue }

    /// What the API does when `effort` is omitted.
    static let implicitDefault = Effort.high

    var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        }
    }

    var detail: String {
        switch self {
        case .low: return "Fastest and cheapest. Good for routine chat."
        case .medium: return "A step down in spend where quality holds."
        case .high: return "The default. Balances quality and cost."
        case .xhigh: return "Best for hard reasoning and long tasks."
        case .max: return "When correctness matters more than cost."
        }
    }

    static func parse(_ raw: String?) -> Effort {
        Effort(rawValue: raw ?? "") ?? .implicitDefault
    }
}
