"""Guided calibration workflows.

The invariant every test here circles: a later stage never runs after an earlier
safety check failed.
"""

from __future__ import annotations

import pytest

from app.doctor.workflows import (
    StepState,
    WorkflowRunner,
    WorkflowState,
    full_bed_calibration_workflow,
    z_offset_workflow,
)
from app.klipper.model import parse_config
from app.safety.engine import PrinterSafetyEngine, SafetyContext

CFG = """
[printer]
kinematics: cartesian
max_velocity: 300
max_accel: 3000
[stepper_x]
position_min: 0
position_max: 330
[stepper_y]
position_min: 0
position_max: 330
[stepper_z]
position_min: 0
position_max: 410
[probe]
z_offset: 2.1
[safe_z_home]
home_xy_position: 160, 160
[bed_mesh]
mesh_min: 30, 30
[screws_tilt_adjust]
screw1: 30, 30
"""


class FakeMoonraker:
    """Records commands and replays canned console output."""

    def __init__(self, console: str = "") -> None:
        self.sent: list[str] = []
        self.console = console

    async def recent_console(self) -> str:
        return self.console


def make_runner(context: SafetyContext, console: str = ""):
    moonraker = FakeMoonraker(console)
    engine = PrinterSafetyEngine(runner=lambda c: moonraker.sent.append(c))
    runner = WorkflowRunner(engine, moonraker, context_factory=lambda: context)
    return runner, moonraker


@pytest.fixture()
def ready_context():
    return SafetyContext(
        klippy_ready=True,
        klippy_state="ready",
        homed_axes="xyz",
        probe_triggered=False,
        config=parse_config(CFG),
    )


# --------------------------------------------------------------------------- #
# Shape of the workflows
# --------------------------------------------------------------------------- #


def test_the_z_offset_workflow_covers_the_whole_documented_procedure():
    ids = [s.id for s in z_offset_workflow()]
    assert ids == [
        "probe_check", "home", "start", "adjust", "accept", "confirm_save", "save",
    ]


def test_full_calibration_levels_the_screws_before_meshing():
    ids = [s.id for s in full_bed_calibration_workflow()]
    assert ids.index("screws") < ids.index("mesh")
    assert ids.index("screws_adjust") < ids.index("mesh")
    # And it checks the probe before anything moves.
    assert ids[0] == "probe_check"


def test_every_workflow_checks_the_probe_or_the_sensor_first():
    from app.doctor.workflows import WORKFLOW_BUILDERS

    for kind, builder in WORKFLOW_BUILDERS.items():
        steps = builder(None) if kind == "axis_health" else builder()
        assert steps[0].id in {"probe_check", "detect"}, kind


def test_the_axis_health_test_stays_inside_the_configured_travel():
    from app.doctor.workflows import axis_health_workflow

    steps = axis_health_workflow(parse_config(CFG))
    commands = [c for s in steps for c in s.commands if c.startswith("G1")]
    assert commands
    for command in commands:
        for token in command.split():
            if token[0] in "XY":
                value = float(token[1:])
                assert 0 <= value <= 330, command


# --------------------------------------------------------------------------- #
# Running
# --------------------------------------------------------------------------- #


@pytest.mark.asyncio
async def test_a_workflow_runs_step_by_step(ready_context):
    runner, moonraker = make_runner(ready_context)
    runner.start("safe_home")

    await runner.advance(force=True)
    assert moonraker.sent == ["QUERY_PROBE"]

    await runner.advance(force=True)
    assert moonraker.sent[-1] == "G28 X Y"

    workflow = await runner.advance(force=True)
    assert moonraker.sent[-1] == "G28 Z"
    assert workflow.state is WorkflowState.DONE
    assert workflow.progress == 1.0


@pytest.mark.asyncio
async def test_a_blocked_step_fails_the_workflow_and_stops_it(ready_context):
    ready_context.probe_triggered = True
    runner, moonraker = make_runner(ready_context)
    runner.start("safe_home")

    await runner.advance(force=True)      # probe check runs
    await runner.advance(force=True)      # G28 X Y runs
    workflow = await runner.advance(force=True)   # G28 Z is blocked

    assert workflow.state is WorkflowState.FAILED
    assert "probe" in workflow.message.lower()
    assert moonraker.sent == ["QUERY_PROBE", "G28 X Y"]

    # And it stays stopped - advancing again does not run the mesh.
    again = await runner.advance(force=True)
    assert again.state is WorkflowState.FAILED
    assert moonraker.sent == ["QUERY_PROBE", "G28 X Y"]


@pytest.mark.asyncio
async def test_full_calibration_never_reaches_the_mesh_when_homing_is_refused(ready_context):
    ready_context.probe_triggered = True
    runner, moonraker = make_runner(ready_context)
    runner.start("full_bed_calibration")

    for _ in range(len(full_bed_calibration_workflow())):
        workflow = await runner.advance(force=True)
        if workflow.state is WorkflowState.FAILED:
            break

    assert workflow.state is WorkflowState.FAILED
    assert not any("BED_MESH" in c for c in moonraker.sent)
    assert not any("SAVE_CONFIG" in c for c in moonraker.sent)


