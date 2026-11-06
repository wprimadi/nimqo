import AppKit
import os
import UserNotifications

/// Notifications for new messages, one per chat (a newer one replaces it),
/// plus the unread count on the Dock icon. Driven by unread counts going
/// up, so history imports (stored as read) never notify.
///
/// Only the chat name is shown, never the message: macOS keeps delivered
/// notifications in its own unencrypted database.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Unread per chat as last seen; nil until the first list after
    /// connecting, so what was already unread then does not notify.
    private var unread: [String: Int]?
    private var authorized = false
    private let log = Logger(subsystem: "app.nimqo", category: "notifier")
    /// Clicking a notification opens its chat.
    var open: ((String) -> Void)?

    /// A new session (or none, after logging out): nothing of the old one
    /// stays in Notification Center, and counting starts again.
    func reset() {
        unread = nil
        NSApp?.dockTile.badgeLabel = nil
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    func update(_ chats: [ChatSummary], viewing: String?) {
        let total = chats.reduce(0) { $0 + $1.unread }
        NSApp?.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
        let center = UNUserNotificationCenter.current()
        let read = chats.filter { $0.unread == 0 }.map(\.id)
        if !read.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: read)
        }
        defer { unread = Dictionary(chats.map { ($0.id, $0.unread) }, uniquingKeysWith: max) }
        guard let unread else { return }
        let reading = NSApp?.isActive == true ? viewing : nil
        let rose = chats.filter { $0.unread > (unread[$0.id] ?? 0) }
        let fresh = rose.filter { $0.id != reading }
        // Counts only. ponytail: remove once media notifications are settled.
        if !rose.isEmpty || total > 0 {
            log.info("unread \(total) in \(chats.count) chats; rose in \(rose.count), notifying \(fresh.count)")
        }
        guard !fresh.isEmpty else { return }
        authorize()
        for chat in fresh {
            let content = UNMutableNotificationContent()
            content.title = chat.title
            content.body = chat.unread == 1 ? "New message" : "\(chat.unread) new messages"
            content.sound = .default
            content.threadIdentifier = chat.id
            center.add(UNNotificationRequest(identifier: chat.id, content: content, trigger: nil))
        }
    }

    /// Asked the first time there is something to show.
    private func authorize() {
        guard !authorized else { return }
        authorized = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Posted only for chats not on screen, so show it in the app too.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let chat = response.notification.request.identifier
        await MainActor.run {
            // Only chats of the current session.
            guard unread?[chat] != nil else { return }
            NSApp.activate()
            open?(chat)
        }
    }
}
