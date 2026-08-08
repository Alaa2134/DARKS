import SwiftUI

/// The five connection checks, each reported on its own.
///
/// The point of this screen is that the checks are *independent*. Moonraker can
/// answer while Klipper sits in shutdown; the backend can be healthy while nginx
/// is not; either WebSocket can fail while the matching HTTP endpoint is fine.
/// Collapsing those into one "connection failed" is what sends people rebooting
/// a Raspberry Pi that was never the problem.
struct ConnectionTestPanel: View {
    let diagnostics: PrinterStore.Diagnostics?
    let isTesting: Bool

    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            checks
            failures
            details
        }
    }

    // MARK: - The checks

    private var checks: some View {
        VStack(spacing: 0) {
            row("diagnostics.network", diagnostics?.hostReachable, detail: hostDetail)
            Divider()
            row("diagnostics.moonraker", diagnostics?.moonrakerReachable, detail: moonrakerDetail)
            Divider()
            row("diagnostics.klipper_ready", diagnostics?.klipperReady, detail: klipperDetail)
            Divider()
            row("diagnostics.backend", diagnostics?.backendReachable, detail: backendDetail)
            Divider()
            row("diagnostics.moonraker_websocket", diagnostics?.moonrakerWebSocketConnected)
            Divider()
            row("diagnostics.backend_websocket", diagnostics?.backendWebSocketConnected)
        }
        .card()
    }

    /// The one-line verdict under each row - the sentence the user actually
    /// reads. Never a generic failure.
    private var hostDetail: String? {
        guard let diagnostics else { return nil }
        if diagnostics.hostReachable == true { return nil }
        if diagnostics.moonrakerError == .blockedByATS { return L.t("error.ats_blocked") }
        return diagnostics.moonrakerError?.localizedDescription
    }

    private var moonrakerDetail: String? {
        guard let diagnostics else { return nil }
        if let key = diagnostics.moonrakerVerdictKey { return L.t(key) }
        return diagnostics.moonrakerError?.localizedDescription
    }

    /// Klipper's verdict has to make clear that a healthy Moonraker with a
    /// stopped Klipper is a Klipper problem, not a connection problem.
    private var klipperDetail: String? {
        guard let diagnostics, let key = diagnostics.klipperVerdictKey else { return nil }
        // Klipper reached but not ready: name the state Klipper reported.
        if key == "diagnostics.moonraker_ok_klipper_not_ready", let state = diagnostics.klippyState {
            return "\(L.t(key)) (\(state))"
        }
        return L.t(key)
    }

    private var backendDetail: String? {
        guard let diagnostics else { return nil }
        if diagnostics.backendReachable == true {
            return L.t("diagnostics.backend_connected")
        }
        return diagnostics.backendError?.localizedDescription
    }

    private func row(_ key: String, _ value: Bool?, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(localized: key)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(value == true ? .secondary : Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            marker(value)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func marker(_ value: Bool?) -> some View {
        if isTesting && value == nil {
            ProgressView().controlSize(.small)
        } else if let value {
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(value ? Theme.printing : Theme.danger)
        } else {
            Text("—").foregroundStyle(.secondary)
        }
    }

    // MARK: - Failure notes

    @ViewBuilder
    private var failures: some View {
        if let diagnostics, diagnostics.moonrakerError != nil || diagnostics.backendError != nil {
            VStack(alignment: .leading, spacing: 12) {
                if let error = diagnostics.moonrakerError {
                    FailureNote(
                        labelKey: "diagnostics.moonraker",
                        error: error,
                        url: diagnostics.moonrakerURL,
                        tint: Theme.danger
                    )
                }
                if let error = diagnostics.backendError {
                    FailureNote(
                        labelKey: "diagnostics.backend",
                        error: error,
                        url: diagnostics.backendURL,
                        tint: Theme.paused
                    )
                }
            }
            .card()
        }
    }

    // MARK: - Technical details

    @ViewBuilder
    private var details: some View {
        if let diagnostics {
            DisclosureGroup(isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    detailRow("diagnostics.moonraker_url", diagnostics.moonrakerURL)
                    detailRow("diagnostics.moonraker_websocket", diagnostics.moonrakerWebSocketURL)
                    detailRow("diagnostics.backend_url", diagnostics.backendURL)
                    detailRow("diagnostics.backend_websocket", diagnostics.backendWebSocketURL)
                    detailRow("diagnostics.klippy_state", diagnostics.klippyState)
                    detailRow("settings.backend_version", diagnostics.backendVersion)
                    detailRow("diagnostics.power_provider", diagnostics.powerProvider)
                    detailRow("diagnostics.ats", diagnostics.atsSummary)
                }
                .padding(.top, 8)
            } label: {
                Text(localized: "diagnostics.technical")
                    .font(.subheadline.weight(.medium))
            }
            .card()
        }
    }

    @ViewBuilder
    private func detailRow(_ key: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(localized: key)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption2)
                    .monospaced()
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
