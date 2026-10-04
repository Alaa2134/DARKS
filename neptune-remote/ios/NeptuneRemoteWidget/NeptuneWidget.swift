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

/// The app's identity, restated for the extension (the app's `Theme` is not
/// compiled into it): deep water for the machine, molten amber only for heat.
enum WidgetTheme {
    static let abyssTop = Color(red: 0.055, green: 0.208, blue: 0.341)    // #0E3557
    static let abyssMid = Color(red: 0.031, green: 0.149, blue: 0.251)    // #082640
    static let abyssDeep = Color(red: 0.012, green: 0.059, blue: 0.118)   // #030F1E
    static let tide = Color(red: 0.133, green: 0.827, blue: 0.933)        // #22D3EE
    static let tideDeep = Color(red: 0.031, green: 0.569, blue: 0.698)    // #0891B2
    static let emberHot = Color(red: 1.00, green: 0.541, blue: 0.122)     // #FF8A1F
    static let emberWarm = Color(red: 1.00, green: 0.757, blue: 0.302)    // #FFC14D

    static let nozzle = emberHot
    static let bed = tide
    static let printing = tide
    static let paused = Color(red: 1.00, green: 0.72, blue: 0.20)
    static let danger = Color(red: 0.94, green: 0.28, blue: 0.30)
    static let done = Color(red: 0.20, green: 0.84, blue: 0.55)

    static func color(for state: PrinterState) -> Color {
        switch state {
        case .printing: return printing
        case .complete: return done
        case .paused: return paused
        case .error, .cancelled: return danger
        default: return Color.white.opacity(0.7)
        }
    }

    static let abyss = LinearGradient(
        colors: [abyssTop, abyssMid, abyssDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    static let tideGradient = LinearGradient(colors: [tideDeep, tide], startPoint: .leading, endPoint: .trailing)
}

/// Deep water with the state's light coming up through it and the printed
/// layers along the bottom - the same surface as the app's hero card.
struct WidgetBackdrop: View {
    var glow: Color

    var body: some View {
        ZStack {
            WidgetTheme.abyss
            RadialGradient(
                colors: [glow.opacity(0.40), .clear],
                center: UnitPoint(x: 0.9, y: 0.0),
                startRadius: 2,
                endRadius: 170
            )
            WidgetWaves()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
    }
}

struct WidgetWaves: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<3 {
            let y = rect.maxY - CGFloat(index) * 10 - 8
            path.move(to: CGPoint(x: rect.minX, y: y))
            var x = rect.minX
            while x <= rect.maxX {
                let t = (x - rect.minX) / max(rect.width, 1)
                path.addLine(to: CGPoint(x: x, y: y + sin(t * .pi * 2.2 + CGFloat(index) * 0.9) * 4))
                x += 5
            }
        }
        return path
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
            Text("\(entry.snapshot.printerName) · \(percent)")
        default:
            mediumView
        }
    }

    private var snapshot: PrinterWidgetSnapshot { entry.snapshot }
    private var stateColor: Color { WidgetTheme.color(for: snapshot.state) }
    private var percent: String { "\(Int((min(max(snapshot.progress, 0), 1) * 100).rounded()))%" }

    private var stateText: String {
        NSLocalizedString(snapshot.state.localizationKey, comment: "")
    }

    private var printName: String {
        snapshot.filename.isEmpty ? snapshot.printerName : Format.printName(snapshot.filename)
    }

    // MARK: Pieces

    private var stateChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
                .shadow(color: stateColor, radius: 3)
            Text(stateText)
                .lineLimit(1)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(stateColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(stateColor.opacity(0.16), in: Capsule())
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(WidgetTheme.tideGradient)
                    .frame(width: max(5, proxy.size.width * CGFloat(min(max(snapshot.progress, 0), 1))))
                    .shadow(color: WidgetTheme.tide.opacity(0.7), radius: 4)
            }
        }
        .frame(height: 5)
    }

    private var temperatureRow: some View {
        HStack(spacing: 10) {
            Label("\(Int(snapshot.nozzleActual))°", systemImage: "flame.fill")
                .foregroundStyle(WidgetTheme.emberWarm)
            Label("\(Int(snapshot.bedActual))°", systemImage: "square.stack.3d.down.right.fill")
                .foregroundStyle(WidgetTheme.tide)
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
    }

    /// When the app has not written a snapshot for a while, say how old it is
    /// instead of passing an old number off as live.
    @ViewBuilder
    private var staleNote: some View {
        if entry.isStale {
            Label {
                Text(snapshot.updatedAt, style: .relative)
            } icon: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
        }
    }

    // MARK: Small

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 6) {
            stateChip

            if snapshot.state.isActive {
                Spacer(minLength: 0)
                Text(percent)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                if let remaining = snapshot.estimatedRemaining {
                    Text(Format.duration(remaining))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetTheme.emberWarm)
                        .lineLimit(1)
                }
                progressBar
            } else {
                Spacer(minLength: 0)
                Text(snapshot.printerName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            temperatureRow
            staleNote
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Medium

    private var mediumView: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                stateChip
                Text(snapshot.state.isActive ? printName : snapshot.printerName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if snapshot.state.isActive, let remaining = snapshot.estimatedRemaining {
                    Label(Format.duration(remaining), systemImage: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(WidgetTheme.emberWarm)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                temperatureRow
                HStack(spacing: 8) {
                    Label(
                        NSLocalizedString(snapshot.power.localizationKey, comment: ""),
                        systemImage: snapshot.power == .on ? "bolt.fill" : "bolt.slash.fill"
                    )
                    .foregroundStyle(snapshot.power == .on ? WidgetTheme.tide : .white.opacity(0.5))
                    staleNote
                }
                .font(.caption2)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.001, min(snapshot.progress, 1))))
                    .stroke(
                        AngularGradient(colors: [WidgetTheme.tideDeep, WidgetTheme.tide], center: .center),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .shadow(color: WidgetTheme.tide.opacity(0.6), radius: 6)
                Text(percent)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
            }
            .frame(width: 92, height: 92)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .fontDesign(.rounded)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Lock screen

    private var circularView: some View {
        Gauge(value: min(max(snapshot.progress, 0), 1)) {
            Image(systemName: "printer.fill")
        } currentValueLabel: {
            Text("\(Int((min(max(snapshot.progress, 0), 1) * 100).rounded()))")
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.state.isActive ? printName : snapshot.printerName)
                .font(.headline)
                .lineLimit(1)
            Text("\(stateText) · \(percent)")
                .font(.caption)
                .lineLimit(1)
            Text("\(Int(snapshot.nozzleActual))° / \(Int(snapshot.bedActual))°")
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
                .containerBackground(for: .widget) {
                    WidgetBackdrop(glow: WidgetTheme.color(for: entry.snapshot.state))
                }
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
