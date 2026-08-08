import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Filament

struct FilamentSpool: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let brand: String
    let material: String
    let colorName: String
    let colorHex: String
    let initialGrams: Double
    let remainingGrams: Double
    let spoolWeightGrams: Double
    let price: Double
    let currency: String
    let purchasedAt: Double?
    let notes: String
    let active: Bool
    let archived: Bool

    var percentRemaining: Double {
        guard initialGrams > 0 else { return 0 }
        return min(1, max(0, remainingGrams / initialGrams))
    }

    var costPerGram: Double {
        guard initialGrams > 0, price > 0 else { return 0 }
        return price / initialGrams
    }

    var color: Color { Color(hex: colorHex) ?? Theme.accent }

    var displayName: String {
        let parts = [brand, material, colorName].filter { !$0.isEmpty }
        return parts.isEmpty ? material : parts.joined(separator: " · ")
    }

    enum CodingKeys: String, CodingKey {
        case id, brand, material, price, currency, notes, active, archived
        case colorName = "color_name"
        case colorHex = "color_hex"
        case initialGrams = "initial_grams"
        case remainingGrams = "remaining_grams"
        case spoolWeightGrams = "spool_weight_g"
        case purchasedAt = "purchased_at"
    }
}

struct FilamentSpoolPayload: Encodable {
    var brand: String = ""
    var material: String = "PLA"
    var colorName: String = ""
    var colorHex: String = "#333333"
    var initialGrams: Double = 1000
    var remainingGrams: Double?
    var price: Double = 0
    var currency: String = "EGP"
    var notes: String = ""
    var active: Bool = false

    enum CodingKeys: String, CodingKey {
        case brand, material, price, currency, notes, active
        case colorName = "color_name"
        case colorHex = "color_hex"
        case initialGrams = "initial_grams"
        case remainingGrams = "remaining_grams"
    }
}

struct FilamentSummary: Decodable, Equatable {
    let spoolCount: Int
    let totalRemainingGrams: Double
    let totalValue: Double
    let byMaterial: [String: Double]
    let activeSpoolID: String?

    enum CodingKeys: String, CodingKey {
        case spoolCount = "spool_count"
        case totalRemainingGrams = "total_remaining_grams"
        case totalValue = "total_value"
        case byMaterial = "by_material"
        case activeSpoolID = "active_spool_id"
    }

    static let empty = FilamentSummary(
        spoolCount: 0, totalRemainingGrams: 0, totalValue: 0, byMaterial: [:], activeSpoolID: nil
    )
}

struct FilamentCheck: Decodable, Equatable {
    let ok: Bool
    let spool: FilamentSpool?
    let requiredGrams: Double
    let remainingGrams: Double
    let marginGrams: Double
    let messageKey: String
    let hasActiveSpool: Bool

    enum CodingKeys: String, CodingKey {
        case ok, spool
        case requiredGrams = "required_grams"
        case remainingGrams = "remaining_grams"
        case marginGrams = "margin_grams"
        case messageKey = "message_key"
        case hasActiveSpool = "has_active_spool"
    }
}

// MARK: - Cost

struct CostSettings: Codable, Equatable {
    var currency: String
    var filamentPricePerKg: Double
    var electricityPricePerKwh: Double
    var printerWatts: Double
    var machineHourlyRate: Double
    var failureRatePercent: Double
    var labourPerPrint: Double
    var packagingPerPrint: Double
    var otherPerPrint: Double
    var profitPercent: Double
    var roundSellingPriceTo: Double

    enum CodingKeys: String, CodingKey {
        case currency
        case filamentPricePerKg = "filament_price_per_kg"
        case electricityPricePerKwh = "electricity_price_per_kwh"
        case printerWatts = "printer_watts"
        case machineHourlyRate = "machine_hourly_rate"
        case failureRatePercent = "failure_rate_percent"
        case labourPerPrint = "labour_per_print"
        case packagingPerPrint = "packaging_per_print"
        case otherPerPrint = "other_per_print"
        case profitPercent = "profit_percent"
        case roundSellingPriceTo = "round_selling_price_to"
    }

