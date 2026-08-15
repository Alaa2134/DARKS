"""The Safety Command Engine.

Nothing in this project sends a movement command to Klipper directly. Routers,
wizards, the diagnostics engine and the AI assistant all call
:meth:`PrinterSafetyEngine.execute`, which:

* classifies the command,
* checks the preconditions that class of command needs,
* clamps coordinates to the **live** ``printer.cfg`` limits (never to hardcoded
  printer dimensions),
* refuses, with a reason the UI can show, when a precondition fails.

The design rule throughout: when the engine cannot establish that a command is
safe, it refuses. It never assumes.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, Sequence

from ..klipper.model import ParsedConfig

# --------------------------------------------------------------------------- #
# Classification
# --------------------------------------------------------------------------- #


class CommandKind(str, Enum):
    """What a command *does*, which decides which checks apply."""

    MOVEMENT = "movement"            # G0/G1/G2/G3
    HOMING = "homing"                # G28
    PROBE = "probe"                  # PROBE, QUERY_PROBE, PROBE_ACCURACY
    PROBE_CALIBRATE = "probe_calibrate"
    TESTZ = "testz"
    ACCEPT_ABORT = "accept_abort"    # ACCEPT / ABORT during a calibration session
    BED_MESH = "bed_mesh"
    SCREWS_TILT = "screws_tilt"
    SAVE_CONFIG = "save_config"
    TEMPERATURE = "temperature"      # M104/M109/M140/M190/SET_HEATER_TEMPERATURE
    FAN = "fan"                      # M106/M107/SET_FAN_SPEED
    LIMITS = "limits"                # SET_VELOCITY_LIMIT, M204, M205
    RESONANCE = "resonance"          # TEST_RESONANCES, SHAPER_CALIBRATE, ACCELEROMETER_QUERY
    STEPPER = "stepper"              # M84 / SET_STEPPER_ENABLE
    EMERGENCY = "emergency"          # M112
    QUERY = "query"                  # read-only: QUERY_ENDSTOPS, GET_POSITION, STATUS
    OTHER = "other"


class Severity(str, Enum):
    OK = "ok"
    WARNING = "warning"
    BLOCKED = "blocked"


#: Command word -> kind. Matched on the first token, case-insensitively.
_KINDS: Dict[str, CommandKind] = {
    "G0": CommandKind.MOVEMENT,
    "G1": CommandKind.MOVEMENT,
    "G2": CommandKind.MOVEMENT,
    "G3": CommandKind.MOVEMENT,
    "G28": CommandKind.HOMING,
    "PROBE": CommandKind.PROBE,
    "PROBE_ACCURACY": CommandKind.PROBE,
    "QUERY_PROBE": CommandKind.QUERY,
    "QUERY_ENDSTOPS": CommandKind.QUERY,
    "GET_POSITION": CommandKind.QUERY,
    "STATUS": CommandKind.QUERY,
    "HELP": CommandKind.QUERY,
    "PROBE_CALIBRATE": CommandKind.PROBE_CALIBRATE,
    "Z_ENDSTOP_CALIBRATE": CommandKind.PROBE_CALIBRATE,
    "TESTZ": CommandKind.TESTZ,
    "ACCEPT": CommandKind.ACCEPT_ABORT,
    "ABORT": CommandKind.ACCEPT_ABORT,
    "BED_MESH_CALIBRATE": CommandKind.BED_MESH,
    "BED_MESH_PROFILE": CommandKind.BED_MESH,
    "BED_MESH_CLEAR": CommandKind.BED_MESH,
    "BED_MESH_OUTPUT": CommandKind.QUERY,
    "SCREWS_TILT_CALCULATE": CommandKind.SCREWS_TILT,
    "SAVE_CONFIG": CommandKind.SAVE_CONFIG,
    "M104": CommandKind.TEMPERATURE,
    "M109": CommandKind.TEMPERATURE,
    "M140": CommandKind.TEMPERATURE,
    "M190": CommandKind.TEMPERATURE,
    "SET_HEATER_TEMPERATURE": CommandKind.TEMPERATURE,
    "TURN_OFF_HEATERS": CommandKind.TEMPERATURE,
    "M106": CommandKind.FAN,
    "M107": CommandKind.FAN,
    "SET_FAN_SPEED": CommandKind.FAN,
    "SET_VELOCITY_LIMIT": CommandKind.LIMITS,
    "M204": CommandKind.LIMITS,
    "M205": CommandKind.LIMITS,
    "TEST_RESONANCES": CommandKind.RESONANCE,
    "SHAPER_CALIBRATE": CommandKind.RESONANCE,
    "ACCELEROMETER_QUERY": CommandKind.RESONANCE,
    "MEASURE_AXES_NOISE": CommandKind.RESONANCE,
    "M84": CommandKind.STEPPER,
    "M18": CommandKind.STEPPER,
    "SET_STEPPER_ENABLE": CommandKind.STEPPER,
    "M112": CommandKind.EMERGENCY,
}

_WORD_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)")
#: `X12.5`, `S200`, `F3000` - a single letter followed by a number. The
#: lookbehind keeps `MAX_X=5` and similar macro parameters from matching.
_AXIS_RE = re.compile(r"(?<![A-Za-z0-9_])([XYZEFS])\s*(-?\d+(?:\.\d+)?)", re.IGNORECASE)
#: `TESTZ Z=-0.05`, `SET_VELOCITY_LIMIT ACCEL=1500`.
_PARAM_RE = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_]+)\s*=\s*(-?\d+(?:\.\d+)?)")
#: A bare axis letter with no value, as in `G28 X Y`.
_BARE_AXIS_RE = re.compile(r"(?<![A-Za-z0-9_])([XYZ])(?![A-Za-z0-9_.=-])", re.IGNORECASE)


def classify(command: str) -> CommandKind:
    """Kind of the first word of ``command``."""
    match = _WORD_RE.match(command or "")
    if not match:
        return CommandKind.OTHER
    return _KINDS.get(match.group(1).upper(), CommandKind.OTHER)


def command_word(command: str) -> str:
    match = _WORD_RE.match(command or "")
    return match.group(1).upper() if match else ""


def parse_axis_words(command: str) -> Dict[str, float]:
    """``G1 X10 Y20 F3000`` -> ``{"X": 10.0, "Y": 20.0, "F": 3000.0}``."""
    return {
        letter.upper(): float(value)
        for letter, value in _AXIS_RE.findall(command or "")
    }


def parse_bare_axes(command: str) -> List[str]:
    """Axis letters mentioned without a value: ``G28 X Y`` -> ``["X", "Y"]``.

    Only meaningful after the command word, so the first token is dropped -
    otherwise ``Z_ENDSTOP_CALIBRATE`` would look like a Z axis word.
    """
    _, _, rest = (command or "").strip().partition(" ")
    return [letter.upper() for letter in _BARE_AXIS_RE.findall(rest)]


def parse_named_params(command: str) -> Dict[str, float]:
    """``TESTZ Z=-0.05`` -> ``{"Z": -0.05}``."""
    return {
        key.upper(): float(value)
        for key, value in _PARAM_RE.findall(command or "")
    }


# --------------------------------------------------------------------------- #
# Context and decisions
# --------------------------------------------------------------------------- #


@dataclass
class SafetyContext:
    """Everything the engine needs to know about the printer *right now*.

    Built from live Moonraker status plus the parsed live config. Deliberately a
    plain value object so the rules are testable without a printer.
    """

    klippy_ready: bool = False
    klippy_state: str = "unknown"
    klippy_message: str = ""
    printing: bool = False
    paused: bool = False
    homed_axes: str = ""
    position: Sequence[float] = (0.0, 0.0, 0.0)
    nozzle_temp: float = 0.0
    nozzle_target: float = 0.0
    bed_temp: float = 0.0
    bed_target: float = 0.0
    probe_triggered: Optional[bool] = None      # None = unknown, not "fine"
    endstops: Dict[str, str] = field(default_factory=dict)
    config: Optional[ParsedConfig] = None
    #: Set while PROBE_CALIBRATE / Z_ENDSTOP_CALIBRATE is in progress.
    calibration_session: Optional[str] = None
    #: Cumulative Z travel already requested in this TESTZ session, in mm.
    testz_total_down: float = 0.0

    def is_homed(self, axis: str) -> bool:
        return axis.lower() in (self.homed_axes or "").lower()

    @property
    def all_homed(self) -> bool:
        return all(self.is_homed(axis) for axis in "xyz")

    @property
    def min_extrude_temp(self) -> float:
        section = self.config.section("extruder") if self.config else None
        value = section.get_float("min_extrude_temp") if section else None
        return value if value is not None else 170.0


@dataclass
class SafetyIssue:
    code: str
    severity: Severity
    message: str
    detail: str = ""
    remedy: str = ""


@dataclass
class CommandDecision:
    """The engine's answer for one command."""

    original: str
    command: str                      # possibly clamped / rewritten
    kind: CommandKind
    severity: Severity
    issues: List[SafetyIssue] = field(default_factory=list)
    adjustments: List[str] = field(default_factory=list)
    requires_backup: bool = False

    @property
    def allowed(self) -> bool:
        return self.severity is not Severity.BLOCKED

    @property
    def was_modified(self) -> bool:
        return self.command != self.original

    def blocked_reasons(self) -> List[str]:
        return [i.message for i in self.issues if i.severity is Severity.BLOCKED]

    def as_dict(self) -> Dict[str, Any]:
        return {
            "original": self.original,
            "command": self.command,
            "kind": self.kind.value,
            "severity": self.severity.value,
            "allowed": self.allowed,
            "modified": self.was_modified,
            "requires_backup": self.requires_backup,
            "adjustments": list(self.adjustments),
            "issues": [
                {
                    "code": i.code,
                    "severity": i.severity.value,
                    "message": i.message,
                    "detail": i.detail,
                    "remedy": i.remedy,
                }
                for i in self.issues
            ],
        }


