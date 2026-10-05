import Foundation
import UserNotifications

/// Lên lịch thông báo nhắc note và báo hết giờ Pomodoro.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let focusID = "memo.focus"

    var onOpenNote: (@MainActor (UUID) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func setup() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func sync(_ note: Note) {
        let id = note.id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard let date = note.reminder, !note.isDone, date > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = note.displayTitle
        content.body = note.preview.isEmpty ? date.reminderText : note.preview
        content.sound = .default
        content.userInfo = ["noteID": id]

        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func cancel(_ id: UUID) {
        center.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        center.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    func scheduleFocusEnd(after seconds: TimeInterval, title: String, body: String) {
        cancelFocus()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Âm thanh do app tự phát (NSSound) để không bị kêu hai lần.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.focusID, content: content, trigger: trigger))
    }

    /// Nhắc trước mỗi tiết học, lặp lại hằng tuần.
    func syncTimetable(_ blocks: [ClassBlock]) {
        center.getPendingNotificationRequests { [center] reqs in
            center.removePendingNotificationRequests(withIdentifiers: reqs.map(\.identifier).filter { $0.hasPrefix("tt-") })
            for b in blocks where !b.isRest {
                guard let before = b.reminder else { continue }
                var minute = b.start - before
                var day = b.weekday
                if minute < 0 { minute += 1440; day = day == 1 ? 7 : day - 1 }
                var comps = DateComponents()
                comps.weekday = day == 7 ? 1 : day + 1 // Apple: 1 = Chủ nhật
                comps.hour = minute / 60
                comps.minute = minute % 60
                let content = UNMutableNotificationContent()
                content.title = "\(b.title.isEmpty ? "Tiết học" : b.title) lúc \(TT.time(b.start))"
                content.body = ["Còn \(before) phút", b.location.isEmpty ? nil : "Phòng \(b.location)",
                                b.teacher.isEmpty ? nil : b.teacher].compactMap { $0 }.joined(separator: " · ")
                content.sound = .default
                center.add(UNNotificationRequest(identifier: "tt-\(b.id.uuidString)", content: content,
                                                 trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)))
            }
        }
    }

    /// Thông báo ngay lập tức.
    func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func cancelFocus() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.focusID])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let raw = response.notification.request.content.userInfo["noteID"] as? String,
           let id = UUID(uuidString: raw) {
            Task { @MainActor in self.onOpenNote?(id) }
        }
        completionHandler()
    }
}
