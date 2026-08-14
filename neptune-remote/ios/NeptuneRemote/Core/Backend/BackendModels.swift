import Foundation

// Mirrors raspberry-pi/app/schemas.py

struct BackendHealth: Decodable, Equatable {
    let ok: Bool
    let version: String
    let moonrakerReachable: Bool
    let moonrakerURL: String
    let powerProvider: String
    let slicerEngine: String
    let slicerAvailable: Bool
    let authRequired: Bool

    enum CodingKeys: String, CodingKey {
        case ok, version
        case moonrakerReachable = "moonraker_reachable"
        case moonrakerURL = "moonraker_url"
        case powerProvider = "power_provider"
        case slicerEngine = "slicer_engine"
        case slicerAvailable = "slicer_available"
        case authRequired = "auth_required"
    }
}

struct BackendTailscale: Decodable, Equatable {
    let installed: Bool
    let running: Bool
    let hostname: String
    let ips: [String]
    let backendState: String

    enum CodingKeys: String, CodingKey {
        case installed, running, hostname, ips
        case backendState = "backend_state"
    }
}

struct BackendSystem: Decodable, Equatable {
    let hostname: String
    let platform: String
    let model: String
    let cpuPercent: Double
    let cpuTempC: Double?
    let loadAverage: [Double]
    let memoryTotalMB: Double
    let memoryUsedMB: Double
    let memoryPercent: Double
    let diskTotalGB: Double
    let diskUsedGB: Double
    let diskPercent: Double
    let uptimeSeconds: Double
    let ipAddresses: [String]
    let tailscale: BackendTailscale
    let throttled: String?

    enum CodingKeys: String, CodingKey {
        case hostname, platform, model, tailscale, throttled
        case cpuPercent = "cpu_percent"
        case cpuTempC = "cpu_temp_c"
        case loadAverage = "load_average"
        case memoryTotalMB = "memory_total_mb"
        case memoryUsedMB = "memory_used_mb"
        case memoryPercent = "memory_percent"
        case diskTotalGB = "disk_total_gb"
        case diskUsedGB = "disk_used_gb"
        case diskPercent = "disk_percent"
        case uptimeSeconds = "uptime_seconds"
        case ipAddresses = "ip_addresses"
    }
}

struct BackendPowerStatus: Decodable, Equatable {
    let provider: String
    let state: String
    let available: Bool
    let device: String
    let message: String
}

struct BackendPowerSafety: Decodable, Equatable {
    let safe: Bool
    let blockers: [String]
    let warnings: [String]
    let nozzleTemp: Double
    let bedTemp: Double
    let maxNozzleTemp: Double
    let maxBedTemp: Double
    let printing: Bool

    enum CodingKeys: String, CodingKey {
        case safe, blockers, warnings, printing
        case nozzleTemp = "nozzle_temp"
        case bedTemp = "bed_temp"
        case maxNozzleTemp = "max_nozzle_temp"
        case maxBedTemp = "max_bed_temp"
    }
}

struct BackendPowerAction: Decodable, Equatable {
    let ok: Bool
    let state: String
    let provider: String
    let message: String
}

struct BackendOK: Decodable {
    let ok: Bool
    let message: String
}

// MARK: - Files

struct BackendModelFile: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let filename: String
    let size: Int
    let modified: Double
    let fileExtension: String

    enum CodingKeys: String, CodingKey {
        case id, filename, size, modified
        case fileExtension = "extension"
    }
}

// MARK: - Placement

/// How a model is turned and sized before it reaches the slicer.
///
/// The file in the library is never modified. This is what gets sent with a
/// slice request, and the Pi writes a transformed copy for the slicer to read -
/// which is what makes a rotation something you can take back.
struct ModelTransform: Codable, Equatable {
    /// Degrees about X, then Y, then Z. The order is fixed, so the same values
    /// always reproduce the same orientation.
    var rotationDeg: [Double] = [0, 0, 0]
    /// Per-axis multiplier, so a model can be stretched as well as resized.
    var scale: [Double] = [1, 1, 1]
    var mirror: [Bool] = [false, false, false]
    /// Sit the result on the bed afterwards. The app always wants this: a model
    /// left hovering has its first layer printed in mid-air.
    var dropToBed: Bool = true
    var centerOnBed: Bool = true

    static let identity = ModelTransform()

    var isIdentity: Bool {
        rotationDeg == [0, 0, 0] && scale == [1, 1, 1] && mirror == [false, false, false]
    }

    /// Uniform scale, when all three axes agree. Nil for a stretched model,
    /// which is the signal the UI needs to show three fields instead of one.
    var uniformScale: Double? {
        guard scale.count == 3, scale[0] == scale[1], scale[1] == scale[2] else { return nil }
        return scale[0]
    }

    static func uniform(_ factor: Double) -> ModelTransform {
        ModelTransform(scale: [factor, factor, factor])
    }

