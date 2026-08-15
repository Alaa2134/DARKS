import SwiftUI

/// The camera reads the printed patch and gives a Z number.
///
/// The screen has two states and no third one. Either the measurement is good
/// enough to act on - and then there is one button that applies exactly the
/// correction shown - or it is not, and then there is nothing to tap and the
/// failed check is named. There is deliberately no "apply anyway": a Z offset
/// taken from a bad reading drives the nozzle into the bed.
struct FirstLayerCheckView: View {
    @EnvironmentObject private var calibration: CalibrationStore
    @Environment(\.dismiss) private var dismiss

    @State private var applied = false

    var body: some View {
        List {
            Section {
                Text(localized: "first_layer.how")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Button {
                    applied = false
                    Task { await calibration.inspectFirstLayer() }
                } label: {
                    HStack {
                        if calibration.isInspecting { ProgressView().controlSize(.small) }
                        Label(L.t("first_layer.measure"), systemImage: "camera.viewfinder")
                    }
                }
                .disabled(calibration.isInspecting)
            } footer: {
                Text(localized: "first_layer.measure.footer")
            }

            if let reading = calibration.firstLayer {
                resultSection(reading)
                if reading.readable { measurementsSection(reading) }
            }

            if let error = calibration.lastError {
                Section {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Theme.danger)
                }
            }
        }
        .navigationTitle(L.t("first_layer.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(L.t("common.done")) { dismiss() }
            }
        }
        .onDisappear { calibration.clearFirstLayer() }
    }

    private func resultSection(_ reading: FirstLayerReading) -> some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(for: reading))
                    .font(.title2)
                    .foregroundStyle(colour(for: reading))
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(reading.verdictAR)
                        .font(.subheadline.weight(.semibold))
                    Text(reading.detailAR)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)

            if reading.needsAdjustment, let command = reading.command {
                Button {
                    Task {
                        applied = await calibration.applyFirstLayerCorrection()
                        if applied { Haptics.success() }
                    }
                } label: {
                    Label(
                        L.t("first_layer.apply", String(format: "%+.3f", reading.zAdjustMM ?? 0)),
                        systemImage: "arrow.up.and.down"
                    )
                }
                Text(command)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)

                if applied {
                    Label(L.t("first_layer.applied"), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.printing)
                    Text(localized: "first_layer.applied.hint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(localized: "first_layer.result")
        } footer: {
            if reading.readable {
                Text(L.t("first_layer.confidence", Int(reading.confidence * 100)))
            } else {
                // Named rather than hidden: the user can fix lighting or the
                // camera angle, but only if they are told which one failed.
                Text(localized: "first_layer.unreadable.footer")
            }
        }
    }

    private func measurementsSection(_ reading: FirstLayerReading) -> some View {
        Section {
            row("first_layer.measured_width", reading.measurements["line_width_mm"], "%.3f mm")
            row("first_layer.expected_width", reading.measurements["expected_width_mm"], "%.3f mm")
            row("first_layer.lines", reading.measurements["lines_found"], "%.0f")
            row("first_layer.contrast", reading.measurements["contrast"], "%.2f")
            row("first_layer.drift", reading.measurements["spacing_drift"], "%.2f")
        } header: {
            Text(localized: "first_layer.measurements")
        } footer: {
            Text(localized: "first_layer.measurements.footer")
        }
    }

    private func row(_ titleKey: String, _ value: Double?, _ format: String) -> some View {
        LabeledContent(L.t(titleKey)) {
            Text(value.map { String(format: format, $0) } ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func icon(for reading: FirstLayerReading) -> String {
        switch reading.verdict {
        case "good": return "checkmark.seal.fill"
        case "too_low": return "arrow.down.to.line"
        case "too_high": return "arrow.up.to.line"
        default: return "eye.slash"
        }
    }

    private func colour(for reading: FirstLayerReading) -> Color {
        switch reading.verdict {
        case "good": return Theme.printing
        case "unreadable": return Theme.paused
        default: return Theme.accent
        }
    }
}
