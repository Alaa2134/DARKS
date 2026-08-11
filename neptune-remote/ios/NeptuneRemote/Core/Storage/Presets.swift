import Foundation

/// Editable nozzle/bed temperature preset shown on the Temperature screen.
struct TemperaturePreset: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var nozzle: Double
    var bed: Double
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, nozzle: Double, bed: Double, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.nozzle = nozzle
        self.bed = bed
        self.isBuiltIn = isBuiltIn
    }

    /// Defaults requested for the Neptune 3 Plus. All of them are editable.
    static let defaults: [TemperaturePreset] = [
        TemperaturePreset(name: "PLA", nozzle: 205, bed: 60, isBuiltIn: true),
        TemperaturePreset(name: "PLA+", nozzle: 215, bed: 60, isBuiltIn: true),
        TemperaturePreset(name: "PETG", nozzle: 235, bed: 75, isBuiltIn: true),
        TemperaturePreset(name: "TPU", nozzle: 220, bed: 50, isBuiltIn: true),
        TemperaturePreset(name: "ASA", nozzle: 250, bed: 100, isBuiltIn: true),
        TemperaturePreset(name: "ABS", nozzle: 245, bed: 100, isBuiltIn: true),
        TemperaturePreset(name: "Custom", nozzle: 210, bed: 60, isBuiltIn: true)
    ]
}

/// A favourite or predefined terminal command.
struct GCodeShortcut: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var command: String
    var label: String
    var isFavourite: Bool

    init(id: UUID = UUID(), command: String, label: String, isFavourite: Bool = false) {
        self.id = id
        self.command = command
        self.label = label
        self.isFavourite = isFavourite
    }

    /// The Klipper object a command needs before it exists at all.
    ///
    /// Klipper only defines BED_MESH_CALIBRATE when there is a `[bed_mesh]`
    /// section, SCREWS_TILT_CALCULATE when there is `[screws_tilt_adjust]`, and
    /// QUAD_GANTRY_LEVEL when there is `[quad_gantry_level]` - which a
    /// bed-slinger never has. Offering a one-tap button that answers "Unknown
    /// command" is the same class of mistake as a print that dies on a macro
    /// nobody installed, just smaller.
    var requiredObject: String? {
        switch command.split(separator: " ").first.map(String.init)?.uppercased() {
        case "BED_MESH_CALIBRATE": return "bed_mesh"
        case "SCREWS_TILT_CALCULATE": return "screws_tilt_adjust"
        case "QUAD_GANTRY_LEVEL": return "quad_gantry_level"
        case "Z_TILT_ADJUST": return "z_tilt"
        default: return nil
        }
    }

    /// Commands that are safe to expose as one-tap buttons on a Klipper machine.
    ///
    /// Not all of them apply to every machine - see `requiredObject`, and the
    /// filtering in the terminal that uses it.
    static let predefined: [GCodeShortcut] = [
        GCodeShortcut(command: "G28", label: "Home all"),
        GCodeShortcut(command: "G28 X", label: "Home X"),
        GCodeShortcut(command: "G28 Y", label: "Home Y"),
        GCodeShortcut(command: "G28 Z", label: "Home Z"),
        GCodeShortcut(command: "M84", label: "Disable steppers"),
        GCodeShortcut(command: "M106 S255", label: "Fan 100%"),
        GCodeShortcut(command: "M107", label: "Fan off"),
        GCodeShortcut(command: "TURN_OFF_HEATERS", label: "Turn off heaters"),
        GCodeShortcut(command: "BED_MESH_CALIBRATE", label: "Bed mesh calibrate"),
        GCodeShortcut(command: "SAVE_CONFIG", label: "Save config (restarts Klipper)"),
        GCodeShortcut(command: "QUAD_GANTRY_LEVEL", label: "Quad gantry level"),
        GCodeShortcut(command: "Z_TILT_ADJUST", label: "Z tilt adjust"),
        GCodeShortcut(command: "SCREWS_TILT_CALCULATE", label: "Screws tilt calculate"),
        GCodeShortcut(command: "M115", label: "Firmware info"),
        GCodeShortcut(command: "STATUS", label: "Klipper status")
    ]
}

/// Slicing parameters that the user can save and reuse.
struct SlicePreset: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var printerProfile: String
    var filamentProfile: String
    var printProfile: String
    var layerHeight: Double
    var infill: Int
    var supports: Bool
    var adhesion: String

    init(
        id: UUID = UUID(),
        name: String,
        printerProfile: String = "neptune3plus_0.4",
        filamentProfile: String = "pla",
        printProfile: String = "standard",
        layerHeight: Double = 0.2,
        infill: Int = 20,
        supports: Bool = false,
        adhesion: String = "skirt"
    ) {
        self.id = id
        self.name = name
        self.printerProfile = printerProfile
        self.filamentProfile = filamentProfile
        self.printProfile = printProfile
        self.layerHeight = layerHeight
        self.infill = infill
        self.supports = supports
        self.adhesion = adhesion
    }

    static let defaults: [SlicePreset] = [
        SlicePreset(name: "PLA · Standard"),
        SlicePreset(name: "PETG · Quality", filamentProfile: "petg", printProfile: "quality", layerHeight: 0.16),
        SlicePreset(name: "TPU · Slow", filamentProfile: "tpu", printProfile: "quality", layerHeight: 0.2, infill: 15),
        SlicePreset(name: "Draft · Fast", printProfile: "fast", layerHeight: 0.28, infill: 12)
    ]
}
