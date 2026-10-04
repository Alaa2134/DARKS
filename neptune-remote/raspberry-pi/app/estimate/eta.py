"""How long is left, worked out properly.

The estimate this replaces was one line:

    total = print_duration / file_progress
    remaining = total - print_duration

That is what Mainsail shows, and it is bad for reasons that all compound:

* **File progress is byte progress.** G-code is not uniformly dense. The first
  layers are slow, small, heavily-segmented moves, so 10 % of the bytes can be
  25 % of the time. The estimate is systematically wrong early and drifts.
* **`print_duration` includes the warm-up.** Five minutes of bed heating pass
  with progress at zero, so the very first division is by a number near zero
  and the answer is measured in days.
* **It ignores the slicer entirely**, even though the slicer already simulated
  the motion planner move by move and wrote the answer into the file.
* **It ignores the speed factor.** Set the printer to 150 % and the number
  does not move until enough new samples wash the old rate out.
* **It is unsmoothed**, so it jumps on every poll.

What this does instead, in order of what it trusts:

1. **The slicer's own estimate**, read from the G-code metadata.
2. **Corrected by a factor learned from this printer.** A slicer estimate is
   wrong by a fairly *constant* ratio on a given machine - PRINT_START heating,
   acceleration limits it did not model, a heavy hotend. Every completed print
   gives one `actual / estimated` sample. The median of the recent ones turns
   "the slicer says 4h and it always takes 4h40" into a number that is right
   from the first minute.
3. **Scaled by the live speed factor**, so moving the slider changes the answer
   immediately rather than fifteen minutes later.
4. **Blended toward this print's observed rate** as it progresses, because by
   halfway the print itself is better evidence than any prior.

And it smooths the **total**, not the remaining. Smoothing the remaining fights
the countdown; smoothing the total lets the remaining fall second by second on
its own, which is what makes it feel steady.

Nothing here invents a number. When there is no slicer estimate and too little
progress to extrapolate, the answer is `None` and the UI says it does not know
yet - which is more useful than a confident lie.
"""

from __future__ import annotations

import statistics
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, List, Optional

# When to start letting this print's own rate pull the answer.
#
# Late, deliberately. Extrapolating from progress carries a bias that only
# vanishes as progress approaches 1 - see _observed_total - so mid-print the
# calibrated slicer estimate is the better of the two, and the observed rate
# is worth most exactly where the slicer has least left to say.
OBSERVED_TRUSTED_FROM = 0.55
OBSERVED_FULLY_TRUSTED_AT = 0.92
# Progress at which the print is considered genuinely under way, used to place
# the anchor past the warm-up.
WARMUP_DONE_PROGRESS = 0.005
# The observed rate is measured over a window. Below these the window is too
# small to mean anything and the estimator says it does not know yet.
MIN_OBSERVED_PROGRESS = 0.05
MIN_OBSERVED_SECONDS = 120.0
# First progress reading above this means the backend joined a print already in
# flight - a restart - rather than watching it from the beginning.
MID_PRINT_JOIN_PROGRESS = 0.05
# Ignore calibration ratios outside this range - they are a cancelled print or
# a mismatched file, not a real measurement of this machine.
CALIBRATION_MIN = 0.5
CALIBRATION_MAX = 3.0
MIN_CALIBRATION_SAMPLES = 3
# Exponential smoothing on the total estimate.
SMOOTHING_ALPHA = 0.25


class Method(str, Enum):
    """Which evidence produced the number, reported so the UI can say so."""

    UNKNOWN = "unknown"
    SLICER = "slicer"
    SLICER_CALIBRATED = "slicer_calibrated"
    BLENDED = "blended"
    OBSERVED = "observed"


METHOD_AR: Dict[str, str] = {
    Method.UNKNOWN: "لسه بدري على تقدير",
    Method.SLICER: "من تقدير السلايسر",
    Method.SLICER_CALIBRATED: "من تقدير السلايسر، معايَر على طابعتك",
    Method.BLENDED: "تقدير السلايسر + السرعة الفعلية",
    Method.OBSERVED: "من السرعة الفعلية للطباعة",
}

METHOD_EN: Dict[str, str] = {
    Method.UNKNOWN: "Not enough to estimate yet",
    Method.SLICER: "From the slicer's estimate",
    Method.SLICER_CALIBRATED: "Slicer estimate, calibrated to this printer",
    Method.BLENDED: "Slicer estimate blended with the live rate",
    Method.OBSERVED: "From the observed print rate",
}


