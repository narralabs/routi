import Foundation

extension PluginInfo {
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
}
