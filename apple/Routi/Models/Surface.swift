import Foundation

/// The shared Linux desktop, as the client sees it.
struct SurfaceStatus: Codable, Hashable {
    enum State: String, Codable {
        case stopped, starting, running, unavailable
    }

    var state: State
    var width: Int
    var height: Int
    /// Why it can't run, when it can't — Docker stopped, image missing, and so on.
    var detail: String?
    /// Conversation currently holding the pointer.
    var heldBy: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decode(State.self, forKey: .state)) ?? .stopped
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1280
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 800
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        heldBy = try c.decodeIfPresent(String.self, forKey: .heldBy)
    }

    private enum CodingKeys: String, CodingKey { case state, width, height, detail, heldBy }

    init(state: State, width: Int = 1280, height: Int = 800) {
        self.state = state
        self.width = width
        self.height = height
    }

    static let unknown = SurfaceStatus(state: .stopped)

    var aspectRatio: Double { Double(width) / Double(height) }
}
