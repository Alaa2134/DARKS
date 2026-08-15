import SwiftUI

/// Shows one printer condition, coloured and worded by how serious it actually
/// is.
///
/// The distinction this exists to draw: an unhomed axis gets a calm blue card
/// with a Home button and a line explaining that it is normal after a restart.
/// A shutdown gets a red one. Both used to be the same red "Printer error".
struct ConditionCard: View {
    let condition: PrinterCondition
    var onRemedy: ((PrinterCondition.Remedy) -> Void)?

    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let bodyKey = condition.bodyKey {
                Text(localized: bodyKey)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let label = remedyLabel {
                Button {
                    onRemedy?(condition.remedy)
                } label: {
                    Label(label, systemImage: remedyIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
            }

            // Klipper's exact English, never translated, always available.
            if let raw = condition.rawMessage, !raw.isEmpty {
                DisclosureGroup(isExpanded: $showingDetails) {
                    Text(raw)
                        .font(.caption)
                        .monospaced()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text(localized: "condition.technical_details")
                        .font(.caption.weight(.medium))
                }
            }
        }
        .card()
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                Text(localized: condition.severity.localizationKey)
                    .font(.caption2)
                    .foregroundStyle(tint)
            }
            Spacer()
        }
    }

    /// The homing card names the axes that are actually missing, so "محور Z
    /// يحتاج Home" rather than a generic sentence.
    private var title: String {
        guard condition.cause == .notHomed, !condition.axes.isEmpty else {
            return L.t(condition.titleKey)
        }
        return L.t(condition.titleKey, condition.axes.uppercased().map(String.init).joined(separator: " · "))
    }

    private var tint: Color {
        switch condition.severity {
        case .informational: return Theme.accent
        case .actionRequired: return Theme.accent
        case .warning: return Theme.paused
        case .recoverableError: return Theme.paused
        case .configurationError: return Theme.danger
        case .critical: return Theme.danger
        }
    }

    private var icon: String {
        switch condition.severity {
        case .informational: return "info.circle.fill"
        case .actionRequired: return "hand.raised.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .recoverableError: return "arrow.clockwise.circle.fill"
        case .configurationError: return "doc.badge.gearshape.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private var remedyLabel: String? {
        switch condition.remedy {
        case .homeAxes(let axes):
            return axes.isEmpty
                ? L.t("action.home_all")
                : L.t("condition.home_axes", axes.uppercased())
        case .firmwareRestart: return L.t("action.restart_firmware")
        case .restartKlipper: return L.t("action.restart_klipper")
        case .openConfig: return L.t("condition.open_config")
        case .none: return nil
        }
    }

    private var remedyIcon: String {
        switch condition.remedy {
        case .homeAxes: return "house.fill"
        case .firmwareRestart, .restartKlipper: return "arrow.clockwise"
        case .openConfig: return "doc.text"
        case .none: return ""
        }
    }
}

/// Every current condition, worst first. Empty when the printer is fine, which
/// is what makes stale warnings disappear on their own.
struct ConditionList: View {
    @EnvironmentObject private var printer: PrinterStore

    var body: some View {
        ForEach(printer.conditions) { condition in
            ConditionCard(condition: condition) { remedy in
                apply(remedy)
            }
        }
    }

    private func apply(_ remedy: PrinterCondition.Remedy) {
        Task {
            switch remedy {
            case .homeAxes(let axes):
                await printer.home(axes: axes)
            case .firmwareRestart:
                await printer.restartFirmware()
            case .restartKlipper:
                await printer.restartKlipper()
            case .openConfig, .none:
                break
            }
        }
    }
}
