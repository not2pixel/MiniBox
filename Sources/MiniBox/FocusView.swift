import SwiftUI

struct FocusView: View {
    @EnvironmentObject private var timer: FocusTimer
    @EnvironmentObject private var store: Store
    @State private var showSettings = false

    private var tint: Color { timer.phase.color }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Picker("Chế độ", selection: Binding(get: { timer.phase }, set: { timer.switchTo($0) })) {
                    ForEach(FocusTimer.Phase.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                ring
                controls
                cycleDots
                taskCard
                stats
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [tint.opacity(0.14), .clear], startPoint: .top, endPoint: .center)
                .animation(.smooth, value: timer.phase)
        )
        .navigationTitle("Tập trung")
        .navigationSubtitle(timer.isRunning ? "Đang chạy · \(timer.phase.title)" : "Pomodoro")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings.toggle() } label: {
                    Label("Tuỳ chỉnh", systemImage: "slider.horizontal.3")
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { FocusSettings() }
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: 14)
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: timer.progress)

            VStack(spacing: 6) {
                Image(systemName: timer.phase.symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: timer.isRunning)
                Text(timer.timeString)
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: timer.timeString)
                Text(timer.phase.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 280, height: 280)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            roundButton("arrow.counterclockwise", help: "Đặt lại") { timer.reset() }

            Button { timer.toggle() } label: {
                Image(systemName: timer.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 76, height: 76)
                    .background(tint.gradient, in: Circle())
                    .shadow(color: tint.opacity(0.45), radius: 12, y: 5)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help(timer.isRunning ? "Tạm dừng (Space)" : "Bắt đầu (Space)")

            roundButton("forward.end.fill", help: "Bỏ qua") { timer.skip() }
        }
    }

    private func roundButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var cycleDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<timer.sessionsBeforeLong, id: \.self) { i in
                Circle()
                    .fill(i < timer.cycle % timer.sessionsBeforeLong || (timer.phase == .longBreak) ? AnyShapeStyle(Color.playBlue) : AnyShapeStyle(.quaternary))
                    .frame(width: 8, height: 8)
            }
        }
        .help("Số phiên trước khi nghỉ dài")
    }

    private var taskCard: some View {
        let linked = store.notes.first { $0.id == timer.linkedNoteID && !$0.isDone }
        return HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.title3)
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Đang làm").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Button("Không chọn") { timer.linkedNoteID = nil }
                    Divider()
                    ForEach(store.openNotes.prefix(30)) { n in
                        Button(n.displayTitle) { timer.linkedNoteID = n.id }
                    }
                } label: {
                    Text(linked?.displayTitle ?? "Chọn một việc cần tập trung…")
                        .font(.headline)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Spacer()

            if let linked {
                Button {
                    store.toggleDone(linked.id)
                    timer.linkedNoteID = nil
                } label: {
                    Label("Xong", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var stats: some View {
        HStack(spacing: 12) {
            StatCard(value: "\(timer.sessionsToday)", label: "Phiên hôm nay", symbol: "flame.fill", color: .orange)
            StatCard(value: "\(timer.minutesToday)", label: "Phút tập trung", symbol: "hourglass", color: .playBlue)
        }
        .frame(maxWidth: 420)
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: symbol, color: color, size: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct FocusSettings: View {
    @EnvironmentObject private var timer: FocusTimer

    var body: some View {
        Form {
            Section("Thời lượng (phút)") {
                Stepper("Tập trung: \(timer.focusLength)", value: $timer.focusLength, in: 1...180)
                Stepper("Nghỉ ngắn: \(timer.shortLength)", value: $timer.shortLength, in: 1...60)
                Stepper("Nghỉ dài: \(timer.longLength)", value: $timer.longLength, in: 1...90)
                Stepper("Nghỉ dài sau \(timer.sessionsBeforeLong) phiên", value: $timer.sessionsBeforeLong, in: 2...10)
            }
            Section {
                Toggle("Tự chuyển phiên tiếp theo", isOn: $timer.autoStart)
                Toggle("Phát âm thanh khi hết giờ", isOn: $timer.playSound)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320, height: 330)
    }
}
