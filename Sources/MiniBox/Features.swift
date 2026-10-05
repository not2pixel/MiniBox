import SwiftUI

/// Các mục trên sidebar có thể bật/tắt trong Cài đặt → Chung.
enum Feature: String, CaseIterable, Identifiable {
    case today, scheduled, done, timetable, focus, music, quiz, ai, storage, gamebox

    var id: String { rawValue }

    static let lists: [Feature] = [.today, .scheduled, .done, .timetable]
    static let utilities: [Feature] = [.focus, .quiz, .ai, .storage, .gamebox, .music]

    var item: SidebarItem {
        switch self {
        case .today: .today
        case .scheduled: .scheduled
        case .done: .done
        case .focus: .focus
        case .quiz: .quiz
        case .ai: .ai
        case .storage: .storage
        case .gamebox: .gamebox
        case .music: .music
        case .timetable: .timetable
        }
    }

    var title: String { self == .focus ? "Pomodoro" : item.title }

    init?(item: SidebarItem) {
        guard let f = Feature.allCases.first(where: { $0.item == item }) else { return nil }
        self = f
    }
}

@MainActor
final class Features: ObservableObject {
    static let shared = Features()

    @Published private(set) var hidden: Set<String> {
        didSet { UserDefaults.standard.set(Array(hidden), forKey: "hiddenFeatures") }
    }

    private init() {
        hidden = Set(UserDefaults.standard.stringArray(forKey: "hiddenFeatures") ?? [])
    }

    func isOn(_ f: Feature) -> Bool { !hidden.contains(f.rawValue) }

    func binding(_ f: Feature) -> Binding<Bool> {
        Binding(get: { self.isOn(f) }, set: { on in
            if on { self.hidden.remove(f.rawValue) } else { self.hidden.insert(f.rawValue) }
        })
    }

    /// "Tất cả" và danh mục luôn hiện.
    func isVisible(_ item: SidebarItem?) -> Bool {
        guard let item, let f = Feature(item: item) else { return true }
        return isOn(f)
    }
}