    enum CodingKeys: String, CodingKey {
        case scale, mirror
        case rotationDeg = "rotation_deg"
        case dropToBed = "drop_to_bed"
        case centerOnBed = "center_on_bed"
    }
}

/// What an orientation costs, measured against the real mesh.
struct OrientationReport: Codable, Equatable {
    /// Area that would sit flat on the bed, mm². Bigger sticks better.
    var baseArea: Double = 0
    /// Area that would need support, mm². This is the number to minimise.
    var overhangArea: Double = 0
    var height: Double = 0
    var width: Double = 0
    var depth: Double = 0
    var needsSupport: Bool = false
    /// Whether the result is inside this printer's own build volume.
    var fits: Bool = true
    /// Plain Arabic, naming each axis that is over. Empty when it fits.
    var problemsAr: [String] = []

    enum CodingKeys: String, CodingKey {
        case height, width, depth, fits
        case baseArea = "base_area"
        case overhangArea = "overhang_area"
        case needsSupport = "needs_support"
        case problemsAr = "problems_ar"
    }
}

/// The way up the Pi recommends, with the evidence for it.
///
/// `current` is the same measurement for the model as it stands, so the app can
/// show what the change actually buys rather than asking to be trusted.
struct OrientationSuggestion: Codable, Equatable {
    var transform: ModelTransform
    var suggested: OrientationReport
    var current: OrientationReport

    /// How much support area the suggestion removes, as a fraction of what is
    /// there now. Nil when there was no support needed to begin with - the
    /// honest answer to "how much better" when the answer is "it already was".
    var overhangReduction: Double? {
        guard current.overhangArea > 0 else { return nil }
        let saved = current.overhangArea - suggested.overhangArea
        return max(0, saved / current.overhangArea)
    }

    /// Whether turning the model is actually worth doing.
    var isWorthApplying: Bool {
        if !current.fits && suggested.fits { return true }
        guard let reduction = overhangReduction else {
            return suggested.baseArea > current.baseArea * 1.2
        }
        return reduction > 0.1
    }
}

/// A layer the print stops at so the filament can be swapped.
///
/// One nozzle, several colours: the printer stops, you change the spool, it
/// carries on. `layer` is the first layer printed in the new colour, counting
/// the way the app shows layers - the first layer of the print is 1.
struct ColorChange: Codable, Equatable, Hashable, Identifiable {
    var layer: Int
    var color: String
    /// Height above the bed, filled in by the backend once the file is sliced.
    /// nil while the change is still only a request: the real height comes from
    /// the sliced file, because the first layer is usually thicker than the
    /// rest and multiplying out the layer height would be wrong by that much.
    var z: Double?

    var id: Int { layer }

    init(layer: Int, color: String, z: Double? = nil) {
        self.layer = layer
        self.color = color
        self.z = z
    }
}

struct BackendGCodeFile: Decodable, Identifiable, Equatable, Hashable {
    let path: String
    let filename: String
    let size: Int
    let modified: Double
    let estimatedTime: Double?
    let filamentTotalMM: Double?
    let filamentWeightG: Double?
    let layerHeight: Double?
    let firstLayerHeight: Double?
    let objectHeight: Double?
    let filamentType: String?
    let filamentName: String?
    let slicer: String?
    let thumbnailPath: String?
    let layerCount: Int?
    /// Filament swaps this file will stop for, read from its own header.
    ///
    /// Optional in storage and not in use: a backend that predates this feature
    /// omits the key, and a missing key must not fail the decode of the whole
    /// file list. Not private only because that would make the memberwise
    /// initialiser private too, and demo data needs it. Read `colorChanges`.
    let storedColorChanges: [ColorChange]?
    let source: String

    /// Empty for anything sliced elsewhere, or by an older backend.
    var colorChanges: [ColorChange] { storedColorChanges ?? [] }

    var id: String { "\(source):\(path)" }

    enum CodingKeys: String, CodingKey {
        case path, filename, size, modified, slicer, source
        case estimatedTime = "estimated_time"
        case filamentTotalMM = "filament_total_mm"
        case filamentWeightG = "filament_weight_g"
        case layerHeight = "layer_height"
        case firstLayerHeight = "first_layer_height"
        case objectHeight = "object_height"
        case filamentType = "filament_type"
        case filamentName = "filament_name"
        case thumbnailPath = "thumbnail_path"
        case layerCount = "layer_count"
        case storedColorChanges = "color_changes"
    }
}

struct BackendUploadResult: Decodable {
    let ok: Bool
    let id: String
    let filename: String
    let size: Int
    let path: String
}

// MARK: - Profiles

struct BackendProfile: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let kind: String
    let description: String
    let values: [String: String]

    var displayName: String { name.isEmpty ? id : name }
}

struct BackendProfiles: Decodable, Equatable {
    let printers: [BackendProfile]
    let filaments: [BackendProfile]
    let prints: [BackendProfile]

