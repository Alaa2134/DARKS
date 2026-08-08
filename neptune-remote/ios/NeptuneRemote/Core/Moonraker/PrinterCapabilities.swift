import Foundation

/// What this particular printer can actually do, discovered from Klipper.
///
/// Everything here comes from two live sources and nothing else:
///
/// * `configfile.settings` - the parsed printer.cfg, so section options such as
///   `stepper_x.position_max` or `extruder.max_temp` are read rather than
///   assumed;
/// * `printer.objects.list` - the objects Klipper actually instantiated, which
///   is how optional modules (bed_mesh, probe, input_shaper, exclude_object,
///   extra fans, extra sensors) are detected.
///
/// The rule this type exists to enforce: **printer.cfg is the source of truth**.
/// No screen may hardcode a build volume, a heater ceiling, a fan name or a
/// macro list. If a value is not in here, it was not configured, and the UI for
/// it should not appear.
struct PrinterCapabilities: Equatable {

    // MARK: - Motion

    struct AxisLimit: Equatable {
        let axis: String        // "x", "y", "z"
        let min: Double
        let max: Double

        var span: Double { Swift.max(0, max - min) }

        func clamp(_ value: Double) -> Double {
            Swift.min(Swift.max(value, min), max)
        }

        func contains(_ value: Double) -> Bool { value >= min && value <= max }
    }

    struct SafeZHome: Equatable {
        let x: Double?
        let y: Double?
        let zHop: Double?
        let speed: Double?
    }

    // MARK: - Heaters

    struct HeaterSpec: Equatable, Identifiable {
        let object: String          // "extruder", "extruder1", "heater_bed"
        let displayName: String
        let minTemp: Double
        let maxTemp: Double
        let sensorType: String?
        /// Extruder-only, absent on the bed.
        let minExtrudeTemp: Double?
        let maxExtrudeOnlyDistance: Double?
        let maxExtrudeCrossSection: Double?
        let nozzleDiameter: Double?
        let filamentDiameter: Double?

        var id: String { object }
        var isExtruder: Bool { object.hasPrefix("extruder") }

        /// The highest target the UI may offer. Klipper refuses anything above
        /// `max_temp` outright, and going near it is how heaters get damaged, so
        /// the app never presents more than the configured ceiling.
        func clampTarget(_ value: Double) -> Double {
            Swift.min(Swift.max(value, 0), maxTemp)
        }
    }

    // MARK: - Fans

    struct FanSpec: Equatable, Identifiable {
        /// Klipper object name exactly as it must be addressed, e.g. `fan`,
        /// `heater_fan hotend_fan`, `fan_generic exhaust`.
        let object: String
        /// Klipper section kind: fan / heater_fan / controller_fan / fan_generic /
        /// temperature_fan.
        let kind: String
        /// The part after the kind, when there is one.
        let name: String?

        var id: String { object }

        /// Only `fan` (the part-cooling fan) responds to M106/M107, and only
        /// `fan_generic` responds to SET_FAN_SPEED. Everything else is driven by
        /// Klipper itself and is read-only from here - commanding it would mean
        /// guessing at a pin, which this app never does.
        var isControllable: Bool { kind == "fan" || kind == "fan_generic" }

        var displayName: String {
            if let name, !name.isEmpty { return name.replacingOccurrences(of: "_", with: " ") }
            switch kind {
            case "fan": return L.t("fan.part_cooling")
            default: return kind.replacingOccurrences(of: "_", with: " ")
            }
        }

        /// The command that sets this fan's speed, or nil when it is read-only.
        func speedCommand(percent: Double) -> String? {
            let clamped = Swift.min(Swift.max(percent, 0), 100)
            switch kind {
            case "fan":
                return clamped <= 0 ? "M107" : String(format: "M106 S%.0f", clamped / 100 * 255)
            case "fan_generic":
                guard let name else { return nil }
                return String(format: "SET_FAN_SPEED FAN=%@ SPEED=%.2f", name, clamped / 100)
            default:
                return nil
            }
        }
    }

    // MARK: - Sensors

    struct SensorSpec: Equatable, Identifiable {
        let object: String      // "temperature_sensor mcu_temp", "extruder"
        let displayName: String
        let kind: String        // "temperature_sensor", "extruder", "heater_bed", "temperature_fan"
        var id: String { object }
    }

    struct FilamentSensorSpec: Equatable, Identifiable {
        let object: String      // "filament_switch_sensor runout"
        let name: String
        /// switch or motion - motion sensors also detect a jam, not just runout.
        let kind: String
        var id: String { object }
    }

    // MARK: - Probing and mesh

    struct ProbeSpec: Equatable {
        /// The configured probe section: probe / bltouch / smart_effector /
        /// dockable_probe / eddy_current, whichever Klipper actually created.
        let kind: String
        let zOffset: Double?
        let xOffset: Double?
        let yOffset: Double?
        let speed: Double?
        let samples: Int?

        /// PROBE_CALIBRATE only exists when a probe is configured. Without one
        /// the printer uses Z_ENDSTOP_CALIBRATE instead.
        var supportsProbeCalibrate: Bool { true }
    }

    struct BedMeshSpec: Equatable {
        let meshMin: [Double]?
        let meshMax: [Double]?
        let probeCount: [Double]?
        let algorithm: String?
        let speed: Double?
        let horizontalMoveZ: Double?
        let fadeStart: Double?
        let fadeEnd: Double?
        let profiles: [String]
    }

    struct InputShaperSpec: Equatable {
        let shaperTypeX: String?
        let shaperTypeY: String?
        let shaperFreqX: Double?
        let shaperFreqY: Double?
    }

    // MARK: - Macros

