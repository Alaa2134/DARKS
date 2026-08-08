"""Screw-tilt parsing and the "Fix My Printer" diagnostics engine.

The recurring assertion: an observation the engine could not make is reported as
*unknown*, never as a pass.
"""

from __future__ import annotations

import pytest

from app.doctor.engine import (
    DiagnosticInput,
    DiagnosticsEngine,
    Health,
    Severity,
    Subsystem,
)
from app.klipper.model import parse_config
from app.klipper.screws import parse_screws_tilt, position_key
from app.klipper.validator import NEPTUNE_3_PLUS

# --------------------------------------------------------------------------- #
# SCREWS_TILT_CALCULATE
# --------------------------------------------------------------------------- #

SCREWS_OUTPUT = """
01:23:45 Bed tilt calculated from probe points
screw (front left) : x=30.0, y=30.0, z=2.10000 : base
front right : x=270.0, y=30.0, z=2.32500 : adjust CW 00:21
center left : x=30.0, y=160.0, z=2.05000 : adjust CCW 00:01
center right : x=270.0, y=160.0, z=2.20000 : adjust CW 00:12
back left : x=30.0, y=290.0, z=2.08000 : adjust CCW 00:02
back right : x=270.0, y=290.0, z=1.80000 : adjust CCW 01:12
"""


def test_a_clock_reading_becomes_a_fraction_of_a_turn():
    """Klipper's clock is one full turn per hour: 00:21 is 21/60 of a turn."""
    result = parse_screws_tilt(SCREWS_OUTPUT)
    front_right = next(s for s in result.screws if s.name == "front right")
    assert front_right.turns == pytest.approx(0.35, abs=0.001)
    assert "0.35 of a turn" in front_right.instruction
    assert front_right.direction == "CW"


def test_hours_are_whole_turns():
    result = parse_screws_tilt(SCREWS_OUTPUT)
    back_right = next(s for s in result.screws if s.name == "back right")
    assert back_right.turns == pytest.approx(1.2, abs=0.001)
    assert back_right.severity == "high"


def test_the_base_screw_is_identified_and_never_asked_to_turn():
    result = parse_screws_tilt(SCREWS_OUTPUT)
    base = result.base
    assert base is not None
    assert base.name == "front left"
    assert base.turns == 0.0
    assert "do not turn" in base.instruction.lower()


def test_all_six_neptune_positions_are_mapped():
    result = parse_screws_tilt(SCREWS_OUTPUT)
    keys = {s.as_dict()["position_key"] for s in result.screws}
    assert keys == {
        "left_front", "left_middle", "left_rear",
        "right_front", "right_middle", "right_rear",
    }


def test_a_tiny_adjustment_is_treated_as_good_enough():
    result = parse_screws_tilt(SCREWS_OUTPUT)
    center_left = next(s for s in result.screws if s.name == "center left")
    assert center_left.turns == pytest.approx(1 / 60, abs=0.001)
    assert center_left.adjusted is False
    assert center_left.severity == "ok"


def test_direction_is_signed_for_the_ui_arrow():
    result = parse_screws_tilt(SCREWS_OUTPUT)
    assert next(s for s in result.screws if s.name == "front right").signed_turns > 0
    assert next(s for s in result.screws if s.name == "back right").signed_turns < 0


def test_verdict_and_spread():
    result = parse_screws_tilt(SCREWS_OUTPUT)
    assert result.verdict == "poor"          # worst is 1.2 turns
    assert result.level is False
    assert result.z_spread == pytest.approx(0.525, abs=0.001)


def test_a_level_bed_reports_level():
    output = """
screw front left : x=30.0, y=30.0, z=2.10000 : base
front right : x=270.0, y=30.0, z=2.10100 : adjust CW 00:00
back left : x=30.0, y=290.0, z=2.09900 : adjust CCW 00:01
"""
    result = parse_screws_tilt(output)
    assert result.level is True
    assert result.verdict == "level"
    assert "within tolerance" in result.summary


def test_unparseable_output_says_so_rather_than_claiming_level():
    result = parse_screws_tilt("Unknown command: SCREWS_TILT_CALCULATE")
    assert result.parse_failed is True
    assert result.level is False
    assert result.verdict == "unknown"


def test_empty_output_is_not_a_pass():
    result = parse_screws_tilt("")
    assert result.parse_failed is True
    assert result.level is False


def test_an_unrecognised_screw_label_falls_back_to_klippers_own_text():
    assert position_key("some custom name") == ""
    result = parse_screws_tilt("my weird screw : x=1.0, y=2.0, z=3.0 : adjust CW 00:30")
    assert result.screws[0].name == "my weird screw"
    assert result.screws[0].turns == pytest.approx(0.5)