    static let empty = BackendProfiles(printers: [], filaments: [], prints: [])
}

struct BackendSlicerInfo: Decodable, Equatable {
    let engine: String
    let binary: String
    let resolvedBinary: String?
    let available: Bool
    let version: String
    let profilesDir: String

    enum CodingKeys: String, CodingKey {
        case engine, binary, available, version
        case resolvedBinary = "resolved_binary"
        case profilesDir = "profiles_dir"
    }
}

// MARK: - Slicing

struct SliceRequestPayload: Encodable, Equatable {
    var modelID: String
    /// More models on the same plate, sliced into one file.
    var extraModelIDs: [String] = []
    /// Copies of everything on the plate.
    var copies: Int = 1
    var printerProfile: String = "neptune3plus_0.4"
    var filamentProfile: String = "pla"
    var printProfile: String = "standard"
    /// draft | fast | balanced | quality | strong | miniature. Naming one fills
    /// in everything below that the caller leaves nil.
    var mode: String?

    var layerHeight: Double?
    var firstLayerHeight: Double?
    var nozzleDiameter: Double?
    var infillPercent: Int?
    var infillPattern: String?
    var perimeters: Int?
    var supports: Bool = false
    var supportStyle: String?
    /// everywhere | build_plate_only
    var supportPlacement: String?
    /// Overhang angle past which support is generated, in degrees.
    var supportThresholdAngle: Int?
    var adhesion: String?
    var brimWidth: Double?

    var nozzleTemperature: Int?
    var firstLayerNozzleTemperature: Int?
    var bedTemperature: Int?
    var firstLayerBedTemperature: Int?

    var retractionLength: Double?
    var retractionSpeed: Double?
    var retractionZHop: Double?

    var topSolidLayers: Int?
    var bottomSolidLayers: Int?
    var ironing: Bool?
    var seamPosition: String?
    var spiralVase: Bool?

    var supportZDistance: Double?
    var supportInterfaceLayers: Int?

    var fanMinPercent: Int?
    var fanMaxPercent: Int?
    var disableFanFirstLayers: Int?

    var avoidCrossingPerimeters: Bool?

    var speedProfileOverrides: [String: Double] = [:]
    var customOverrides: [String: String] = [:]

    /// Layers at which the print stops for a filament swap. Requires a
    /// COLOR_CHANGE macro on the printer; the backend refuses the slice rather
    /// than producing a file that would stop dead at the first swap.
    var colorChanges: [ColorChange] = []

    /// How each model is turned and sized, keyed by model id.
    ///
    /// Sent with the slice rather than saved against the model, so the same
    /// model can go on the plate twice at two different angles.
    var transforms: [String: ModelTransform] = [:]

    var outputName: String?
    var uploadToMoonraker: Bool = true
    var startPrintAfterUpload: Bool = false

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case extraModelIDs = "extra_model_ids"
        case copies
        case printerProfile = "printer_profile"
        case filamentProfile = "filament_profile"
        case printProfile = "print_profile"
        case mode
        case layerHeight = "layer_height"
        case firstLayerHeight = "first_layer_height"
        case nozzleDiameter = "nozzle_diameter"
        case infillPercent = "infill_percent"
        case infillPattern = "infill_pattern"
        case perimeters, supports
        case supportStyle = "support_style"
        case supportPlacement = "support_placement"
        case supportThresholdAngle = "support_threshold_angle"
        case adhesion
        case brimWidth = "brim_width"
        case nozzleTemperature = "nozzle_temperature"
        case firstLayerNozzleTemperature = "first_layer_nozzle_temperature"
        case bedTemperature = "bed_temperature"
        case firstLayerBedTemperature = "first_layer_bed_temperature"
        case retractionLength = "retraction_length"
        case retractionSpeed = "retraction_speed"
        case retractionZHop = "retraction_z_hop"
        case topSolidLayers = "top_solid_layers"
        case bottomSolidLayers = "bottom_solid_layers"
        case ironing
        case seamPosition = "seam_position"
        case spiralVase = "spiral_vase"
        case supportZDistance = "support_z_distance"
        case supportInterfaceLayers = "support_interface_layers"
        case fanMinPercent = "fan_min_percent"
        case fanMaxPercent = "fan_max_percent"
        case disableFanFirstLayers = "disable_fan_first_layers"
        case avoidCrossingPerimeters = "avoid_crossing_perimeters"
        case speedProfileOverrides = "speed_profile_overrides"
        case customOverrides = "custom_overrides"
        case colorChanges = "color_changes"
        case transforms
        case outputName = "output_name"
        case uploadToMoonraker = "upload_to_moonraker"
        case startPrintAfterUpload = "start_print_after_upload"
    }
}

