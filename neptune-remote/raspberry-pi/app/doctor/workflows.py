"""Guided calibration workflows.

Each workflow is a small state machine the phone drives one step at a time. The
app never has to remember G28 / PROBE_CALIBRATE / TESTZ / SCREWS_TILT_CALCULATE
/ BED_MESH_CALIBRATE / SAVE_CONFIG - the workflow issues them, in order, and
every one goes through the safety engine.

The invariant across all of them: **a later stage never runs when an earlier
safety check failed.** :meth:`Workflow.advance` stops at the first refusal and
records why.
"""

from __future__ import annotations

import contextlib
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional

from ..klipper.screws import ScrewsTiltResult, parse_screws_tilt
from ..safety.engine import CommandDecision, SafetyBlocked, Severity


class StepState(str, Enum):
    PENDING = "pending"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"
    SKIPPED = "skipped"
    #: Waiting for the person to do something physical, or to confirm.
    WAITING_FOR_USER = "waiting_for_user"


class WorkflowState(str, Enum):
    IDLE = "idle"
    RUNNING = "running"
    WAITING_FOR_USER = "waiting_for_user"
    DONE = "done"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class WorkflowStep:
    id: str
    title: str
    description: str = ""
    #: Commands this step issues, in order. Empty for user-action steps.
    commands: List[str] = field(default_factory=list)
    #: True when the step needs the person to act before the workflow continues.
    manual: bool = False
    state: StepState = StepState.PENDING
    message: str = ""
    output: str = ""
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    decisions: List[Dict[str, Any]] = field(default_factory=list)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "description": self.description,
            "commands": list(self.commands),
            "manual": self.manual,
            "state": self.state.value,
            "message": self.message,
            "output": self.output[-4000:],
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "decisions": list(self.decisions),
        }


@dataclass
class Workflow:
    """A running guided procedure."""

    id: str
    kind: str
    title: str
    steps: List[WorkflowStep]
    state: WorkflowState = WorkflowState.IDLE
    current: int = 0
    created_at: float = field(default_factory=time.time)
    updated_at: float = field(default_factory=time.time)
    message: str = ""
    #: Workflow-specific results (screw readings, offsets, mesh summary, ...).
    data: Dict[str, Any] = field(default_factory=dict)

    @property
    def active_step(self) -> Optional[WorkflowStep]:
        return self.steps[self.current] if 0 <= self.current < len(self.steps) else None

    @property
    def finished(self) -> bool:
        return self.state in {WorkflowState.DONE, WorkflowState.FAILED, WorkflowState.CANCELLED}

    @property
    def progress(self) -> float:
        if not self.steps:
            return 0.0
        done = sum(1 for s in self.steps if s.state in {StepState.DONE, StepState.SKIPPED})
        return done / len(self.steps)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "kind": self.kind,
            "title": self.title,
            "state": self.state.value,
            "message": self.message,
            "current": self.current,
            "progress": round(self.progress, 3),
            "finished": self.finished,
            "created_at": self.created_at,
            "updated_at": self.updated_at,
            "steps": [s.as_dict() for s in self.steps],
            "data": self.data,
        }


# --------------------------------------------------------------------------- #
# Definitions
# --------------------------------------------------------------------------- #


def _step(step_id: str, title: str, description: str = "", commands: Optional[List[str]] = None,
          manual: bool = False) -> WorkflowStep:
    return WorkflowStep(
        id=step_id, title=title, description=description,
        commands=list(commands or []), manual=manual,
    )


def safe_home_workflow() -> List[WorkflowStep]:
    return [
        _step(
            "probe_check", "Check the probe",
            "Reads the probe before anything moves. If it is already triggered, "
            "the workflow stops here rather than driving the nozzle into the bed.",
            ["QUERY_PROBE"],
        ),
        _step("home_xy", "Home X and Y", "Finds the X and Y endstops.", ["G28 X Y"]),
        _step("home_z", "Home Z", "Homes Z over the bed centre.", ["G28 Z"]),
    ]


