import Foundation

@main
struct TimerStateTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = TimerState()
        let short = state.start(minutes: 1, at: now)
        let long = state.start(minutes: 60, at: now)
        precondition(short.id != long.id)
        precondition(state.timers.count == 2)
        precondition(abs(short.remaining(at: now.addingTimeInterval(12.1)) - 47.9) < 0.001,
                     "Deadlines must remain independent")
        precondition(long.remaining(at: now.addingTimeInterval(60)) == 3540)
        precondition(Countdown.displayTime(59.1) == "1:00", "Round partial seconds up")
        precondition(Countdown.displayTime(3600) == "60:00", "An hour must fit without truncation")
        precondition(Countdown.displayTime(-5) == "0:00")
        precondition(state.expired(at: now.addingTimeInterval(60)).map(\.id) == [short.id])
        precondition(short.progress(at: now.addingTimeInterval(300)) == 0)
        precondition(short.progress(at: now.addingTimeInterval(-10)) == 1)
        let restored = try JSONDecoder().decode(TimerState.self, from: JSONEncoder().encode(state))
        precondition(restored == state, "Relaunch must preserve IDs, deadlines, and completed timers")
        state.remove(id: short.id)
        precondition(state.timers == [long], "Stopping one timer must leave the other unchanged")
        state.remove(id: short.id)
        precondition(state.timers == [long], "Repeated Stop actions must be safe")

        let suite = "DialTimerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Date.now.addingTimeInterval(120).timeIntervalSince1970, forKey: "timerDeadline")
        defaults.set(240.0, forKey: "timerDuration")
        let migrated = TimerState.restore(from: defaults)
        precondition(migrated.timers.count == 1 && migrated.timers[0].duration == 240)
        defaults.set(try JSONEncoder().encode(state), forKey: "countdowns")
        precondition(TimerState.restore(from: defaults) == state,
                     "New state must take precedence over the legacy timer")
        defaults.set(try JSONEncoder().encode(TimerState()), forKey: "countdowns")
        precondition(TimerState.restore(from: defaults).timers.isEmpty,
                     "Removing the last timer must not resurrect the legacy timer")

        var alert = CompletionAlert()
        let ids: Set<UUID> = [short.id]
        precondition(alert.pulse(at: now, expiredIDs: ids, active: true) == .gentle)
        precondition(alert.pulse(at: now.addingTimeInterval(2), expiredIDs: ids, active: true) == nil)
        precondition(alert.pulse(at: now.addingTimeInterval(3), expiredIDs: ids, active: true) == .gentle)
        precondition(alert.pulse(at: now.addingTimeInterval(6), expiredIDs: ids, active: true) == .urgent)
        precondition(alert.pulse(at: now.addingTimeInterval(7), expiredIDs: ids, active: true) == nil)
        precondition(alert.pulse(at: now.addingTimeInterval(7.5), expiredIDs: ids, active: true) == .urgent)
        precondition(alert.pulse(at: now.addingTimeInterval(15), expiredIDs: ids, active: true) == .urgent)
        precondition(alert.pulse(at: now.addingTimeInterval(15.9), expiredIDs: ids, active: true) == .urgent)
        precondition(alert.pulse(at: now.addingTimeInterval(16), expiredIDs: ids, active: false) == nil,
                     "Haptics must stop when leaving the active app")
        precondition(alert.pulse(at: now.addingTimeInterval(17), expiredIDs: ids, active: true) == .gentle)
        precondition(alert.pulse(at: now.addingTimeInterval(18), expiredIDs: [], active: true) == nil)
        precondition(alert.pulse(at: now.addingTimeInterval(19), expiredIDs: [long.id], active: true) == .gentle)
        let batch = TimerReminder.plan(timers: [short], at: now)
        precondition(batch.count == 13, "Alert at expiry plus twelve ten-second follow-ups")
        precondition(batch.first?.date == short.deadline)
        precondition(batch.last?.date == short.deadline.addingTimeInterval(120))
        precondition(Set(batch.map(\.identifier)).count == 13)
        precondition(batch.allSatisfy { TimerReminder.timerID(from: $0.identifier) == short.id },
                     "Stop from any follow-up must identify the same timer")
        precondition(Set(TimerReminder.identifiers(for: short.id)) == Set(batch.map(\.identifier)),
                     "Stop must cancel the entire batch, including the original notification")
        let resumed = TimerReminder.plan(timers: [short], at: short.deadline.addingTimeInterval(25))
        precondition(resumed.first?.step == 3 && resumed.last?.step == 12,
                     "Relaunch must keep the original expiry window without replaying past alerts")
        precondition(TimerReminder.plan(timers: [short], at: short.deadline.addingTimeInterval(121)).isEmpty)
        let four = (0..<4).map { _ in Countdown(duration: 60, startedAt: now) }
        precondition(TimerReminder.plan(timers: four, at: now).count == 52)
        let many = (0..<32).map { _ in Countdown(duration: 60, startedAt: now) }
        let shared = TimerReminder.plan(timers: many, at: now)
        precondition(shared.count == 60, "Never exceed the shared notification budget")
        precondition(shared.filter { $0.step == 0 }.count == 32,
                     "Every timer gets its initial alert before any extra reminders")
        let afterStop = TimerReminder.plan(timers: [long], at: now)
        precondition(afterStop.allSatisfy { $0.timerID == long.id }, "Stopping one timer cannot affect another's IDs")
        print("Timer checks passed, including repeat cadence, Stop identifiers, shared capacity, and relaunch window")
    }
}
