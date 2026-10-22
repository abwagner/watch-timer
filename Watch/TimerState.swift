import Foundation

struct Countdown: Codable, Identifiable, Equatable {
    let id: UUID
    let duration: TimeInterval
    let deadline: Date

    init(id: UUID = UUID(), duration: TimeInterval, startedAt: Date = .now) {
        self.id = id
        self.duration = duration
        deadline = startedAt.addingTimeInterval(duration)
    }

    func remaining(at date: Date) -> TimeInterval { max(0, deadline.timeIntervalSince(date)) }
    func progress(at date: Date) -> Double { min(1, remaining(at: date) / max(1, duration)) }

    static func displayTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TimerState: Codable, Equatable {
    var timers: [Countdown] = []

    @discardableResult
    mutating func start(minutes: Int, at date: Date = .now) -> Countdown {
        let timer = Countdown(duration: Double(min(60, max(1, minutes)) * 60), startedAt: date)
        timers.append(timer)
        return timer
    }

    mutating func remove(id: UUID) { timers.removeAll { $0.id == id } }
    func expired(at date: Date) -> [Countdown] { timers.filter { $0.deadline <= date } }

    // Preserve the original single timer when upgrading to multiple timers.
    static func restore(from defaults: UserDefaults) -> TimerState {
        if let data = defaults.data(forKey: "countdowns"),
           let state = try? JSONDecoder().decode(TimerState.self, from: data) { return state }
        let deadline = defaults.double(forKey: "timerDeadline")
        guard deadline > Date.now.timeIntervalSince1970 else { return TimerState() }
        let duration = max(1, defaults.double(forKey: "timerDuration"))
        return TimerState(timers: [Countdown(duration: duration,
            startedAt: Date(timeIntervalSince1970: deadline - duration))])
    }
}

struct CompletionAlert {
    enum Pulse { case gentle, urgent }
    private var began: Date?
    private var lastPulse = Date.distantPast
    private var previousIDs: Set<UUID> = []

    mutating func pulse(at date: Date, expiredIDs: Set<UUID>, active: Bool) -> Pulse? {
        guard active, !expiredIDs.isEmpty else {
            began = nil
            previousIDs = []
            return nil
        }
        if began == nil || !expiredIDs.subtracting(previousIDs).isEmpty {
            began = date
            lastPulse = .distantPast
        }
        previousIDs = expiredIDs
        let elapsed = date.timeIntervalSince(began ?? date)
        let interval = elapsed < 6 ? 3.0 : elapsed < 15 ? 1.5 : 0.8
        guard date.timeIntervalSince(lastPulse) >= interval else { return nil }
        lastPulse = date
        return elapsed < 6 ? .gentle : .urgent
    }
}

struct TimerReminder: Equatable {
    let timerID: UUID
    let step: Int
    let date: Date

    var identifier: String { Self.identifier(timerID: timerID, step: step) }

    static func identifier(timerID: UUID, step: Int) -> String {
        step == 0 ? timerID.uuidString : "\(timerID.uuidString):\(step)"
    }

    static func identifiers(for timerID: UUID) -> [String] {
        (0...12).map { identifier(timerID: timerID, step: $0) }
    }

    static func timerID(from identifier: String) -> UUID? {
        identifier.split(separator: ":").first.flatMap { UUID(uuidString: String($0)) }
    }

    // Reserve every timer's first alert before sharing remaining slots among
    // follow-ups. Four simultaneous timers get the full two-minute window.
    static func plan(timers: [Countdown], at date: Date, budget: Int = 60) -> [TimerReminder] {
        let ordered = timers.sorted { $0.deadline < $1.deadline }
        var result: [TimerReminder] = []
        for step in 0...12 {
            for timer in ordered {
                guard result.count < budget else { return result }
                let fireDate = timer.deadline.addingTimeInterval(Double(step * 10))
                if fireDate > date {
                    result.append(TimerReminder(timerID: timer.id, step: step, date: fireDate))
                }
            }
        }
        return result
    }
}
