"""When the queue may run itself, and - mostly - when it may not.

Every branch here ends in the toolhead moving across a bed with a finished part
on it, so the decision is kept away from the doing and proved on its own.
"""

from __future__ import annotations

import pytest

from app.printqueue.auto import (
    NOZZLE_SAFE_C,
    RELEASE_TEMP_C,
    Conditions,
    blockers,
    decide,
)


def ready(**overrides) -> Conditions:
    """A machine that has just finished a print and could carry on."""
    base = dict(
        enabled=True,
        has_eject_macro=True,
        printer_state="complete",
        last_result="completed",
        bed_temp=25.0,
        nozzle_temp=30.0,
        bed_clear=False,
        waiting_jobs=2,
    )
    base.update(overrides)
    return Conditions(**base)


# --------------------------------------------------------------------------- #
# Going ahead
# --------------------------------------------------------------------------- #


def test_a_cold_bed_after_a_finished_print_gets_swept():
    assert decide(ready()).action == "sweep"


def test_a_bed_somebody_already_cleared_starts_straight_away():
    # No reason to sweep an empty bed, and a sweep across bare PEI is a scratch
    # waiting to happen.
    assert decide(ready(bed_clear=True)).action == "start"


def test_every_decision_carries_a_key_the_app_can_show():
    for conditions in (ready(), ready(bed_clear=True), ready(enabled=False)):
        assert decide(conditions).reason_key


# --------------------------------------------------------------------------- #
# Waiting
# --------------------------------------------------------------------------- #


def test_a_hot_bed_waits_rather_than_refuses():
    # The bed is on its way down; this is a "not yet", not a "no".
    decision = decide(ready(bed_temp=RELEASE_TEMP_C + 5))

    assert decision.action == "wait"
    assert decision.reason_key == "queue.auto.cooling"


def test_a_hot_nozzle_waits_too():
    # It would drag a melted line across the part on the way past.
    assert decide(ready(nozzle_temp=NOZZLE_SAFE_C + 10)).action == "wait"


def test_nothing_happens_while_a_print_is_running():
    assert decide(ready(printer_state="printing")).action == "wait"
    assert decide(ready(printer_state="paused")).action == "wait"


def test_an_empty_queue_does_nothing_at_all():
    assert decide(ready(waiting_jobs=0)).action == "idle"


def test_switched_off_means_switched_off():
    assert decide(ready(enabled=False)).action == "idle"


# --------------------------------------------------------------------------- #
# Refusing
# --------------------------------------------------------------------------- #


def test_a_printer_without_the_ejector_macro_is_blocked_with_advice():
    # The macro is generated from the user's own printer.cfg and installed by
    # hand. Guessing at toolhead moves for a machine we cannot see is how a
    # gantry gets driven into a part.
    decision = decide(ready(has_eject_macro=False))

    assert decision.action == "blocked"
    assert "EJECT_PART" in decision.detail_ar


def test_a_cancelled_print_stops_the_queue_dead():
    # Something is on that bed that nobody has looked at.
    decision = decide(ready(last_result="cancelled"))

    assert decision.action == "blocked"
    assert decision.reason_key == "queue.auto.not_completed"


def test_a_failed_print_stops_the_queue_dead():
    assert decide(ready(last_result="error")).action == "blocked"


def test_a_sweep_that_did_not_clear_the_bed_is_not_tried_again():
    # Pushing a second time is how a part gets shoved into a corner.
    decision = decide(ready(swept=True))

    assert decision.action == "blocked"
    assert decision.reason_key == "queue.auto.sweep_failed"


def test_a_fault_disarms_everything_until_a_human_returns():
    decision = decide(ready(faulted=True))

    assert decision.action == "blocked"
    assert not decision.is_action


def test_being_switched_off_beats_every_other_reason():
    # The off switch is the one thing that cannot be argued with.
    assert decide(ready(enabled=False, faulted=True, bed_temp=200)).action == "idle"


# --------------------------------------------------------------------------- #
# What to tell the user
# --------------------------------------------------------------------------- #


def test_a_ready_machine_has_nothing_standing_in_the_way():
    assert blockers(ready()) == []


def test_everything_wrong_is_listed_at_once():
    # A screen that fixes one thing only to reveal the next is a screen people
    # give up on.
    problems = blockers(
        ready(has_eject_macro=False, faulted=True, last_result="cancelled")
    )

    assert len(problems) == 3


@pytest.mark.parametrize("state", ["printing", "paused"])
def test_a_running_print_is_never_an_action(state):
    assert not decide(ready(printer_state=state)).is_action
