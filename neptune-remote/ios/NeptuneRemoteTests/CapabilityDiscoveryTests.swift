import XCTest
@testable import NeptuneRemote

/// Discovery is tested against configurations that are deliberately *not* a
/// Neptune 3 Plus, because the whole point is that the app adapts to whatever
/// printer.cfg it is pointed at.
final class CapabilityDiscoveryTests: XCTestCase {

    // MARK: - Fixtures

    /// A CoreXY machine with a differently sized bed, two extra fans, no probe,
    /// and macros the app has never heard of.
    private func coreXYSettings() -> [String: ConfigValue] {
        decode("""
        {
          "printer": {
            "kinematics": "corexy",
            "max_velocity": 500,
            "max_accel": 9000,
            "max_z_velocity": 15,
            "max_z_accel": 350,
            "square_corner_velocity": 8
          },
          "stepper_x": { "position_min": 0, "position_max": 250 },
          "stepper_y": { "position_min": -4, "position_max": 252 },
          "stepper_z": { "position_max": 240 },
          "extruder": {
            "min_temp": 10, "max_temp": 320, "min_extrude_temp": 180,
            "max_extrude_only_distance": 150, "nozzle_diameter": 0.6,
            "sensor_type": "PT1000"
          },
          "heater_bed": { "min_temp": 0, "max_temp": 130, "sensor_type": "Generic 3950" },
          "bed_mesh": {
            "mesh_min": [15, 15], "mesh_max": [235, 235],
            "probe_count": [7, 7], "algorithm": "bicubic",
            "speed": 200, "horizontal_move_z": 3, "fade_start": 0.6, "fade_end": 10
          },
          "bltouch": { "z_offset": 1.94, "x_offset": -31.8, "y_offset": -41, "speed": 8 },
          "input_shaper": {
            "shaper_type_x": "mzv", "shaper_type_y": "ei",
            "shaper_freq_x": 62.4, "shaper_freq_y": 45.2
          },
          "safe_z_home": { "home_xy_position": [125, 125], "z_hop": 10, "speed": 60 },
          "gcode_macro PRINT_START": { "gcode": "G28\\nBED_MESH_CALIBRATE", "description": "Start" },
          "gcode_macro BLOB_PURGE": { "gcode": "G1 E{params.LENGTH|default(20)}" }
        }
        """)
    }

    private func coreXYObjects() -> [String] {
        [
            "bed_mesh", "bltouch", "configfile", "display_status", "exclude_object",
            "extruder", "fan", "fan_generic exhaust", "gcode_macro BLOB_PURGE",
            "gcode_macro PRINT_START", "gcode_move", "heater_bed",
            "heater_fan hotend_fan", "controller_fan mcu_fan", "idle_timeout",
            "input_shaper", "adxl345", "resonance_tester", "pause_resume",
            "print_stats", "filament_switch_sensor runout",
            "temperature_sensor mcu", "toolhead", "virtual_sdcard"
        ]
    }

    private func decode(_ json: String) -> [String: ConfigValue] {
        (try? JSONDecoder().decode([String: ConfigValue].self, from: Data(json.utf8))) ?? [:]
    }

    private func build() -> PrinterCapabilities {
        CapabilityDiscovery.build(settings: coreXYSettings(), objects: coreXYObjects())
    }

    // MARK: - Axes

    func testAxisLimitsComeFromTheConfigNotFromAnAssumedPrinter() throws {
        let capabilities = build()
        XCTAssertEqual(capabilities.xLimit?.min, 0)
        XCTAssertEqual(capabilities.xLimit?.max, 250)
        XCTAssertEqual(capabilities.yLimit?.min, -4)
        XCTAssertEqual(capabilities.yLimit?.max, 252)
        // position_min omitted for Z: Klipper's default of 0 applies.
        XCTAssertEqual(capabilities.zLimit?.min, 0)
        XCTAssertEqual(capabilities.zLimit?.max, 240)

        let volume = try XCTUnwrap(capabilities.buildVolume)
        XCTAssertEqual(volume.x, 250, accuracy: 0.01)
        XCTAssertEqual(volume.z, 240, accuracy: 0.01)
        XCTAssertNotEqual(volume.x, 320, "must not fall back to the old hardcoded volume")
    }

