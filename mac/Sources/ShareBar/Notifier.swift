import Foundation
import ShareBarCore
import UserNotifications

/// Posts one local notification for a General toggle that is on. The first post asks macOS for
/// permission; a refusal is silent (the toggle stays what the person set).
enum Notifier {
    static func post(_ event: NotifyEvent) {
        post(title: event.title, body: event.body, id: event.key)
    }

    static func post(title: String, body: String, id: String) {
        // A bare executable has no bundle for the center to attach to.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
