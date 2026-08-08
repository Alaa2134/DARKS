import Foundation
import SwiftUI

/// Filament spools, print cost, products, maintenance and the print queue.
///
/// The queue deliberately never starts a job on its own: `startNext()` refuses
/// unless the user has confirmed the bed is clear, and that confirmation is
/// consumed by the backend on every start.
@MainActor
final class InventoryStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var spools: [FilamentSpool] = []
    @Published private(set) var filament = FilamentSummary.empty
    @Published private(set) var costSettings = CostSettings.default
    @Published private(set) var products: [Product] = []
    @Published private(set) var maintenance = MaintenanceStatus.empty
    @Published private(set) var queue = QueueState.empty

    @Published private(set) var lastCost: CostBreakdown?
    @Published private(set) var isLoading = false
    @Published private(set) var isBusy = false
    @Published var lastError: APIError?
    @Published var lastMessage: String?

    private let settings: AppSettings
    private let printer: PrinterStore

    init(settings: AppSettings, printer: PrinterStore) {
        self.settings = settings
        self.printer = printer
    }

    // MARK: - Summary routing

    func apply(_ summary: BackendSummary) {
        filament = summary.filament
        queue = summary.queue
    }

    // MARK: - Loading

    func load(force: Bool = false) async {
        guard force || spools.isEmpty else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if settings.demoMode {
            spools = DemoInventory.spools
            filament = DemoInventory.summary
            costSettings = .default
            products = DemoInventory.products
            maintenance = DemoInventory.maintenance
            queue = DemoInventory.queue
            return
        }

        do {
            async let spoolsTask = printer.backend.spools()
            async let summaryTask = printer.backend.filamentSummary()
            async let costTask = printer.backend.costSettings()
            async let queueTask = printer.backend.queueState()
            spools = try await spoolsTask
            filament = try await summaryTask
            costSettings = try await costTask
            queue = try await queueTask
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Filament

    var activeSpool: FilamentSpool? {
        spools.first { $0.active } ?? spools.first { $0.id == filament.activeSpoolID }
    }

    var lowSpools: [FilamentSpool] {
        spools.filter { !$0.archived && $0.remainingGrams < 100 }
    }

    func reloadFilament() async {
        guard !settings.demoMode else { return }
        do {
            spools = try await printer.backend.spools()
            filament = try await printer.backend.filamentSummary()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    @discardableResult
    func addSpool(_ payload: FilamentSpoolPayload) async -> FilamentSpool? {
        guard !settings.demoMode else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let spool = try await printer.backend.createSpool(payload)
            await reloadFilament()
            Haptics.success()
            lastError = nil
            return spool
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return nil
        }
    }

    func activate(_ spool: FilamentSpool) async {
        guard !settings.demoMode else { return }
        do {
            _ = try await printer.backend.activateSpool(id: spool.id)
            await reloadFilament()
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// Manual correction, e.g. after weighing the spool.
    func consume(_ spool: FilamentSpool, grams: Double) async {
        guard !settings.demoMode else { return }
        do {
            _ = try await printer.backend.consumeFilament(id: spool.id, grams: grams)
            await reloadFilament()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func deleteSpool(_ spool: FilamentSpool) async {
        guard !settings.demoMode else {
            spools.removeAll { $0.id == spool.id }
            return
        }
        do {
            try await printer.backend.deleteSpool(id: spool.id)
            await reloadFilament()
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// "Is there enough filament for this print?" - never blocks when no spool
    /// has been configured, because then the app simply does not know.
    func checkFilament(grams: Double, material: String? = nil) async -> FilamentCheck? {
        guard !settings.demoMode else { return nil }
        do {
            let check = try await printer.backend.checkFilament(grams: grams, material: material)
            lastError = nil
            return check
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    // MARK: - Cost

    func saveCostSettings(_ newSettings: CostSettings) async {
        guard !settings.demoMode else {
            costSettings = newSettings
            return
        }
        do {
            costSettings = try await printer.backend.saveCostSettings(newSettings)
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    @discardableResult
    func calculateCost(_ payload: CostRequestPayload) async -> CostBreakdown? {
        if settings.demoMode {
            lastCost = DemoInventory.cost
            return lastCost
        }
        do {
            let breakdown = try await printer.backend.calculateCost(payload)
            lastCost = breakdown
            lastError = nil
            return breakdown
        } catch {
            lastError = APIError.from(error, host: settings.host)
            return nil
        }
    }

    /// Convenience for the model detail screen.
    @discardableResult
    func costFor(item: LibraryItem, quantity: Int = 1) async -> CostBreakdown? {
        await calculateCost(
            CostRequestPayload(
                filamentGrams: item.estimatedFilamentGrams ?? 0,
                printSeconds: item.estimatedSeconds ?? 0,
                quantity: quantity,
                spoolID: activeSpool?.id
            )
        )
    }

    // MARK: - Products

    func loadProducts() async {
        guard !settings.demoMode else {
            products = DemoInventory.products
            return
        }
        do {
            products = try await printer.backend.products()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    @discardableResult
    func addProduct(_ payload: ProductPayload) async -> Product? {
        guard !settings.demoMode else { return nil }
        do {
            let product = try await printer.backend.createProduct(payload)
            products.insert(product, at: 0)
            Haptics.success()
            lastError = nil
            return product
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return nil
        }
    }

    func deleteProduct(_ product: Product) async {
        guard !settings.demoMode else {
            products.removeAll { $0.id == product.id }
            return
        }
        do {
            try await printer.backend.deleteProduct(id: product.id)
            products.removeAll { $0.id == product.id }
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Maintenance

    var dueMaintenance: [MaintenanceTask] { maintenance.tasks.filter(\.due) }

    func loadMaintenance() async {
        guard !settings.demoMode else {
            maintenance = DemoInventory.maintenance
            return
        }
        do {
            maintenance = try await printer.backend.maintenance()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    func completeMaintenance(_ task: MaintenanceTask, note: String = "") async {
        guard !settings.demoMode else { return }
        do {
            try await printer.backend.completeMaintenance(id: task.id, note: note)
            await loadMaintenance()
            lastMessage = L.t("maintenance.done")
            Haptics.success()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    // MARK: - Print queue

    func loadQueue() async {
        guard !settings.demoMode else {
            queue = DemoInventory.queue
            return
        }
        do {
            queue = try await printer.backend.queueState()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    @discardableResult
    func enqueue(_ payload: QueueJobPayload) async -> QueueJob? {
        guard !settings.demoMode else { return nil }
        do {
            let job = try await printer.backend.addToQueue(payload)
            await loadQueue()
            lastMessage = L.t("queue.added")
            Haptics.success()
            lastError = nil
            return job
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
            return nil
        }
    }

    func remove(_ job: QueueJob) async {
        guard !settings.demoMode else {
            queue = QueueState(
                jobs: queue.jobs.filter { $0.id != job.id }, bedClear: queue.bedClear,
                nextJob: nil, totalSeconds: 0, totalFilamentGrams: 0, blockedReasonKey: ""
            )
            return
        }
        do {
            try await printer.backend.removeFromQueue(id: job.id)
            await loadQueue()
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    /// The user physically confirms the bed is empty. This is the only thing
    /// that ever unblocks the next queued job - nothing auto-starts.
    func setBedClear(_ clear: Bool) async {
        guard !settings.demoMode else { return }
        do {
            queue = try await printer.backend.setBedClear(clear)
            Haptics.impact(.medium)
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
        }
    }

    var canStartNext: Bool {
        queue.bedClear && queue.nextJob != nil && !printer.snapshot.isPrinting
    }

    /// Why the "start next" button is disabled, as a localization key.
    var queueBlockedKey: String {
        if queue.nextJob == nil { return "queue.empty" }
        if printer.snapshot.isPrinting { return "queue.blocked.printing" }
        if !queue.bedClear { return "queue.blocked.bed_not_clear" }
        return queue.blockedReasonKey
    }

    func startNext() async {
        guard !settings.demoMode else { return }
        guard canStartNext else {
            lastError = .unknown(L.t(queueBlockedKey))
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await printer.backend.startNextQueuedJob()
            await loadQueue()
            Haptics.success()
            lastError = nil
        } catch {
            lastError = APIError.from(error, host: settings.host)
            Haptics.error()
        }
    }
}

// MARK: - Demo data

enum DemoInventory {
    static let spools: [FilamentSpool] = [
        FilamentSpool(
            id: "demo-spool-1", brand: "eSUN", material: "PLA+", colorName: "أسود",
            colorHex: "#1C1C1E", initialGrams: 1000, remainingGrams: 640,
            spoolWeightGrams: 220, price: 720, currency: "EGP",
            purchasedAt: Date().timeIntervalSince1970 - 2_600_000, notes: "",
            active: true, archived: false
        ),
        FilamentSpool(
            id: "demo-spool-2", brand: "Sunlu", material: "PETG", colorName: "شفاف",
            colorHex: "#D8E2E8", initialGrams: 1000, remainingGrams: 85,
            spoolWeightGrams: 210, price: 810, currency: "EGP",
            purchasedAt: Date().timeIntervalSince1970 - 7_600_000, notes: "",
            active: false, archived: false
        )
    ]

    static let summary = FilamentSummary(
        spoolCount: 2, totalRemainingGrams: 725, totalValue: 521,
        byMaterial: ["PLA+": 640, "PETG": 85], activeSpoolID: "demo-spool-1"
    )

    static let products: [Product] = [
        Product(
            id: "demo-product-1", itemID: "demo-keychain", nameAR: "ميدالية مفاتيح مخصصة",
            nameEN: "Custom keychain", sku: "KC-001", image: nil, material: "PLA",
            colors: ["#1C1C1E", "#E5484D"], printCost: 6.5, sellingPrice: 35,
            currency: "EGP", madeToOrder: true, stock: 0, notes: ""
        )
    ]

    static let maintenance = MaintenanceStatus(
        totalPrints: 63, totalPrintHours: 214.5, totalFilamentGrams: 4_812,
        tasks: [
            MaintenanceTask(
                id: "lubricate_rods", nameAR: "تشحيم الأعمدة", nameEN: "Lubricate rods",
                icon: "drop", intervalHours: 200, intervalPrints: nil, intervalDays: nil,
                lastDoneAt: Date().timeIntervalSince1970 - 1_900_000, enabled: true,
                builtin: true, progress: 0.92, due: false, dueReason: "",
                remainingHours: 16, remainingPrints: nil, remainingDays: nil
            ),
            MaintenanceTask(
                id: "clean_nozzle", nameAR: "تنظيف الفوهة", nameEN: "Clean nozzle",
                icon: "sparkles", intervalHours: nil, intervalPrints: 25, intervalDays: nil,
                lastDoneAt: Date().timeIntervalSince1970 - 900_000, enabled: true,
                builtin: true, progress: 1.0, due: true, dueReason: "prints",
                remainingHours: nil, remainingPrints: 0, remainingDays: nil
            )
        ],
        dueCount: 1
    )

    static let queue = QueueState(
        jobs: [
            QueueJob(
                id: "demo-job-1", itemID: "demo-keychain", gcodePath: "keychain_0.2_PLA.gcode",
                displayName: "ميدالية مفاتيح", material: "PLA", estimatedSeconds: 900,
                filamentGrams: 4, position: 0, status: "waiting"
            )
        ],
        bedClear: false,
        nextJob: QueueJob(
            id: "demo-job-1", itemID: "demo-keychain", gcodePath: "keychain_0.2_PLA.gcode",
            displayName: "ميدالية مفاتيح", material: "PLA", estimatedSeconds: 900,
            filamentGrams: 4, position: 0, status: "waiting"
        ),
        totalSeconds: 900, totalFilamentGrams: 4, blockedReasonKey: "queue.blocked.bed_not_clear"
    )

    static let cost = CostBreakdown(
        currency: "EGP", quantity: 1,
        lines: [
            CostLine(key: "cost.line.filament", amount: 16.8, detail: "24 g × 0.70"),
            CostLine(key: "cost.line.electricity", amount: 0.41, detail: "1.5 h × 180 W"),
            CostLine(key: "cost.line.machine", amount: 7.5, detail: "1.5 h × 5.00"),
            CostLine(key: "cost.line.labour", amount: 10, detail: ""),
            CostLine(key: "cost.line.failure", amount: 2.78, detail: "8%")
        ],
        costPerUnit: 37.49, totalCost: 37.49, suggestedPricePerUnit: 55,
        suggestedPriceTotal: 55, profitPerUnit: 17.51, profitPercent: 40,
        printHours: 1.5, filamentGrams: 24
    )
}