def z_offset_workflow() -> List[WorkflowStep]:
    return [
        _step(
            "probe_check", "Check the probe",
            "The probe must read open before calibration starts.",
            ["QUERY_PROBE"],
        ),
        _step("home", "Home all axes", "", ["G28"]),
        _step(
            "start", "Start probe calibration",
            "Klipper probes the bed and then lowers the nozzle for the paper test.",
            ["PROBE_CALIBRATE"],
        ),
        _step(
            "adjust", "Adjust until the paper drags",
            "Use the buttons to step the nozzle down, then up, until a sheet of paper "
            "just drags under it. The app limits each step and the total travel.",
            manual=True,
        ),
        _step(
            "accept", "Accept the position",
            "Klipper calculates the probe z_offset from where you stopped.",
            ["ACCEPT"],
        ),
        _step(
            "confirm_save", "Confirm the new offset",
            "Review the calculated value before it is written.",
            manual=True,
        ),
        _step(
            "save", "Save and restart",
            "SAVE_CONFIG writes the offset and restarts Klipper. A backup is taken first.",
            ["SAVE_CONFIG"],
        ),
    ]


def screws_tilt_workflow() -> List[WorkflowStep]:
    return [
        _step("probe_check", "Check the probe", "", ["QUERY_PROBE"]),
        _step("home", "Home all axes", "", ["G28"]),
        _step(
            "measure", "Measure the bed screws",
            "Probes each screw position and reports how far to turn each knob.",
            ["SCREWS_TILT_CALCULATE"],
        ),
        _step(
            "adjust", "Turn the screws",
            "Follow the on-screen arrows, then measure again. Repeat until every "
            "screw is inside tolerance.",
            manual=True,
        ),
    ]


def bed_mesh_workflow() -> List[WorkflowStep]:
    return [
        _step("probe_check", "Check the probe", "", ["QUERY_PROBE"]),
        _step("home", "Home all axes", "", ["G28"]),
        _step(
            "mesh", "Probe the bed",
            "Measures the bed surface across the whole plate. This takes a few minutes.",
            ["BED_MESH_CALIBRATE"],
        ),
        _step(
            "confirm_save", "Review the mesh",
            "Check the deviation before saving.",
            manual=True,
        ),
        _step("save", "Save the mesh", "", ["SAVE_CONFIG"]),
    ]


def full_bed_calibration_workflow() -> List[WorkflowStep]:
    """Everything, in the order that actually makes sense: screws first (a
    mesh over a badly tilted bed is wasted work), then Z offset, then mesh."""
    return [
        _step("probe_check", "Check the probe", "", ["QUERY_PROBE"]),
        _step("home", "Home all axes", "", ["G28"]),
        _step(
            "screws", "Measure the bed screws",
            "Mechanical levelling comes first - a mesh cannot compensate for a badly "
            "tilted bed.",
            ["SCREWS_TILT_CALCULATE"],
        ),
        _step(
            "screws_adjust", "Turn the screws until level",
            "Repeat measure-and-turn until every screw is inside tolerance.",
            manual=True,
        ),
        _step("rehome", "Home again", "", ["G28"]),
        _step(
            "z_offset", "Calibrate the Z offset",
            "Only needed if the offset has never been set, or the nozzle changed.",
            ["PROBE_CALIBRATE"],
        ),
        _step("z_adjust", "Adjust until the paper drags", "", manual=True),
        _step("z_accept", "Accept the Z position", "", ["ACCEPT"]),
        _step(
            "mesh", "Probe the bed mesh",
            "Compensates for whatever warp is left after levelling.",
            ["BED_MESH_CALIBRATE"],
        ),
        _step("save", "Save everything", "", ["SAVE_CONFIG"]),
    ]


def axis_health_workflow(config: Any = None) -> List[WorkflowStep]:
    """Move to known coordinates at a conservative speed, then re-home and
    compare. This is indirect evidence, not position feedback - open-loop
    steppers cannot report where they really are."""
    limits = {}
    if config is not None:
        for axis in ("x", "y"):
            axis_limits = config.axis_limits(axis)
            if axis_limits.is_known:
                limits[axis] = (axis_limits.position_min, axis_limits.position_max)

    def point(axis: str, fraction: float) -> float:
        low, high = limits.get(axis, (0.0, 200.0))
        span = high - low
        # Stay a few mm inside the configured travel.
        return round(low + 5 + (span - 10) * fraction, 2)

    return [
        _step("probe_check", "Check the probe", "", ["QUERY_PROBE"]),
        _step("home", "Home all axes", "", ["G28"]),
        _step(
            "x_sweep", "Move X across its travel",
            "Three positions at a conservative speed.",
            [
                f"G1 X{point('x', 0.0)} F3000",
                f"G1 X{point('x', 1.0)} F3000",
                f"G1 X{point('x', 0.5)} F3000",
            ],
        ),
        _step(
            "y_sweep", "Move Y across its travel",
            "Y carries the bed on this printer, so it is the axis most likely to skip.",
            [
                f"G1 Y{point('y', 0.0)} F3000",
                f"G1 Y{point('y', 1.0)} F3000",
                f"G1 Y{point('y', 0.5)} F3000",
            ],
        ),
        _step(
            "rehome", "Re-home X and Y",
            "If the axis lost steps during the sweep, the endstop is reached from a "
            "different place than expected.",
            ["G28 X Y"],
        ),
        _step(
            "verify", "Compare the result",
            "Reads the endstops and reports pass or 'possible skipped steps'.",
            ["QUERY_ENDSTOPS", "GET_POSITION"],
        ),
    ]