    struct MacroSpec: Equatable, Identifiable, Comparable {
        let name: String            // as it must be typed, e.g. "LOAD_FILAMENT"
        let description: String?
        let hasParameters: Bool

        var id: String { name }

        static func < (lhs: MacroSpec, rhs: MacroSpec) -> Bool {
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        /// Macros that move the machine, heat it, or rewrite configuration get a
        /// confirmation step. Matching is on the verb rather than an allowlist,
        /// because the whole point is that these names are the user's own.
        var needsConfirmation: Bool {
            let upper = name.uppercased()
            let dangerous = [
                "CALIBRATE", "SAVE_CONFIG", "RESTART", "SHUTDOWN", "CANCEL",
                "HOME", "PROBE", "MESH", "LEVEL", "TILT", "PID", "TEST",
                "UNLOAD", "LOAD", "PURGE", "PRIME", "CLEAN", "PARK", "MOVE",
                "OFF", "RESET", "ERASE", "DELETE", "FLASH", "FIRMWARE"
            ]
            return dangerous.contains { upper.contains($0) }
        }
    }

    // MARK: - Stored state

    /// Every object name Klipper reported, verbatim.
    var objects: [String] = []
    /// The raw parsed printer.cfg, kept so the diagnostics page can show what
    /// was read and future features need no new plumbing.
    var settings: [String: ConfigValue] = [:]

    var axisLimits: [String: AxisLimit] = [:]
    var homedAxes: String = ""
    var safeZHome: SafeZHome?

    var heaters: [HeaterSpec] = []
    var fans: [FanSpec] = []
    var temperatureSensors: [SensorSpec] = []
    var filamentSensors: [FilamentSensorSpec] = []

    var bedMesh: BedMeshSpec?
    var probe: ProbeSpec?
    var inputShaper: InputShaperSpec?
    var accelerometers: [String] = []
    var macros: [MacroSpec] = []

    var maxVelocity: Double?
    var maxAccel: Double?
    var maxZVelocity: Double?
    var maxZAccel: Double?
    var squareCornerVelocity: Double?

    var kinematics: String?
    var klipperVersion: String = ""
    /// Identifies the loaded configuration, so a printer.cfg edit is noticed
    /// without re-reading the whole thing on every poll.
    var configSignature: String = ""
    var discoveredAt: Date?

    /// Nothing has been discovered yet - the UI should not claim a feature is
    /// missing while this is true, only that it is unknown.
    var isEmpty: Bool { objects.isEmpty && settings.isEmpty }

    // MARK: - Derived answers the UI asks

    var xLimit: AxisLimit? { axisLimits["x"] }
    var yLimit: AxisLimit? { axisLimits["y"] }
    var zLimit: AxisLimit? { axisLimits["z"] }

    /// The usable build volume, from the configured axis travel. Replaces the
    /// build volume this app used to hardcode.
    var buildVolume: SIMD3<Float>? {
        guard let x = xLimit, let y = yLimit, let z = zLimit else { return nil }
        return SIMD3(Float(x.span), Float(y.span), Float(z.span))
    }

    var hasHeatedBed: Bool { heaters.contains { $0.object == "heater_bed" } }
    var bedHeater: HeaterSpec? { heaters.first { $0.object == "heater_bed" } }
    var extruders: [HeaterSpec] { heaters.filter(\.isExtruder) }
    var primaryExtruder: HeaterSpec? { extruders.first { $0.object == "extruder" } ?? extruders.first }

    var controllableFans: [FanSpec] { fans.filter(\.isControllable) }

    func has(_ object: String) -> Bool {
        objects.contains { $0 == object || $0.hasPrefix("\(object) ") }
    }

    var hasBedMesh: Bool { bedMesh != nil || has("bed_mesh") }
    var hasProbe: Bool { probe != nil }
    var hasInputShaper: Bool { inputShaper != nil || has("input_shaper") }
    var hasResonanceTester: Bool { has("resonance_tester") && !accelerometers.isEmpty }
    var hasVirtualSDCard: Bool { has("virtual_sdcard") }
    var hasPauseResume: Bool { has("pause_resume") }
    var hasExcludeObject: Bool { has("exclude_object") }
    var hasSkewCorrection: Bool { has("skew_correction") }
    var hasFirmwareRetraction: Bool { has("firmware_retraction") }
    var hasSaveVariables: Bool { has("save_variables") }
    var hasIdleTimeout: Bool { has("idle_timeout") }
    var hasDisplayStatus: Bool { has("display_status") }
    var hasScrewsTiltAdjust: Bool { has("screws_tilt_adjust") }
    var hasZTiltAdjust: Bool { has("z_tilt") }
    var hasQuadGantryLevel: Bool { has("quad_gantry_level") }

    /// A macro Klipper defines, looked up by name. Used to prefer the printer's
    /// own PAUSE/RESUME/CANCEL_PRINT over the bare Moonraker calls.
    func macro(named name: String) -> MacroSpec? {
        macros.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Motion safety

    /// Clamps a target coordinate to the configured travel of that axis.
    ///
    /// Returns nil when the axis is unknown, which callers treat as "refuse"
    /// rather than "allow": moving an axis whose limits were never discovered is
    /// exactly the guess this type exists to prevent.
    func clampTarget(axis: String, to value: Double) -> Double? {
        axisLimits[axis.lowercased()]?.clamp(value)
    }

    /// Given the current position, how far this axis may still be jogged in the
    /// requested direction before hitting a configured limit.
    func allowedJog(axis: String, from current: Double, delta: Double) -> Double? {
        guard let limit = axisLimits[axis.lowercased()] else { return nil }
        let target = limit.clamp(current + delta)
        return target - current
    }

    func isHomed(_ axis: String) -> Bool {
        homedAxes.lowercased().contains(axis.lowercased())
    }
}
