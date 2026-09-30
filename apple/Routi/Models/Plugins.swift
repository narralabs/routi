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

    // Google's scope descriptions: developers.google.com/identity/protocols/oauth2/scopes
    private static let scopeDescriptions = [
        "gmail.readonly": "View your email messages and settings",
        "gmail.modify": "Read, compose, and send emails from your Gmail account",
        "gmail.compose": "Manage drafts and send emails",
        "gmail.send": "Send email on your behalf",
        "https://mail.google.com/": "Read, compose, send, and permanently delete all your email from Gmail",
        "calendar": "See, edit, share, and permanently delete all the calendars you can access using Google Calendar",
        "calendar.readonly": "See and download any calendar you can access using your Calendar",
        "calendar.events": "View and edit events on all your calendars",
        "calendar.events.readonly": "View events on all your calendars",
        "calendar.calendarlist.readonly": "See the list of Google calendars you're subscribed to",
        "calendar.events.freebusy": "See the availability on Google calendars you have access to",
        "calendar.freebusy": "View your availability in your calendars",
        "drive": "See, edit, create, and delete all of your Google Drive files",
        "drive.readonly": "See and download all your Google Drive files",
        "drive.file": "See, edit, create, and delete only the specific Google Drive files you use with this app",
    ]

    func permissions(_ scopes: [String]) -> [String] {
        let prefix = id == "google_calendar" ? "calendar" : id == "google_drive" ? "drive" : "gmail"
        return scopes.compactMap { scope in
            let key = scope.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "")
            guard key.hasPrefix(prefix) || (id == "gmail" && key == "https://mail.google.com/") else { return nil }
            return Self.scopeDescriptions[key] ?? key
        }
    }

    func permissionChoice(readOnly: Bool) -> String {
        let scope = switch id {
        case "gmail": readOnly ? "gmail.readonly" : "gmail.modify"
        case "google_calendar": readOnly ? "calendar.events.readonly" : "calendar.events"
        default: "drive.file"
        }
        return Self.scopeDescriptions[scope]!
    }

    var sharedPermissions: [String] {
        let scopes = switch id {
        case "google_calendar": ["calendar.calendarlist.readonly", "calendar.events.freebusy"]
        case "google_drive": ["drive.readonly"]
        default: [String]()
        }
        return scopes.compactMap { Self.scopeDescriptions[$0] }
    }

    static let all: [PluginInfo] = [
        .init(id: "robinhood", name: "Robinhood", summary: "Account information, market data, and trading", asset: "PluginRobinhood", accessDescription: "Includes account information and trading tools. Connecting does not place a trade."),
        .init(id: "gmail", name: "Gmail", summary: "Search, read, draft, and send email", asset: "PluginGmail", accessDescription: "Allows reading email, composing and sending drafts, changing labels, and moving messages to trash when authorized."),
        .init(id: "google_calendar", name: "Google Calendar", summary: "Manage events and find available times", asset: "PluginGoogleCalendar", accessDescription: "Allows reading calendars and availability, creating and editing events, cancelling events, and responding to invitations when authorized."),
        .init(id: "google_drive", name: "Google Drive", summary: "Find and read files, and create new ones", asset: "PluginGoogleDrive", accessDescription: "Allows searching, reading, downloading, copying, and creating Drive files when authorized."),
    ]
    static func find(_ id: String) -> PluginInfo? { all.first { $0.id == id } }
}
