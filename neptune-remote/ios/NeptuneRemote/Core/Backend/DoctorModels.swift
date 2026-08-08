import Foundation
import SwiftUI

// Mirrors raspberry-pi/app/doctor, app/safety, app/klipper, app/gcode, app/preflight.

// MARK: - Diagnosis

struct DoctorFinding: Decodable, Identifiable, Equatable, Hashable {
    let code: String
    let subsystem: String
    let severity: String          // info | warning | critical
    let title: String
    let cause: String
    let recommendation: String
    let autoFix: String?
    let autoFixLabel: String
    let manualSteps: [String]
    let detail: String

    var id: String { "\(subsystem).\(code)" }

    var isCritical: Bool { severity == "critical" }
    var needsHands: Bool { !manualSteps.isEmpty }

    var color: Color {
        switch severity {
        case "critical": return Theme.danger
        case "warning": return Theme.paused
        default: return Theme.accent
        }
    }

    var symbol: String {
        switch severity {
        case "critical": return "exclamationmark.octagon.fill"
        case "warning": return "exclamationmark.triangle.fill"
        default: return "info.circle.fill"
        }
    }

    enum CodingKeys: String, CodingKey {
        case code, subsystem, severity, title, cause, recommendation, detail
        case autoFix = "auto_fix"
        case autoFixLabel = "auto_fix_label"
        case manualSteps = "manual_steps"
    }
}

struct HealthCard: Decodable, Identifiable, Equatable, Hashable {
    let subsystem: String
    let health: String            // green | yellow | red | unknown
    let status: String
    let detail: String
    let recommendation: String
    let checkedAt: Double

    var id: String { subsystem }

    var color: Color {
        switch health {
        case "green": return Theme.printing
        case "yellow": return Theme.paused
        case "red": return Theme.danger
        default: return Theme.idle
        }
    }

    var symbol: String {
        switch health {
        case "green": return "checkmark.circle.fill"
        case "yellow": return "exclamationmark.triangle.fill"
        case "red": return "xmark.octagon.fill"
        default: return "questionmark.circle"
        }
    }

    /// Localization key for the subsystem's display name.
    var nameKey: String { "subsystem.\(subsystem)" }

    var icon: String { DoctorCatalog.icon(forSubsystem: subsystem) }

    enum CodingKeys: String, CodingKey {
        case subsystem, health, status, detail, recommendation
        case checkedAt = "checked_at"
    }
}

struct DiagnosisReport: Decodable, Equatable {
    let generatedAt: Double
    let overall: String
    let summary: String
    let safeToPrint: Bool
    let criticalCount: Int
    let warningCount: Int
    let findings: [DoctorFinding]
    let cards: [HealthCard]

    var isHealthy: Bool { overall == "green" }

    var color: Color {
        switch overall {
        case "green": return Theme.printing
        case "yellow": return Theme.paused
        case "red": return Theme.danger
        default: return Theme.idle
        }
    }

    enum CodingKeys: String, CodingKey {
        case overall, summary, findings, cards
        case generatedAt = "generated_at"
        case safeToPrint = "safe_to_print"
        case criticalCount = "critical_count"
        case warningCount = "warning_count"
    }

    static let empty = DiagnosisReport(
        generatedAt: 0, overall: "unknown", summary: "", safeToPrint: true,
        criticalCount: 0, warningCount: 0, findings: [], cards: []
    )
}

// MARK: - Safety decisions

struct SafetyIssue: Decodable, Identifiable, Equatable, Hashable {
    let code: String
    let severity: String
    let message: String
    let detail: String
    let remedy: String

    var id: String { code + message }
}

struct CommandDecision: Decodable, Equatable {
    let original: String
    let command: String
    let kind: String
    let severity: String          // ok | warning | blocked
    let allowed: Bool
    let modified: Bool
    let requiresBackup: Bool
    let adjustments: [String]
    let issues: [SafetyIssue]

    var blocked: Bool { !allowed }

    var color: Color {
        switch severity {
        case "blocked": return Theme.danger
        case "warning": return Theme.paused
        default: return Theme.printing
        }
    }

