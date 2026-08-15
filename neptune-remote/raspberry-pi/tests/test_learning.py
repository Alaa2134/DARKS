"""Learning from this printer's own results.

The risk here is a percentage that looks authoritative and is not. Two prints
is not a success rate, an interrupted print is not the profile's fault, and
"PETG is bad" is a different claim from "PETG at 0.28 is bad". So most of these
tests are about refusing to conclude.
"""

from __future__ import annotations

import pytest

from app.learning.profiles import (
    MIN_SAMPLES,
    Outcome,
    duration_accuracy,
    insights,
    report,
    summarise,
)

HOUR = 3600.0


def outcome(result="completed", *, material="PLA", profile="standard",
            layer=0.2, duration=2 * HOUR, estimated=2 * HOUR):
    return Outcome(
        result=result, duration=duration, estimated_seconds=estimated,
        filament_type=material, print_profile=profile, layer_height=layer,
    )


def find(items, item_id):
    return next((item for item in items if item.id == item_id), None)


# --------------------------------------------------------------------------- #
# Refusing to conclude
# --------------------------------------------------------------------------- #


class TestSampleSize:
    def test_a_single_failure_is_not_a_success_rate(self):
        combinations = summarise([outcome("cancelled")])
        assert combinations[0].success_rate is None
        assert combinations[0].is_conclusive is False

    def test_below_the_minimum_nothing_is_claimed(self):
        combinations = summarise([outcome() for _ in range(MIN_SAMPLES - 1)])
        found = insights(combinations)
        assert find(found, "not_enough_data") is not None
        assert find(found, "best_combination") is None

    def test_the_shortfall_is_stated(self):
        found = insights(summarise([outcome(), outcome()]))
        message = find(found, "not_enough_data").detail_ar
        assert "2" in message

    def test_an_empty_history_says_so_rather_than_crashing(self):
        payload = report([])
        assert payload["total_prints"] == 0
        assert payload["insights"][0]["id"] == "not_enough_data"

    def test_at_the_minimum_a_verdict_appears(self):
        found = insights(summarise([outcome() for _ in range(MIN_SAMPLES)]))
        assert find(found, "best_combination") is not None


# --------------------------------------------------------------------------- #
# What counts as evidence
# --------------------------------------------------------------------------- #


class TestWhatCounts:
    def test_an_interrupted_print_is_not_the_profiles_fault(self):
        """A power cut says nothing about the settings that were loaded."""
        outcomes = [outcome() for _ in range(4)] + [outcome("interrupted")]
        combinations = summarise(outcomes)
        assert combinations[0].total == 4
        assert combinations[0].success_rate == 1.0

    def test_an_in_progress_print_is_not_counted_yet(self):
        combinations = summarise([outcome("in_progress"), outcome()])
        assert combinations[0].total == 1

    def test_combinations_are_kept_apart_by_layer_height(self):
        """"PETG is bad" and "PETG at 0.28 is bad" are different claims."""
        outcomes = [outcome(material="PETG", layer=0.20) for _ in range(4)]
        outcomes += [outcome("cancelled", material="PETG", layer=0.28) for _ in range(4)]
        combinations = summarise(outcomes)
        assert len(combinations) == 2
        rates = {item.layer_height: item.success_rate for item in combinations}
        assert rates[0.2] == 1.0
        assert rates[0.28] == 0.0

    def test_missing_metadata_groups_under_unknown_rather_than_being_dropped(self):
        combinations = summarise([Outcome(result="completed")])
        assert combinations[0].filament_type == "غير معروف"


# --------------------------------------------------------------------------- #
# When it failed matters as much as that it failed
# --------------------------------------------------------------------------- #


