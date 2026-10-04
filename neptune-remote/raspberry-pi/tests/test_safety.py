"""The Safety Command Engine.

These are the tests that matter most in this project: every one of them
describes a way the printer could be damaged, and asserts that the engine
refuses rather than assumes.
"""

from __future__ import annotations

import pytest

from app.klipper.model import parse_config
from app.safety.engine import (
    CommandKind,
    PrinterSafetyEngine,
    SafetyBlocked,
    SafetyContext,
    Severity,
    classify,
    parse_axis_words,
    parse_named_params,
)

NEPTUNE_CFG = """
[printer]
kinematics: cartesian
max_velocity: 300
max_accel: 3000
max_z_velocity: 12
square_corner_velocity: 5

[stepper_x]
position_endstop: -3
position_min: -3
position_max: 330
homing_speed: 50

[stepper_y]
position_endstop: -8
position_min: -8
position_max: 330
homing_speed: 50

[stepper_z]
position_min: -3
position_max: 410

[probe]
x_offset: 27.0
y_offset: -20.0
z_offset: 2.15

[safe_z_home]
home_xy_position: 160, 160

[bed_mesh]
mesh_min: 30, 30
mesh_max: 290, 290

[screws_tilt_adjust]
screw1: 30, 30

[extruder]
min_extrude_temp: 170
"""


@pytest.fixture()
def config():
    return parse_config(NEPTUNE_CFG)


@pytest.fixture()
def ready(config):
    return SafetyContext(
        klippy_ready=True,
        klippy_state="ready",
        homed_axes="xyz",
        probe_triggered=False,
        config=config,
    )


@pytest.fixture()
def engine():
    return PrinterSafetyEngine()


# --------------------------------------------------------------------------- #
# Classification
# --------------------------------------------------------------------------- #


@pytest.mark.parametrize(
    "command,kind",
    [
        ("G1 X10", CommandKind.MOVEMENT),
        ("g0 x10", CommandKind.MOVEMENT),
        ("G28", CommandKind.HOMING),
        ("QUERY_PROBE", CommandKind.QUERY),
        ("PROBE_CALIBRATE", CommandKind.PROBE_CALIBRATE),
        ("TESTZ Z=-0.05", CommandKind.TESTZ),
        ("ACCEPT", CommandKind.ACCEPT_ABORT),
        ("SCREWS_TILT_CALCULATE", CommandKind.SCREWS_TILT),
        ("BED_MESH_CALIBRATE", CommandKind.BED_MESH),
        ("SAVE_CONFIG", CommandKind.SAVE_CONFIG),
        ("M112", CommandKind.EMERGENCY),
        ("SHAPER_CALIBRATE", CommandKind.RESONANCE),
        ("SOMETHING_CUSTOM", CommandKind.OTHER),
    ],
)
def test_classification(command, kind):
    assert classify(command) is kind


def test_axis_word_parsing_is_not_fooled_by_macro_names():
    # "MAX_X" must not be read as an X word.
    assert parse_axis_words("SET_THING MAX_X=5") == {}
    assert parse_axis_words("G1 X10 Y-20.5 F3000") == {"X": 10.0, "Y": -20.5, "F": 3000.0}


def test_named_parameter_parsing():
    assert parse_named_params("TESTZ Z=-0.05") == {"Z": -0.05}
    assert parse_named_params("SET_VELOCITY_LIMIT ACCEL=1500 VELOCITY=200") == {
        "ACCEL": 1500.0,
        "VELOCITY": 200.0,
    }


# --------------------------------------------------------------------------- #
# Klipper readiness gates everything
# --------------------------------------------------------------------------- #


def test_nothing_runs_when_klipper_is_not_ready(engine, config):
    context = SafetyContext(klippy_ready=False, klippy_state="shutdown", config=config)
    decision = engine.evaluate("G28", context)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "klippy_not_ready" for i in decision.issues)


