import Foundation

struct Category: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbol: String
    var color: Palette
}

struct ChecklistItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var text = ""
    var isDone = false
}

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var title = ""
    var body = ""
    var categoryID: UUID?
    var isDone = false
    var isPinned = false
    var reminder: Date?
    var checklist: [ChecklistItem] = []
    var createdAt = Date()
    var updatedAt = Date()

    var displayTitle: String { title.trimmed.isEmpty ? "Ghi chú mới" : title }

    var preview: String {
        body.split(whereSeparator: \.isNewline)
            .map { String($0).trimmed }
            .first { !$0.isEmpty } ?? ""
    }

    var checklistDone: Int { checklist.filter(\.isDone).count }

    var isOverdue: Bool {
        guard let reminder, !isDone else { return false }
        return reminder < .now
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return title.localizedCaseInsensitiveContains(query)
            || body.localizedCaseInsensitiveContains(query)
            || checklist.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

enum SidebarItem: Hashable {
    case all, today, scheduled, done
    case category(UUID)
    case focus
    case quiz
    case ai
    case storage
    case gamebox
    case music
    case timetable

    static let smart: [SidebarItem] = [.all, .today, .scheduled, .done]

    var title: String {
        switch self {
        case .all: "Tất cả"
        case .today: "Hôm nay"
        case .scheduled: "Đã lên lịch"
        case .done: "Hoàn thành"
        case .category: "Danh mục"
        case .focus: "Tập trung"
        case .quiz: "Trắc nghiệm"
        case .ai: "Trợ lý AI"
        case .storage: "Thư viện"
        case .gamebox: "Trò chơi"
        case .music: "Phát nhạc"
        case .timetable: "Thời khoá biểu"
        }
    }

    var symbol: String {
        switch self {
        case .all: "tray.full.fill"
        case .today: "sun.max.fill"
        case .scheduled: "calendar"
        case .done: "checkmark.circle.fill"
        case .category: "folder.fill"
        case .focus: "timer"
        case .quiz: "graduationcap.fill"
        case .ai: "sparkles"
        case .storage: "externaldrive.fill"
        case .gamebox: "gamecontroller.fill"
        case .music: "music.note"
        case .timetable: "calendar.badge.clock"
        }
    }

    var palette: Palette {
        switch self {
        case .all: .blue
        case .today: .orange
        case .scheduled: .red
        case .done: .gray
        case .category: .blue
        case .focus: .indigo
        case .quiz: .purple
        case .ai: .orange
        case .storage: .teal
        case .gamebox: .pink
        case .music: .green
        case .timetable: .red
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Locale {
    static let vi = Locale(identifier: "vi_VN")
}

extension Date {
    var reminderText: String {
        let cal = Calendar.current
        let time = formatted(.dateTime.hour().minute().locale(.vi))
        if cal.isDateInToday(self) { return "Hôm nay, \(time)" }
        if cal.isDateInTomorrow(self) { return "Ngày mai, \(time)" }
        if cal.isDateInYesterday(self) { return "Hôm qua, \(time)" }
        return formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(.vi))
    }

    /// Đầu giờ tiếp theo, ví dụ 14:23 → 15:00.
    static var nextHour: Date {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .hour, for: .now)?.start ?? .now
        return cal.date(byAdding: .hour, value: 1, to: start) ?? .now
    }

    static func today(at hour: Int, dayOffset: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: dayOffset, to: .now) ?? .now
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
}
