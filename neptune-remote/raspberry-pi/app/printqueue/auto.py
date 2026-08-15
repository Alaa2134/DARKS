"""Running the queue without a human between the jobs.

The queue already knew what to print next and refused to start until somebody
confirmed the bed was clear. That confirmation is the whole safety of it: a
second print started on top of the first is a ruined plate and a nozzle full of
somebody else's part.

So this does not remove the confirmation - it *earns* it, by sweeping the bed
with the printer's own `EJECT_PART` macro and treating a successful sweep as the
answer. Everything else is refusal:

* No `EJECT_PART` on this machine and nothing happens at all. The macro is
  generated from the user's own `printer.cfg` and installed by hand; guessing at
  toolhead moves for a machine we cannot see is how a gantry gets driven into a
  part.
* The bed has to be cold enough that the part actually releases. Sweeping a warm
  one pushes the toolhead into something still stuck.
* The print has to have *finished*, not stopped. A cancelled or failed print
  leaves something on the bed that nobody has looked at, and the next job would
  print on top of whatever went wrong.
* One attempt per finished print, and the whole thing disarms after a failure.
  A loop that keeps retrying a sweep is a loop that keeps driving into the part
  it could not move.

The decision is kept separate from the doing so it can be tested without a
printer, because every branch here ends in the toolhead moving.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import List, Optional

log = logging.getLogger("neptune.queue.auto")

#: The macro that sweeps the bed. Generated for the user's machine by the macro
#: generator; this only ever checks whether they installed it.
EJECT_MACRO = "EJECT_PART"

#: Bed temperature the part is expected to release at. Above this the sweep is
#: postponed rather than refused - the bed is still on its way down.
RELEASE_TEMP_C = 40.0

#: The nozzle must be cold enough not to drag a melted line across the plate on
#: the way past. Matches what the macro itself refuses at.
NOZZLE_SAFE_C = 170.0


@dataclass
class Decision:
    """What to do right now, and why - in words the app can show."""

    #: sweep | start | wait | idle | blocked
    action: str = "idle"
    reason_key: str = ""
    #: Filled for `blocked`, so the screen can say what to fix.
    detail_ar: str = ""

    @property
    def is_action(self) -> bool:
        return self.action in {"sweep", "start"}


@dataclass
class Conditions:
    """Everything the decision depends on, gathered in one place."""

    enabled: bool = False
    #: Whether the printer's config actually has the ejector macro.
    has_eject_macro: bool = False
    printer_state: str = "standby"
    #: The result of the print that just ended, when one just ended.
    last_result: str = ""
    bed_temp: float = 0.0
    nozzle_temp: float = 0.0
    bed_clear: bool = False
    waiting_jobs: int = 0
    #: Set once a sweep has been attempted for this finished print, so a failed
    #: sweep is not retried forever.
    swept: bool = False
    #: Disarmed after any failure, until the user turns it back on.
    faulted: bool = False


def decide(conditions: Conditions) -> Decision:
    """The next step, or a reason there is not one."""
    if not conditions.enabled:
        return Decision(action="idle", reason_key="queue.auto.off")

    if conditions.faulted:
        return Decision(action="blocked", reason_key="queue.auto.faulted")

    if conditions.waiting_jobs <= 0:
        return Decision(action="idle", reason_key="queue.auto.empty")

    if conditions.printer_state in {"printing", "paused"}:
        return Decision(action="wait", reason_key="queue.auto.printing")

    # A bed somebody already cleared by hand needs no sweep.
    if conditions.bed_clear:
        return Decision(action="start", reason_key="queue.auto.starting")

    if not conditions.has_eject_macro:
        return Decision(
            action="blocked",
            reason_key="queue.auto.no_macro",
            detail_ar=(
                "الطابعة مفيهاش ماكرو EJECT_PART. مولّد الماكرو في الإعدادات "
                "بيطلعه من الـprinter.cfg بتاعك — ركّبه وبعدين رجّع شغّل ده."
            ),
        )

    # Only a print that *finished* leaves a bed worth sweeping unattended. A
    # cancelled or failed one leaves something nobody has looked at yet.
    if conditions.last_result and conditions.last_result != "completed":
        return Decision(
            action="blocked",
            reason_key="queue.auto.not_completed",
            detail_ar=(
                "آخر طباعة مخلصتش صح، فالسرير محتاج عين عليه قبل اللي بعدها."
            ),
        )

    if conditions.swept:
        # The sweep ran and the bed was still not confirmed clear. Something is
        # left on it, and pushing again is how a part gets shoved into a corner.
        return Decision(action="blocked", reason_key="queue.auto.sweep_failed")

    if conditions.bed_temp > RELEASE_TEMP_C or conditions.nozzle_temp > NOZZLE_SAFE_C:
        return Decision(action="wait", reason_key="queue.auto.cooling")

    return Decision(action="sweep", reason_key="queue.auto.sweeping")


def blockers(conditions: Conditions) -> List[str]:
    """Everything standing between this queue and running itself.

    Reported all at once rather than one at a time: a screen that fixes one
    thing only to reveal the next is a screen people give up on.
    """
    problems: List[str] = []
    if not conditions.has_eject_macro:
        problems.append("مفيش ماكرو EJECT_PART على الطابعة.")
    if conditions.faulted:
        problems.append("التشغيل التلقائي اتوقف بعد مشكلة — شغّله تاني بعد ما تتأكد.")
    if conditions.last_result and conditions.last_result != "completed":
        problems.append("آخر طباعة مخلصتش صح.")
    return problems