def test_emergency_stop_is_never_gated(engine):
    context = SafetyContext(klippy_ready=False, klippy_state="shutdown", printing=True)
    decision = engine.evaluate("M112", context)
    assert decision.allowed
    assert decision.severity is Severity.OK


# --------------------------------------------------------------------------- #
# The probe rule - the one that saves the nozzle
# --------------------------------------------------------------------------- #


def test_z_homing_is_blocked_when_the_probe_is_already_triggered(engine, config):
    context = SafetyContext(
        klippy_ready=True, homed_axes="xy", probe_triggered=True, config=config
    )
    decision = engine.evaluate("G28 Z", context)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "probe_already_triggered" for i in decision.issues)


def test_bare_g28_also_covers_z_and_is_blocked(engine, config):
    context = SafetyContext(klippy_ready=True, probe_triggered=True, config=config)
    decision = engine.evaluate("G28", context)
    assert decision.severity is Severity.BLOCKED


def test_homing_only_xy_is_allowed_even_with_a_triggered_probe(engine, config):
    context = SafetyContext(klippy_ready=True, probe_triggered=True, config=config)
    decision = engine.evaluate("G28 X Y", context)
    assert decision.allowed


def test_unknown_probe_state_warns_rather_than_assuming_it_is_fine(engine, config):
    context = SafetyContext(klippy_ready=True, homed_axes="xy", probe_triggered=None, config=config)
    decision = engine.evaluate("G28 Z", context)
    assert decision.severity is Severity.WARNING
    assert any(i.code == "probe_state_unknown" for i in decision.issues)


def test_probing_requires_homing(engine, config):
    context = SafetyContext(klippy_ready=True, homed_axes="", probe_triggered=False, config=config)
    decision = engine.evaluate("PROBE", context)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "must_home_before_probe" for i in decision.issues)


def test_probing_without_a_configured_probe_is_blocked(engine):
    context = SafetyContext(klippy_ready=True, homed_axes="xyz", config=parse_config("[printer]\n"))
    decision = engine.evaluate("PROBE", context)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "no_probe" for i in decision.issues)


# --------------------------------------------------------------------------- #
# Movement: clamped to the LIVE config, never to hardcoded dimensions
# --------------------------------------------------------------------------- #


def test_move_beyond_configured_travel_is_clamped_not_rejected(engine, ready):
    decision = engine.evaluate("G1 X400 Y10", ready)
    assert decision.allowed
    assert "X330" in decision.command
    assert decision.was_modified
    assert any(i.code == "clamped" for i in decision.issues)


def test_negative_travel_is_clamped_to_position_min(engine, ready):
    # This config allows X down to -3, so -50 clamps to -3, not to 0.
    decision = engine.evaluate("G1 X-50", ready)
    assert "X-3" in decision.command


def test_clamping_follows_the_config_even_when_it_differs_from_the_printer_model(engine):
    small = parse_config(
        "[printer]\nmax_velocity: 100\n"
        "[stepper_x]\nposition_min: 0\nposition_max: 120\n"
    )
    context = SafetyContext(klippy_ready=True, homed_axes="xyz", config=small)
    decision = engine.evaluate("G1 X300", context)
    # Clamped to 120 from the config - not to any Neptune 3 Plus dimension.
    assert "X120" in decision.command


def test_movement_without_homing_is_blocked(engine, config):
    context = SafetyContext(klippy_ready=True, homed_axes="", config=config)
    decision = engine.evaluate("G1 X10", context)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "not_homed" for i in decision.issues)


def test_movement_during_a_print_is_blocked(engine, ready):
    ready.printing = True
    decision = engine.evaluate("G1 X10", ready)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "print_active" for i in decision.issues)


def test_a_paused_print_still_allows_manual_movement(engine, ready):
    ready.printing = True
    ready.paused = True
    decision = engine.evaluate("G1 X10", ready)
    assert not any(i.code == "print_active" for i in decision.issues)


def test_diagnostic_moves_get_a_conservative_feedrate(engine, ready):
    decision = engine.evaluate("G1 X100", ready)
    assert "F3000" in decision.command


