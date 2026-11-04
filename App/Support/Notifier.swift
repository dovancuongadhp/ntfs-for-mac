import Foundation
import NTFSShared
import notify
import UserNotifications

/// Shows user notifications, and listens for the extension's read-only signals.
@MainActor
final class Notifier {
    private var tokens: [Int32] = []
    /// The center only keeps a weak reference to its delegate.
    private let presenter = NotificationPresenter()

    func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                appLog.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Calls `handler` whenever the extension reports that a volume fell back to read-only.
    func observeReadOnlyFallbacks(_ handler: @escaping @MainActor (ReadOnlyReason) -> Void) {
        for reason in ReadOnlyReason.allCases {
            var token: Int32 = 0
            let status = notify_register_dispatch(reason.notificationName, &token, .main) { _ in
                MainActor.assumeIsolated { handler(reason) }
            }
            if status == NOTIFY_STATUS_OK {
                tokens.append(token)
            }
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Lets a notification show while the app is the active one. Without this the system keeps quiet for a
/// foreground app, and a copy waiting for an answer on another page of the window would go unnoticed.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let foregroundOptions: UNNotificationPresentationOptions = [.banner, .sound]

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.foregroundOptions
    }
}