    enum CodingKeys: String, CodingKey {
        case original, command, kind, severity, allowed, modified, adjustments, issues
        case requiresBackup = "requires_backup"
    }
}

// MARK: - Workflows

struct WorkflowStep: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let description: String
    let commands: [String]
    let manual: Bool
    let state: String             // pending | running | done | failed | skipped | waiting_for_user
    let message: String
    let output: String

    var isDone: Bool { state == "done" || state == "skipped" }
    var isFailed: Bool { state == "failed" }
    var isActive: Bool { state == "running" || state == "waiting_for_user" }

    var symbol: String {
        switch state {
        case "done": return "checkmark.circle.fill"
        case "skipped": return "arrow.right.circle"
        case "failed": return "xmark.octagon.fill"
        case "running": return "circle.dotted"
        case "waiting_for_user": return "hand.raised.fill"
        default: return "circle"
        }
    }

    var color: Color {
        switch state {
        case "done": return Theme.printing
        case "skipped": return Theme.idle
        case "failed": return Theme.danger
        case "waiting_for_user": return Theme.paused
        case "running": return Theme.accent
        default: return Theme.idle
        }
    }
}

struct WorkflowRun: Decodable, Equatable {
    let id: String
    let kind: String
    let title: String
    let state: String             // idle | running | waiting_for_user | done | failed | cancelled
    let message: String
    let current: Int
    let progress: Double
    let finished: Bool
    let steps: [WorkflowStep]
    let data: WorkflowData

    var activeStep: WorkflowStep? {
        guard current >= 0, current < steps.count else { return nil }
        return steps[current]
    }

    var needsUser: Bool { state == "waiting_for_user" }
    var failed: Bool { state == "failed" }

    var color: Color {
        switch state {
        case "done": return Theme.printing
        case "failed": return Theme.danger
        case "waiting_for_user": return Theme.paused
        default: return Theme.accent
        }
    }
}

/// The workflow's own result payload. Decoded leniently: the backend adds keys
/// per workflow, and an unknown one must not break the whole response.
struct WorkflowData: Decodable, Equatable {
    var screws: ScrewsTiltReport?
    var probeTriggered: Bool?
    var acceptOutput: String?
    var meshOutput: String?
    var axisVerifyOutput: String?

    enum CodingKeys: String, CodingKey {
        case screws
        case probeTriggered = "probe_triggered"
        case acceptOutput = "accept_output"
        case meshOutput = "mesh_output"
        case axisVerifyOutput = "axis_verify_output"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        screws = try container.decodeIfPresent(ScrewsTiltReport.self, forKey: .screws)
        probeTriggered = try container.decodeIfPresent(Bool.self, forKey: .probeTriggered)
        acceptOutput = try container.decodeIfPresent(String.self, forKey: .acceptOutput)
        meshOutput = try container.decodeIfPresent(String.self, forKey: .meshOutput)
        axisVerifyOutput = try container.decodeIfPresent(String.self, forKey: .axisVerifyOutput)
    }

    init() {}
}

struct WorkflowOption: Decodable, Identifiable, Equatable, Hashable {
    let kind: String
    let title: String

    var id: String { kind }

    var icon: String { DoctorCatalog.icon(forWorkflow: kind) }
    var titleKey: String { "workflow.\(kind)" }
    var descriptionKey: String { "workflow.\(kind).description" }
}

// MARK: - Bed screws

struct ScrewAdjustment: Decodable, Identifiable, Equatable, Hashable {
    let name: String
    let positionKey: String
    let x: Double
    let y: Double
    let z: Double
    let isBase: Bool
    let direction: String         // CW | CCW | ""
    let clock: String
    let turns: Double
    let signedTurns: Double
    let adjusted: Bool
    let severity: String          // ok | medium | high
    let instruction: String

    var id: String { name }

    /// Layout slot on the bed diagram; empty when Klipper used a custom label.
    var slot: String { positionKey }

    var color: Color {
        switch severity {
        case "high": return Theme.danger
        case "medium": return Theme.paused
        default: return Theme.printing
        }
    }

    var isClockwise: Bool { direction == "CW" }

