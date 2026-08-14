import SwiftUI

/// Says what the app is waiting for, while it waits.
///
/// Getting from "app opened" to "printer on screen" is four separate waits -
/// reaching the Pi, reaching Moonraker, Klipper becoming ready, reading
/// printer.cfg - and any one of them can be the slow or broken one. The app
/// showed the same nothing for all four, so a Pi that was switched off looked
/// exactly like a Klipper that was still starting, and both looked like an app
/// that had hung.
///
/// The bar tracks the real step, not a timer. It never fills on its own: if it
/// stops at step two, step two is where the problem is, and that is worth more
/// than an animation that reassures you while nothing happens.
struct StartupCard: View {
    @EnvironmentObject private var printer: PrinterStore
    @EnvironmentObject private var settings: AppSettings

    private var stage: PrinterStore.StartupStage { printer.startupStage }

    var body: some View {
        if stage != .ready {
            VStack(alignment: .leading, spacing: 12) {
                header

                if !stage.isSettled {
                    steps
                } else {
                    settledDetail
                }
            }
            .card()
            .transition(.neptuneContent)
            .animation(.neptuneContent, value: stage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if stage.isSettled {
                Image(systemName: stage == .offline ? "wifi.slash" : "lock.trianglebadge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(Theme.danger)
            } else {
                ProgressView().controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(localized: stage.localizationKey)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !stage.isSettled {
                    Text(L.t("startup.step", stage.step, PrinterStore.StartupStage.totalSteps))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - The four steps

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.ordered, id: \.self) { step in
                stepRow(step)
            }
        }
    }

    private static let ordered: [PrinterStore.StartupStage] = [
        .reachingPi, .reachingPrinter, .waitingForKlipper, .readingConfig
    ]

    private func stepRow(_ step: PrinterStore.StartupStage) -> some View {
        let done = stage.step > step.step
        let current = stage.step == step.step

        return HStack(spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.printing)
                } else if current {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)

            Text(localized: step.localizationKey)
                .font(.caption)
                .foregroundStyle(done ? .secondary : (current ? .primary : .tertiary))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .animation(.neptune, value: done)
    }

    // MARK: - When it has stopped rather than progressed

    @ViewBuilder
    private var settledDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized: stage == .offline ? "startup.offline.hint" : "startup.auth.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The address is the single most common thing to be wrong, so it is
            // shown rather than hidden behind the settings screen.
            Text(verbatim: settings.host)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
