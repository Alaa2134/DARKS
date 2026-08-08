import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen Live Activity and Dynamic Island presentation for a running print.
///
/// The model picture leads here too: when the Pi rendered a preview it is shown
/// on the lock screen and in the expanded Dynamic Island. The G-code filename is
/// only used when there is genuinely nothing else to identify the print by.
struct PrintLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrintActivityAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    thumbnail(context.attributes, size: 42)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(percent(context.state.progress))
                            .font(.title3.weight(.semibold).monospacedDigit())
                        if let finish = context.state.estimatedFinish {
                            Text(finish, style: .timer)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(context.attributes))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let warningKey = context.state.warningKey {
                            Label(NSLocalizedString(warningKey, comment: ""), systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(WidgetTheme.paused)
                                .lineLimit(1)
                        } else if let layer = context.state.layerText {
                            Text(layer)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        ProgressView(value: clamped(context.state.progress))
                            .tint(WidgetTheme.color(for: context.state.state))
                        HStack(spacing: 14) {
                            temperature(
                                symbol: "thermometer.high",
                                actual: context.state.nozzleActual,
                                target: context.state.nozzleTarget,
                                tint: WidgetTheme.nozzle
                            )
                            temperature(
                                symbol: "square.3.layers.3d.bottom.filled",
                                actual: context.state.bedActual,
                                target: context.state.bedTarget,
                                tint: WidgetTheme.bed
                            )
                            Spacer(minLength: 0)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.state.symbolName)
                    .foregroundStyle(WidgetTheme.color(for: context.state.state))
            } compactTrailing: {
                Text(percent(context.state.progress))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                ProgressView(value: clamped(context.state.progress))
                    .progressViewStyle(.circular)
                    .tint(WidgetTheme.color(for: context.state.state))
            }
            .widgetURL(URL(string: "neptuneremote://home"))
            .keylineTint(WidgetTheme.color(for: context.state.state))
        }
    }

    // MARK: - Lock screen

    private func lockScreen(_ context: ActivityViewContext<PrintActivityAttributes>) -> some View {
        HStack(spacing: 12) {
            thumbnail(context.attributes, size: 58)

            VStack(alignment: .leading, spacing: 6) {
                Text(title(context.attributes))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                ProgressView(value: clamped(context.state.progress))
                    .tint(WidgetTheme.color(for: context.state.state))

                HStack(spacing: 10) {
                    Text(percent(context.state.progress))
                        .font(.caption.weight(.medium).monospacedDigit())
                    if let layer = context.state.layerText {
                        Text(layer)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let finish = context.state.estimatedFinish {
                        Text(finish, style: .timer)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 60, alignment: .trailing)
                    }
                }

                if let warningKey = context.state.warningKey {
                    Label(NSLocalizedString(warningKey, comment: ""), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(WidgetTheme.paused)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func thumbnail(_ attributes: PrintActivityAttributes, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(WidgetTheme.printing.opacity(0.18))
            if let url = attributes.thumbnailURL {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "cube")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "cube")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func temperature(symbol: String, actual: Double, target: Double, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(String(format: target > 0 ? "%.0f/%.0f°" : "%.0f°", actual, target))
                .font(.caption2.monospacedDigit())
        }
    }

    /// Model name when we have one, G-code filename only as a last resort.
    private func title(_ attributes: PrintActivityAttributes) -> String {
        if !attributes.modelName.isEmpty { return attributes.modelName }
        if !attributes.gcodeName.isEmpty { return attributes.gcodeName }
        return attributes.printerName
    }

    private func percent(_ progress: Double) -> String {
        String(format: "%.0f%%", clamped(progress) * 100)
    }

    private func clamped(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}