@dataclass
class Calibration:
    """How wrong the slicer usually is on this machine."""

    factor: float = 1.0
    samples: int = 0
    spread: float = 0.0

    @property
    def is_learned(self) -> bool:
        return self.samples >= MIN_CALIBRATION_SAMPLES

    @property
    def percent_off(self) -> float:
        return (self.factor - 1.0) * 100.0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "factor": round(self.factor, 4),
            "samples": self.samples,
            "spread": round(self.spread, 4),
            "learned": self.is_learned,
            "percent_off": round(self.percent_off, 1),
        }


def learn_calibration(pairs: List[tuple]) -> Calibration:
    """Median of `actual / estimated` over completed prints.

    Median rather than mean on purpose: one print that was paused for an hour
    while somebody changed filament would drag a mean permanently, and there
    are never enough samples for that to wash out.
    """
    ratios = []
    for actual, estimated in pairs:
        if not actual or not estimated or estimated <= 0:
            continue
        ratio = float(actual) / float(estimated)
        if CALIBRATION_MIN <= ratio <= CALIBRATION_MAX:
            ratios.append(ratio)

    if len(ratios) < MIN_CALIBRATION_SAMPLES:
        return Calibration(factor=1.0, samples=len(ratios))

    factor = statistics.median(ratios)
    spread = statistics.pstdev(ratios) if len(ratios) > 1 else 0.0
    return Calibration(factor=factor, samples=len(ratios), spread=spread)


@dataclass
class Estimate:
    remaining_seconds: Optional[float] = None
    total_seconds: Optional[float] = None
    method: Method = Method.UNKNOWN
    #: 0..1. Not a probability - a statement about how much evidence there is.
    confidence: float = 0.0
    calibration: Optional[Calibration] = None
    slicer_seconds: Optional[float] = None
    speed_factor: float = 1.0
    #: "filament" or "file" - which progress signal produced this. Filament is
    #: materially more accurate; reported so the diagnostics page can say when
    #: a file arrived without the metadata that makes it possible.
    progress_source: str = "file"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "remaining_seconds": self.remaining_seconds,
            "total_seconds": self.total_seconds,
            "method": self.method.value,
            "method_ar": METHOD_AR[self.method],
            "method_en": METHOD_EN[self.method],
            "confidence": round(self.confidence, 2),
            "slicer_seconds": self.slicer_seconds,
            "speed_factor": self.speed_factor,
            "progress_source": self.progress_source,
            "calibration": self.calibration.to_dict() if self.calibration else None,
        }