def input_shaper_workflow() -> List[WorkflowStep]:
    return [
        _step(
            "detect", "Check the accelerometer",
            "Confirms the ADXL345 answers before anything moves.",
            ["ACCELEROMETER_QUERY"],
        ),
        _step("home", "Home all axes", "", ["G28"]),
        _step(
            "noise", "Measure background noise",
            "A noisy baseline makes the resonance result meaningless.",
            ["MEASURE_AXES_NOISE"],
        ),
        _step(
            "shaper_x", "Test the X axis",
            "The toolhead sweeps a frequency range while the accelerometer records.",
            ["SHAPER_CALIBRATE AXIS=X"],
        ),
        _step("shaper_y", "Test the Y axis", "", ["SHAPER_CALIBRATE AXIS=Y"]),
        _step("confirm_save", "Review the recommendation", "", manual=True),
        _step("save", "Save the shaper settings", "", ["SAVE_CONFIG"]),
    ]


WORKFLOW_BUILDERS: Dict[str, Callable[..., List[WorkflowStep]]] = {
    "safe_home": safe_home_workflow,
    "z_offset": z_offset_workflow,
    "screws_tilt": screws_tilt_workflow,
    "bed_mesh": bed_mesh_workflow,
    "full_bed_calibration": full_bed_calibration_workflow,
    "axis_health": axis_health_workflow,
    "input_shaper": input_shaper_workflow,
}

WORKFLOW_TITLES = {
    "safe_home": "Home safely",
    "z_offset": "Z Offset wizard",
    "screws_tilt": "Bed screw adjustment",
    "bed_mesh": "Bed mesh",
    "full_bed_calibration": "Full bed calibration",
    "axis_health": "Axis health test",
    "input_shaper": "Input shaper calibration",
}


#: The printer.cfg section each workflow cannot run without, and why.
#:
#: Every one of these workflows opens by sending a command that Klipper only
#: defines when the matching section exists. Offering the Input Shaper wizard on
#: a machine with no accelerometer means its first step answers "Unknown
#: command: ACCELEROMETER_QUERY" - which reads, from the outside, exactly like
#: the app being broken.
WORKFLOW_REQUIREMENTS: Dict[str, tuple] = {
    "z_offset": (
        ("probe", "bltouch", "smart_effector", "eddy_current", "scanner"),
        "مفيش بروب في printer.cfg، فمفيش Z offset يتعاير أوتوماتيك.",
    ),
    "screws_tilt": (
        ("screws_tilt_adjust",),
        "مفيش قسم [screws_tilt_adjust]، فمفيش قياس أوتوماتيك للمسامير.",
    ),
    "bed_mesh": (("bed_mesh",), "مفيش قسم [bed_mesh] في printer.cfg."),
    "full_bed_calibration": (("bed_mesh",), "مفيش قسم [bed_mesh] في printer.cfg."),
    "input_shaper": (
        ("adxl345", "lis2dw", "mpu9250"),
        "مفيش أكسيليروميتر (ADXL345 مثلاً) متوصل ومكتوب في printer.cfg. "
        "من غيره مفيش حاجة تقيس الاهتزاز.",
    ),
    "safe_home": (("safe_z_home",), "مفيش قسم [safe_z_home]."),
}