class SafetyBlocked(Exception):
    """Raised when a caller insists on running a command the engine refused."""

    def __init__(self, decision: CommandDecision) -> None:
        super().__init__("; ".join(decision.blocked_reasons()) or "Command blocked")
        self.decision = decision


# --------------------------------------------------------------------------- #
# Engine
# --------------------------------------------------------------------------- #

#: Conservative feedrate for anything the app initiates itself, mm/min.
DIAGNOSTIC_FEEDRATE = 3000.0
#: Hard cap on a single TESTZ step, mm. Klipper accepts more; we do not.
MAX_TESTZ_STEP = 1.0
#: Hard cap on total downward TESTZ travel in one session, mm.
MAX_TESTZ_SESSION_DOWN = 12.0


class PrinterSafetyEngine:
    """Validates, adjusts and (optionally) runs printer commands.

    ``runner`` is an async callable taking the final command string. It is only
    ever invoked for commands the engine allowed.
    """

    def __init__(
        self,
        runner: Optional[Callable[[str], Any]] = None,
        *,
        on_backup: Optional[Callable[[str], Any]] = None,
        audit_limit: int = 400,
    ) -> None:
        self._runner = runner
        self._on_backup = on_backup
        self._audit: List[Dict[str, Any]] = []
        self._audit_limit = audit_limit

    # ------------------------------------------------------------- auditing
    @property
    def audit_log(self) -> List[Dict[str, Any]]:
        return list(self._audit)

    def _record(self, decision: CommandDecision, executed: bool) -> None:
        self._audit.append(
            {
                "at": time.time(),
                "executed": executed,
                **decision.as_dict(),
            }
        )
        if len(self._audit) > self._audit_limit:
            del self._audit[: len(self._audit) - self._audit_limit]

    # -------------------------------------------------------------- publics
    def evaluate(self, command: str, context: SafetyContext) -> CommandDecision:
        """Decide what to do with ``command`` without running anything."""
        text = (command or "").strip()
        kind = classify(text)
        decision = CommandDecision(original=text, command=text, kind=kind, severity=Severity.OK)

        if not text:
            self._add(decision, "empty", Severity.BLOCKED, "Empty command")
            return decision

        # M112 is the one command that must never be gated on anything.
        if kind is CommandKind.EMERGENCY:
            return decision

        self._check_klippy(decision, context)
        # A shutdown Klipper cannot act on anything except a restart, so stop here.
        if decision.severity is Severity.BLOCKED and kind is not CommandKind.QUERY:
            return decision

        handler = {
            CommandKind.MOVEMENT: self._check_movement,
            CommandKind.HOMING: self._check_homing,
            CommandKind.PROBE: self._check_probe,
            CommandKind.PROBE_CALIBRATE: self._check_probe_calibrate,
            CommandKind.TESTZ: self._check_testz,
            CommandKind.ACCEPT_ABORT: self._check_accept_abort,
            CommandKind.BED_MESH: self._check_bed_mesh,
            CommandKind.SCREWS_TILT: self._check_screws_tilt,
            CommandKind.SAVE_CONFIG: self._check_save_config,
            CommandKind.TEMPERATURE: self._check_temperature,
            CommandKind.LIMITS: self._check_limits,
            CommandKind.RESONANCE: self._check_resonance,
        }.get(kind)

        if handler is not None:
            handler(decision, context)
        return decision

    async def execute(
        self,
        command: str,
        context: SafetyContext,
        *,
        force: bool = False,
    ) -> CommandDecision:
        """Evaluate and, if allowed, run. ``force`` downgrades warnings only -
        it can never override a block."""
        decision = self.evaluate(command, context)

        if not decision.allowed:
            self._record(decision, executed=False)
            raise SafetyBlocked(decision)

        if decision.severity is Severity.WARNING and not force:
            self._record(decision, executed=False)
            return decision

        if decision.requires_backup and self._on_backup is not None:
            await self._maybe_await(self._on_backup(decision.command))

        if self._runner is not None:
            await self._maybe_await(self._runner(decision.command))
            self._record(decision, executed=True)
        else:
            self._record(decision, executed=False)
        return decision

    async def execute_sequence(
        self,
        commands: Sequence[str],
        context: SafetyContext,
        *,
        force: bool = False,
    ) -> List[CommandDecision]:
        """Run commands in order, stopping at the first refusal.

        Used by the guided workflows: a later stage must never run when an
        earlier safety check failed.
        """
        results: List[CommandDecision] = []
        for command in commands:
            decision = await self.execute(command, context, force=force)
            results.append(decision)
            if not decision.allowed or (
                decision.severity is Severity.WARNING and not force
            ):
                break
        return results

    @staticmethod
    async def _maybe_await(value: Any) -> Any:
        if hasattr(value, "__await__"):
            return await value
        return value

    # ---------------------------------------------------------------- rules
    @staticmethod
    def _add(
        decision: CommandDecision,
        code: str,
        severity: Severity,
        message: str,
        detail: str = "",
        remedy: str = "",
    ) -> None:
        decision.issues.append(
            SafetyIssue(code=code, severity=severity, message=message, detail=detail, remedy=remedy)
        )
        order = {Severity.OK: 0, Severity.WARNING: 1, Severity.BLOCKED: 2}
        if order[severity] > order[decision.severity]:
            decision.severity = severity

    def _check_klippy(self, decision: CommandDecision, context: SafetyContext) -> None:
        if context.klippy_ready:
            return
        self._add(
            decision,
            "klippy_not_ready",
            Severity.BLOCKED,
            f"Klipper is not ready (state: {context.klippy_state}).",
            detail=context.klippy_message,
            remedy="Fix the reported Klipper error, then run FIRMWARE_RESTART.",
        )

    def _check_printing(self, decision: CommandDecision, context: SafetyContext, what: str) -> None:
        if context.printing and not context.paused:
            self._add(
                decision,
                "print_active",
                Severity.BLOCKED,
                f"A print is running - {what} is not allowed.",
                remedy="Pause or cancel the print first.",
            )

    # -- movement -----------------------------------------------------------
    def _check_movement(self, decision: CommandDecision, context: SafetyContext) -> None:
        self._check_printing(decision, context, "manual movement")
        words = parse_axis_words(decision.command)
        moved = {a: v for a, v in words.items() if a in {"X", "Y", "Z"}}

        for axis in moved:
            if not context.is_homed(axis):
                self._add(
                    decision,
                    "not_homed",
                    Severity.BLOCKED,
                    f"{axis} is not homed - the printer does not know where it is.",
                    remedy="Home the axis first.",
                )
                return

        if context.config is None:
            if moved:
                self._add(
                    decision,
                    "limits_unknown",
                    Severity.WARNING,
                    "Travel limits are unknown, so the move cannot be checked.",
                    remedy="Let the app read printer.cfg, then retry.",
                )
            return

        command = decision.command
        for axis, value in moved.items():
            limits = context.config.axis_limits(axis)
            if not limits.is_known:
                self._add(
                    decision,
                    "axis_limits_unknown",
                    Severity.WARNING,
                    f"No position_min/position_max for {axis} - not clamping.",
                )
                continue
            if not limits.contains(value):
                clamped = limits.clamp(value)
                command = _replace_axis(command, axis, clamped)
                decision.adjustments.append(
                    f"{axis}{value:g} clamped to {clamped:g} "
                    f"(limits {limits.position_min:g}..{limits.position_max:g})"
                )
                self._add(
                    decision,
                    "clamped",
                    Severity.WARNING,
                    f"{axis} target {value:g} is outside the configured travel.",
                    detail=f"Allowed {limits.position_min:g} to {limits.position_max:g} mm.",
                    remedy="The move was clamped to the configured limit.",
                )

        # Diagnostics move slowly. If a feedrate was given, cap it; if not, add one.
        feed = words.get("F")
        max_velocity = context.config.max_velocity
        cap = DIAGNOSTIC_FEEDRATE
        if max_velocity is not None:
            cap = min(cap, max_velocity * 60.0)
        if feed is None:
            command = f"{command} F{cap:.0f}"
            decision.adjustments.append(f"feedrate set to F{cap:.0f} for a diagnostic move")
        elif feed > cap:
            command = _replace_axis(command, "F", cap)
            decision.adjustments.append(f"feedrate F{feed:g} reduced to F{cap:.0f}")
            self._add(
                decision,
                "feedrate_capped",
                Severity.WARNING,
                "Requested feedrate is faster than this diagnostic move allows.",
            )

        decision.command = command

    # -- homing -------------------------------------------------------------
    def _check_homing(self, decision: CommandDecision, context: SafetyContext) -> None:
        self._check_printing(decision, context, "homing")
        # `G28 X Y` names axes with no values; `G28 Z0` gives one a value.
        # A bare `G28` homes everything, Z included.
        named = set(parse_bare_axes(decision.command))
        named.update(a for a in parse_axis_words(decision.command) if a in {"X", "Y", "Z"})
        axes = sorted(named) or ["X", "Y", "Z"]

        if "Z" not in axes:
            return

        # The rule that matters: never blindly home Z with a suspect probe.
        if context.probe_triggered is True:
            self._add(
                decision,
                "probe_already_triggered",
                Severity.BLOCKED,
                "The Z probe is already triggered before any movement.",
                detail=(
                    "Homing Z now would drive the nozzle into the bed, because Klipper "
                    "would immediately believe it had reached the trigger point."
                ),
                remedy=(
                    "Check the probe wiring and that nothing is holding the probe down, "
                    "then run QUERY_PROBE again."
                ),
            )
            return

        if context.probe_triggered is None and context.config is not None and context.config.has_probe:
            self._add(
                decision,
                "probe_state_unknown",
                Severity.WARNING,
                "The probe state has not been read, so homing Z cannot be verified as safe.",
                remedy="Run QUERY_PROBE first - the app does this automatically in the wizards.",
            )

        if (
            context.config is not None
            and context.config.has_probe
            and context.config.safe_z_home is None
            and not (context.is_homed("x") and context.is_homed("y"))
        ):
            self._add(
                decision,
                "no_safe_z_home",
                Severity.WARNING,
                "Z is being homed without safe_z_home and with X/Y not homed.",
                detail="The probe may be off the bed at the current position.",
                remedy="Home X and Y first, or add a [safe_z_home] section.",
            )

    # -- probe --------------------------------------------------------------
    def _check_probe(self, decision: CommandDecision, context: SafetyContext) -> None:
        self._check_printing(decision, context, "probing")
        if context.config is not None and not context.config.has_probe:
            self._add(
                decision,
                "no_probe",
                Severity.BLOCKED,
                "No probe is configured on this printer.",
                remedy="Add a [probe] or [bltouch] section, or use manual levelling.",
            )
            return
        if context.probe_triggered is True:
            self._add(
                decision,
                "probe_already_triggered",
                Severity.BLOCKED,
                "The probe is already triggered - probing would report a false result.",
                remedy="Clear the probe trigger, then retry.",
            )
        if not context.all_homed:
            self._add(
                decision,
                "must_home_before_probe",
                Severity.BLOCKED,
                "The printer must be homed before probing.",
                remedy="Run a safe G28 first.",
            )

    def _check_probe_calibrate(self, decision: CommandDecision, context: SafetyContext) -> None:
        self._check_probe(decision, context)
        if context.nozzle_temp > 80:
            self._add(
                decision,
                "hot_nozzle_calibration",
                Severity.WARNING,
                f"The nozzle is at {context.nozzle_temp:.0f} °C.",
                detail="Paper will scorch and the reading will drift as it cools.",
                remedy="Calibrate near printing temperature only if that is what you intend.",
            )

    # -- TESTZ --------------------------------------------------------------
    def _check_testz(self, decision: CommandDecision, context: SafetyContext) -> None:
        if context.calibration_session is None:
            self._add(
                decision,
                "no_calibration_session",
                Severity.BLOCKED,
                "TESTZ only works during a calibration session.",
                remedy="Start PROBE_CALIBRATE (or Z_ENDSTOP_CALIBRATE) first.",
            )
            return

        params = parse_named_params(decision.command)
        step = params.get("Z")
        if step is None:
            words = parse_axis_words(decision.command)
            step = words.get("Z")
        if step is None:
            # TESTZ Z=+ / Z=- are valid; they move by the current step size.
            return

        if abs(step) > MAX_TESTZ_STEP:
            clamped = MAX_TESTZ_STEP if step > 0 else -MAX_TESTZ_STEP
            decision.command = _replace_named(decision.command, "Z", clamped)
            decision.adjustments.append(f"TESTZ step {step:g} limited to {clamped:g} mm")
            self._add(
                decision,
                "testz_step_limited",
                Severity.WARNING,
                f"A {abs(step):g} mm step is too large for Z calibration.",
                detail=f"Limited to {MAX_TESTZ_STEP:g} mm.",
            )
            step = clamped

        if step < 0:
            total = context.testz_total_down + abs(step)
            if total > MAX_TESTZ_SESSION_DOWN:
                self._add(
                    decision,
                    "testz_travel_exhausted",
                    Severity.BLOCKED,
                    "This calibration session has already moved down too far.",
                    detail=(
                        f"{context.testz_total_down:.2f} mm of downward travel so far; "
                        f"the limit is {MAX_TESTZ_SESSION_DOWN:g} mm."
                    ),
                    remedy=(
                        "Abort and check the probe: needing this much travel usually means "
                        "the probe z_offset or the physical mount is wrong."
                    ),
                )

    def _check_accept_abort(self, decision: CommandDecision, context: SafetyContext) -> None:
        if context.calibration_session is None:
            self._add(
                decision,
                "no_calibration_session",
                Severity.BLOCKED,
                f"{command_word(decision.command)} has no calibration session to act on.",
            )

    # -- bed --------------------------------------------------------------
    def _check_bed_mesh(self, decision: CommandDecision, context: SafetyContext) -> None:
        word = command_word(decision.command)
        if word in {"BED_MESH_PROFILE", "BED_MESH_CLEAR"}:
            return
        self._check_printing(decision, context, "a bed mesh")
        if context.config is not None and not context.config.has_bed_mesh:
            self._add(
                decision,
                "no_bed_mesh_section",
                Severity.BLOCKED,
                "No [bed_mesh] section is configured.",
                remedy="Add [bed_mesh] to printer.cfg.",
            )
        if not context.all_homed:
            self._add(
                decision,
                "must_home_first",
                Severity.BLOCKED,
                "The printer must be homed before meshing.",
                remedy="Run a safe G28 first.",
            )

    def _check_screws_tilt(self, decision: CommandDecision, context: SafetyContext) -> None:
        self._check_printing(decision, context, "screw tilt measurement")
        if context.config is not None and not context.config.has_screws_tilt:
            self._add(
                decision,
                "no_screws_tilt_section",
                Severity.BLOCKED,
                "No [screws_tilt_adjust] section is configured.",
                remedy="Add [screws_tilt_adjust] with your bed screw positions.",
            )
        if not context.all_homed:
            self._add(
                decision,
                "must_home_first",
                Severity.BLOCKED,
                "The printer must be homed before measuring bed screws.",
                remedy="Run a safe G28 first.",
            )

    # -- config -------------------------------------------------------------
    def _check_save_config(self, decision: CommandDecision, context: SafetyContext) -> None:
        decision.requires_backup = True
        self._check_printing(decision, context, "SAVE_CONFIG")
        self._add(
            decision,
            "save_config_restarts",
            Severity.WARNING,
            "SAVE_CONFIG rewrites printer.cfg and restarts Klipper.",
            detail="A backup is taken automatically before it runs.",
        )

    # -- heaters, limits, resonance ----------------------------------------
    def _check_temperature(self, decision: CommandDecision, context: SafetyContext) -> None:
        words = parse_axis_words(decision.command)
        params = parse_named_params(decision.command)
        target = words.get("S", params.get("TARGET"))
        if target is None:
            return
        word = command_word(decision.command)
        is_bed = word in {"M140", "M190"} or "bed" in decision.command.lower()
        ceiling = 130.0 if is_bed else 300.0
        if target > ceiling:
            self._add(
                decision,
                "temperature_too_high",
                Severity.BLOCKED,
                f"{target:.0f} °C is above the safe ceiling for this heater.",
                detail=f"The app refuses targets above {ceiling:.0f} °C.",
            )

    def _check_limits(self, decision: CommandDecision, context: SafetyContext) -> None:
        if context.config is None:
            return
        params = parse_named_params(decision.command)
        words = parse_axis_words(decision.command)

        max_velocity = context.config.max_velocity
        max_accel = context.config.max_accel

        requested_velocity = params.get("VELOCITY")
        if requested_velocity is not None and max_velocity is not None and requested_velocity > max_velocity:
            self._add(
                decision,
                "velocity_above_config",
                Severity.WARNING,
                f"Requested velocity {requested_velocity:g} exceeds printer.cfg max_velocity "
                f"({max_velocity:g}).",
                detail="Klipper will clamp it; the app is telling you rather than hiding it.",
            )

        requested_accel = params.get("ACCEL", words.get("S") if command_word(decision.command) == "M204" else None)
        if requested_accel is not None and max_accel is not None and requested_accel > max_accel:
            self._add(
                decision,
                "accel_above_config",
                Severity.WARNING,
                f"Requested acceleration {requested_accel:g} exceeds printer.cfg max_accel "
                f"({max_accel:g}).",
            )

    def _check_resonance(self, decision: CommandDecision, context: SafetyContext) -> None:
        self._check_printing(decision, context, "a resonance test")
        if context.config is not None and not context.config.has_accelerometer:
            self._add(
                decision,
                "no_accelerometer",
                Severity.BLOCKED,
                "No accelerometer is configured.",
                detail="TEST_RESONANCES and SHAPER_CALIBRATE need an ADXL345 or similar.",
                remedy="Install and configure the accelerometer first.",
            )
        if command_word(decision.command) != "ACCELEROMETER_QUERY" and not context.all_homed:
            self._add(
                decision,
                "must_home_first",
                Severity.BLOCKED,
                "The printer must be homed before a resonance test.",
                remedy="Run a safe G28 first.",
            )


# --------------------------------------------------------------------------- #
# Command rewriting helpers
# --------------------------------------------------------------------------- #


def _replace_axis(command: str, axis: str, value: float) -> str:
    """Replace ``X12.5`` style words, preserving everything else verbatim."""
    pattern = re.compile(rf"(?<![A-Za-z0-9_])({axis})\s*(-?\d+(?:\.\d+)?)", re.IGNORECASE)
    replacement = f"{axis.upper()}{_format_number(value)}"
    result, count = pattern.subn(replacement, command, count=1)
    return result if count else f"{command} {replacement}"


def _replace_named(command: str, key: str, value: float) -> str:
    """Replace ``Z=-0.05`` style parameters."""
    pattern = re.compile(rf"(?<![A-Za-z0-9_])({key})\s*=\s*(-?\d+(?:\.\d+)?)", re.IGNORECASE)
    replacement = f"{key.upper()}={_format_number(value)}"
    result, count = pattern.subn(replacement, command, count=1)
    return result if count else f"{command} {replacement}"


def _format_number(value: float) -> str:
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return text if text and text not in {"-", ""} else "0"