def test_an_excessive_feedrate_is_reduced(engine, ready):
    decision = engine.evaluate("G1 X100 F30000", ready)
    assert "F3000" in decision.command
    assert any(i.code == "feedrate_capped" for i in decision.issues)


def test_unknown_config_warns_instead_of_clamping_blindly(engine):
    context = SafetyContext(klippy_ready=True, homed_axes="xyz", config=None)
    decision = engine.evaluate("G1 X999", context)
    assert decision.severity is Severity.WARNING
    assert any(i.code == "limits_unknown" for i in decision.issues)
    assert decision.command == decision.original


# --------------------------------------------------------------------------- #
# TESTZ - the step that can drive the nozzle into the bed
# --------------------------------------------------------------------------- #


def test_testz_outside_a_calibration_session_is_blocked(engine, ready):
    decision = engine.evaluate("TESTZ Z=-0.05", ready)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "no_calibration_session" for i in decision.issues)


def test_testz_inside_a_session_is_allowed(engine, ready):
    ready.calibration_session = "probe_calibrate"
    decision = engine.evaluate("TESTZ Z=-0.05", ready)
    assert decision.allowed
    assert decision.severity is Severity.OK


def test_an_oversized_testz_step_is_limited(engine, ready):
    ready.calibration_session = "probe_calibrate"
    decision = engine.evaluate("TESTZ Z=-5", ready)
    assert "Z=-1" in decision.command
    assert any(i.code == "testz_step_limited" for i in decision.issues)


def test_cumulative_downward_travel_is_capped(engine, ready):
    ready.calibration_session = "probe_calibrate"
    ready.testz_total_down = 11.8
    decision = engine.evaluate("TESTZ Z=-0.5", ready)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "testz_travel_exhausted" for i in decision.issues)


def test_moving_up_is_never_blocked_by_the_travel_budget(engine, ready):
    ready.calibration_session = "probe_calibrate"
    ready.testz_total_down = 11.8
    decision = engine.evaluate("TESTZ Z=+0.5", ready)
    assert decision.allowed


def test_accept_requires_a_session(engine, ready):
    assert engine.evaluate("ACCEPT", ready).severity is Severity.BLOCKED
    ready.calibration_session = "probe_calibrate"
    assert engine.evaluate("ACCEPT", ready).allowed


# --------------------------------------------------------------------------- #
# Bed workflows
# --------------------------------------------------------------------------- #


def test_bed_mesh_requires_homing(engine, config):
    context = SafetyContext(klippy_ready=True, homed_axes="xy", probe_triggered=False, config=config)
    decision = engine.evaluate("BED_MESH_CALIBRATE", context)
    assert decision.severity is Severity.BLOCKED


def test_bed_mesh_profile_load_does_not_require_homing(engine, config):
    context = SafetyContext(klippy_ready=True, homed_axes="", config=config)
    assert engine.evaluate("BED_MESH_PROFILE LOAD=default", context).allowed


def test_screws_tilt_needs_the_section(engine):
    context = SafetyContext(
        klippy_ready=True, homed_axes="xyz", config=parse_config("[printer]\n[probe]\nz_offset: 2\n")
    )
    decision = engine.evaluate("SCREWS_TILT_CALCULATE", context)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "no_screws_tilt_section" for i in decision.issues)


# --------------------------------------------------------------------------- #
# SAVE_CONFIG always backs up first
# --------------------------------------------------------------------------- #


def test_save_config_requires_a_backup(engine, ready):
    decision = engine.evaluate("SAVE_CONFIG", ready)
    assert decision.requires_backup is True
    assert decision.severity is Severity.WARNING


@pytest.mark.asyncio
async def test_the_backup_hook_runs_before_the_command():
    order = []

    async def backup(_command):
        order.append("backup")

    async def runner(_command):
        order.append("run")

    engine = PrinterSafetyEngine(runner=runner, on_backup=backup)
    context = SafetyContext(klippy_ready=True, homed_axes="xyz", config=parse_config("[printer]\n"))
    await engine.execute("SAVE_CONFIG", context, force=True)
    assert order == ["backup", "run"]


