"""Wait for the printer to cool, then sweep the finished part off.

The eject macro refuses while the printer is warm and it is right to: a printed
part is held down by nothing but the temperature difference between the plastic
and the sheet, so sweeping a warm one drives the toolhead into something still
glued down. That costs skipped steps, and it can cost a nozzle.

What was missing was the waiting. The app greyed the button out, said "the bed
is 58 degrees", and left it there - and after a cancelled print the heaters are
usually still holding a target, so the bed never cooled at all and the button
never came back.

This is the wait, and it lives on the Pi rather than in the phone. iOS suspends
an app within seconds of it leaving the screen, so an arm-and-wait implemented
on the phone only works while somebody is watching it - which is precisely the
case where they did not need the feature. The Pi is already awake and already
polling once a second.

Every guard is checked again at the moment of firing, against the live status,
because arming happens minutes earlier and the printer may have been asked to do
something else since.
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

log = logging.getLogger("neptune.eject")

#: Bed temperature the part reliably releases below. Mirrors the value the
#: generated EJECT_PART macro guards on - see app/klipper/macros.py.
MAX_BED_C = 40.0

#: Klipper's own default when [extruder] omits min_extrude_temp. A nozzle above
#: this drags a melted line across the part and drools on the sheet.
DEFAULT_MIN_EXTRUDE_C = 170.0

#: Give up waiting after this long. A printer that has not reached 40 C in two
#: hours is not cooling - the heater is still on, the sensor is wrong, or the
#: room is very hot - and an arm that stays live indefinitely is a toolhead that
#: sweeps the bed at some unpredictable point days later.
ARM_TIMEOUT_SECONDS = 2 * 3600

#: Ignore the first moments after arming. TURN_OFF_HEATERS has to actually reach
#: Klipper and the reported temperature has to start falling; firing off a stale
#: status that still says "cold" would sweep a bed that is not.
ARM_SETTLE_SECONDS = 5.0


@dataclass
class EjectArm:
    """A request to sweep the part off once the printer is cold enough."""

    armed_at: float
    #: Nozzle ceiling for this printer, read from its own min_extrude_temp.
    max_nozzle_c: float = DEFAULT_MIN_EXTRUDE_C
    #: Set when it fires or is abandoned, with the reason.
    finished_at: Optional[float] = None
    outcome: str = ""          # ejected | cancelled | timeout | failed
    message: str = ""

    @property
    def active(self) -> bool:
        return self.finished_at is None


def blockers(
    status: Any, *, max_nozzle_c: float, now: Optional[float] = None, armed_at: float = 0.0
) -> List[str]:
    """Everything standing between here and a safe sweep, in plain Arabic.

    Returned rather than raised: this is the same list the app shows while it
    waits, so it has to be describable as well as decidable.
    """
    reasons: List[str] = []
    if not status.online:
        reasons.append("الطابعة مش متوصلة.")
        return reasons
    if status.state in {"printing", "paused"}:
        reasons.append("فيه طبعة شغالة.")
    if status.bed.actual > MAX_BED_C:
        reasons.append(
            f"السرير {status.bed.actual:.0f}° ولازم يبقى تحت {MAX_BED_C:.0f}° "
            f"عشان القطعة تسيب."
        )
    if status.nozzle.actual > max_nozzle_c:
        reasons.append(f"الفوهة لسه سخنة ({status.nozzle.actual:.0f}°).")
    # A target still set means it is not cooling, it is being held.
    if status.bed.target > 0 or status.nozzle.target > 0:
        reasons.append("لسه فيه درجة حرارة مطلوبة - السخانات مش مقفولة.")
    if armed_at and (now or time.time()) - armed_at < ARM_SETTLE_SECONDS:
        reasons.append("بيستنى القراءة تستقر بعد قفل السخانات.")
    return reasons


class EjectWaiter:
    """Holds the arm and decides, once per status poll, whether to fire.

    Deliberately not a timer. The only thing that may fire this is a fresh
    printer status, so the decision is always made against a reading rather than
    against an elapsed guess.
    """

    def __init__(self) -> None:
        self.arm: Optional[EjectArm] = None
        #: The last completed attempt, kept so the app can say what happened to
        #: an arm the user was not watching.
        self.last: Optional[EjectArm] = None

    # ------------------------------------------------------------------ state
    @property
    def is_armed(self) -> bool:
        return self.arm is not None and self.arm.active

    def to_dict(self, status: Any = None, *, macro_installed: bool = False) -> Dict[str, Any]:
        arm = self.arm if self.is_armed else None
        payload: Dict[str, Any] = {
            "armed": arm is not None,
            "armed_at": arm.armed_at if arm else None,
            "macro_installed": macro_installed,
            "max_bed_c": MAX_BED_C,
            "max_nozzle_c": arm.max_nozzle_c if arm else DEFAULT_MIN_EXTRUDE_C,
            "blockers": [],
            "last_outcome": self.last.outcome if self.last else "",
            "last_message": self.last.message if self.last else "",
            "last_at": self.last.finished_at if self.last else None,
        }
        if status is not None:
            payload["blockers"] = blockers(
                status,
                max_nozzle_c=payload["max_nozzle_c"],
                armed_at=arm.armed_at if arm else 0.0,
            )
        return payload

    # ---------------------------------------------------------------- control
    def start(self, *, max_nozzle_c: float) -> EjectArm:
        self.arm = EjectArm(armed_at=time.time(), max_nozzle_c=max_nozzle_c)
        return self.arm

    def cancel(self) -> bool:
        if not self.is_armed:
            return False
        assert self.arm is not None
        self._finish("cancelled", "الانتظار اتلغى.")
        return True

    def _finish(self, outcome: str, message: str) -> None:
        if self.arm is None:
            return
        self.arm.finished_at = time.time()
        self.arm.outcome = outcome
        self.arm.message = message
        self.last = self.arm
        self.arm = None

    # ----------------------------------------------------------------- decide
    def should_fire(self, status: Any, *, now: Optional[float] = None) -> bool:
        """Whether the sweep may run against *this* reading.

        Returns False and abandons the arm on timeout, so a printer that never
        cools does not leave a toolhead primed to move hours later.
        """
        if not self.is_armed or self.arm is None:
            return False

        moment = now if now is not None else time.time()
        if moment - self.arm.armed_at > ARM_TIMEOUT_SECONDS:
            self._finish(
                "timeout",
                "عدت ساعتين والطابعة ماوصلتش لدرجة حرارة آمنة، فالانتظار اتلغى.",
            )
            return False

        return not blockers(
            status,
            max_nozzle_c=self.arm.max_nozzle_c,
            now=moment,
            armed_at=self.arm.armed_at,
        )

    def record_fired(self, ok: bool, message: str = "") -> None:
        if self.arm is None:
            return
        if ok:
            self._finish("ejected", message or "القطعة اتزقت من على السرير.")
        else:
            self._finish("failed", message or "الماكرو رفض ينفّذ.")
