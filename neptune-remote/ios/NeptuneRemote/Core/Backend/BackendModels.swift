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

    var layerHeight: Double?
    var firstLayerHeight: Double?
    var nozzleDiameter: Double?
    var infillPercent: Int?
    var infillPattern: String?
    var perimeters: Int?
    var supports: Bool = false
    var supportStyle: String?
    var adhesion: String?
    var brimWidth: Double?

    var nozzleTemperature: Int?
    var firstLayerNozzleTemperature: Int?
    var bedTemperature: Int?
    var firstLayerBedTemperature: Int?

    var retractionLength: Double?
    var retractionSpeed: Double?

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
        case layerHeight = "layer_height"
        case firstLayerHeight = "first_layer_height"
        case nozzleDiameter = "nozzle_diameter"
        case infillPercent = "infill_percent"
        case infillPattern = "infill_pattern"
        case perimeters, supports
        case supportStyle = "support_style"
        case adhesion
        case brimWidth = "brim_width"
        case nozzleTemperature = "nozzle_temperature"
        case firstLayerNozzleTemperature = "first_layer_nozzle_temperature"
        case bedTemperature = "bed_temperature"
        case firstLayerBedTemperature = "first_layer_bed_temperature"
        case retractionLength = "retraction_length"
        case retractionSpeed = "retraction_speed"
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
    let actual: Double
    let target: Double
    let power: Double
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
