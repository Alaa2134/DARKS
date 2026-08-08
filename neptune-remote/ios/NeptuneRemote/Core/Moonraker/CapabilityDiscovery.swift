import Foundation

/// Turns Klipper's `configfile.settings` and `printer.objects.list` into a
/// `PrinterCapabilities`.
///
/// Pure and synchronous so it can be tested against captured configurations
/// from real machines without a printer attached.
enum CapabilityDiscovery {

    /// Section kinds that describe a fan, mapped to how they are driven.
    static let fanKinds = [
        "fan", "fan_generic", "heater_fan", "controller_fan", "temperature_fan"
    ]

    /// Probe sections Klipper may instantiate. `probe` is the generic one;
    /// the rest are specific hardware. We take whichever exists rather than
    /// assuming a BLTouch.
    static let probeKinds = [
        "probe", "bltouch", "smart_effector", "dockable_probe",
        "probe_eddy_current", "load_cell_probe", "biqu_microprobe"
    ]

    static let accelerometerKinds = ["adxl345", "lis2dw", "lis3dh", "mpu9250", "icm20948"]

    // MARK: - Entry point

    static func build(
        settings: [String: ConfigValue],
        objects: [String],
        homedAxes: String = "",
        meshProfiles: [String] = [],
        klipperVersion: String = ""
    ) -> PrinterCapabilities {
        var capabilities = PrinterCapabilities()
        capabilities.objects = objects.sorted()
        capabilities.settings = settings
        capabilities.homedAxes = homedAxes
        capabilities.klipperVersion = klipperVersion
        capabilities.discoveredAt = Date()

        capabilities.axisLimits = axisLimits(from: settings)
        capabilities.safeZHome = safeZHome(from: settings)
        capabilities.heaters = heaters(from: settings, objects: objects)
        capabilities.fans = fans(from: settings, objects: objects)
        capabilities.temperatureSensors = sensors(from: settings, objects: objects)
        capabilities.filamentSensors = filamentSensors(from: settings, objects: objects)
        capabilities.bedMesh = bedMesh(from: settings, objects: objects, profiles: meshProfiles)
        capabilities.probe = probe(from: settings, objects: objects)
        capabilities.inputShaper = inputShaper(from: settings, objects: objects)
        capabilities.accelerometers = accelerometers(from: objects)
        capabilities.macros = macros(from: settings, objects: objects)

        if let printer = settings.section("printer") {
            capabilities.maxVelocity = printer.double("max_velocity")
            capabilities.maxAccel = printer.double("max_accel")
            capabilities.maxZVelocity = printer.double("max_z_velocity")
            capabilities.maxZAccel = printer.double("max_z_accel")
            capabilities.squareCornerVelocity = printer.double("square_corner_velocity")
            capabilities.kinematics = printer.string("kinematics")
        }

        capabilities.configSignature = signature(settings: settings, objects: objects)
        return capabilities
    }

    // MARK: - Axes

    /// Reads travel from the stepper sections. `position_min` defaults to 0 in
    /// Klipper when omitted, and Z frequently omits it, so only `position_max`
    /// is strictly required for an axis to count as known.
    static func axisLimits(from settings: [String: ConfigValue]) -> [String: PrinterCapabilities.AxisLimit] {
        var result: [String: PrinterCapabilities.AxisLimit] = [:]
        for axis in ["x", "y", "z"] {
            // CoreXY and delta printers still expose stepper_x/y/z sections.
            guard let section = settings.section("stepper_\(axis)"),
                  let maximum = section.double("position_max")
            else { continue }
            let minimum = section.double("position_min") ?? 0
            guard maximum > minimum else { continue }
            result[axis] = PrinterCapabilities.AxisLimit(axis: axis, min: minimum, max: maximum)
        }
        return result
    }

    static func safeZHome(from settings: [String: ConfigValue]) -> PrinterCapabilities.SafeZHome? {
        guard let section = settings.section("safe_z_home") else { return nil }
        let position = section.numbers("home_xy_position")
        return PrinterCapabilities.SafeZHome(
            x: position?.first,
            y: position?.dropFirst().first,
            zHop: section.double("z_hop"),
            speed: section.double("speed")
        )
    }

    // MARK: - Heaters