    static let `default` = CostSettings(
        currency: "EGP", filamentPricePerKg: 700, electricityPricePerKwh: 1.5,
        printerWatts: 180, machineHourlyRate: 5, failureRatePercent: 8,
        labourPerPrint: 10, packagingPerPrint: 0, otherPerPrint: 0,
        profitPercent: 40, roundSellingPriceTo: 5
    )
}

struct CostRequestPayload: Encodable {
    var filamentGrams: Double
    var printSeconds: Double
    var quantity: Int = 1
    var extraCost: Double = 0
    var profitPercent: Double?
    var spoolID: String?

    enum CodingKeys: String, CodingKey {
        case quantity
        case filamentGrams = "filament_grams"
        case printSeconds = "print_seconds"
        case extraCost = "extra_cost"
        case profitPercent = "profit_percent"
        case spoolID = "spool_id"
    }
}

struct CostLine: Decodable, Equatable, Identifiable {
    let key: String
    let amount: Double
    let detail: String

    var id: String { key }
}

struct CostBreakdown: Decodable, Equatable {
    let currency: String
    let quantity: Int
    let lines: [CostLine]
    let costPerUnit: Double
    let totalCost: Double
    let suggestedPricePerUnit: Double
    let suggestedPriceTotal: Double
    let profitPerUnit: Double
    let profitPercent: Double
    let printHours: Double
    let filamentGrams: Double

    enum CodingKeys: String, CodingKey {
        case currency, quantity, lines
        case costPerUnit = "cost_per_unit"
        case totalCost = "total_cost"
        case suggestedPricePerUnit = "suggested_price_per_unit"
        case suggestedPriceTotal = "suggested_price_total"
        case profitPerUnit = "profit_per_unit"
        case profitPercent = "profit_percent"
        case printHours = "print_hours"
        case filamentGrams = "filament_grams"
    }
}

// MARK: - Products

struct Product: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let itemID: String?
    let nameAR: String
    let nameEN: String
    let sku: String
    let image: String?
    let material: String
    let colors: [String]
    let printCost: Double
    let sellingPrice: Double
    let currency: String
    let madeToOrder: Bool
    let stock: Int
    let notes: String

    var displayName: String { nameAR.isEmpty ? nameEN : nameAR }
    var margin: Double { sellingPrice - printCost }
    var marginPercent: Double { printCost > 0 ? margin / printCost * 100 : 0 }

    enum CodingKeys: String, CodingKey {
        case id, sku, image, material, colors, currency, stock, notes
        case itemID = "item_id"
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case printCost = "print_cost"
        case sellingPrice = "selling_price"
        case madeToOrder = "made_to_order"
    }
}

struct ProductPayload: Encodable {
    var itemID: String?
    var nameAR: String = ""
    var nameEN: String = ""
    var sku: String = ""
    var material: String = "PLA"
    var colors: [String] = []
    var printCost: Double = 0
    var sellingPrice: Double = 0
    var currency: String = "EGP"
    var madeToOrder: Bool = true
    var stock: Int = 0
    var notes: String = ""

    enum CodingKeys: String, CodingKey {
        case sku, material, colors, currency, stock, notes
        case itemID = "item_id"
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case printCost = "print_cost"
        case sellingPrice = "selling_price"
        case madeToOrder = "made_to_order"
    }
}

// MARK: - Maintenance

struct MaintenanceTask: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let nameAR: String
    let nameEN: String
    let icon: String
    let intervalHours: Double?
    let intervalPrints: Int?
    let intervalDays: Int?
    let lastDoneAt: Double?
    let enabled: Bool
    let builtin: Bool
    let progress: Double
    let due: Bool
    let dueReason: String
    let remainingHours: Double?
    let remainingPrints: Int?
    let remainingDays: Int?

    var displayName: String { nameAR.isEmpty ? nameEN : nameAR }

    enum CodingKeys: String, CodingKey {
        case id, icon, enabled, builtin, progress, due
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case intervalHours = "interval_hours"
        case intervalPrints = "interval_prints"
        case intervalDays = "interval_days"
        case lastDoneAt = "last_done_at"
        case dueReason = "due_reason"
        case remainingHours = "remaining_hours"
        case remainingPrints = "remaining_prints"
        case remainingDays = "remaining_days"
    }
}

struct MaintenanceStatus: Decodable, Equatable {
    let totalPrints: Int
    let totalPrintHours: Double
    let totalFilamentGrams: Double
    let tasks: [MaintenanceTask]
    let dueCount: Int