struct SliceStats: Decodable, Equatable {
    let estimatedTimeSeconds: Double?
    let filamentGrams: Double?
    let filamentMeters: Double?
    let filamentCM3: Double?
    let layerCount: Int?
    let layerHeight: Double?
    let objectHeight: Double?
    let gcodeSize: Int?

    enum CodingKeys: String, CodingKey {
        case estimatedTimeSeconds = "estimated_time_seconds"
        case filamentGrams = "filament_grams"
        case filamentMeters = "filament_meters"
        case filamentCM3 = "filament_cm3"
        case layerCount = "layer_count"
        case layerHeight = "layer_height"
        case objectHeight = "object_height"
        case gcodeSize = "gcode_size"
    }

    static let empty = SliceStats(
        estimatedTimeSeconds: nil, filamentGrams: nil, filamentMeters: nil, filamentCM3: nil,
        layerCount: nil, layerHeight: nil, objectHeight: nil, gcodeSize: nil
    )
}

struct SliceJob: Decodable, Identifiable, Equatable {
    let id: String
    let status: String
    let progress: Double
    let stage: String
    let modelID: String
    let modelFilename: String
    let outputFilename: String
    let outputPath: String
    let moonrakerPath: String?
    let createdAt: Double
    let startedAt: Double?
    let finishedAt: Double?
    let error: String?
    let logs: [String]
    let stats: SliceStats
    /// Where the stops actually landed, with their real heights. Optional for
    /// the same reason as on BackendGCodeFile - read `colorChanges`.
    let storedColorChanges: [ColorChange]?
    let engine: String

    var colorChanges: [ColorChange] { storedColorChanges ?? [] }

    var isFinished: Bool { ["done", "failed", "cancelled"].contains(status) }
    var isRunning: Bool { status == "running" || status == "queued" }
    var didSucceed: Bool { status == "done" }

    enum CodingKeys: String, CodingKey {
        case id, status, progress, stage, error, logs, stats, engine
        case storedColorChanges = "color_changes"
        case modelID = "model_id"
        case modelFilename = "model_filename"
        case outputFilename = "output_filename"
        case outputPath = "output_path"
        case moonrakerPath = "moonraker_path"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }
}

// MARK: - History

struct HistoryEntry: Decodable, Identifiable, Equatable {
    let id: Int
    let filename: String
    let startTime: Double
    let finishTime: Double?
    let duration: Double?
    let result: String
    let filamentUsedMM: Double?
    let estimatedFilamentMM: Double?
    let nozzleTemp: Double?
    let bedTemp: Double?
    let speedProfile: String?
    let thumbnailPath: String?
    let note: String

    enum CodingKeys: String, CodingKey {
        case id, filename, result, note
        case startTime = "start_time"
        case finishTime = "finish_time"
        case duration
        case filamentUsedMM = "filament_used_mm"
        case estimatedFilamentMM = "estimated_filament_mm"
        case nozzleTemp = "nozzle_temp"
        case bedTemp = "bed_temp"
        case speedProfile = "speed_profile"
        case thumbnailPath = "thumbnail_path"
    }
}

struct HistoryStats: Decodable, Equatable {
    let totalPrints: Int
    let successful: Int
    let failed: Int
    let cancelled: Int
    let totalPrintSeconds: Double
    let totalFilamentMM: Double
    let longestPrintSeconds: Double

    enum CodingKeys: String, CodingKey {
        case successful, failed, cancelled
        case totalPrints = "total_prints"
        case totalPrintSeconds = "total_print_seconds"
        case totalFilamentMM = "total_filament_mm"
        case longestPrintSeconds = "longest_print_seconds"
    }

    static let empty = HistoryStats(
        totalPrints: 0, successful: 0, failed: 0, cancelled: 0,
        totalPrintSeconds: 0, totalFilamentMM: 0, longestPrintSeconds: 0
    )
}

struct HistoryResponse: Decodable, Equatable {
    let entries: [HistoryEntry]
    let stats: HistoryStats
}

// MARK: - Backend printer status (used in Demo/fallback paths)

struct BackendTemperature: Decodable, Equatable {
    var actual: Double = 0
    var target: Double = 0
    var power: Double = 0

    init(actual: Double = 0, target: Double = 0, power: Double = 0) {
        self.actual = actual
        self.target = target
        self.power = power
    }

    // Written out rather than synthesised: declaring an initialiser of our own
    // stops Swift generating the Decodable conformance, and CodingKeys comes
    // with that conformance.
    enum CodingKeys: String, CodingKey {
        case actual, target, power
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actual = try container.decodeIfPresent(Double.self, forKey: .actual) ?? 0
        target = try container.decodeIfPresent(Double.self, forKey: .target) ?? 0
        power = try container.decodeIfPresent(Double.self, forKey: .power) ?? 0
    }
}

