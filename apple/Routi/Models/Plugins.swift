import Foundation

struct RobinhoodStatus: Decodable {
    let connected: Bool
    let connecting: Bool
    let error: String?
    let botIds: [String]
}