    enum CodingKeys: String, CodingKey {
        case tasks
        case totalPrints = "total_prints"
        case totalPrintHours = "total_print_hours"
        case totalFilamentGrams = "total_filament_grams"
        case dueCount = "due_count"
    }

    static let empty = MaintenanceStatus(
        totalPrints: 0, totalPrintHours: 0, totalFilamentGrams: 0, tasks: [], dueCount: 0
    )
}

// MARK: - Print queue

struct QueueJob: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let itemID: String?
    let gcodePath: String
    let displayName: String
    let material: String
    let estimatedSeconds: Double?
    let filamentGrams: Double?
    let position: Int
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, position, status, material
        case itemID = "item_id"
        case gcodePath = "gcode_path"
        case displayName = "display_name"
        case estimatedSeconds = "estimated_seconds"
        case filamentGrams = "filament_g"
    }
}

struct QueueState: Decodable, Equatable {
    let jobs: [QueueJob]
    let bedClear: Bool
    let nextJob: QueueJob?
    let totalSeconds: Double
    let totalFilamentGrams: Double
    let blockedReasonKey: String

    var waiting: [QueueJob] { jobs.filter { $0.status == "waiting" } }

    enum CodingKeys: String, CodingKey {
        case jobs
        case bedClear = "bed_clear"
        case nextJob = "next_job"
        case totalSeconds = "total_seconds"
        case totalFilamentGrams = "total_filament_g"
        case blockedReasonKey = "blocked_reason_key"
    }

    static let empty = QueueState(
        jobs: [], bedClear: false, nextJob: nil, totalSeconds: 0,
        totalFilamentGrams: 0, blockedReasonKey: ""
    )
}

struct QueueJobPayload: Encodable {
    let gcodePath: String
    var itemID: String?
    var displayName: String = ""
    var material: String = ""
    var estimatedSeconds: Double?
    var filamentGrams: Double?

    enum CodingKeys: String, CodingKey {
        case material
        case gcodePath = "gcode_path"
        case itemID = "item_id"
        case displayName = "display_name"
        case estimatedSeconds = "estimated_seconds"
        case filamentGrams = "filament_g"
    }
}

// MARK: - Diagnostics & knowledge

struct DiagnosticCheck: Decodable, Identifiable, Equatable {
    let id: String
    let nameAR: String
    let nameEN: String
    let status: String            // ok | warning | error
    let detail: String
    let hintKey: String

    var displayName: String { nameAR.isEmpty ? nameEN : nameAR }

    var symbol: String {
        switch status {
        case "ok": return "checkmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch status {
        case "ok": return Theme.printing
        case "warning": return Theme.paused
        default: return Theme.danger
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, detail
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case hintKey = "hint_key"
    }
}

struct DiagnosticsReport: Decodable, Equatable {
    let generatedAt: Double
    let version: String
    let overall: String
    let checks: [DiagnosticCheck]
    let summaryAR: String

    enum CodingKeys: String, CodingKey {
        case version, overall, checks
        case generatedAt = "generated_at"
        case summaryAR = "summary_ar"
    }
}

struct TranslatedError: Decodable, Equatable {
    let matched: Bool
    let code: String
    let titleAR: String
    let titleEN: String
    let explanationAR: String
    let explanationEN: String
    let causesAR: [String]
    let checksAR: [String]
    let severity: String
    let original: String

    enum CodingKeys: String, CodingKey {
        case matched, code, severity, original
        case titleAR = "title_ar"
        case titleEN = "title_en"
        case explanationAR = "explanation_ar"
        case explanationEN = "explanation_en"
        case causesAR = "causes_ar"
        case checksAR = "checks_ar"
    }
}

struct TroubleshootingStep: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let questionAR: String
    let questionEN: String
    let yesNext: String?
    let noNext: String?
    let adviceAR: String
    let adviceEN: String

    var isLeaf: Bool { yesNext == nil && noNext == nil }

    enum CodingKeys: String, CodingKey {
        case id
        case questionAR = "question_ar"
        case questionEN = "question_en"
        case yesNext = "yes_next"
        case noNext = "no_next"
        case adviceAR = "advice_ar"
        case adviceEN = "advice_en"
    }
}