    func testJogIsClampedToConfiguredTravel() {
        let capabilities = build()
        // 240 away from X=245 would run past position_max of 250.
        XCTAssertEqual(capabilities.allowedJog(axis: "x", from: 245, delta: 50), 5)
        // Backwards past position_min is clamped the same way.
        XCTAssertEqual(capabilities.allowedJog(axis: "y", from: 0, delta: -50), -4)
        // Inside the range, nothing is changed.
        XCTAssertEqual(capabilities.allowedJog(axis: "z", from: 100, delta: 10), 10)
    }

    /// An axis with no discovered limits must be refused, not guessed at.
    func testUnknownAxisHasNoAllowedMove() {
        let capabilities = build()
        XCTAssertNil(capabilities.allowedJog(axis: "a", from: 0, delta: 10))
        XCTAssertNil(capabilities.clampTarget(axis: "w", to: 10))
    }

    func testSafeZHomeIsRead() throws {
        let home = try XCTUnwrap(build().safeZHome)
        XCTAssertEqual(home.x, 125)
        XCTAssertEqual(home.y, 125)
        XCTAssertEqual(home.zHop, 10)
    }

    // MARK: - Heaters

    func testHeaterLimitsAreTheConfiguredOnes() {
        let capabilities = build()
        let extruder = capabilities.primaryExtruder
        XCTAssertEqual(extruder?.maxTemp, 320, "not the 300 the slider used to assume")
        XCTAssertEqual(extruder?.minExtrudeTemp, 180)
        XCTAssertEqual(extruder?.maxExtrudeOnlyDistance, 150)
        XCTAssertEqual(extruder?.sensorType, "PT1000")

        XCTAssertEqual(capabilities.bedHeater?.maxTemp, 130, "not the 120 the slider used to assume")
        XCTAssertTrue(capabilities.hasHeatedBed)
    }

    func testTargetsAreCappedAtMaxTemp() throws {
        let extruder = try XCTUnwrap(build().primaryExtruder)
        XCTAssertEqual(extruder.clampTarget(400), 320)
        XCTAssertEqual(extruder.clampTarget(-20), 0)
        XCTAssertEqual(extruder.clampTarget(210), 210)
    }

    /// A printer with no bed section must report no heated bed, so the UI can
    /// hide the control instead of offering a command that cannot work.
    func testPrinterWithoutHeatedBed() {
        let capabilities = CapabilityDiscovery.build(
            settings: decode("""
            {"stepper_x": {"position_max": 120},
             "stepper_y": {"position_max": 120},
             "stepper_z": {"position_max": 120},
             "extruder": {"max_temp": 260}}
            """),
            objects: ["extruder", "fan", "toolhead", "gcode_move"]
        )
        XCTAssertFalse(capabilities.hasHeatedBed)
        XCTAssertNil(capabilities.bedHeater)
    }

    // MARK: - Fans

    func testEveryFanIsDiscoveredWithItsExactObjectName() {
        let fans = build().fans
        XCTAssertEqual(
            Set(fans.map(\.object)),
            ["fan", "fan_generic exhaust", "heater_fan hotend_fan", "controller_fan mcu_fan"]
        )
        // The part-cooling fan sorts first.
        XCTAssertEqual(fans.first?.object, "fan")
    }

    /// Only the fans Klipper lets us drive get a control. The rest are managed
    /// by Klipper and commanding them would mean guessing at a pin.
    func testOnlyPartCoolingAndGenericFansAreControllable() {
        let fans = build().fans
        func fan(_ object: String) -> PrinterCapabilities.FanSpec? {
            fans.first { $0.object == object }
        }
        XCTAssertEqual(fan("fan")?.isControllable, true)
        XCTAssertEqual(fan("fan_generic exhaust")?.isControllable, true)
        XCTAssertEqual(fan("heater_fan hotend_fan")?.isControllable, false)
        XCTAssertEqual(fan("controller_fan mcu_fan")?.isControllable, false)
    }

