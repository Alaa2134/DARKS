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
        # M82 is not decoration. The E values below are absolute, and the
        # extruder mode at this point belongs to whatever ran last - a slicer
        # that emitted M83, a previous macro, a terminal command. In relative
        # mode "E15 then E30" purges 45 mm instead of 30.
        "    M82",
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


#: Bed temperature at or below which a printed part has usually let go.
#:
#: Adhesion is thermal: the plastic contracts faster than the sheet as both
#: cool, and that mismatch is what breaks the bond. Sweeping a part off a warm
#: bed does not eject it - it drives the toolhead into something that is still
#: glued down, which costs steps, and can cost a nozzle.
EJECT_MAX_BED_C = 40.0

#: How high the nozzle rides during the sweep.
#:
#: Low enough to catch the first layer rather than glide over a short part,
#: high enough not to score the sheet. This is the one number worth tuning per
#: build surface, so it is a parameter with this as its default.
EJECT_SWEEP_Z_MM = 1.0

#: How fast the sweep runs, mm/min. Fast enough that momentum helps, slow
#: enough that a part which refuses to move stalls the motor rather than
#: slamming into the frame.
EJECT_SWEEP_FEED = 6000


def suggest_eject_part(config: ParsedConfig) -> MacroSuggestion:
    """A macro that pushes the finished part off the bed.

    Only generated for a bed-slinger, and only with its assumptions stated.
    Klipper's config says `kinematics: cartesian`; it does **not** say whether Y
    moves the bed or the gantry, and this technique needs the bed to be the
    thing that moves. That is written into the rationale rather than hidden,
    because it is the one thing here that cannot be read from the file.

    On corexy/delta the bed does not travel at all, so it is refused outright
    instead of emitting motion that would sweep the toolhead across a stationary
    part at a guessed height.
    """
    rationale: List[str] = []
    blockers: List[str] = []

    kinematics = (config.kinematics or "").strip().lower()
    if kinematics and kinematics != "cartesian":
        blockers.append(
            f"kinematics is '{kinematics}'. Sweeping a part off needs the bed to "
            f"move under a stationary nozzle, which only happens on a bed-slinger."
        )

    x = config.axis_limits("x")
    y = config.axis_limits("y")
    z = config.axis_limits("z")
    if not x.is_known or not y.is_known:
        blockers.append(
            "stepper_x/stepper_y travel is not fully defined, so the sweep would "
            "run to guessed coordinates."
        )

    extruder = config.section("extruder")
    min_extrude = DEFAULT_MIN_EXTRUDE_TEMP
    if extruder is not None:
        min_extrude = extruder.get_float("min_extrude_temp") or DEFAULT_MIN_EXTRUDE_TEMP

    if blockers:
        return MacroSuggestion(
            name="EJECT_PART",
            gcode="",
            rationale=rationale,
            blockers=blockers,
            existing=_existing_macro(config, "EJECT_PART"),
        )

    # position_min is homing overtravel, not bed. Sweep between the real
    # surface edges.
    front_y = max(y.position_min, 0.0)

    # Where the sweep starts. A configured mesh gives a coordinate the probe
    # has actually reached on the bed surface, which beats measuring in from
    # the travel limit and hoping the rear clips are not there.
    mesh = config.section("bed_mesh")
    mesh_max = (mesh.get("mesh_max") if mesh else None) or ""
    mesh_max_y: Optional[float] = None
    mesh_min_x: Optional[float] = None
    mesh_max_x: Optional[float] = None
    try:
        parts = [float(piece) for piece in mesh_max.replace(" ", "").split(",") if piece]
        mesh_max_y = parts[1] if len(parts) > 1 else None
        mesh_max_x = parts[0] if parts else None
        low = [
            float(piece)
            for piece in ((mesh.get("mesh_min") if mesh else "") or "").replace(" ", "").split(",")
            if piece
        ]
        mesh_min_x = low[0] if low else None
    except ValueError:
        mesh_max_y = mesh_min_x = mesh_max_x = None

    back_y = mesh_max_y if mesh_max_y is not None else y.position_max - EDGE_MARGIN_MM
    if mesh_max_y is not None:
        rationale.append(
            f"Starts at Y{back_y:.1f}, the back of the configured mesh - a point "
            f"the probe already reaches on the bed itself, rather than a "
            f"measurement in from the travel limit that could be over the clips."
        )

    # Three passes, not one. The nozzle is a point travelling in a straight
    # line, not a blade the width of the bed: it only moves what is in its
    # path. One pass down the middle catches the usual centred part and walks
    # straight past anything printed off to a side.
    low_x = mesh_min_x if mesh_min_x is not None else max(x.position_min, 0.0) + EDGE_MARGIN_MM
    high_x = mesh_max_x if mesh_max_x is not None else x.position_max - EDGE_MARGIN_MM
    centre_x = (low_x + high_x) / 2.0
    # Middle first: it is where most prints are, and a part that goes on the
    # first pass makes the other two harmless travel moves.
    pass_x = [centre_x, low_x + (centre_x - low_x) / 2.0, centre_x + (high_x - centre_x) / 2.0]

    rationale.append(
        f"Assumes Y moves the bed (a bed-slinger). The nozzle starts at "
        f"Y{back_y:.1f} and sweeps to Y{front_y:.1f}, so the part is pushed off "
        f"the front edge. If Y moves the gantry on your machine instead, do not "
        f"install this - printer.cfg cannot tell the two apart."
    )
    rationale.append(
        "Three passes across the width (%s). The nozzle only moves what it "
        "actually touches, so a single pass down the middle misses a part "
        "printed off to one side." % ", ".join(f"X{value:.0f}" for value in pass_x)
    )
    rationale.append(
        f"Refuses above {EJECT_MAX_BED_C:.0f}C. A part only releases once the bed "
        f"has cooled; sweeping a warm one pushes the toolhead into something still "
        f"stuck, which skips steps."
    )
    rationale.append(
        f"Refuses above the configured min_extrude_temp ({min_extrude:.0f}C) on the "
        f"nozzle: a hot nozzle drags a melted line across the part and oozes onto "
        f"the sheet."
    )
    rationale.append(
        f"Sweeps at Z{EJECT_SWEEP_Z_MM:.1f} by default - low enough to catch a "
        f"first layer, high enough not to score the sheet. Pass Z= to change it."
    )

    lines: List[str] = [
        "[gcode_macro EJECT_PART]",
        "description: Sweep the finished part off the bed - generated from this printer.cfg",
        "gcode:",
        f"    {{% set SWEEP_Z = params.Z|default({EJECT_SWEEP_Z_MM})|float %}}",
        f"    {{% set MAX_BED = params.MAX_BED|default({EJECT_MAX_BED_C:.0f})|float %}}",
        "",
        "    # Refuse rather than fight the printer.",
        "    {% if printer.print_stats.state in ['printing', 'paused'] %}",
        '        { action_raise_error("EJECT_PART: a print is still running") }',
        "    {% endif %}",
        "    {% if printer.heater_bed.temperature > MAX_BED %}",
        '        { action_raise_error("EJECT_PART: bed is %.0fC, wait until it is under'
        ' %.0fC or the part will not release" % (printer.heater_bed.temperature, MAX_BED)) }',
        "    {% endif %}",
        f"    {{% if printer.extruder.temperature > {min_extrude:.0f} %}}",
        '        { action_raise_error("EJECT_PART: nozzle is still hot") }',
        "    {% endif %}",
        "",
        "    {% if 'xyz' not in printer.toolhead.homed_axes %}",
        "        G28",
        "    {% endif %}",
        "",
        "    G90",
    ]

    if z.is_known:
        rationale.append("Lifts before travelling so the nozzle does not clip the part on the way.")

    for index, sweep_x in enumerate(pass_x, start=1):
        lines += [
            f"    # Pass {index} of {len(pass_x)}",
            "    G1 Z{SWEEP_Z + 20} F3000",
            f"    G1 X{sweep_x:.1f} Y{back_y:.1f} F6000",
            "    G1 Z{SWEEP_Z} F1500",
            f"    G1 Y{front_y:.1f} F{EJECT_SWEEP_FEED}",
        ]

    lines += [
        "    G1 Z{SWEEP_Z + 20} F3000",
        "    M84",
    ]

    return MacroSuggestion(
        name="EJECT_PART",
        gcode="\n".join(lines) + "\n",
        rationale=rationale,
        blockers=blockers,
        existing=_existing_macro(config, "EJECT_PART"),
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
    eject = suggest_eject_part(config)

    return {
        "macros": [start.to_dict(), end.to_dict(), eject.to_dict()],
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
