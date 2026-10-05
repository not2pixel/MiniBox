import SwiftUI

struct QuizPlayer: View {
    private struct Card: Identifiable {
        let id: UUID
        let question: String
        let options: [String]
        let answer: Int
        let explanation: String

        init(_ q: QuizQuestion, shuffleOptions: Bool) {
            id = q.id
            question = q.question
            explanation = q.explanation
            if shuffleOptions {
                let order = q.options.indices.shuffled()
                options = order.map { q.options[$0] }
                answer = order.firstIndex(of: q.answer) ?? 0
            } else {
                options = q.options
                answer = q.answer
            }
        }
    }

    @Binding var quiz: Quiz
    let onExit: () -> Void

    @AppStorage("quizShuffleQuestions") private var shuffleQuestions = false
    @AppStorage("quizShuffleOptions") private var shuffleOptions = false

    @State private var deck: [Card] = []
    @State private var index = 0
    @State private var picked: Int?
    @State private var correct = 0
    @State private var wrongIDs: [UUID] = []
    @State private var finished = false
    @State private var isFullRun = true
    @State private var newRecord = false

    private var progress: Double {
        guard !deck.isEmpty else { return 0 }
        return Double(index + (picked == nil ? 0 : 1)) / Double(deck.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onExit) {
                    Label("Thoát", systemImage: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

                Spacer()
                Text(finished ? quiz.title : "Câu \(min(index + 1, deck.count))/\(deck.count)")
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer()

                Label("\(correct)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 24)
                .animation(.snappy, value: progress)

            if finished {
                result
            } else if deck.indices.contains(index) {
                ScrollView { card(deck[index]).id(deck[index].id) }
            }
        }
        .onAppear { start(with: quiz.questions, full: true) }
    }

    // MARK: Card

    private func card(_ c: Card) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(c.question)
                .font(.system(size: 22, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(Array(c.options.enumerated()), id: \.offset) { j, opt in
                    OptionButton(letter: j < 26 ? String(UnicodeScalar(UInt8(65 + j))) : "\(j + 1)",
                                 text: opt, state: state(of: j, in: c)) {
                        choose(j, in: c)
                    }
                    .keyboardShortcut(j < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(j + 1)")), modifiers: []) : nil)
                    .disabled(picked != nil)
                }
            }

            if picked != nil {
                if !c.explanation.isEmpty {
                    Label {
                        Text(c.explanation).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    }
                    .font(.callout)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack {
                    Spacer()
                    Button(action: next) {
                        Label(index + 1 < deck.count ? "Câu tiếp" : "Xem kết quả", systemImage: "arrow.right")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                }
            } else {
                Text("Chọn đáp án hoặc nhấn phím 1–\(min(c.options.count, 9))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 640)
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private func state(of j: Int, in c: Card) -> OptionButton.State {
        guard let picked else { return .idle }
        if j == c.answer { return .correct }
        if j == picked { return .wrong }
        return .dimmed
    }

    private func choose(_ j: Int, in c: Card) {
        guard picked == nil else { return }
        withAnimation(.snappy) {
            picked = j
            if j == c.answer { correct += 1 } else { wrongIDs.append(c.id) }
        }
    }

    private func next() {
        withAnimation(.snappy) {
            if index + 1 < deck.count {
                index += 1
                picked = nil
            } else {
                finish()
            }
        }
    }

    private func start(with questions: [QuizQuestion], full: Bool) {
        let qs = shuffleQuestions ? questions.shuffled() : questions
        deck = qs.map { Card($0, shuffleOptions: shuffleOptions) }
        index = 0
        picked = nil
        correct = 0
        wrongIDs = []
        finished = false
        newRecord = false
        isFullRun = full
    }

    private func finish() {
        finished = true
        guard isFullRun else { return }
        quiz.playCount += 1
        quiz.lastScore = correct
        if correct > (quiz.bestScore ?? -1) {
            newRecord = quiz.bestScore != nil
            quiz.bestScore = correct
        }
    }

    // MARK: Result

    private var result: some View {
        let total = max(deck.count, 1)
        let ratio = Double(correct) / Double(total)
        let tint: Color = ratio >= 0.8 ? .green : ratio >= 0.5 ? .orange : .red

        return ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(tint.opacity(0.15), lineWidth: 14)
                    Circle()
                        .trim(from: 0, to: ratio)
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 2) {
                        Text("\(Int((ratio * 100).rounded()))%")
                            .font(.system(size: 48, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("\(correct)/\(deck.count) câu đúng")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 200, height: 200)

                VStack(spacing: 6) {
                    Text(ratio >= 0.8 ? "Xuất sắc!" : ratio >= 0.5 ? "Khá lắm!" : "Cố thêm chút nữa nhé!")
                        .font(.title2.bold())
                    if newRecord {
                        Label("Kỷ lục mới", systemImage: "trophy.fill")
                            .foregroundStyle(.orange)
                            .font(.callout.weight(.semibold))
                    } else if !isFullRun {
                        Text("Lượt ôn câu sai không tính vào điểm cao nhất.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.snappy) { start(with: quiz.questions, full: true) }
                    } label: {
                        Label("Làm lại", systemImage: "arrow.counterclockwise")
                    }

                    Button {
                        let wrong = quiz.questions.filter { wrongIDs.contains($0.id) }
                        withAnimation(.snappy) { start(with: wrong, full: false) }
                    } label: {
                        Label("Ôn câu sai (\(wrongIDs.count))", systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(wrongIDs.isEmpty)

                    Button("Xong", action: onExit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct OptionButton: View {
    enum State { case idle, correct, wrong, dimmed }

    let letter: String
    let text: String
    let state: State
    let action: () -> Void
    @SwiftUI.State private var hovering = false

    private var tint: Color {
        switch state {
        case .correct: .green
        case .wrong: .red
        default: .playBlue
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(letter)
                    .font(.callout.weight(.bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(state == .correct || state == .wrong ? .white : tint)
                    .background(
                        Circle().fill(state == .correct || state == .wrong
                                      ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.15)))
                    )
                Text(text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if state == .correct {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if state == .wrong {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(state == .correct || state == .wrong
                          ? AnyShapeStyle(tint.opacity(0.12))
                          : AnyShapeStyle(.quaternary.opacity(hovering ? 0.8 : 0.45)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(state == .correct || state == .wrong ? tint.opacity(0.6) : .clear, lineWidth: 1.5)
            )
            .opacity(state == .dimmed ? 0.5 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
