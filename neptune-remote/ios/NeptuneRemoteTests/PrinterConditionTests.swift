import XCTest
@testable import NeptuneRemote

/// Covers the scenarios a printer actually goes through, because the bug this
/// replaces was a classifier that called all of them "Printer error".
final class PrinterConditionTests: XCTestCase {

    private func input(
        klippy: KlippyState = .ready,
        message: String = "",
        homed: String = "xyz",
        print state: PrinterState = .standby,
        printing: Bool = false,
        axes: [String] = ["x", "y", "z"],
        printMessage: String = ""
    ) -> PrinterConditionEvaluator.Input {
        var value = PrinterConditionEvaluator.Input()
        value.klippy = klippy
        value.klippyMessage = message
        value.homedAxes = homed
        value.printState = state
        value.isPrinting = printing
        value.configuredAxes = axes
        value.printMessage = printMessage
        return value
    }

    // MARK: - The reported bug

    /// "Z is not homed" is a normal state, not a hardware failure. It must be
    /// action-required, never an error, and it must carry a Home button.
    func testUnhomedAxisIsActionRequiredNotAnError() throws {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(message: "Z is not homed", homed: "xy")
        )

        XCTAssertEqual(conditions.count, 1, "one card, not three")
        let condition = try XCTUnwrap(conditions.first)
        XCTAssertEqual(condition.cause, .notHomed)
        XCTAssertEqual(condition.severity, .actionRequired)
        XCTAssertFalse(condition.isError, "must not be presented as a fault")
        XCTAssertEqual(condition.remedy, .homeAxes("z"))
        XCTAssertEqual(condition.axes, "z")
        // Klipper's own words survive for the technical details section.
        XCTAssertEqual(condition.rawMessage, "Z is not homed")
    }

    /// The exact deduplication the report asks for: one underlying condition
    /// must never produce "Printer error" + "Z is not homed" + "Printer error".
    func testOneCauseProducesOneCard() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(message: "Must home axis first", homed: "")
        )
        XCTAssertEqual(conditions.count, 1)
        XCTAssertEqual(conditions.first?.cause, .notHomed)
        XCTAssertEqual(
            conditions.filter { $0.cause == .unknownMessage }.count, 0,
            "the homing card already explains this message"
        )
    }

    func testAllThreeAxesUnhomedIsStillOneCard() {
        let conditions = PrinterConditionEvaluator.conditions(for: input(homed: ""))
        XCTAssertEqual(conditions.count, 1)
        XCTAssertEqual(conditions.first?.axes, "xyz")
        XCTAssertEqual(conditions.first?.remedy, .homeAxes("xyz"))
    }

    // MARK: - Scenarios

    func testFreshKlipperRestartIsInformational() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(klippy: .startup, homed: "")
        )
        XCTAssertEqual(conditions.first?.cause, .klippyStartup)
        XCTAssertEqual(conditions.first?.severity, .informational)
        // Homing is not nagged about while Klipper is still coming up.
        XCTAssertFalse(conditions.contains { $0.cause == .notHomed })
    }

    func testAfterHomingEverythingIsClear() {
        let conditions = PrinterConditionEvaluator.conditions(for: input(homed: "xyz"))
        XCTAssertTrue(conditions.isEmpty, "nothing to report on a homed, ready printer")
    }

    /// A message left over from before the restart must not resurrect an error
    /// card once Klipper reports ready and the axes are homed.
    func testStaleMessageDoesNotBecomeAnErrorOnceReady() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(message: "Z is not homed", homed: "xyz")
        )
        XCTAssertFalse(conditions.contains(where: \.isError))
        XCTAssertFalse(conditions.contains { $0.cause == .notHomed })
    }

    func testDuringPrintingHomingIsNotRaised() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(homed: "xy", print: .printing, printing: true)
        )
        XCTAssertFalse(conditions.contains { $0.cause == .notHomed })
    }

    func testPauseIsInformational() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(print: .paused, printing: true)
        )
        XCTAssertEqual(conditions.first?.cause, .printPaused)
        XCTAssertEqual(conditions.first?.severity, .informational)
        XCTAssertFalse(conditions.contains(where: \.isError))
    }

    // MARK: - Filament

    private func runoutSensor(kind: String) -> BackendFilamentSensor {
        let json = """
        {"name": "filament_sensor", "kind": "\(kind)", "enabled": true, "filament_detected": false}
        """
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(BackendFilamentSensor.self, from: Data(json.utf8))
    }

    func testARunoutIsReportedAsItselfNotAsAPause() throws {
        // Klipper's pause_on_runout produces a PAUSE, so without reading the
        // sensor the user sees the same card as when they tapped pause.
        var value = input(print: .paused, printing: true)
        value.filamentRunoutSensor = runoutSensor(kind: "switch")

        let conditions = PrinterConditionEvaluator.conditions(for: value)
        XCTAssertEqual(conditions.first?.cause, .filamentRunout)
        XCTAssertEqual(conditions.first?.severity, .actionRequired)
    }

    func testARunoutDoesNotAlsoRaiseAPauseCard() {
        // One condition, one card - the pause is the consequence, not a
        // second thing that happened.
        var value = input(print: .paused, printing: true)
        value.filamentRunoutSensor = runoutSensor(kind: "switch")

        let conditions = PrinterConditionEvaluator.conditions(for: value)
        XCTAssertFalse(conditions.contains { $0.cause == .printPaused })
    }

    func testASwitchSensorIsNotDescribedAsCatchingAJam() throws {
        var value = input(print: .paused, printing: true)
        value.filamentRunoutSensor = runoutSensor(kind: "switch")
        let switchCondition = try XCTUnwrap(
            PrinterConditionEvaluator.conditions(for: value).first
        )
        XCTAssertEqual(switchCondition.bodyKey, "condition.filament_runout.switch")

        value.filamentRunoutSensor = runoutSensor(kind: "motion")
        let motionCondition = try XCTUnwrap(
            PrinterConditionEvaluator.conditions(for: value).first
        )
        XCTAssertEqual(motionCondition.bodyKey, "condition.filament_runout.motion")
    }

    func testAPrinterWithNoSensorStillReportsAPlainPause() {
        // No sensor is not the same as "there is filament", so the pause card
        // has to stay for machines that cannot tell.
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(print: .paused, printing: true)
        )
        XCTAssertEqual(conditions.first?.cause, .printPaused)
    }

    func testARunoutIsNotAnError() {
        // It needs a person, but nothing is broken - red would be wrong.
        var value = input(print: .paused, printing: true)
        value.filamentRunoutSensor = runoutSensor(kind: "switch")
        XCTAssertFalse(PrinterConditionEvaluator.conditions(for: value).contains(where: \.isError))
    }

    func testGenuineShutdownIsAnError() throws {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(
                klippy: .shutdown,
                message: "Lost communication with MCU 'mcu'"
            )
        )
        let condition = try XCTUnwrap(conditions.first)
        XCTAssertTrue(condition.isError)
        XCTAssertEqual(condition.cause, .klippyShutdown)
        XCTAssertEqual(condition.rawMessage, "Lost communication with MCU 'mcu'")
    }

    /// An MCU or config problem is not cleared by restarting, so it is graded
    /// apart from a plain shutdown and offers a different remedy.
    func testMCUAndConfigProblemsAreGradedAsConfiguration() {
        let mcu = PrinterConditionEvaluator.conditions(
            for: input(klippy: .shutdown, message: "MCU 'mcu' shutdown: Timer too close")
        )
        XCTAssertEqual(mcu.first?.severity, .configurationError)

        let config = PrinterConditionEvaluator.conditions(
            for: input(klippy: .error, message: "Option 'foo' is not valid in section 'extruder'")
        )
        XCTAssertEqual(config.first?.severity, .configurationError)
        XCTAssertEqual(config.first?.remedy, .openConfig)
    }

    func testThermalShutdownDuringAPrintIsCritical() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(
                klippy: .shutdown,
                message: "Heater extruder not heating at expected rate",
                print: .printing,
                printing: true
            )
        )
        XCTAssertEqual(conditions.first?.severity, .critical)
    }

    func testKlipperDisconnectedIsRecoverable() {
        let conditions = PrinterConditionEvaluator.conditions(for: input(klippy: .disconnected))
        XCTAssertEqual(conditions.first?.cause, .klippyDisconnected)
        XCTAssertEqual(conditions.first?.remedy, .restartKlipper)
    }

    // MARK: - No fabricated diagnoses

    /// A message the classifier does not recognise is shown as needing review,
    /// with Klipper's exact words - not as an invented diagnosis.
    func testUnrecognisedMessageIsNotDiagnosed() throws {
        let message = "Something entirely unfamiliar happened"
        let conditions = PrinterConditionEvaluator.conditions(for: input(message: message))
        let condition = try XCTUnwrap(conditions.first)
        XCTAssertEqual(condition.cause, .unknownMessage)
        XCTAssertEqual(condition.titleKey, "condition.unknown.title")
        XCTAssertEqual(condition.rawMessage, message)
        XCTAssertEqual(condition.severity, .warning, "unknown is not the same as broken")
    }

    // MARK: - Homing state comes from objects, not strings

    /// The homing state is read from `toolhead.homed_axes`. A message claiming
    /// otherwise must not override it.
    func testHomingStateIgnoresContradictoryMessages() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(message: "Must home axis first", homed: "xyz")
        )
        XCTAssertFalse(
            conditions.contains { $0.cause == .notHomed },
            "homed_axes says xyz, so the message is stale"
        )
    }

    /// A printer with no Z configured must not be told to home Z.
    func testOnlyConfiguredAxesAreChecked() {
        let missing = PrinterConditionEvaluator.missingAxes(homed: "xy", configured: ["x", "y"])
        XCTAssertTrue(missing.isEmpty)

        let conditions = PrinterConditionEvaluator.conditions(
            for: input(homed: "xy", axes: ["x", "y"])
        )
        XCTAssertTrue(conditions.isEmpty)
    }

    func testMissingAxesIsCaseInsensitive() {
        XCTAssertEqual(
            PrinterConditionEvaluator.missingAxes(homed: "XY", configured: ["x", "y", "z"]),
            ["z"]
        )
    }

    // MARK: - Ordering and grouping

    func testWorstConditionSortsFirst() {
        let conditions = PrinterConditionEvaluator.deduplicate([
            PrinterCondition(
                cause: .printPaused, severity: .informational, titleKey: "printer.state.paused",
                bodyKey: nil, rawMessage: nil, remedy: .none, axes: ""
            ),
            PrinterCondition(
                cause: .klippyShutdown, severity: .critical, titleKey: "condition.shutdown.title",
                bodyKey: nil, rawMessage: nil, remedy: .firmwareRestart, axes: ""
            )
        ])
        XCTAssertEqual(conditions.first?.cause, .klippyShutdown)
    }

    func testDeduplicationKeepsTheMoreSevereOfTheSameCause() {
        let conditions = PrinterConditionEvaluator.deduplicate([
            PrinterCondition(
                cause: .klippyShutdown, severity: .recoverableError, titleKey: "condition.shutdown.title",
                bodyKey: nil, rawMessage: nil, remedy: .firmwareRestart, axes: ""
            ),
            PrinterCondition(
                cause: .klippyShutdown, severity: .critical, titleKey: "condition.shutdown.title",
                bodyKey: nil, rawMessage: nil, remedy: .firmwareRestart, axes: ""
            )
        ])
        XCTAssertEqual(conditions.count, 1)
        XCTAssertEqual(conditions.first?.severity, .critical)
    }

    func testSeverityOrdering() {
        XCTAssertLessThan(PrinterCondition.Severity.actionRequired, .recoverableError)
        XCTAssertLessThan(PrinterCondition.Severity.warning, .critical)
        XCTAssertFalse(PrinterCondition.Severity.actionRequired.isError)
        XCTAssertFalse(PrinterCondition.Severity.informational.isError)
        XCTAssertTrue(PrinterCondition.Severity.recoverableError.isError)
        XCTAssertTrue(PrinterCondition.Severity.critical.isError)
    }

    // MARK: - Localisation

    func testEveryConditionKeyIsLocalized() throws {
        let keys = [
            "condition.not_homed.title", "condition.not_homed.body",
            "condition.starting.title", "condition.starting.body",
            "condition.shutdown.title", "condition.shutdown.body",
            "condition.error.title", "condition.error.body",
            "condition.config_error.title", "condition.config_error.body",
            "condition.disconnected.title", "condition.disconnected.body",
            "condition.unknown.title", "condition.technical_details",
            "condition.home_first.title", "condition.home.not_ready",
            "condition.severity.info", "condition.severity.action",
            "condition.severity.warning", "condition.severity.recoverable",
            "condition.severity.configuration", "condition.severity.critical"
        ]
        for language in ["en", "ar"] {
            guard let path = Bundle(for: PrinterConditionTests.self)
                    .path(forResource: language, ofType: "lproj")
                    ?? Bundle.main.path(forResource: language, ofType: "lproj"),
                  let table = NSDictionary(contentsOfFile: path + "/Localizable.strings")
                    as? [String: String]
            else { throw XCTSkip("Localizable.strings not in the test bundle") }

            for key in keys {
                XCTAssertNotNil(table[key], "\(key) missing from \(language).lproj")
            }
        }
    }
    // MARK: - A print that stopped by itself

    /// The reported symptom: "I press print and nothing happens."
    ///
    /// Moonraker accepts the start, Klipper reads the first line, finds a
    /// macro that is not defined, and aborts. Klipper itself stays **ready**,
    /// so no Klippy condition fires - and the reason lives in
    /// print_stats.message, which the app stored and never showed.
    func testAFailedPrintReportsKlippersOwnReason() throws {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(
                klippy: .ready,
                print: .error,
                printMessage: "Unknown command: PRINT_START"
            )
        )
        let condition = try XCTUnwrap(conditions.first { $0.cause == .printFailed })
        XCTAssertTrue(condition.isError)
        XCTAssertEqual(condition.rawMessage, "Unknown command: PRINT_START")
    }

    /// A failure with no message still has to appear. Silence was the bug.
    func testAFailedPrintWithoutAMessageStillAppears() throws {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(klippy: .ready, print: .error)
        )
        let condition = try XCTUnwrap(conditions.first { $0.cause == .printFailed })
        XCTAssertNil(condition.rawMessage)
        XCTAssertNotNil(condition.bodyKey)
    }

    func testANormalPrintProducesNoFailureCard() {
        let conditions = PrinterConditionEvaluator.conditions(
            for: input(klippy: .ready, print: .printing, printing: true)
        )
        XCTAssertFalse(conditions.contains { $0.cause == .printFailed })
    }
}