    func testFanCommandsMatchTheFanKind() {
        let fans = build().fans
        let part = fans.first { $0.object == "fan" }
        XCTAssertEqual(part?.speedCommand(percent: 100), "M106 S255")
        XCTAssertEqual(part?.speedCommand(percent: 0), "M107")

        let generic = fans.first { $0.object == "fan_generic exhaust" }
        XCTAssertEqual(generic?.speedCommand(percent: 50), "SET_FAN_SPEED FAN=exhaust SPEED=0.50")

        let managed = fans.first { $0.object == "heater_fan hotend_fan" }
        XCTAssertNil(managed?.speedCommand(percent: 100), "must not invent a command")
    }

    // MARK: - Probe, mesh, shaper

    /// The probe is whichever section exists. Assuming BLTouch is exactly the
    /// bug this is guarding.
    func testProbeKindIsTheConfiguredOne() throws {
        let probe = try XCTUnwrap(build().probe)
        XCTAssertEqual(probe.kind, "bltouch")
        XCTAssertEqual(probe.zOffset, 1.94)

        let inductive = CapabilityDiscovery.build(
            settings: decode(#"{"probe": {"z_offset": 2.2, "speed": 5}}"#),
            objects: ["probe"]
        )
        XCTAssertEqual(inductive.probe?.kind, "probe")

        let none = CapabilityDiscovery.build(settings: [:], objects: ["extruder"])
        XCTAssertNil(none.probe)
        XCTAssertFalse(none.hasProbe)
    }

    func testBedMeshGeometryIsRead() throws {
        let mesh = try XCTUnwrap(build().bedMesh)
        XCTAssertEqual(mesh.meshMin ?? [], [15, 15])
        XCTAssertEqual(mesh.meshMax ?? [], [235, 235])
        XCTAssertEqual(mesh.probeCount ?? [], [7, 7])
        XCTAssertEqual(mesh.algorithm, "bicubic")
        XCTAssertEqual(mesh.fadeEnd, 10)
    }

    func testInputShaperAndAccelerometer() {
        let capabilities = build()
        XCTAssertEqual(capabilities.inputShaper?.shaperTypeX, "mzv")
        XCTAssertEqual(capabilities.inputShaper?.shaperFreqY, 45.2)
        XCTAssertEqual(capabilities.accelerometers, ["adxl345"])
        XCTAssertTrue(capabilities.hasResonanceTester)
    }

    /// Without an accelerometer there is nothing to run a resonance test with,
    /// so the feature must report itself unavailable.
    func testResonanceTesterNeedsAnAccelerometer() {
        let capabilities = CapabilityDiscovery.build(
            settings: [:], objects: ["resonance_tester", "extruder"]
        )
        XCTAssertFalse(capabilities.hasResonanceTester)
    }

    // MARK: - Macros

    func testMacrosAreDiscoveredWithNoHardcodedList() {
        let macros = build().macros
        XCTAssertEqual(macros.map(\.name), ["BLOB_PURGE", "PRINT_START"])
        XCTAssertEqual(macros.first { $0.name == "PRINT_START" }?.description, "Start")
    }

    func testMacrosReadingParametersAreFlagged() {
        let macros = build().macros
        XCTAssertEqual(macros.first { $0.name == "BLOB_PURGE" }?.hasParameters, true)
        XCTAssertEqual(macros.first { $0.name == "PRINT_START" }?.hasParameters, false)
    }

    func testMovingOrHeatingMacrosRequireConfirmation() {
        XCTAssertTrue(PrinterCapabilities.MacroSpec(
            name: "PRINT_START", description: nil, hasParameters: false
        ).needsConfirmation)
        XCTAssertTrue(PrinterCapabilities.MacroSpec(
            name: "UNLOAD_FILAMENT", description: nil, hasParameters: false
        ).needsConfirmation)
        XCTAssertFalse(PrinterCapabilities.MacroSpec(
            name: "STATUS_LEDS", description: nil, hasParameters: false
        ).needsConfirmation)
    }

    // MARK: - Feature flags

    func testOptionalModulesFollowTheObjectList() {
        let capabilities = build()
        XCTAssertTrue(capabilities.hasExcludeObject)
        XCTAssertTrue(capabilities.hasPauseResume)
        XCTAssertTrue(capabilities.hasVirtualSDCard)
        XCTAssertTrue(capabilities.hasBedMesh)
        XCTAssertFalse(capabilities.hasSkewCorrection)
        XCTAssertFalse(capabilities.hasQuadGantryLevel)
        XCTAssertFalse(capabilities.hasSaveVariables)
    }

    func testFilamentSensorIsDiscovered() {
        let sensors = build().filamentSensors
        XCTAssertEqual(sensors.map(\.object), ["filament_switch_sensor runout"])
        XCTAssertEqual(sensors.first?.name, "runout")
        XCTAssertEqual(sensors.first?.kind, "switch")
    }

    func testTemperatureSensorsIncludeHeatersAndStandaloneSensors() {
        let objects = Set(build().temperatureSensors.map(\.object))
        XCTAssertTrue(objects.contains("extruder"))
        XCTAssertTrue(objects.contains("heater_bed"))
        XCTAssertTrue(objects.contains("temperature_sensor mcu"))
    }

    func testConfiguredMaximaAreRead() {
        let capabilities = build()
        XCTAssertEqual(capabilities.maxVelocity, 500)
        XCTAssertEqual(capabilities.maxAccel, 9000)
        XCTAssertEqual(capabilities.kinematics, "corexy")
    }

    // MARK: - Change detection

    /// Editing printer.cfg has to be noticed, so the app picks it up on a
    /// FIRMWARE_RESTART rather than needing a reinstall.
    func testSignatureChangesWithTheConfiguration() {
        let original = build()
        var edited = coreXYSettings()
        edited["stepper_x"] = .object(["position_max": .number(300)])
        let changed = CapabilityDiscovery.build(settings: edited, objects: coreXYObjects())

        XCTAssertNotEqual(original.configSignature, changed.configSignature)
        XCTAssertEqual(changed.xLimit?.max, 300)
    }

    func testSignatureIsStableForAnUnchangedConfiguration() {
        XCTAssertEqual(build().configSignature, build().configSignature)
    }

    func testSignatureChangesWhenAModuleIsAdded() {
        let original = build()
        let withExtra = CapabilityDiscovery.build(
            settings: coreXYSettings(),
            objects: coreXYObjects() + ["skew_correction"]
        )
        XCTAssertNotEqual(original.configSignature, withExtra.configSignature)
        XCTAssertTrue(withExtra.hasSkewCorrection)
    }

    // MARK: - Parsing

    func testObjectNamesSplitIntoKindAndName() {
        XCTAssertEqual(CapabilityDiscovery.split("heater_fan hotend").kind, "heater_fan")
        XCTAssertEqual(CapabilityDiscovery.split("heater_fan hotend").name, "hotend")
        XCTAssertEqual(CapabilityDiscovery.split("extruder").kind, "extruder")
        XCTAssertNil(CapabilityDiscovery.split("extruder").name)
        // Macro names can contain underscores and digits.
        XCTAssertEqual(CapabilityDiscovery.split("gcode_macro M600").name, "M600")
    }

    /// Klipper writes coordinate pairs as arrays in some sections and as
    /// comma-separated strings in others.
    func testCoordinatePairsParseFromBothShapes() {
        let asArray = decode(#"{"bed_mesh": {"mesh_min": [10, 12]}}"#)
        XCTAssertEqual(asArray.section("bed_mesh")?.numbers("mesh_min") ?? [], [10, 12])

        let asString = decode(#"{"bed_mesh": {"mesh_min": "10, 12"}}"#)
        XCTAssertEqual(asString.section("bed_mesh")?.numbers("mesh_min") ?? [], [10, 12])
    }

    func testEmptyConfigurationReportsNothingRatherThanDefaults() {
        let capabilities = CapabilityDiscovery.build(settings: [:], objects: [])
        XCTAssertTrue(capabilities.axisLimits.isEmpty)
        XCTAssertNil(capabilities.buildVolume, "must not invent a build volume")
        XCTAssertFalse(capabilities.hasHeatedBed)
        XCTAssertTrue(capabilities.fans.isEmpty)
        XCTAssertTrue(capabilities.macros.isEmpty)
    }
}
