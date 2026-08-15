"""Decide where each model sits on the bed, and say when it will not work.

`extra_model_ids` and `copies` already existed, but the arrangement was left
entirely to the slicer: the user could put four things on a plate and had no
say in where any of them went, and no way to see it. That is fine until two
parts touch, or one lands over the bed clip, or the whole plate is pushed off
the front edge - and then the first sign of it is a failed print.

Everything here works on **bounding rectangles**, not on the real outlines. A
part shaped like an L takes a rectangle bigger than the plastic in it, so two of
them nested together are reported as touching when they are not. That is the
wrong answer in the safe direction, and computing real outlines means the
convex hull of every layer - work with a big cost and a small payoff on a
6-inch screen.

Positions are in millimetres from the **bed centre**, because that is what the
mesh transform applies and what the slicer's own coordinates reduce to. The bed
origin is a corner on some machines and the middle on others; the centre is the
one point both agree on.
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

log = logging.getLogger("neptune.slicer.arrange")

#: Gap left between parts. Enough for the nozzle to travel between them without
#: dragging over a neighbour, and for two skirts not to fuse.
DEFAULT_SPACING_MM = 6.0

#: Keep this clear of the bed edge. The first layer needs the plate under it,
#: and the outermost few millimetres of any bed are the least reliable part of
#: it - clips, warped corners, the edge of the PEI sheet.
DEFAULT_MARGIN_MM = 8.0


class ArrangeError(RuntimeError):
    pass


@dataclass
class Placement:
    """One model's footprint and where it goes.

    `width` and `depth` are the footprint *after* rotation and scale - the
    arrangement works on what will actually be printed, not on what the file
    contained.
    """

    model_id: str
    width: float
    depth: float
    #: Millimetres from the bed centre. The mesh is moved by this before it
    #: reaches the slicer.
    x: float = 0.0
    y: float = 0.0

    @property
    def rect(self) -> Tuple[float, float, float, float]:
        """(left, bottom, right, top), in bed-centre millimetres."""
        return (
            self.x - self.width / 2,
            self.y - self.depth / 2,
            self.x + self.width / 2,
            self.y + self.depth / 2,
        )

    def as_dict(self) -> dict:
        return {
            "model_id": self.model_id,
            "width": round(self.width, 3),
            "depth": round(self.depth, 3),
            "x": round(self.x, 3),
            "y": round(self.y, 3),
        }


@dataclass
class ArrangeResult:
    placements: List[Placement] = field(default_factory=list)
    #: Pairs that overlap, and models that fall outside the bed.
    problems_ar: List[str] = field(default_factory=list)
    #: Models that could not be fitted at all.
    unplaced: List[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.problems_ar and not self.unplaced

    def as_dict(self) -> dict:
        return {
            "placements": [placement.as_dict() for placement in self.placements],
            "problems_ar": self.problems_ar,
            "unplaced": self.unplaced,
            "ok": self.ok,
        }


# --------------------------------------------------------------------------- #
# Checking an arrangement
# --------------------------------------------------------------------------- #


def _overlap(a: Placement, b: Placement, spacing: float) -> bool:
    """Whether two footprints come closer than `spacing`."""
    left_a, bottom_a, right_a, top_a = a.rect
    left_b, bottom_b, right_b, top_b = b.rect
    return (
        left_a - spacing < right_b
        and left_b - spacing < right_a
        and bottom_a - spacing < top_b
        and bottom_b - spacing < top_a
    )


def check(
    placements: Sequence[Placement],
    *,
    bed_width: float,
    bed_depth: float,
    spacing: float = DEFAULT_SPACING_MM,
    margin: float = DEFAULT_MARGIN_MM,
) -> List[str]:
    """Everything wrong with an arrangement, in plain Arabic.

    Returned rather than raised: this is what the app shows while the user is
    dragging, so it has to be describable as well as decidable.
    """
    problems: List[str] = []

    half_width = bed_width / 2 - margin
    half_depth = bed_depth / 2 - margin

    for placement in placements:
        left, bottom, right, top = placement.rect
        if left < -half_width or right > half_width or bottom < -half_depth or top > half_depth:
            problems.append(
                f"«{placement.model_id}» بره حدود السرير أو قريبة جدًا من الحرف."
            )

    for index, first in enumerate(placements):
        for second in placements[index + 1:]:
            if _overlap(first, second, spacing):
                problems.append(
                    f"«{first.model_id}» و«{second.model_id}» متلاصقين — "
                    f"لازم يكون بينهم {spacing:.0f} مم على الأقل."
                )

    return problems


# --------------------------------------------------------------------------- #
# Working one out
# --------------------------------------------------------------------------- #


def auto_arrange(
    footprints: Sequence[Tuple[str, float, float]],
    *,
    bed_width: float,
    bed_depth: float,
    spacing: float = DEFAULT_SPACING_MM,
    margin: float = DEFAULT_MARGIN_MM,
) -> ArrangeResult:
    """Lay parts out in rows, tallest first.

    Shelf packing: sort by depth, fill a row across the bed, start a new row
    when the next part will not fit, and stop when there is no room for another
    row. It is not optimal - optimal rectangle packing is NP-hard and nobody
    needs the last few percent of a print bed - but it is stable, which matters
    more: the same set of parts always comes out the same way, so the
    arrangement does not reshuffle itself every time the screen is opened.

    Sorted by depth rather than area so rows come out even. Packing a tall part
    next to a short one wastes the whole strip above the short one.
    """
    result = ArrangeResult()

    usable_width = bed_width - margin * 2
    usable_depth = bed_depth - margin * 2
    if usable_width <= 0 or usable_depth <= 0:
        raise ArrangeError("مساحة السرير صغيرة جدًا بعد ما نسيب هامش من الحرف.")

    ordered = sorted(footprints, key=lambda item: item[2], reverse=True)

    # Rows are built from the back of the bed forwards, then the whole block is
    # centred at the end - so a half-full plate sits in the middle rather than
    # bunched against one edge.
    rows: List[List[Placement]] = []
    row: List[Placement] = []
    row_width = 0.0
    row_depth = 0.0
    used_depth = 0.0

    def close_row() -> bool:
        """Commit the current row. False when it does not fit at all."""
        nonlocal row, row_width, row_depth, used_depth
        if not row:
            return True
        needed = row_depth if not rows else row_depth + spacing
        if used_depth + needed > usable_depth:
            return False
        used_depth += needed
        rows.append(row)
        row = []
        row_width = 0.0
        row_depth = 0.0
        return True

    for model_id, width, depth in ordered:
        if width > usable_width or depth > usable_depth:
            result.unplaced.append(model_id)
            result.problems_ar.append(
                f"«{model_id}» أكبر من مساحة السرير المتاحة "
                f"({usable_width:.0f}×{usable_depth:.0f} مم)."
            )
            continue

        addition = width if not row else width + spacing
        if row_width + addition > usable_width:
            if not close_row():
                result.unplaced.append(model_id)
                continue
            addition = width

        row.append(Placement(model_id=model_id, width=width, depth=depth))
        row_width += addition
        row_depth = max(row_depth, depth)

    if not close_row():
        for placement in row:
            result.unplaced.append(placement.model_id)
        row = []

    if result.unplaced and not any("أكبر من مساحة" in p for p in result.problems_ar):
        result.problems_ar.append(
            f"مفيش مكان على السرير لـ{len(result.unplaced)} قطعة."
        )

    # Lay the committed rows out and centre the whole block.
    total_depth = sum(
        max(p.depth for p in r) for r in rows
    ) + spacing * max(0, len(rows) - 1)

    cursor_y = total_depth / 2
    for current in rows:
        depth = max(placement.depth for placement in current)
        centre_y = cursor_y - depth / 2

        width = sum(placement.width for placement in current)
        width += spacing * max(0, len(current) - 1)
        cursor_x = -width / 2

        for placement in current:
            placement.x = cursor_x + placement.width / 2
            placement.y = centre_y
            cursor_x += placement.width + spacing

        cursor_y -= depth + spacing

    result.placements = [placement for current in rows for placement in current]
    return result


def bed_size_from_limits(limits: Dict[str, Tuple[Optional[float], Optional[float]]]) -> Tuple[float, float]:
    """Usable bed size from `position_min`/`position_max` pairs.

    `position_min` is usually negative - it is homing overtravel, not printable
    space - so the usable size starts at zero.
    """
    sizes: List[float] = []
    for axis in ("x", "y"):
        low, high = limits.get(axis, (None, None))
        if high is None:
            sizes.append(0.0)
            continue
        sizes.append(float(high) - max(float(low or 0.0), 0.0))
    return (sizes[0], sizes[1])
