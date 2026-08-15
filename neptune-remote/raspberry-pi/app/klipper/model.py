"""A parsed, queryable view of the live ``printer.cfg``.

Everything the safety engine needs to decide whether a move is legal comes from
here - never from hardcoded printer dimensions. A Neptune 3 Plus profile exists
to *validate* what the config says, not to override it.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

# ``[stepper_x]`` / ``[gcode_macro FOO]`` / ``[tmc2209 stepper_x]``
SECTION_RE = re.compile(r"^\s*\[([^\]]+)\]\s*$")
# ``key: value`` or ``key = value``
OPTION_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_.]*)\s*[:=]\s*(.*?)\s*$")
COMMENT_RE = re.compile(r"(^|\s)[#;].*$")


def _strip_comment(line: str) -> str:
    return COMMENT_RE.sub("", line).rstrip()


def _as_float(value: Any) -> Optional[float]:
    try:
        return float(str(value).strip())
    except (TypeError, ValueError):
        return None


def _as_int(value: Any) -> Optional[int]:
    number = _as_float(value)
    return int(number) if number is not None else None


@dataclass
class ConfigSection:
    """One ``[section]`` block, with its options and where it came from."""

    raw_name: str
    line: int
    options: Dict[str, str] = field(default_factory=dict)
    option_lines: Dict[str, int] = field(default_factory=dict)

    @property
    def kind(self) -> str:
        """``stepper_x`` for ``[stepper_x]``, ``gcode_macro`` for ``[gcode_macro FOO]``."""
        return self.raw_name.split()[0] if self.raw_name.split() else self.raw_name

    @property
    def label(self) -> str:
        """``FOO`` for ``[gcode_macro FOO]``; empty for a bare section."""
        parts = self.raw_name.split(maxsplit=1)
        return parts[1] if len(parts) > 1 else ""

    def get(self, key: str, default: Optional[str] = None) -> Optional[str]:
        return self.options.get(key, default)

    def get_float(self, key: str) -> Optional[float]:
        return _as_float(self.options.get(key))

    def get_int(self, key: str) -> Optional[int]:
        return _as_int(self.options.get(key))

    def get_bool(self, key: str) -> Optional[bool]:
        value = self.options.get(key)
        if value is None:
            return None
        return value.strip().lower() in {"true", "1", "yes", "on"}


@dataclass
class AxisLimits:
    """Travel limits for one axis, straight from the config."""

    axis: str
    position_min: Optional[float] = None
    position_max: Optional[float] = None
    position_endstop: Optional[float] = None
    homing_speed: Optional[float] = None
    homing_positive_dir: Optional[bool] = None

    @property
    def is_known(self) -> bool:
        return self.position_min is not None and self.position_max is not None

    def clamp(self, value: float) -> float:
        """Clamp to the configured travel. Unknown limits clamp to nothing."""
        if self.position_min is not None:
            value = max(value, self.position_min)
        if self.position_max is not None:
            value = min(value, self.position_max)
        return value

    def contains(self, value: float, tolerance: float = 0.001) -> bool:
        if self.position_min is not None and value < self.position_min - tolerance:
            return False
        if self.position_max is not None and value > self.position_max + tolerance:
            return False
        return True


@dataclass
class ParsedConfig:
    """The whole ``printer.cfg`` (plus any includes that were resolved)."""

    text: str = ""
    sections: List[ConfigSection] = field(default_factory=list)
    parse_errors: List[str] = field(default_factory=list)
    includes: List[str] = field(default_factory=list)

    # ------------------------------------------------------------- lookups
    def section(self, name: str) -> Optional[ConfigSection]:
        """Exact section match, e.g. ``stepper_x`` or ``gcode_macro START_PRINT``."""
        for item in self.sections:
            if item.raw_name.lower() == name.lower():
                return item
        return None

    def sections_of_kind(self, kind: str) -> List[ConfigSection]:
        return [s for s in self.sections if s.kind.lower() == kind.lower()]

    def has(self, name: str) -> bool:
        return self.section(name) is not None

    # -------------------------------------------------------------- limits
    def axis_limits(self, axis: str) -> AxisLimits:
        section = self.section(f"stepper_{axis.lower()}")
        limits = AxisLimits(axis=axis.upper())
        if section is None:
            return limits
        limits.position_min = section.get_float("position_min")
        limits.position_max = section.get_float("position_max")
        limits.position_endstop = section.get_float("position_endstop")
        limits.homing_speed = section.get_float("homing_speed")
        limits.homing_positive_dir = section.get_bool("homing_positive_dir")
        # Klipper's own default when the option is absent.
        if limits.position_min is None and section.get("position_max") is not None:
            limits.position_min = 0.0
        return limits

    @property
    def all_limits(self) -> Dict[str, AxisLimits]:
        return {axis: self.axis_limits(axis) for axis in ("x", "y", "z")}

    # ------------------------------------------------------------- printer
    @property
    def max_velocity(self) -> Optional[float]:
        section = self.section("printer")
        return section.get_float("max_velocity") if section else None

    @property
    def max_accel(self) -> Optional[float]:
        section = self.section("printer")
        return section.get_float("max_accel") if section else None

    @property
    def max_z_velocity(self) -> Optional[float]:
        section = self.section("printer")
        return section.get_float("max_z_velocity") if section else None

    @property
    def square_corner_velocity(self) -> Optional[float]:
        section = self.section("printer")
        return section.get_float("square_corner_velocity") if section else None

    @property
    def kinematics(self) -> Optional[str]:
        section = self.section("printer")
        return section.get("kinematics") if section else None

    # --------------------------------------------------------------- probe
    @property
    def probe_section(self) -> Optional[ConfigSection]:
        """Whichever probe-ish section exists, in order of specificity."""
        for name in ("bltouch", "probe", "smart_effector", "eddy_current", "scanner"):
            found = self.section(name)
            if found is not None:
                return found
        return None

    @property
    def has_probe(self) -> bool:
        return self.probe_section is not None

    @property
    def probe_z_offset(self) -> Optional[float]:
        section = self.probe_section
        return section.get_float("z_offset") if section else None

    @property
    def probe_offsets(self) -> Tuple[Optional[float], Optional[float]]:
        section = self.probe_section
        if section is None:
            return (None, None)
        return (section.get_float("x_offset"), section.get_float("y_offset"))

    @property
    def safe_z_home(self) -> Optional[ConfigSection]:
        return self.section("safe_z_home")

    @property
    def has_bed_mesh(self) -> bool:
        return self.has("bed_mesh")

    @property
    def has_screws_tilt(self) -> bool:
        return self.has("screws_tilt_adjust")

    @property
    def has_filament_sensor(self) -> bool:
        return bool(
            self.sections_of_kind("filament_switch_sensor")
            or self.sections_of_kind("filament_motion_sensor")
        )

    @property
    def has_accelerometer(self) -> bool:
        return bool(
            self.sections_of_kind("adxl345")
            or self.sections_of_kind("lis2dw")
            or self.sections_of_kind("mpu9250")
        )

    @property
    def input_shaper(self) -> Optional[ConfigSection]:
        return self.section("input_shaper")

    @property
    def fan_sections(self) -> List[ConfigSection]:
        kinds = ("fan", "heater_fan", "controller_fan", "fan_generic", "temperature_fan")
        return [s for s in self.sections if s.kind.lower() in kinds]

    def section_body(self, section: ConfigSection) -> str:
        """The raw text of a section, header excluded.

        The option parser keeps one line per key, which is right for
        ``position_max: 330`` and useless for ``gcode:`` - a macro body is a
        dozen indented lines and lands in ``options`` as an empty string. Any
        question about what a macro *does* has to read the block itself.
        """
        lines = self.text.splitlines()
        start = section.line  # 1-based header line; body begins after it
        if start < 1 or start > len(lines):
            return ""
        end = len(lines)
        for other in self.sections:
            if other.line > section.line:
                end = min(end, other.line - 1)
        body = lines[start:end]
        # Klipper's own SAVE_CONFIG block is not part of anybody's macro.
        cut = next((i for i, line in enumerate(body) if line.startswith("#*#")), None)
        if cut is not None:
            body = body[:cut]
        return "\n".join(body)

    # ----------------------------------------------------------- SAVE_CONFIG
    @property
    def autosave_values(self) -> Dict[str, Dict[str, str]]:
        """Values Klipper wrote below ``#*# <---------------------- SAVE_CONFIG``."""
        result: Dict[str, Dict[str, str]] = {}
        marker = "#*# <---------------------- SAVE_CONFIG"
        if marker not in self.text:
            return result
        tail = self.text.split(marker, 1)[1]
        current: Optional[str] = None
        for raw in tail.splitlines():
            line = raw.strip()
            if not line.startswith("#*#"):
                continue
            body = line[3:].strip()
            if not body:
                continue
            match = SECTION_RE.match(body)
            if match:
                current = match.group(1).strip()
                result.setdefault(current, {})
                continue
            option = OPTION_RE.match(body)
            if option and current:
                result[current][option.group(1).lower()] = option.group(2)
        return result

    @property
    def has_saved_mesh(self) -> bool:
        return any(name.startswith("bed_mesh ") for name in self.autosave_values)

    @property
    def saved_mesh_profiles(self) -> List[str]:
        return [
            name.split(" ", 1)[1]
            for name in self.autosave_values
            if name.startswith("bed_mesh ")
        ]

    @property
    def saved_probe_z_offset(self) -> Optional[float]:
        for name, values in self.autosave_values.items():
            if name.split()[0] in {"probe", "bltouch"} and "z_offset" in values:
                return _as_float(values["z_offset"])
        return None

    @property
    def effective_probe_z_offset(self) -> Optional[float]:
        """SAVE_CONFIG wins over the hand-written value, exactly as Klipper does."""
        saved = self.saved_probe_z_offset
        return saved if saved is not None else self.probe_z_offset


