import SwiftUI

/// A telemetry finding, on the screen where it is useful.
///
/// These are the things a camera cannot see - a clog forming as a slow drift in
/// layer time, the extruder quietly slipping, a heater losing its grip - and
/// they are worth nothing on a settings page. A clog is only actionable while
/// the print is still running, so the card belongs on Home, next to the print
/// it is about.
///
/// The evidence is shown rather than summarised. Every finding is arithmetic
/// over numbers the backend already had, and showing the numbers is what makes
/// a wrong one arguable instead of just annoying.
struct AnomalyCard: View {
    let finding: AnomalyFinding

    @State private var showingEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(colour)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 3) {
                    Text(finding.titleAR)
                        .font(.subheadline.weight(.semibold))
                    Text(finding.detailAR)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !finding.suggestionAR.isEmpty {
                Text(finding.suggestionAR)
                    .font(.caption)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Theme.pageFill,
                        in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous)
                    )
            }

            if !finding.evidence.isEmpty {
                DisclosureGroup(L.t("anomaly.evidence"), isExpanded: $showingEvidence) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(finding.evidence.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                            HStack {
                                Text(key.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(format(value))
                                    .font(.caption2.monospaced())
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .card(tint: colour)
    }

    private func format(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 10_000
            ? String(Int(value))
            : String(format: "%.2f", value)
    }

    private var icon: String {
        switch finding.id {
        case "layer_time_drift": return "chart.line.uptrend.xyaxis"
        case "extrusion_deviation": return "arrow.triangle.branch"
        case "nozzle_unstable": return "waveform.path.ecg"
        case "nozzle_below_target": return "thermometer.snowflake"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var colour: Color {
        switch finding.severity {
        case "urgent": return Theme.danger
        case "warning": return Theme.paused
        default: return Theme.accent
        }
    }
}

/// Every current finding, worst first. Empty while the printer is behaving,
/// so it disappears on its own rather than needing to be dismissed.
struct AnomalyList: View {
    @EnvironmentObject private var calibration: CalibrationStore

    var body: some View {
        ForEach(sorted) { finding in
            AnomalyCard(finding: finding)
        }
    }

    private var sorted: [AnomalyFinding] {
        let order = ["urgent": 0, "warning": 1, "watch": 2, "info": 3]
        return calibration.anomalies.findings.sorted {
            (order[$0.severity] ?? 9) < (order[$1.severity] ?? 9)
        }
    }
}
