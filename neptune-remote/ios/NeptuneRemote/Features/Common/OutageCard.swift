import SwiftUI

/// "Something interrupted a print while you were out."
///
/// This card deliberately offers no resume button. Klipper has no power-loss
/// recovery, and on a printer whose Z is homed by a probe under `[safe_z_home]`
/// the first `G28` after a cut drives the nozzle down in the middle of the bed -
/// straight into whatever is still stuck there. The one useful action is
/// physical: clear the bed first. Offering a resume that cannot work, on a
/// screen someone reads while walking through the door, would be worse than
/// offering nothing.
struct OutageCard: View {
    let record: OutageRecord
    var onAcknowledge: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.systemImage)
                    .font(.title2)
                    .foregroundStyle(record.isPowerRelated ? Theme.danger : Theme.paused)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.causeAr.isEmpty ? L.t("alerts.outage.generic") : record.causeAr)
                        .font(.subheadline.weight(.semibold))
                    Text(Format.date(record.detectedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if let snapshot = record.snapshot, record.wasPrinting {
                VStack(alignment: .leading, spacing: 6) {
                    if !snapshot.filename.isEmpty {
                        Text(snapshot.filename)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 14) {
                        if !snapshot.layerText.isEmpty {
                            stat("alerts.outage.layer", snapshot.layerText)
                        }
                        if snapshot.progress > 0 {
                            stat("alerts.outage.progress", Format.percent(snapshot.progress))
                        }
                        if snapshot.zHeight > 0 {
                            stat("alerts.outage.height", Format.millimetres(snapshot.zHeight))
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.pageFill, in: RoundedRectangle(cornerRadius: Theme.smallCornerRadius, style: .continuous))
            }

            if !record.adviceAr.isEmpty {
                Text(record.adviceAr)
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !record.detail.isEmpty {
                DisclosureGroup(L.t("condition.technical_details")) {
                    Text(record.detail)
                        .font(.caption2)
                        .monospaced()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }

            if let onAcknowledge {
                Button(action: onAcknowledge) {
                    Label(L.t("alerts.outage.acknowledge"), systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .card(tint: record.isPowerRelated ? Theme.danger : Theme.paused)
    }

    private func stat(_ titleKey: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(localized: titleKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }
}
