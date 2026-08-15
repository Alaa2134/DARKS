import XCTest
@testable import NeptuneRemote

final class PowerSafetyTests: XCTestCase {

    private func snapshot(
        state: PrinterState = .standby,
        nozzle: Double = 24,
        bed: Double = 23,
        online: Bool = true,
        nozzleTarget: Double = 0,
        bedTarget: Double = 0
    ) -> PrinterSnapshot {
        var value = PrinterSnapshot()
        value.isOnline = online
        value.state = state
        value.nozzleActual = nozzle
        value.bedActual = bed
        value.nozzleTarget = nozzleTarget
        value.bedTarget = bedTarget
        return value
    }

    private let defaults = PowerSafety.Thresholds()

    func testDefaultThresholdsMatchTheSpecification() {
        XCTAssertEqual(defaults.maxNozzleTemp, 50)
        XCTAssertEqual(defaults.maxBedTemp, 45)
        XCTAssertTrue(defaults.blockWhilePrinting)
    }

    func testColdIdlePrinterIsSafe() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(), thresholds: defaults)
        XCTAssertTrue(report.isSafe)
        XCTAssertTrue(report.blockers.isEmpty)
    }

    func testHotNozzleBlocks() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(nozzle: 180), thresholds: defaults)
        XCTAssertFalse(report.isSafe)
        XCTAssertEqual(report.blockers.count, 1)
    }

    func testExactlyAtThresholdBlocks() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(nozzle: 50), thresholds: defaults)
        XCTAssertFalse(report.isSafe)
    }

    func testJustBelowThresholdIsSafe() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(nozzle: 49.9, bed: 44.9), thresholds: defaults)
        XCTAssertTrue(report.isSafe)
    }

    func testHotBedBlocks() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(bed: 60), thresholds: defaults)
        XCTAssertFalse(report.isSafe)
    }

    func testPrintingBlocks() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(state: .printing), thresholds: defaults)
        XCTAssertFalse(report.isSafe)
    }

    func testPausedBlocks() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(state: .paused), thresholds: defaults)
        XCTAssertFalse(report.isSafe)
    }

    func testMultipleBlockersAreAllReported() {
        let report = PowerSafety.evaluatePowerOff(
            snapshot: snapshot(state: .printing, nozzle: 210, bed: 60),
            thresholds: defaults
        )
        XCTAssertEqual(report.blockers.count, 3)
    }

    func testCustomThresholdsAreRespected() {
        let lenient = PowerSafety.Thresholds(maxNozzleTemp: 200, maxBedTemp: 100)
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(nozzle: 180, bed: 60), thresholds: lenient)
        XCTAssertTrue(report.isSafe)
    }

    func testOfflinePrinterWarnsButDoesNotBlock() {
        let report = PowerSafety.evaluatePowerOff(snapshot: snapshot(online: false), thresholds: defaults)
        XCTAssertTrue(report.isSafe)
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testActiveTargetsProduceWarning() {
        let report = PowerSafety.evaluatePowerOff(
            snapshot: snapshot(nozzleTarget: 200),
            thresholds: defaults
        )
        XCTAssertTrue(report.isSafe)
        XCTAssertFalse(report.warnings.isEmpty)
    }

    func testChecklistHasFourItems() {
        XCTAssertEqual(PowerSafety.printChecklistKeys.count, 4)
        XCTAssertTrue(PowerSafety.printChecklistKeys.contains("checklist.bed_clear"))
        XCTAssertTrue(PowerSafety.printChecklistKeys.contains("checklist.filament_loaded"))
    }

    func testColdExtrusionGuard() {
        var value = PrinterSnapshot()
        value.nozzleActual = 165
        XCTAssertFalse(value.canExtrude(minimumTemperature: 170))
        value.nozzleActual = 170
        XCTAssertTrue(value.canExtrude(minimumTemperature: 170))
    }

    func testHomedAxisHelpers() {
        var value = PrinterSnapshot()
        value.homedAxes = "xy"
        XCTAssertTrue(value.isHomed("x"))
        XCTAssertTrue(value.isHomed("Y"))
        XCTAssertFalse(value.isHomed("z"))
        XCTAssertFalse(value.hasHomedAll)
        value.homedAxes = "xyz"
        XCTAssertTrue(value.hasHomedAll)
    }
}