    /// Rotation for the arrow, so a bigger correction sweeps further.
    var arrowDegrees: Double {
        min(turns, 1.0) * 360.0 * (isClockwise ? 1 : -1)
    }

    enum CodingKeys: String, CodingKey {
        case name, x, y, z, direction, clock, turns, adjusted, severity, instruction
        case positionKey = "position_key"
        case isBase = "is_base"
        case signedTurns = "signed_turns"
    }
}

struct ScrewsTiltReport: Decodable, Equatable {
    let verdict: String           // level | adjust | poor | unknown
    let level: Bool
    let summary: String
    let maxTurns: Double
    let zSpread: Double
    let screws: [ScrewAdjustment]
    let parseFailed: Bool

    var color: Color {
        switch verdict {
        case "level": return Theme.printing
        case "adjust": return Theme.paused
        case "poor": return Theme.danger
        default: return Theme.idle
        }
    }

    func screw(at slot: String) -> ScrewAdjustment? {
        screws.first { $0.positionKey == slot }
    }

    enum CodingKeys: String, CodingKey {
        case verdict, level, summary, screws
        case maxTurns = "max_turns"
        case zSpread = "z_spread"
        case parseFailed = "parse_failed"
    }
}

// MARK: - Config versions

struct ConfigVersion: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let createdAt: Double
    let label: String
    let reason: String
    let sizeBytes: Int
    let sha256: String
    let golden: Bool
    let provenPrints: Int
    let lastProvenAt: Double?
    let note: String
    let sectionCount: Int

    var displayName: String {
        if !label.isEmpty { return label }
        return Format.date(createdAt)
    }

    var reasonKey: String { "config.reason.\(reason)" }

    enum CodingKeys: String, CodingKey {
        case id, label, reason, sha256, golden, note
        case createdAt = "created_at"
        case sizeBytes = "size_bytes"
        case provenPrints = "proven_prints"
        case lastProvenAt = "last_proven_at"
        case sectionCount = "section_count"
    }
}

struct ConfigOptionChange: Decodable, Equatable, Hashable {
    let option: String
    let before: String?
    let after: String?
}

struct ConfigSectionChange: Decodable, Identifiable, Equatable, Hashable {
    let section: String
    let options: [ConfigOptionChange]

    var id: String { section }
}

struct ConfigDiff: Decodable, Equatable {
    let addedSections: [String]
    let removedSections: [String]
    let changedSections: [ConfigSectionChange]
    let autosaveChanges: [ConfigSectionChange]
    let identical: Bool

    var changeCount: Int {
        addedSections.count + removedSections.count + changedSections.count
    }

    enum CodingKeys: String, CodingKey {
        case identical
        case addedSections = "added_sections"
        case removedSections = "removed_sections"
        case changedSections = "changed_sections"
        case autosaveChanges = "autosave_changes"
    }
}

struct ConfigValidationFinding: Decodable, Identifiable, Equatable, Hashable {
    let code: String
    let severity: String
    let section: String
    let message: String
    let detail: String
    let remedy: String
    let line: Int?

    var id: String { "\(section).\(code).\(line ?? 0)" }
}

struct ConfigValidation: Decodable, Equatable {
    let verdict: String
    let ok: Bool
    let errorCount: Int
    let warningCount: Int
    let findings: [ConfigValidationFinding]

    enum CodingKeys: String, CodingKey {
        case verdict, ok, findings
        case errorCount = "error_count"
        case warningCount = "warning_count"
    }
}

struct LiveConfig: Decodable, Equatable {
    let text: String
    let sha256: String
    let sections: [String]
    let validation: ConfigValidation
    let matchesKnownGood: Bool
    let knownGood: ConfigVersion?

    enum CodingKeys: String, CodingKey {
        case text, sha256, sections, validation
        case matchesKnownGood = "matches_known_good"
        case knownGood = "known_good"
    }
}

// MARK: - G-code inspection

struct GCodeIssue: Decodable, Identifiable, Equatable, Hashable {
    let code: String
    let severity: String
    let message: String
    let detail: String
    let remedy: String
    let line: Int?
    let sample: String

    var id: String { "\(code)-\(line ?? 0)-\(message.hashValue)" }

