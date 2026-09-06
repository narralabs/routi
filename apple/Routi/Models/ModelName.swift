import Foundation

/// Turns an Anthropic model id into something readable.
///
/// Deliberately a transformation rather than a lookup table. Model ids follow a stable
/// shape — `claude-<family>-<version parts>[-<snapshot date>][<context suffix>]` — so
/// deriving the name means a model released tomorrow displays correctly without an app
/// update. A hardcoded map would show a raw id, or nothing, for anything new.
///
///     claude-opus-5              -> Opus 5
///     claude-opus-5[1m]          -> Opus 5 (1M)
///     claude-fable-5-1           -> Fable 5.1
///     claude-haiku-4-5-20251001  -> Haiku 4.5
enum ModelName {
    static func pretty(_ rawID: String) -> String {
        var id = rawID

        // Context-window suffix, e.g. "[1m]".
        var suffix = ""
        if let range = id.range(of: #"\[[^\]]+\]$"#, options: .regularExpression) {
            suffix = id[range].trimmingCharacters(in: CharacterSet(charactersIn: "[]")).uppercased()
            id.removeSubrange(range)
        }

        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }

        var parts = id.split(separator: "-").map(String.init)
        // Trailing snapshot date carries no meaning for a person reading a chat window.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard let family = parts.first else { return rawID }

        let version = parts.dropFirst().joined(separator: ".")
        var name = family.prefix(1).uppercased() + family.dropFirst()
        if !version.isEmpty { name += " \(version)" }
        if !suffix.isEmpty { name += " (\(suffix))" }
        return name
    }
}
