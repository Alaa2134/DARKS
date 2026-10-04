import Foundation

// MARK: - Envelope

struct MoonrakerEnvelope<T: Decodable>: Decodable {
    let result: T
}

struct MoonrakerErrorPayload: Decodable {
    struct Body: Decodable {
        let code: Int?
        let message: String?
    }
    let error: Body
}

// MARK: - Server / printer info

struct MoonrakerServerInfo: Decodable, Equatable {
    let klippyConnected: Bool
    let klippyState: String
    let moonrakerVersion: String?
    let components: [String]?

    enum CodingKeys: String, CodingKey {
        case klippyConnected = "klippy_connected"
        case klippyState = "klippy_state"
        case moonrakerVersion = "moonraker_version"
        case components
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        klippyConnected = try container.decodeIfPresent(Bool.self, forKey: .klippyConnected) ?? false
        klippyState = try container.decodeIfPresent(String.self, forKey: .klippyState) ?? "unknown"
        moonrakerVersion = try container.decodeIfPresent(String.self, forKey: .moonrakerVersion)
        components = try container.decodeIfPresent([String].self, forKey: .components)
    }
}

struct MoonrakerPrinterInfo: Decodable, Equatable {
    let state: String?
    let stateMessage: String?
    let hostname: String?
    let softwareVersion: String?

    enum CodingKeys: String, CodingKey {
        case state
        case stateMessage = "state_message"
        case hostname
        case softwareVersion = "software_version"
    }
}

// MARK: - Klipper objects

struct PrintStatsInfo: Decodable, Equatable {
    let currentLayer: Int?
    let totalLayer: Int?

    enum CodingKeys: String, CodingKey {
        case currentLayer = "current_layer"
        case totalLayer = "total_layer"
    }
}

struct PrintStats: Decodable, Equatable {
    var filename: String?
    var totalDuration: Double?
    var printDuration: Double?
    var filamentUsed: Double?
    var state: String?
    var message: String?
    var info: PrintStatsInfo?

    enum CodingKeys: String, CodingKey {
        case filename
        case totalDuration = "total_duration"
        case printDuration = "print_duration"
        case filamentUsed = "filament_used"
        case state, message, info
    }
}

struct DisplayStatus: Decodable, Equatable {
    var progress: Double?
    var message: String?
}

struct VirtualSDCard: Decodable, Equatable {
    var progress: Double?
    var isActive: Bool?
    var filePosition: Double?

    enum CodingKeys: String, CodingKey {
        case progress
        case isActive = "is_active"
        case filePosition = "file_position"
    }
}

struct Toolhead: Decodable, Equatable {
    var position: [Double]?
    var homedAxes: String?
    var maxVelocity: Double?
    var maxAccel: Double?
    var squareCornerVelocity: Double?
    var printTime: Double?

    enum CodingKeys: String, CodingKey {
        case position
        case homedAxes = "homed_axes"
        case maxVelocity = "max_velocity"
        case maxAccel = "max_accel"
        case squareCornerVelocity = "square_corner_velocity"
        case printTime = "print_time"
    }
}

struct HeaterStatus: Decodable, Equatable {
    var temperature: Double?
    var target: Double?
    var power: Double?
}

struct FanStatus: Decodable, Equatable {
    var speed: Double?
    var rpm: Double?
}

struct GCodeMove: Decodable, Equatable {
    var speed: Double?
    var speedFactor: Double?
    var extrudeFactor: Double?
    var gcodePosition: [Double]?
    var absoluteCoordinates: Bool?
    var homingOrigin: [Double]?

    enum CodingKeys: String, CodingKey {
        case speed
        case speedFactor = "speed_factor"
        case extrudeFactor = "extrude_factor"
        case gcodePosition = "gcode_position"
        case absoluteCoordinates = "absolute_coordinates"
        case homingOrigin = "homing_origin"
    }
}

struct Webhooks: Decodable, Equatable {
    var state: String?
    var stateMessage: String?

    enum CodingKeys: String, CodingKey {
        case state
        case stateMessage = "state_message"
    }
}

struct IdleTimeout: Decodable, Equatable {
    var state: String?
    var printingTime: Double?

    enum CodingKeys: String, CodingKey {
        case state
        case printingTime = "printing_time"
    }
}

