import SwiftUI

struct PasteDraft: Identifiable {
    let id = UUID()
    var text: String
}

struct QuizBrowser: View {
    @EnvironmentObject private var store: Store
    @State private var showPrompt = false
    @State private var pasteDraft: PasteDraft?
    @State private var playingID: UUID?

    var body: some View {
        HSplitView {
            QuizList(onPrompt: { showPrompt = true }, onPaste: pasteFromClipboard)
                .frame(minWidth: 260, idealWidth: 310, maxWidth: 440)

            Group {
                if let id = store.selectedQuizID, let quiz = store.quizBinding(id) {
                    if playingID == id {
                        QuizPlayer(quiz: quiz) { playingID = nil }
                            .id("play-\(id)")
                    } else {
                        QuizDetail(quiz: quiz) { playingID = id }
                            .id(id)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Chưa chọn bộ câu hỏi", systemImage: "graduationcap")
                    } description: {
                        Text("Chọn một bộ câu hỏi bên trái, hoặc dán bộ câu hỏi AI vừa tạo (⌘V).")
                    }
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationTitle("Trắc nghiệm")
        .navigationSubtitle("\(store.quizzes.count) bộ câu hỏi")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showPrompt = true } label: {
                    Label("Prompt mẫu", systemImage: "wand.and.stars")
                }
                .help("Tạo prompt để AI soạn câu hỏi")

                Button(action: pasteFromClipboard) {
                    Label("Dán câu hỏi", systemImage: "doc.on.clipboard")
                }
                .help("Tạo bộ câu hỏi từ nội dung đã copy (⌘V)")
            }
        }
        .sheet(isPresented: $showPrompt) { QuizPromptSheet() }
        .sheet(item: $pasteDraft) { QuizPasteSheet(text: $0.text) }
        .onChange(of: store.selectedQuizID) { playingID = nil }
    }

    /// Dán thẳng: đọc được thì tạo ngay, không thì mở sheet để sửa.
    private func pasteFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        if let parsed = try? QuizParser.parse(text) {
            withAnimation(.snappy) { store.addQuiz(parsed) }
        } else {
            pasteDraft = PasteDraft(text: text)
        }
    }
}

// MARK: - List

private struct QuizList: View {
    @EnvironmentObject private var store: Store
    let onPrompt: () -> Void
    let onPaste: () -> Void