/// The backend's remaining-time estimate, and how it got there.
///
/// Shipped with its reasoning on purpose. A single number carries no sense of
/// how much to trust it, and this one legitimately varies: in the first minutes
/// it is the slicer's simulation corrected by a factor learned from past
/// prints; by the end it is this print's measured rate. Saying which lets the
/// user calibrate their own confidence instead of assuming the worst case
/// always applies.
struct PrintEstimate: Decodable, Equatable {
    var remainingSeconds: Double?
    var totalSeconds: Double?
    /// unknown | slicer | slicer_calibrated | blended | observed
    var method: String = "unknown"
    var methodAR: String = ""
    var methodEN: String = ""
    /// 0…1. Not a probability — a statement about how much evidence exists.
    var confidence: Double = 0
    var slicerSeconds: Double?
    var speedFactor: Double = 1
    /// "filament" or "file". Filament progress is materially more accurate;
    /// "file" means this G-code arrived without a filament total in its
    /// metadata, so the estimate is working with a coarser signal.
    var progressSource: String = "file"
    var calibration: EstimateCalibration?

    var isRough: Bool { confidence < 0.6 }

    enum CodingKeys: String, CodingKey {
        case method, confidence, calibration
        case remainingSeconds = "remaining_seconds"
        case totalSeconds = "total_seconds"
        case methodAR = "method_ar"
        case methodEN = "method_en"
        case slicerSeconds = "slicer_seconds"
        case speedFactor = "speed_factor"
        case progressSource = "progress_source"
    }
}

/// How wrong this printer's slicer estimates usually are.
struct EstimateCalibration: Decodable, Equatable {
    var factor: Double = 1
    var samples: Int = 0
    var spread: Double = 0
    var learned: Bool = false
    /// Signed: +18 means prints run 18 % longer than the slicer predicts.
    var percentOff: Double = 0

    enum CodingKeys: String, CodingKey {
        case factor, samples, spread, learned
        case percentOff = "percent_off"
    }
}

/// One Klipper filament sensor as the backend sees it.
struct BackendFilamentSensor: Decodable, Equatable {
    var name: String = ""
    /// `switch` sees the filament is gone; `motion` also sees it stop moving.
    /// The distinction is not cosmetic - a switch cannot detect a jam, and
    /// presenting it as if it could promises a safety net that is not there.
    var kind: String = "switch"
    var enabled: Bool = true
    var filamentDetected: Bool = true

    var detectsJams: Bool { kind == "motion" }

    enum CodingKeys: String, CodingKey {
        case name, kind, enabled
        case filamentDetected = "filament_detected"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "switch"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        filamentDetected = try container.decodeIfPresent(Bool.self, forKey: .filamentDetected) ?? true
    }
}

