"""Parse ``SCREWS_TILT_CALCULATE`` output into per-screw adjustments.

Klipper reports each screw as a clock reading:

    screw (front left) : x=30.0, y=30.0, z=2.10000 : base
    front right : x=270.0, y=30.0, z=2.32500 : adjust CW 00:21

The clock notation is unhelpful on a phone, so each result also carries the
fraction of a full turn, which is what a person actually does with a knob.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

#: A `base` line, or an `adjust CW 00:21` line.
_SCREW_RE = re.compile(
    r"^\s*(?:screw\s+)?(?P<name>[^:]+?)\s*:\s*"
    r"x\s*=\s*(?P<x>-?[\d.]+)\s*,\s*"
    r"y\s*=\s*(?P<y>-?[\d.]+)\s*,\s*"
    r"z\s*=\s*(?P<z>-?[\d.]+)"
    r"(?:\s*:\s*(?P<verdict>.+))?\s*$",
    re.IGNORECASE,
)
_ADJUST_RE = re.compile(
    r"adjust\s+(?P<dir>CW|CCW)\s+(?P<hours>\d{1,2}):(?P<minutes>\d{2})", re.IGNORECASE
)
_BASE_RE = re.compile(r"\bbase\b", re.IGNORECASE)

#: Below this fraction of a turn, the screw is close enough to leave alone.
#: Klipper itself stops reporting adjustments under about a minute (1/60 turn).
GOOD_ENOUGH_TURNS = 0.02
#: Above this, the bed is far enough out that one pass will not settle it.
SEVERE_TURNS = 0.5


@dataclass
class ScrewResult:
    """One bed screw, as measured."""

    name: str                     # Klipper's own label, e.g. "front left"
    x: float
    y: float
    z: float
    is_base: bool = False
    direction: str = ""           # "CW" | "CCW" | "" when nothing to do
    hours: int = 0
    minutes: int = 0

    @property
    def clock(self) -> str:
        return f"{self.hours:02d}:{self.minutes:02d}"

    @property
    def turns(self) -> float:
        """How far to turn the screw, in full turns.

        Klipper's clock notation is *one full turn per hour*: the minutes field
        counts sixtieths of a rotation, and the hours field counts whole
        rotations. So ``00:21`` is 21/60 = 0.35 of a turn, and ``01:12`` is one
        and a fifth turns - not a twelfth of anything.
        """
        return self.hours + self.minutes / 60.0

    @property
    def signed_turns(self) -> float:
        """Positive clockwise, negative counter-clockwise."""
        return self.turns if self.direction.upper() == "CW" else -self.turns

    @property
    def adjusted(self) -> bool:
        return self.turns > GOOD_ENOUGH_TURNS

    @property
    def severity(self) -> str:
        if self.is_base or not self.adjusted:
            return "ok"
        return "high" if self.turns >= SEVERE_TURNS else "medium"

    @property
    def instruction(self) -> str:
        if self.is_base:
            return "Reference screw - do not turn this one."
        if not self.adjusted:
            return "Close enough - leave it."
        way = "clockwise" if self.direction.upper() == "CW" else "counter-clockwise"
        return f"Turn {way} about {self.turns:.2f} of a turn ({self.clock})."

    def as_dict(self) -> Dict[str, Any]:
        return {
            "name": self.name,
            "position_key": position_key(self.name),
            "x": self.x,
            "y": self.y,
            "z": self.z,
            "is_base": self.is_base,
            "direction": self.direction.upper(),
            "clock": self.clock,
            "turns": round(self.turns, 3),
            "signed_turns": round(self.signed_turns, 3),
            "adjusted": self.adjusted,
            "severity": self.severity,
            "instruction": self.instruction,
        }


@dataclass
class ScrewsTiltResult:
    screws: List[ScrewResult] = field(default_factory=list)
    raw: str = ""
    parse_failed: bool = False

    @property
    def base(self) -> Optional[ScrewResult]:
        return next((s for s in self.screws if s.is_base), None)

    @property
    def worst(self) -> Optional[ScrewResult]:
        candidates = [s for s in self.screws if not s.is_base]
        return max(candidates, key=lambda s: s.turns) if candidates else None

    @property
    def max_turns(self) -> float:
        worst = self.worst
        return worst.turns if worst else 0.0

    @property
    def z_spread(self) -> float:
        """Difference between the highest and lowest measured point, mm."""
        if not self.screws:
            return 0.0
        heights = [s.z for s in self.screws]
        return max(heights) - min(heights)

    @property
    def level(self) -> bool:
        """True when every screw is inside the good-enough band."""
        return bool(self.screws) and not any(s.adjusted for s in self.screws)

    @property
    def verdict(self) -> str:
        if not self.screws:
            return "unknown"
        if self.level:
            return "level"
        return "poor" if self.max_turns >= SEVERE_TURNS else "adjust"

    @property
    def summary(self) -> str:
        if self.parse_failed:
            return "Could not read the screw measurements."
        if not self.screws:
            return "No screws were measured."
        if self.level:
            return "All screws are within tolerance."
        pending = sum(1 for s in self.screws if s.adjusted)
        worst = self.worst
        detail = f"the worst is about {worst.turns:.2f} of a turn" if worst else ""
        return f"{pending} screw(s) need adjusting - {detail}."

    def as_dict(self) -> Dict[str, Any]:
        return {
            "verdict": self.verdict,
            "level": self.level,
            "summary": self.summary,
            "max_turns": round(self.max_turns, 3),
            "z_spread": round(self.z_spread, 4),
            "screws": [s.as_dict() for s in self.screws],
            "parse_failed": self.parse_failed,
        }


#: Klipper labels vary between configs. Map the common spellings onto the six
#: positions a Neptune 3 Plus bed actually has, so the UI can lay them out.
_POSITION_ALIASES = {
    "front left": "left_front",
    "left front": "left_front",
    "center left": "left_middle",
    "left center": "left_middle",
    "middle left": "left_middle",
    "left middle": "left_middle",
    "back left": "left_rear",
    "rear left": "left_rear",
    "left back": "left_rear",
    "left rear": "left_rear",
    "front right": "right_front",
    "right front": "right_front",
    "center right": "right_middle",
    "right center": "right_middle",
    "middle right": "right_middle",
    "right middle": "right_middle",
    "back right": "right_rear",
    "rear right": "right_rear",
    "right back": "right_rear",
    "right rear": "right_rear",
}


def position_key(name: str) -> str:
    """Normalise Klipper's screw label to a stable layout key.

    Returns ``""`` when the label is not one of the recognised positions - the
    UI then falls back to Klipper's own text rather than guessing a position.
    """
    cleaned = re.sub(r"[^a-z ]+", " ", name.lower())
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    if cleaned in _POSITION_ALIASES:
        return _POSITION_ALIASES[cleaned]
    words = [w for w in cleaned.split() if w != "screw"]
    return _POSITION_ALIASES.get(" ".join(words), "")


def parse_screws_tilt(output: str) -> ScrewsTiltResult:
    """Parse the console text Klipper prints for SCREWS_TILT_CALCULATE."""
    result = ScrewsTiltResult(raw=output or "")
    if not output:
        result.parse_failed = True
        return result

    for line in output.splitlines():
        match = _SCREW_RE.match(line)
        if not match:
            continue

        name = re.sub(r"^screw\s+", "", match.group("name").strip(), flags=re.IGNORECASE)
        name = name.strip().strip("()").strip()

        screw = ScrewResult(
            name=name,
            x=float(match.group("x")),
            y=float(match.group("y")),
            z=float(match.group("z")),
        )

        verdict = (match.group("verdict") or "").strip()
        if _BASE_RE.search(verdict):
            screw.is_base = True
        else:
            adjust = _ADJUST_RE.search(verdict)
            if adjust:
                screw.direction = adjust.group("dir").upper()
                screw.hours = int(adjust.group("hours"))
                screw.minutes = int(adjust.group("minutes"))

        result.screws.append(screw)

    if not result.screws:
        result.parse_failed = True
    return result
