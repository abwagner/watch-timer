import SwiftUI
import UserNotifications
import WatchKit

@main
struct DialTimerApp: App {
    @WKApplicationDelegateAdaptor(TimerDelegate.self) private var delegate
    var body: some Scene { WindowGroup { TimerScreen() } }
}

final class TimerDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let stop = UNNotificationAction(identifier: "stop", title: "Stop", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "countdown", actions: [stop], intentIdentifiers: [])
        ])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // A lowered wrist may leave the app frontmost but inactive. Preserve the
        // system alert there; only the active screen supplies repeating haptics.
        await MainActor.run {
            WKApplication.shared().applicationState == .active ? [] : [.banner, .sound]
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "stop",
              let id = TimerReminder.timerID(from: response.notification.request.identifier) else { return }
        await MainActor.run { TimerStore.shared.remove(id: id) }
    }
}

@MainActor
final class TimerStore: ObservableObject {
    static let shared = TimerStore()
    @Published private(set) var state: TimerState
    @Published var alertProblem: String?
    private let defaults: UserDefaults
    private var completionAlert = CompletionAlert()
    private var schedulingTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = TimerState.restore(from: defaults)
        persist()
        if defaults.double(forKey: "timerDeadline") > 0 {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["timer"])
            defaults.removeObject(forKey: "timerDeadline")
        }
        refreshNotifications()
    }

    func start(minutes: Int) {
        // Leave headroom below the pending local-notification limit.
        guard state.timers.count < 32 else {
            alertProblem = "Stop a timer before adding another. You can run up to 32 timers."
            return
        }
        state.start(minutes: minutes)
        persist()
        WKInterfaceDevice.current().play(.start)
        refreshNotifications()
    }

    func remove(id: UUID) {
        state.remove(id: id)
        persist()
        let center = UNUserNotificationCenter.current()
        let identifiers = TimerReminder.identifiers(for: id)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        refreshNotifications()
        updateHaptics(at: .now, active: WKApplication.shared().applicationState == .active)
    }

    func updateHaptics(at date: Date, active: Bool) {
        let expiredIDs = Set(state.expired(at: date).map(\.id))
        if let pulse = completionAlert.pulse(at: date, expiredIDs: expiredIDs, active: active) {
            WKInterfaceDevice.current().play(pulse == .gentle ? .notification : .retry)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "countdowns") }
    }

    private func refreshNotifications() {
        let previous = schedulingTask
        previous?.cancel()
        schedulingTask = Task { @MainActor [weak self] in
            // Serialize replacements so an in-flight add cannot resurrect a
            // stopped timer or remove a newer batch using the same identifiers.
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            await self.scheduleNotifications()
        }
    }

    private func scheduleNotifications() async {
        let center = UNUserNotificationCenter.current()
        let timers = state.timers
        let reminders = TimerReminder.plan(timers: timers, at: .now)
        let expectedIDs = Set(reminders.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        let staleIDs = pending.map(\.identifier).filter { !expectedIDs.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: staleIDs)
        guard !reminders.isEmpty else { return }
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            guard !Task.isCancelled else { return }
            guard allowed else {
                alertProblem = "Enable Dial Timer notifications in Settings to receive completion alerts after leaving the app."
                return
            }
            for reminder in reminders {
                guard !Task.isCancelled else { return }
                guard let timer = timers.first(where: { $0.id == reminder.timerID }) else { continue }
                let seconds = reminder.date.timeIntervalSinceNow
                guard seconds > 0 else { continue }
                let content = UNMutableNotificationContent()
                content.title = "Time’s up"
                content.body = "Your \(Int(timer.duration / 60))-minute timer has finished. Tap Stop to end reminders."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                content.categoryIdentifier = "countdown"
                content.threadIdentifier = timer.id.uuidString
                let request = UNNotificationRequest(identifier: reminder.identifier, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false))
                try await center.add(request)
                if Task.isCancelled {
                    center.removePendingNotificationRequests(withIdentifiers: [reminder.identifier])
                    return
                }
            }
            let accepted = await center.pendingNotificationRequests()
            guard !Task.isCancelled else { return }
            let acceptedIDs = Set(accepted.map(\.identifier))
            let futureIDs = Set(reminders.filter { $0.date.timeIntervalSinceNow > 2 }.map(\.identifier))
            if !futureIDs.isSubset(of: acceptedIDs) {
                alertProblem = "The watch could not schedule every reminder. Some timers may have fewer repeat alerts."
            }
        } catch {
            guard !Task.isCancelled else { return }
            alertProblem = "The completion alerts could not be scheduled. \(error.localizedDescription)"
        }
    }
}

