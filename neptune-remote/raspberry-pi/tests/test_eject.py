"""Waiting for the printer to cool, then sweeping the part off.

Every guard here protects the same thing: a part that has not let go yet. The
toolhead sweeping a bed that is still warm is driven into something glued down,
which skips steps and can cost a nozzle - so "not yet" has to be the answer far
more often than "go".
"""

from __future__ import annotations

import time

import pytest

from app.eject import (
    ARM_TIMEOUT_SECONDS,
    ARM_SETTLE_SECONDS,
    MAX_BED_C,
    EjectWaiter,
    blockers,
)
from app.schemas import PrinterStatusResponse, TemperatureBlock


def status(*, bed=25.0, nozzle=30.0, state="standby", online=True,
           bed_target=0.0, nozzle_target=0.0) -> PrinterStatusResponse:
    return PrinterStatusResponse(
        online=online,
        state=state,
        bed=TemperatureBlock(actual=bed, target=bed_target),
        nozzle=TemperatureBlock(actual=nozzle, target=nozzle_target),
    )


def armed(waiter: EjectWaiter, *, age: float = 60.0) -> None:
    waiter.start(max_nozzle_c=170.0)
    waiter.arm.armed_at = time.time() - age


# --------------------------------------------------------------------------- #
# When it may fire
# --------------------------------------------------------------------------- #


def test_a_cold_idle_printer_fires():
    waiter = EjectWaiter()
    armed(waiter)
    assert waiter.should_fire(status())


def test_a_warm_bed_does_not_fire():
    """The whole reason the feature exists: the part is still stuck."""
    waiter = EjectWaiter()
    armed(waiter)
    assert not waiter.should_fire(status(bed=MAX_BED_C + 1))
    # And it stays armed - waiting is the expected state, not a failure.
    assert waiter.is_armed


def test_a_hot_nozzle_does_not_fire():
    waiter = EjectWaiter()
    armed(waiter)
    assert not waiter.should_fire(status(nozzle=200))


def test_a_running_print_does_not_fire():
    waiter = EjectWaiter()
    armed(waiter)
    assert not waiter.should_fire(status(state="printing"))
    assert not waiter.should_fire(status(state="paused"))


def test_an_offline_printer_does_not_fire():
    waiter = EjectWaiter()
    armed(waiter)
    assert not waiter.should_fire(status(online=False))


def test_a_held_target_does_not_fire():
    """Cold *now* is not the same as cooling.

    A bed reading 30 with a target of 60 is on its way up, and by the time the
    toolhead is over it the part is stuck down again.
    """
    waiter = EjectWaiter()
    armed(waiter)
    assert not waiter.should_fire(status(bed=30, bed_target=60))


def test_it_does_not_fire_on_the_reading_it_was_armed_with():
    """TURN_OFF_HEATERS has to reach Klipper before any reading means anything."""
    waiter = EjectWaiter()
    waiter.start(max_nozzle_c=170.0)
    assert not waiter.should_fire(status())
    assert waiter.should_fire(status(), now=time.time() + ARM_SETTLE_SECONDS + 1)


def test_nothing_fires_when_nothing_is_armed():
    assert not EjectWaiter().should_fire(status())


# --------------------------------------------------------------------------- #
# Giving up
# --------------------------------------------------------------------------- #


def test_an_arm_that_never_cools_is_abandoned():
    """A live arm is a toolhead primed to move. It must not outlive the session
    that asked for it by hours."""
    waiter = EjectWaiter()
    armed(waiter, age=ARM_TIMEOUT_SECONDS + 60)
    assert not waiter.should_fire(status(bed=90))
    assert not waiter.is_armed
    assert waiter.last.outcome == "timeout"


def test_cancelling_stops_it():
    waiter = EjectWaiter()
    armed(waiter)
    assert waiter.cancel()
    assert not waiter.is_armed
    assert not waiter.should_fire(status())
    assert waiter.last.outcome == "cancelled"


def test_cancelling_nothing_is_not_an_error_but_is_reported():
    assert EjectWaiter().cancel() is False


def test_firing_disarms_so_it_cannot_run_twice():
    waiter = EjectWaiter()
    armed(waiter)
    assert waiter.should_fire(status())
    waiter.record_fired(True)
    assert not waiter.is_armed
    assert not waiter.should_fire(status())
    assert waiter.last.outcome == "ejected"


def test_a_refused_macro_is_recorded_as_a_failure():
    waiter = EjectWaiter()
    armed(waiter)
    waiter.record_fired(False, "EJECT_PART: bed is 55C")
    assert waiter.last.outcome == "failed"
    assert "55C" in waiter.last.message


# --------------------------------------------------------------------------- #
# What the app shows while it waits
# --------------------------------------------------------------------------- #


def test_the_blockers_are_the_same_ones_that_decide():
    reasons = blockers(status(bed=60, nozzle=200), max_nozzle_c=170.0)
    assert any("السرير" in reason for reason in reasons)
    assert any("الفوهة" in reason for reason in reasons)


def test_a_ready_printer_lists_no_blockers():
    assert blockers(status(), max_nozzle_c=170.0) == []


def test_an_offline_printer_reports_only_that():
    assert blockers(status(online=False, bed=90), max_nozzle_c=170.0) == [
        "الطابعة مش متوصلة."
    ]


def test_the_status_payload_carries_the_live_blockers():
    waiter = EjectWaiter()
    armed(waiter)
    payload = waiter.to_dict(status(bed=70), macro_installed=True)
    assert payload["armed"] is True
    assert payload["macro_installed"] is True
    assert payload["blockers"]
