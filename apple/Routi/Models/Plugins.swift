import Foundation

struct PluginStatus: Decodable {
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
        .init(id: "gmail", name: "Gmail", summary: "Search and read email, and create drafts", asset: "PluginGmail", accessDescription: "Allows reading email and composing drafts using Google’s MCP tools."),
        .init(id: "google_drive", name: "Google Drive", summary: "Search, read, and work with files", asset: "PluginGoogleDrive", accessDescription: "Allows reading Drive files and working with files authorized for Routi."),
        .init(id: "google_calendar", name: "Google Calendar", summary: "Read calendars, events, and availability", asset: "PluginGoogleCalendar", accessDescription: "Allows reading calendar events and checking availability."),
    ]
    static func find(_ id: String) -> PluginInfo? { all.first { $0.id == id } }
}