/// The subset of `printer.objects.query` the dashboard uses.
struct PrinterObjects: Decodable, Equatable {
    var printStats: PrintStats?
    var displayStatus: DisplayStatus?
    var virtualSDCard: VirtualSDCard?
    var toolhead: Toolhead?
    var extruder: HeaterStatus?
    var heaterBed: HeaterStatus?
    var fan: FanStatus?
    var gcodeMove: GCodeMove?
    var webhooks: Webhooks?
    var idleTimeout: IdleTimeout?

    enum CodingKeys: String, CodingKey {
        case printStats = "print_stats"
        case displayStatus = "display_status"
        case virtualSDCard = "virtual_sdcard"
        case toolhead
        case extruder
        case heaterBed = "heater_bed"
        case fan
        case gcodeMove = "gcode_move"
        case webhooks
        case idleTimeout = "idle_timeout"
    }

    static let queryObjects = [
        "print_stats", "display_status", "virtual_sdcard", "toolhead",
        "extruder", "heater_bed", "fan", "gcode_move", "webhooks", "idle_timeout"
    ]

    /// Merge a partial update (as delivered by `notify_status_update`) into self.
    mutating func merge(_ other: PrinterObjects) {
        if let value = other.printStats { printStats = merge(printStats, value) }
        if let value = other.displayStatus { displayStatus = merge(displayStatus, value) }
        if let value = other.virtualSDCard { virtualSDCard = merge(virtualSDCard, value) }
        if let value = other.toolhead { toolhead = merge(toolhead, value) }
        if let value = other.extruder { extruder = merge(extruder, value) }
        if let value = other.heaterBed { heaterBed = merge(heaterBed, value) }
        if let value = other.fan { fan = merge(fan, value) }
        if let value = other.gcodeMove { gcodeMove = merge(gcodeMove, value) }
        if let value = other.webhooks { webhooks = merge(webhooks, value) }
        if let value = other.idleTimeout { idleTimeout = merge(idleTimeout, value) }
    }

    private func merge(_ old: PrintStats?, _ new: PrintStats) -> PrintStats {
        guard var merged = old else { return new }
        if let value = new.filename { merged.filename = value }
        if let value = new.totalDuration { merged.totalDuration = value }
        if let value = new.printDuration { merged.printDuration = value }
        if let value = new.filamentUsed { merged.filamentUsed = value }
        if let value = new.state { merged.state = value }
        if let value = new.message { merged.message = value }
        if let value = new.info { merged.info = value }
        return merged
    }

    private func merge(_ old: DisplayStatus?, _ new: DisplayStatus) -> DisplayStatus {
        guard var merged = old else { return new }
        if let value = new.progress { merged.progress = value }
        if let value = new.message { merged.message = value }
        return merged
    }

    private func merge(_ old: VirtualSDCard?, _ new: VirtualSDCard) -> VirtualSDCard {
        guard var merged = old else { return new }
        if let value = new.progress { merged.progress = value }
        if let value = new.isActive { merged.isActive = value }
        if let value = new.filePosition { merged.filePosition = value }
        return merged
    }

    private func merge(_ old: Toolhead?, _ new: Toolhead) -> Toolhead {
        guard var merged = old else { return new }
        if let value = new.position { merged.position = value }
        if let value = new.homedAxes { merged.homedAxes = value }
        if let value = new.maxVelocity { merged.maxVelocity = value }
        if let value = new.maxAccel { merged.maxAccel = value }
        if let value = new.squareCornerVelocity { merged.squareCornerVelocity = value }
        if let value = new.printTime { merged.printTime = value }
        return merged
    }

    private func merge(_ old: HeaterStatus?, _ new: HeaterStatus) -> HeaterStatus {
        guard var merged = old else { return new }
        if let value = new.temperature { merged.temperature = value }
        if let value = new.target { merged.target = value }
        if let value = new.power { merged.power = value }
        return merged
    }

    private func merge(_ old: FanStatus?, _ new: FanStatus) -> FanStatus {
        guard var merged = old else { return new }
        if let value = new.speed { merged.speed = value }
        if let value = new.rpm { merged.rpm = value }
        return merged
    }

    private func merge(_ old: GCodeMove?, _ new: GCodeMove) -> GCodeMove {
        guard var merged = old else { return new }
        if let value = new.speed { merged.speed = value }
        if let value = new.speedFactor { merged.speedFactor = value }
        if let value = new.extrudeFactor { merged.extrudeFactor = value }
        if let value = new.gcodePosition { merged.gcodePosition = value }
        if let value = new.absoluteCoordinates { merged.absoluteCoordinates = value }
        if let value = new.homingOrigin { merged.homingOrigin = value }
        return merged
    }

