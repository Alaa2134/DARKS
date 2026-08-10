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
    let source: String

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

    var outputName: String?
    var uploadToMoonraker: Bool = true
    var startPrintAfterUpload: Bool = false

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
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
    let engine: String

    var isFinished: Bool { ["done", "failed", "cancelled"].contains(status) }
    var isRunning: Bool { status == "running" || status == "queued" }
    var didSucceed: Bool { status == "done" }

    enum CodingKeys: String, CodingKey {
        case id, status, progress, stage, error, logs, stats, engine
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