struct TroubleshootingTopic: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let titleAR: String
    let titleEN: String
    let icon: String
    let summaryAR: String
    let firstStep: String
    let steps: [TroubleshootingStep]
    let quickFixesAR: [String]

    var displayTitle: String { titleAR.isEmpty ? titleEN : titleAR }

    func step(_ identifier: String) -> TroubleshootingStep? {
        steps.first { $0.id == identifier }
    }

    enum CodingKeys: String, CodingKey {
        case id, icon, steps
        case titleAR = "title_ar"
        case titleEN = "title_en"
        case summaryAR = "summary_ar"
        case firstStep = "first_step"
        case quickFixesAR = "quick_fixes_ar"
    }
}

struct BedMeshReport: Decodable, Equatable {
    let available: Bool
    let profileName: String?
    let matrix: [[Double]]?
    let highest: Double?
    let lowest: Double?
    let range: Double?
    let verdict: String?
    let verdictKey: String?
    let messageKey: String?

    enum CodingKeys: String, CodingKey {
        case available, matrix, highest, lowest, range, verdict
        case profileName = "profile_name"
        case verdictKey = "verdict_key"
        case messageKey = "message_key"
    }
}

struct BackupInfo: Decodable, Identifiable, Equatable {
    let filename: String
    let path: String
    let sizeBytes: Int
    let createdAt: Double
    let contents: [String]

    var id: String { filename }

    enum CodingKeys: String, CodingKey {
        case filename, path, contents
        case sizeBytes = "size_bytes"
        case createdAt = "created_at"
    }
}

// MARK: - Summary (one call for the whole Home screen)

struct PrintingItemInfo: Decodable, Equatable {
    let id: String
    let nameAR: String
    let nameEN: String
    let thumbnail: String?
    let heroImage: String?
    let category: String
    let recommendedMaterial: String

    var displayName: String { nameAR.isEmpty ? nameEN : nameAR }

    enum CodingKeys: String, CodingKey {
        case id, category, thumbnail
        case nameAR = "name_ar"
        case nameEN = "name_en"
        case heroImage = "hero_image"
        case recommendedMaterial = "recommended_material"
    }
}

struct PrinterTotals: Decodable, Equatable {
    let totalPrintHours: Double
    let totalPrints: Int
    let totalFilamentGrams: Double

    enum CodingKeys: String, CodingKey {
        case totalPrintHours = "total_print_hours"
        case totalPrints = "total_prints"
        case totalFilamentGrams = "total_filament_grams"
    }

    static let empty = PrinterTotals(totalPrintHours: 0, totalPrints: 0, totalFilamentGrams: 0)
}

struct LibraryStats: Decodable, Equatable {
    let total: Int
    let favourites: Int
    let products: Int
    let prints: Int

    static let empty = LibraryStats(total: 0, favourites: 0, products: 0, prints: 0)
}

struct BackendSummary: Decodable, Equatable {
    let printer: BackendPrinterStatus
    let item: PrintingItemInfo?
    let power: BackendPowerStatus
    let camera: CameraStatus
    let recording: RecordingStatus
    let timelapse: TimelapseStatus
    let vision: VisionStatus
    let queue: QueueState
    let filament: FilamentSummary
    let library: LibraryStats
    let totals: PrinterTotals
    let maintenanceDue: Int

    enum CodingKeys: String, CodingKey {
        case printer, item, power, camera, recording, timelapse, vision, queue
        case filament, library, totals
        case maintenanceDue = "maintenance_due"
    }
}

// MARK: - Colour helper

extension Color {
    /// "#RRGGBB" or "RRGGBB".
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255.0,
            green: Double((number >> 8) & 0xFF) / 255.0,
            blue: Double(number & 0xFF) / 255.0
        )
    }

    var hexString: String {
        #if canImport(UIKit)
        let components = UIColor(self).cgColor.components ?? [0, 0, 0]
        let red = Int((components.count > 0 ? components[0] : 0) * 255)
        let green = Int((components.count > 1 ? components[1] : 0) * 255)
        let blue = Int((components.count > 2 ? components[2] : 0) * 255)
        return String(format: "#%02X%02X%02X", red, green, blue)
        #else
        return "#333333"
        #endif
    }
}