    private func merge(_ old: Webhooks?, _ new: Webhooks) -> Webhooks {
        guard var merged = old else { return new }
        if let value = new.state { merged.state = value }
        if let value = new.stateMessage { merged.stateMessage = value }
        return merged
    }

    private func merge(_ old: IdleTimeout?, _ new: IdleTimeout) -> IdleTimeout {
        guard var merged = old else { return new }
        if let value = new.state { merged.state = value }
        if let value = new.printingTime { merged.printingTime = value }
        return merged
    }
}

struct PrinterObjectsQueryResult: Decodable {
    let status: PrinterObjects
    let eventtime: Double?
}

// MARK: - Files

struct MoonrakerThumbnail: Decodable, Equatable, Hashable {
    let width: Int
    let height: Int
    let size: Int?
    let relativePath: String

    enum CodingKeys: String, CodingKey {
        case width, height, size
        case relativePath = "relative_path"
    }
}

struct MoonrakerFile: Decodable, Equatable, Identifiable, Hashable {
    let path: String
    let modified: Double?
    let size: Int?
    let estimatedTime: Double?
    let filamentTotal: Double?
    let filamentWeightTotal: Double?
    let layerHeight: Double?
    let firstLayerHeight: Double?
    let objectHeight: Double?
    let filamentType: String?
    let filamentName: String?
    let slicer: String?
    let slicerVersion: String?
    let thumbnails: [MoonrakerThumbnail]?
    let printStartTime: Double?

    var id: String { path }

    var filename: String { (path as NSString).lastPathComponent }

    /// Path of the biggest embedded thumbnail, relative to the gcodes root.
    var thumbnailPath: String? {
        guard let best = thumbnails?.max(by: { ($0.size ?? 0) < ($1.size ?? 0) }) else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        return directory.isEmpty ? best.relativePath : "\(directory)/\(best.relativePath)"
    }

    enum CodingKeys: String, CodingKey {
        case path, modified, size, slicer, thumbnails
        case filename
        case estimatedTime = "estimated_time"
        case filamentTotal = "filament_total"
        case filamentWeightTotal = "filament_weight_total"
        case layerHeight = "layer_height"
        case firstLayerHeight = "first_layer_height"
        case objectHeight = "object_height"
        case filamentType = "filament_type"
        case filamentName = "filament_name"
        case slicerVersion = "slicer_version"
        case printStartTime = "print_start_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // /server/files/list uses "path", /server/files/metadata uses "filename".
        let rawPath = try container.decodeIfPresent(String.self, forKey: .path)
            ?? container.decodeIfPresent(String.self, forKey: .filename)
            ?? ""
        path = rawPath
        modified = try container.decodeIfPresent(Double.self, forKey: .modified)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        estimatedTime = try container.decodeIfPresent(Double.self, forKey: .estimatedTime)
        filamentTotal = try container.decodeIfPresent(Double.self, forKey: .filamentTotal)
        filamentWeightTotal = try container.decodeIfPresent(Double.self, forKey: .filamentWeightTotal)
        layerHeight = try container.decodeIfPresent(Double.self, forKey: .layerHeight)
        firstLayerHeight = try container.decodeIfPresent(Double.self, forKey: .firstLayerHeight)
        objectHeight = try container.decodeIfPresent(Double.self, forKey: .objectHeight)
        filamentType = try container.decodeIfPresent(String.self, forKey: .filamentType)
        filamentName = try container.decodeIfPresent(String.self, forKey: .filamentName)
        slicer = try container.decodeIfPresent(String.self, forKey: .slicer)
        slicerVersion = try container.decodeIfPresent(String.self, forKey: .slicerVersion)
        thumbnails = try container.decodeIfPresent([MoonrakerThumbnail].self, forKey: .thumbnails)
        printStartTime = try container.decodeIfPresent(Double.self, forKey: .printStartTime)
    }
}

struct MoonrakerUploadResult: Decodable {
    struct Item: Decodable {
        let path: String?
        let root: String?
    }
    let item: Item?
    let action: String?
}

// MARK: - Power devices

struct MoonrakerPowerDevice: Decodable, Equatable, Identifiable {
    let device: String
    let status: String?
    let lockedWhilePrinting: Bool?
    let type: String?

    var id: String { device }

    enum CodingKeys: String, CodingKey {
        case device, status, type
        case lockedWhilePrinting = "locked_while_printing"
    }
}

struct MoonrakerPowerDevices: Decodable {
    let devices: [MoonrakerPowerDevice]
}
