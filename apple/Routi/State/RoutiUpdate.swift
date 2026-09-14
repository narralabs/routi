#if os(macOS)
import Foundation
import Observation

struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Keep the app open until the connected core has successfully updated.
@MainActor @Observable
final class RoutiUpdate {
    private(set) var running = false
    private(set) var message: String?

    func run(prepareApp: () async throws -> String?, updateCore: (String?) async throws -> Void,
             installApp: () async throws -> Void) async {
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            message = "Preparing the app update…"
            let version = try await prepareApp()
            message = "Updating Routi Core…"
            try await updateCore(version)
            if version != nil {
                message = "Restarting Routi…"
                try await installApp()
            } else {
                message = "Routi is up to date."
            }
        } catch { message = error.localizedDescription }
    }
}
#endif
