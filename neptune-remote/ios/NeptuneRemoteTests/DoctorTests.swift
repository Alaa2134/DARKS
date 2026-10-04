import SwiftUI
import XCTest
@testable import NeptuneRemote

/// Decoding and presentation for Fix My Printer, the calibration wizards and
/// the G-code safety layer.
///
/// The recurring assertion: the app shows what the backend actually said, and
/// never upgrades an unknown or a warning into a pass.
final class DoctorTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Findings and health

    func testAFindingDecodesWithItsFixAndManualSteps() throws {
        let json = """
        {"code": "probe_triggered_at_rest", "subsystem": "probe", "severity": "critical",
         "title": "The Z probe is already triggered before any movement.",
         "cause": "The probe is shorted or stuck down.",
         "recommendation": "Fix the probe before homing Z.",
         "auto_fix": null, "auto_fix_label": "",
         "manual_steps": ["Check nothing is pressing on the probe.", "Check the connector."],
         "detail": ""}
        """
        let finding = try decoder.decode(DoctorFinding.self, from: Data(json.utf8))
        XCTAssertTrue(finding.isCritical)
        XCTAssertTrue(finding.needsHands)
        XCTAssertEqual(finding.manualSteps.count, 2)
        XCTAssertNil(finding.autoFix)
    }

    func testAnUnknownHealthCardIsNotGreen() throws {
        let json = """
        {"subsystem": "accelerometer", "health": "unknown", "status": "Not installed",
         "detail": "", "recommendation": "", "checked_at": 0}
        """
        let card = try decoder.decode(HealthCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.symbol, "questionmark.circle")
        XCTAssertNotEqual(card.color, Theme.printing)
        XCTAssertEqual(card.nameKey, "subsystem.accelerometer")
    }

    func testEverySubsystemHasAnIcon() {
        for subsystem in DoctorCatalog.subsystemIcons.keys {
            XCTAssertFalse(DoctorCatalog.icon(forSubsystem: subsystem).isEmpty)
        }
        // And an unknown one still gets something drawable.
        XCTAssertFalse(DoctorCatalog.icon(forSubsystem: "brand-new-thing").isEmpty)
    }

    func testEveryWorkflowHasAnIcon() {
        for kind in ["safe_home", "z_offset", "screws_tilt", "bed_mesh",
                     "full_bed_calibration", "axis_health", "input_shaper"] {
            XCTAssertFalse(DoctorCatalog.icon(forWorkflow: kind).isEmpty, kind)
        }
    }

    // MARK: - Command decisions

    func testABlockedDecisionIsNotAllowed() throws {
        let json = """
        {"original": "G28 Z", "command": "G28 Z", "kind": "homing", "severity": "blocked",
         "allowed": false, "modified": false, "requires_backup": false, "adjustments": [],
         "issues": [{"code": "probe_already_triggered", "severity": "blocked",
                     "message": "The Z probe is already triggered.", "detail": "", "remedy": ""}]}
        """
        let decision = try decoder.decode(CommandDecision.self, from: Data(json.utf8))
        XCTAssertTrue(decision.blocked)
        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.issues.count, 1)
    }

    func testAClampedDecisionReportsTheAdjustment() throws {
        let json = """
        {"original": "G1 X400", "command": "G1 X330 F3000", "kind": "movement",
         "severity": "warning", "allowed": true, "modified": true, "requires_backup": false,
         "adjustments": ["X400 clamped to 330"], "issues": []}
        """
        let decision = try decoder.decode(CommandDecision.self, from: Data(json.utf8))
        XCTAssertTrue(decision.allowed)
        XCTAssertTrue(decision.modified)
        XCTAssertEqual(decision.adjustments.first, "X400 clamped to 330")
    }

    // MARK: - Screws

    private func screwsReport() throws -> ScrewsTiltReport {
        let json = """
        {"verdict": "adjust", "level": false, "summary": "2 screws need adjusting.",
         "max_turns": 1.2, "z_spread": 0.525, "parse_failed": false,
         "screws": [
           {"name": "front left", "position_key": "left_front", "x": 30, "y": 30, "z": 2.1,
            "is_base": true, "direction": "", "clock": "00:00", "turns": 0.0,
            "signed_turns": 0.0, "adjusted": false, "severity": "ok",
            "instruction": "Reference screw - do not turn this one."},
           {"name": "front right", "position_key": "right_front", "x": 270, "y": 30, "z": 2.325,
            "is_base": false, "direction": "CW", "clock": "00:21", "turns": 0.35,
            "signed_turns": 0.35, "adjusted": true, "severity": "medium",
            "instruction": "Turn clockwise about 0.35 of a turn (00:21)."},
           {"name": "back right", "position_key": "right_rear", "x": 270, "y": 290, "z": 1.8,
            "is_base": false, "direction": "CCW", "clock": "01:12", "turns": 1.2,
            "signed_turns": -1.2, "adjusted": true, "severity": "high",
            "instruction": "Turn counter-clockwise about 1.20 of a turn (01:12)."}
         ]}
        """
        return try decoder.decode(ScrewsTiltReport.self, from: Data(json.utf8))
    }

    func testTheClockReadingSurvivesAsAFractionOfATurn() throws {
        let report = try screwsReport()
        let frontRight = try XCTUnwrap(report.screw(at: "right_front"))
        XCTAssertEqual(frontRight.turns, 0.35, accuracy: 0.001)
        XCTAssertEqual(frontRight.clock, "00:21")
        XCTAssertTrue(frontRight.instruction.contains("0.35"))
    }

    func testArrowDirectionFollowsTheSignedTurns() throws {
        let report = try screwsReport()
        let clockwise = try XCTUnwrap(report.screw(at: "right_front"))
        let counter = try XCTUnwrap(report.screw(at: "right_rear"))
        XCTAssertTrue(clockwise.isClockwise)
        XCTAssertGreaterThan(clockwise.arrowDegrees, 0)
        XCTAssertFalse(counter.isClockwise)
        XCTAssertLessThan(counter.arrowDegrees, 0)
    }

    func testTheArrowSweepIsCappedAtOneFullTurn() throws {
        let report = try screwsReport()
        let big = try XCTUnwrap(report.screw(at: "right_rear"))   // 1.2 turns
        XCTAssertEqual(abs(big.arrowDegrees), 360, accuracy: 0.001)
    }

    func testTheBaseScrewIsNeverAskedToTurn() throws {
        let report = try screwsReport()
        let base = try XCTUnwrap(report.screw(at: "left_front"))
        XCTAssertTrue(base.isBase)
        XCTAssertFalse(base.adjusted)
    }

    func testMissingScrewPositionsResolveToNil() throws {
        let report = try screwsReport()
        // The layout has six slots; this report only filled three.
        XCTAssertNil(report.screw(at: "left_middle"))
    }

    func testTheBedLayoutCoversAllSixNeptunePositions() {
        let slots = Set(DoctorCatalog.bedLayout.flatMap { $0 })
        XCTAssertEqual(slots, Set(DoctorCatalog.screwLabelKeys.keys))
        XCTAssertEqual(slots.count, 6)
    }

    // MARK: - Workflows

    func testAWorkflowDecodesWithItsStepsAndActiveIndex() throws {
        let json = """
        {"id": "abc", "kind": "screws_tilt", "title": "Bed screw adjustment",
         "state": "waiting_for_user", "message": "Turn the screws.", "current": 3,
         "progress": 0.75, "finished": false, "data": {},
         "steps": [
           {"id": "probe_check", "title": "Check the probe", "description": "",
            "commands": ["QUERY_PROBE"], "manual": false, "state": "done",
            "message": "", "output": "", "started_at": null, "finished_at": null, "decisions": []},
           {"id": "home", "title": "Home", "description": "", "commands": ["G28"],
            "manual": false, "state": "done", "message": "", "output": "",
            "started_at": null, "finished_at": null, "decisions": []},
           {"id": "measure", "title": "Measure", "description": "",
            "commands": ["SCREWS_TILT_CALCULATE"], "manual": false, "state": "done",
            "message": "", "output": "", "started_at": null, "finished_at": null, "decisions": []},
           {"id": "adjust", "title": "Turn the screws", "description": "",
            "commands": [], "manual": true, "state": "waiting_for_user",
            "message": "", "output": "", "started_at": null, "finished_at": null, "decisions": []}
         ]}
        """
        let run = try decoder.decode(WorkflowRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.activeStep?.id, "adjust")
        XCTAssertTrue(run.needsUser)
        XCTAssertFalse(run.failed)
        XCTAssertTrue(run.steps[0].isDone)
        XCTAssertTrue(run.steps[3].manual)
    }

    func testAFailedWorkflowIsNotTreatedAsFinishedSuccessfully() throws {
        let json = """
        {"id": "a", "kind": "safe_home", "title": "Home safely", "state": "failed",
         "message": "The Z probe is already triggered.", "current": 2, "progress": 0.66,
         "finished": true, "data": {}, "steps": []}
        """
        let run = try decoder.decode(WorkflowRun.self, from: Data(json.utf8))
        XCTAssertTrue(run.failed)
        XCTAssertEqual(run.color, Theme.danger)
    }

    func testWorkflowDataToleratesKeysItDoesNotKnow() throws {
        // The backend adds result keys per workflow; an unfamiliar one must not
        // break the whole response.
        let json = """
        {"id": "a", "kind": "bed_mesh", "title": "Bed mesh", "state": "running",
         "message": "", "current": 0, "progress": 0, "finished": false, "steps": [],
         "data": {"something_new": 42, "probe_triggered": false}}
        """
        let run = try decoder.decode(WorkflowRun.self, from: Data(json.utf8))
        XCTAssertEqual(run.data.probeTriggered, false)
        XCTAssertNil(run.data.screws)
    }

    // MARK: - G-code

    private func gcodeReport(
        verdict: String = "safe",
        profileStatus: String = "golden",
        slicer: String = "PrusaSlicer"
    ) throws -> GCodeReport {
        let json = """
        {"verdict": "\(verdict)", "blocked": \(verdict == "blocked"),
         "error_count": 0, "warning_count": 0, "issues": [],
         "slicer": "\(slicer)", "slicer_version": "2.8.1",
         "profile_name": "Neptune3Plus 0.20 Standard", "filament": "PLA",
         "verified_profile": \(profileStatus == "golden"), "profile_status": "\(profileStatus)",
         "bounds": {"min_x": 10, "max_x": 300, "min_y": 12, "max_y": 280,
                    "min_z": 0.2, "max_z": 40},
         "estimated_seconds": 5400, "layer_height": 0.2, "first_layer_height": 0.25,
         "nozzle_diameter": 0.4, "layer_count": 200,
         "max_requested_feedrate": 9000, "max_requested_accel": 3000,
         "positioning_absolute": true, "extrusion_relative": true, "has_home": true,
         "sets_hotend_temp": true, "sets_bed_temp": true,
         "unsupported": [], "lines_scanned": 1000}
        """
        return try decoder.decode(GCodeReport.self, from: Data(json.utf8))
    }

    func testAGoldenReportIsVerified() throws {
        let report = try gcodeReport()
        XCTAssertTrue(report.isVerified)
        XCTAssertEqual(report.profileStatusKey, "gcode.profile.golden")
        XCTAssertEqual(report.color, Theme.printing)
    }

    func testAnUnverifiedReportIsNotShownAsVerified() throws {
        let report = try gcodeReport(verdict: "warning", profileStatus: "unverified", slicer: "Cura")
        XCTAssertFalse(report.isVerified)
        XCTAssertEqual(report.profileStatusKey, "gcode.profile.unverified")
        XCTAssertEqual(report.color, Theme.paused)
    }

    func testBoundsRenderReadably() throws {
        let report = try gcodeReport()
        XCTAssertTrue(report.bounds.description.contains("X 10.0…300.0"))
    }

    func testMissingBoundsDoNotRenderAsZero() {
        let bounds = GCodeBounds(minX: nil, maxX: nil, minY: nil, maxY: nil, minZ: nil, maxZ: nil)
        XCTAssertEqual(bounds.description, "--")
    }

    func testAnUnsupportedCommandDecodesWithItsExplanation() throws {
        let json = """
        {"command": "M413", "line": 42,
         "reason": "Marlin power-loss recovery. Klipper does not implement it."}
        """
        let command = try decoder.decode(UnsupportedCommand.self, from: Data(json.utf8))
        XCTAssertEqual(command.command, "M413")
        XCTAssertTrue(command.reason.contains("Klipper"))
    }

    // MARK: - Preflight

    func testThePreflightBannerCarriesEveryRowFromTheBrief() throws {
        let json = """
        {"verdict": "ready", "ready": true, "strict": false, "summary": "Ready to print.",
         "failure_count": 0, "warning_count": 0, "checks": [], "gcode": null,
         "banner": {"slicer": "PrusaSlicer", "printer_profile": "Neptune3Plus 0.20 Standard",
                    "profile_status": "GOLDEN", "gcode_validation": "SAFE",
                    "build_volume": "PASSED", "unsupported_commands": "NONE",
                    "motion_limits": "PASSED", "bounds": "X 10…300"}}
        """
        let report = try decoder.decode(PreflightReport.self, from: Data(json.utf8))
        let banner = try XCTUnwrap(report.banner)
        XCTAssertEqual(banner.rows.count, 7)
        XCTAssertEqual(banner.rows.map(\.value).first, "PrusaSlicer")
        XCTAssertTrue(banner.rows.contains { $0.value == "GOLDEN" })
        XCTAssertTrue(report.ready)
    }

    func testABlockedPreflightIsNotReady() throws {
        let json = """
        {"verdict": "blocked", "ready": false, "strict": true, "summary": "X goes off the bed.",
         "failure_count": 1, "warning_count": 0, "gcode": null, "banner": null,
         "checks": [{"id": "gcode_outside_build_volume", "label": "X goes to 400 mm",
                     "passed": false, "severity": "error", "detail": "", "remedy": "Re-slice."}]}
        """
        let report = try decoder.decode(PreflightReport.self, from: Data(json.utf8))
        XCTAssertFalse(report.ready)
        XCTAssertEqual(report.verdictKey, "preflight.verdict.blocked")
        XCTAssertEqual(report.checks.first?.symbol, "xmark.octagon.fill")
        XCTAssertEqual(report.color, Theme.danger)
    }

    // MARK: - Config versions

    func testAGoldenVersionKeepsItsLabelAndProvenPrints() throws {
        let json = """
        {"id": "v1", "created_at": 1700000000, "label": "Golden Config", "reason": "manual",
         "size_bytes": 8000, "sha256": "abc", "golden": true, "proven_prints": 12,
         "last_proven_at": 1700000100, "note": "", "section_count": 30}
        """
        let version = try decoder.decode(ConfigVersion.self, from: Data(json.utf8))
        XCTAssertTrue(version.golden)
        XCTAssertEqual(version.displayName, "Golden Config")
        XCTAssertEqual(version.provenPrints, 12)
        XCTAssertEqual(version.reasonKey, "config.reason.manual")
    }

    func testAnUnnamedVersionFallsBackToItsDate() throws {
        let json = """
        {"id": "v2", "created_at": 1700000000, "label": "", "reason": "pre_save_config",
         "size_bytes": 8000, "sha256": "def", "golden": false, "proven_prints": 0,
         "last_proven_at": null, "note": "", "section_count": 30}
        """
        let version = try decoder.decode(ConfigVersion.self, from: Data(json.utf8))
        XCTAssertFalse(version.displayName.isEmpty)
        XCTAssertNotEqual(version.displayName, "")
    }

    func testADiffCountsOnlyRealChanges() throws {
        let json = """
        {"added_sections": ["adxl345"], "removed_sections": [],
         "changed_sections": [{"section": "printer",
                               "options": [{"option": "max_accel", "before": "3000", "after": "6000"}]}],
         "autosave_changes": [], "identical": false}
        """
        let diff = try decoder.decode(ConfigDiff.self, from: Data(json.utf8))
        XCTAssertEqual(diff.changeCount, 2)
        XCTAssertFalse(diff.identical)
        XCTAssertEqual(diff.changedSections.first?.options.first?.after, "6000")
    }

    func testARestorePreviewIsNotARestore() throws {
        let json = """
        {"requires_confirmation": true, "version": null, "diff": null}
        """
        let result = try decoder.decode(ConfigRestoreResult.self, from: Data(json.utf8))
        XCTAssertTrue(result.needsConfirmation)
        XCTAssertFalse(result.didRestore)
    }
}
