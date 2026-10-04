"""Noticing a print going wrong before it looks wrong.

This is the honest version of "make the app predict things". There is no model
here and nothing is learned from anyone else's printer. Everything below is
computed from telemetry that is already streaming once a second, and every
finding carries the numbers it was derived from - so a wrong one can be argued
with instead of shrugged at.

What it watches, and why each one is worth watching:

* **Layer time trend.** A partial clog does not announce itself. What it does
  is make every layer take slightly longer than the last, for tens of layers,
  while the print still looks fine. By the time the extruder starts clicking
  the part is already ruined. A sustained upward drift in layer time, on layers
  of similar size, is the earliest signal there is.

* **Extrusion against the slicer's plan.** The G-code metadata says how much
  filament the whole file needs. Compare that to what has actually been fed at
  the current progress: consistently short means the extruder is slipping or
  grinding; consistently over means the flow multiplier is wrong.

* **Heater stability.** A nozzle oscillating several degrees around its target
  is a loose thermistor, a failing heater cartridge or PID that needs retuning.
  Klipper only shuts down on a runaway - the long slow version that just ruins
  surface quality passes silently.

* **Temperature deviation.** Sitting far below target mid-print means the
  heater is losing the fight - a part-cooling fan aimed wrong, a draught, or a
  dying cartridge.

Deliberately *not* here: anything that needs a camera (the vision detector
already owns that), and anything that would pause a print on its own. These
raise findings; acting on them is the user's call.
"""

from __future__ import annotations

import statistics
import time
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Deque, Dict, List, Optional


class Severity(str, Enum):
    INFO = "info"
    WATCH = "watch"      # worth knowing, nothing to do yet
    WARNING = "warning"  # act soon or the print suffers
    URGENT = "urgent"    # act now


@dataclass
class Finding:
    """One observation, with the arithmetic that produced it."""

    id: str
    severity: Severity
    title_ar: str
    title_en: str
    detail_ar: str
    #: The numbers behind the claim, so it can be checked rather than believed.
    evidence: Dict[str, float] = field(default_factory=dict)
    suggestion_ar: str = ""
    detected_at: float = 0.0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "severity": self.severity.value,
            "title_ar": self.title_ar,
            "title_en": self.title_en,
            "detail_ar": self.detail_ar,
            "evidence": {k: round(v, 3) for k, v in self.evidence.items()},
            "suggestion_ar": self.suggestion_ar,
            "detected_at": self.detected_at,
        }


@dataclass
class LayerRecord:
    number: int
    seconds: float
    filament_mm: float


@dataclass
class Thresholds:
    """Every number that decides whether something is reported.

    Gathered here rather than scattered through the code so they can be argued
    about, and so it is obvious how much slack each check has. They are set to
    be quiet: a detector that cries wolf is one nobody reads.
    """

    #: Layers needed before a trend means anything.
    min_layers_for_trend: int = 12
    #: Layers compared against the baseline.
    trend_window: int = 8
    #: Fractional slowdown that counts as a trend.
    slowdown_warning: float = 0.35
    slowdown_urgent: float = 0.70
    #: A layer using this much less filament than the baseline is a smaller
    #: layer, not a slower one, and its time says nothing about flow.
    similar_layer_tolerance: float = 0.30

    #: Under-extrusion against the slicer's plan.
    extrusion_warning: float = 0.10
    extrusion_urgent: float = 0.20
    #: Progress before the extrusion comparison means anything - early on the
    #: purge line and first layer distort it badly.
    extrusion_min_progress: float = 0.15

    #: Heater stability, in degrees.
    heater_wobble_warning: float = 2.5
    heater_wobble_urgent: float = 5.0
    heater_below_target_warning: float = 5.0
    #: A sample further than this from target means the heater is still
    #: travelling - heating up, or following a temperature-tower band - so
    #: there is nothing to say about its stability yet.
    ramp_deviation_c: float = 12.0
    #: Samples needed before the heater verdict is meaningful.
    min_heater_samples: int = 30


