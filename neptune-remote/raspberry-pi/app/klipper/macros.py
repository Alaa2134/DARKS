"""Build PRINT_START / PRINT_END from the printer's own configuration.

Every value here is read from the live ``printer.cfg``. Nothing is a constant
lifted from someone else's machine: the purge line is placed inside the
configured travel, the mesh is only loaded when a saved profile exists, and the
heat-then-home order depends on whether Z is probed.

Nothing is ever written. :func:`suggest` returns text and the reasoning behind
each decision; installing it is a separate, explicitly confirmed step that
snapshots the configuration first.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional

from .model import ParsedConfig

# Klipper's own default when [extruder] omits it.
DEFAULT_MIN_EXTRUDE_TEMP = 170.0

# Standing off the very edge of the configured travel: an axis can usually
# reach its limit, but parking a nozzle exactly on it is asking for a shutdown
# from the smallest rounding difference.
EDGE_MARGIN_MM = 5.0


@dataclass
class MacroSuggestion:
    """One generated macro plus why it looks the way it does."""

    name: str
    gcode: str
    # Human-readable reasons, each tied to something read from the config.
    rationale: List[str] = field(default_factory=list)
    # Reasons this could not be generated at all.
    blockers: List[str] = field(default_factory=list)
    # A macro of this name the user already has.
    existing: Optional[str] = None

    @property
    def ok(self) -> bool:
        return not self.blockers

    @property
    def conflicts(self) -> bool:
        return self.existing is not None

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "gcode": self.gcode,
            "rationale": self.rationale,
            "blockers": self.blockers,
            "existing": self.existing,
            "ok": self.ok,
            "conflicts": self.conflicts,
        }


def _purge_line(config: ParsedConfig, rationale: List[str]) -> List[str]:
    """A purge stripe placed inside the configured travel.

    Skipped entirely when the axis limits are unknown - a purge at guessed
    coordinates is exactly the kind of invented motion this project refuses to
    emit.
    """
    x = config.axis_limits("x")
    y = config.axis_limits("y")
    if not x.is_known or not y.is_known:
        rationale.append(
            "No purge line: stepper_x/stepper_y travel is not fully defined, "
            "and a purge at guessed coordinates could crash the nozzle."
        )
        return []

    # position_min is frequently negative - it is overtravel for homing, not
    # printable surface. The bed itself starts at 0 in Klipper's coordinates,
    # so purging relative to position_min would put the stripe off the bed and
    # onto the frame. Take whichever is further in.
    printable_min_x = max(x.position_min, 0.0)
    printable_min_y = max(y.position_min, 0.0)

    start_x = printable_min_x + EDGE_MARGIN_MM
    start_y = printable_min_y + EDGE_MARGIN_MM
    # Long enough to prime the nozzle properly, short of the far limit.
    end_x = min(
        start_x + (x.position_max - printable_min_x) * 0.6,
        x.position_max - EDGE_MARGIN_MM,
    )

    rationale.append(
        f"Purge line runs X{start_x:.1f}->{end_x:.1f} at Y{start_y:.1f}. "
        f"Measured from the bed origin, not from position_min "
        f"(X {x.position_min:.1f}, Y {y.position_min:.1f}) - those are negative here, "
        f"which is homing overtravel rather than printable surface."
    )

    return [
        "",
        "    # Purge line - placed inside this printer's configured travel",
        "    G92 E0",
        "    G90",
        f"    G1 X{start_x:.1f} Y{start_y:.1f} Z0.3 F5000",
        f"    G1 X{end_x:.1f} Y{start_y:.1f} E15 F1500",
        f"    G1 Y{start_y + 0.4:.1f} F5000",
        f"    G1 X{start_x:.1f} E30 F1500",
        "    G92 E0",
        "    G1 Z2 F3000",
    ]


def suggest_print_start(config: ParsedConfig) -> MacroSuggestion:
    rationale: List[str] = []
    blockers: List[str] = []

    extruder = config.section("extruder")
    if extruder is None:
        blockers.append("No [extruder] section - this is not a printer config.")

    has_bed = config.has("heater_bed")
    probes_z = False
    stepper_z = config.section("stepper_z")
    if stepper_z is not None:
        endstop = (stepper_z.get("endstop_pin") or "").lower()
        probes_z = "probe" in endstop

    mesh_profiles = config.saved_mesh_profiles
    min_extrude = DEFAULT_MIN_EXTRUDE_TEMP
    if extruder is not None:
        min_extrude = extruder.get_float("min_extrude_temp") or DEFAULT_MIN_EXTRUDE_TEMP

    lines: List[str] = [
        "[gcode_macro PRINT_START]",
        "description: Heat, home and prepare - generated from this printer.cfg",
        "gcode:",
        "    {% set BED = params.BED|default(60)|float %}",
        "    {% set EXTRUDER = params.EXTRUDER|default(200)|float %}",
        "",
    ]

    # A standby temperature below min_extrude_temp: hot enough to stop the
    # nozzle dripping during homing, cold enough that Klipper refuses to
    # extrude, so nothing oozes onto the bed while probing.
    standby = max(min_extrude - 20.0, 140.0)
    lines += [
        f"    # Standby heat, below min_extrude_temp ({min_extrude:.0f}C) so nothing extrudes",
        f"    M104 S{standby:.0f}",
    ]
    rationale.append(
        f"Nozzle waits at {standby:.0f}C during homing - under the configured "
        f"min_extrude_temp of {min_extrude:.0f}C, so it cannot ooze onto the bed."
    )

    if has_bed:
        lines += [
            "    M140 S{BED}",
            "    M190 S{BED}                      # wait: the bed moves as it expands",
        ]
        rationale.append(
            "Bed reaches temperature *before* homing, because the surface rises as "
            "it heats and probing a cold bed gives a Z offset that is wrong once hot."
        )
    else:
        rationale.append("No [heater_bed] in the config, so no bed heating step.")

    lines.append("")
    lines.append("    G28")
    if config.has("safe_z_home"):
        rationale.append("G28 alone - [safe_z_home] already decides where Z is homed.")
    else:
        rationale.append("G28 homes all axes; no [safe_z_home] section is configured.")

    if mesh_profiles:
        profile = "default" if "default" in mesh_profiles else mesh_profiles[0]
        lines.append(f"    BED_MESH_PROFILE LOAD={profile}")
        rationale.append(
            f"Loads the saved mesh '{profile}'. Without this line the mesh you "
            f"calibrated is never applied to a print."
        )
    elif config.has("bed_mesh"):
        lines.append("    # BED_MESH_CALIBRATE            # no saved profile yet")
        rationale.append(
            "[bed_mesh] exists but no profile has been saved. Run BED_MESH_CALIBRATE "
            "then SAVE_CONFIG, and this will load it instead of probing every print."
        )
    else:
        rationale.append("No [bed_mesh] section, so no mesh step.")

    lines += [
        "",
        "    M109 S{EXTRUDER}                 # full temperature only now",
    ]
    rationale.append(
        "Full nozzle temperature comes last, after probing, so a hot nozzle is "
        "never sitting over the bed longer than it has to be."
    )

    if probes_z:
        rationale.append(
            "Z is homed by the probe (stepper_z endstop_pin references it), which is "
            "why the order above matters: the bed must be at temperature first."
        )

    lines += _purge_line(config, rationale)

    return MacroSuggestion(
        name="PRINT_START",
        gcode="\n".join(lines) + "\n",
        rationale=rationale,
        blockers=blockers,
        existing=_existing_macro(config, "PRINT_START"),
    )


def suggest_print_end(config: ParsedConfig) -> MacroSuggestion:
    rationale: List[str] = []
    lines: List[str] = [
        "[gcode_macro PRINT_END]",
        "description: Retract, park and cool down - generated from this printer.cfg",
        "gcode:",
        "    G91",
        "    G1 E-3 F1800",
    ]

    z = config.axis_limits("z")
    x = config.axis_limits("x")
    y = config.axis_limits("y")

    if z.is_known:
        lines.append("    G1 Z10 F3000                     # lift clear of the print")
        rationale.append("Lifts Z by 10 mm before parking so the nozzle does not drag over the part.")
    lines.append("    G90")

    if x.is_known and y.is_known:
        park_x = x.position_max - EDGE_MARGIN_MM
        park_y = y.position_max - EDGE_MARGIN_MM
        lines.append(f"    G1 X{park_x:.1f} Y{park_y:.1f} F6000")
        rationale.append(
            f"Parks at X{park_x:.1f} Y{park_y:.1f} - {EDGE_MARGIN_MM:.0f} mm inside the "
            f"configured maximum on both axes, which puts the finished part in reach."
        )
    else:
        rationale.append("No parking move: the X/Y travel is not fully defined in the config.")

    lines += [
        "    TURN_OFF_HEATERS",
        "    M107",
        "    M84",
    ]
    rationale.append("Heaters off, fan off, steppers released.")

    return MacroSuggestion(
        name="PRINT_END",
        gcode="\n".join(lines) + "\n",
        rationale=rationale,
        existing=_existing_macro(config, "PRINT_END"),
    )


def _existing_macro(config: ParsedConfig, name: str) -> Optional[str]:
    for section in config.sections_of_kind("gcode_macro"):
        if section.label.upper() == name.upper():
            return section.raw_name
    return None


def suggest(config: ParsedConfig) -> dict:
    """Both macros, plus what the slicer has to be told to call them."""
    start = suggest_print_start(config)
    end = suggest_print_end(config)

    return {
        "macros": [start.to_dict(), end.to_dict()],
        # Generating the macro is only half of it: a macro nothing calls does
        # nothing at all, which is the state this printer is in today.
        "slicer": {
            "start_gcode": "PRINT_START BED=[first_layer_bed_temperature] EXTRUDER=[first_layer_temperature]",
            "end_gcode": "PRINT_END",
            "note": (
                "Replace the existing start and end G-code in the slicer with these "
                "single lines. Leaving the old commands in place runs them twice."
            ),
        },
        "already_configured": bool(start.existing and end.existing),
    }