@pytest.mark.asyncio
async def test_a_manual_step_waits_for_the_person(ready_context):
    runner, _ = make_runner(ready_context)
    runner.start("screws_tilt")

    await runner.advance(force=True)   # probe
    await runner.advance(force=True)   # home
    await runner.advance(force=True)   # measure
    workflow = await runner.advance(force=True)   # adjust - manual

    assert workflow.state is WorkflowState.WAITING_FOR_USER
    assert workflow.active_step.id == "adjust"


@pytest.mark.asyncio
async def test_confirming_a_manual_step_moves_on(ready_context):
    runner, _ = make_runner(ready_context)
    runner.start("screws_tilt")
    for _ in range(3):
        await runner.advance(force=True)
    await runner.advance(force=True)

    workflow = await runner.confirm(payload={"turned": True})
    assert workflow.state is WorkflowState.DONE
    assert workflow.data["confirmations"]["adjust"] == {"turned": True}


@pytest.mark.asyncio
async def test_screw_measurements_are_parsed_into_the_workflow_data(ready_context):
    console = (
        "screw (front left) : x=30.0, y=30.0, z=2.10000 : base\n"
        "front right : x=270.0, y=30.0, z=2.32500 : adjust CW 00:21\n"
    )
    runner, _ = make_runner(ready_context, console=console)
    runner.start("screws_tilt")
    await runner.advance(force=True)
    await runner.advance(force=True)
    workflow = await runner.advance(force=True)

    screws = workflow.data["screws"]
    assert screws["verdict"] == "adjust"
    assert screws["screws"][1]["turns"] == pytest.approx(0.35, abs=0.001)


@pytest.mark.asyncio
async def test_a_level_bed_skips_the_adjust_step(ready_context):
    console = (
        "screw front left : x=30.0, y=30.0, z=2.10000 : base\n"
        "front right : x=270.0, y=30.0, z=2.10000 : adjust CW 00:00\n"
    )
    runner, _ = make_runner(ready_context, console=console)
    runner.start("screws_tilt")
    for _ in range(3):
        await runner.advance(force=True)

    adjust = next(s for s in runner.active.steps if s.id == "adjust")
    assert adjust.state is StepState.SKIPPED


@pytest.mark.asyncio
async def test_measure_again_re_runs_the_step(ready_context):
    runner, moonraker = make_runner(ready_context)
    runner.start("screws_tilt")
    for _ in range(3):
        await runner.advance(force=True)

    runner.go_to_step("measure")
    await runner.advance(force=True)
    assert moonraker.sent.count("SCREWS_TILT_CALCULATE") == 2


@pytest.mark.asyncio
async def test_only_one_workflow_runs_at_a_time(ready_context):
    runner, _ = make_runner(ready_context)
    runner.start("safe_home")
    with pytest.raises(RuntimeError, match="already running"):
        runner.start("bed_mesh")


@pytest.mark.asyncio
async def test_cancelling_frees_the_runner(ready_context):
    runner, _ = make_runner(ready_context)
    runner.start("safe_home")
    runner.cancel()
    assert runner.active.state is WorkflowState.CANCELLED
    runner.start("bed_mesh")     # no longer refused


@pytest.mark.asyncio
async def test_a_warning_pauses_for_confirmation_rather_than_charging_on(ready_context):
    # An unread probe makes G28 Z a warning, not a block.
    ready_context.probe_triggered = None
    runner, moonraker = make_runner(ready_context)
    runner.start("safe_home")

    await runner.advance()      # probe check
    await runner.advance()      # G28 X Y
    workflow = await runner.advance()   # G28 Z warns

    assert workflow.state is WorkflowState.WAITING_FOR_USER
    assert "probe" in workflow.message.lower()
    assert "G28 Z" not in moonraker.sent

    # Confirming with force runs it.
    workflow = await runner.advance(force=True)
    assert "G28 Z" in moonraker.sent


@pytest.mark.asyncio
async def test_console_collection_failure_does_not_fail_the_workflow(ready_context):
    class Broken:
        async def recent_console(self):
            raise RuntimeError("moonraker went away")

    engine = PrinterSafetyEngine(runner=lambda c: None)
    runner = WorkflowRunner(engine, Broken(), context_factory=lambda: ready_context)
    runner.start("safe_home")
    workflow = await runner.advance(force=True)
    assert workflow.state is WorkflowState.RUNNING


def test_an_unknown_workflow_is_rejected(ready_context):
    runner, _ = make_runner(ready_context)
    with pytest.raises(ValueError, match="Unknown workflow"):
        runner.start("make_me_a_sandwich")


@pytest.mark.asyncio
async def test_the_workflow_serialises_for_the_api(ready_context):
    runner, _ = make_runner(ready_context)
    runner.start("z_offset")
    await runner.advance(force=True)
    payload = runner.active.as_dict()
    assert payload["kind"] == "z_offset"
    assert payload["steps"][0]["state"] == "done"
    assert 0.0 < payload["progress"] < 1.0
