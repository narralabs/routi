#if os(macOS)
import Foundation
import Observation
import Sparkle

/// Sparkle downloads and verifies the app; RoutiUpdate coordinates installation
/// with the core. Debug builds require -checkAppUpdate to enable Sparkle.
@Observable
final class AppUpdater: NSObject {
    enum Phase: Equatable {
        case idle
        case checking
        /// Fraction of the download, when the size is known.
        case downloading(Double?)
        /// Downloaded and verified; installing means a relaunch.
        case ready(String)
        case upToDate
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// The version the feed offers, once one is known.
    private(set) var latestVersion: String?
    /// Whether this build checks at all.
    let isEnabled: Bool

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var installReply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var expectedLength: UInt64 = 0
    @ObservationIgnored private var receivedLength: UInt64 = 0
    @ObservationIgnored private let feedOverride: String?

    override init() {
        let args = ProcessInfo.processInfo.arguments
        #if DEBUG
        isEnabled = args.contains("-checkAppUpdate")
        #else
        isEnabled = true
        #endif
        if let i = args.firstIndex(of: "-appcastURL"), i + 1 < args.count {
            feedOverride = args[i + 1]
        } else {
            feedOverride = nil
        }
        super.init()
        guard isEnabled else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = false
        updater.updateCheckInterval = 24 * 60 * 60
        do {
            try updater.start()
        } catch {
            phase = .failed(error.localizedDescription)
        }
        self.updater = updater
    }

    /// Whether a release is downloaded and waiting for the relaunch.
    var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    /// Asks now rather than waiting for the daily check.
    func check() {
        guard let updater, updater.canCheckForUpdates else { return }
        phase = .checking
        updater.checkForUpdates()
    }

    func prepareUpdate() async throws -> String? {
        guard isEnabled else { return nil }
        if case .ready(let version) = phase { return version }
        check()
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            switch phase {
            case .ready(let version): return version
            case .upToDate: return nil
            case .failed(let message): throw UpdateFailure(message: message)
            default: try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw UpdateFailure(message: "The app download timed out. Try Update Routi again.")
    }

    /// Installs the downloaded release and relaunches into it.
    func installAndRelaunch() throws {
        guard let reply = installReply else { throw UpdateFailure(message: "The app update is no longer ready. Try Update Routi again.") }
        installReply = nil
        reply(.install)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { feedOverride }
}

extension AppUpdater: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Checking is the point; nothing about the Mac is sent along.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        phase = .checking
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        latestVersion = appcastItem.displayVersionString
        switch state.stage {
        case .notDownloaded:
            // Download straight away; the person is asked only about the relaunch.
            phase = .downloading(nil)
            reply(.install)
        case .downloaded, .installing:
            phase = .ready(appcastItem.displayVersionString)
            installReply = reply
        @unknown default:
            phase = .ready(appcastItem.displayVersionString)
            installReply = reply
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .upToDate
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        phase = .failed(error.localizedDescription)
        installReply = nil
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedLength = 0
        receivedLength = 0
        phase = .downloading(nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedLength += length
        if expectedLength > 0 {
            phase = .downloading(min(1, Double(receivedLength) / Double(expectedLength)))
        }
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .downloading(1)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        phase = .ready(latestVersion ?? "")
        installReply = reply
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        if case .ready = phase { return }
        phase = .idle
    }
}
#endif
