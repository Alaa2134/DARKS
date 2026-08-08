import SwiftUI

struct SystemInfoView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var system: SystemStore

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                if let error = system.lastError {
                    ErrorBanner(
                        message: error.localizedDescription,
                        onRetry: { Task { await system.load() } },
                        onDismiss: { system.lastError = nil }
                    )
                }

                if let info = system.info {
                    overviewCard(info)
                    resourcesCard(info)
                    networkCard(info)
                } else if system.isLoading {
                    ProgressView().padding(.top, 60)
                } else {
                    EmptyStateView(
                        titleKey: "system.unavailable.title",
                        messageKey: "system.unavailable.message",
                        systemImage: "cpu",
                        actionTitleKey: "common.retry"
                    ) {
                        Task { await system.load() }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Theme.pageFill)
        .navigationTitle(L.t("system.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await system.load() }
        .refreshable { await system.load() }
    }

    private func overviewCard(_ info: BackendSystem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("system.overview", systemImage: "server.rack")
            InfoRow(titleKey: "system.hostname", value: info.hostname)
            if !info.model.isEmpty {
                InfoRow(titleKey: "system.model", value: info.model)
            }
            InfoRow(titleKey: "system.platform", value: info.platform)
            InfoRow(titleKey: "system.uptime", value: Format.duration(info.uptimeSeconds))
            if let throttled = info.throttled {
                InfoRow(
                    titleKey: "system.throttled",
                    value: throttled,
                    tint: throttled == "ok" ? Theme.printing : Theme.danger
                )
            }
        }
        .card()
    }

    private func resourcesCard(_ info: BackendSystem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("system.resources", systemImage: "gauge")

            gauge(
                titleKey: "system.cpu",
                value: info.cpuPercent / 100,
                label: Format.percentValue(info.cpuPercent),
                tint: info.cpuPercent > 85 ? Theme.danger : Theme.accent
            )
            if let temperature = info.cpuTempC {
                gauge(
                    titleKey: "system.cpu_temp",
                    value: min(1, temperature / 90),
                    label: Format.temperature(temperature),
                    tint: temperature > 75 ? Theme.danger : (temperature > 65 ? Theme.paused : Theme.printing)
                )
            }
            gauge(
                titleKey: "system.memory",
                value: info.memoryPercent / 100,
                label: "\(Int(info.memoryUsedMB)) / \(Int(info.memoryTotalMB)) MB",
                tint: info.memoryPercent > 85 ? Theme.danger : Theme.bed
            )
            gauge(
                titleKey: "system.disk",
                value: info.diskPercent / 100,
                label: String(format: "%.1f / %.1f GB", info.diskUsedGB, info.diskTotalGB),
                tint: info.diskPercent > 90 ? Theme.danger : Theme.printing
            )

            if !info.loadAverage.isEmpty {
                InfoRow(
                    titleKey: "system.load",
                    value: info.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  ")
                )
            }
        }
        .card()
    }

    private func gauge(titleKey: String, value: Double, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(localized: titleKey).font(.subheadline)
                Spacer()
                Text(label).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            ProgressView(value: max(0, min(1, value))).tint(tint)
        }
    }

    private func networkCard(_ info: BackendSystem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("system.network", systemImage: "network")

            ForEach(info.ipAddresses, id: \.self) { address in
                Text(address)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text(localized: "system.tailscale")
                    .font(.subheadline)
                Spacer()
                StatusPill(
                    text: info.tailscale.running
                        ? L.t("status.connected")
                        : (info.tailscale.installed ? L.t("status.stopped") : L.t("status.not_installed")),
                    color: info.tailscale.running ? Theme.printing : Theme.paused
                )
            }
            if !info.tailscale.ips.isEmpty {
                InfoRow(titleKey: "system.tailscale_ip", value: info.tailscale.ips.joined(separator: ", "))
            }
            if !info.tailscale.hostname.isEmpty {
                InfoRow(titleKey: "system.tailscale_host", value: info.tailscale.hostname)
            }
        }
        .card()
    }
}
