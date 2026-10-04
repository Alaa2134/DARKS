"""Static validation of a ``printer.cfg`` before it is saved or trusted.

Two jobs:

* **Structural** - duplicate sections, unparseable values, contradictory limits,
  missing required fields. These apply to any Klipper printer.
* **Model** - does this config describe the printer profile the user selected?
  A Neptune 3 Plus with ``position_max: 220`` is almost certainly a config from
  a different machine, and printing with it is how you crash a gantry.

The model checks *advise*; they never rewrite the config. The live config is
always the authority for what the machine will actually do.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .model import ParsedConfig, parse_config

SEVERITY_ORDER = {"info": 0, "warning": 1, "error": 2}


@dataclass
class ValidationFinding:
    code: str
    severity: str            # info | warning | error
    section: str
    message: str
    detail: str = ""
    remedy: str = ""
    line: Optional[int] = None

    def as_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "severity": self.severity,
            "section": self.section,
            "message": self.message,
            "detail": self.detail,
            "remedy": self.remedy,
            "line": self.line,
        }


@dataclass
class ValidationResult:
    findings: List[ValidationFinding] = field(default_factory=list)

    @property
    def errors(self) -> List[ValidationFinding]:
        return [f for f in self.findings if f.severity == "error"]

    @property
    def warnings(self) -> List[ValidationFinding]:
        return [f for f in self.findings if f.severity == "warning"]

    @property
    def ok(self) -> bool:
        return not self.errors

    @property
    def verdict(self) -> str:
        if self.errors:
            return "blocked"
        if self.warnings:
            return "warning"
        return "ok"

    def as_dict(self) -> Dict[str, Any]:
        return {
            "verdict": self.verdict,
            "ok": self.ok,
            "error_count": len(self.errors),
            "warning_count": len(self.warnings),
            "findings": [f.as_dict() for f in self.findings],
        }


@dataclass
class PrinterModelProfile:
    """Expected geometry for a known printer, used to *advise* on a config."""

    id: str
    name: str
    #: Usable print area, mm.
    build_x: float
    build_y: float
    build_z: float
    #: Machine travel, which is normally slightly larger than the print area.
    travel_x: float
    travel_y: float
    travel_z: float
    #: Acceleration above which this frame is likely to skip steps.
    recommended_max_accel: float
    #: Bed-slinger frames are far more sensitive on the Y axis.
    moving_bed_axis: Optional[str] = None
    tolerance: float = 0.12   # 12 % before a mismatch is reported

    def within(self, actual: Optional[float], expected: float) -> bool:
        if actual is None:
            return True
        return abs(actual - expected) <= expected * self.tolerance


#: The printer this project was built for. Values are compared against the live
#: config; they never replace it.
NEPTUNE_3_PLUS = PrinterModelProfile(
    id="neptune3plus",
    name="ELEGOO Neptune 3 Plus",
    build_x=320.0,
    build_y=320.0,
    build_z=400.0,
    travel_x=330.0,
    travel_y=330.0,
    travel_z=410.0,
    recommended_max_accel=3000.0,
    moving_bed_axis="Y",
)

PROFILES: Dict[str, PrinterModelProfile] = {NEPTUNE_3_PLUS.id: NEPTUNE_3_PLUS}


def validate(
    config: ParsedConfig | str,
    *,
    profile: Optional[PrinterModelProfile] = None,
) -> ValidationResult:
    parsed = parse_config(config) if isinstance(config, str) else config
    result = ValidationResult()

    def add(code: str, severity: str, section: str, message: str, **kwargs: Any) -> None:
        result.findings.append(
            ValidationFinding(code=code, severity=severity, section=section, message=message, **kwargs)
        )

    # ------------------------------------------------------------ structural
    for error in parsed.parse_errors:
        add("parse_error", "error", "", f"Could not parse the config: {error}")

    seen: Dict[str, int] = {}
    for section in parsed.sections:
        key = section.raw_name.lower()
        if key in seen:
            add(
                "duplicate_section",
                "error",
                section.raw_name,
                f"[{section.raw_name}] is defined more than once.",
                detail=f"First at line {seen[key]}, again at line {section.line}.",
                remedy="Klipper uses the last one. Delete the duplicate.",
                line=section.line,
            )
        else:
            seen[key] = section.line

    if not parsed.has("printer"):
        add(
            "missing_printer",
            "error",
            "printer",
            "There is no [printer] section.",
            remedy="Klipper cannot start without it.",
        )
    elif parsed.kinematics is None:
        add("missing_kinematics", "error", "printer", "[printer] has no kinematics.")

    for axis in ("x", "y", "z"):
        name = f"stepper_{axis}"
        section = parsed.section(name)
        if section is None:
            add("missing_stepper", "error", name, f"There is no [{name}] section.")
            continue

        limits = parsed.axis_limits(axis)
        if limits.position_max is None:
            add("missing_position_max", "error", name, f"[{name}] has no position_max.")
        if (
            limits.position_min is not None
            and limits.position_max is not None
            and limits.position_min >= limits.position_max
        ):
            add(
                "inverted_limits",
                "error",
                name,
                f"[{name}] position_min ({limits.position_min:g}) is not below "
                f"position_max ({limits.position_max:g}).",
                remedy="Swap or correct the two values.",
                line=section.option_lines.get("position_min"),
            )

        endstop = limits.position_endstop
        if endstop is not None and limits.position_min is not None and limits.position_max is not None:
            if not (limits.position_min <= endstop <= limits.position_max):
                add(
                    "endstop_outside_limits",
                    "error",
                    name,
                    f"position_endstop ({endstop:g}) is outside "
                    f"position_min..position_max ({limits.position_min:g}..{limits.position_max:g}).",
                    detail="Klipper refuses to start with this combination.",
                    remedy="Move position_endstop inside the travel, or widen the limits.",
                    line=section.option_lines.get("position_endstop"),
                )

    # -------------------------------------------------------------- probe
    probe = parsed.probe_section
    if probe is not None:
        z_offset = parsed.effective_probe_z_offset
        if z_offset is None:
            add(
                "probe_z_offset_missing",
                "warning",
                probe.raw_name,
                "The probe has no z_offset yet.",
                detail="Klipper's stored probe z_offset is a positive distance from nozzle to trigger point.",
                remedy="Run the Z Offset wizard.",
            )
        elif z_offset <= 0:
            add(
                "probe_z_offset_suspicious",
                "warning",
                probe.raw_name,
                f"probe z_offset is {z_offset:g}, which is unusual.",
                detail=(
                    "For an inductive or BLTouch probe this value is normally positive: it is "
                    "how far below the trigger point the nozzle sits."
                ),
                remedy="Re-run the Z Offset wizard unless you know this is right for your probe.",
            )
        elif z_offset > 10:
            add(
                "probe_z_offset_large",
                "warning",
                probe.raw_name,
                f"probe z_offset of {z_offset:g} mm is very large.",
                remedy="Check the probe mount height.",
            )

        if parsed.safe_z_home is None and not parsed.has("homing_override"):
            add(
                "no_safe_z_home",
                "warning",
                "safe_z_home",
                "A probe is configured but there is no [safe_z_home].",
                detail="Z homing may run with the probe off the bed.",
                remedy="Add [safe_z_home] with home_xy_position near the bed centre.",
            )

    if not parsed.has_bed_mesh:
        add(
            "no_bed_mesh",
            "info",
            "bed_mesh",
            "No [bed_mesh] section, so mesh levelling is unavailable.",
        )

    # ------------------------------------------------------------- printer
    max_accel = parsed.max_accel
    max_velocity = parsed.max_velocity
    if max_accel is None:
        add("missing_max_accel", "warning", "printer", "[printer] has no max_accel.")
    if max_velocity is None:
        add("missing_max_velocity", "warning", "printer", "[printer] has no max_velocity.")

    # ------------------------------------------------------------- profile
    if profile is not None:
        _validate_against_profile(parsed, profile, add)

    return result


def _validate_against_profile(parsed: ParsedConfig, profile: PrinterModelProfile, add: Any) -> None:
    """Compare the live config to the expected machine, advising only."""
    axes = {
        "x": (profile.travel_x, profile.build_x),
        "y": (profile.travel_y, profile.build_y),
        "z": (profile.travel_z, profile.build_z),
    }
    for axis, (travel, build) in axes.items():
        limits = parsed.axis_limits(axis)
        if limits.position_max is None:
            continue
        # Either the print area or the machine travel is a plausible position_max.
        if profile.within(limits.position_max, travel) or profile.within(limits.position_max, build):
            continue
        add(
            "geometry_mismatch",
            "warning",
            f"stepper_{axis}",
            f"{axis.upper()} position_max is {limits.position_max:g} mm, but a "
            f"{profile.name} is about {build:g} mm ({travel:g} mm of travel).",
            detail="A config from a different printer model is the usual cause.",
            remedy=(
                "Check that this printer.cfg belongs to this machine. "
                "If your printer really is modified, ignore this."
            ),
        )

    max_accel = parsed.max_accel
    if max_accel is not None and max_accel > profile.recommended_max_accel:
        detail = (
            f"{profile.moving_bed_axis} carries the moving bed on this frame, so it is the "
            "axis most likely to skip steps under high acceleration."
            if profile.moving_bed_axis
            else ""
        )
        add(
            "accel_above_recommended",
            "warning",
            "printer",
            f"max_accel is {max_accel:g} mm/s², above the {profile.recommended_max_accel:g} "
            f"recommended for a {profile.name}.",
            detail=detail,
            remedy=(
                "If you are seeing layer shifts, lower it and run the Axis Health Test. "
                "Input shaping lets you raise it again with evidence."
            ),
        )


def diff_configs(old_text: str, new_text: str) -> Dict[str, Any]:
    """Section-aware diff: which sections were added, removed or changed, and
    which individual options moved. Far more readable than a line diff when a
    config has been reformatted."""
    old = parse_config(old_text)
    new = parse_config(new_text)

    old_map = {s.raw_name.lower(): s for s in old.sections}
    new_map = {s.raw_name.lower(): s for s in new.sections}

    added = sorted(new_map.keys() - old_map.keys())
    removed = sorted(old_map.keys() - new_map.keys())
    changed: List[Dict[str, Any]] = []

    for key in sorted(old_map.keys() & new_map.keys()):
        before, after = old_map[key], new_map[key]
        options: List[Dict[str, Any]] = []
        for option in sorted(set(before.options) | set(after.options)):
            was = before.options.get(option)
            now = after.options.get(option)
            if was != now:
                options.append({"option": option, "before": was, "after": now})
        if options:
            changed.append({"section": after.raw_name, "options": options})

    # SAVE_CONFIG values are Klipper's, and change on their own. Report them
    # separately so a mesh update does not look like the user edited the config.
    autosave: List[Dict[str, Any]] = []
    old_auto, new_auto = old.autosave_values, new.autosave_values
    for name in sorted(set(old_auto) | set(new_auto)):
        before_values = old_auto.get(name, {})
        after_values = new_auto.get(name, {})
        options = [
            {"option": key, "before": before_values.get(key), "after": after_values.get(key)}
            for key in sorted(set(before_values) | set(after_values))
            if before_values.get(key) != after_values.get(key)
        ]
        if options:
            autosave.append({"section": name, "options": options})

    return {
        "added_sections": [new_map[k].raw_name for k in added],
        "removed_sections": [old_map[k].raw_name for k in removed],
        "changed_sections": changed,
        "autosave_changes": autosave,
        "identical": not (added or removed or changed or autosave),
    }