def describe(config: Any = None) -> List[Dict[str, Any]]:
    """Every workflow, and whether this printer can actually run it.

    A workflow with an unmet requirement is still listed - hiding it would leave
    someone hunting a menu for something that is simply not possible on their
    machine - but it comes back with the reason attached.
    """
    entries: List[Dict[str, Any]] = []
    for kind, title in WORKFLOW_TITLES.items():
        blockers: List[str] = []
        requirement = WORKFLOW_REQUIREMENTS.get(kind)
        if requirement is not None and config is not None:
            sections, reason = requirement
            if not any(config.has(name) for name in sections):
                blockers.append(reason)
        entries.append(
            {
                "kind": kind,
                "title": title,
                "available": not blockers,
                "blockers": blockers,
            }
        )
    return entries


# --------------------------------------------------------------------------- #
# Runner
# --------------------------------------------------------------------------- #


class WorkflowRunner:
    """Creates and advances workflows.

    One at a time, deliberately: two calibration procedures moving the same
    toolhead is never what anyone wants.
    """

    def __init__(self, safety: Any, moonraker: Any, *, context_factory: Callable[[], Any]) -> None:
        self.safety = safety
        self.moonraker = moonraker
        self.context_factory = context_factory
        self.active: Optional[Workflow] = None
        self.history: List[Workflow] = []
        #: Called with each SCREWS_TILT_CALCULATE result so it can be kept.
        #:
        #: printer.cfg records nothing about the bed knobs - it is the one part
        #: of levelling that leaves no trace - so unless the measurement is
        #: remembered here, the honest answer to "is my bed level" is always
        #: "no idea", even a minute after measuring it.
        self.on_screws_measured: Optional[Callable[[Dict[str, Any]], None]] = None

    # ------------------------------------------------------------- lifecycle
    def start(self, kind: str, *, config: Any = None) -> Workflow:
        if kind not in WORKFLOW_BUILDERS:
            raise ValueError(f"Unknown workflow: {kind}")
        if self.active is not None and not self.active.finished:
            raise RuntimeError(
                f"'{self.active.title}' is already running. Cancel it before starting another."
            )

        builder = WORKFLOW_BUILDERS[kind]
        steps = builder(config) if kind == "axis_health" else builder()
        workflow = Workflow(
            id=uuid.uuid4().hex[:12],
            kind=kind,
            title=WORKFLOW_TITLES.get(kind, kind),
            steps=steps,
            state=WorkflowState.RUNNING,
        )
        self.active = workflow
        self.history.append(workflow)
        if len(self.history) > 20:
            del self.history[:-20]
        return workflow

    def cancel(self) -> Optional[Workflow]:
        workflow = self.active
        if workflow is None or workflow.finished:
            return workflow
        workflow.state = WorkflowState.CANCELLED
        workflow.message = "Cancelled."
        step = workflow.active_step
        if step is not None and step.state is StepState.RUNNING:
            step.state = StepState.SKIPPED
        workflow.updated_at = time.time()
        return workflow

    def get(self, workflow_id: Optional[str] = None) -> Optional[Workflow]:
        if workflow_id is None:
            return self.active
        return next((w for w in self.history if w.id == workflow_id), None)

    # --------------------------------------------------------------- driving
    async def advance(self, *, force: bool = False) -> Workflow:
        """Run the current step. Stops at the first refusal."""
        workflow = self.active
        if workflow is None:
            raise RuntimeError("No workflow is running.")
        if workflow.finished:
            return workflow

        step = workflow.active_step
        if step is None:
            workflow.state = WorkflowState.DONE
            return workflow

        if step.manual and step.state is not StepState.DONE:
            step.state = StepState.WAITING_FOR_USER
            workflow.state = WorkflowState.WAITING_FOR_USER
            workflow.message = step.description or step.title
            workflow.updated_at = time.time()
            return workflow

        step.state = StepState.RUNNING
        step.started_at = time.time()
        workflow.state = WorkflowState.RUNNING
        workflow.updated_at = time.time()

        try:
            for command in step.commands:
                context = self.context_factory()
                decision = await self.safety.execute(command, context, force=force)
                step.decisions.append(decision.as_dict())

                if decision.severity is Severity.WARNING and not force:
                    step.state = StepState.WAITING_FOR_USER
                    workflow.state = WorkflowState.WAITING_FOR_USER
                    workflow.message = decision.issues[-1].message if decision.issues else ""
                    step.message = workflow.message
                    workflow.updated_at = time.time()
                    return workflow

                output = await self._collect(decision.command)
                if output:
                    step.output = f"{step.output}\n{output}".strip()
        except SafetyBlocked as blocked:
            step.state = StepState.FAILED
            step.finished_at = time.time()
            step.message = "; ".join(blocked.decision.blocked_reasons())
            step.decisions.append(blocked.decision.as_dict())
            workflow.state = WorkflowState.FAILED
            workflow.message = step.message
            workflow.updated_at = time.time()
            return workflow
        except Exception as error:                      # noqa: BLE001
            step.state = StepState.FAILED
            step.finished_at = time.time()
            step.message = str(error)
            workflow.state = WorkflowState.FAILED
            workflow.message = str(error)
            workflow.updated_at = time.time()
            return workflow

        self._interpret(workflow, step)

        step.state = StepState.DONE
        step.finished_at = time.time()
        workflow.current += 1
        workflow.updated_at = time.time()

        if workflow.current >= len(workflow.steps):
            workflow.state = WorkflowState.DONE
            workflow.message = "Finished."
        return workflow

    async def confirm(self, *, payload: Optional[Dict[str, Any]] = None) -> Workflow:
        """The person did the physical step, or approved the value."""
        workflow = self.active
        if workflow is None:
            raise RuntimeError("No workflow is running.")
        step = workflow.active_step
        if step is None:
            return workflow
        if payload:
            workflow.data.setdefault("confirmations", {})[step.id] = payload
        step.state = StepState.DONE
        step.finished_at = time.time()
        workflow.current += 1
        workflow.state = (
            WorkflowState.DONE if workflow.current >= len(workflow.steps) else WorkflowState.RUNNING
        )
        workflow.updated_at = time.time()
        return workflow

    async def repeat_step(self) -> Workflow:
        """Re-run the current step - used by "measure again" after turning screws."""
        workflow = self.active
        if workflow is None:
            raise RuntimeError("No workflow is running.")
        step = workflow.active_step
        if step is not None:
            step.state = StepState.PENDING
            step.output = ""
            step.message = ""
            step.decisions.clear()
        return await self.advance()

    def go_to_step(self, step_id: str) -> Workflow:
        """Jump back to an earlier step, e.g. from 'adjust' to 'measure'."""
        workflow = self.active
        if workflow is None:
            raise RuntimeError("No workflow is running.")
        for index, step in enumerate(workflow.steps):
            if step.id == step_id:
                workflow.current = index
                step.state = StepState.PENDING
                step.output = ""
                step.decisions.clear()
                workflow.state = WorkflowState.RUNNING
                workflow.updated_at = time.time()
                return workflow
        raise ValueError(f"No step '{step_id}' in this workflow.")

    # -------------------------------------------------------------- helpers
    async def _collect(self, command: str) -> str:
        """Read whatever the command printed to the console, when the client
        supports it. Failure here must never fail the workflow."""
        collector = getattr(self.moonraker, "recent_console", None)
        if collector is None:
            return ""
        try:
            return await collector()
        except Exception:                                # noqa: BLE001
            return ""

    def _interpret(self, workflow: Workflow, step: WorkflowStep) -> None:
        """Turn raw console text into something the UI can draw."""
        output = step.output or ""

        if step.id in {"measure", "screws"} and output:
            result: ScrewsTiltResult = parse_screws_tilt(output)
            measurement = result.as_dict()
            measurement["measured_at"] = time.time()
            measurement["worst"] = result.worst.name if result.worst else ""
            workflow.data["screws"] = measurement
            step.message = result.summary
            if self.on_screws_measured is not None and not result.parse_failed:
                with contextlib.suppress(Exception):
                    self.on_screws_measured(measurement)
            # A level bed means the adjust step has nothing to do.
            if result.level:
                for candidate in workflow.steps:
                    if candidate.id in {"adjust", "screws_adjust"}:
                        candidate.state = StepState.SKIPPED
                        candidate.message = "Already level."

        if step.id == "probe_check" and output:
            lowered = output.lower()
            triggered = "probe: triggered" in lowered
            workflow.data["probe_triggered"] = triggered
            step.message = "Probe is triggered." if triggered else "Probe is open."

        if step.id in {"accept", "z_accept"} and output:
            workflow.data["accept_output"] = output
            for line in output.splitlines():
                if "z_offset" in line.lower():
                    step.message = line.strip()
                    break

        if step.id == "mesh" and output:
            workflow.data["mesh_output"] = output

        if step.id == "verify" and output:
            workflow.data["axis_verify_output"] = output
