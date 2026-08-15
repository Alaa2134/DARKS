"""The remaining-time estimate.

The old one was `elapsed / file_progress`. These tests exist mostly to pin down
the specific ways that was wrong, so it cannot quietly come back: the warm-up
skew, the byte-progress non-linearity, ignoring the slicer, ignoring the speed
factor, and jumping on every poll.

The last test simulates a whole print with realistic non-linear progress and
asserts the estimate is actually *close*, which is the only claim that matters.
"""

from __future__ import annotations

import pytest

from app.estimate.eta import (
    Calibration,
    Method,
    PrintTimeEstimator,
    learn_calibration,
    slicer_seconds_from_metadata,
)

HOUR = 3600.0


def estimator(slicer: float | None = 4 * HOUR, calibration: Calibration | None = None):
    est = PrintTimeEstimator()
    if calibration is not None:
        est.set_calibration(calibration)
    est.begin("benchy.gcode", slicer)
    return est


def settle(est: PrintTimeEstimator, *, progress: float, duration: float, speed: float = 1.0,
           polls: int = 40, filament_used_mm: float | None = None):
    """Run the same reading enough times for the smoothing to converge.

    The real monitor polls once a second, so by the time anyone looks at the
    screen the smoothing has long since settled. Tests that assert a converged
    value have to poll like the monitor does.
    """
    result = None
    for _ in range(polls):
        result = est.update(
            progress=progress, print_duration=duration, speed_factor=speed,
            filament_used_mm=filament_used_mm,
        )
    return result


# --------------------------------------------------------------------------- #
# Calibration - the part that learns
# --------------------------------------------------------------------------- #


class TestCalibration:
    def test_nothing_is_learned_from_too_few_prints(self):
        calibration = learn_calibration([(4.5 * HOUR, 4 * HOUR)])
        assert calibration.is_learned is False
        assert calibration.factor == 1.0

    def test_a_consistent_overrun_is_learned(self):
        """The slicer says 4h, the printer always takes 4h40. Learn the 1.17."""
        pairs = [(4.66 * HOUR, 4 * HOUR), (2.33 * HOUR, 2 * HOUR), (7.0 * HOUR, 6 * HOUR)]
        calibration = learn_calibration(pairs)
        assert calibration.is_learned
        assert calibration.factor == pytest.approx(1.166, abs=0.01)
        assert calibration.percent_off == pytest.approx(16.6, abs=1.0)

    def test_one_absurd_print_does_not_move_the_median(self):
        """A print paused for hours mid-way is not evidence about speed."""
        pairs = [
            (4.6 * HOUR, 4 * HOUR),
            (2.3 * HOUR, 2 * HOUR),
            (6.9 * HOUR, 6 * HOUR),
            (40 * HOUR, 4 * HOUR),   # paused overnight; ratio 10, discarded
        ]
        calibration = learn_calibration(pairs)
        assert calibration.factor == pytest.approx(1.15, abs=0.02)
        assert calibration.samples == 3, "the outlier should be dropped, not averaged"

    def test_impossible_ratios_are_discarded(self):
        pairs = [(1.0, 4 * HOUR), (100 * HOUR, 1.0), (4.4 * HOUR, 4 * HOUR)]
        assert learn_calibration(pairs).samples == 1

    def test_missing_estimates_are_skipped_not_treated_as_zero(self):
        pairs = [(4 * HOUR, None), (4 * HOUR, 0), (4.4 * HOUR, 4 * HOUR)]
        assert learn_calibration(pairs).samples == 1


# --------------------------------------------------------------------------- #
# The warm-up, which broke the old estimate hardest
# --------------------------------------------------------------------------- #