struct TimerScreen: View {
    @ObservedObject private var store = TimerStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("presetMinutes") private var preset = 4
    @State private var addingTimer = false
    @State private var editingPreset = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            GeometryReader { geometry in
                ZStack(alignment: .bottomTrailing) {
                    if store.state.timers.isEmpty || addingTimer {
                        DurationDial(preset: preset, editPreset: { editingPreset = true }) { minutes in
                            store.start(minutes: minutes)
                            addingTimer = false
                        }
                        .overlay(alignment: .topLeading) {
                            if addingTimer {
                                cornerButton("chevron.left", label: "Back to timers") { addingTimer = false }
                                    .offset(x: 4, y: -28)
                            }
                        }
                    } else if store.state.timers.count == 1, let timer = store.state.timers.first {
                        SingleCountdown(timer: timer, date: context.date) { store.remove(id: timer.id) }
                    } else {
                        ScrollView {
                            VStack(spacing: 8) {
                                ForEach(store.state.timers) { timer in
                                    TimerBar(timer: timer, date: context.date) { store.remove(id: timer.id) }
                                }
                            }
                            .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                        .padding(.bottom, 40)
                    }
                    if !addingTimer && !store.state.timers.isEmpty {
                        cornerButton("plus", label: "Add timer", diameter: 24) { addingTimer = true }
                            .offset(y: 14)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else {
                store.updateHaptics(at: .now, active: false)
                return
            }
            while !Task.isCancelled {
                store.updateHaptics(at: .now, active: scenePhase == .active)
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
            }
        }
        .sheet(isPresented: $editingPreset) {
            VStack {
                Text("Quick timer").font(.headline)
                Picker("Minutes", selection: $preset) {
                    ForEach(1...60, id: \.self) { Text("\($0) min").tag($0) }
                }.labelsHidden()
                Button("Done") { editingPreset = false }
            }
        }
        .alert("Timer alerts", isPresented: Binding(
            get: { store.alertProblem != nil },
            set: { if !$0 { store.alertProblem = nil } }
        )) {
            Button("OK", role: .cancel) { store.alertProblem = nil }
        } message: { Text(store.alertProblem ?? "") }
    }

    private func cornerButton(_ symbol: String, label: String, diameter: CGFloat = 36,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: diameter * 0.53, weight: .semibold))
                .frame(width: diameter, height: diameter).background(.black, in: Circle())
                .overlay(Circle().stroke(.orange.opacity(0.55), lineWidth: 1))
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.orange).accessibilityLabel(label)
    }
}

private struct SingleCountdown: View {
    let timer: Countdown
    let date: Date
    let stop: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width - 14, geometry.size.height + 24)
            let remaining = timer.remaining(at: date)
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 9)
                Circle().trim(from: 0, to: timer.progress(at: date))
                    .stroke(.orange, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Countdown.displayTime(remaining))
                    .font(.system(size: 68, weight: .medium, design: .rounded))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
                    .frame(width: side - 22)
                    .accessibilityLabel("\(Countdown.displayTime(remaining)) remaining")
                VStack(spacing: 0) {
                    Button(remaining > 0 ? "Cancel" : "Stop", action: stop)
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.plain).frame(minHeight: 34)
                    if remaining == 0 {
                        Text("TIME’S UP").font(.system(size: 11, weight: .bold))
                    }
                }
                .offset(y: side * 0.29)
            }
            .foregroundStyle(.orange)
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