    var body: some View {
        List(selection: $store.selectedQuizID) {
            ForEach(store.quizzes) { quiz in
                QuizRow(quiz: quiz)
                    .tag(quiz.id)
                    .contextMenu {
                        Button("Nhân bản", systemImage: "plus.square.on.square") { store.duplicateQuiz(quiz.id) }
                        Button("Copy dạng JSON", systemImage: "curlybraces") { store.copyQuizJSON(quiz.id) }
                        Divider()
                        Button("Xoá", systemImage: "trash", role: .destructive) { store.deleteQuiz(quiz.id) }
                    }
            }
            .onMove { store.quizzes.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.background.secondary)
        .onDeleteCommand {
            if let id = store.selectedQuizID { store.deleteQuiz(id) }
        }
        .onPasteCommand(of: [.plainText]) { _ in onPaste() }
        .overlay {
            if store.quizzes.isEmpty {
                ContentUnavailableView {
                    Label("Chưa có bộ câu hỏi", systemImage: "graduationcap")
                } description: {
                    Text("Lấy prompt mẫu gửi cho AI, copy kết quả rồi dán vào đây.")
                } actions: {
                    Button("Prompt mẫu", action: onPrompt)
                    Button("Dán câu hỏi", action: onPaste)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct QuizRow: View {
    let quiz: Quiz

    var body: some View {
        HStack(spacing: 10) {
            SymbolBadge(symbol: "graduationcap.fill", color: .purple, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(quiz.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(quiz.questions.count) câu · \(quiz.createdAt.formatted(.dateTime.day().month(.abbreviated).locale(.vi)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let best = quiz.bestScore {
                Text("\(best)/\(quiz.questions.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .foregroundStyle(.green)
                    .background(.green.opacity(0.15), in: Capsule())
                    .help("Điểm cao nhất")
            }
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Detail

private struct QuizDetail: View {
    @Binding var quiz: Quiz
    let onPlay: () -> Void
    @State private var editing: QuizQuestion?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Tên bộ câu hỏi", text: $quiz.title)
                    .font(.system(size: 26, weight: .bold))
                    .textFieldStyle(.plain)

                HStack(spacing: 8) {
                    Label("\(quiz.questions.count) câu", systemImage: "list.number")
                        .modifier(InfoChip(tint: .playBlue))
                    if let best = quiz.bestScore {
                        Label("Cao nhất \(best)/\(quiz.questions.count)", systemImage: "trophy.fill")
                            .modifier(InfoChip(tint: .orange))
                    }

                    Button {
                        withAnimation(.snappy) { quiz.questions.shuffle() }
                    } label: {
                        Label("Trộn thứ tự", systemImage: "shuffle")
                    }
                    .buttonStyle(ChipStyle())
                    .disabled(quiz.questions.count < 2)

                    Button {
                        editing = QuizQuestion(question: "", options: ["", "", "", ""], answer: 0)
                    } label: {
                        Label("Thêm câu", systemImage: "plus")
                    }
                    .buttonStyle(ChipStyle())

                    Spacer(minLength: 0)

                    Button(action: onPlay) {
                        Label("Bắt đầu", systemImage: "play.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(quiz.questions.isEmpty)
                    .help("Bắt đầu làm bài (⌘↩)")
                }
                .labelStyle(CompactLabel())

                Text("Kéo thả để sắp xếp lại câu hỏi · nhấp đúp để sửa")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider().padding(.horizontal, 28)

            List {
                ForEach(Array(quiz.questions.enumerated()), id: \.element.id) { i, q in
                    QuestionRow(number: i + 1, question: q)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = q }
                        .contextMenu {
                            Button("Sửa…", systemImage: "pencil") { editing = q }
                            Button("Lên trên", systemImage: "arrow.up") { move(q.id, by: -1) }
                                .disabled(i == 0)
                            Button("Xuống dưới", systemImage: "arrow.down") { move(q.id, by: 1) }
                                .disabled(i == quiz.questions.count - 1)
                            Divider()
                            Button("Xoá câu", systemImage: "trash", role: .destructive) {
                                withAnimation(.snappy) { quiz.questions.removeAll { $0.id == q.id } }
                            }
                        }
                }
                .onMove { quiz.questions.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
        .sheet(item: $editing) { q in
            QuestionEditor(question: q, isNew: !quiz.questions.contains { $0.id == q.id }) { saved in
                withAnimation(.snappy) {
                    if let i = quiz.questions.firstIndex(where: { $0.id == saved.id }) {
                        quiz.questions[i] = saved
                    } else {
                        quiz.questions.append(saved)
                    }
                }
            }
        }
    }

    /// Tìm lại vị trí theo id ngay lúc bấm (chỉ số cũ có thể đã lệch).
    private func move(_ id: UUID, by delta: Int) {
        guard let i = quiz.questions.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard quiz.questions.indices.contains(j) else { return }
        withAnimation(.snappy) { quiz.questions.swapAt(i, j) }
    }
}

private struct InfoChip: ViewModifier {
    let tint: Color
    func body(content: Content) -> some View {
        content
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

private struct QuestionRow: View {
    let number: Int
    let question: QuizQuestion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.playBlue)
                .frame(width: 26, height: 26)
                .background(Color.playBlue.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(question.question)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(question.options.enumerated()), id: \.offset) { j, opt in
                    let right = j == question.answer
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: right ? "checkmark.circle.fill" : "circle")
                            .imageScale(.small)
                            .foregroundStyle(right ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                        Text(opt)
                            .foregroundStyle(right ? .primary : .secondary)
                    }
                    .font(.callout)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Question editor

private struct QuestionEditor: View {
    private struct Option: Identifiable {
        let id = UUID()
        var text: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var question: QuizQuestion
    @State private var options: [Option]
    @State private var answerID: UUID?
    let isNew: Bool
    let onSave: (QuizQuestion) -> Void

    init(question: QuizQuestion, isNew: Bool, onSave: @escaping (QuizQuestion) -> Void) {
        let opts = question.options.map { Option(text: $0) }
        _question = State(initialValue: question)
        _options = State(initialValue: opts)
        _answerID = State(initialValue: opts.indices.contains(question.answer) ? opts[question.answer].id : opts.first?.id)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var isValid: Bool {
        !question.question.trimmed.isEmpty
            && options.filter { !$0.text.trimmed.isEmpty }.count >= 2
            && options.contains { $0.id == answerID && !$0.text.trimmed.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Câu hỏi mới" : "Sửa câu hỏi").font(.title3.bold())

            TextField("Nội dung câu hỏi", text: $question.question, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)

            Text("Lựa chọn — bấm vòng tròn để chọn đáp án đúng")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(options) { opt in
                HStack(spacing: 8) {
                    CheckButton(isOn: answerID == opt.id, size: 17, tint: .green) { answerID = opt.id }
                    TextField("Lựa chọn", text: $options.element(opt.id, fallback: opt).text)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let id = opt.id
                        withAnimation(.snappy) { options.removeAll { $0.id == id } }
                        if answerID == id { answerID = options.first?.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(options.count <= 2)
                }
            }

            Button {
                withAnimation(.snappy) { options.append(Option(text: "")) }
            } label: {
                Label("Thêm lựa chọn", systemImage: "plus.circle")
            }
            .buttonStyle(.link)
            .disabled(options.count >= 6)

            TextField("Giải thích (không bắt buộc)", text: $question.explanation, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            HStack {
                Button("Huỷ", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isNew ? "Thêm" : "Lưu") {
                    let kept = options.filter { !$0.text.trimmed.isEmpty }
                    question.question = question.question.trimmed
                    question.options = kept.map { $0.text.trimmed }
                    question.answer = kept.firstIndex { $0.id == answerID } ?? 0
                    onSave(question)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 480)
    }
}
