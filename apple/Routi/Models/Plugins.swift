import Foundation

struct PluginStatus: Decodable {
    let accountEmail: String?
    let connected: Bool
    let connecting: Bool
    let error: String?
    let botIds: [String]
}

struct PluginAccessRequest: Decodable, Identifiable {
    let id: String
    let pluginId: String?
    let botId: String
    let conversationId: String
    let profileId: String
    let connected: Bool
    let connecting: Bool
    let expiresAt: Double
}

struct PluginInfo: Identifiable {
    let id: String
    let name: String
    let summary: String
    let asset: String
    let accessDescription: String

    static let all: [PluginInfo] = [
        .init(id: "robinhood", name: "Robinhood", summary: "Account information, market data, and trading", asset: "PluginRobinhood", accessDescription: "Includes account information and trading tools. Connecting does not place a trade."),
        .init(id: "gmail", name: "Gmail", summary: "Search, read, draft, and send email", asset: "PluginGmail", accessDescription: "Allows reading email, composing and sending drafts, changing labels, and moving messages to trash when authorized."),
    ]
    static func find(_ id: String) -> PluginInfo? { all.first { $0.id == id } }
}
