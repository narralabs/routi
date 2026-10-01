import Foundation

struct PluginPermission: Decodable, Identifiable {
    let id: String
    let label: String
    let rule: String
    let available: Bool
}

struct PluginStatus: Decodable {
    let permissions: [PluginPermission]?
    let grantedScopes: [String]?
    let supportsReadOnly: Bool?
    let accountEmail: String?
    let connected: Bool
    let connecting: Bool
    let error: String?
    let botIds: [String]
}

struct PluginAccessRequest: Decodable, Identifiable {
    struct Action: Decodable {
        let tool: String
        let arguments: String

        var title: String {
            switch tool {
            case "create_draft": "Create email draft"
            case "update_draft": "Update email draft"
            case "gmail_send_draft", "send_message": "Send email"
            case "reply": "Reply to email"
            case "forward": "Forward email"
            default: Self.label(tool)
            }
        }

        var details: [(label: String, value: String)]? {
            guard let object = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
            return Self.rows(object, path: "")
        }

        private static func label(_ key: String) -> String {
            if key == "body" { return "Message" }
            if key == "cc" || key == "bcc" { return key.uppercased() }
            let text = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }

        private static func rows(_ value: Any, path: String) -> [(label: String, value: String)] {
            if let object = value as? [String: Any] {
                if object.isEmpty { return path.isEmpty ? [] : [(path, "None")] }
                let order = ["to", "cc", "bcc", "subject", "body"]
                return object.keys.sorted {
                    let a = order.firstIndex(of: $0) ?? order.count
                    let b = order.firstIndex(of: $1) ?? order.count
                    return a == b ? $0 < $1 : a < b
                }.flatMap { key in rows(object[key]!, path: path.isEmpty ? label(key) : "\(path) · \(label(key))") }
            }
            if let strings = value as? [String], !strings.isEmpty { return [(path, strings.joined(separator: ", "))] }
            if let array = value as? [Any] {
                if array.isEmpty { return [(path, "None")] }
                return array.enumerated().flatMap { rows($0.element, path: "\(path) · \($0.offset + 1)") }
            }
            if value is NSNull { return [(path, "None")] }
            if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                return [(path, number.boolValue ? "Yes" : "No")]
            }
            return [(path, String(describing: value))]
        }
    }
    let action: Action?
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
        .init(id: "google_calendar", name: "Google Calendar", summary: "Manage events and find available times", asset: "PluginGoogleCalendar", accessDescription: "Allows reading calendars and availability, creating and editing events, cancelling events, and responding to invitations when authorized."),
        .init(id: "google_drive", name: "Google Drive", summary: "Find and read files, and create new ones", asset: "PluginGoogleDrive", accessDescription: "Allows searching, reading, downloading, copying, and creating Drive files when authorized."),
        .init(id: "google_docs", name: "Google Docs", summary: "Read and edit documents", asset: "PluginGoogleDocs", accessDescription: "Allows reading document contents and editing text, structure, and formatting when authorized."),
    ]
    static func find(_ id: String) -> PluginInfo? { all.first { $0.id == id } }
}