private struct TimerBar: View {
    let timer: Countdown
    let date: Date
    let stop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(timer.remaining(at: date) == 0 ? "TIME’S UP" : "\(Int(timer.duration / 60)) MIN")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    Text(Countdown.displayTime(timer.remaining(at: date)))
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 4)
                Button(action: stop) {
                    Image(systemName: timer.remaining(at: date) == 0 ? "stop.fill" : "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36).background(.orange.opacity(0.15), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop \(Int(timer.duration / 60)) minute timer")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(.orange).frame(width: geometry.size.width * timer.progress(at: date))
                }
            }.frame(height: 8)
        }
        .foregroundStyle(.orange)
    }
}

private struct DurationDial: View {
    let preset: Int
    let editPreset: () -> Void
    let start: (Int) -> Void
    @State private var selection = 4
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width - 16, geometry.size.height + 20)
            let radius = side / 2
            let ringWidth: CGFloat = 12
            let markerDiameter = ringWidth + 2
            let minutes = dragging ? selection : preset
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: ringWidth)
                    .frame(width: side, height: side)
                Circle().trim(from: 0, to: Double(minutes) / 60)
                    .stroke(.orange, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(-90))
                ForEach([5, 10, 15, 30, 45], id: \.self) { minute in
                    let angle = Double(minute) / 60 * 2 * Double.pi
                    Circle().fill(.white).frame(width: markerDiameter, height: markerDiameter)
                        .offset(x: sin(angle) * radius, y: -cos(angle) * radius)
                    Text("\(minute)").font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .offset(x: sin(angle) * (radius - 24), y: -cos(angle) * (radius - 24))
                }
                Circle().fill(.white).frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.orange, lineWidth: 2))
                    .offset(y: -radius).rotationEffect(.degrees(Double(minutes) * 6))
                RingTouchTarget(innerRatio: max(0, (radius - 30) / (radius + 6)))
                    .fill(.clear).frame(width: side + 12, height: side + 12)
                    .contentShape(RingTouchTarget(innerRatio: max(0, (radius - 30) / (radius + 6))))
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragging = true
                            let touchRadius = (side + 12) / 2
                            let angle = atan2(value.location.x - touchRadius, -(value.location.y - touchRadius))
                            let fraction = (angle < 0 ? angle + 2 * .pi : angle) / (2 * .pi)
                            let next = min(60, max(1, Int((fraction * 60).rounded())))
                            if next != selection { WKInterfaceDevice.current().play(.click) }
                            selection = next
                        }
                        .onEnded { _ in
                            guard dragging else { return }
                            dragging = false
                            start(selection)
                        })
                    .accessibilityLabel("Timer duration dial")
                    .accessibilityValue("\(minutes) minutes")
                    .accessibilityAdjustableAction { direction in
                        selection = min(60, max(1, minutes + (direction == .increment ? 1 : -1)))
                        dragging = true
                    }
                    .accessibilityAction(named: Text("Start selected timer")) { start(minutes) }
                Button { start(minutes) } label: {
                    VStack(spacing: 0) {
                        Text("\(minutes)").font(.system(size: 46, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("MIN").font(.system(size: 10, weight: .bold))
                    }
                    .frame(width: max(60, side - 76), height: max(60, side - 76))
                    .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .highPriorityGesture(LongPressGesture(minimumDuration: 0.6)
                    .exclusively(before: TapGesture()).onEnded { gesture in
                        switch gesture {
                        case .first: editPreset()
                        case .second: start(minutes)
                        }
                    })
                .accessibilityLabel("Start \(minutes) minute timer")
                .accessibilityAction(named: Text("Edit preset"), editPreset)
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

// Keep ring drags separate from the center button's tap and long press.
private struct RingTouchTarget: Shape {
    let innerRatio: Double
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()
        path.addPath(Path { inner in
            inner.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2 * innerRatio,
                         startAngle: .degrees(0), endAngle: .degrees(360), clockwise: true)
            inner.closeSubpath()
        })
        return path
    }
}
