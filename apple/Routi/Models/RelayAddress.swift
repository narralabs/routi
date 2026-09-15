import Foundation

/// A relay origin, stored locally until the Mac connector is configured.
enum RelayAddress {
    static let defaultValue = "wss://connect.routibot.com"

    static func normalize(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }),
              var url = URLComponents(string: value),
              url.scheme?.lowercased() == "wss",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.port.map({ (1...65535).contains($0) }) ?? true,
              url.url != nil else { return nil }
        url.scheme = "wss"
        url.host = host.lowercased()
        url.path = ""
        return url.string
    }
}
