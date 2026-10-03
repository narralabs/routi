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
        case "google_docs":
            capabilities = [
                ("Read documents", ["documents.readonly", "documents", "drive.readonly", "drive"]),
                ("Edit documents", ["documents", "drive"]),
            ]
        case "google_sheets":
            capabilities = [
                ("Read spreadsheets", ["spreadsheets.readonly", "spreadsheets", "drive.readonly", "drive"]),
                ("Edit spreadsheets", ["spreadsheets", "drive"]),
            ]
        case "google_slides":
            capabilities = [
                ("Read presentations", ["presentations.readonly", "presentations", "drive.readonly", "drive"]),
                ("Edit presentations", ["presentations", "drive"]),
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

    var writePermission: String {
        switch id {
        case "gmail": "Send email and manage drafts and messages"
        case "google_calendar": "Create, edit, and delete events"
        case "google_docs": "Edit document text and formatting"
        case "google_sheets": "Edit spreadsheet values, formulas, and formatting"
        case "google_slides": "Edit slides, text, and layouts"
        default: "Manage files used with Routi"
        }
    }

    var basePermissions: [String] {
        switch id {
        case "gmail": ["Read email"]
        case "google_docs": ["Read documents"]
        case "google_sheets": ["Read spreadsheets"]
        case "google_slides": ["Read presentations"]
        case "google_calendar": ["View calendars", "Check availability", "Read events"]
        case "google_drive": ["Read Drive files"]
        default: []
        }
    }
}