def test_the_result_serialises_for_the_api():
    payload = parse_screws_tilt(SCREWS_OUTPUT).as_dict()
    assert payload["verdict"] == "poor"
    assert len(payload["screws"]) == 6
    assert payload["screws"][0]["is_base"] is True


# --------------------------------------------------------------------------- #
# Diagnostics engine
# --------------------------------------------------------------------------- #

HEALTHY_CFG = """
[printer]
kinematics: cartesian
max_velocity: 300
max_accel: 3000

[stepper_x]
position_min: -3
position_max: 330

[stepper_y]
position_min: -8
position_max: 330

[stepper_z]
position_min: 0
position_max: 410

[probe]
z_offset: 2.15

[safe_z_home]
home_xy_position: 160, 160

[bed_mesh]
mesh_min: 30, 30

[screws_tilt_adjust]
screw1: 30, 30

#*# <---------------------- SAVE_CONFIG
#*#
#*# [probe]
#*# z_offset = 2.145
#*#
#*# [bed_mesh default]
#*# version = 1
"""


@pytest.fixture()
def engine():
    return DiagnosticsEngine(profile=NEPTUNE_3_PLUS)


def healthy_input(**overrides) -> DiagnosticInput:
    data = DiagnosticInput(
        moonraker_reachable=True,
        klippy_state="ready",
        config=parse_config(HEALTHY_CFG),
        homed_axes="xyz",
        probe_triggered=False,
        mcu_awake=True,
        mcu_load=0.3,
        heaters={
            "extruder": {"temperature": 24.0, "target": 0.0},
            "heater_bed": {"temperature": 23.0, "target": 0.0},
        },
        fans={"fan": 0.0},
        disk_free_gb=40.0,
    )
    for key, value in overrides.items():
        setattr(data, key, value)
    return data


def card(report, subsystem: Subsystem):
    return next(c for c in report.cards if c.subsystem is subsystem)


def codes(report):
    return {f.code for f in report.findings}


def test_a_healthy_printer_reports_green_and_is_safe_to_print(engine):
    report = engine.run(healthy_input())
    assert report.overall is Health.GREEN
    assert report.safe_to_print is True
    assert report.critical == []


def test_an_unreachable_moonraker_stops_the_scan_cleanly(engine):
    report = engine.run(DiagnosticInput(moonraker_reachable=False))
    assert report.safe_to_print is False
    assert "moonraker_unreachable" in codes(report)
    # It does not flood the report with "unknown" for everything downstream.
    assert len(report.cards) == 1


def test_a_triggered_probe_is_critical_and_blocks_printing(engine):
    report = engine.run(healthy_input(probe_triggered=True))
    assert report.safe_to_print is False
    assert "probe_triggered_at_rest" in codes(report)
    finding = next(f for f in report.findings if f.code == "probe_triggered_at_rest")
    assert finding.severity is Severity.CRITICAL
    assert finding.manual_steps          # hardware intervention is spelled out
    assert card(report, Subsystem.PROBE).health is Health.RED


def test_an_unread_probe_is_unknown_not_green(engine):
    report = engine.run(healthy_input(probe_triggered=None))
    assert card(report, Subsystem.PROBE).health is Health.UNKNOWN
    # Unknown is not an alarm either - it does not block printing on its own.
    assert report.safe_to_print is True


def test_klipper_in_shutdown_is_critical(engine):
    report = engine.run(
        healthy_input(klippy_state="shutdown", klippy_message="Lost communication with MCU 'mcu'")
    )
    assert report.safe_to_print is False
    finding = next(f for f in report.findings if f.code == "klipper_not_ready")
    assert finding.auto_fix == "firmware_restart"


def test_a_disconnected_mcu_is_critical(engine):
    report = engine.run(healthy_input(mcu_awake=False))
    assert "mcu_disconnected" in codes(report)
    assert card(report, Subsystem.MCU).health is Health.RED


def test_high_mcu_load_warns_before_it_shuts_down_mid_print(engine):
    report = engine.run(healthy_input(mcu_load=0.95))
    assert "mcu_load_high" in codes(report)
    assert card(report, Subsystem.MCU).health is Health.YELLOW


def test_a_missing_z_offset_is_critical_and_offers_the_wizard(engine):
    config = parse_config(HEALTHY_CFG.replace("z_offset: 2.15", "").split("#*#")[0])
    report = engine.run(healthy_input(config=config))
    finding = next(f for f in report.findings if f.code == "z_offset_missing")
    assert finding.severity is Severity.CRITICAL
    assert finding.auto_fix == "z_offset_wizard"
    assert report.safe_to_print is False


def test_a_missing_bed_mesh_warns_and_offers_the_wizard(engine):
    config = parse_config(HEALTHY_CFG.split("#*#")[0])
    report = engine.run(healthy_input(config=config))
    finding = next(f for f in report.findings if f.code == "bed_mesh_missing")
    assert finding.auto_fix == "bed_mesh_wizard"
    # A missing mesh is a warning, not a block.
    assert report.safe_to_print is True


