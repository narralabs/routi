// Compile with -D DEBUG and link the Sparkle.framework from a Mac build.
import Foundation

@main struct AppUpdaterTests {
    @MainActor static func main() {
        let updater = AppUpdater() // Debug: no network checks or installation.
        precondition(!updater.isEnabled)
        let error = NSError(domain: "UpdateTest", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        updater.showUpdateNotFoundWithError(error, acknowledgement: {})
        updater.dismissUpdateInstallation()
        precondition(updater.phase == .upToDate, "Dismissal must preserve the completed check")

        updater.showUpdaterError(error, acknowledgement: {})
        updater.dismissUpdateInstallation()
        precondition(updater.phase == .failed("Download failed"), "Dismissal must preserve the error")

        var installed = false
        updater.showReady(toInstallAndRelaunch: { _ in installed = true })
        updater.dismissUpdateInstallation()
        do {
            try updater.installAndRelaunch()
            preconditionFailure("A dismissed installation must not remain usable")
        } catch {}
        precondition(!installed && !updater.isReady)
        print("3 Sparkle dismissal checks passed")
    }
}
