import Foundation

/// Swift mirror of `protocol/src/blocks.ts`.
///
/// A message is an ordered array of blocks, never a string — one assistant turn
/// interleaves prose, screenshots, and tool cards, and the UI renders them as
/// siblings in the order the daemon streamed them.
enum Block: Identifiable, Hashable {
    case text(String)
    case thinking(String)
    case image(ImagePayload)
    case toolUse(ToolUse)
    case toolResult(ToolResult)
    case surfaceEvent(SurfaceEvent)
    /// A newer daemon may send a block kind this build predates; render nothing
    /// rather than failing the whole message.
    case unknown

    var id: String {
        switch self {
        case .text(let s): return "text:\(s.hashValue)"
        case .thinking(let s): return "thinking:\(s.hashValue)"
        case .image(let p): return "image:\(p.assetID ?? String(p.dataURL?.hashValue ?? 0))"
        case .toolUse(let t): return "tool:\(t.id)"
        case .toolResult(let r): return "result:\(r.toolUseID)"
        case .surfaceEvent(let e): return "surface:\(e.sessionID)-\(e.kind)"
        case .unknown: return "unknown"
        }
    }

    struct ImagePayload: Hashable {
        var mediaType: String
        var dataURL: String?
        var assetID: String?
    }

    struct ToolUse: Hashable {
        var id: String
        var name: String
        var title: String?
        var status: Status

        enum Status: String, Hashable {
            case running, done, error

            init(raw: String?) {
                self = Status(rawValue: raw ?? "") ?? .running
            }
        }
    }

    struct ToolResult: Hashable {
        var toolUseID: String
        var isError: Bool
    }

    struct SurfaceEvent: Hashable {
        var sessionID: String
        var kind: String
        var assetID: String?
    }
}

// MARK: - Codable

extension Block: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, mediaType, dataUrl, assetId
        case id, name, title, status, input
        case toolUseId, isError, content
        case sessionId, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""

        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "thinking":
            self = .thinking(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image":
            self = .image(ImagePayload(
                mediaType: try c.decodeIfPresent(String.self, forKey: .mediaType) ?? "image/png",
                dataURL: try c.decodeIfPresent(String.self, forKey: .dataUrl),
                assetID: try c.decodeIfPresent(String.self, forKey: .assetId)
            ))
        case "tool_use":
            self = .toolUse(ToolUse(
                id: try c.decodeIfPresent(String.self, forKey: .id) ?? "",
                name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                title: try c.decodeIfPresent(String.self, forKey: .title),
                status: ToolUse.Status(raw: try c.decodeIfPresent(String.self, forKey: .status))
            ))
        case "tool_result":
            self = .toolResult(ToolResult(
                toolUseID: try c.decodeIfPresent(String.self, forKey: .toolUseId) ?? "",
                isError: try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            ))
        case "surface_event":
            self = .surfaceEvent(SurfaceEvent(
                sessionID: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? "",
                kind: try c.decodeIfPresent(String.self, forKey: .kind) ?? "attached",
                assetID: try c.decodeIfPresent(String.self, forKey: .assetId)
            ))
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .thinking(let s):
            try c.encode("thinking", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let p):
            try c.encode("image", forKey: .type)
            try c.encode(p.mediaType, forKey: .mediaType)
            try c.encodeIfPresent(p.dataURL, forKey: .dataUrl)
            try c.encodeIfPresent(p.assetID, forKey: .assetId)
        case .toolUse(let t):
            try c.encode("tool_use", forKey: .type)
            try c.encode(t.id, forKey: .id)
            try c.encode(t.name, forKey: .name)
            try c.encodeIfPresent(t.title, forKey: .title)
            try c.encode(t.status.rawValue, forKey: .status)
        case .toolResult(let r):
            try c.encode("tool_result", forKey: .type)
            try c.encode(r.toolUseID, forKey: .toolUseId)
            try c.encode(r.isError, forKey: .isError)
        case .surfaceEvent(let e):
            try c.encode("surface_event", forKey: .type)
            try c.encode(e.sessionID, forKey: .sessionId)
            try c.encode(e.kind, forKey: .kind)
            try c.encodeIfPresent(e.assetID, forKey: .assetId)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }
}