struct BackendPrinterStatus: Decodable, Equatable {
    let online: Bool
    let klippyState: String
    let klippyMessage: String
    let state: String
    let stateMessage: String
    /// Whatever M117 last put on the printer's display - see PrinterSnapshot.
    let displayMessage: String
    let filename: String
    let progress: Double
    let printDuration: Double
    let totalDuration: Double
    let estimatedTimeLeft: Double?
    let filamentUsedMM: Double
    let currentLayer: Int?
    let totalLayer: Int?
    let nozzle: BackendTemperature
    let bed: BackendTemperature
    let position: [Double]
    let gcodePosition: [Double]
    let homedAxes: String
    let speed: Double
    let speedFactor: Double
    let extrudeFactor: Double
    let fanSpeed: Double
    /// Klipper filament sensors, keyed by short name. Discovered per machine -
    /// a printer with no sensor simply reports none.
    let filamentSensors: [String: BackendFilamentSensor]
    let estimate: PrintEstimate?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case online, state, filename, progress, nozzle, bed, position, speed, error
        case klippyState = "klippy_state"
        case klippyMessage = "klippy_message"
        case stateMessage = "state_message"
        case displayMessage = "display_message"
        case printDuration = "print_duration"
        case totalDuration = "total_duration"
        case estimatedTimeLeft = "estimated_time_left"
        case filamentUsedMM = "filament_used_mm"
        case currentLayer = "current_layer"
        case totalLayer = "total_layer"
        case gcodePosition = "gcode_position"
        case homedAxes = "homed_axes"
        case speedFactor = "speed_factor"
        case extrudeFactor = "extrude_factor"
        case fanSpeed = "fan_speed"
        case filamentSensors = "filament_sensors"
        case estimate
    }

    /// Decoded field by field with defaults, rather than by the synthesised
    /// initialiser.
    ///
    /// The synthesised one requires every key to be present, so a backend one
    /// version behind - missing a field the app has just learned about - fails
    /// to decode the *whole* status and blanks the dashboard. A missing
    /// `filament_sensors` should cost you the filament row, not the printer.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        klippyState = try container.decodeIfPresent(String.self, forKey: .klippyState) ?? "unknown"
        klippyMessage = try container.decodeIfPresent(String.self, forKey: .klippyMessage) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        stateMessage = try container.decodeIfPresent(String.self, forKey: .stateMessage) ?? ""
        displayMessage = try container.decodeIfPresent(String.self, forKey: .displayMessage) ?? ""
        filename = try container.decodeIfPresent(String.self, forKey: .filename) ?? ""
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        printDuration = try container.decodeIfPresent(Double.self, forKey: .printDuration) ?? 0
        totalDuration = try container.decodeIfPresent(Double.self, forKey: .totalDuration) ?? 0
        estimatedTimeLeft = try container.decodeIfPresent(Double.self, forKey: .estimatedTimeLeft)
        filamentUsedMM = try container.decodeIfPresent(Double.self, forKey: .filamentUsedMM) ?? 0
        currentLayer = try container.decodeIfPresent(Int.self, forKey: .currentLayer)
        totalLayer = try container.decodeIfPresent(Int.self, forKey: .totalLayer)
        nozzle = try container.decodeIfPresent(BackendTemperature.self, forKey: .nozzle) ?? BackendTemperature()
        bed = try container.decodeIfPresent(BackendTemperature.self, forKey: .bed) ?? BackendTemperature()
        position = try container.decodeIfPresent([Double].self, forKey: .position) ?? [0, 0, 0]
        gcodePosition = try container.decodeIfPresent([Double].self, forKey: .gcodePosition) ?? [0, 0, 0]
        homedAxes = try container.decodeIfPresent(String.self, forKey: .homedAxes) ?? ""
        speed = try container.decodeIfPresent(Double.self, forKey: .speed) ?? 0
        speedFactor = try container.decodeIfPresent(Double.self, forKey: .speedFactor) ?? 1
        extrudeFactor = try container.decodeIfPresent(Double.self, forKey: .extrudeFactor) ?? 1
        fanSpeed = try container.decodeIfPresent(Double.self, forKey: .fanSpeed) ?? 0
        filamentSensors = try container.decodeIfPresent(
            [String: BackendFilamentSensor].self, forKey: .filamentSensors
        ) ?? [:]
        estimate = try container.decodeIfPresent(PrintEstimate.self, forKey: .estimate)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    var snapshot: PrinterSnapshot {
        var value = PrinterSnapshot()
        value.isOnline = online
        value.klippy = KlippyState(raw: klippyState)
        value.klippyMessage = klippyMessage
        value.state = PrinterState(moonraker: state)
        value.stateMessage = stateMessage
        value.displayMessage = displayMessage
        value.filename = filename
        value.progress = progress
        value.printDuration = printDuration
        value.totalDuration = totalDuration
        value.filamentUsedMM = filamentUsedMM
        value.currentLayer = currentLayer
        value.totalLayer = totalLayer
        value.nozzleActual = nozzle.actual
        value.nozzleTarget = nozzle.target
        value.nozzlePower = nozzle.power
        value.bedActual = bed.actual
        value.bedTarget = bed.target
        value.bedPower = bed.power
        value.position = position
        value.gcodePosition = gcodePosition
        value.homedAxes = homedAxes
        value.speed = speed
        value.speedFactor = speedFactor
        value.extrudeFactor = extrudeFactor
        value.fanSpeed = fanSpeed
        value.filamentSensors = filamentSensors
        value.estimate = estimate
        value.errorMessage = error
        value.lastUpdate = Date()
        return value
    }
}

/// Discrete event emitted by the backend monitor (also used for notifications).
struct BackendPrinterEvent: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let timestamp: Double
    let title: String
    let message: String
    let filename: String
}

/// Whether the printer is waiting to cool before sweeping the part off.
///
/// The wait is held by the Pi, not by the phone. `blockers` is the same list
/// the backend decides on, not a parallel one computed here - a countdown that
/// disagreed with the thing actually holding the toolhead would be worse than
/// no countdown at all.
struct EjectState: Decodable, Equatable {
    let armed: Bool
    let armedAt: Double?
    /// Whether EJECT_PART is really in printer.cfg. Without it there is nothing
    /// to arm, and the card says so instead of offering a button.
    let macroInstalled: Bool
    let maxBedC: Double
    let maxNozzleC: Double
    let blockers: [String]
    /// ejected | cancelled | timeout | failed - what happened to the last arm,
    /// which the person was probably not watching.
    let lastOutcome: String
    let lastMessage: String
    let lastAt: Double?

    static let idle = EjectState(
        armed: false, armedAt: nil, macroInstalled: false,
        maxBedC: 40, maxNozzleC: 170, blockers: [],
        lastOutcome: "", lastMessage: "", lastAt: nil
    )

    enum CodingKeys: String, CodingKey {
        case armed, blockers
        case armedAt = "armed_at"
        case macroInstalled = "macro_installed"
        case maxBedC = "max_bed_c"
        case maxNozzleC = "max_nozzle_c"
        case lastOutcome = "last_outcome"
        case lastMessage = "last_message"
        case lastAt = "last_at"
    }