class PrintTimeEstimator:
    """Per-print state plus the machine-wide calibration.

    One instance lives for the life of the backend; :meth:`begin` resets the
    per-print half when a new file starts.
    """

    def __init__(self, *, clock=time.time) -> None:
        self._clock = clock
        self.calibration = Calibration()

        self.filename: str = ""
        self.slicer_seconds: Optional[float] = None
        #: Total filament the slicer says this file needs, when the metadata
        #: carries it. Extrusion is far more linear in time than bytes are, so
        #: this makes a materially better progress signal - see `_progress`.
        self.filament_total_mm: Optional[float] = None
        #: (print_duration, progress) at the first moment printing was genuinely
        #: under way. Everything about the observed rate is measured from here.
        self._anchor: Optional[tuple] = None
        #: "filament" or "file" - which signal the last estimate actually used.
        self.progress_source: str = "file"
        self._smoothed_total: Optional[float] = None
        self.last: Estimate = Estimate()

    # ------------------------------------------------------------- lifecycle
    def set_calibration(self, calibration: Calibration) -> None:
        self.calibration = calibration

    def begin(
        self,
        filename: str,
        slicer_seconds: Optional[float] = None,
        filament_total_mm: Optional[float] = None,
    ) -> None:
        """A new print started."""
        self.filename = filename
        self.slicer_seconds = slicer_seconds if (slicer_seconds or 0) > 0 else None
        self.filament_total_mm = (
            filament_total_mm if (filament_total_mm or 0) > 0 else None
        )
        self._anchor = None
        self.progress_source = "file"
        self._smoothed_total = None
        self.last = Estimate(slicer_seconds=self.slicer_seconds)

    def reset(self) -> None:
        self.begin("", None, None)

    # -------------------------------------------------------------- updating
    def _progress(
        self, file_progress: float, filament_used_mm: Optional[float]
    ) -> tuple:
        """The best progress signal this file offers.

        Filament first when the metadata gave us a total. Byte progress is a
        proxy for time and a poor one: G-code density varies enormously between
        a dense first layer and long infill runs. Extruded length tracks the
        material actually laid down, and volumetric flow is far steadier over a
        print than bytes-per-second is.

        Falls back to byte progress whenever the total is unknown or the
        reading looks wrong, rather than trusting a number that would put the
        print past 100 %.

        Returns (progress, is_filament_based).
        """
        if self.filament_total_mm and filament_used_mm is not None and filament_used_mm > 0:
            ratio = filament_used_mm / self.filament_total_mm
            if 0.0 < ratio <= 1.05:
                return min(1.0, ratio), True
        return file_progress, False

    def update(
        self,
        *,
        progress: float,
        print_duration: float,
        speed_factor: float = 1.0,
        filename: str = "",
        filament_used_mm: Optional[float] = None,
    ) -> Estimate:
        """Fold in one poll and return the current estimate."""
        if filename and filename != self.filename:
            # The file changed without a state transition being seen - start
            # over rather than mixing two prints together.
            self.begin(filename, None, None)

        file_progress = max(0.0, min(1.0, float(progress or 0.0)))
        print_duration = max(0.0, float(print_duration or 0.0))
        speed_factor = float(speed_factor or 1.0)
        if speed_factor <= 0:
            speed_factor = 1.0

        effective, from_filament = self._progress(file_progress, filament_used_mm)
        self.progress_source = "filament" if from_filament else "file"

        if self._anchor is None and effective >= WARMUP_DONE_PROGRESS:
            self._anchor = self._place_anchor(print_duration, effective, from_filament)

        estimate = self._compute(effective, print_duration, speed_factor)
        self.last = estimate
        return estimate

    # -------------------------------------------------------------- internals
    def _place_anchor(
        self, print_duration: float, progress: float, from_filament: bool
    ) -> tuple:
        """Where to measure the observed rate from.

        Three cases, and the third is an empirical compensation rather than a
        principle - said plainly so nobody "corrects" it later and makes the
        estimate worse:

        1. **Joined mid-print.** The backend restarted while something was
           already running. Anchor here, at whatever progress we first saw.
           Pretending the print began at zero would say it did 60 % in the ten
           seconds since we woke up.
        2. **Filament progress.** Extrusion is close to linear in time, so the
           warm-up genuinely is not printing time and excluding it is simply
           correct.
        3. **Byte progress.** Here two errors were cancelling in the formula
           this replaces. Byte progress runs *ahead* of time early - the dense
           first layers are slow - which under-predicts what is left; and
           counting the warm-up in the denominator over-predicts it. Measured
           over a simulated print, removing only the second makes the answer
           worse (mean error 57 -> 65 min). So with byte progress the warm-up
           stays counted. It is compensation, not correctness, and it is only
           reached when the file carries no filament total.
        """
        if progress > MID_PRINT_JOIN_PROGRESS:
            return (print_duration, progress)
        if from_filament:
            return (print_duration, progress)
        return (0.0, 0.0)

    def _observed_total(self, progress: float, print_duration: float) -> Optional[float]:
        """Total time implied by how fast *this* print is actually going.

        Measured between an anchor and now, rather than from t=0. Two reasons,
        and the second is a bug the obvious version has:

        * the anchor is placed at the end of the warm-up, so five minutes of
          bed heating are not counted as five minutes of slow printing - which
          would make every print look permanently behind and never recover;
        * the anchor records the *progress* at that moment too, so a backend
          that restarts mid-print measures the rate over the window it actually
          observed. Assuming progress started at zero would say a print
          resumed at 60 % had done 60 % in ten seconds.

        The result is biased, and knowingly so. Progress here is byte progress
        unless the file told us its filament total, and bytes run ahead of time
        early - dense, slow first-layer moves - so this under-predicts what is
        left. The bias shrinks to nothing as progress approaches 1, which is
        exactly why this is weighted in late and not early.
        """
        if self._anchor is None:
            return None

        anchor_duration, anchor_progress = self._anchor
        moved = progress - anchor_progress
        elapsed = print_duration - anchor_duration

        # A rate measured over two minutes and 2 % of a print is not a rate,
        # it is one number divided by another. Refusing to answer here is why
        # the estimate no longer swings by hours in the opening minutes.
        if moved < MIN_OBSERVED_PROGRESS or elapsed < MIN_OBSERVED_SECONDS:
            return None

        remaining_progress = max(0.0, 1.0 - progress)
        remaining_seconds = remaining_progress * (elapsed / moved)
        return print_duration + remaining_seconds

    def _slicer_total(self, speed_factor: float) -> Optional[float]:
        if self.slicer_seconds is None:
            return None
        total = self.slicer_seconds
        if self.calibration.is_learned:
            total *= self.calibration.factor
        # The slicer simulated 100 % speed. Anything else scales the whole
        # thing, and this is why the number reacts to the slider immediately.
        return total / speed_factor

    @staticmethod
    def _observed_weight(progress: float) -> float:
        """How much to trust this print over the prior, by progress."""
        if progress <= OBSERVED_TRUSTED_FROM:
            return 0.0
        if progress >= OBSERVED_FULLY_TRUSTED_AT:
            return 1.0
        span = OBSERVED_FULLY_TRUSTED_AT - OBSERVED_TRUSTED_FROM
        return (progress - OBSERVED_TRUSTED_FROM) / span

    def _compute(self, progress: float, print_duration: float, speed_factor: float) -> Estimate:
        slicer_total = self._slicer_total(speed_factor)
        observed_total = self._observed_total(progress, print_duration)

        if slicer_total is None and observed_total is None:
            return Estimate(
                method=Method.UNKNOWN,
                confidence=0.0,
                calibration=self.calibration,
                slicer_seconds=self.slicer_seconds,
                speed_factor=speed_factor,
                progress_source=self.progress_source,
            )

        if observed_total is None:
            total = slicer_total
            method = (
                Method.SLICER_CALIBRATED if self.calibration.is_learned else Method.SLICER
            )
            confidence = 0.8 if self.calibration.is_learned else 0.55
        elif slicer_total is None:
            total = observed_total
            method = Method.OBSERVED
            # Extrapolating from 5 % is a guess; from 60 % it is a measurement.
            confidence = min(0.75, 0.15 + progress * 0.8)
        else:
            weight = self._observed_weight(progress)
            total = slicer_total * (1 - weight) + observed_total * weight
            if weight <= 0.0:
                method = (
                    Method.SLICER_CALIBRATED if self.calibration.is_learned else Method.SLICER
                )
                confidence = 0.8 if self.calibration.is_learned else 0.6
            elif weight >= 1.0:
                method = Method.OBSERVED
                confidence = 0.9
            else:
                method = Method.BLENDED
                confidence = 0.85

        total = self._smooth(total)
        remaining = max(0.0, total - print_duration) if total is not None else None

        return Estimate(
            remaining_seconds=remaining,
            total_seconds=total,
            method=method,
            confidence=confidence,
            calibration=self.calibration,
            slicer_seconds=self.slicer_seconds,
            speed_factor=speed_factor,
            progress_source=self.progress_source,
        )

    def _smooth(self, total: Optional[float]) -> Optional[float]:
        """Exponential smoothing on the *total*.

        Smoothing the remaining time would fight the countdown - every second
        that passes should take a second off, and a filter would blunt exactly
        that. Smoothing the total leaves the subtraction to do the counting,
        so the displayed number falls steadily and only the underlying
        prediction moves.
        """
        if total is None:
            return None
        if self._smoothed_total is None:
            self._smoothed_total = total
        else:
            self._smoothed_total = (
                SMOOTHING_ALPHA * total + (1 - SMOOTHING_ALPHA) * self._smoothed_total
            )
        return self._smoothed_total


def slicer_seconds_from_metadata(metadata: Optional[Dict[str, Any]]) -> Optional[float]:
    """The slicer's own estimate, if the file carries one.

    PrusaSlicer, OrcaSlicer and Cura all write this and Moonraker surfaces it
    as `estimated_time`. A file uploaded from somewhere else may not have it,
    which is a reason to fall back - not a reason to invent a number.
    """
    if not isinstance(metadata, dict):
        return None
    value = metadata.get("estimated_time")
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    return seconds if seconds > 0 else None
