import SwiftUI
import WidgetKit

struct TimerEntry: TimelineEntry { let date: Date }
struct TimerProvider: TimelineProvider {
    func placeholder(in context: Context) -> TimerEntry { TimerEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (TimerEntry) -> Void) {
        completion(TimerEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TimerEntry>) -> Void) {
        completion(Timeline(entries: [TimerEntry(date: .now)], policy: .never))
    }
}

struct TimerComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Image(systemName: "stopwatch")
            case .accessoryRectangular:
                StopwatchSymbol().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                StopwatchSymbol().padding(3)
            }
        }
        .foregroundStyle(.orange)
        .containerBackground(.black, for: .widget)
        .accessibilityLabel("Open Dial Timer")
    }
}

@main
struct TimerComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DialTimer", provider: TimerProvider()) { _ in
            TimerComplicationView()
        }
        .configurationDisplayName("Dial Timer")
        .description("Open your timer dial.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// Round stopwatch, one hand, and three flat plunger caps. No visible text.
private struct StopwatchSymbol: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            Path { path in
                path.addEllipse(in: CGRect(x: size * 0.16, y: size * 0.28, width: size * 0.68, height: size * 0.68))
                path.move(to: CGPoint(x: size * 0.5, y: size * 0.28))
                path.addLine(to: CGPoint(x: size * 0.5, y: size * 0.12))
                path.move(to: CGPoint(x: size * 0.25, y: size * 0.38))
                path.addLine(to: CGPoint(x: size * 0.16, y: size * 0.27))
                path.move(to: CGPoint(x: size * 0.75, y: size * 0.38))
                path.addLine(to: CGPoint(x: size * 0.84, y: size * 0.27))
                path.move(to: CGPoint(x: size * 0.5, y: size * 0.62))
                path.addLine(to: CGPoint(x: size * 0.62, y: size * 0.47))
            }
            .stroke(style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
            .frame(width: geometry.size.width, height: geometry.size.height)
            Path { path in
                path.move(to: CGPoint(x: size * 0.39, y: size * 0.10))
                path.addLine(to: CGPoint(x: size * 0.61, y: size * 0.10))
                path.move(to: CGPoint(x: size * 0.10, y: size * 0.32))
                path.addLine(to: CGPoint(x: size * 0.22, y: size * 0.22))
                path.move(to: CGPoint(x: size * 0.78, y: size * 0.22))
                path.addLine(to: CGPoint(x: size * 0.90, y: size * 0.32))
            }
            .stroke(style: StrokeStyle(lineWidth: size * 0.075, lineCap: .butt))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
