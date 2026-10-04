import Foundation

/// A capability set for demo mode, so every screen has something to render
/// without a printer attached.
///
/// This is the *only* place in the app that states Neptune 3 Plus numbers, and
/// it is explicitly fake data for a mode that talks to no hardware. Everywhere
/// else these values are read from the connected printer's own printer.cfg.
enum DemoCapabilities {
    static let neptune3Plus: PrinterCapabilities = {
        var value = PrinterCapabilities()
        value.klipperVersion = "v0.12.0-demo"
        value.configSignature = "demo"
        value.discoveredAt = Date()

        value.objects = [
            "bed_mesh", "configfile", "display_status", "extruder", "fan",
            "gcode_macro CANCEL_PRINT", "gcode_macro LOAD_FILAMENT",
            "gcode_macro PAUSE", "gcode_macro RESUME", "gcode_macro UNLOAD_FILAMENT",
            "gcode_move", "heater_bed", "heater_fan hotend_fan", "idle_timeout",
            "pause_resume", "print_stats", "probe", "temperature_sensor mcu_temp",
            "temperature_sensor raspberry_pi", "toolhead", "virtual_sdcard", "webhooks"
        ]

        value.axisLimits = [
            "x": .init(axis: "x", min: -3, max: 330),
            "y": .init(axis: "y", min: -8, max: 330),
            "z": .init(axis: "z", min: 0, max: 400)
        ]
        value.homedAxes = "xyz"

        value.heaters = [
            .init(
                object: "extruder", displayName: L.t("temperature.nozzle"),
                minTemp: 0, maxTemp: 300, sensorType: "EPCOS 100K B57560G104F",
                minExtrudeTemp: 170, maxExtrudeOnlyDistance: 100,
                maxExtrudeCrossSection: nil, nozzleDiameter: 0.4, filamentDiameter: 1.75
            ),
            .init(
                object: "heater_bed", displayName: L.t("temperature.bed"),
                minTemp: 0, maxTemp: 110, sensorType: "EPCOS 100K B57560G104F",
                minExtrudeTemp: nil, maxExtrudeOnlyDistance: nil,
                maxExtrudeCrossSection: nil, nozzleDiameter: nil, filamentDiameter: nil
            )
        ]

        value.fans = [
            .init(object: "fan", kind: "fan", name: nil),
            .init(object: "heater_fan hotend_fan", kind: "heater_fan", name: "hotend_fan")
        ]

        value.temperatureSensors = [
            .init(object: "extruder", displayName: L.t("temperature.nozzle"), kind: "extruder"),
            .init(object: "heater_bed", displayName: L.t("temperature.bed"), kind: "heater_bed"),
            .init(
                object: "temperature_sensor raspberry_pi",
                displayName: "raspberry pi", kind: "temperature_sensor"
            ),
            .init(
                object: "temperature_sensor mcu_temp",
                displayName: "mcu temp", kind: "temperature_sensor"
            )
        ]

        value.bedMesh = .init(
            meshMin: [20, 20], meshMax: [300, 300], probeCount: [5, 5],
            algorithm: "bicubic", speed: 120, horizontalMoveZ: 5,
            fadeStart: 1, fadeEnd: 10, profiles: ["default"]
        )
        value.probe = .init(kind: "probe", zOffset: 2.15, xOffset: -28.5, yOffset: -18, speed: 5, samples: 2)

        value.macros = [
            .init(name: "CANCEL_PRINT", description: "Cancel the running print", hasParameters: false),
            .init(name: "LOAD_FILAMENT", description: "Load filament", hasParameters: true),
            .init(name: "PAUSE", description: "Pause the running print", hasParameters: false),
            .init(name: "RESUME", description: "Resume the paused print", hasParameters: false),
            .init(name: "UNLOAD_FILAMENT", description: "Unload filament", hasParameters: true)
        ]

        value.maxVelocity = 300
        value.maxAccel = 3000
        value.maxZVelocity = 10
        value.maxZAccel = 100
        value.squareCornerVelocity = 5
        value.kinematics = "cartesian"

        return value
    }()
}
