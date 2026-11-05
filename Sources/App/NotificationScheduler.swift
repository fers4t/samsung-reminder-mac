import Foundation
import UserNotifications
import os

/// Local notifications for due reminders. Rebuilt from the snapshot after each
/// sync; identifiers are the reminder ids so repeats never double-schedule.
actor NotificationScheduler {
    /// macOS keeps at most 64 pending requests per app.
    static let limit = 60
    private static let logger = Logger(subsystem: "SamsungReminder", category: "notifications")
    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool?

    private func ensureAuthorized() async -> Bool {
        if let authorized { return authorized }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default: authorized = false
        }
        return authorized ?? false
    }

    func schedule(for pending: [Reminder]) async {
        guard await ensureAuthorized() else { return }
        center.removeAllPendingNotificationRequests()
        let now = Date()
        let due = pending.lazy.filter { ($0.dueAt ?? .distantPast) > now }.prefix(Self.limit)
        for reminder in due {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            if !reminder.text.isEmpty { content.body = reminder.text }
            content.sound = .default
            content.userInfo = ["id": reminder.id]
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.dueAt!)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            } catch {
                Self.logger.error("schedule failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
    }
}
