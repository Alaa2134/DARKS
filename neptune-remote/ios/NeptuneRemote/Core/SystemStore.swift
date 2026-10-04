import Foundation

/// Raspberry Pi metrics (CPU, RAM, disk, uptime, Tailscale).
@MainActor
final class SystemStore: ObservableObject {

    @Published private(set) var info: BackendSystem?
    @Published private(set) var isLoading = false
    @Published var lastError: APIError?

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if settings.demoMode {
            info = Self.demoInfo
            return
        }
        do {
            info = try await printer.backend.system()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func apply(_ system: BackendSystem) {
        info = system
    }

    static let demoInfo = BackendSystem(
        hostname: "pi",
        platform: "Linux 6.6.51+rpt-rpi-2712 (aarch64)",
        model: "Raspberry Pi 5 Model B Rev 1.0",
        cpuPercent: 14.2,
        cpuTempC: 47.8,
        loadAverage: [0.42, 0.38, 0.31],
        memoryTotalMB: 8_192,
        memoryUsedMB: 1_486,
        memoryPercent: 18.1,
        diskTotalGB: 117.2,
        diskUsedGB: 21.6,
        diskPercent: 18.4,
        uptimeSeconds: 412_800,
        ipAddresses: ["eth0: 192.168.1.42", "tailscale0: 100.78.2.66"],
        tailscale: BackendTailscale(
            installed: true, running: true, hostname: "pi",
            ips: ["100.78.2.66"], backendState: "Running"
        ),
        throttled: "ok"
    )
}