# --------------------------------------------------------------------------- #
# Resonance
# --------------------------------------------------------------------------- #


def test_resonance_test_without_an_accelerometer_is_blocked(engine, ready):
    decision = engine.evaluate("SHAPER_CALIBRATE", ready)
    assert decision.severity is Severity.BLOCKED
    assert any(i.code == "no_accelerometer" for i in decision.issues)


def test_resonance_test_with_an_accelerometer_is_allowed(engine):
    cfg = parse_config(NEPTUNE_CFG + "\n[adxl345]\ncs_pin: rpi:None\n")
    context = SafetyContext(klippy_ready=True, homed_axes="xyz", probe_triggered=False, config=cfg)
    assert engine.evaluate("SHAPER_CALIBRATE", context).allowed


# --------------------------------------------------------------------------- #
# Heaters
# --------------------------------------------------------------------------- #


def test_an_absurd_nozzle_target_is_blocked(engine, ready):
    assert engine.evaluate("M104 S400", ready).severity is Severity.BLOCKED


def test_a_normal_nozzle_target_is_allowed(engine, ready):
    assert engine.evaluate("M104 S210", ready).allowed


def test_an_absurd_bed_target_is_blocked(engine, ready):
    assert engine.evaluate("M140 S200", ready).severity is Severity.BLOCKED


# --------------------------------------------------------------------------- #
# Execution
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_execute_raises_on_a_blocked_command():
    sent = []
    engine = PrinterSafetyEngine(runner=lambda c: sent.append(c))
    context = SafetyContext(klippy_ready=True, probe_triggered=True, config=parse_config(NEPTUNE_CFG))

    with pytest.raises(SafetyBlocked) as excinfo:
        await engine.execute("G28 Z", context)

    assert sent == []
    assert "probe" in str(excinfo.value).lower()


@pytest.mark.asyncio
async def test_a_warning_needs_force_before_it_runs():
    sent = []
    engine = PrinterSafetyEngine(runner=lambda c: sent.append(c))
    context = SafetyContext(
        klippy_ready=True, homed_axes="xy", probe_triggered=None, config=parse_config(NEPTUNE_CFG)
    )

    await engine.execute("G28 Z", context)
    assert sent == []

    await engine.execute("G28 Z", context, force=True)
    assert sent == ["G28 Z"]


@pytest.mark.asyncio
async def test_force_can_never_override_a_block():
    sent = []
    engine = PrinterSafetyEngine(runner=lambda c: sent.append(c))
    context = SafetyContext(klippy_ready=True, probe_triggered=True, config=parse_config(NEPTUNE_CFG))

    with pytest.raises(SafetyBlocked):
        await engine.execute("G28 Z", context, force=True)
    assert sent == []


@pytest.mark.asyncio
async def test_a_sequence_stops_at_the_first_refusal():
    sent = []
    engine = PrinterSafetyEngine(runner=lambda c: sent.append(c))
    context = SafetyContext(
        klippy_ready=True, homed_axes="xyz", probe_triggered=True, config=parse_config(NEPTUNE_CFG)
    )

    with pytest.raises(SafetyBlocked):
        await engine.execute_sequence(
            ["G28 X Y", "G28 Z", "BED_MESH_CALIBRATE"], context, force=True
        )

    # The first command ran; the blocked one did not, and neither did the third.
    assert sent == ["G28 X Y"]


@pytest.mark.asyncio
async def test_every_decision_is_audited():
    engine = PrinterSafetyEngine(runner=lambda c: None)
    context = SafetyContext(klippy_ready=True, homed_axes="xyz", config=parse_config(NEPTUNE_CFG))
    await engine.execute("G1 X10", context, force=True)
    entry = engine.audit_log[-1]
    assert entry["executed"] is True
    assert entry["kind"] == "movement"
    assert entry["original"] == "G1 X10"
