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
        var preview: String? = nil
        var editableFields: [String]? = nil

        var title: String {
            switch tool {
            case "create_draft": "Create email draft"
            case "update_draft": "Update email draft"
            case "gmail_send_email", "gmail_send_draft", "send_message": "Send email"
            case "reply": "Reply to email"
            case "forward": "Forward email"
            default: Self.label(tool)
            }
        }

        struct Detail {
            let path: [String]
            let label: String
            let value: String
            let editable: Bool
        }

        func editedArguments(_ edits: [[String]: String]) throws -> [String: Any] {
            func apply(_ value: Any, path: [String]) -> Any {
                if value is String, let edit = edits[path] { return edit }
                if let object = value as? [String: Any] {
                    return object.reduce(into: [String: Any]()) { result, entry in
                        result[entry.key] = apply(entry.value, path: path + [entry.key])
                    }
                }
                if let array = value as? [Any] {
                    return array.enumerated().map { apply($0.element, path: path + [String($0.offset)]) }
                }
                return value
            }
            let object = try JSONSerialization.jsonObject(with: Data((preview ?? arguments).utf8))
            guard let edited = apply(object, path: []) as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
            return edited
        }

        var details: [Detail]? {
            guard let object = try? JSONSerialization.jsonObject(with: Data((preview ?? arguments).utf8)) as? [String: Any] else { return nil }
            return Self.rows(object, path: [])
        }

        private static func label(_ key: String) -> String {
            if key == "body" { return "Message" }
            if key == "cc" || key == "bcc" { return key.uppercased() }
            let text = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
                .replacingOccurrences(of: "_", with: " ")
            return text.prefix(1).uppercased() + text.dropFirst()
        }

        private static func rows(_ value: Any, path: [String]) -> [Detail] {
            if let object = value as? [String: Any], !object.isEmpty {
                let order = ["to", "cc", "bcc", "subject", "body"]
                return object.keys.sorted {
                    let a = order.firstIndex(of: $0) ?? order.count
                    let b = order.firstIndex(of: $1) ?? order.count
                    return a == b ? $0 < $1 : a < b
                }.flatMap { rows(object[$0]!, path: path + [$0]) }
            }
            if let array = value as? [Any], !array.isEmpty {
                return array.enumerated().flatMap { rows($0.element, path: path + [String($0.offset)]) }
            }
            if path.isEmpty { return [] }
            let title = path.map { Int($0).map { String($0 + 1) } ?? label($0) }.joined(separator: " · ")
            let text: String
            if value is NSNull || value is [Any] || value is [String: Any] { text = "None" }
            else if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { text = number.boolValue ? "Yes" : "No" }
            else { text = String(describing: value) }
            return [Detail(path: path, label: title, value: text, editable: value is String)]
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
