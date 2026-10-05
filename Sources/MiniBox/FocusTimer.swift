import AppKit
import SwiftUI

@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: String, CaseIterable, Identifiable {
        case focus, shortBreak, longBreak

        var id: String { rawValue }

        var title: String {
            switch self {
            case .focus: "Tập trung"
            case .shortBreak: "Nghỉ ngắn"
            case .longBreak: "Nghỉ dài"
            }
        }

        var symbol: String {
            switch self {
            case .focus: "brain.head.profile"
            case .shortBreak: "cup.and.saucer.fill"
            case .longBreak: "figure.walk"
            }
        }

        var color: Color {
            switch self {
            case .focus: .playBlue
            case .shortBreak: .mint
            case .longBreak: .indigo
            }
        }
    }

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var remaining: TimeInterval = 25 * 60
    @Published private(set) var isRunning = false
    @Published private(set) var cycle = 0
    @Published private(set) var sessionsToday = 0
    @Published private(set) var minutesToday = 0
    @Published var linkedNoteID: UUID?

    @Published var focusLength: Int { didSet { settingChanged("focusLength", focusLength) } }
    @Published var shortLength: Int { didSet { settingChanged("shortLength", shortLength) } }
    @Published var longLength: Int { didSet { settingChanged("longLength", longLength) } }
    @Published var sessionsBeforeLong: Int { didSet { settingChanged("sessionsBeforeLong", sessionsBeforeLong) } }
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "autoStart") } }
    @Published var playSound: Bool { didSet { defaults.set(playSound, forKey: "playSound") } }

    private let defaults = UserDefaults.standard
    private var endDate: Date?
    private var ticker: Timer?
    private var activity: NSObjectProtocol?

    init() {
        func int(_ key: String, _ fallback: Int) -> Int {
            let v = UserDefaults.standard.integer(forKey: key)
            return v > 0 ? v : fallback
        }
        focusLength = int("focusLength", 25)
        shortLength = int("shortLength", 5)
        longLength = int("longLength", 15)
        sessionsBeforeLong = int("sessionsBeforeLong", 4)
        autoStart = defaults.bool(forKey: "autoStart")
        playSound = defaults.object(forKey: "playSound") as? Bool ?? true
        remaining = TimeInterval(focusLength * 60)
        loadStats()
    }

    // MARK: Derived

    var duration: TimeInterval { TimeInterval(minutes(for: phase) * 60) }
    var progress: Double { duration > 0 ? 1 - remaining / duration : 0 }

    var timeString: String {
        let s = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    func minutes(for phase: Phase) -> Int {
        switch phase {
        case .focus: focusLength
        case .shortBreak: shortLength
        case .longBreak: longLength
        }
    }

    // MARK: Controls

    func toggle() { isRunning ? pause() : start() }

    func start() {
        guard !isRunning else { return }
        if remaining <= 0 { remaining = duration }
        endDate = Date().addingTimeInterval(remaining)
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Pomodoro")

        let next = nextPhase(afterCompleting: phase)
        Notifier.shared.scheduleFocusEnd(
            after: remaining,
            title: phase == .focus ? "Hết phiên tập trung" : "Hết giờ nghỉ",
            body: phase == .focus
                ? "Tuyệt! \(next.title) \(minutes(for: next)) phút nhé."
                : "Quay lại tập trung \(focusLength) phút nào.")

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        guard isRunning else { return }
        if let endDate { remaining = max(0, endDate.timeIntervalSinceNow) }
        stopTicking()
        Notifier.shared.cancelFocus()
    }

    func reset() {
        pause()
        remaining = duration
    }

    func skip() { finish(completed: false) }

    func switchTo(_ newPhase: Phase) {
        pause()
        phase = newPhase
        remaining = duration
    }

    // MARK: Internals

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining == 0 { finish(completed: true) }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        isRunning = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func finish(completed: Bool) {
        stopTicking()
        Notifier.shared.cancelFocus()
        let finished = phase

        if finished == .focus {
            if completed {
                rollStatsIfNeeded()
                sessionsToday += 1
                minutesToday += focusLength
                saveStats()
            }
            cycle += 1
        } else if finished == .longBreak {
            cycle = 0
        }
        if completed, playSound { NSSound(named: "Glass")?.play() }

        phase = nextPhase(afterCompleting: finished)
        remaining = duration
        if completed, autoStart { start() }
    }

    private func nextPhase(afterCompleting p: Phase) -> Phase {
        guard p == .focus else { return .focus }
        return (cycle + 1) % sessionsBeforeLong == 0 ? .longBreak : .shortBreak
    }

    private func settingChanged(_ key: String, _ value: Int) {
        defaults.set(value, forKey: key)
        if !isRunning { remaining = duration }
    }

    // MARK: Daily stats

    private var todayKey: String { Date().formatted(.iso8601.year().month().day()) }

    private func loadStats() {
        guard defaults.string(forKey: "statsDay") == todayKey else { return }
        sessionsToday = defaults.integer(forKey: "statsSessions")
        minutesToday = defaults.integer(forKey: "statsMinutes")
    }

    private func rollStatsIfNeeded() {
        if defaults.string(forKey: "statsDay") != todayKey {
            sessionsToday = 0
            minutesToday = 0
        }
    }

    private func saveStats() {
        defaults.set(todayKey, forKey: "statsDay")
        defaults.set(sessionsToday, forKey: "statsSessions")
        defaults.set(minutesToday, forKey: "statsMinutes")
    }
}
