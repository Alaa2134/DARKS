import SwiftUI
import WidgetKit

// MARK: - Timeline

struct PrinterEntry: TimelineEntry {
    let date: Date
    let snapshot: PrinterWidgetSnapshot
    let isStale: Bool
}

struct PrinterTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> PrinterEntry {
        PrinterEntry(date: Date(), snapshot: .placeholder, isStale: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (PrinterEntry) -> Void) {
        completion(currentEntry(preview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PrinterEntry>) -> Void) {
        let entry = currentEntry(preview: false)
        // The app writes a fresh snapshot into the App Group whenever it is
        // running. Refresh often while printing, lazily when idle.
        let interval: TimeInterval = entry.snapshot.state.isActive ? 300 : 900
        let timeline = Timeline(
            entries: [entry],
            policy: .after(Date().addingTimeInterval(interval))
        )
        completion(timeline)
    }

    private func currentEntry(preview: Bool) -> PrinterEntry {
        guard !preview, let stored = SharedStore.loadSnapshot() else {
            return PrinterEntry(date: Date(), snapshot: .placeholder, isStale: false)
        }
        let age = Date().timeIntervalSince(stored.updatedAt)
        return PrinterEntry(date: Date(), snapshot: stored, isStale: age > 1_800)
    }
}

// MARK: - Colours

enum WidgetTheme {
    static let nozzle = Color(red: 1.00, green: 0.45, blue: 0.25)
    static let bed = Color(red: 0.30, green: 0.62, blue: 1.00)
    static let printing = Color(red: 0.20, green: 0.78, blue: 0.55)
    static let paused = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let danger = Color(red: 0.94, green: 0.28, blue: 0.30)

    static func color(for state: PrinterState) -> Color {
        switch state {
        case .printing, .complete: return printing
        case .paused: return paused
        case .error, .cancelled: return danger
        default: return .secondary
        }
    }
}

// MARK: - Views

struct NeptuneWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PrinterEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .accessoryCircular:
            circularView
        case .accessoryRectangular:
            rectangularView
        case .accessoryInline:
            Text("\(entry.snapshot.printerName) · \(Int(entry.snapshot.progress * 100))%")
        default:
            mediumView
        }
    }

    private var stateColor: Color { WidgetTheme.color(for: entry.snapshot.state) }

    private var stateText: String {
        NSLocalizedString(entry.snapshot.state.localizationKey, comment: "")
    }

    // MARK: Small

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: entry.snapshot.state.symbolName)
                    .foregroundStyle(stateColor)
                Text(stateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if entry.snapshot.state.isActive {
                ProgressView(value: entry.snapshot.progress)
                    .tint(stateColor)
                Text("\(Int(entry.snapshot.progress * 100))%")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if let remaining = entry.snapshot.estimatedRemaining {
                    Text(Format.duration(remaining))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(entry.snapshot.printerName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            temperatureRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Medium

    private var mediumView: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.snapshot.printerName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: entry.snapshot.state.symbolName)
                    Text(stateText)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateColor)

                if !entry.snapshot.filename.isEmpty {
                    Text(entry.snapshot.filename)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
                temperatureRow

                HStack(spacing: 5) {
                    Image(systemName: entry.snapshot.power == .on ? "bolt.fill" : "bolt.slash.fill")
                    Text(NSLocalizedString(entry.snapshot.power.localizationKey, comment: ""))
                }
                .font(.caption2)
                .foregroundStyle(entry.snapshot.power == .on ? WidgetTheme.printing : .secondary)
            }

            Spacer(minLength: 0)

            ZStack {
                Circle().stroke(stateColor.opacity(0.18), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.001, entry.snapshot.progress))
                    .stroke(stateColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(entry.snapshot.progress * 100))%")
                        .font(.headline.weight(.bold))
                        .monospacedDigit()
                    if let remaining = entry.snapshot.estimatedRemaining {
                        Text(Format.duration(remaining))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 78, height: 78)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var temperatureRow: some View {
        HStack(spacing: 10) {
            Label(
                "\(Int(entry.snapshot.nozzleActual))°",
                systemImage: "flame.fill"
            )
            .foregroundStyle(WidgetTheme.nozzle)

            Label(
                "\(Int(entry.snapshot.bedActual))°",
                systemImage: "square.stack.3d.down.right.fill"
            )
            .foregroundStyle(WidgetTheme.bed)
        }
        .font(.caption2.weight(.medium))
        .monospacedDigit()
        .lineLimit(1)
    }

    // MARK: Lock screen

    private var circularView: some View {
        Gauge(value: entry.snapshot.progress) {
            Image(systemName: "printer.fill")
        } currentValueLabel: {
            Text("\(Int(entry.snapshot.progress * 100))")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.snapshot.printerName)
                .font(.headline)
                .lineLimit(1)
            Text("\(stateText) · \(Int(entry.snapshot.progress * 100))%")
                .font(.caption)
                .lineLimit(1)
            Text("\(Int(entry.snapshot.nozzleActual))° / \(Int(entry.snapshot.bedActual))°")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

// MARK: - Widget

struct NeptuneWidget: Widget {
    let kind = "NeptuneRemoteWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PrinterTimelineProvider()) { entry in
            NeptuneWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Neptune 3 Plus")
        .description("Printer state, progress and temperatures.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}

@main
struct NeptuneWidgetBundle: WidgetBundle {
    var body: some Widget {
        NeptuneWidget()
        PrintLiveActivity()
    }
}

#Preview(as: .systemMedium) {
    NeptuneWidget()
} timeline: {
    PrinterEntry(date: .now, snapshot: .placeholder, isStale: false)
}