    init(armed: Bool, armedAt: Double?, macroInstalled: Bool, maxBedC: Double,
         maxNozzleC: Double, blockers: [String], lastOutcome: String,
         lastMessage: String, lastAt: Double?) {
        self.armed = armed
        self.armedAt = armedAt
        self.macroInstalled = macroInstalled
        self.maxBedC = maxBedC
        self.maxNozzleC = maxNozzleC
        self.blockers = blockers
        self.lastOutcome = lastOutcome
        self.lastMessage = lastMessage
        self.lastAt = lastAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        armed = try container.decodeIfPresent(Bool.self, forKey: .armed) ?? false
        armedAt = try container.decodeIfPresent(Double.self, forKey: .armedAt)
        macroInstalled = try container.decodeIfPresent(Bool.self, forKey: .macroInstalled) ?? false
        maxBedC = try container.decodeIfPresent(Double.self, forKey: .maxBedC) ?? 40
        maxNozzleC = try container.decodeIfPresent(Double.self, forKey: .maxNozzleC) ?? 170
        blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
        lastOutcome = try container.decodeIfPresent(String.self, forKey: .lastOutcome) ?? ""
        lastMessage = try container.decodeIfPresent(String.self, forKey: .lastMessage) ?? ""
        lastAt = try container.decodeIfPresent(Double.self, forKey: .lastAt)
    }
}

// MARK: - Probe diagnosis

/// How repeatable the probe is, from PROBE_ACCURACY.
struct ProbeAccuracy: Decodable, Equatable {
    let maximum: Double
    let minimum: Double
    let range: Double
    let average: Double
    let median: Double
    let deviation: Double
    /// good | loose | mechanical
    let verdict: String
    /// A samples_tolerance this probe can actually meet.
    let recommendedTolerance: Double

    enum CodingKeys: String, CodingKey {
        case maximum, minimum, range, average, median, deviation, verdict
        case recommendedTolerance = "recommended_tolerance"
    }
}

/// What the probe is doing and why.
///
/// "The probe doesn't work" is four faults with four fixes, and Klipper reports
/// them all as a failed home. Two readings - untouched, then pressed - are what
/// tell them apart.
struct ProbeDiagnosis: Decodable, Equatable {
    /// working | stuck | dead | inverted | unreadable | unrepeatable
    let fault: String
    let ok: Bool
    let title: String
    let detail: String
    let fixes: [String]
    let atRest: Bool?
    let pressed: Bool?
    let accuracy: ProbeAccuracy?
    /// A printer.cfg change to make, as section -> option -> value. Text only:
    /// this app never writes printer.cfg on its own.
    let suggestedConfig: [String: [String: String]]

    /// Whether the second half of the wiring test has been done.
    var isComplete: Bool { pressed != nil || fault != "working" }

    enum CodingKeys: String, CodingKey {
        case fault, ok, accuracy
        case title = "title_ar"
        case detail = "detail_ar"
        case fixes = "fixes_ar"
        case atRest = "at_rest"
        case pressed
        case suggestedConfig = "suggested_config"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fault = try container.decodeIfPresent(String.self, forKey: .fault) ?? "unreadable"
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        fixes = try container.decodeIfPresent([String].self, forKey: .fixes) ?? []
        atRest = try container.decodeIfPresent(Bool.self, forKey: .atRest)
        pressed = try container.decodeIfPresent(Bool.self, forKey: .pressed)
        accuracy = try container.decodeIfPresent(ProbeAccuracy.self, forKey: .accuracy)
        suggestedConfig = try container.decodeIfPresent(
            [String: [String: String]].self, forKey: .suggestedConfig
        ) ?? [:]
    }
}

// MARK: - Calibration status

/// One thing on this printer that either is or is not calibrated.
///
/// The app has had wizards for all three of these for a while. What it did not
/// have was an answer to the question people actually ask, which is not "how do
/// I calibrate" but "is my printer calibrated" - and finding out meant opening
/// each wizard and running it.
struct CalibrationItem: Decodable, Equatable, Identifiable {
    /// Matches the workflow kind, so tapping a row opens the right wizard with
    /// no second mapping table to drift out of step.
    let id: String
    /// done | missing | unknown | not_applicable
    ///
    /// "unknown" is its own state. A bed whose screws have never been measured
    /// is not level and is not un-level, and claiming either would be inventing
    /// something the printer never said.
    let state: String
    let ok: Bool
    let title: String
    let detail: String
    /// Trouble beyond the headline - most importantly a saved mesh that nothing
    /// loads, which reads as calibrated and never reaches the nozzle.
    let warnings: [String]
    let value: Double?
    let measuredAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, state, ok, value
        case title = "title_ar"
        case detail = "detail_ar"
        case warnings = "warnings_ar"
        case measuredAt = "measured_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "unknown"
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        value = try container.decodeIfPresent(Double.self, forKey: .value)
        measuredAt = try container.decodeIfPresent(Double.self, forKey: .measuredAt)
    }

    init(id: String, state: String, ok: Bool, title: String, detail: String,
         warnings: [String] = [], value: Double? = nil, measuredAt: Double? = nil) {
        self.id = id
        self.state = state
        self.ok = ok
        self.title = title
        self.detail = detail
        self.warnings = warnings
        self.value = value
        self.measuredAt = measuredAt
    }
}

