import Foundation

extension PluginInfo {
    func permissions(_ scopes: [String]) -> [String] {
        let granted = Set(scopes.map { $0.replacingOccurrences(of: "https://www.googleapis.com/auth/", with: "") })
        let capabilities: [(String, Set<String>)]
        switch id {
        case "gmail":
            capabilities = [
                ("Read email", ["gmail.readonly", "gmail.modify", "https://mail.google.com/"]),
                ("Send email", ["gmail.send", "gmail.compose", "gmail.modify", "https://mail.google.com/"]),
                ("Manage drafts", ["gmail.compose", "gmail.modify", "https://mail.google.com/"]),
                ("Organize email", ["gmail.modify", "https://mail.google.com/"]),
            ]
        case "google_calendar":
            capabilities = [
                ("Read events", ["calendar.events.readonly", "calendar.events", "calendar.readonly", "calendar"]),
                ("Manage events", ["calendar.events", "calendar"]),
                ("View calendars", ["calendar.calendarlist.readonly", "calendar.readonly", "calendar"]),
                ("Check availability", ["calendar.events.freebusy", "calendar.freebusy", "calendar.readonly", "calendar"]),
            ]
        case "google_drive":
            capabilities = [
                ("Read Drive files", ["drive.readonly", "drive"]),
                ("Manage files used with Routi", ["drive.file"]),
                ("Manage all Drive files", ["drive"]),
            ]
        default: return []
        }
        return capabilities.compactMap { label, scopes in granted.isDisjoint(with: scopes) ? nil : label }
    }

}
