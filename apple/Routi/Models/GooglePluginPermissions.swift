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

    func hasWriteAccess(_ scopes: [String]) -> Bool {
        let writeScopes: [String]
        switch id {
        case "gmail": writeScopes = ["gmail.modify", "gmail.compose", "gmail.send"]
        case "google_calendar": writeScopes = ["calendar.events", "calendar"]
        case "google_drive": writeScopes = ["drive.file", "drive"]
        default: return false
        }
        return scopes.contains { scope in
            writeScopes.contains { scope == "https://www.googleapis.com/auth/" + $0 }
                || (id == "gmail" && scope == "https://mail.google.com/")
        }
    }

    func permissionChoice(readOnly: Bool) -> String {
        switch id {
        case "gmail": readOnly ? "Read email" : "Read, send, and manage email"
        case "google_calendar": readOnly ? "Read events" : "Read and manage events"
        default: "Manage files used with Routi"
        }
    }

    var sharedPermissions: [String] {
        switch id {
        case "google_calendar": ["View calendars", "Check availability"]
        case "google_drive": ["Read Drive files"]
        default: []
        }
    }
}
