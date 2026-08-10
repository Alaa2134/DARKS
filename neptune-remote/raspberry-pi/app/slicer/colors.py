"""Multi-colour printing on a single-nozzle machine, by stopping at a layer.

A Neptune 3 Plus has one nozzle and one filament path, so "multi-colour" here
means exactly one thing: the print stops at a chosen layer, the person swaps the
spool, and the print continues. Everything below the stop is one colour and
everything above it is the next. That is a real, useful mode - logos, two-tone
lids, name plates - and it needs no hardware at all.

PrusaSlicer's *command line* cannot place colour changes; that is a GUI feature
which writes into the project file, not something ``--export-gcode`` accepts. So
the change is made afterwards, on the sliced G-code, which has the advantage of
working identically whichever engine produced the file.

Three things are written at each stop:

``;COLOR_CHANGE layer=N color=...``
    A comment, so the file still explains itself when read by a human or by
    anything that is not this program.
``M117 COLOR: ...``
    Klipper copies this into ``display_status.message``. That is how the backend
    knows *which* colour a paused printer is waiting for without having to tie
    the running file back to the job that sliced it - the answer travels in the
    printer's own state.
``COLOR_CHANGE COLOR="..." LAYER=N``
    The actual stop. Klipper has no built-in ``M600``, so this calls a macro,
    and a macro that does not exist aborts the print with "Unknown command" -
    the same failure this printer already hit once with ``PRINT_START``. The API
    refuses to queue a colour-change slice until the macro is really installed;
    see :func:`app.klipper.macros.suggest_color_change` for the macro itself.

The insertion goes *before* the layer marker, which means after the last move of
the previous layer and before the first move of the new one. The nozzle is still
at the old Z, and the macro lifts and parks from there; the new layer's own Z
move happens on resume, where it belongs.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Sequence, Tuple

#: The macro each stop calls. Klipper has no M600 of its own.
COLOR_CHANGE_COMMAND = "COLOR_CHANGE"

#: What M117 is prefixed with. Latin, deliberately: the colour name itself may
#: be in any script, and the prefix is what the parser matches on.
DISPLAY_PREFIX = "COLOR:"

#: Header comment listing the whole plan, so a G-code file the app did not
#: slice this session still says what it is going to ask for.
MANIFEST_KEY = "neptune_color_changes"

#: Characters that would end a G-code line early, split a parameter, or break
#: the manifest's own encoding. Stripped from colour names rather than rejected:
#: a name is a label, and silently losing a semicolon beats refusing the slice.
_UNSAFE_IN_NAME = str.maketrans({c: None for c in ';#*"\'\\|:\r\n\t'})

_LAYER_CHANGE = re.compile(r"^\s*;\s*(?:LAYER_CHANGE|CHANGE_LAYER)\b", re.I)
_LAYER_NUMBER = re.compile(r"^\s*;\s*LAYER:\s*(-?\d+)", re.I)
_Z_COMMENT = re.compile(r"^\s*;\s*Z:\s*([\d.]+)", re.I)
_Z_MOVE = re.compile(r"^\s*G[01]\s[^;]*?\bZ(\d+(?:\.\d+)?)", re.I)

#: How far past a layer marker to look for the layer's Z height. PrusaSlicer
#: puts ``;Z:`` on the very next line; Cura's Z arrives in a move a few lines
#: down, after the mesh/type comments.
_Z_LOOKAHEAD = 12


def clean_color_name(name: str) -> str:
    """A colour name that survives a G-code line and the manifest."""
    cleaned = " ".join(name.translate(_UNSAFE_IN_NAME).split())
    return cleaned[:40]


@dataclass(frozen=True)
class LayerMark:
    """One layer boundary in a sliced file."""

    #: 1-based, counting the way a person does: the first layer is 1.
    number: int
    #: Index of the marker line within the file.
    line: int
    #: Height of the layer that starts here, when the file says so.
    z: Optional[float] = None


@dataclass(frozen=True)
class AppliedChange:
    layer: int
    color: str
    z: Optional[float] = None


class ColorChangeError(ValueError):
    """A colour change that cannot be placed in this file."""


def scan_layers(path: Path) -> List[LayerMark]:
    """Index every layer boundary, streaming.

    One entry per layer, not per line: a 300 MB G-code file produces a few
    hundred small records, so this stays cheap on a Raspberry Pi where reading
    the whole file into memory would not be.

    Two dialects exist and they are told apart by whichever appears first.
    Cura numbers its layers explicitly and counts from zero; PrusaSlicer,
    SuperSlicer and OrcaSlicer emit an unnumbered marker, so those are counted.
    """
    marks: List[LayerMark] = []
    numbered: Optional[bool] = None
    counter = 0
    pending: Optional[int] = None  # index into `marks` still missing its Z
    pending_age = 0

    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for index, line in enumerate(handle):
            if pending is not None:
                z = _z_from(line)
                if z is not None:
                    mark = marks[pending]
                    marks[pending] = LayerMark(number=mark.number, line=mark.line, z=z)
                    pending = None
                else:
                    pending_age += 1
                    if pending_age > _Z_LOOKAHEAD:
                        pending = None

            number: Optional[int] = None
            explicit = _LAYER_NUMBER.match(line)
            if explicit is not None and numbered is not False:
                numbered = True
                # Cura's first layer is ;LAYER:0.
                number = int(explicit.group(1)) + 1
            elif numbered is not True and _LAYER_CHANGE.match(line):
                numbered = False
                counter += 1
                number = counter

            if number is None:
                continue
            marks.append(LayerMark(number=number, line=index))
            pending = len(marks) - 1
            pending_age = 0

    return marks


def _z_from(line: str) -> Optional[float]:
    match = _Z_COMMENT.match(line)
    if match is None:
        match = _Z_MOVE.match(line)
    if match is None:
        return None
    try:
        return float(match.group(1))
    except ValueError:
        return None


def plan_changes(
    marks: Sequence[LayerMark], changes: Sequence[Tuple[int, str]]
) -> List[Tuple[LayerMark, str]]:
    """Match requested layers to real ones, or explain why they do not exist.

    Refusing here rather than at print time is the whole point: a colour change
    aimed at layer 400 of a 120-layer print is a mistake that would otherwise
    only show up as "the printer never asked me to change the filament", hours
    in and unrecoverable.
    """
    if not changes:
        return []
    if not marks:
        raise ColorChangeError(
            "This G-code has no layer markers, so there is nowhere to place a "
            "colour change. Slicing with PrusaSlicer, SuperSlicer, OrcaSlicer "
            "or Cura produces them."
        )

    by_number = {mark.number: mark for mark in marks}
    highest = max(by_number)
    planned: List[Tuple[LayerMark, str]] = []
    seen: set[int] = set()

    for layer, raw_name in sorted(changes, key=lambda item: item[0]):
        if layer < 2:
            raise ColorChangeError(
                f"Layer {layer}: a colour change at the first layer is just the "
                f"colour you load before starting - there is nothing to stop for."
            )
        if layer > highest:
            raise ColorChangeError(
                f"Layer {layer} does not exist - this print is {highest} layers tall."
            )
        mark = by_number.get(layer)
        if mark is None:
            raise ColorChangeError(f"Layer {layer} is not a layer boundary in this file.")
        if layer in seen:
            raise ColorChangeError(f"Layer {layer} has two colour changes on it.")
        seen.add(layer)

        name = clean_color_name(raw_name)
        if not name:
            raise ColorChangeError(f"Layer {layer} has no colour name.")
        planned.append((mark, name))

    return planned


def _insertion(layer: int, color: str) -> List[str]:
    return [
        f";COLOR_CHANGE layer={layer} color={color}\n",
        f"M117 {DISPLAY_PREFIX} {color}\n",
        f'{COLOR_CHANGE_COMMAND} COLOR="{color}" LAYER={layer}\n',
    ]


def manifest_line(applied: Sequence[AppliedChange]) -> str:
    """The whole plan on one comment line, near the top of the file."""
    parts = [f"{item.layer}:{item.color}" for item in applied]
    return f"; {MANIFEST_KEY} = {'|'.join(parts)}\n"


def color_from_display(message: str) -> Optional[str]:
    """The colour a paused printer is waiting for, from its display message.

    ``M117 COLOR: Red`` is written next to every stop, so the answer is in
    Klipper's own state and needs no bookkeeping tying the running file back to
    the job that sliced it - a file printed from a USB stick or sliced last
    month still says what it wants.
    """
    text = (message or "").strip()
    if not text.upper().startswith(DISPLAY_PREFIX):
        return None
    return text[len(DISPLAY_PREFIX):].strip() or None


def parse_manifest(text: str) -> List[AppliedChange]:
    """Read back the plan from a file's header. Never raises."""
    match = re.search(rf"^;\s*{MANIFEST_KEY}\s*=\s*(.+)$", text, re.M)
    if match is None:
        return []
    found: List[AppliedChange] = []
    for piece in match.group(1).strip().split("|"):
        layer, _, color = piece.partition(":")
        try:
            number = int(layer.strip())
        except ValueError:
            continue
        color = color.strip()
        if number > 0 and color:
            found.append(AppliedChange(layer=number, color=color))
    return found


def apply_color_changes(
    path: Path, changes: Sequence[Tuple[int, str]]
) -> List[AppliedChange]:
    """Rewrite `path` in place with a stop at each requested layer.

    The rewrite goes to a sibling temporary file and is moved over the original
    only once it is complete, so a failure half way through leaves the sliced
    G-code intact rather than truncated.
    """
    path = Path(path)
    if not changes:
        return []

    marks = scan_layers(path)
    planned = plan_changes(marks, changes)
    applied = [
        AppliedChange(layer=mark.number, color=color, z=mark.z) for mark, color in planned
    ]
    insert_at = {mark.line: (mark.number, color) for mark, color in planned}

    temporary = path.with_name(path.name + ".colors.tmp")
    try:
        with path.open("r", encoding="utf-8", errors="replace") as source, temporary.open(
            "w", encoding="utf-8"
        ) as target:
            target.write(manifest_line(applied))
            for index, line in enumerate(source):
                stop = insert_at.get(index)
                if stop is not None:
                    target.writelines(_insertion(stop[0], stop[1]))
                target.write(line)
        os.replace(temporary, path)
    except OSError:
        temporary.unlink(missing_ok=True)
        raise

    return applied