    var color: Color {
        switch severity {
        case "error": return Theme.danger
        case "warning": return Theme.paused
        default: return Theme.accent
        }
    }
}

struct GCodeBounds: Decodable, Equatable {
    let minX: Double?
    let maxX: Double?
    let minY: Double?
    let maxY: Double?
    let minZ: Double?
    let maxZ: Double?

    var description: String {
        guard let minX, let maxX, let minY, let maxY, let minZ, let maxZ else { return "--" }
        return String(
            format: "X %.1f…%.1f   Y %.1f…%.1f   Z %.1f…%.1f",
            minX, maxX, minY, maxY, minZ, maxZ
        )
    }

    enum CodingKeys: String, CodingKey {
        case minX = "min_x", maxX = "max_x"
        case minY = "min_y", maxY = "max_y"
        case minZ = "min_z", maxZ = "max_z"
    }
}

struct UnsupportedCommand: Decodable, Identifiable, Equatable, Hashable {
    let command: String
    let line: Int
    let reason: String

    var id: String { command }
}

struct GCodeReport: Decodable, Equatable {
    let verdict: String           // safe | warning | blocked
    let blocked: Bool
    let errorCount: Int
    let warningCount: Int
    let issues: [GCodeIssue]

    let slicer: String
    let slicerVersion: String
    let profileName: String
    let filament: String
    let verifiedProfile: Bool
    let profileStatus: String     // golden | known | unverified

    let bounds: GCodeBounds
    let estimatedSeconds: Double?
    let layerHeight: Double?
    let firstLayerHeight: Double?
    let nozzleDiameter: Double?
    let layerCount: Int?

    let maxRequestedFeedrate: Double?
    let maxRequestedAccel: Double?

    let positioningAbsolute: Bool?
    let extrusionRelative: Bool?
    let hasHome: Bool
    let setsHotendTemp: Bool
    let setsBedTemp: Bool

    let unsupported: [UnsupportedCommand]
    let linesScanned: Int

    var isVerified: Bool { profileStatus == "golden" }

    var color: Color {
        switch verdict {
        case "safe": return Theme.printing
        case "warning": return Theme.paused
        default: return Theme.danger
        }
    }

    var verdictKey: String { "gcode.verdict.\(verdict)" }
    var profileStatusKey: String { "gcode.profile.\(profileStatus)" }

    enum CodingKeys: String, CodingKey {
        case verdict, blocked, issues, slicer, filament, bounds, unsupported
        case errorCount = "error_count"
        case warningCount = "warning_count"
        case slicerVersion = "slicer_version"
        case profileName = "profile_name"
        case verifiedProfile = "verified_profile"
        case profileStatus = "profile_status"
        case estimatedSeconds = "estimated_seconds"
        case layerHeight = "layer_height"
        case firstLayerHeight = "first_layer_height"
        case nozzleDiameter = "nozzle_diameter"
        case layerCount = "layer_count"
        case maxRequestedFeedrate = "max_requested_feedrate"
        case maxRequestedAccel = "max_requested_accel"
        case positioningAbsolute = "positioning_absolute"
        case extrusionRelative = "extrusion_relative"
        case hasHome = "has_home"
        case setsHotendTemp = "sets_hotend_temp"
        case setsBedTemp = "sets_bed_temp"
        case linesScanned = "lines_scanned"
    }
}

// MARK: - Preflight

struct PreflightCheck: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let label: String
    let passed: Bool
    let severity: String
    let detail: String
    let remedy: String

    var color: Color {
        if passed { return Theme.printing }
        return severity == "error" ? Theme.danger : Theme.paused
    }

    var symbol: String {
        if passed { return "checkmark.circle.fill" }
        return severity == "error" ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }
}

struct PreflightBanner: Decodable, Equatable {
    let slicer: String
    let printerProfile: String
    let profileStatus: String
    let gcodeValidation: String
    let buildVolume: String
    let unsupportedCommands: String
    let motionLimits: String
    let bounds: String