class AnomalyDetector:
    """Per-print telemetry watcher. Findings only - it never acts."""

    def __init__(self, thresholds: Optional[Thresholds] = None, *, clock=time.time) -> None:
        self.thresholds = thresholds or Thresholds()
        self._clock = clock

        self.filename: str = ""
        self.slicer_filament_mm: Optional[float] = None
        self.layers: List[LayerRecord] = []
        self._nozzle: Deque[tuple] = deque(maxlen=120)   # (actual, target)
        self._bed: Deque[tuple] = deque(maxlen=120)
        self._layer_started_at: Optional[float] = None
        self._layer_started_filament: float = 0.0
        self._current_layer: Optional[int] = None
        self.findings: List[Finding] = []

    # ------------------------------------------------------------- lifecycle
    def begin(self, filename: str, slicer_filament_mm: Optional[float] = None) -> None:
        self.filename = filename
        self.slicer_filament_mm = (
            slicer_filament_mm if (slicer_filament_mm or 0) > 0 else None
        )
        self.layers = []
        self._nozzle.clear()
        self._bed.clear()
        self._layer_started_at = None
        self._layer_started_filament = 0.0
        self._current_layer = None
        self.findings = []

    def reset(self) -> None:
        self.begin("", None)

    # --------------------------------------------------------------- feeding
    def observe(
        self,
        *,
        layer: Optional[int],
        print_duration: float,
        filament_used_mm: float,
        nozzle_actual: float,
        nozzle_target: float,
        bed_actual: float = 0.0,
        bed_target: float = 0.0,
    ) -> None:
        """One poll."""
        if nozzle_target > 0:
            self._nozzle.append((nozzle_actual, nozzle_target))
        if bed_target > 0:
            self._bed.append((bed_actual, bed_target))

        if layer is None:
            return

        if self._current_layer is None:
            self._current_layer = layer
            self._layer_started_at = print_duration
            self._layer_started_filament = filament_used_mm
            return

        if layer == self._current_layer:
            return

        # A layer boundary: close the one that just finished.
        if self._layer_started_at is not None:
            seconds = print_duration - self._layer_started_at
            filament = filament_used_mm - self._layer_started_filament
            if seconds > 0:
                self.layers.append(
                    LayerRecord(
                        number=self._current_layer, seconds=seconds, filament_mm=max(0.0, filament)
                    )
                )
        self._current_layer = layer
        self._layer_started_at = print_duration
        self._layer_started_filament = filament_used_mm

    # ---------------------------------------------------------------- checks
    def evaluate(self, *, progress: float = 0.0, filament_used_mm: float = 0.0) -> List[Finding]:
        """Everything worth reporting right now."""
        findings: List[Finding] = []
        for check in (
            lambda: self._check_layer_time_trend(),
            lambda: self._check_extrusion_against_plan(progress, filament_used_mm),
            lambda: self._check_heater_stability(),
            lambda: self._check_heater_deficit(),
        ):
            finding = check()
            if finding is not None:
                finding.detected_at = self._clock()
                findings.append(finding)

        self.findings = findings
        return findings

    # -- layer time -----------------------------------------------------------
    def _comparable_layers(self) -> List[LayerRecord]:
        """Layers of similar size, so time differences mean speed differences.

        Without this the check fires on every print that has a wide base and a
        narrow top - which is most of them. A layer that used 40 % less
        filament took less time because it was smaller, and that says nothing
        about a clog.
        """
        if len(self.layers) < self.thresholds.min_layers_for_trend:
            return []

        recent = self.layers[-self.thresholds.trend_window:]
        median_filament = statistics.median(
            [layer.filament_mm for layer in recent if layer.filament_mm > 0] or [0.0]
        )
        if median_filament <= 0:
            return []

        tolerance = self.thresholds.similar_layer_tolerance
        return [
            layer
            for layer in self.layers
            if layer.filament_mm > 0
            and abs(layer.filament_mm - median_filament) / median_filament <= tolerance
        ]

    def _check_layer_time_trend(self) -> Optional[Finding]:
        comparable = self._comparable_layers()
        window = self.thresholds.trend_window
        if len(comparable) < window * 2:
            return None

        baseline = statistics.median([layer.seconds for layer in comparable[:-window]])
        recent = statistics.median([layer.seconds for layer in comparable[-window:]])
        if baseline <= 0:
            return None

        change = (recent - baseline) / baseline
        if change < self.thresholds.slowdown_warning:
            return None

        severity = (
            Severity.URGENT if change >= self.thresholds.slowdown_urgent else Severity.WARNING
        )
        return Finding(
            id="layer_time_drift",
            severity=severity,
            title_ar="الطبقات بقت بتاخد وقت أطول",
            title_en="Layers are taking longer",
            detail_ar=(
                f"الطبقات دلوقتي بتاخد {recent:.0f} ثانية بدل {baseline:.0f} ثانية "
                f"في الأول — زيادة {change * 100:.0f}٪ على طبقات بنفس الحجم تقريبًا. "
                "ده أول علامة على انسداد جزئي بيتكوّن، أو الفيلامنت بيزحلق في الإكستروجن."
            ),
            evidence={
                "baseline_seconds": baseline,
                "recent_seconds": recent,
                "change_percent": change * 100,
                "layers_compared": float(len(comparable)),
            },
            suggestion_ar=(
                "اسمع صوت الإكستروجن — لو بيطقطق يبقى انسداد. "
                "لو الطباعة مهمة، أوقفها واعمل تنظيف للنوزل قبل ما القطعة تتبهدل."
            ),
        )

    # -- extrusion ------------------------------------------------------------
    def _check_extrusion_against_plan(
        self, progress: float, filament_used_mm: float
    ) -> Optional[Finding]:
        if self.slicer_filament_mm is None or filament_used_mm <= 0:
            return None
        if progress < self.thresholds.extrusion_min_progress:
            return None

        expected = self.slicer_filament_mm * progress
        if expected <= 0:
            return None

        deviation = (filament_used_mm - expected) / expected
        magnitude = abs(deviation)
        if magnitude < self.thresholds.extrusion_warning:
            return None

        severity = (
            Severity.URGENT if magnitude >= self.thresholds.extrusion_urgent else Severity.WARNING
        )
        short = deviation < 0

        return Finding(
            id="extrusion_deviation",
            severity=severity,
            title_ar="كمية الفيلامنت مش زي خطة السلايسر",
            title_en="Extrusion is off the slicer's plan",
            detail_ar=(
                f"عند {progress * 100:.0f}٪ من الطباعة، المفروض يكون اتصرف "
                f"{expected / 1000:.1f} متر فيلامنت، والفعلي {filament_used_mm / 1000:.1f} متر "
                f"({deviation * 100:+.0f}٪). "
                + (
                    "الأقل من المتوقع معناه الإكستروجن بيزحلق أو بيبرد على الخيط."
                    if short
                    else "الأكتر من المتوقع معناه معامل التدفق عالي."
                )
            ),
            evidence={
                "expected_mm": expected,
                "actual_mm": filament_used_mm,
                "deviation_percent": deviation * 100,
                "progress": progress,
            },
            suggestion_ar=(
                "شوف ترس الإكستروجن نضيف ولا عليه برادة، واتأكد إن ضغط الزنبرك مظبوط."
                if short
                else "اعمل معايرة التدفق (Flow) من صفحة المعايرة."
            ),
        )

    # -- heaters --------------------------------------------------------------
    def _check_heater_stability(self) -> Optional[Finding]:
        window = self.thresholds.min_heater_samples
        if len(self._nozzle) < window:
            return None

        # The most recent window only, and only if the whole of it is settled.
        #
        # Every print starts cold, so the heat-up ramp is a large, entirely
        # expected deviation. Filtering individual samples is not enough: the
        # tail of the ramp still sits inside any sane per-sample threshold and
        # inflates the spread on its own. So if *any* sample in the window is
        # still far from target, the heater is moving rather than misbehaving,
        # and there is no stability verdict to give yet.
        recent = list(self._nozzle)[-window:]
        deviations = [actual - target for actual, target in recent if target > 0]
        if len(deviations) < window:
            return None
        if max(abs(value) for value in deviations) > self.thresholds.ramp_deviation_c:
            return None
        wobble = statistics.pstdev(deviations)
        if wobble < self.thresholds.heater_wobble_warning:
            return None

        severity = (
            Severity.URGENT if wobble >= self.thresholds.heater_wobble_urgent else Severity.WARNING
        )
        return Finding(
            id="nozzle_unstable",
            severity=severity,
            title_ar="حرارة النوزل مش ثابتة",
            title_en="The nozzle temperature is unstable",
            detail_ar=(
                f"الحرارة بتتأرجح حوالي ±{wobble:.1f}° حوالين الهدف. "
                "Klipper بيوقف الطباعة في حالة الانفلات الحراري بس، والتأرجح البطيء ده "
                "بيعدّي من غير ما حد ياخد باله — وهو بيأثر على شكل السطح."
            ),
            evidence={
                "wobble_c": wobble,
                "samples": float(len(deviations)),
                "max_deviation_c": max(abs(value) for value in deviations),
            },
            suggestion_ar=(
                "شوف سلك الثيرمستور مربوط كويس ومش بيتحرك مع الحركة، "
                "وبعدين اعمل PID_CALIBRATE HEATER=extruder TARGET=210 وSAVE_CONFIG."
            ),
        )

    def _check_heater_deficit(self) -> Optional[Finding]:
        if len(self._nozzle) < self.thresholds.min_heater_samples:
            return None

        recent = list(self._nozzle)[-self.thresholds.min_heater_samples:]
        deficits = [target - actual for actual, target in recent if target > 0]
        if not deficits:
            return None

        average = statistics.mean(deficits)
        if average < self.thresholds.heater_below_target_warning:
            return None

        return Finding(
            id="nozzle_below_target",
            severity=Severity.WARNING,
            title_ar="النوزل مش واصل للحرارة المطلوبة",
            title_en="The nozzle is not reaching its target",
            detail_ar=(
                f"النوزل قاعد {average:.1f}° تحت الهدف في المتوسط أثناء الطباعة. "
                "السخان بيخسر المعركة — غالبًا مروحة التبريد مسلطة عليه، "
                "أو في هوا بارد، أو الكارتريدج بيضعف."
            ),
            evidence={
                "average_deficit_c": average,
                "samples": float(len(deficits)),
            },
            suggestion_ar=(
                "اتأكد إن سيليكون النوزل (الجورب) موجود ومظبوط، "
                "وإن مروحة التبريد مش بتضرب على البلوك نفسه."
            ),
        )

    # ---------------------------------------------------------------- status
    def status(self) -> Dict[str, Any]:
        return {
            "filename": self.filename,
            "layers_observed": len(self.layers),
            "findings": [finding.to_dict() for finding in self.findings],
            "watching": bool(self.filename),
        }
