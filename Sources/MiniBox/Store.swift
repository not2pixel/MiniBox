import AppKit
import Combine
import SwiftUI

/// Toàn bộ dữ liệu lưu trong một file JSON ở ~/Library/Application Support/MiniBox/data.json.
@MainActor
final class Store: ObservableObject {
    @Published var notes: [Note] = []
    @Published var categories: [Category] = []
    @Published var selection: SidebarItem? = .all
    @Published var selectedNoteID: UUID?
    @Published var searchText = ""
    @Published var quizzes: [Quiz] = []
    @Published var selectedQuizID: UUID?
    @Published var timetable: [ClassBlock] = []

    private struct Snapshot: Codable {
        var notes: [Note]
        var categories: [Category]
        var quizzes: [Quiz]?
        var timetable: [ClassBlock]?
    }

    private let fileURL: URL
    private var bag = Set<AnyCancellable>()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiniBox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("data.json")
        load()

        Publishers.CombineLatest4($notes, $categories, $quizzes, $timetable)
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)

        // Nhắc trước giờ học: đồng bộ lại khi thời khoá biểu thay đổi.
        $timetable
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { Notifier.shared.syncTimetable($0) }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.save() }
            .store(in: &bag)
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            categories = [
                Category(name: "Cá nhân", symbol: "person.fill", color: .blue),
                Category(name: "Công việc", symbol: "briefcase.fill", color: .orange),
                Category(name: "Ý tưởng", symbol: "lightbulb.fill", color: .yellow),
            ]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snap = try? decoder.decode(Snapshot.self, from: data) {
            notes = snap.notes
            categories = snap.categories
            quizzes = snap.quizzes ?? []
            timetable = snap.timetable ?? []
        } else {
            // Không đọc được: giữ một bản sao trước khi app ghi dữ liệu mới đè lên.
            let stamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("data-backup-\(stamp).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Snapshot(notes: notes, categories: categories, quizzes: quizzes, timetable: timetable)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Queries

    func category(_ id: UUID?) -> Category? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    func notes(for item: SidebarItem?, query: String? = nil) -> [Note] {
        let base: [Note]
        switch item ?? .all {
        case .all: base = notes.filter { !$0.isDone }
        case .today:
            base = notes.filter { n in
                guard !n.isDone, let r = n.reminder else { return false }
                return Calendar.current.isDateInToday(r) || r < .now
            }
        case .scheduled: base = notes.filter { !$0.isDone && $0.reminder != nil }
        case .done: base = notes.filter(\.isDone)
        case .category(let id): base = notes.filter { $0.categoryID == id }
        case .focus, .quiz, .ai, .storage, .gamebox, .music, .timetable: base = []
        }
        let q = (query ?? searchText).trimmed
        let filtered = base.filter { $0.matches(q) }

        if item == .scheduled || item == .today {
            return filtered.sorted { ($0.reminder ?? .distantFuture) < ($1.reminder ?? .distantFuture) }
        }
        return filtered.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.isDone != $1.isDone { return !$0.isDone }
            return $0.updatedAt > $1.updatedAt
        }
    }

    func count(for item: SidebarItem) -> Int {
        notes(for: item, query: "").count
    }

    var openNotes: [Note] { notes.filter { !$0.isDone }.sorted { $0.updatedAt > $1.updatedAt } }

    // MARK: Mutations

    func addNote() {
        var note = Note()
        switch selection ?? .all {
        case .category(let id): note.categoryID = id
        case .today, .scheduled: note.reminder = .nextHour
        case .done, .focus, .quiz, .ai, .storage, .gamebox, .music, .timetable: selection = .all
        case .all: break
        }
        searchText = ""
        notes.append(note)
        selectedNoteID = note.id
        Notifier.shared.sync(note)
    }

    func binding(for id: UUID) -> Binding<Note>? {
        guard let current = notes.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.notes.first { $0.id == id } ?? current },
            set: { [weak self] in self?.update($0) }
        )
    }

    func update(_ note: Note) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        let old = notes[i]
        guard old != note else { return }
        var new = note
        new.updatedAt = .now
        notes[i] = new
        if old.reminder != new.reminder || old.isDone != new.isDone
            || (new.reminder != nil && old.title != new.title) {
            Notifier.shared.sync(new)
        }
    }

    func mutate(_ id: UUID, _ change: (inout Note) -> Void) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        change(&note)
        withAnimation(.snappy) { update(note) }
    }

    func toggleDone(_ id: UUID) { mutate(id) { $0.isDone.toggle() } }
    func togglePin(_ id: UUID) { mutate(id) { $0.isPinned.toggle() } }

    func delete(_ id: UUID) {
        Notifier.shared.cancel(id)
        withAnimation(.snappy) { notes.removeAll { $0.id == id } }
        if selectedNoteID == id { selectedNoteID = nil }
    }

    func reveal(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        searchText = ""
        selection = note.isDone ? .done : .all
        selectedNoteID = id
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Thời khoá biểu

    /// Thêm mới (có thể cho nhiều ngày cùng lúc) hoặc lưu thay đổi.
    func saveBlock(_ block: ClassBlock, days: [Int], isNew: Bool) {
        var b = block
        b.title = b.title.trimmed
        if isNew {
            for d in days {
                var copy = b
                copy.id = UUID()
                copy.weekday = d
                timetable.append(copy)
            }
        } else if let i = timetable.firstIndex(where: { $0.id == b.id }) {
            if let d = days.first { b.weekday = d }
            timetable[i] = b
        }
    }

    func updateBlock(_ id: UUID, _ change: (inout ClassBlock) -> Void) {
        guard let i = timetable.firstIndex(where: { $0.id == id }) else { return }
        change(&timetable[i])
    }

    func deleteBlock(_ id: UUID) {
        withAnimation(.snappy) { timetable.removeAll { $0.id == id } }
    }

    func duplicateBlock(_ id: UUID, to day: Int) {
        guard var b = timetable.first(where: { $0.id == id }) else { return }
        guard !timetable.contains(where: { $0.weekday == day && $0.start == b.start && $0.title == b.title }) else { return }
        b.id = UUID()
        b.weekday = day
        timetable.append(b)
    }

    // MARK: Quiz

    func addQuiz(_ parsed: ParsedQuiz) {
        let title = parsed.title?.trimmed ?? ""
        let quiz = Quiz(title: title.isEmpty ? "Bộ trắc nghiệm mới" : title, questions: parsed.questions)
        quizzes.insert(quiz, at: 0)
        selection = .quiz
        selectedQuizID = quiz.id
    }

    func quizBinding(_ id: UUID) -> Binding<Quiz>? {
        guard let current = quizzes.first(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.quizzes.first { $0.id == id } ?? current },
            set: { [weak self] new in
                guard let self, let i = self.quizzes.firstIndex(where: { $0.id == id }) else { return }
                self.quizzes[i] = new
            }
        )
    }

    func deleteQuiz(_ id: UUID) {
        withAnimation(.snappy) { quizzes.removeAll { $0.id == id } }
        if selectedQuizID == id { selectedQuizID = nil }
    }

    func duplicateQuiz(_ id: UUID) {
        guard let i = quizzes.firstIndex(where: { $0.id == id }) else { return }
        var copy = quizzes[i]
        copy.id = UUID()
        copy.title += " (bản sao)"
        copy.createdAt = .now
        copy.bestScore = nil
        copy.lastScore = nil
        copy.playCount = 0
        copy.questions = copy.questions.map { var q = $0; q.id = UUID(); return q }
        quizzes.insert(copy, at: i + 1)
        selectedQuizID = copy.id
    }

    func copyQuizJSON(_ id: UUID) {
        guard let quiz = quizzes.first(where: { $0.id == id }) else { return }
        let dict: [String: Any] = [
            "title": quiz.title,
            "questions": quiz.questions.map {
                ["question": $0.question, "options": $0.options, "answer": $0.answer, "explanation": $0.explanation]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: AI

    /// Mở trợ lý AI hiện tại (trong app hoặc Safari tuỳ cài đặt).
    func openAI() {
        let ai = AISettings.shared
        if ai.openMode == .safari, let url = ai.current.home {
            Safari.open(url)
        } else {
            selection = .ai
        }
    }

    /// Gửi nội dung sang trợ lý AI: luôn copy vào clipboard, và tự điền vào ô chat nếu mở trong app.
    func askAI(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let provider = AISettings.shared.current
        openAI()
        guard AISettings.shared.openMode == .inApp else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AIWebStore.shared.page(for: provider)?.send(text)
        }
    }

    // MARK: Categories

    func upsert(_ category: Category, select: Bool = true) {
        if let i = categories.firstIndex(where: { $0.id == category.id }) {
            categories[i] = category
        } else {
            categories.append(category)
            if select { selection = .category(category.id) }
        }
    }

    func deleteCategory(_ id: UUID) {
        for i in notes.indices where notes[i].categoryID == id { notes[i].categoryID = nil }
        categories.removeAll { $0.id == id }
        if selection == .category(id) { selection = .all }
    }

    func moveCategory(from source: IndexSet, to destination: Int) {
        categories.move(fromOffsets: source, toOffset: destination)
    }
}