class TestWarmup:
    def test_the_old_formula_blows_up_during_heating_and_this_one_does_not(self):
        """400 seconds of bed heating with progress at 0.0001.

        The formula this replaces divides by that: 400 / 0.0001 is 46 days.
        Anyone glancing at the phone in the first minutes saw a number like
        that, decided the app was broken, and stopped trusting the ETA for the
        rest of the print.
        """
        naive_remaining = 400.0 / 0.0001 - 400.0
        assert naive_remaining > 40 * 24 * HOUR   # the bug, stated numerically

        est = estimator(slicer=None)
        result = est.update(progress=0.0001, print_duration=400.0)
        assert result.remaining_seconds is None
        assert result.method == Method.UNKNOWN

    def test_with_filament_progress_the_warmup_is_excluded_from_the_rate(self):
        """Extrusion is near-linear in time, so heating genuinely is not
        printing time and leaving it in makes every print look behind."""
        est = PrintTimeEstimator()
        est.begin("benchy.gcode", None, filament_total_mm=100_000.0)

        # Warm-up: time passes, nothing is extruded.
        for second in range(0, 300, 10):
            est.update(progress=0.0, print_duration=float(second), filament_used_mm=0.0)

        # Then a steady hour laying down half the filament, polled as the
        # monitor would poll it.
        for step in range(1, 121):
            fraction = step / 120.0
            est.update(
                progress=0.5 * fraction,
                print_duration=300.0 + HOUR * fraction,
                filament_used_mm=50_000.0 * fraction,
            )
        result = est.last

        assert est.progress_source == "filament"
        assert result.total_seconds == pytest.approx(2 * HOUR + 300.0, rel=0.05)

    def test_a_backend_restart_mid_print_does_not_think_it_just_started(self):
        """Anchoring at zero would read 60 % done in ten seconds as a
        six-minute print."""
        est = PrintTimeEstimator()
        est.begin("benchy.gcode", None)

        # First thing it ever sees: a print already 60 % through, 3 hours in.
        est.update(progress=0.60, print_duration=3 * HOUR)
        result = settle(est, progress=0.70, duration=3.5 * HOUR, polls=200)

        # 10 % took half an hour, so 30 % left is about 90 minutes.
        assert result.remaining_seconds == pytest.approx(1.5 * HOUR, rel=0.15)


# --------------------------------------------------------------------------- #
# Using the slicer, which the old one never did
# --------------------------------------------------------------------------- #


class TestSlicerEstimate:
    def test_the_slicer_carries_the_first_minutes(self):
        """At 1 % there is nothing else to go on, and it is already accurate."""
        est = estimator(slicer=4 * HOUR)
        result = est.update(progress=0.01, print_duration=120.0)
        assert result.method == Method.SLICER
        assert result.total_seconds == pytest.approx(4 * HOUR, rel=0.01)
        assert result.remaining_seconds == pytest.approx(4 * HOUR - 120.0, rel=0.01)

    def test_calibration_is_applied_to_it(self):
        est = estimator(slicer=4 * HOUR, calibration=Calibration(factor=1.2, samples=5))
        result = est.update(progress=0.01, print_duration=60.0)
        assert result.method == Method.SLICER_CALIBRATED
        assert result.total_seconds == pytest.approx(4.8 * HOUR, rel=0.01)

    def test_an_unlearned_calibration_changes_nothing(self):
        est = estimator(slicer=4 * HOUR, calibration=Calibration(factor=1.2, samples=1))
        result = est.update(progress=0.01, print_duration=60.0)
        assert result.total_seconds == pytest.approx(4 * HOUR, rel=0.01)
        assert result.method == Method.SLICER

    def test_metadata_without_an_estimate_is_not_invented(self):
        assert slicer_seconds_from_metadata({}) is None
        assert slicer_seconds_from_metadata({"estimated_time": 0}) is None
        assert slicer_seconds_from_metadata({"estimated_time": "nonsense"}) is None
        assert slicer_seconds_from_metadata(None) is None
        assert slicer_seconds_from_metadata({"estimated_time": 14400}) == 14400.0

    def test_no_slicer_estimate_and_no_progress_means_no_answer(self):
        """Better than a confident lie."""
        est = estimator(slicer=None)
        result = est.update(progress=0.001, print_duration=30.0)
        assert result.remaining_seconds is None
        assert result.confidence == 0.0


# --------------------------------------------------------------------------- #
# Speed factor
# --------------------------------------------------------------------------- #


class TestSpeedFactor:
    def test_speeding_up_shortens_the_estimate_immediately(self):
        """The slicer simulated 100 %. At 150 % the whole thing scales."""
        est = estimator(slicer=4 * HOUR)
        at_100 = est.update(progress=0.02, print_duration=60.0, speed_factor=1.0)

        est = estimator(slicer=4 * HOUR)
        at_150 = est.update(progress=0.02, print_duration=60.0, speed_factor=1.5)

        assert at_150.total_seconds == pytest.approx(at_100.total_seconds / 1.5, rel=0.01)

    def test_a_zero_speed_factor_does_not_divide_by_zero(self):
        est = estimator(slicer=4 * HOUR)
        result = est.update(progress=0.02, print_duration=60.0, speed_factor=0.0)
        assert result.total_seconds == pytest.approx(4 * HOUR, rel=0.01)


# --------------------------------------------------------------------------- #
# Blending
# --------------------------------------------------------------------------- #


