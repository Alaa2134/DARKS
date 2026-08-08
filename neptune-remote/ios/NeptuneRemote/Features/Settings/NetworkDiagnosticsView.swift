import SwiftUI

struct NetworkDiagnosticsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var printer: PrinterStore

    @State private var diagnostics: PrinterStore.Diagnostics?
    @State private var isRunning = false

    var body: some View {
        List {
            Section {
                InfoRow(titleKey: "settings.host", value: settings.host)
                InfoRow(
                    titleKey: "diagnostics.moonraker_url",
                    value: settings.connection.moonrakerBaseURL?.absoluteString ?? "--"
                )
                InfoRow(
                    titleKey: "diagnostics.backend_url",
                    value: settings.connection.backendBaseURL?.absoluteString ?? "--"
                )
            } header: {
                Text(localized: "diagnostics.endpoints")
            }

            Section {
                resultRow("diagnostics.moonraker", diagnostics?.moonrakerReachable)
                resultRow("diagnostics.klipper_ready", diagnostics?.klipperReady)
                resultRow("diagnostics.websocket", diagnostics?.websocketConnected)
                resultRow("diagnostics.backend", diagnostics?.backendReachable)
                resultRow("diagnostics.slicer_available", diagnostics?.slicerAvailable)

                if let provider = diagnostics?.powerProvider {
                    InfoRow(titleKey: "diagnostics.power_provider", value: provider)
                }
                if let version = diagnostics?.backendVersion {
                    InfoRow(titleKey: "settings.backend_version", value: version)
                }
                if let error = diagnostics?.moonrakerError {
                    FailureNote(labelKey: "diagnostics.moonraker", error: error, tint: Theme.danger)
                }
                if let error = diagnostics?.backendError {
                    FailureNote(labelKey: "diagnostics.backend", error: error, tint: Theme.danger)
                }

                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        if isRunning { ProgressView().controlSize(.small) }
                        Text(localized: "diagnostics.run")
                    }
                }
            } header: {
                Text(localized: "diagnostics.checks")
            }

            Section {
                ForEach(1...5, id: \.self) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(step)")
                            .font(.caption.weight(.bold))
                            .frame(width: 20, height: 20)
                            .background(Theme.accent.opacity(0.18), in: Circle())
                        Text(localized: "diagnostics.tailscale.step\(step)")
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(localized: "diagnostics.tailscale")
            } footer: {
                Text(localized: "diagnostics.tailscale.footer")
            }
        }
        .navigationTitle(L.t("diagnostics.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await run() }
    }

    private func resultRow(_ key: String, _ value: Bool?) -> some View {
        HStack {
            Text(localized: key)
            Spacer()
            if let value {
                Label(
                    L.t(value ? "status.ok" : "status.failed"),
                    systemImage: value ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(value ? Theme.printing : Theme.danger)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        diagnostics = await printer.runDiagnostics()
    }
}
