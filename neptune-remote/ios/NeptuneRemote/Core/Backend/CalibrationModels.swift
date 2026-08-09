import Foundation

// Mirrors /api/slice/modes, /api/doctor/calibration/* and /api/history/learning.
//
// The shape of these is the point: every one of them carries the reasoning
// alongside the number. A mode says what it had to clamp and why, a calibration
// says what to measure and what the result means, a first-layer reading says
// which check failed when it will not answer. None of that survives if the app
// decodes only the values.

// MARK: - Print modes

struct PrintModeList: Decodable {
    var modes: [PrintMode] = []
    var printerProfile: String = ""
    var filamentProfile: String = ""
    /// True when the limits came from the live printer.cfg rather than the
    /// slicer's description of the machine.
    var limitsFromConfig: Bool = false
    var maxAccel: Double?
    var maxVelocity: Double?

    enum CodingKeys: String, CodingKey {
        case modes
        case printerProfile = "printer_profile"
        case filamentProfile = "filament_profile"
        case limitsFromConfig = "limits_from_config"
        case maxAccel = "max_accel"
        case maxVelocity = "max_velocity"
    }
}

struct PrintMode: Decodable, Identifiable, Equatable {
    var id: String = ""
    var titleAR: String = ""
    var titleEN: String = ""
    var descriptionAR: String = ""
    /// What this mode costs you. Shown next to the choice, not buried.
    var tradeoffAR: String = ""
    var layerHeight: Double = 0
    var perimeters: Int = 0
    var infillPercent: Int = 0
    var printSpeed: Double = 0
    var acceleration: Double = 0
    var volumetricFlow: Double = 0
    /// Time against the balanced mode. 1.0 is the same, 2.0 is twice as long.
    var relativeTime: Double = 1
    /// True when the material's melt rate is what limits this mode, not the
    /// settings — which is when a coarser mode stops buying any time.
    var flowLimited: Bool = false
    var wasClamped: Bool = false
    var adjustments: [ModeAdjustment] = []
    /// Chiefly "this will not actually be faster than X, and here is why".
    var notesAR: [String] = []

    var title: String { L.isArabic ? titleAR : titleEN }

    /// "40 % faster" / "2.6× longer", against balanced.
    var timeComparison: String {
        if abs(relativeTime - 1) < 0.05 { return L.t("mode.time.same") }
        if relativeTime < 1 {
            return L.t("mode.time.faster", Int(((1 - relativeTime) * 100).rounded()))
        }
        return L.t("mode.time.longer", String(format: "%.1f", relativeTime))
    }

    enum CodingKeys: String, CodingKey {
        case id, perimeters, adjustments
        case titleAR = "title_ar"
        case titleEN = "title_en"
        case descriptionAR = "description_ar"
        case tradeoffAR = "tradeoff_ar"
        case layerHeight = "layer_height"
        case infillPercent = "infill_percent"
        case printSpeed = "print_speed"
        case acceleration
        case volumetricFlow = "volumetric_flow"
        case relativeTime = "relative_time"
        case flowLimited = "flow_limited"
        case wasClamped = "was_clamped"
        case notesAR = "notes_ar"
    }
}

struct ModeAdjustment: Decodable, Equatable, Identifiable {
    var setting: String = ""
    var requested: Double = 0
    var applied: Double = 0
    var reasonAR: String = ""
    var reasonEN: String = ""

    var id: String { setting }
    var reason: String { L.isArabic ? reasonAR : reasonEN }

    enum CodingKeys: String, CodingKey {
        case setting, requested, applied
        case reasonAR = "reason_ar"
        case reasonEN = "reason_en"
    }
}

// MARK: - Calibration test prints

struct CalibrationTestSummary: Decodable, Identifiable, Equatable {
    var id: String = ""
    var titleAR: String = ""
    var titleEN: String = ""
    var ok: Bool = false
    /// Why this printer cannot run it — a missing [firmware_retraction], for
    /// instance. Shown instead of hiding the row.
    var blockers: [String] = []
    var estimatedMinutes: Double = 0

    var title: String { L.isArabic ? titleAR : titleEN }

    enum CodingKeys: String, CodingKey {
        case id, ok, blockers
        case titleAR = "title_ar"
        case titleEN = "title_en"
        case estimatedMinutes = "estimated_minutes"
    }
}

struct CalibrationTest: Decodable, Equatable {
    var id: String = ""
    var titleAR: String = ""
    var titleEN: String = ""
    var gcode: String = ""
    var instructionsAR: [String] = []
    var parameters: [String: Double] = [:]
    var estimatedMinutes: Double = 0

    var title: String { L.isArabic ? titleAR : titleEN }

    enum CodingKeys: String, CodingKey {
        case id, gcode, parameters
        case titleAR = "title_ar"
        case titleEN = "title_en"
        case instructionsAR = "instructions_ar"
        case estimatedMinutes = "estimated_minutes"
    }
}