def parse_config(text: str) -> ParsedConfig:
    """Parse ``printer.cfg`` text. Tolerant on purpose: a config we cannot fully
    read must still yield whatever is legible, because the diagnosis of a broken
    config is exactly when this matters most."""
    parsed = ParsedConfig(text=text)
    current: Optional[ConfigSection] = None
    in_autosave = False

    for number, raw in enumerate(text.splitlines(), start=1):
        if raw.startswith("#*#"):
            in_autosave = True
            continue
        if in_autosave:
            # Everything after the SAVE_CONFIG block is Klipper's, not the user's.
            continue

        line = _strip_comment(raw)
        if not line.strip():
            continue

        match = SECTION_RE.match(line)
        if match:
            name = match.group(1).strip()
            current = ConfigSection(raw_name=name, line=number)
            parsed.sections.append(current)
            continue

        # An indented continuation line belongs to the previous option
        # (multi-line gcode: blocks). Skipping them is intentional: the safety
        # engine never needs macro bodies, and mis-parsing them creates noise.
        if raw[:1] in {" ", "\t"} and current is not None:
            continue

        option = OPTION_RE.match(line)
        if option and current is not None:
            key = option.group(1).lower()
            value = option.group(2).strip()
            if key == "include" or current.raw_name.lower().startswith("include"):
                parsed.includes.append(value)
            current.options[key] = value
            current.option_lines[key] = number
            continue

        if line.strip().startswith("[include"):
            parsed.includes.append(line.strip()[8:].strip(" ]"))
            continue

        if option is None and current is None:
            parsed.parse_errors.append(f"line {number}: unexpected content outside a section")

    return parsed
