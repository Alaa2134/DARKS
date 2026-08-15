"""Carry on printing from a layer, or print only part of a file.

Two things people ask for that a printer cannot do on its own.

**Carry on.** A print stops - power cut, filament out, a cancel a day ago - and
the part is still stuck to the bed exactly where it was left. Klipper has no
memory of it: the file starts at layer one and there is no way to say "start at
layer 340". So the file is rewritten: everything below the resume layer is
dropped and replaced with a preamble that puts the machine back into the state
it was in when it stopped.

**Print a piece.** The same machinery with an end as well as a start, which is
how you reprint the top half of something that failed at 80%, or a single
section of a tall part.

What makes this safe rather than reckless is what the preamble does *not* do.
It never homes Z. Z homing on this class of printer drives the nozzle down onto
the bed at a fixed point, and after a resume that point may be inside the part
already sitting there - which is a nozzle through a print and possibly through a
bed. The Z position is asserted instead, and the app checks the homing point
against the part's own footprint before it offers the option at all.

The bed is brought back to temperature and *held* before anything moves, because
a cold sheet is a different size from a hot one: resuming onto a cold plate lands
the new layer beside the old one rather than on it.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional, Tuple

from .preview import PreviewError, PreviewIndex

log = logging.getLogger("neptune.gcode.resume")

#: Lift this far above the resume layer before travelling to the start point.
#: Enough to clear a curled edge or a blob, small enough not to string.
TRAVEL_CLEARANCE_MM = 5.0

#: Prime this much filament before the first move, to refill a nozzle that has
#: been sitting open. A resume after a day is a resume through a partly drained
#: melt zone, and the first millimetres of a layer would otherwise be missing.
DEFAULT_PRIME_MM = 8.0

#: How close the Z homing point may be to the printed part before homing Z is
#: refused. The probe needs clear bed, and "clear" has to include the skirt.
Z_HOME_CLEARANCE_MM = 10.0


class ResumeError(RuntimeError):
    pass


# --------------------------------------------------------------------------- #
# Reading the machine's state at a layer
# --------------------------------------------------------------------------- #


_S_VALUE = re.compile(rb"\bS(-?[0-9.]+)")
_F_VALUE = re.compile(rb"\bF([0-9.]+)")


@dataclass
class MachineState:
    """What the printer had been told, by the time it reached a layer.

    Read by replaying the file's own commands rather than assumed: a profile
    that changes the bed temperature after layer three, or switches to relative
    extrusion halfway, has to be honoured or the resumed print differs from the
    one that was running.
    """

    nozzle_temp: Optional[float] = None
    bed_temp: Optional[float] = None
    #: 0-255 as G-code writes it.
    fan_speed: Optional[float] = None
    absolute_positioning: bool = True
    absolute_extrusion: bool = True
    feedrate: Optional[float] = None
    x: Optional[float] = None
    y: Optional[float] = None
    z: Optional[float] = None

    @property
    def fan_percent(self) -> Optional[float]:
        if self.fan_speed is None:
            return None
        return round(self.fan_speed / 255.0 * 100.0, 1)


def state_at_layer(path: Path, index: PreviewIndex, layer: int) -> MachineState:
    """Replay the file up to `layer` and report the state it left behind.

    Only the commands that outlive a single move are tracked. A resumed print
    does not need to know every G1 that ever ran; it needs to know how hot the
    machine was, which way round the extruder was counting, and where the
    toolhead had got to.
    """
    if layer < 0 or layer >= len(index.layers):
        raise ResumeError(f"الطبقة {layer} مش موجودة في الملف ده.")

    state = MachineState()
    stop = index.layers[layer].offset

    with Path(path).open("rb") as handle:
        read = 0
        for line in handle:
            if read >= stop:
                break
            read += len(line)
            stripped = line.lstrip()
            if not stripped or stripped.startswith(b";"):
                continue

            word = stripped.split(maxsplit=1)[0].upper()

            if word in (b"M104", b"M109"):
                match = _S_VALUE.search(stripped)
                if match:
                    value = float(match.group(1))
                    # A cooldown at the end of a cancelled print must not become
                    # the temperature we resume at.
                    if value > 0:
                        state.nozzle_temp = value
            elif word in (b"M140", b"M190"):
                match = _S_VALUE.search(stripped)
                if match:
                    value = float(match.group(1))
                    if value > 0:
                        state.bed_temp = value
            elif word == b"M106":
                match = _S_VALUE.search(stripped)
                state.fan_speed = float(match.group(1)) if match else 255.0
            elif word == b"M107":
                state.fan_speed = 0.0
            elif word == b"M82":
                state.absolute_extrusion = True
            elif word == b"M83":
                state.absolute_extrusion = False
            elif word == b"G90":
                state.absolute_positioning = True
            elif word == b"G91":
                state.absolute_positioning = False
            elif word in (b"G0", b"G1"):
                match = _F_VALUE.search(stripped)
                if match:
                    state.feedrate = float(match.group(1))
                for token in stripped.split():
                    letter = token[0:1].upper()
                    if letter not in (b"X", b"Y", b"Z"):
                        continue
                    try:
                        value = float(token[1:].split(b";")[0])
                    except ValueError:
                        continue
                    if letter == b"X":
                        state.x = value if state.absolute_positioning else (state.x or 0) + value
                    elif letter == b"Y":
                        state.y = value if state.absolute_positioning else (state.y or 0) + value
                    else:
                        state.z = value if state.absolute_positioning else (state.z or 0) + value

    # The layer's own Z from the index is more trustworthy than the last G1 Z
    # seen, which may belong to a Z-hop rather than to the layer itself.
    recorded = index.layers[layer].z
    if recorded is not None:
        state.z = recorded

    return state


# --------------------------------------------------------------------------- #
# Is it safe to home Z?
# --------------------------------------------------------------------------- #


@dataclass
class ResumeSafety:
    """Whether the machine can find itself again without hitting the part."""

    can_home_z: bool = False
    #: Where Z homing would put the nozzle, when the config says.
    z_home_point: Optional[Tuple[float, float]] = None
    warnings_ar: List[str] = field(default_factory=list)
    blockers_ar: List[str] = field(default_factory=list)

    @property
    def is_safe(self) -> bool:
        return not self.blockers_ar


def assess(
    index: PreviewIndex,
    *,
    z_home_point: Optional[Tuple[float, float]],
    force_move_enabled: bool,
    state: MachineState,
) -> ResumeSafety:
    """Work out how the machine should recover its position.

    The whole question is Z. X and Y home into empty air at the edge of the
    machine and are always safe; Z homing drives the nozzle down at a fixed
    point, and that point may now be occupied by the part being resumed.
    """
    safety = ResumeSafety(z_home_point=z_home_point)

    if state.z is None:
        safety.blockers_ar.append(
            "مش عارف الطبقة دي على أي ارتفاع - الملف مفيهوش علامة Z."
        )
        return safety

    if z_home_point is None:
        safety.warnings_ar.append(
            "مفيش [safe_z_home] في الإعدادات، فمش عارف الطابعة بتعمل هومنج للـZ فين."
        )
    else:
        x, y = z_home_point
        inside = (
            index.min_x - Z_HOME_CLEARANCE_MM <= x <= index.max_x + Z_HOME_CLEARANCE_MM
            and index.min_y - Z_HOME_CLEARANCE_MM <= y <= index.max_y + Z_HOME_CLEARANCE_MM
        )
        if inside:
            safety.warnings_ar.append(
                f"نقطة هومنج الـZ ({x:.0f}, {y:.0f}) جوه مساحة القطعة اللي على السرير، "
                "فمش هينفع نعمل هومنج للـZ - هنقول لكليبر الارتفاع بدل ما نقيسه."
            )
        else:
            safety.can_home_z = True

    if not safety.can_home_z and not force_move_enabled:
        safety.blockers_ar.append(
            "عشان نكمل من غير هومنج للـZ، لازم [force_move] مع enable_force_move: True "
            "في printer.cfg."
        )

    if state.nozzle_temp is None or state.bed_temp is None:
        safety.warnings_ar.append(
            "مش لاقي درجات الحرارة في الملف - هتحتاج تحطها بإيدك قبل ما تكمل."
        )

    return safety


# --------------------------------------------------------------------------- #
# Building the file
# --------------------------------------------------------------------------- #


def build_preamble(
    state: MachineState,
    safety: ResumeSafety,
    *,
    layer: int,
    nozzle_temp: Optional[float] = None,
    bed_temp: Optional[float] = None,
    prime_mm: float = DEFAULT_PRIME_MM,
) -> List[str]:
    """The lines that put the machine back where it was.

    Order matters and every step is here for a reason:

    1. Bed first, and *wait*. A cold sheet is a different size from a hot one,
       and the part on it moves as it warms. Starting the new layer before the
       plate has finished expanding lands it beside the old one.
    2. Nozzle next, also waiting - the first move must not drag a cold nozzle.
    3. Home X and Y only. Both run into empty air at the edge of the machine.
    4. Establish Z without homing it, unless the probe point is clear.
    5. Lift, travel, drop. Never travel at layer height across a printed part.
    6. Prime, because a nozzle that has been open for a day has drained.
    """
    nozzle = nozzle_temp if nozzle_temp is not None else state.nozzle_temp
    bed = bed_temp if bed_temp is not None else state.bed_temp

    lines: List[str] = [
        "; ------------------------------------------------------------------",
        f"; Neptune Remote - resumed at layer {layer + 1}",
        ";",
        "; Everything below the resume layer has been removed. This preamble",
        "; puts the machine back into the state the print was in when it",
        "; stopped. Z is NOT homed: the probe point may be inside the part",
        "; already on the bed.",
        "; ------------------------------------------------------------------",
        "M117 Neptune: resuming",
    ]

    if bed is not None:
        lines.append(f"M140 S{bed:.0f}")
    if nozzle is not None:
        # Warm but not oozing while the bed catches up.
        lines.append(f"M104 S{min(nozzle, 160.0):.0f}")
    if bed is not None:
        lines.append("M117 Neptune: heating the bed")
        lines.append(f"M190 S{bed:.0f}")
    if nozzle is not None:
        lines.append("M117 Neptune: heating the nozzle")
        lines.append(f"M109 S{nozzle:.0f}")

    lines += [
        "M117 Neptune: homing X and Y",
        "G28 X Y",
    ]

    z = state.z or 0.0
    if safety.can_home_z:
        lines += [
            "; The Z homing point is clear of the part, so Z can be measured.",
            "G28 Z",
        ]
    else:
        lines += [
            "; The Z homing point is inside the part, so the height is asserted",
            "; rather than measured. This is why [force_move] is required.",
            f"SET_KINEMATIC_POSITION Z={z + TRAVEL_CLEARANCE_MM:.3f}",
        ]

    lines.append("G90")
    lines.append(f"G1 Z{z + TRAVEL_CLEARANCE_MM:.3f} F600")

    if state.x is not None and state.y is not None:
        lines.append(f"G1 X{state.x:.3f} Y{state.y:.3f} F6000")

    if prime_mm > 0 and (nozzle or 0) > 0:
        lines += [
            "M117 Neptune: priming",
            "M83",
            f"G1 E{prime_mm:.2f} F180",
            "G92 E0",
        ]

    lines.append(f"G1 Z{z:.3f} F300")

    if state.fan_speed is not None:
        lines.append(
            f"M106 S{state.fan_speed:.0f}" if state.fan_speed > 0 else "M107"
        )

    # Restore the modes the file itself was using, last, so nothing above has
    # disturbed them.
    lines.append("M82" if state.absolute_extrusion else "M83")
    lines.append("G90" if state.absolute_positioning else "G91")
    if state.absolute_extrusion:
        lines.append("G92 E0")
    if state.feedrate:
        lines.append(f"G1 F{state.feedrate:.0f}")

    lines += [
        "M117 Neptune: printing",
        "; ---------------------------- resumed print follows ---------------",
    ]
    return lines


def build_resumed_file(
    source: Path,
    destination: Path,
    index: PreviewIndex,
    *,
    start_layer: int,
    end_layer: Optional[int] = None,
    safety: ResumeSafety,
    state: MachineState,
    nozzle_temp: Optional[float] = None,
    bed_temp: Optional[float] = None,
    prime_mm: float = DEFAULT_PRIME_MM,
) -> Path:
    """Write a file that starts at `start_layer` and optionally stops after
    `end_layer`.

    With no end this is a resume. With one it is "print this piece" - the top
    half of something that failed at 80%, or one section of a tall part.

    The tail of the original file is kept when there is no end layer, because
    that is where the end-of-print sequence lives - turning the heaters off,
    parking the head, retracting. Cutting at an end layer means that sequence
    would never run, so a minimal one is written instead.
    """
    if not safety.is_safe:
        raise ResumeError(" ".join(safety.blockers_ar))
    if start_layer < 0 or start_layer >= len(index.layers):
        raise ResumeError(f"الطبقة {start_layer} مش موجودة في الملف ده.")
    if end_layer is not None:
        if end_layer < start_layer:
            raise ResumeError("آخر طبقة لازم تكون بعد أول طبقة.")
        if end_layer >= len(index.layers):
            raise ResumeError(f"الطبقة {end_layer} مش موجودة في الملف ده.")

    source = Path(source)
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)

    begin = index.layers[start_layer].offset
    finish = (
        index.layers[end_layer + 1].offset
        if end_layer is not None and end_layer + 1 < len(index.layers)
        else None
    )

    preamble = build_preamble(
        state, safety,
        layer=start_layer,
        nozzle_temp=nozzle_temp,
        bed_temp=bed_temp,
        prime_mm=prime_mm,
    )

    # Written through a temporary name and moved into place, so a failure
    # halfway cannot leave a half-written file that looks printable.
    temporary = destination.with_suffix(destination.suffix + ".partial")
    try:
        with source.open("rb") as reader, temporary.open("wb") as writer:
            for line in preamble:
                writer.write(line.encode("ascii", "replace") + b"\n")

            reader.seek(begin)
            if finish is None:
                # Everything to the end, including the slicer's own end-of-print
                # sequence.
                while True:
                    chunk = reader.read(1024 * 1024)
                    if not chunk:
                        break
                    writer.write(chunk)
            else:
                remaining = finish - begin
                while remaining > 0:
                    chunk = reader.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    writer.write(chunk)
                for line in _closing_sequence():
                    writer.write(line.encode("ascii", "replace") + b"\n")

        temporary.replace(destination)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise

    return destination


def _closing_sequence() -> List[str]:
    """A minimal end-of-print, for a file cut short of the slicer's own.

    Deliberately conservative: heaters off, extruder relaxed, motors left
    engaged. Parking the head is left to the printer's own END_PRINT if it has
    one, because where it is safe to park depends on the machine.
    """
    return [
        "; ------------------------ end of the requested range --------------",
        "M117 Neptune: range finished",
        "M104 S0",
        "M140 S0",
        "M107",
        "G91",
        "G1 E-3 F1800",
        "G90",
        "; Heaters are off. The part is still on the bed.",
    ]