struct CalibrationStatus: Decodable, Equatable {
    let items: [CalibrationItem]
    let allDone: Bool
    /// What to do first. One answer rather than a list: somebody unsure whether
    /// their printer is calibrated is not helped by three choices.
    let nextID: String?
    let nextTitle: String

    static let empty = CalibrationStatus(items: [], allDone: true, nextID: nil, nextTitle: "")

    enum CodingKeys: String, CodingKey {
        case items
        case allDone = "all_done"
        case nextID = "next_id"
        case nextTitle = "next_title_ar"
    }

    init(items: [CalibrationItem], allDone: Bool, nextID: String?, nextTitle: String) {
        self.items = items
        self.allDone = allDone
        self.nextID = nextID
        self.nextTitle = nextTitle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([CalibrationItem].self, forKey: .items) ?? []
        allDone = try container.decodeIfPresent(Bool.self, forKey: .allDone) ?? true
        nextID = try container.decodeIfPresent(String.self, forKey: .nextID)
        nextTitle = try container.decodeIfPresent(String.self, forKey: .nextTitle) ?? ""
    }
}

// MARK: - Generated macros

/// One macro the backend built from the live printer.cfg, with its reasoning.
///
/// `rationale` is not decoration. A macro that moves the toolhead is only worth
/// installing if you can see why every coordinate in it is what it is, and
/// `blockers` says when the backend refused to generate one at all rather than
/// emitting motion it could not justify.
struct MacroSuggestion: Decodable, Equatable, Identifiable {
    let name: String
    let gcode: String
    let rationale: [String]
    let blockers: [String]
    /// A macro of this name already in the user's config.
    let existing: String?
    let ok: Bool
    let conflicts: Bool

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, gcode, rationale, blockers, existing, ok, conflicts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        gcode = try container.decodeIfPresent(String.self, forKey: .gcode) ?? ""
        rationale = try container.decodeIfPresent([String].self, forKey: .rationale) ?? []
        blockers = try container.decodeIfPresent([String].self, forKey: .blockers) ?? []
        existing = try container.decodeIfPresent(String.self, forKey: .existing)
        ok = try container.decodeIfPresent(Bool.self, forKey: .ok) ?? blockers.isEmpty
        conflicts = try container.decodeIfPresent(Bool.self, forKey: .conflicts) ?? (existing != nil)
    }
}

struct MacroSlicerWiring: Decodable, Equatable {
    let startGCode: String
    let endGCode: String
    let note: String

    enum CodingKeys: String, CodingKey {
        case startGCode = "start_gcode"
        case endGCode = "end_gcode"
        case note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startGCode = try container.decodeIfPresent(String.self, forKey: .startGCode) ?? ""
        endGCode = try container.decodeIfPresent(String.self, forKey: .endGCode) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct MacroSuggestions: Decodable, Equatable {
    let macros: [MacroSuggestion]
    let slicer: MacroSlicerWiring?
    let alreadyConfigured: Bool

    enum CodingKeys: String, CodingKey {
        case macros, slicer
        case alreadyConfigured = "already_configured"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        macros = try container.decodeIfPresent([MacroSuggestion].self, forKey: .macros) ?? []
        slicer = try container.decodeIfPresent(MacroSlicerWiring.self, forKey: .slicer)
        alreadyConfigured = try container.decodeIfPresent(
            Bool.self, forKey: .alreadyConfigured
        ) ?? false
    }
}


/// What the camera can be told to do, as reported by the Pi.
///
/// `available` is false on a camera with no motors and on one that was never
/// configured, and the difference does not matter to the screen: either way
/// there is nothing to point, and a control that cannot work should not be
/// drawn at all.
struct PTZStatus: Decodable, Equatable {
    var available: Bool = false
    var vendor: String = ""
    var host: String = ""
    var directions: [String] = []

    enum CodingKeys: String, CodingKey { case available, vendor, host, directions }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? false
        vendor = try container.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        directions = try container.decodeIfPresent([String].self, forKey: .directions) ?? []
    }

    /// Optical zoom exists only on a camera with the motor for it. Most indoor
    /// pan-and-tilt cameras have none, and the Pi reports what this one
    /// actually answered to rather than what the box claimed.
    var hasOpticalZoom: Bool { directions.contains("zoom_in") }
}