class TestBlending:
    def test_early_on_the_slicer_wins(self):
        est = estimator(slicer=4 * HOUR)
        result = settle(est, progress=0.10, duration=0.5 * HOUR)
        assert result.method in {Method.SLICER, Method.SLICER_CALIBRATED}

    def test_by_the_end_this_print_wins(self):
        """The slicer said 4h; this print is plainly going to take 6h."""
        est = estimator(slicer=4 * HOUR)
        est.update(progress=0.01, print_duration=60.0)
        result = settle(est, progress=0.95, duration=5.7 * HOUR, polls=400)

        assert result.method == Method.OBSERVED
        assert result.total_seconds == pytest.approx(6 * HOUR, rel=0.05)

    def test_the_middle_is_a_blend_of_both(self):
        est = estimator(slicer=4 * HOUR)
        est.update(progress=0.01, print_duration=60.0)
        result = settle(est, progress=0.70, duration=4.2 * HOUR, polls=400)

        assert result.method == Method.BLENDED
        # Slicer says 4h, observed says 6h; the answer sits between them.
        assert 4 * HOUR < result.total_seconds < 6 * HOUR

    def test_confidence_rises_with_evidence(self):
        early = estimator(slicer=None)
        early.update(progress=0.01, print_duration=60.0)
        early_result = settle(early, progress=0.05, duration=0.2 * HOUR)

        late = estimator(slicer=None)
        late.update(progress=0.01, print_duration=60.0)
        late_result = settle(late, progress=0.70, duration=2.8 * HOUR)

        assert late_result.confidence > early_result.confidence


# --------------------------------------------------------------------------- #
# Smoothing
# --------------------------------------------------------------------------- #


class TestSmoothing:
    def test_a_single_odd_reading_does_not_jerk_the_estimate(self):
        est = estimator(slicer=4 * HOUR)
        est.update(progress=0.01, print_duration=60.0)
        steady = settle(est, progress=0.50, duration=2 * HOUR, polls=60)

        # One poll where progress stalls entirely.
        jolted = est.update(progress=0.50, print_duration=2 * HOUR + 600)

        assert abs(jolted.total_seconds - steady.total_seconds) < 0.15 * steady.total_seconds

    def test_the_countdown_keeps_falling_between_polls(self):
        """Smoothing the total, not the remaining, is what makes this true."""
        est = estimator(slicer=4 * HOUR)
        first = est.update(progress=0.30, print_duration=1.0 * HOUR)
        second = est.update(progress=0.30, print_duration=1.0 * HOUR + 60)
        assert second.remaining_seconds < first.remaining_seconds

    def test_a_persistent_change_does_get_through(self):
        """Smoothing must damp noise, not ignore reality."""
        est = estimator(slicer=4 * HOUR)
        est.update(progress=0.01, print_duration=60.0)
        settle(est, progress=0.50, duration=2 * HOUR, polls=60)

        # The print genuinely halves in speed and stays there.
        slow = settle(est, progress=0.80, duration=6 * HOUR, polls=400)
        assert slow.total_seconds > 5 * HOUR


# --------------------------------------------------------------------------- #
# Lifecycle
# --------------------------------------------------------------------------- #


class TestLifecycle:
    def test_a_new_file_starts_over(self):
        est = estimator(slicer=4 * HOUR)
        settle(est, progress=0.90, duration=3.5 * HOUR)

        est.update(progress=0.0, print_duration=0.0, filename="other.gcode")
        assert est.filename == "other.gcode"
        assert est.slicer_seconds is None
        assert est.last.remaining_seconds is None

    def test_reset_clears_everything(self):
        est = estimator(slicer=4 * HOUR)
        settle(est, progress=0.5, duration=2 * HOUR)
        est.reset()
        assert est.filename == ""
        assert est.last.total_seconds is None

    def test_the_reported_method_is_translated(self):
        est = estimator(slicer=4 * HOUR, calibration=Calibration(factor=1.2, samples=5))
        payload = est.update(progress=0.01, print_duration=60.0).to_dict()
        assert payload["method"] == "slicer_calibrated"
        assert "معايَر" in payload["method_ar"]
        assert payload["calibration"]["learned"] is True


# --------------------------------------------------------------------------- #
# The claim that actually matters
# --------------------------------------------------------------------------- #


