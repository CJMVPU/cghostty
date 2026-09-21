import AppKit
import UserNotifications

extension Ghostty.SurfaceView {
    /// Show a user notification and associate it with this surface
    func showUserNotification(title: String, body: String, requireFocus: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = self.title
        content.body = body
        content.sound = UNNotificationSound.default
        content.categoryIdentifier = Ghostty.userNotificationCategory
        content.userInfo = [
            "surface": self.id.uuidString,
            "requireFocus": requireFocus,
        ]

        let uuid = UUID().uuidString
        let request = UNNotificationRequest(
            identifier: uuid,
            content: content,
            trigger: nil
        )

        // Note the callback may be executed on a background thread as documented
        // so we need @MainActor since we're reading/writing view state.
        // We use [weak self] here because we don't want to extend the surface's
        // lifetime when a notification is triggered right before the surface closes.
        Task { @MainActor [weak self] in
            do {
                try await UNUserNotificationCenter.current().add(request)

                guard let focused = self?.focused else {
                    // We remove the notification if the surface is deallocated.
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: [uuid])
                    return
                }

                // We need to keep track of this notification so we can remove it
                // under certain circumstances
                self?.notificationIdentifiers.insert(uuid)

                // If we're focused then we schedule to remove the notification
                // after a few seconds. If we gain focus we automatically remove it
                // in focusDidChange.
                if focused {
                    // If the suspension is failed, we remove the notification anyway.
                    try? await Task.sleep(for: .seconds(3))
                    self?.notificationIdentifiers.remove(uuid)
                    // We remove the notification if the surface is deallocated while we wait.
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: [uuid])
                }
            } catch {
                AppDelegate.logger.error("Error scheduling user notification: \(error, privacy: .public)")
            }
        }
    }

    /// Handle a user notification click
    func handleUserNotification(notification: UNNotification, focus: Bool) {
        let id = notification.request.identifier
        guard self.notificationIdentifiers.remove(id) != nil else { return }
        if focus {
            self.window?.makeKeyAndOrderFront(self)
            Ghostty.moveFocus(to: self)
        }
    }

}
