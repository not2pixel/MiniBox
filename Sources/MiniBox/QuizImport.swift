import SwiftUI

/// Sheet tạo prompt mẫu để gửi cho AI.
struct QuizPromptSheet: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var ai = AISettings.shared
    @Environment(\.dismiss) private var dismiss

    @AppStorage("quizCount") private var count = 10
    @AppStorage("quizChoices") private var choices = 4
    @AppStorage("quizDifficulty") private var difficulty: QuizDifficulty.RawValue = QuizDifficulty.medium.rawValue
    @AppStorage("quizLanguage") private var language = "Tiếng Việt"

    @State private var topic = ""
    @State private var sourceNoteID: UUID?
    @State private var copied = false

    private var sourceNote: Note? { store.notes.first { $0.id == sourceNoteID } }

    private var sourceText: String? {
        guard let n = sourceNote else { return nil }
        var t = n.displayTitle
        if !n.checklist.isEmpty { t += "\n" + n.checklist.map { "- \($0.text)" }.joined(separator: "\n") }
        if !n.body.trimmed.isEmpty { t += "\n" + n.body }
        return t
    }

    private var prompt: String {
        QuizPrompt.build(topic: topic, count: count, choices: choices,
                         difficulty: QuizDifficulty(rawValue: difficulty) ?? .medium,
                         language: language, source: sourceText)
    }

    private var canBuild: Bool { !topic.trimmed.isEmpty || sourceNote != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: "wand.and.stars", color: .purple, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompt mẫu tạo trắc nghiệm").font(.title3.bold())
                    Text("Gửi cho AI → copy kết quả → dán vào Trắc nghiệm (⌘V).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Chủ đề").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("VD: Lịch sử Việt Nam 1945–1975", text: $topic)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Nguồn").foregroundStyle(.secondary)
                    Menu {
                        Button("Không dùng note") { sourceNoteID = nil }
                        Divider()
                        ForEach(store.notes.sorted { $0.updatedAt > $1.updatedAt }.prefix(40)) { n in
                            Button(n.displayTitle) { sourceNoteID = n.id }
                        }
                    } label: {
                        Label(sourceNote?.displayTitle ?? "Không dùng note",
                              systemImage: sourceNote == nil ? "note.text" : "note.text.badge.plus")
                    }
                    .fixedSize()
                }
                GridRow {
                    Text("Số câu").foregroundStyle(.secondary)
                    Stepper("\(count) câu", value: $count, in: 3...50)
                }
                GridRow {
                    Text("Lựa chọn").foregroundStyle(.secondary)
                    Stepper("\(choices) đáp án mỗi câu", value: $choices, in: 2...6)
                }
                GridRow {
                    Text("Độ khó").foregroundStyle(.secondary)
                    Picker("Độ khó", selection: $difficulty) {
                        ForEach(QuizDifficulty.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Ngôn ngữ").foregroundStyle(.secondary)
                    Picker("Ngôn ngữ", selection: $language) {
                        Text("Tiếng Việt").tag("Tiếng Việt")
                        Text("English").tag("English")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Xem trước").font(.subheadline.weight(.semibold))
                ScrollView {
                    Text(canBuild ? prompt : "Nhập chủ đề hoặc chọn một note làm nguồn.")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(canBuild ? .primary : .tertiary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 170)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack {
                Button("Đóng") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                    withAnimation(.snappy) { copied = true }
                } label: {
                    Label(copied ? "Đã copy" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(!canBuild)

                Button {
                    let text = prompt
                    dismiss()
                    store.askAI(text)
                } label: {
                    Label { Text("Gửi tới \(ai.current.name)") } icon: { ai.current.menuIcon }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canBuild)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onChange(of: prompt) { copied = false }
    }
}

/// Sheet dán kết quả AI khi không tự đọc được từ clipboard.
struct QuizPasteSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var text: String
    @State private var title = ""

    var body: some View {
        let result = Result { try QuizParser.parse(text) }

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: "doc.on.clipboard", color: .playBlue, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dán câu hỏi từ AI").font(.title3.bold())
                    Text("Dán nguyên câu trả lời của AI — app tự lọc lấy phần JSON.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            TextEditor(text: $text)
                .font(.system(.callout, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 260)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("{ \"title\": …, \"questions\": [ … ] }")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }

            Group {
                switch result {
                case .success(let parsed):
                    Label("Đọc được \(parsed.questions.count) câu hỏi\(parsed.title.map { " · “\($0)”" } ?? "")",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)

            TextField("Tên bộ câu hỏi (để trống sẽ dùng tên AI đặt)", text: $title)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    text = NSPasteboard.general.string(forType: .string) ?? text
                } label: {
                    Label("Dán từ clipboard", systemImage: "doc.on.clipboard")
                }
                Spacer()
                Button("Huỷ") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Tạo bộ câu hỏi") {
                    guard case .success(var parsed) = result else { return }
                    if !title.trimmed.isEmpty { parsed.title = title.trimmed }
                    store.addQuiz(parsed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled((try? result.get()) == nil)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