def test_a_saved_mesh_and_saved_offset_read_from_the_save_config_block(engine):
    report = engine.run(healthy_input())
    assert card(report, Subsystem.BED_MESH).health is Health.GREEN
    assert "2.145" in card(report, Subsystem.Z_OFFSET).status


def test_geometry_from_a_different_printer_is_flagged(engine):
    config = parse_config(HEALTHY_CFG.replace("position_max: 330", "position_max: 220"))
    report = engine.run(healthy_input(config=config))
    assert "geometry_mismatch" in codes(report)


def test_acceleration_above_the_frame_recommendation_is_flagged(engine):
    config = parse_config(HEALTHY_CFG.replace("max_accel: 3000", "max_accel: 6000"))
    report = engine.run(healthy_input(config=config))
    finding = next(f for f in report.findings if f.code == "accel_above_recommended")
    assert "moving bed" in finding.cause.lower()


def test_an_implausible_thermistor_reading_is_critical(engine):
    report = engine.run(
        healthy_input(heaters={"extruder": {"temperature": -273.0, "target": 0.0}})
    )
    assert "thermistor_implausible" in codes(report)
    assert card(report, Subsystem.HOTEND).health is Health.RED


def test_a_full_disk_is_critical(engine):
    report = engine.run(healthy_input(disk_free_gb=0.3))
    assert "disk_almost_full" in codes(report)
    assert report.safe_to_print is False


def test_config_drift_from_the_known_good_version_is_reported(engine):
    report = engine.run(
        healthy_input(config_sha="aaa", known_good_sha="bbb", known_good_label="Golden Config")
    )
    finding = next(f for f in report.findings if f.code == "config_changed")
    assert "Golden Config" in finding.title
    assert finding.auto_fix == "config_diff"


def test_matching_the_known_good_config_produces_no_drift_finding(engine):
    report = engine.run(healthy_input(config_sha="aaa", known_good_sha="aaa"))
    assert "config_changed" not in codes(report)


def test_an_unreadable_config_is_unknown_rather_than_valid(engine):
    report = engine.run(healthy_input(config=None, config_error="404 from Moonraker"))
    assert card(report, Subsystem.CONFIG).health is Health.UNKNOWN
    assert "config_unreadable" in codes(report)


def test_a_configured_accelerometer_that_does_not_answer_is_reported(engine):
    config = parse_config(HEALTHY_CFG.split("#*#")[0] + "\n[adxl345]\ncs_pin: rpi:None\n")
    report = engine.run(healthy_input(config=config, accelerometer_present=False))
    assert "accelerometer_not_responding" in codes(report)


def test_no_accelerometer_reads_as_not_installed_not_broken(engine):
    report = engine.run(healthy_input())
    assert card(report, Subsystem.ACCELEROMETER).status == "Not installed"
    assert card(report, Subsystem.ACCELEROMETER).health is Health.UNKNOWN


def test_klipper_log_lines_are_translated_into_findings(engine):
    report = engine.run(
        healthy_input(
            klipper_log_tail=[
                "Starting Klippy...",
                "Probe triggered prior to movement",
            ]
        )
    )
    assert any(f.code.startswith("log_probe_triggered") for f in report.findings)


def test_unhomed_axes_are_information_with_a_one_tap_fix(engine):
    report = engine.run(healthy_input(homed_axes=""))
    finding = next(f for f in report.findings if f.code == "not_homed")
    assert finding.severity is Severity.INFO
    assert finding.auto_fix == "safe_home"
    assert report.safe_to_print is True


def test_the_report_serialises_for_the_api(engine):
    payload = engine.run(healthy_input()).as_dict()
    assert payload["overall"] == "green"
    assert payload["safe_to_print"] is True
    assert any(c["subsystem"] == "probe" for c in payload["cards"])


def test_every_subsystem_gets_a_card_on_a_healthy_printer(engine):
    report = engine.run(healthy_input())
    covered = {c.subsystem for c in report.cards}
    for required in (
        Subsystem.MOONRAKER, Subsystem.KLIPPER, Subsystem.MCU, Subsystem.CONFIG,
        Subsystem.X_AXIS, Subsystem.Y_AXIS, Subsystem.Z_AXIS, Subsystem.PROBE,
        Subsystem.BED, Subsystem.HOTEND, Subsystem.PART_COOLING,
        Subsystem.FILAMENT_SENSOR, Subsystem.BED_MESH, Subsystem.Z_OFFSET,
        Subsystem.MOTION_LIMITS, Subsystem.ACCELEROMETER, Subsystem.CAMERA,
        Subsystem.HOST, Subsystem.STORAGE,
    ):
        assert required in covered, f"missing health card for {required.value}"