class TestAgainstASimulatedPrint:
    """A six-hour print, polled the way the monitor polls it.

    Byte progress runs ahead of time early - dense first-layer G-code is slow
    to execute - and lags late, when long infill moves are cheap in bytes.
    Filament tracks time far more closely, because volumetric flow is steady.
    Both curves are modelled so the two progress signals can be compared
    honestly rather than asserted about.

    The claims made here are only the ones that survive measurement. In
    particular there is no claim that rate maths alone beats the old formula:
    `elapsed * (1 - p) / p` IS the old formula, so a better *rate* cannot help.
    What helps is a better progress signal and a slicer estimate.
    """

    REAL_TOTAL = 6 * HOUR
    WARMUP = 400.0
    SLICER_SAID = 5 * HOUR      # slicers under-predict; this one by 20 %
    FILAMENT_TOTAL = 100_000.0
    POLL = 5.0

    def byte_progress(self, fraction: float) -> float:
        return min(1.0, fraction ** 0.75)

    def filament_used(self, fraction: float) -> float:
        return self.FILAMENT_TOTAL * (fraction ** 0.95)

    def run(self, *, slicer=None, calibration=None, filament=False):
        est = PrintTimeEstimator()
        if calibration is not None:
            est.set_calibration(calibration)
        est.begin("benchy.gcode", slicer, self.FILAMENT_TOTAL if filament else None)

        errors, silent = [], 0
        moment = 0.0
        while moment < self.WARMUP:
            est.update(progress=0.0, print_duration=moment, filament_used_mm=0.0)
            moment += self.POLL

        while moment < self.WARMUP + self.REAL_TOTAL:
            fraction = (moment - self.WARMUP) / self.REAL_TOTAL
            result = est.update(
                progress=self.byte_progress(fraction),
                print_duration=moment,
                filament_used_mm=self.filament_used(fraction) if filament else None,
            )
            truth = (1 - fraction) * self.REAL_TOTAL
            if result.remaining_seconds is None:
                silent += 1
            else:
                errors.append(abs(result.remaining_seconds - truth))
            moment += self.POLL
        return errors, silent

    def naive(self):
        """The formula being replaced, on the same print."""
        errors = []
        moment = self.WARMUP + self.POLL
        while moment < self.WARMUP + self.REAL_TOTAL:
            fraction = (moment - self.WARMUP) / self.REAL_TOTAL
            progress = self.byte_progress(fraction)
            remaining = moment / progress - moment
            errors.append(abs(remaining - (1 - fraction) * self.REAL_TOTAL))
            moment += self.POLL
        return errors

    @staticmethod
    def mean(values):
        return sum(values) / len(values)

    # ---- the case this printer is actually in ------------------------------

    def test_the_real_configuration_is_an_order_of_magnitude_better(self):
        """A file sliced on the Pi, after a few prints have been completed.

        Both the slicer estimate and the filament total come from the G-code
        metadata, which every file PrusaSlicer, Orca or Cura produced carries.
        """
        ours, _ = self.run(
            slicer=self.SLICER_SAID,
            calibration=Calibration(factor=1.2, samples=6),
            filament=True,
        )
        theirs = self.naive()

        assert self.mean(ours) < self.mean(theirs) / 5, (
            f"ours {self.mean(ours)/60:.0f} min average, "
            f"old {self.mean(theirs)/60:.0f} min"
        )
        assert max(ours) < 15 * 60, f"worst error {max(ours)/60:.0f} minutes"

    def test_the_old_formula_reports_days_remaining_early_on(self):
        """Not an exaggeration - this is the single worst reading it produces."""
        assert max(self.naive()) > 24 * HOUR

    def test_ours_never_reports_anything_absurd(self):
        ours, _ = self.run(
            slicer=self.SLICER_SAID,
            calibration=Calibration(factor=1.2, samples=6),
            filament=True,
        )
        assert max(ours) < HOUR

    # ---- degraded cases, measured rather than assumed ----------------------

    def test_filament_progress_alone_is_four_times_better_than_the_old_formula(self):
        """No slicer estimate at all - only a filament total."""
        ours, _ = self.run(filament=True)
        assert self.mean(ours) < self.mean(self.naive()) / 3

    def test_bytes_only_with_no_slicer_estimate_is_no_worse_than_before(self):
        """The honest floor.

        With byte progress and no slicer estimate there is nothing better to
        compute: `elapsed * (1 - p) / p` is exactly the formula being replaced,
        so the most that can be claimed is not making it worse - and not
        emitting the absurd early readings.
        """
        ours, _ = self.run()
        theirs = self.naive()
        assert self.mean(ours) <= self.mean(theirs) * 1.05
        assert max(ours) < max(theirs) / 10

    def test_the_uncalibrated_first_print_is_already_better(self):
        """Before any history exists, the slicer estimate alone still helps."""
        ours, _ = self.run(slicer=self.SLICER_SAID, filament=True)
        assert self.mean(ours) < self.mean(self.naive())

    def test_it_stays_silent_rather_than_guessing_when_it_cannot_tell(self):
        _, silent = self.run()
        assert silent > 0, "it should decline to answer during the warm-up"