class TestFailureTiming:
    def test_a_print_that_died_at_five_percent_is_an_early_failure(self):
        item = outcome("cancelled", duration=0.1 * HOUR, estimated=2 * HOUR)
        assert item.failed_early is True

    def test_a_print_that_died_at_eighty_percent_is_not(self):
        item = outcome("cancelled", duration=1.6 * HOUR, estimated=2 * HOUR)
        assert item.failed_early is False

    def test_without_an_estimate_the_timing_is_unknown_not_assumed(self):
        item = outcome("cancelled", duration=0.1 * HOUR, estimated=None)
        assert item.failed_early is None

    def test_clustered_early_failures_are_diagnosed_as_adhesion(self):
        outcomes = [outcome(material="PETG")]
        outcomes += [
            outcome("cancelled", material="PETG", duration=0.1 * HOUR, estimated=3 * HOUR)
            for _ in range(4)
        ]
        found = insights(summarise(outcomes))
        early = find(found, "early_failures")
        assert early is not None
        assert "الطبقة الأولى" in early.detail_ar
        assert "حرارة السرير" in early.suggestion_ar

    def test_late_failures_get_different_advice(self):
        outcomes = [outcome(material="ABS")]
        outcomes += [
            outcome("cancelled", material="ABS", duration=2.5 * HOUR, estimated=3 * HOUR)
            for _ in range(4)
        ]
        found = insights(summarise(outcomes))
        poor = find(found, "poor_combination")
        assert poor is not None
        assert "برج الحرارة" in poor.suggestion_ar


# --------------------------------------------------------------------------- #
# Recommendations
# --------------------------------------------------------------------------- #


class TestInsights:
    def test_the_most_reliable_combination_is_named(self):
        outcomes = [outcome(material="PLA", profile="standard") for _ in range(8)]
        outcomes += [outcome("cancelled", material="PETG") for _ in range(4)]
        best = find(insights(summarise(outcomes)), "best_combination")
        assert best is not None
        assert "PLA" in best.detail_ar
        assert best.samples == 8

    def test_a_combination_that_mostly_works_is_not_called_out(self):
        outcomes = [outcome() for _ in range(9)] + [outcome("cancelled")]
        found = insights(summarise(outcomes))
        assert find(found, "poor_combination") is None
        assert find(found, "early_failures") is None

    def test_a_material_failing_across_every_profile_is_named_once(self):
        """Not once per profile - that is the same finding repeated."""
        outcomes = []
        for profile in ("standard", "quality"):
            outcomes += [outcome(material="Nylon", profile=profile)]
            outcomes += [
                outcome("cancelled", material="Nylon", profile=profile,
                        duration=1.5 * HOUR, estimated=2 * HOUR)
                for _ in range(2)
            ]
        found = insights(summarise(outcomes))
        material = [item for item in found if item.id == "material_struggles"]
        assert len(material) == 1
        assert "جفّفها" in material[0].suggestion_ar

    def test_every_insight_carries_its_sample_count(self):
        outcomes = [outcome() for _ in range(6)]
        for item in insights(summarise(outcomes)):
            assert item.samples > 0


# --------------------------------------------------------------------------- #
# Per-material time accuracy
# --------------------------------------------------------------------------- #


class TestDurationAccuracy:
    def test_it_reports_how_far_off_the_slicer_runs_per_material(self):
        outcomes = [
            outcome(material="PETG", duration=2.4 * HOUR, estimated=2 * HOUR)
            for _ in range(3)
        ]
        accuracy = duration_accuracy(outcomes)
        assert accuracy["PETG"] == pytest.approx(1.2, abs=0.01)

    def test_too_few_samples_for_a_material_produces_nothing(self):
        assert duration_accuracy([outcome(material="ASA")]) is None

    def test_failed_prints_are_excluded(self):
        """They stopped early, so their duration says nothing about the file."""
        outcomes = [
            outcome("cancelled", material="PLA", duration=0.2 * HOUR, estimated=2 * HOUR)
            for _ in range(5)
        ]
        assert duration_accuracy(outcomes) is None


# --------------------------------------------------------------------------- #
# The payload
# --------------------------------------------------------------------------- #


class TestReport:
    def test_the_report_is_serialisable_and_complete(self):
        outcomes = [outcome() for _ in range(5)]
        payload = report(outcomes)
        assert payload["total_prints"] == 5
        assert payload["min_samples"] == MIN_SAMPLES
        assert payload["combinations"][0]["conclusive"] is True
        assert payload["combinations"][0]["label_ar"]

    def test_combinations_are_ordered_by_how_much_they_are_used(self):
        outcomes = [outcome(material="PLA") for _ in range(6)]
        outcomes += [outcome(material="PETG") for _ in range(2)]
        payload = report(outcomes)
        assert payload["combinations"][0]["filament_type"] == "PLA"
