"""Static analysis of a sliced G-code file, before it is allowed to print.

The hard rule this module exists to enforce: **this project never invents,
regenerates, reorders, optimises or modifies a toolpath.** Nothing here writes
G-code. Every function reads, measures and reports.

What it checks:

* every X/Y/Z coordinate against the **live** ``printer.cfg`` limits,
* positioning modes (G90/G91) and extrusion modes (M82/M83),
* requested acceleration and velocity (M204, M205, SET_VELOCITY_LIMIT),
* commands Klipper does not implement (M413 and friends),
* which slicer produced the file, and against which profile.

The verdict is one of SAFE / WARNING / BLOCKED, and a validation failure is
never silently ignored.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

from ..klipper.model import ParsedConfig


class GCodeVerdict(str, Enum):
    SAFE = "safe"
    WARNING = "warning"
    BLOCKED = "blocked"


#: Marlin commands that Klipper does not implement. Klipper errors on an unknown
#: command mid-print, which aborts the job - so these are worth catching first.
#: The value is the human explanation shown in the app.
UNSUPPORTED_COMMANDS: Dict[str, str] = {
    "M413": "Marlin power-loss recovery. Klipper does not implement it; use [save_variables] or a plugin.",
    "M420": "Marlin bed levelling state. Klipper uses BED_MESH_PROFILE instead.",
    "M900": "Marlin linear advance. Klipper uses SET_PRESSURE_ADVANCE.",
    "M851": "Marlin Z probe offset. Klipper stores this in the [probe] section.",
    "M600": "Filament change. Only works if you have defined an M600 macro.",
    "M0": "Marlin unconditional stop. Klipper needs a macro for this.",
    "M1": "Marlin conditional stop. Klipper needs a macro for this.",
    "M80": "ATX power on. Requires [power] or a macro in Klipper.",
    "M81": "ATX power off. Requires [power] or a macro in Klipper.",
    "M108": "Marlin heater interrupt. Not implemented by Klipper.",
    "M301": "Marlin hotend PID. Klipper stores PID in printer.cfg.",
    "M304": "Marlin bed PID. Klipper stores PID in printer.cfg.",
    "M500": "Marlin save settings. Klipper uses SAVE_CONFIG.",
    "M501": "Marlin load settings. Not applicable to Klipper.",
    "M502": "Marlin factory reset. Not applicable to Klipper.",
    "G29": "Marlin auto bed levelling. Klipper uses BED_MESH_CALIBRATE.",
}

#: Commands Klipper does implement that people expect to be missing.
KNOWN_SUPPORTED = {
    "G0", "G1", "G2", "G3", "G4", "G10", "G11", "G20", "G21", "G28", "G90", "G91", "G92",
    "M17", "M18", "M82", "M83", "M84", "M104", "M105", "M106", "M107", "M109", "M112",
    "M114", "M115", "M117", "M118", "M119", "M140", "M141", "M190", "M191", "M204", "M205",
    "M220", "M221", "M400", "M486",
}

_LINE_RE = re.compile(r"^\s*([GM]\d+|[A-Z_][A-Z0-9_]*)", re.IGNORECASE)
_WORD_RE = re.compile(r"(?<![A-Za-z0-9_])([XYZEFS])\s*(-?\d+(?:\.\d+)?)", re.IGNORECASE)
_PARAM_RE = re.compile(r"(?<![A-Za-z0-9_])([A-Za-z_]+)\s*=\s*(-?\d+(?:\.\d+)?)")

#: Slicer signatures found in the header comments.
_SLICER_PATTERNS: List[Tuple[str, re.Pattern[str]]] = [
    ("PrusaSlicer", re.compile(r"prusaslicer\s*([0-9][\w.+-]*)?", re.IGNORECASE)),
    ("SuperSlicer", re.compile(r"superslicer\s*([0-9][\w.+-]*)?", re.IGNORECASE)),
    ("OrcaSlicer", re.compile(r"orcaslicer\s*([0-9][\w.+-]*)?", re.IGNORECASE)),
    ("Cura", re.compile(r"(?:generated with )?cura[_\s]*(?:steamengine\s*)?([0-9][\w.+-]*)?", re.IGNORECASE)),
    ("Simplify3D", re.compile(r"simplify3d\s*(?:\(r\))?\s*(?:version\s*)?([0-9][\w.+-]*)?", re.IGNORECASE)),
    ("Bambu Studio", re.compile(r"bambustudio\s*([0-9][\w.+-]*)?", re.IGNORECASE)),
    ("ideaMaker", re.compile(r"ideamaker\s*([0-9][\w.+-]*)?", re.IGNORECASE)),
]


@dataclass
class GCodeIssue:
    code: str
    severity: str          # info | warning | error
    message: str
    detail: str = ""
    remedy: str = ""
    line: Optional[int] = None
    sample: str = ""

    def as_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "severity": self.severity,
            "message": self.message,
            "detail": self.detail,
            "remedy": self.remedy,
            "line": self.line,
            "sample": self.sample,
        }


@dataclass
class GCodeBounds:
    min_x: Optional[float] = None
    max_x: Optional[float] = None
    min_y: Optional[float] = None
    max_y: Optional[float] = None
    min_z: Optional[float] = None
    max_z: Optional[float] = None

    def observe(self, axis: str, value: float) -> None:
        low = getattr(self, f"min_{axis}")
        high = getattr(self, f"max_{axis}")
        if low is None or value < low:
            setattr(self, f"min_{axis}", value)
        if high is None or value > high:
            setattr(self, f"max_{axis}", value)

    def as_dict(self) -> Dict[str, Any]:
        return {
            "min_x": self.min_x, "max_x": self.max_x,
            "min_y": self.min_y, "max_y": self.max_y,
            "min_z": self.min_z, "max_z": self.max_z,
        }


@dataclass
class GCodeReport:
    verdict: GCodeVerdict = GCodeVerdict.SAFE
    issues: List[GCodeIssue] = field(default_factory=list)

    slicer: str = ""
    slicer_version: str = ""
    profile_name: str = ""
    filament: str = ""
    verified_profile: bool = False   # produced by an approved (Golden) profile
    profile_status: str = "unverified"   # golden | known | unverified

    bounds: GCodeBounds = field(default_factory=GCodeBounds)
    estimated_seconds: Optional[float] = None
    filament_mm: Optional[float] = None
    layer_height: Optional[float] = None
    first_layer_height: Optional[float] = None
    nozzle_diameter: Optional[float] = None
    layer_count: Optional[int] = None

    max_requested_feedrate: Optional[float] = None   # mm/min
    max_requested_accel: Optional[float] = None      # mm/s^2
    max_square_corner_velocity: Optional[float] = None

    positioning_absolute: Optional[bool] = None
    extrusion_relative: Optional[bool] = None
    has_home: bool = False
    has_bed_mesh_command: bool = False
    sets_hotend_temp: bool = False
    sets_bed_temp: bool = False

    unsupported: List[Dict[str, Any]] = field(default_factory=list)
    lines_scanned: int = 0
    truncated: bool = False

    # ------------------------------------------------------------------ api
    @property
    def blocked(self) -> bool:
        return self.verdict is GCodeVerdict.BLOCKED

    @property
    def errors(self) -> List[GCodeIssue]:
        return [i for i in self.issues if i.severity == "error"]

    @property
    def warnings(self) -> List[GCodeIssue]:
        return [i for i in self.issues if i.severity == "warning"]

    def add(
        self,
        code: str,
        severity: str,
        message: str,
        **kwargs: Any,
    ) -> None:
        self.issues.append(GCodeIssue(code=code, severity=severity, message=message, **kwargs))
        if severity == "error":
            self.verdict = GCodeVerdict.BLOCKED
        elif severity == "warning" and self.verdict is GCodeVerdict.SAFE:
            self.verdict = GCodeVerdict.WARNING

    def as_dict(self) -> Dict[str, Any]:
        return {
            "verdict": self.verdict.value,
            "blocked": self.blocked,
            "error_count": len(self.errors),
            "warning_count": len(self.warnings),
            "issues": [i.as_dict() for i in self.issues],
            "slicer": self.slicer,
            "slicer_version": self.slicer_version,
            "profile_name": self.profile_name,
            "filament": self.filament,
            "verified_profile": self.verified_profile,
            "profile_status": self.profile_status,
            "bounds": self.bounds.as_dict(),
            "estimated_seconds": self.estimated_seconds,
            "filament_mm": self.filament_mm,
            "layer_height": self.layer_height,
            "first_layer_height": self.first_layer_height,
            "nozzle_diameter": self.nozzle_diameter,
            "layer_count": self.layer_count,
            "max_requested_feedrate": self.max_requested_feedrate,
            "max_requested_accel": self.max_requested_accel,
            "max_square_corner_velocity": self.max_square_corner_velocity,
            "positioning_absolute": self.positioning_absolute,
            "extrusion_relative": self.extrusion_relative,
            "has_home": self.has_home,
            "has_bed_mesh_command": self.has_bed_mesh_command,
            "sets_hotend_temp": self.sets_hotend_temp,
            "sets_bed_temp": self.sets_bed_temp,
            "unsupported": list(self.unsupported),
            "lines_scanned": self.lines_scanned,
            "truncated": self.truncated,
        }


# --------------------------------------------------------------------------- #
# Header metadata
# --------------------------------------------------------------------------- #


def _parse_header(lines: Iterable[str], report: GCodeReport) -> None:
    """Slicer identity and settings live in comments, in several dialects."""
    for raw in lines:
        line = raw.strip()
        if not line.startswith(";"):
            continue
        body = line.lstrip("; ").strip()
        lowered = body.lower()

        if not report.slicer:
            for name, pattern in _SLICER_PATTERNS:
                match = pattern.search(body)
                if match:
                    report.slicer = name
                    report.slicer_version = (match.group(1) or "").strip()
                    break

        for key, setter in (
            ("layer_height", "layer_height"),
            ("first_layer_height", "first_layer_height"),
            ("nozzle_diameter", "nozzle_diameter"),
        ):
            if lowered.startswith(f"{key} =") or lowered.startswith(f"{key}="):
                value = body.split("=", 1)[1].strip().split(",")[0]
                try:
                    setattr(report, setter, float(value))
                except ValueError:
                    pass

        if lowered.startswith("print_settings_id"):
            report.profile_name = body.split("=", 1)[1].strip() if "=" in body else ""
        elif lowered.startswith("filament_settings_id"):
            report.filament = body.split("=", 1)[1].strip() if "=" in body else ""
        elif lowered.startswith("filament_type") and not report.filament:
            report.filament = body.split("=", 1)[1].strip() if "=" in body else ""


# --------------------------------------------------------------------------- #
# Main analysis
# --------------------------------------------------------------------------- #


def analyse_gcode(
    text: str,
    *,
    config: Optional[ParsedConfig] = None,
    golden_profiles: Optional[Iterable[str]] = None,
    max_lines: int = 400_000,
) -> GCodeReport:
    """Scan ``text`` and produce a verdict. Reads only; never rewrites."""
    report = GCodeReport()
    lines = text.splitlines()
    if len(lines) > max_lines:
        report.truncated = True

    _parse_header(lines[:400], report)
    _parse_header(lines[-400:], report)

    absolute_positioning: Optional[bool] = None
    relative_extrusion: Optional[bool] = None
    position: Dict[str, Optional[float]] = {"x": None, "y": None, "z": None}
    offset: Dict[str, float] = {"x": 0.0, "y": 0.0, "z": 0.0}
    seen_unsupported: Dict[str, GCodeIssue] = {}

    for index, raw in enumerate(lines[:max_lines], start=1):
        report.lines_scanned = index
        line = raw.split(";", 1)[0].strip()
        if not line:
            continue

        match = _LINE_RE.match(line)
        if not match:
            continue
        word = match.group(1).upper()

        # -- unsupported ----------------------------------------------------
        if word in UNSUPPORTED_COMMANDS:
            if word not in seen_unsupported:
                issue = GCodeIssue(
                    code="unsupported_command",
                    severity="warning",
                    message=f"{word} is not supported by Klipper.",
                    detail=UNSUPPORTED_COMMANDS[word],
                    remedy=(
                        "Remove it from the slicer's custom G-code, or define a macro "
                        "with that name in printer.cfg."
                    ),
                    line=index,
                    sample=line,
                )
                seen_unsupported[word] = issue
                report.issues.append(issue)
                if report.verdict is GCodeVerdict.SAFE:
                    report.verdict = GCodeVerdict.WARNING
                report.unsupported.append(
                    {"command": word, "line": index, "reason": UNSUPPORTED_COMMANDS[word]}
                )
            continue

        # -- modes ----------------------------------------------------------
        if word == "G90":
            absolute_positioning = True
            if report.positioning_absolute is None:
                report.positioning_absolute = True
            continue
        if word == "G91":
            absolute_positioning = False
            report.positioning_absolute = False
            continue
        if word == "M82":
            relative_extrusion = False
            if report.extrusion_relative is None:
                report.extrusion_relative = False
            continue
        if word == "M83":
            relative_extrusion = True
            if report.extrusion_relative is None:
                report.extrusion_relative = True
            continue
        if word == "G28":
            report.has_home = True
            for axis in ("x", "y", "z"):
                position[axis] = None
                offset[axis] = 0.0
            continue
        if word == "G92":
            words = _words(line)
            for axis in ("x", "y", "z"):
                if axis.upper() in words and position[axis] is not None:
                    # G92 redefines the origin: remember the shift so later
                    # coordinates are still compared against real machine space.
                    offset[axis] += position[axis] - words[axis.upper()]
                    position[axis] = words[axis.upper()]
            continue
        if word in {"M104", "M109"}:
            report.sets_hotend_temp = True
            continue
        if word in {"M140", "M190"}:
            report.sets_bed_temp = True
            continue
        if word.startswith("BED_MESH"):
            report.has_bed_mesh_command = True
            continue

        # -- limits ---------------------------------------------------------
        if word == "M204":
            words = _words(line)
            for key in ("S", "P", "T"):
                value = words.get(key)
                if value is not None:
                    report.max_requested_accel = max(report.max_requested_accel or 0.0, value)
            continue
        if word == "M205":
            words = _words(line)
            for key in ("X", "Y"):
                value = words.get(key)
                if value is not None:
                    report.max_square_corner_velocity = max(
                        report.max_square_corner_velocity or 0.0, value
                    )
            continue
        if word == "SET_VELOCITY_LIMIT":
            params = {k.upper(): v for k, v in _PARAM_RE.findall(line)}
            accel = params.get("ACCEL")
            velocity = params.get("VELOCITY")
            scv = params.get("SQUARE_CORNER_VELOCITY")
            if accel is not None:
                report.max_requested_accel = max(report.max_requested_accel or 0.0, float(accel))
            if velocity is not None:
                report.max_requested_feedrate = max(
                    report.max_requested_feedrate or 0.0, float(velocity) * 60.0
                )
            if scv is not None:
                report.max_square_corner_velocity = max(
                    report.max_square_corner_velocity or 0.0, float(scv)
                )
            continue

        # -- motion ---------------------------------------------------------
        if word in {"G0", "G1", "G2", "G3"}:
            words = _words(line)
            feed = words.get("F")
            if feed is not None:
                report.max_requested_feedrate = max(report.max_requested_feedrate or 0.0, feed)

            for axis in ("x", "y", "z"):
                value = words.get(axis.upper())
                if value is None:
                    continue
                if absolute_positioning is False and position[axis] is not None:
                    absolute = position[axis] + value
                else:
                    absolute = value
                position[axis] = absolute
                report.bounds.observe(axis, absolute + offset[axis])
            continue

    _finalise(report, config, golden_profiles)
    return report


def _words(line: str) -> Dict[str, float]:
    return {letter.upper(): float(value) for letter, value in _WORD_RE.findall(line)}


def _finalise(
    report: GCodeReport,
    config: Optional[ParsedConfig],
    golden_profiles: Optional[Iterable[str]],
) -> None:
    """Turn the raw measurements into findings."""

    # -- slicer provenance --------------------------------------------------
    approved = {p.strip().lower() for p in (golden_profiles or []) if p.strip()}
    profile_key = (report.profile_name or "").strip().lower()

    if profile_key and profile_key in approved:
        report.verified_profile = True
        report.profile_status = "golden"
    elif report.slicer == "PrusaSlicer":
        report.profile_status = "known"
    else:
        report.profile_status = "unverified"

    if not report.slicer:
        report.add(
            "unknown_slicer",
            "warning",
            "UNVERIFIED G-CODE: the slicer that produced this file could not be identified.",
            detail="No recognised slicer signature was found in the header comments.",
            remedy="Slice with the approved PrusaSlicer profile for this printer.",
        )
    elif report.slicer != "PrusaSlicer":
        report.add(
            "non_prusaslicer",
            "warning",
            f"UNVERIFIED G-CODE: produced by {report.slicer}, not the approved PrusaSlicer profile.",
            detail=(
                "Incorrect print positioning has been traced to G-code from a mismatched "
                "slicer profile on this printer before."
            ),
            remedy="Re-slice with the Neptune 3 Plus PrusaSlicer profile before printing.",
        )
    elif not report.verified_profile and approved:
        report.add(
            "unverified_profile",
            "warning",
            f"UNVERIFIED G-CODE: PrusaSlicer profile '{report.profile_name or 'unknown'}' "
            "is not the approved Golden profile.",
            remedy="Re-slice with the Golden profile, or mark this profile as known-good.",
        )

    # -- positioning modes --------------------------------------------------
    if report.positioning_absolute is None:
        report.add(
            "no_positioning_mode",
            "error",
            "The file never sets G90 or G91.",
            detail="Klipper keeps whatever mode was left over from the previous job.",
            remedy="Add G90 to the slicer's start G-code.",
        )
    elif report.positioning_absolute is False:
        report.add(
            "relative_positioning",
            "warning",
            "The file leaves the printer in relative positioning (G91).",
            detail="Relative moves are legal but unusual for a whole print.",
        )

    if report.extrusion_relative is None:
        report.add(
            "no_extrusion_mode",
            "warning",
            "The file never sets M82 or M83.",
            detail="Extrusion mode is inherited from the previous job.",
            remedy="Add M83 (or M82) to the slicer's start G-code.",
        )

    if not report.has_home:
        report.add(
            "no_homing",
            "error",
            "The file never homes the printer (no G28).",
            detail=(
                "Without homing, Klipper prints relative to wherever it currently believes "
                "the toolhead is - which is exactly how a print ends up in the wrong place."
            ),
            remedy="Add G28 to the slicer's start G-code.",
        )

    if not report.sets_hotend_temp:
        report.add(
            "no_hotend_temperature",
            "warning",
            "The file never sets a hotend temperature.",
            remedy="Check the slicer's start G-code.",
        )

    # -- geometry against the LIVE config -----------------------------------
    if config is None:
        report.add(
            "limits_unknown",
            "warning",
            "Live printer limits are unavailable, so the build volume was not checked.",
            remedy="Connect to the printer and retry.",
        )
    else:
        for axis in ("x", "y", "z"):
            low = getattr(report.bounds, f"min_{axis}")
            high = getattr(report.bounds, f"max_{axis}")
            if low is None or high is None:
                continue
            limits = config.axis_limits(axis)
            if not limits.is_known:
                continue
            if limits.position_min is not None and low < limits.position_min - 0.5:
                report.add(
                    "outside_build_volume",
                    "error",
                    f"{axis.upper()} goes to {low:.2f} mm, below the machine minimum of "
                    f"{limits.position_min:g} mm.",
                    detail="Klipper aborts the print with 'Move out of range'.",
                    remedy="Re-slice with the correct printer profile, or move the model on the plate.",
                )
            if limits.position_max is not None and high > limits.position_max + 0.5:
                report.add(
                    "outside_build_volume",
                    "error",
                    f"{axis.upper()} goes to {high:.2f} mm, beyond the machine maximum of "
                    f"{limits.position_max:g} mm.",
                    detail="Klipper aborts the print with 'Move out of range'.",
                    remedy="Re-slice with the correct printer profile, or move the model on the plate.",
                )

        # -- motion limits --------------------------------------------------
        max_accel = config.max_accel
        if (
            report.max_requested_accel is not None
            and max_accel is not None
            and report.max_requested_accel > max_accel
        ):
            report.add(
                "accel_above_printer",
                "warning",
                f"The file asks for {report.max_requested_accel:g} mm/s² acceleration, above "
                f"printer.cfg max_accel ({max_accel:g}).",
                detail=(
                    "Klipper clamps it, so nothing unsafe happens - but the print will not "
                    "behave the way the slicer estimated."
                ),
                remedy="Align the slicer profile with the printer's approved motion limits.",
            )

        max_velocity = config.max_velocity
        if (
            report.max_requested_feedrate is not None
            and max_velocity is not None
            and report.max_requested_feedrate > max_velocity * 60.0
        ):
            report.add(
                "feedrate_above_printer",
                "warning",
                f"The file asks for F{report.max_requested_feedrate:.0f} "
                f"({report.max_requested_feedrate / 60.0:.0f} mm/s), above printer.cfg "
                f"max_velocity ({max_velocity:g} mm/s).",
                detail="Klipper clamps it.",
            )

        # -- nozzle ---------------------------------------------------------
        extruder = config.section("extruder")
        configured_nozzle = extruder.get_float("nozzle_diameter") if extruder else None
        if (
            report.nozzle_diameter is not None
            and configured_nozzle is not None
            and abs(report.nozzle_diameter - configured_nozzle) > 0.01
        ):
            report.add(
                "nozzle_mismatch",
                "warning",
                f"The file was sliced for a {report.nozzle_diameter:g} mm nozzle, but the "
                f"printer is configured for {configured_nozzle:g} mm.",
                remedy="Change the nozzle, or re-slice with the matching profile.",
            )

    if report.bounds.max_x is None and report.bounds.max_y is None:
        report.add(
            "no_motion",
            "error",
            "The file contains no movement commands.",
            detail="Nothing would print.",
        )


def analyse_gcode_file(
    path: Path | str,
    *,
    config: Optional[ParsedConfig] = None,
    golden_profiles: Optional[Iterable[str]] = None,
) -> GCodeReport:
    file_path = Path(path)
    if not file_path.is_file():
        report = GCodeReport()
        report.add("missing_file", "error", f"G-code file not found: {file_path.name}")
        return report
    text = file_path.read_text(encoding="utf-8", errors="replace")
    return analyse_gcode(text, config=config, golden_profiles=golden_profiles)
