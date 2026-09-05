import Foundation

/// A bot waiting for you to do something on its screen.
///
/// The bot is paused mid-turn while this exists — it called a tool that does not return
/// until you answer — which is why it is shown as prominently as it is. An unnoticed
/// handover is a bot stuck until it times out.
struct Handover: Codable, Identifiable, Hashable {
    var id: String
    var botId: String
    var conversationId: String
    /// What you are being asked to do, in the bot's own words.
    var reason: String
    var askedAt: Double
}
