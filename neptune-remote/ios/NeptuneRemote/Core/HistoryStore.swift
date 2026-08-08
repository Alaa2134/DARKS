import Foundation

@MainActor
final class HistoryStore: ObservableObject {

    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var stats = HistoryStats.empty
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
            entries = Self.demoEntries
            stats = HistoryStats(
                totalPrints: 3, successful: 2, failed: 0, cancelled: 1,
                totalPrintSeconds: 21_600, totalFilamentMM: 48_320, longestPrintSeconds: 14_400
            )
            return
        }

        do {
            let response = try await printer.backend.history()
            entries = response.entries
            stats = response.stats
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func delete(_ entry: HistoryEntry) async {
        guard !settings.demoMode else {
            entries.removeAll { $0.id == entry.id }
            return
        }
        do {
            try await printer.backend.deleteHistory(id: entry.id)
            entries.removeAll { $0.id == entry.id }
            await load()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    var successRate: Double {
        guard stats.totalPrints > 0 else { return 0 }
        return Double(stats.successful) / Double(stats.totalPrints)
    }

    var totalFilamentMeters: Double { stats.totalFilamentMM / 1000 }

    static let demoEntries: [HistoryEntry] = [
        HistoryEntry(
            id: 3, filename: "phone_stand.gcode",
            startTime: Date().addingTimeInterval(-100_000).timeIntervalSince1970,
            finishTime: Date().addingTimeInterval(-85_600).timeIntervalSince1970,
            duration: 14_400, result: "completed",
            filamentUsedMM: 18_900, estimatedFilamentMM: 18_400,
            nozzleTemp: 205, bedTemp: 60, speedProfile: "Standard",
            thumbnailPath: nil, note: ""
        ),
        HistoryEntry(
            id: 2, filename: "calibration_cube.gcode",
            startTime: Date().addingTimeInterval(-200_000).timeIntervalSince1970,
            finishTime: Date().addingTimeInterval(-198_180).timeIntervalSince1970,
            duration: 1_820, result: "completed",
            filamentUsedMM: 1_140, estimatedFilamentMM: 1_100,
            nozzleTemp: 235, bedTemp: 75, speedProfile: "Quality",
            thumbnailPath: nil, note: ""
        ),
        HistoryEntry(
            id: 1, filename: "benchy.gcode",
            startTime: Date().addingTimeInterval(-300_000).timeIntervalSince1970,
            finishTime: Date().addingTimeInterval(-294_600).timeIntervalSince1970,
            duration: 5_400, result: "cancelled",
            filamentUsedMM: 2_180, estimatedFilamentMM: 4_321,
            nozzleTemp: 205, bedTemp: 60, speedProfile: "Standard",
            thumbnailPath: nil, note: "Layer shift"
        )
    ]
}