    static func heaters(
        from settings: [String: ConfigValue],
        objects: [String]
    ) -> [PrinterCapabilities.HeaterSpec] {
        var result: [PrinterCapabilities.HeaterSpec] = []

        // Extruders are `extruder`, `extruder1`, `extruder2`, ... in Klipper.
        let extruderNames = objects
            .filter { $0 == "extruder" || ($0.hasPrefix("extruder") && Int($0.dropFirst(8)) != nil) }
            .sorted()

        for name in extruderNames {
            guard let section = settings.section(name) else { continue }
            result.append(
                PrinterCapabilities.HeaterSpec(
                    object: name,
                    displayName: extruderNames.count > 1 ? name : L.t("temperature.nozzle"),
                    minTemp: section.double("min_temp") ?? 0,
                    maxTemp: section.double("max_temp") ?? 0,
                    sensorType: section.string("sensor_type"),
                    // Klipper's own default when the option is absent.
                    minExtrudeTemp: section.double("min_extrude_temp") ?? 170,
                    maxExtrudeOnlyDistance: section.double("max_extrude_only_distance") ?? 50,
                    maxExtrudeCrossSection: section.double("max_extrude_cross_section"),
                    nozzleDiameter: section.double("nozzle_diameter"),
                    filamentDiameter: section.double("filament_diameter")
                )
            )
        }

        if objects.contains("heater_bed"), let section = settings.section("heater_bed") {
            result.append(
                PrinterCapabilities.HeaterSpec(
                    object: "heater_bed",
                    displayName: L.t("temperature.bed"),
                    minTemp: section.double("min_temp") ?? 0,
                    maxTemp: section.double("max_temp") ?? 0,
                    sensorType: section.string("sensor_type"),
                    minExtrudeTemp: nil,
                    maxExtrudeOnlyDistance: nil,
                    maxExtrudeCrossSection: nil,
                    nozzleDiameter: nil,
                    filamentDiameter: nil
                )
            )
        }

        return result
    }

    // MARK: - Fans

    /// Every fan section in the config, each addressed by its exact Klipper
    /// object name. A printer with a cooling upgrade has several; assuming one
    /// is how an app ends up driving the wrong one.
    static func fans(
        from settings: [String: ConfigValue],
        objects: [String]
    ) -> [PrinterCapabilities.FanSpec] {
        var result: [PrinterCapabilities.FanSpec] = []
        for object in objects {
            let (kind, name) = split(object)
            guard fanKinds.contains(kind) else { continue }
            // A bare `fan` has no name; every other kind does.
            guard kind == "fan" || name != nil else { continue }
            result.append(PrinterCapabilities.FanSpec(object: object, kind: kind, name: name))
        }
        // The part-cooling fan first, then the rest alphabetically - it is the
        // one people reach for.
        return result.sorted {
            if ($0.kind == "fan") != ($1.kind == "fan") { return $0.kind == "fan" }
            return $0.object.localizedCaseInsensitiveCompare($1.object) == .orderedAscending
        }
    }

    // MARK: - Sensors

    static func sensors(
        from settings: [String: ConfigValue],
        objects: [String]
    ) -> [PrinterCapabilities.SensorSpec] {
        var result: [PrinterCapabilities.SensorSpec] = []
        for object in objects {
            let (kind, name) = split(object)
            switch kind {
            case "temperature_sensor", "temperature_fan":
                result.append(
                    PrinterCapabilities.SensorSpec(
                        object: object,
                        displayName: (name ?? kind).replacingOccurrences(of: "_", with: " "),
                        kind: kind
                    )
                )
            case "extruder" where object == "extruder" || Int(object.dropFirst(8)) != nil:
                result.append(
                    PrinterCapabilities.SensorSpec(
                        object: object, displayName: L.t("temperature.nozzle"), kind: "extruder"
                    )
                )
            case "heater_bed":
                result.append(
                    PrinterCapabilities.SensorSpec(
                        object: object, displayName: L.t("temperature.bed"), kind: "heater_bed"
                    )
                )
            default:
                continue
            }
        }
        return result
    }

    static func filamentSensors(
        from settings: [String: ConfigValue],
        objects: [String]
    ) -> [PrinterCapabilities.FilamentSensorSpec] {
        objects.compactMap { object in
            let (kind, name) = split(object)
            guard kind == "filament_switch_sensor" || kind == "filament_motion_sensor",
                  let name
            else { return nil }
            return PrinterCapabilities.FilamentSensorSpec(
                object: object,
                name: name,
                kind: kind == "filament_motion_sensor" ? "motion" : "switch"
            )
        }
    }

