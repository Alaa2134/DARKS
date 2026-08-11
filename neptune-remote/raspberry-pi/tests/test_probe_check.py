"""Diagnosing a probe that "doesn't work".

That phrase covers four faults with four different fixes, and Klipper reports
all of them as a failed home. Two readings - at rest and pressed - separate
them, and this is the table that does it.
"""

from __future__ import annotations

from app.klipper.probe_check import (
    GOOD_RANGE_MM,
    ProbeAccuracy,
    diagnose_accuracy,
    diagnose_wiring,
    parse_probe_accuracy,
    read_probe_state,
)

ACCURACY_OUTPUT = (
    "probe at 160.000,160.000 is z=1.812500\n"
    "probe accuracy results: maximum 1.850000, minimum 1.780000, range 0.070000, "
    "average 1.812000, median 1.810000, standard deviation 0.021000"
)


# --------------------------------------------------------------------------- #
# Reading the probe
# --------------------------------------------------------------------------- #


def test_query_probe_output_is_read_either_way():
    assert read_probe_state("probe: TRIGGERED") is True
    assert read_probe_state("probe: open") is False
    assert read_probe_state("ok") is None


# --------------------------------------------------------------------------- #
# The four-way table
# --------------------------------------------------------------------------- #


def test_open_then_triggered_is_a_working_probe():
    assert diagnose_wiring(False, True).fault == "working"


def test_triggered_at_rest_is_the_one_that_stops_g28_dead():
    """Klipper refuses to move at all: "Probe triggered prior to movement"."""
    result = diagnose_wiring(True, True, probe_pin="^PA8")
    assert result.fault == "stuck"
    assert not result.ok
    # And the fix it offers keeps the pull-up while flipping the polarity.
    assert result.suggested_config == {"probe": {"pin": "!^PA8"}}


def test_never_triggering_is_called_out_as_dangerous():
    """The nozzle is driven into the bed looking for a trigger that never comes."""
    result = diagnose_wiring(False, False)
    assert result.fault == "dead"
    assert "متعملش G28" in result.detail_ar


def test_backwards_readings_are_named_as_inverted():
    result = diagnose_wiring(True, False, probe_pin="^PA8")
    assert result.fault == "inverted"
    assert result.suggested_config == {"probe": {"pin": "!^PA8"}}


def test_the_first_reading_alone_does_not_condemn_a_good_probe():
    """Half the test is a real state, not an error - the app shows it before
    asking anyone to touch the probe."""
    result = diagnose_wiring(False, None)
    assert result.fault == "working"
    assert result.pressed is None


def test_an_unreadable_probe_is_not_guessed_at():
    assert diagnose_wiring(None, None).fault == "unreadable"


def test_flipping_a_pin_keeps_its_pullup_and_drops_its_inversion():
    assert diagnose_wiring(True, False, probe_pin="!^PA8").suggested_config == {
        "probe": {"pin": "^PA8"}
    }
    assert diagnose_wiring(True, False, probe_pin="PA8").suggested_config == {
        "probe": {"pin": "!PA8"}
    }


# --------------------------------------------------------------------------- #
# Repeatability, and the tolerance that follows from it
# --------------------------------------------------------------------------- #


def test_probe_accuracy_output_is_parsed():
    measured = parse_probe_accuracy(ACCURACY_OUTPUT)
    assert measured is not None
    assert abs(measured.range - 0.07) < 1e-9
    assert abs(measured.deviation - 0.021) < 1e-9


def test_unparseable_output_returns_nothing_rather_than_zeros():
    assert parse_probe_accuracy("ok") is None


def test_a_tolerance_tighter_than_the_probe_is_named_as_the_cause():
    """This is the exact fault that left this printer unable to home: a
    tolerance of 0.02 on a probe that varies by 0.07."""
    measured = parse_probe_accuracy(ACCURACY_OUTPUT)
    result = diagnose_accuracy(measured, 0.02)
    assert result.fault == "unrepeatable"
    assert "samples_tolerance" in result.detail_ar
    assert float(result.suggested_config["probe"]["samples_tolerance"]) > 0.07


def test_the_recommendation_leaves_headroom_over_what_was_measured():
    """A tolerance set exactly at the measured range fails about half the time -
    the range is what happened once, not a ceiling."""
    measured = parse_probe_accuracy(ACCURACY_OUTPUT)
    assert measured.recommended_tolerance > measured.range


def test_a_hopeless_probe_is_called_mechanical_rather_than_retuned():
    """Past a point, no tolerance rescues it: any value wide enough to pass is
    wide enough to make the measurement meaningless."""
    measured = ProbeAccuracy(
        maximum=2.1, minimum=1.8, range=0.3, average=1.95, median=1.95, deviation=0.09
    )
    result = diagnose_accuracy(measured, 0.05)
    assert result.fault == "unrepeatable"
    assert result.accuracy.verdict == "mechanical"
    # No config change offered - there is no number that fixes this.
    assert result.suggested_config == {}


def test_a_good_probe_inside_its_tolerance_passes():
    measured = ProbeAccuracy(
        maximum=1.81, minimum=1.80, range=GOOD_RANGE_MM - 0.01,
        average=1.805, median=1.805, deviation=0.004,
    )
    assert diagnose_accuracy(measured, 0.05).fault == "working"
