import SwiftUI

// MARK: - Model

struct ClassBlock: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable { case lesson, rest }

    var id = UUID()
    var title: String
    var kind: Kind = .lesson
    /// 1 = Thứ 2 … 7 = Chủ nhật
    var weekday: Int
    /// Phút tính từ 0:00
    var start: Int
    var end: Int
    var color: Palette = .blue
    var symbol = "book.fill"
    var location = ""
    var teacher = ""
    var note = ""
    /// Nhắc trước bao nhiêu phút (nil = không nhắc)
    var reminder: Int?

    var duration: Int { end - start }
    var isRest: Bool { kind == .rest }
}

enum TT {
    static let dayNames = ["Thứ 2", "Thứ 3", "Thứ 4", "Thứ 5", "Thứ 6", "Thứ 7", "Chủ nhật"]
    static let shortDays = ["T2", "T3", "T4", "T5", "T6", "T7", "CN"]

    static func time(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }

    /// Thứ hôm nay theo quy ước 1 = Thứ 2 … 7 = Chủ nhật.
    static var today: Int { (Calendar.current.component(.weekday, from: .now) + 5) % 7 + 1 }
    static var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: .now)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Ngày cụ thể của tuần hiện tại (cho tiêu đề cột).
    static func date(of weekday: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: weekday - today, to: .now) ?? .now
    }

    static let lessonSymbols = [
        "book.fill", "function", "atom", "flask.fill", "globe.asia.australia.fill", "character.book.closed.fill",
        "paintbrush.fill", "music.note", "sportscourt.fill", "laptopcomputer", "brain.head.profile", "leaf.fill",
        "building.columns.fill", "chart.bar.fill", "text.book.closed.fill", "pencil.and.ruler.fill",
    ]
    static let restSymbols = ["cup.and.saucer.fill", "fork.knife", "bed.double.fill", "figure.walk", "gamecontroller.fill", "sun.max.fill"]
}

/// Cài đặt hiển thị (lưu trong UserDefaults).
final class TimetablePrefs: ObservableObject {
    private static let d = UserDefaults.standard
    private static func int(_ k: String, _ v: Int) -> Int { d.object(forKey: k) as? Int ?? v }

    @Published var dayStart = int("ttDayStart", 6) { didSet { Self.d.set(dayStart, forKey: "ttDayStart") } }
    @Published var dayEnd = int("ttDayEnd", 22) { didSet { Self.d.set(dayEnd, forKey: "ttDayEnd") } }
    @Published var hourHeight = d.object(forKey: "ttHourHeight") as? Double ?? 64 {
        didSet { Self.d.set(hourHeight, forKey: "ttHourHeight") }
    }
    @Published var showWeekend = d.object(forKey: "ttWeekend") as? Bool ?? true {
        didSet { Self.d.set(showWeekend, forKey: "ttWeekend") }
    }
    @Published var snap = int("ttSnap", 5) { didSet { Self.d.set(snap, forKey: "ttSnap") } }
    @Published var lessonLength = int("ttLesson", 45) { didSet { Self.d.set(lessonLength, forKey: "ttLesson") } }
    @Published var restLength = int("ttRest", 10) { didSet { Self.d.set(restLength, forKey: "ttRest") } }
    @Published var defaultReminder = int("ttReminder", 10) { didSet { Self.d.set(defaultReminder, forKey: "ttReminder") } }
}

// MARK: - Màn chính