    // MARK: - Probe and mesh

    static func probe(
        from settings: [String: ConfigValue],
        objects: [String]
    ) -> PrinterCapabilities.ProbeSpec? {
        // Take whichever probe section exists rather than assuming BLTouch.
        for kind in probeKinds {
            guard objects.contains(where: { $0 == kind || $0.hasPrefix("\(kind) ") }),
                  let section = settings.section(kind)
            else { continue }
            return PrinterCapabilities.ProbeSpec(
                kind: kind,
                zOffset: section.double("z_offset"),
                xOffset: section.double("x_offset"),
                yOffset: section.double("y_offset"),
                speed: section.double("speed"),
                samples: section.double("samples").map { Int($0) }
            )
        }
        return nil
    }

    static func bedMesh(
        from settings: [String: ConfigValue],
        objects: [String],
        profiles: [String]
    ) -> PrinterCapabilities.BedMeshSpec? {
        guard objects.contains("bed_mesh"), let section = settings.section("bed_mesh") else {
            return nil
        }
        return PrinterCapabilities.BedMeshSpec(
            meshMin: section.numbers("mesh_min"),
            meshMax: section.numbers("mesh_max"),
            probeCount: section.numbers("probe_count"),
            algorithm: section.string("algorithm"),
            speed: section.double("speed"),
            horizontalMoveZ: section.double("horizontal_move_z"),
            fadeStart: section.double("fade_start"),
            fadeEnd: section.double("fade_end"),
            profiles: profiles.sorted()
        )
    }

    static func inputShaper(
        from settings: [String: ConfigValue],
        objects: [String]
    ) -> PrinterCapabilities.InputShaperSpec? {
        guard objects.contains("input_shaper") else { return nil }
        let section = settings.section("input_shaper") ?? [:]
        return PrinterCapabilities.InputShaperSpec(
            shaperTypeX: section.string("shaper_type_x") ?? section.string("shaper_type"),
            shaperTypeY: section.string("shaper_type_y") ?? section.string("shaper_type"),
            shaperFreqX: section.double("shaper_freq_x"),
            shaperFreqY: section.double("shaper_freq_y")
        )
    }

    static func accelerometers(from objects: [String]) -> [String] {
        objects.filter { object in
            let (kind, _) = split(object)
            return accelerometerKinds.contains(kind)
        }
    }

    // MARK: - Macros

    /// Every `[gcode_macro NAME]` in the config. No allowlist: a macro the user
    /// wrote themselves is exactly as real as PAUSE.
    static func macros(
        from settings: [String: ConfigValue],
        objects: [String]
    ) -> [PrinterCapabilities.MacroSpec] {
        var result: [PrinterCapabilities.MacroSpec] = []
        for object in objects {
            let (kind, name) = split(object)
            guard kind == "gcode_macro", let name, !name.isEmpty else { continue }
            let section = settings.section(object) ?? settings.section("gcode_macro \(name)") ?? [:]
            let body = section.string("gcode") ?? ""
            result.append(
                PrinterCapabilities.MacroSpec(
                    name: name.uppercased(),
                    description: section.string("description"),
                    // Klipper exposes macro parameters as `params.NAME` in the
                    // body; a macro that reads one needs input to be useful.
                    hasParameters: body.contains("params.")
                )
            )
        }
        return result.sorted()
    }

    // MARK: - Helpers

    /// Splits a Klipper object name into its kind and optional name:
    /// `"heater_fan hotend"` -> `("heater_fan", "hotend")`.
    static func split(_ object: String) -> (kind: String, name: String?) {
        let parts = object.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (object.lowercased(), nil) }
        return (parts[0].lowercased(), parts[1])
    }

    /// Cheap fingerprint of the configuration, used to notice a printer.cfg
    /// change without diffing the whole tree on every reconnect.
    static func signature(settings: [String: ConfigValue], objects: [String]) -> String {
        var hasher = Hasher()
        for object in objects.sorted() { hasher.combine(object) }
        for key in settings.keys.sorted() {
            hasher.combine(key)
            if let section = settings[key]?.objectValue {
                for option in section.keys.sorted() {
                    hasher.combine(option)
                    hasher.combine(section[option]?.stringValue ?? "")
                }
            }
        }
        return String(hasher.finalize(), radix: 16)
    }
}
