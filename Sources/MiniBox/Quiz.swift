import Foundation

struct QuizQuestion: Identifiable, Codable, Hashable {
    var id = UUID()
    var question: String
    var options: [String]
    var answer: Int
    var explanation = ""
}

struct Quiz: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var questions: [QuizQuestion]
    var createdAt = Date()
    var bestScore: Int?
    var lastScore: Int?
    var playCount = 0
}

// MARK: - Prompt mẫu

enum QuizDifficulty: String, CaseIterable, Identifiable {
    case easy, medium, hard, mixed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .easy: "Dễ"
        case .medium: "Vừa"
        case .hard: "Khó"
        case .mixed: "Trộn"
        }
    }
    var promptText: String {
        switch self {
        case .easy: "dễ (kiến thức cơ bản)"
        case .medium: "trung bình"
        case .hard: "khó (đòi hỏi hiểu sâu, có bẫy)"
        case .mixed: "trộn từ dễ đến khó"
        }
    }
}

enum QuizPrompt {
    static func build(topic: String, count: Int, choices: Int, difficulty: QuizDifficulty,
                      language: String, source: String?) -> String {
        let subject = topic.trimmed.isEmpty ? "nội dung nguồn bên dưới" : "\"\(topic.trimmed)\""
        var p = """
        Hãy tạo \(count) câu hỏi trắc nghiệm về \(subject).
        - Độ khó: \(difficulty.promptText).
        - Ngôn ngữ: \(language).
        - Mỗi câu có đúng \(choices) lựa chọn và chỉ 1 đáp án đúng; vị trí đáp án đúng phân bố ngẫu nhiên.
        - Không ghi "A.", "B.", "1)"… trước lựa chọn.
        - "answer" là số thứ tự của đáp án đúng, BẮT ĐẦU TỪ 0.
        - "explanation" giải thích ngắn gọn (1–2 câu) vì sao đáp án đúng.
        """
        if let source, !source.trimmed.isEmpty {
            p += "\n- Chỉ dựa trên nội dung nguồn sau:\n\"\"\"\n\(source.trimmed)\n\"\"\""
        }
        p += """


        CHỈ trả về một khối JSON hợp lệ, không thêm lời dẫn, theo đúng định dạng:
        ```json
        {
          "title": "Tên bộ câu hỏi",
          "questions": [
            {
              "question": "Nội dung câu hỏi?",
              "options": [\((0..<choices).map { "\"Lựa chọn \($0 + 1)\"" }.joined(separator: ", "))],
              "answer": 0,
              "explanation": "Giải thích ngắn."
            }
          ]
        }
        ```
        """
        return p
    }
}

// MARK: - Đọc kết quả AI

struct ParsedQuiz {
    var title: String?
    var questions: [QuizQuestion]
}

enum QuizParser {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func parse(_ raw: String) throws -> ParsedQuiz {
        let text = raw.trimmed
        guard !text.isEmpty else { throw Failure(message: "Chưa có nội dung — hãy dán kết quả AI trả về.") }

        if let json = extractJSON(text), let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            let (title, items) = unwrap(obj)
            let qs = items.compactMap(question(from:))
            guard !qs.isEmpty else {
                throw Failure(message: "JSON hợp lệ nhưng không có câu hỏi nào đúng định dạng.")
            }
            return ParsedQuiz(title: title, questions: qs)
        }