    enum CodingKeys: String, CodingKey {
        case slicer, bounds
        case printerProfile = "printer_profile"
        case profileStatus = "profile_status"
        case gcodeValidation = "gcode_validation"
        case buildVolume = "build_volume"
        case unsupportedCommands = "unsupported_commands"
        case motionLimits = "motion_limits"
    }

    /// The rows shown before a print starts, in the order the brief specifies.
    var rows: [(labelKey: String, value: String)] {
        [
            ("preflight.row.slicer", slicer),
            ("preflight.row.profile", printerProfile),
            ("preflight.row.profile_status", profileStatus),
            ("preflight.row.validation", gcodeValidation),
            ("preflight.row.build_volume", buildVolume),
            ("preflight.row.unsupported", unsupportedCommands),
            ("preflight.row.motion", motionLimits)
        ]
    }
}

struct PreflightReport: Decodable, Equatable {
    let verdict: String           // ready | warning | blocked
    let ready: Bool
    let strict: Bool
    let summary: String
    let failureCount: Int
    let warningCount: Int
    let checks: [PreflightCheck]
    let gcode: GCodeReport?
    let banner: PreflightBanner?

    var color: Color {
        switch verdict {
        case "ready": return Theme.printing
        case "warning": return Theme.paused
        default: return Theme.danger
        }
    }

    var verdictKey: String { "preflight.verdict.\(verdict)" }

    enum CodingKeys: String, CodingKey {
        case verdict, ready, strict, summary, checks, gcode, banner
        case failureCount = "failure_count"
        case warningCount = "warning_count"
    }
}

// MARK: - Slicer profiles

struct SlicerProfile: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let displayName: String
    let version: Int
    let engine: String
    let golden: Bool
    let status: String
    let successfulPrints: Int
    let failedPrints: Int
    let createdAt: Double
    let promotedAt: Double?
    let note: String

    enum CodingKeys: String, CodingKey {
        case id, name, version, engine, golden, status, note
        case displayName = "display_name"
        case successfulPrints = "successful_prints"
        case failedPrints = "failed_prints"
        case createdAt = "created_at"
        case promotedAt = "promoted_at"
    }
}

// MARK: - Icons and labels

enum DoctorCatalog {
    static let subsystemIcons: [String: String] = [
        "connection": "network",
        "moonraker": "server.rack",
        "klipper": "cpu",
        "mcu": "memorychip",
        "config": "doc.text",
        "x_axis": "arrow.left.arrow.right",
        "y_axis": "arrow.up.arrow.down",
        "z_axis": "arrow.up.and.down.circle",
        "probe": "sensor.tag.radiowaves.forward",
        "bed": "square.3.layers.3d.bottom.filled",
        "hotend": "thermometer.high",
        "part_cooling": "wind",
        "filament_sensor": "circle.hexagongrid",
        "bed_mesh": "grid",
        "z_offset": "ruler",
        "motion_limits": "speedometer",
        "accelerometer": "waveform.path.ecg",
        "camera": "video",
        "host": "desktopcomputer",
        "storage": "internaldrive"
    ]

    static func icon(forSubsystem subsystem: String) -> String {
        subsystemIcons[subsystem] ?? "gearshape"
    }

    static let workflowIcons: [String: String] = [
        "safe_home": "house",
        "z_offset": "ruler",
        "screws_tilt": "dial.medium",
        "bed_mesh": "grid",
        "full_bed_calibration": "wand.and.stars",
        "axis_health": "waveform.path",
        "input_shaper": "waveform.path.ecg"
    ]

    static func icon(forWorkflow kind: String) -> String {
        workflowIcons[kind] ?? "wrench.and.screwdriver"
    }

    /// The six Neptune 3 Plus bed screw positions, laid out as the bed looks
    /// from above: rear at the top, front at the bottom.
    static let bedLayout: [[String]] = [
        ["left_rear", "right_rear"],
        ["left_middle", "right_middle"],
        ["left_front", "right_front"]
    ]

    static let screwLabelKeys: [String: String] = [
        "left_front": "screw.left_front",
        "left_middle": "screw.left_middle",
        "left_rear": "screw.left_rear",
        "right_front": "screw.right_front",
        "right_middle": "screw.right_middle",
        "right_rear": "screw.right_rear"
    ]
}
