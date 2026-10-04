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

    // MARK: - Lights

    /// A light this printer actually has.
    ///
    /// Klipper has no "light" concept - it has pins and it has LED chains, and
    /// what they are wired to is only known to whoever wired them. So the two
    /// halves of this are discovered very differently:
    ///
    /// * `led` / `neopixel` / `dotstar` / `pca9533` / `pca9632` are LED drivers
    ///   by definition. If one exists, it is a light.
    /// * `[output_pin]` is a bare pin. The same section drives beepers, lasers,
    ///   relays and mains-switching SSRs, and toggling one of those because the
    ///   app decided it looked like a lamp would be the exact kind of guess this
    ///   whole type exists to prevent. So an output pin is offered as a light
    ///   only when its own name says so, and the object name is shown next to
    ///   the switch so it is obvious which pin is about to move.
    struct LightSpec: Equatable, Identifiable {
        /// Klipper object name exactly as it must be addressed, e.g.
        /// `output_pin caselight`, `neopixel toolhead`.
        let object: String
        /// Section kind: output_pin / led / neopixel / dotstar / pca9533 / pca9632.
        let kind: String
        /// The part after the kind. Always present - every one of these is a
        /// named section.
        let name: String
        /// Whether it can sit between off and on. A PWM pin and every addressable
        /// LED can; a plain digital pin cannot, and giving that one a brightness
        /// slider would be a lie the hardware then rounds to on or off.
        let isDimmable: Bool
        /// Klipper's `scale` for an output pin. With `scale: 255` the user's own
        /// macros write VALUE in 0-255, and sending 0.5 to that pin would look
        /// like a failure rather than half brightness.
        let scale: Double
        /// Separate red/green/blue channels, so a colour is meaningful.
        let hasColour: Bool
        /// A dedicated white channel. Only set when the config actually says so
        /// (`color_order` containing W, or a configured `white_pin`): driving
        /// WHITE on a strip that has no white channel turns the light *off*.
        let hasWhite: Bool

        var id: String { object }

        /// SET_LED addresses these; SET_PIN addresses an output pin.
        var isAddressable: Bool { kind != "output_pin" }

        var displayName: String {
            name.replacingOccurrences(of: "_", with: " ")
        }

        /// White light at the given level, 0...1.
        ///
        /// `SYNC=0` on the LED form is deliberate. SET_LED defaults to syncing
        /// with the movement queue, so during a print the light would not change
        /// until the queued moves had run - which for a lamp reads as the button
        /// not working.
        func command(brightness: Double) -> String {
            let level = min(max(brightness, 0), 1)
            guard isAddressable else {
                let value = isDimmable ? level : (level > 0 ? 1 : 0)
                return String(format: "SET_PIN PIN=%@ VALUE=%.3f", name, value * scale)
            }
            if hasWhite {
                return String(
                    format: "SET_LED LED=%@ RED=0 GREEN=0 BLUE=0 WHITE=%.3f SYNC=0", name, level
                )
            }
            return String(
                format: "SET_LED LED=%@ RED=%.3f GREEN=%.3f BLUE=%.3f SYNC=0",
                name, level, level, level
            )
        }

        /// A specific colour, or nil when this light has no colour to set.
        func command(red: Double, green: Double, blue: Double) -> String? {
            guard isAddressable, hasColour else { return nil }
            let clamp = { (value: Double) in min(max(value, 0), 1) }
            return String(
                format: "SET_LED LED=%@ RED=%.3f GREEN=%.3f BLUE=%.3f SYNC=0",
                name, clamp(red), clamp(green), clamp(blue)
            )
        }

        /// How bright Klipper says this light currently is, 0...1.
        ///
        /// Returns nil when the object reported nothing recognisable, which the
        /// UI shows as unknown rather than as off - a switch that claims "off"
        /// about a lamp that is on is worse than one that admits it does not
        /// know yet.
        func brightness(fromStatus status: [String: ConfigValue]) -> Double? {
            guard isAddressable else {
                // Klipper divides by `scale` before storing, so `value` is
                // already 0...1 no matter what the user's macros write.
                return status.double("value").map { min(max($0, 0), 1) }
            }
            guard let first = status.value("color_data")?.arrayValue?.first else { return nil }
            let channels: [Double]
            if let list = first.numberList {
                channels = list
            } else if let entry = first.objectValue {
                // Some Klipper builds report each LED as a named channel map
                // instead of a 4-tuple.
                channels = ["R", "G", "B", "W"].compactMap {
                    entry.double($0) ?? entry.double($0.lowercased())
                }
            } else {
                return nil
            }
            guard let brightest = channels.max() else { return nil }
            return min(max(brightest, 0), 1)
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

        /// Whether running this macro should ask first. **Confirmed by default.**
        ///
        /// A list of dangerous verbs was tried first and is the wrong shape: it
        /// under-flags. `PRINT_START` heats the bed and slams the toolhead
        /// around, and matches none of the obvious words. The app cannot read a
        /// macro body's intent, and these names are the user's own, so any
        /// keyword list is a guess about someone else's vocabulary.
        ///
        /// Failing safe costs one tap on a harmless macro. Failing unsafe runs
        /// something destructive with no warning. Only names that clearly just
        /// report state skip the confirmation.
        var needsConfirmation: Bool {
            let upper = name.uppercased()
            let readOnly = [
                "STATUS", "QUERY", "LIST", "SHOW", "REPORT", "DUMP",
                "GET_", "_INFO", "NOTIFY", "LED", "M117"
            ]
            return !readOnly.contains { upper.contains($0) }
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
    var lights: [LightSpec] = []
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

    var hasLights: Bool { !lights.isEmpty }

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

    /// Whether Klipper will accept `SET_KINEMATIC_POSITION`.
    ///
    /// This is the way out of a printer that cannot home - a dead probe, a
    /// broken endstop - where every move is refused with "Must home axis first"
    /// and there is no way to raise the nozzle off the bed to go and look at the
    /// thing that is broken.
    ///
    /// Klipper registers the command from `[force_move]`, and only when that
    /// section says `enable_force_move: True`. Both are checked, because
    /// offering a button that comes back "Unknown command" is worse than not
    /// offering it: this printer has already ended a print that way once.
    var canSetKinematicPosition: Bool {
        guard let section = settings["force_move"]?.objectValue else { return false }
        return section["enable_force_move"]?.boolValue == true
    }
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