        let qs = parsePlainText(text)
        guard !qs.isEmpty else {
            throw Failure(message: "Không đọc được câu hỏi. Hãy dán nguyên khối JSON mà AI trả về.")
        }
        return ParsedQuiz(title: nil, questions: qs)
    }

    /// Bỏ ```json … ``` và lấy đoạn từ dấu { hoặc [ đầu tiên đến dấu đóng cuối cùng.
    private static func extractJSON(_ text: String) -> String? {
        var t = text
        if let fence = t.range(of: "```") {
            var inner = t[fence.upperBound...]
            if let nl = inner.firstIndex(of: "\n") { inner = inner[inner.index(after: nl)...] }
            if let end = inner.range(of: "```") { inner = inner[..<end.lowerBound] }
            t = String(inner)
        }
        guard let start = t.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let close: Character = t[start] == "{" ? "}" : "]"
        guard let end = t.lastIndex(of: close), end > start else { return nil }
        return String(t[start...end])
    }

    private static func unwrap(_ obj: Any) -> (String?, [[String: Any]]) {
        if let arr = obj as? [[String: Any]] { return (nil, arr) }
        guard let dict = obj as? [String: Any] else { return (nil, []) }
        let title = (dict["title"] ?? dict["name"]) as? String
        for key in ["questions", "quiz", "items", "data", "cau_hoi"] {
            if let arr = dict[key] as? [[String: Any]] { return (title, arr) }
            if let inner = dict[key] as? [String: Any] {
                let (t, items) = unwrap(inner)
                return (title ?? t, items)
            }
        }
        if dict["question"] != nil { return (title, [dict]) }
        return (title, [])
    }

    private static func string(_ d: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let s = d[k] as? String, !s.trimmed.isEmpty { return s.trimmed }
        }
        return nil
    }

    private static func question(from d: [String: Any]) -> QuizQuestion? {
        guard let text = string(d, ["question", "q", "prompt", "text", "cau_hoi", "title"]) else { return nil }

        var options: [String] = []
        let rawOpts = d["options"] ?? d["choices"] ?? d["answers"] ?? d["lua_chon"]
        if let arr = rawOpts as? [Any] {
            options = arr.map { item in
                if let o = item as? [String: Any] { return string(o, ["text", "option", "value"]) ?? "" }
                return "\(item)".trimmed
            }
        } else if let dict = rawOpts as? [String: Any] {
            options = dict.keys.sorted().map { "\(dict[$0]!)".trimmed }
        }
        options = stripPrefixes(options.filter { !$0.isEmpty })
        guard options.count >= 2 else { return nil }

        let rawAnswer = d["answer"] ?? d["correct"] ?? d["correctAnswer"] ?? d["correct_answer"]
            ?? d["answerIndex"] ?? d["correct_index"] ?? d["dap_an"]
        guard let idx = answerIndex(rawAnswer, options: options) else { return nil }

        return QuizQuestion(question: text, options: options, answer: idx,
                            explanation: string(d, ["explanation", "explain", "reason", "giai_thich"]) ?? "")
    }

    private static func answerIndex(_ raw: Any?, options: [String]) -> Int? {
        let n = options.count
        func fromInt(_ i: Int) -> Int? {
            if (0..<n).contains(i) { return i }
            if i == n { return n - 1 } // AI đánh số từ 1
            return nil
        }
        switch raw {
        case let i as Int: return fromInt(i)
        case let d as Double: return fromInt(Int(d))
        case let arr as [Any]: return answerIndex(arr.first, options: options)
        case let s as String:
            let t = s.trimmed
            if let i = Int(t) { return fromInt(i) }
            if t.count == 1, let c = t.uppercased().unicodeScalars.first,
               (65...90).contains(Int(c.value)) {
                let i = Int(c.value) - 65
                return i < n ? i : nil
            }
            let clean = stripPrefixes([t]).first ?? t
            return options.firstIndex { $0.caseInsensitiveCompare(clean) == .orderedSame }
                ?? options.firstIndex { $0.caseInsensitiveCompare(t) == .orderedSame }
        default: return nil
        }
    }

    private static let prefix = try! Regex(#"^\s*(?:[A-Ha-h]|[1-8])\s*[\.\):]\s+"#)

    /// Bỏ "A. ", "B) "… nếu tất cả lựa chọn đều có.
    private static func stripPrefixes(_ options: [String]) -> [String] {
        guard !options.isEmpty, options.allSatisfy({ $0.firstMatch(of: prefix) != nil }) else { return options }
        return options.map { $0.replacing(prefix, with: "", maxReplacements: 1) }
    }

    /// Dạng chữ thường gặp:
    /// Câu 1: …  /  A. …  /  Đáp án: B  /  Giải thích: …
    private static func parsePlainText(_ text: String) -> [QuizQuestion] {
        let qRe = try! Regex(#"^(?:Câu|Cau|Question|Q)?\s*\d+\s*[\.\):]\s*(.+)$"#).ignoresCase()
        let oRe = try! Regex(#"^\*?\s*([A-Ha-h])\s*[\.\)]\s*(.+?)\s*\*?$"#)
        let aRe = try! Regex(#"^(?:Đáp án|Dap an|Answer|ĐA)\s*(?:đúng)?\s*[:：]\s*([A-Ha-h])"#).ignoresCase()
        let eRe = try! Regex(#"^(?:Giải thích|Giai thich|Explanation)\s*[:：]\s*(.+)$"#).ignoresCase()

        var result: [QuizQuestion] = []
        var cur: (q: String, opts: [String], ans: Int?, exp: String)?

        func flush() {
            if let c = cur, c.opts.count >= 2, let a = c.ans, a < c.opts.count {
                result.append(QuizQuestion(question: c.q, options: c.opts, answer: a, explanation: c.exp))
            }
            cur = nil
        }

        for line in text.split(whereSeparator: \.isNewline).map({ String($0).trimmed }) where !line.isEmpty {
            if let m = line.firstMatch(of: aRe), let s = m.output[1].substring,
               let scalar = s.uppercased().unicodeScalars.first {
                cur?.ans = Int(scalar.value) - 65
            } else if let m = line.firstMatch(of: eRe), let s = m.output[1].substring {
                cur?.exp = String(s)
            } else if cur != nil, let m = line.firstMatch(of: oRe), let s = m.output[2].substring {
                cur?.opts.append(String(s))
            } else if let m = line.firstMatch(of: qRe), let s = m.output[1].substring {
                flush()
                cur = (String(s), [], nil, "")
            }
        }
        flush()
        return result
    }
}
