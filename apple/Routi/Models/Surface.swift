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

/// The machine every container screen lives on, as a whole — for setup and Settings.
///
/// Three questions with three different fixes: is Docker installed, is it running, is
/// the desktop image built. Plus which bots have a screen up right now.
struct DesktopHostStatus: Codable, Hashable {
    enum Docker: String, Codable { case missing, stopped, running }
    enum Image: String, Codable { case missing, building, ready, unknown }
    enum Machine: String, Codable { case stopped, running }
    struct Screen: Codable, Hashable {
        var botId: String
        var state: String
    }
    /// Where the image build is, while one runs.
    struct Build: Codable, Hashable {
        var step: Int?
        var of: Int?
        /// The Dockerfile instruction being run, as written.
        var detail: String
        /// The newest line it printed.
        var line: String
        var elapsedMs: Int
    }

    var docker: Docker
    var dockerVersion: String?
    var image: Image
    var machine: Machine
    var screens: [Screen]
    var build: Build?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docker = (try? c.decode(Docker.self, forKey: .docker)) ?? .missing
        dockerVersion = try c.decodeIfPresent(String.self, forKey: .dockerVersion)
        image = (try? c.decode(Image.self, forKey: .image)) ?? .unknown
        machine = (try? c.decode(Machine.self, forKey: .machine)) ?? .stopped
        screens = (try? c.decode([Screen].self, forKey: .screens)) ?? []
        build = try? c.decodeIfPresent(Build.self, forKey: .build)
    }

    private enum CodingKeys: String, CodingKey { case docker, dockerVersion, image, machine, screens, build }

    /// Ready means a bot asking for a screen gets one without anything else happening.
    var isReady: Bool { docker == .running && image == .ready && machine == .running }
}
