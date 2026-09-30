import Foundation

struct PluginStatus: Decodable {
    let grantedScopes: [String]?
    let supportsReadOnly: Bool?
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

    func permissions(_ scopes: [String]) -> [String] {
        let granted = Set(scopes)
        func has(_ names: String...) -> Bool {
            names.contains { granted.contains("https://www.googleapis.com/auth/" + $0) }
        }
        switch id {
        case "gmail":
            if granted.contains("https://mail.google.com/") { return ["Read, send, and permanently delete email"] }
            if has("gmail.modify") { return ["Read and send email; manage drafts, labels, and trash"] }
            var result: [String] = []
            if has("gmail.readonly") { result.append("Read email") }
            if has("gmail.compose") { result.append("Manage drafts and send email") }
            else if has("gmail.send") { result.append("Send email") }
            return result
        case "google_calendar":
            if has("calendar") { return ["Read and manage calendars and events"] }
            var result: [String] = []
            if has("calendar.events") { result.append("Read, create, and change events") }
            else if has("calendar.events.readonly", "calendar.readonly") { result.append("Read events") }
            if has("calendar.calendarlist.readonly", "calendar.readonly") { result.append("List calendars") }
            if has("calendar.events.freebusy", "calendar.freebusy", "calendar.readonly") { result.append("Check availability") }
            return result
        case "google_drive":
            if has("drive") { return ["Read and manage all Drive files"] }
            var result: [String] = []
            if has("drive.readonly") { result.append("Read and download Drive files") }
            if has("drive.file") { result.append("Create and manage files used with Routi") }
            return result
        default: return []
        }
    }

    static let all: [PluginInfo] = [
        .init(id: "robinhood", name: "Robinhood", summary: "Account information, market data, and trading", asset: "PluginRobinhood", accessDescription: "Includes account information and trading tools. Connecting does not place a trade."),
        .init(id: "gmail", name: "Gmail", summary: "Search, read, draft, and send email", asset: "PluginGmail", accessDescription: "Allows reading email, composing and sending drafts, changing labels, and moving messages to trash when authorized."),
        .init(id: "google_calendar", name: "Google Calendar", summary: "Manage events and find available times", asset: "PluginGoogleCalendar", accessDescription: "Allows reading calendars and availability, creating and editing events, cancelling events, and responding to invitations when authorized."),
        .init(id: "google_drive", name: "Google Drive", summary: "Find and read files, and create new ones", asset: "PluginGoogleDrive", accessDescription: "Allows searching, reading, downloading, copying, and creating Drive files when authorized."),
    ]
    static func find(_ id: String) -> PluginInfo? { all.first { $0.id == id } }
}
