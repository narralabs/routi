#if os(macOS)
import Foundation
import Observation
import Sparkle

/**
 The Mac app updating itself, the way Cursor does: a release is downloaded in the
 background and the app offers "Restart to Update"; nothing to download, nothing to
 drag. Sparkle does the work — the check against the appcast, the download, the
 signature check against `SUPublicEDKey`, the swap in place and the relaunch. This
 class is its user interface: instead of Sparkle's own windows, the state lands in
 Settings › Routi Core beside the core's update button.

 Debug builds do not check: a developer's build would offer to replace itself with
 the release. `-checkAppUpdate` turns it on for a debug build, and `-appcastURL <url>`
 points it at a feed of one's own, which is how the flow is tested end to end.
 */
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
    /// Sparkle's handler for a release it has downloaded and prepared in the
    /// background, which it would otherwise install silently on quit.
    @ObservationIgnored private var immediateInstall: (() -> Void)?
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
        updater.automaticallyDownloadsUpdates = true
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
        updater.checkForUpdates()
    }

    /// Installs the downloaded release and relaunches into it.
    func installAndRelaunch() {
        if let install = immediateInstall {
            install()
            return
        }
        guard let reply = installReply else { return }
        installReply = nil
        reply(.install)
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { feedOverride }

    /**
     A background download is done and prepared. Left to itself Sparkle would install
     it on the next quit and say nothing until a later check; taking the handler is
     what puts "Restart to Update" in front of the person now. Sparkle still installs
     on quit if the button is never pressed.
     */
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        latestVersion = item.displayVersionString
        immediateInstall = immediateInstallHandler
        phase = .ready(item.displayVersionString)
        return true
    }
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