struct TimetableView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var prefs = TimetablePrefs()
    @State private var editing: EditTarget?
    @State private var showSettings = false

    struct EditTarget: Identifiable {
        let id = UUID()
        var block: ClassBlock
        var isNew: Bool
    }

    private var days: [Int] { prefs.showWeekend ? Array(1...7) : Array(1...5) }

    var body: some View {
        VStack(spacing: 0) {
            nextUp
            Divider()
            WeekGrid(days: days, prefs: prefs,
                     onCreate: { day, minute in newBlock(kind: .lesson, day: day, minute: minute) },
                     onEdit: { editing = EditTarget(block: $0, isNew: false) })
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Thời khoá biểu")
        .navigationSubtitle("\(store.timetable.filter { !$0.isRest }.count) tiết mỗi tuần")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Tiết học", systemImage: "book.fill") { newBlock(kind: .lesson) }
                    Button("Giờ nghỉ", systemImage: "cup.and.saucer.fill") { newBlock(kind: .rest) }
                } label: {
                    Label("Thêm", systemImage: "plus")
                } primaryAction: {
                    newBlock(kind: .lesson)
                }
                .help("Thêm tiết học (nhấp đúp vào ô trống cũng được)")

                Button { showSettings.toggle() } label: {
                    Label("Tuỳ chỉnh", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { TimetableSettings(prefs: prefs) }
            }
        }
        .sheet(item: $editing) { t in
            BlockEditor(block: t.block, isNew: t.isNew, prefs: prefs)
        }
    }

    private func newBlock(kind: ClassBlock.Kind, day: Int? = nil, minute: Int? = nil) {
        let d = day ?? (days.contains(TT.today) ? TT.today : 1)
        let length = kind == .rest ? prefs.restLength : prefs.lessonLength
        // Mặc định: ngay sau khối cuối cùng của ngày đó, hoặc 7:00.
        let after = store.timetable.filter { $0.weekday == d }.map(\.end).max()
        let start = minute ?? after ?? 7 * 60
        var b = ClassBlock(title: kind == .rest ? "Giờ nghỉ" : "", kind: kind, weekday: d,
                           start: start, end: min(start + length, 24 * 60))
        if kind == .rest {
            b.color = .gray
            b.symbol = "cup.and.saucer.fill"
        } else {
            b.reminder = prefs.defaultReminder > 0 ? prefs.defaultReminder : nil
        }
        editing = EditTarget(block: b, isNew: true)
    }

    /// "Tiếp theo: Toán lúc 09:00 · phòng A2"
    @ViewBuilder
    private var nextUp: some View {
        TimelineView(.everyMinute) { _ in
            let now = TT.nowMinutes, today = TT.today
            let lessons = store.timetable.filter { !$0.isRest }
            let current = lessons.first { $0.weekday == today && $0.start <= now && now < $0.end }
            let upcoming = lessons
                .map { b -> (ClassBlock, Int) in
                    var days = (b.weekday - today + 7) % 7
                    if days == 0 && b.start <= now { days = 7 }
                    return (b, days * 1440 + b.start - now)
                }
                .min { $0.1 < $1.1 }

            HStack(spacing: 14) {
                if let c = current {
                    status("Đang học", c, tint: c.color.color, detail: "còn \(c.end - now) phút")
                }
                if let (n, wait) = upcoming {
                    status("Tiếp theo", n, tint: n.color.color,
                           detail: wait < 1440 ? (wait < 60 ? "sau \(wait) phút" : "lúc \(TT.time(n.start))")
                                               : "\(TT.dayNames[n.weekday - 1]), \(TT.time(n.start))")
                }
                if current == nil && upcoming == nil {
                    Label("Chưa có tiết nào — nhấp đúp vào lưới bên dưới để thêm.", systemImage: "calendar.badge.plus")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func status(_ label: String, _ b: ClassBlock, tint: Color, detail: String) -> some View {
        HStack(spacing: 10) {
            SymbolBadge(symbol: b.symbol, color: tint, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(b.title.isEmpty ? "Tiết học" : b.title).font(.headline)
                    Text(detail).foregroundStyle(.secondary)
                    if !b.location.isEmpty { Text("· \(b.location)").foregroundStyle(.secondary) }
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Lưới tuần

private struct WeekGrid: View {
    @EnvironmentObject private var store: Store
    let days: [Int]
    @ObservedObject var prefs: TimetablePrefs
    let onCreate: (Int, Int) -> Void
    let onEdit: (ClassBlock) -> Void

    private let gutter: CGFloat = 52
    private var hourH: CGFloat { CGFloat(prefs.hourHeight) }
    private var startMin: Int { prefs.dayStart * 60 }
    private var endMin: Int { max(prefs.dayEnd, prefs.dayStart + 1) * 60 }
    private var totalH: CGFloat { CGFloat(endMin - startMin) / 60 * hourH }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    GeometryReader { geo in
                        let colW = (geo.size.width - gutter) / CGFloat(days.count)
                        ZStack(alignment: .topLeading) {
                            hourLines(width: geo.size.width)
                            // nền từng cột (cột hôm nay tô nhẹ) + nhấp đúp để thêm
                            ForEach(Array(days.enumerated()), id: \.element) { i, d in
                                Rectangle()
                                    .fill(d == TT.today ? Color.accentColor.opacity(0.045) : Color.clear)
                                    .frame(width: colW, height: totalH)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2, coordinateSpace: .local) { p in
                                        onCreate(d, snap(startMin + Int(p.y / hourH * 60), step: 15))
                                    }
                                    .overlay(alignment: .leading) { Divider() }
                                    .offset(x: gutter + CGFloat(i) * colW)
                            }
                            ForEach(Array(days.enumerated()), id: \.element) { i, d in
                                dayBlocks(d, colIndex: i, colW: colW)
                            }
                            nowLine(colW: colW)
                        }
                    }
                    .frame(height: totalH)
                    .padding(.vertical, 10)
                    .id("grid")
                    .overlay(alignment: .topLeading) {
                        Color.clear.frame(height: 1)
                            .offset(y: max(0, CGFloat(min(TT.nowMinutes, endMin) - startMin - 90) / 60 * hourH))
                            .id("now")
                    }
                }
                .onAppear { proxy.scrollTo("now", anchor: .top) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let isToday = d == TT.today
                HStack(spacing: 6) {
                    Text(TT.shortDays[d - 1]).font(.callout.weight(.medium))
                        .foregroundStyle(isToday ? Color.red : .secondary)
                    Text(TT.date(of: d).formatted(.dateTime.day()))
                        .font(.system(size: 15, weight: isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(width: 26, height: 26)
                        .background(isToday ? Color.red : .clear, in: Circle())
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
    }

    private func hourLines(width: CGFloat) -> some View {
        ForEach(prefs.dayStart...max(prefs.dayEnd, prefs.dayStart + 1), id: \.self) { h in
            let y = CGFloat(h * 60 - startMin) / 60 * hourH
            HStack(alignment: .center, spacing: 6) {
                Text(String(format: "%02d:00", h % 24))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: gutter - 8, alignment: .trailing)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
            }
            .frame(width: width, height: 12)
            .offset(y: y - 6)
        }
    }

    @ViewBuilder
    private func nowLine(colW: CGFloat) -> some View {
        TimelineView(.everyMinute) { _ in
            let now = TT.nowMinutes
            if let i = days.firstIndex(of: TT.today), now >= startMin, now <= endMin {
                let y = CGFloat(now - startMin) / 60 * hourH
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.red).frame(width: colW, height: 2)
                    Circle().fill(Color.red).frame(width: 10, height: 10).offset(x: -5)
                }
                .offset(x: gutter + CGFloat(i) * colW, y: y - 1)
                .allowsHitTesting(false)
            }
        }
    }

    private func dayBlocks(_ d: Int, colIndex: Int, colW: CGFloat) -> some View {
        let blocks = store.timetable.filter { $0.weekday == d }
        let lanes = Self.layout(blocks)
        return ForEach(blocks) { b in
            let lane = lanes[b.id] ?? (0, 1)
            let w = (colW - 6) / CGFloat(lane.count)
            BlockView(block: b, hourH: hourH, colW: colW, snapStep: prefs.snap, days: days,
                      onEdit: { onEdit(b) })
                .frame(width: max(w - 2, 10))
                .offset(x: gutter + CGFloat(colIndex) * colW + 3 + CGFloat(lane.index) * w,
                        y: CGFloat(b.start - startMin) / 60 * hourH + 1)
        }
    }

    private func snap(_ m: Int, step: Int) -> Int { (m / step) * step }

    /// Xếp các khối trùng giờ thành nhiều làn cạnh nhau.
    static func layout(_ blocks: [ClassBlock]) -> [UUID: (index: Int, count: Int)] {
        let sorted = blocks.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var result: [UUID: (Int, Int)] = [:]
        var cluster: [(ClassBlock, Int)] = []
        var laneEnds: [Int] = []
        var clusterEnd = -1

        func flush() {
            let count = max(laneEnds.count, 1)
            for (b, lane) in cluster { result[b.id] = (lane, count) }
            cluster = []; laneEnds = []
        }
        for b in sorted {
            if b.start >= clusterEnd { flush() }
            if let lane = laneEnds.firstIndex(where: { $0 <= b.start }) {
                laneEnds[lane] = b.end
                cluster.append((b, lane))
            } else {
                laneEnds.append(b.end)
                cluster.append((b, laneEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, b.end)
        }
        flush()
        return result.mapValues { (index: $0.0, count: $0.1) }
    }
}

// MARK: - Một khối (kéo để dời, kéo mép dưới để đổi độ dài)

private struct BlockView: View {
    @EnvironmentObject private var store: Store
    let block: ClassBlock
    let hourH: CGFloat
    let colW: CGFloat
    let snapStep: Int
    let days: [Int]
    let onEdit: () -> Void

    @State private var move: CGSize = .zero
    @State private var resize: CGFloat = 0
    @State private var hovering = false

    private func minutes(_ dy: CGFloat) -> Int {
        let raw = Int((dy / hourH * 60).rounded())
        return (raw / snapStep) * snapStep
    }

    var body: some View {
        let tint = block.color.color
        let previewEnd = block.end + minutes(resize)
        let previewStart = block.start + minutes(move.height)
        let shift = previewStart - block.start

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(block.isRest ? 0.10 : 0.20))
            if block.isRest {
                Stripes().stroke(tint.opacity(0.18), lineWidth: 1)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Rectangle().fill(tint).frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: block.symbol).font(.caption2)
                    Text(block.title.isEmpty ? (block.isRest ? "Giờ nghỉ" : "Tiết học") : block.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(block.isRest ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                Text("\(TT.time(previewStart))–\(TT.time(previewEnd + shift))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !block.location.isEmpty || !block.teacher.isEmpty {
                    Text([block.location, block.teacher].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .padding(.vertical, 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(tint.opacity(hovering ? 0.7 : 0.25), lineWidth: 1)
        )
        // tay nắm đổi độ dài
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.clear)
                .frame(height: 8)
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { resize = $0.translation.height }
                        .onEnded { v in
                            let newEnd = min(max(block.end + minutes(v.translation.height), block.start + snapStep), 24 * 60)
                            store.updateBlock(block.id) { $0.end = newEnd }
                            resize = 0
                        }
                )
        }
        .frame(height: max(CGFloat(block.duration + minutes(resize)) / 60 * hourH - 2, 14), alignment: .top)
        .offset(move)
        .shadow(color: .black.opacity(move == .zero ? 0 : 0.2), radius: 8, y: 4)
        .zIndex(move == .zero && resize == 0 ? 0 : 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { move = $0.translation }
                .onEnded { v in
                    let dm = minutes(v.translation.height)
                    let dc = Int((v.translation.width / colW).rounded())
                    let idx = days.firstIndex(of: block.weekday) ?? 0
                    let newDay = days[min(max(idx + dc, 0), days.count - 1)]
                    let len = block.duration
                    let newStart = min(max(block.start + dm, 0), 24 * 60 - len)
                    withAnimation(.snappy) {
                        store.updateBlock(block.id) {
                            $0.weekday = newDay
                            $0.start = newStart
                            $0.end = newStart + len
                        }
                        move = .zero
                    }
                }
        )
        .help("Kéo để dời · kéo mép dưới để đổi độ dài · nhấp đúp để sửa")
        .contextMenu {
            Button("Sửa…", systemImage: "pencil", action: onEdit)
            Menu("Nhân bản sang") {
                ForEach(1...7, id: \.self) { d in
                    Button(TT.dayNames[d - 1]) { store.duplicateBlock(block.id, to: d) }
                }
                Divider()
                Button("Tất cả ngày trong tuần (T2–T6)") { (1...5).forEach { store.duplicateBlock(block.id, to: $0) } }
            }
            Button(block.isRest ? "Đổi thành tiết học" : "Đổi thành giờ nghỉ",
                   systemImage: block.isRest ? "book" : "cup.and.saucer") {
                store.updateBlock(block.id) {
                    $0.kind = $0.isRest ? .lesson : .rest
                    if $0.isRest { $0.color = .gray; $0.symbol = "cup.and.saucer.fill"; $0.reminder = nil }
                    else { $0.color = .blue; $0.symbol = "book.fill" }
                }
            }
            Divider()
            Button("Xoá", systemImage: "trash", role: .destructive) { store.deleteBlock(block.id) }
        }
    }
}

/// Sọc chéo cho giờ nghỉ.
private struct Stripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += 8
        }
        return p
    }
}

// MARK: - Sửa / thêm khối

private struct BlockEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var block: ClassBlock
    let isNew: Bool
    @ObservedObject var prefs: TimetablePrefs
    @State private var days: Set<Int> = []

    init(block: ClassBlock, isNew: Bool, prefs: TimetablePrefs) {
        _block = State(initialValue: block)
        _days = State(initialValue: [block.weekday])
        self.isNew = isNew
        self.prefs = prefs
    }

    private func dateBinding(_ key: WritableKeyPath<ClassBlock, Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: block[keyPath: key] / 60 % 24, minute: block[keyPath: key] % 60, second: 0, of: .now) ?? .now },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                block[keyPath: key] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var valid: Bool { block.end > block.start && !days.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: block.symbol, color: block.color.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? (block.isRest ? "Thêm giờ nghỉ" : "Thêm tiết học") : "Sửa").font(.title3.bold())
                    Text("\(TT.time(block.start)) – \(TT.time(block.end)) · \(block.duration) phút")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Picker("", selection: $block.kind) {
                    Text("Tiết học").tag(ClassBlock.Kind.lesson)
                    Text("Giờ nghỉ").tag(ClassBlock.Kind.rest)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            TextField(block.isRest ? "Tên (VD: Ra chơi, Ăn trưa)" : "Môn học (VD: Toán)", text: $block.title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            // Ngày
            VStack(alignment: .leading, spacing: 6) {
                Text(isNew ? "Ngày (chọn được nhiều ngày)" : "Ngày").font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    ForEach(1...7, id: \.self) { d in
                        Button(TT.shortDays[d - 1]) {
                            if isNew {
                                if days.contains(d) { days.remove(d) } else { days.insert(d) }
                            } else { days = [d] }
                        }
                        .buttonStyle(ChipStyle(tint: block.color.color, active: days.contains(d)))
                    }
                }
            }

            // Giờ
            HStack(spacing: 16) {
                DatePicker("Bắt đầu", selection: dateBinding(\.start), displayedComponents: .hourAndMinute)
                DatePicker("Kết thúc", selection: dateBinding(\.end), displayedComponents: .hourAndMinute)
            }
            HStack(spacing: 6) {
                Text("Độ dài").font(.callout).foregroundStyle(.secondary)
                ForEach(block.isRest ? [5, 10, 15, 20, 30, 60] : [30, 35, 40, 45, 50, 60, 90], id: \.self) { m in
                    Button("\(m)′") { block.end = min(block.start + m, 24 * 60) }
                        .buttonStyle(ChipStyle(tint: block.color.color, active: block.duration == m))
                }
            }

            // Màu & biểu tượng
            HStack(spacing: 8) {
                ForEach(Palette.allCases) { p in
                    Circle().fill(p.color.gradient).frame(width: 20, height: 20)
                        .overlay { if p == block.color { Circle().strokeBorder(.white, lineWidth: 2).padding(2) } }
                        .onTapGesture { block.color = p }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 6), count: 11), alignment: .leading, spacing: 6) {
                ForEach(block.isRest ? TT.restSymbols : TT.lessonSymbols, id: \.self) { s in
                    Image(systemName: s)
                        .font(.system(size: 13))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(s == block.symbol ? .white : .secondary)
                        .background(Circle().fill(s == block.symbol ? AnyShapeStyle(block.color.color.gradient)
                                                                    : AnyShapeStyle(.quaternary.opacity(0.6))))
                        .onTapGesture { block.symbol = s }
                }
            }

            if !block.isRest {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        TextField("Phòng học", text: $block.location).textFieldStyle(.roundedBorder)
                        TextField("Giáo viên", text: $block.teacher).textFieldStyle(.roundedBorder)
                    }
                }
                Picker("Nhắc trước", selection: $block.reminder) {
                    Text("Không nhắc").tag(Int?.none)
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) phút").tag(Int?.some($0)) }
                }
                .fixedSize()
            }
            TextField("Ghi chú", text: $block.note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            HStack {
                if !isNew {
                    Button("Xoá", role: .destructive) {
                        store.deleteBlock(block.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Huỷ") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Thêm" : "Lưu") {
                    store.saveBlock(block, days: days.sorted(), isNew: isNew)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: block.kind) { _, k in
            if k == .rest {
                if block.title.isEmpty { block.title = "Giờ nghỉ" }
                block.color = .gray; block.symbol = "cup.and.saucer.fill"; block.reminder = nil
            } else {
                if block.title == "Giờ nghỉ" { block.title = "" }
                block.color = .blue; block.symbol = "book.fill"
            }
        }
    }
}

// MARK: - Tuỳ chỉnh

private struct TimetableSettings: View {
    @EnvironmentObject private var store: Store
    @ObservedObject var prefs: TimetablePrefs
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Hiển thị") {
                Stepper("Bắt đầu ngày: \(prefs.dayStart):00", value: $prefs.dayStart, in: 0...(prefs.dayEnd - 1))
                Stepper("Kết thúc ngày: \(prefs.dayEnd):00", value: $prefs.dayEnd, in: (prefs.dayStart + 1)...24)
                LabeledContent("Phóng to") {
                    Slider(value: $prefs.hourHeight, in: 36...140).frame(width: 150)
                }
                Toggle("Hiện Thứ 7 & Chủ nhật", isOn: $prefs.showWeekend)
            }
            Section("Khi thêm & kéo thả") {
                Picker("Bước kéo thả", selection: $prefs.snap) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) phút").tag($0) }
                }
                Stepper("Tiết học mặc định: \(prefs.lessonLength) phút", value: $prefs.lessonLength, in: 15...180, step: 5)
                Stepper("Giờ nghỉ mặc định: \(prefs.restLength) phút", value: $prefs.restLength, in: 5...120, step: 5)
                Picker("Nhắc trước (mặc định)", selection: $prefs.defaultReminder) {
                    Text("Không nhắc").tag(0)
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) phút").tag($0) }
                }
            }
            Section {
                Button("Xoá toàn bộ thời khoá biểu…", role: .destructive) { confirmClear = true }
                    .disabled(store.timetable.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360, height: 470)
        .confirmationDialog("Xoá toàn bộ thời khoá biểu?", isPresented: $confirmClear) {
            Button("Xoá tất cả", role: .destructive) { store.timetable = [] }
        } message: {
            Text("Mọi tiết học và giờ nghỉ sẽ bị xoá.")
        }
    }
}