struct FlowResult: Decodable {
    var flow: Double = 1
    var previousFlow: Double = 1
    var changePercent: Double = 0
    var noteAR: String = ""

    enum CodingKeys: String, CodingKey {
        case flow
        case previousFlow = "previous_flow"
        case changePercent = "change_percent"
        case noteAR = "note_ar"
    }
}

struct PressureAdvanceResult: Decodable {
    var pressureAdvance: Double = 0
    var command: String = ""
    var configAR: String = ""
    /// Always false: this edits printer.cfg, which this project never rewrites
    /// without a separate, explicitly confirmed step.
    var appliesImmediately: Bool = false

    enum CodingKeys: String, CodingKey {
        case command
        case pressureAdvance = "pressure_advance"
        case configAR = "config_ar"
        case appliesImmediately = "applies_immediately"
    }
}

// MARK: - First layer

struct FirstLayerReading: Decodable, Equatable {
    /// good | too_low | too_high | unreadable
    var verdict: String = "unreadable"
    var verdictAR: String = ""
    var readable: Bool = false
    /// Positive raises the nozzle. Nil whenever the image could not support a
    /// measurement — there is no low-confidence middle ground here, because a
    /// wrong Z offset drives the nozzle into the bed.
    var zAdjustMM: Double?
    var command: String?
    var confidence: Double = 0
    var measurements: [String: Double] = [:]
    var blockers: [String] = []
    var detailAR: String = ""
    var pattern: [String: Double] = [:]

    var needsAdjustment: Bool { readable && command != nil }

    enum CodingKeys: String, CodingKey {
        case verdict, readable, command, confidence, measurements, blockers, pattern
        case verdictAR = "verdict_ar"
        case zAdjustMM = "z_adjust_mm"
        case detailAR = "detail_ar"
    }
}

// MARK: - What the history has learned

struct LearningReport: Decodable, Equatable {
    var combinations: [LearnedCombination] = []
    var insights: [LearnedInsight] = []
    /// Median actual/estimated duration per material. Nil until there are
    /// enough completed prints of one to be worth stating.
    var durationAccuracy: [String: Double]?
    var minSamples: Int = 4
    var totalPrints: Int = 0

    enum CodingKeys: String, CodingKey {
        case combinations, insights
        case durationAccuracy = "duration_accuracy"
        case minSamples = "min_samples"
        case totalPrints = "total_prints"
    }
}

struct LearnedCombination: Decodable, Identifiable, Equatable {
    var key: String = ""
    var filamentType: String = ""
    var printProfile: String = ""
    var layerHeight: Double?
    var labelAR: String = ""
    var total: Int = 0
    var succeeded: Int = 0
    var failed: Int = 0
    var earlyFailures: Int = 0
    var lateFailures: Int = 0
    /// Nil below the minimum sample count — deliberately, so the UI cannot
    /// render a percentage that two prints do not support.
    var successRate: Double?
    var conclusive: Bool = false

    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, total, succeeded, failed, conclusive
        case filamentType = "filament_type"
        case printProfile = "print_profile"
        case layerHeight = "layer_height"
        case labelAR = "label_ar"
        case earlyFailures = "early_failures"
        case lateFailures = "late_failures"
        case successRate = "success_rate"
    }
}

struct LearnedInsight: Decodable, Identifiable, Equatable {
    var id: String = ""
    var titleAR: String = ""
    var detailAR: String = ""
    var suggestionAR: String = ""
    var combination: String?
    var samples: Int = 0

    var isWarning: Bool {
        id == "early_failures" || id == "poor_combination" || id == "material_struggles"
    }

    enum CodingKeys: String, CodingKey {
        case id, combination, samples
        case titleAR = "title_ar"
        case detailAR = "detail_ar"
        case suggestionAR = "suggestion_ar"
    }
}

// MARK: - Live anomalies

struct AnomalyStatus: Decodable, Equatable {
    var filename: String = ""
    var layersObserved: Int = 0
    var findings: [AnomalyFinding] = []
    var watching: Bool = false

    enum CodingKeys: String, CodingKey {
        case filename, findings, watching
        case layersObserved = "layers_observed"
    }
}

struct AnomalyFinding: Decodable, Identifiable, Equatable {
    var id: String = ""
    /// info | watch | warning | urgent
    var severity: String = "info"
    var titleAR: String = ""
    var titleEN: String = ""
    var detailAR: String = ""
    /// The arithmetic behind the claim, so it can be checked rather than
    /// believed.
    var evidence: [String: Double] = [:]
    var suggestionAR: String = ""
    var detectedAt: Double = 0

    var title: String { L.isArabic ? titleAR : titleEN }
    var isUrgent: Bool { severity == "urgent" }

    enum CodingKeys: String, CodingKey {
        case id, severity, evidence
        case titleAR = "title_ar"
        case titleEN = "title_en"
        case detailAR = "detail_ar"
        case suggestionAR = "suggestion_ar"
        case detectedAt = "detected_at"
    }
}
