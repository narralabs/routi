import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tells the person when a bot has something for them and they are not looking.
///
/// Two moments earn a notification: a bot finished a reply, and a bot stopped to ask
/// for the screen. Neither fires for the conversation the person is watching in a
/// frontmost window, since a banner over the very message it announces is noise. A
/// click on one opens that bot. Everything is local; nothing leaves the Mac.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Whether the person is looking at this conversation right now, answered by the app model.
    var isWatching: (String) -> Bool = { _ in false }
    /// Open this bot: a notification was clicked.
    var onOpen: (String) -> Void = { _ in }

    private var asked = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asked once, the first time the app is connected and set up, not during setup.
    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A bot finished a reply. `preview` is its first line, when the core sent one.
    func botFinished(botId: String, botName: String, conversationId: String, preview: String?, routineName: String?) {
        guard UserDefaults.standard.object(forKey: "notifyOnFinish") as? Bool ?? true else { return }
        guard !isWatching(conversationId) else { return }
        let content = UNMutableNotificationContent()
        content.title = routineName.map { "\(botName) · \($0)" } ?? botName
        content.body = preview ?? "Finished."
        content.sound = .default
        content.threadIdentifier = conversationId
        content.userInfo = ["botId": botId]
        post(content, id: "finished-\(conversationId)")
    }

    /// A bot stopped and is waiting for the person to take the screen.
    func botWaiting(botId: String, botName: String, conversationId: String, reason: String) {
        guard UserDefaults.standard.object(forKey: "notifyOnHandover") as? Bool ?? true else { return }
        guard !isWatching(conversationId) else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(botName) needs you"
        content.body = reason
        content.sound = .default
        content.threadIdentifier = conversationId
        content.userInfo = ["botId": botId]
        content.interruptionLevel = .timeSensitive
        post(content, id: "waiting-\(conversationId)")
    }

    /// One per conversation at a time: a second reply replaces the banner rather than stacking.
    private func post(_ content: UNMutableNotificationContent, id: String) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Shown even while the app is frontmost: the watching check above already skipped
    /// the one case where a banner would be redundant.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let botId = response.notification.request.content.userInfo["botId"] as? String
        Task { @MainActor in
            if let botId {
                #if os(macOS)
                NSApp.activate(ignoringOtherApps: true)
                #endif
                onOpen(botId)
            }
            completionHandler()
        }
    }
}
